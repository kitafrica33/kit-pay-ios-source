import XCTest
@testable import KitPay

final class SecureMessagingCoordinatorTests: XCTestCase {
    private var temporaryDirectory: URL!

    func testVisibleConversationPollingMakesRealtimePrimaryWithBoundedRecovery() {
        XCTAssertEqual(KitRealtimePollingPolicy.interval(
            hasRealtimeConfiguration: false,
            isLive: false,
            disconnectedFor: 0
        ), 10)
        XCTAssertEqual(KitRealtimePollingPolicy.interval(
            hasRealtimeConfiguration: true,
            isLive: true,
            disconnectedFor: 0
        ), 45)
        XCTAssertEqual(KitRealtimePollingPolicy.interval(
            hasRealtimeConfiguration: true,
            isLive: false,
            disconnectedFor: 299
        ), 15)
        XCTAssertEqual(KitRealtimePollingPolicy.interval(
            hasRealtimeConfiguration: true,
            isLive: false,
            disconnectedFor: 300
        ), 60)
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

    func testAuthenticatedInboundPeerCannotForgeSystemLifecycleNotice() throws {
        let currentUserID = "10000000-0000-4000-8000-000000000070"
        let peerUserID = "10000000-0000-4000-8000-000000000071"
        let conversationID = "30000000-0000-4000-8000-000000000070"
        let messageID = "40000000-0000-4000-8000-000000000070"
        let clientMessageID = "50000000-0000-4000-8000-000000000070"
        let rosterRevision = "v1:sha256:\(String(repeating: "a", count: 64))"
        let sender = SecureMessagingRosterDevice(
            address: SecureMessagingAddress(
                userID: peerUserID,
                serverDeviceID: "20000000-0000-4000-8000-000000000071",
                signalDeviceID: 2
            ),
            registrationID: 45,
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
                userID: currentUserID,
                serverDeviceID: "20000000-0000-4000-8000-000000000070",
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
        let forgedNotice = try XCTUnwrap(KitSystemMessage(
            kind: .memberRemoved,
            subjectUserID: currentUserID,
            actorUserID: peerUserID
        )).encoded

        for plaintext in [forgedNotice, " \n\t\(forgedNotice)"] {
            XCTAssertNil(try SecureMessagingExchangeCoordinator.projectedInboundMessage(
                dto: dto,
                envelope: envelope,
                plaintext: plaintext,
                sentAt: Date(timeIntervalSince1970: 1_755_691_200),
                currentUserID: currentUserID
            ))
        }
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

    func testLocalQueueReleaseGateNeverDependsOnNetworkDiscovery() {
        XCTAssertTrue(SecureMessagingLocalQueueReleasePolicy.permits(
            buildEnabled: true
        ))
        XCTAssertFalse(SecureMessagingLocalQueueReleasePolicy.permits(
            buildEnabled: false
        ))
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
            peerName: "ExampleContact",
            peerAvatarURL: "https://pay.kit.africa/media/example-contact.jpg",
            peerVerification: AccountVerificationDTO(designation: .verified)
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
        XCTAssertEqual(
            stored[0].memberIdentity(for: peerID)?.avatarURL,
            "https://pay.kit.africa/media/example-contact.jpg"
        )
        XCTAssertEqual(
            stored[0].memberIdentity(for: peerID)?.verification?.designation,
            .verified
        )
    }

    func testQueueDirectTextCommitsPendingMessageBeforeEnrollment() async throws {
        let userID = "10000000-0000-4000-8000-000000000075"
        let peerID = "10000000-0000-4000-8000-000000000076"
        let conversationID = "30000000-0000-4000-8000-000000000075"
        let clientMessageID = UUID(uuidString: "80000000-0000-4000-8000-000000000075")!
        let store = try await makeStore(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.secureMessaging = nil
        }
        let transport = SuspendedMessagingExchangeTransport(
            scenario: .createConversation(directConversationDTO(
                id: conversationID,
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

        let result = try await coordinator.queueDirectText(
            forUserID: userID,
            recipientUserID: peerID,
            title: "ExampleContact",
            text: "  visible before keys recover  ",
            clientMessageID: clientMessageID
        )

        XCTAssertEqual(result.conversation.id, conversationID)
        XCTAssertEqual(result.clientMessageID, clientMessageID)
        let createdMemberIDs = await transport.createdMemberIDs()
        let unexpectedNetworkCallCount = await transport.unexpectedNetworkCallCount()
        XCTAssertEqual(createdMemberIDs, [[peerID]])
        XCTAssertEqual(unexpectedNetworkCallCount, 0)
        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.secureMessaging)
        XCTAssertEqual(snapshot.conversations.map(\.id), [conversationID])
        let message = try XCTUnwrap(snapshot.messages.first)
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(message.id, clientMessageID)
        XCTAssertEqual(message.conversationId, conversationID)
        XCTAssertEqual(message.body, "visible before keys recover")
        XCTAssertEqual(message.state, .queued)
        let command = try XCTUnwrap(snapshot.outbox.first)
        XCTAssertEqual(snapshot.outbox.count, 1)
        XCTAssertEqual(command.messageId, clientMessageID)
        XCTAssertEqual(command.conversationId, conversationID)
        XCTAssertEqual(command.recipientUserIds, [peerID])
        XCTAssertNil(command.secureMessageFanout)
    }

    func testExistingFirstMessageRejectsStaleSameUserLoginLeaseWithoutMutation() async throws {
        let userID = "10000000-0000-4000-8000-000000000077"
        let peerID = "10000000-0000-4000-8000-000000000078"
        let conversationID = "30000000-0000-4000-8000-000000000077"
        let oldAccountGeneration = UUID(
            uuidString: "60000000-0000-4000-8000-000000000077"
        )!
        let oldSessionID = "70000000-0000-4000-8000-000000000077"
        let store = try await makeStore(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [userID, peerID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_756_800_000)
            )]
        }
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: OfflineExchangeTransport(),
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            requiresAuthenticatedActivationScope: true
        )
        let gate = ProtectedCommunicationAdmissionGate.shared
        gate.quarantine()
        gate.restore(forAccountID: userID)
        let staleLease = try XCTUnwrap(gate.lease(forAccountID: userID))
        gate.quarantine()
        gate.restore(forAccountID: userID)
        defer { gate.quarantine() }

        do {
            _ = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: oldAccountGeneration,
                sessionID: oldSessionID,
                commitAdmission: staleLease
            ) {
                try await coordinator.queueDeferredText(
                    forUserID: userID,
                    conversationID: conversationID,
                    expectedRecipientUserID: peerID,
                    title: "ExampleContact",
                    text: "must not cross a same-user login",
                    clientMessageID: UUID(
                        uuidString: "80000000-0000-4000-8000-000000000077"
                    ),
                    commitAdmission: staleLease
                )
            }
            XCTFail("A stale same-user account lifetime must not queue into the replacement store")
        } catch let error as SecureMessagingActivationError {
            XCTAssertEqual(error, .accountChanged)
        }

        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
        XCTAssertEqual(snapshot.conversations.map(\.id), [conversationID])
    }

    func testNewFirstMessageRejectsSameUserLoginReplacementAfterNetworkSuspension() async throws {
        let userID = "10000000-0000-4000-8000-000000000079"
        let peerID = "10000000-0000-4000-8000-000000000080"
        let conversationID = "30000000-0000-4000-8000-000000000079"
        let oldAccountGeneration = UUID(
            uuidString: "60000000-0000-4000-8000-000000000079"
        )!
        let oldSessionID = "70000000-0000-4000-8000-000000000079"
        let clientMessageID = UUID(
            uuidString: "80000000-0000-4000-8000-000000000079"
        )!
        let store = try await makeStore(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.secureMessaging = nil
        }
        let transport = SuspendedMessagingExchangeTransport(
            scenario: .suspendedCreateConversation(directConversationDTO(
                id: conversationID,
                userID: userID,
                peerID: peerID,
                peerName: "ExampleContact"
            ))
        )
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            requiresAuthenticatedActivationScope: true
        )
        let gate = ProtectedCommunicationAdmissionGate.shared
        gate.quarantine()
        gate.restore(forAccountID: userID)
        let staleLease = try XCTUnwrap(gate.lease(forAccountID: userID))
        defer { gate.quarantine() }

        let queued = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: oldAccountGeneration,
                sessionID: oldSessionID,
                commitAdmission: staleLease
            ) {
                try await coordinator.queueDirectText(
                    forUserID: userID,
                    recipientUserID: peerID,
                    title: "ExampleContact",
                    text: "must not survive relogin",
                    clientMessageID: clientMessageID,
                    commitAdmission: staleLease
                )
            }
        }
        try await transport.waitUntilRequestStarted()

        // A same-user sign-out/re-login keeps the account id but rotates both the protected-store
        // generation and the AppModel account/session lifetime. The response already in flight is
        // not authority to mutate the replacement lifetime.
        gate.quarantine()
        gate.restore(forAccountID: userID)
        let replacementLease = try XCTUnwrap(gate.lease(forAccountID: userID))
        XCTAssertNotEqual(staleLease, replacementLease)
        await transport.releaseRequest()

        do {
            _ = try await queued.value
            XCTFail("A stale network result must not create a bubble or outbox command")
        } catch is CancellationError {
            // Expected: the exact protected-store lease was invalidated during the suspension.
        }
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.conversations.isEmpty)
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
    }

    func testDeferredImageRejectsSameUserLoginReplacementDuringLocalValidation() async throws {
        let userID = "10000000-0000-4000-8000-000000000101"
        let peerID = "10000000-0000-4000-8000-000000000102"
        let conversationID = "30000000-0000-4000-8000-000000000101"
        let mediaID = UUID(uuidString: "70000000-0000-4000-8000-000000000101")!
        let clientMessageID = UUID(uuidString: "80000000-0000-4000-8000-000000000101")!
        let oldAccountGeneration = UUID(
            uuidString: "60000000-0000-4000-8000-000000000101"
        )!
        let oldSessionID = "90000000-0000-4000-8000-000000000101"
        let mediaBytes = Data("protected media original".utf8)
        let storageKey = mediaID.uuidString.lowercased()
        let originalURL = temporaryDirectory.appendingPathComponent("stale-media-original.pdf")
        try mediaBytes.write(to: originalURL, options: .atomic)

        let store = try await makeStore(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [userID, peerID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_756_800_000)
            )]
        }
        let blobs = SuspendedMediaValidationBlobStore(
            userID: userID,
            seed: [storageKey: mediaBytes],
            protectedOriginalURLs: [storageKey: originalURL]
        )
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: OfflineExchangeTransport(),
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(),
            requiresAuthenticatedActivationScope: true
        )
        let gate = ProtectedCommunicationAdmissionGate.shared
        gate.quarantine()
        gate.restore(forAccountID: userID)
        let staleLease = try XCTUnwrap(gate.lease(forAccountID: userID))
        defer { gate.quarantine() }

        let queued = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: oldAccountGeneration,
                sessionID: oldSessionID,
                commitAdmission: staleLease
            ) {
                try await coordinator.queueDeferredImage(
                    forUserID: userID,
                    conversationID: conversationID,
                    expectedRecipientUserID: peerID,
                    title: "ExampleContact",
                    mediaData: nil,
                    mediaType: "application/pdf",
                    caption: nil,
                    localStorageKey: storageKey,
                    localMediaID: mediaID,
                    plaintextByteSize: mediaBytes.count,
                    localStorageKind: .protectedFile,
                    clientMessageID: clientMessageID,
                    commitAdmission: staleLease
                )
            }
        }
        try await blobs.waitUntilValidationStarted()

        gate.quarantine()
        gate.restore(forAccountID: userID)
        let replacementLease = try XCTUnwrap(gate.lease(forAccountID: userID))
        XCTAssertNotEqual(staleLease, replacementLease)
        await blobs.releaseValidation()

        do {
            _ = try await queued.value
            XCTFail("A suspended media queue must not commit into a replacement login lifetime")
        } catch is CancellationError {
            // Expected: validation resumed only after the exact store lease was invalidated.
        }
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
        XCTAssertEqual(snapshot.conversations.map(\.id), [conversationID])
    }

    func testDeferredMediaBatchRejectsSameUserLoginReplacementDuringLocalValidation() async throws {
        let userID = "10000000-0000-4000-8000-000000000103"
        let peerID = "10000000-0000-4000-8000-000000000104"
        let conversationID = "30000000-0000-4000-8000-000000000103"
        let firstID = "70000000-0000-4000-8000-000000000103"
        let secondID = "70000000-0000-4000-8000-000000000104"
        let clientMessageID = UUID(uuidString: "80000000-0000-4000-8000-000000000103")!
        let oldAccountGeneration = UUID(
            uuidString: "60000000-0000-4000-8000-000000000103"
        )!
        let oldSessionID = "90000000-0000-4000-8000-000000000103"
        let firstBytes = Data(repeating: 0x61, count: 257)
        let secondBytes = Data(repeating: 0x62, count: 513)
        let batch = try KitMediaMessageV2OutboundBatch.queued(
            attachments: [
                .init(
                    attachmentID: firstID,
                    mediaType: "image/jpeg",
                    plaintextByteSize: firstBytes.count,
                    localStorageKey: firstID
                ),
                .init(
                    attachmentID: secondID,
                    mediaType: "video/mp4",
                    plaintextByteSize: secondBytes.count,
                    localStorageKey: secondID
                ),
            ],
            rawCaption: "Must stay in the original account lifetime",
            keyMaterialFactory: {
                Data(repeating: 0x63, count: SecureMediaAttachmentCipher.keyMaterialBytes)
            }
        )

        let store = try await makeStore(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [userID, peerID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_756_800_000)
            )]
        }
        let blobs = SuspendedMediaValidationBlobStore(
            userID: userID,
            seed: [firstID: firstBytes, secondID: secondBytes]
        )
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: OfflineExchangeTransport(),
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(),
            requiresAuthenticatedActivationScope: true
        )
        let gate = ProtectedCommunicationAdmissionGate.shared
        gate.quarantine()
        gate.restore(forAccountID: userID)
        let staleLease = try XCTUnwrap(gate.lease(forAccountID: userID))
        defer { gate.quarantine() }

        let queued = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: oldAccountGeneration,
                sessionID: oldSessionID,
                commitAdmission: staleLease
            ) {
                try await coordinator.queueDeferredMediaBatch(
                    forUserID: userID,
                    conversationID: conversationID,
                    expectedRecipientUserID: peerID,
                    title: "ExampleContact",
                    batch: batch,
                    clientMessageID: clientMessageID,
                    commitAdmission: staleLease
                )
            }
        }
        try await blobs.waitUntilValidationStarted()

        gate.quarantine()
        gate.restore(forAccountID: userID)
        let replacementLease = try XCTUnwrap(gate.lease(forAccountID: userID))
        XCTAssertNotEqual(staleLease, replacementLease)
        await blobs.releaseValidation()

        do {
            _ = try await queued.value
            XCTFail("A suspended media batch must not commit into a replacement login lifetime")
        } catch is CancellationError {
            // Expected: validation resumed only after the exact store lease was invalidated.
        }
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
        XCTAssertEqual(snapshot.conversations.map(\.id), [conversationID])
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

    func testSyncSkipsStructuredConversationNotFoundAndAdvancesCursor() async throws {
        let fixture = try await makeSyncConversationLoadFixture(
            event: conversationUpdatedSyncEvent(),
            conversationBehavior: .structuredNotFound
        )

        let result = try await fixture.coordinator.sync(forUserID: fixture.userID)

        XCTAssertEqual(result.appliedTransitions, 1)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, fixture.nextCursor)
        XCTAssertTrue(snapshot.conversations.isEmpty)
        let requestCount = await fixture.transport.conversationRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSyncMalformedConversationDTOPropagatesWithoutAdvancingCursor() async throws {
        let event = conversationUpdatedSyncEvent()
        let fixture = try await makeSyncConversationLoadFixture(
            event: event,
            conversationBehavior: .response(syncConversationDTO(type: "channel"))
        )

        do {
            _ = try await fixture.coordinator.sync(forUserID: fixture.userID)
            XCTFail("An unsupported conversation projection must retain the sync cursor")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .invalidConversation)
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertNil(snapshot.secureMessaging?.syncCursor)
        XCTAssertTrue(snapshot.conversations.isEmpty)
    }

    func testSyncConversationTransport503PropagatesWithoutAdvancingCursor() async throws {
        let fixture = try await makeSyncConversationLoadFixture(
            event: conversationUpdatedSyncEvent(),
            conversationBehavior: .temporaryUnavailable
        )

        do {
            _ = try await fixture.coordinator.sync(forUserID: fixture.userID)
            XCTFail("A temporary conversation load failure must retain the sync cursor")
        } catch let error as APIErrorPayload {
            XCTAssertEqual(error.code, "MESSAGING_TEMPORARILY_UNAVAILABLE")
            XCTAssertEqual(error.httpStatus, 503)
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertNil(snapshot.secureMessaging?.syncCursor)
    }

    func testEncryptedMessageFailureIsDurablyQuarantinedBeforeCursorAdvances() async throws {
        let fixture = try await makeSyncConversationLoadFixture(
            event: encryptedMessageCreatedSyncEventForQuarantine(),
            conversationBehavior: .temporaryUnavailable
        )

        for expectedAttempt in 1...SecureMessagingSyncQuarantinePolicy.attemptsBeforeCursorRelease {
            do {
                _ = try await fixture.coordinator.sync(forUserID: fixture.userID)
                XCTFail("the bounded ordinary-cursor attempt must surface its transport failure")
            } catch let error as APIErrorPayload {
                XCTAssertEqual(error.httpStatus, 503)
            }
            let attempted = await fixture.store.snapshot()
            XCTAssertNil(attempted.secureMessaging?.syncCursor)
            let retained = try XCTUnwrap(
                attempted.secureMessaging?.quarantinedSyncEvents.first
            )
            XCTAssertEqual(retained.eventID, "106")
            XCTAssertEqual(retained.attemptCount, expectedAttempt)
            XCTAssertEqual(retained.failureCategory, .conversation)
            XCTAssertEqual(retained.event.data?.envelope?.ciphertext, "AA==")
        }

        let reopened = SecureLocalStore(
            stateURL: temporaryDirectory.appendingPathComponent("state.secure"),
            keyData: Data(repeating: 0x91, count: 32)
        )
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.secureMessaging?.quarantinedSyncEvents.count, 1)
        XCTAssertEqual(
            restored.secureMessaging?.quarantinedSyncEvents.first?.event.data?
                .envelope?.ciphertext,
            "AA=="
        )

        let advanced = try await fixture.coordinator.sync(forUserID: fixture.userID)
        XCTAssertEqual(advanced.pages, 1)
        XCTAssertEqual(advanced.receivedMessages, 0)
        let final = await fixture.store.snapshot()
        XCTAssertEqual(final.secureMessaging?.syncCursor, fixture.nextCursor)
        XCTAssertEqual(final.secureMessaging?.quarantinedSyncEvents.count, 1)
        let conversationRequests = await fixture.transport.conversationRequestCount()
        XCTAssertEqual(conversationRequests, 3)
    }

    func testSyncUnstructuredConversation404PropagatesWithoutAdvancingCursor() async throws {
        let fixture = try await makeSyncConversationLoadFixture(
            event: conversationUpdatedSyncEvent(),
            conversationBehavior: .unstructuredNotFound
        )

        do {
            _ = try await fixture.coordinator.sync(forUserID: fixture.userID)
            XCTFail("An unstructured 404 must not be mistaken for inactive membership")
        } catch APIClientError.httpResponse(let status, let retryAfter) {
            XCTAssertEqual(status, 404)
            XCTAssertNil(retryAfter)
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertNil(snapshot.secureMessaging?.syncCursor)
    }

    func testSyncRejectsMismatchedConversationEventResourceWithoutLoading() async throws {
        var event = conversationUpdatedSyncEvent()
        event["resource_type"] = "message"
        let fixture = try await makeSyncConversationLoadFixture(
            event: event,
            conversationBehavior: .unexpected
        )

        do {
            _ = try await fixture.coordinator.sync(forUserID: fixture.userID)
            XCTFail("A conversation event must bind its resource to the conversation")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .invalidServerResponse)
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertNil(snapshot.secureMessaging?.syncCursor)
        let requestCount = await fixture.transport.conversationRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testSyncSkipsMessageForStructuredMissingConversation() async throws {
        let fixture = try await makeSyncConversationLoadFixture(
            event: messageCreatedSyncEvent(),
            conversationBehavior: .structuredNotFound
        )

        let result = try await fixture.coordinator.sync(forUserID: fixture.userID)

        XCTAssertEqual(result.receivedMessages, 0)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, fixture.nextCursor)
        XCTAssertTrue(snapshot.conversations.isEmpty)
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.secureMessaging?.pendingDeliveryAcknowledgementIDs.isEmpty == true)
    }

    func testOlderRenameResponseCannotOverwriteNewerSyncedGroupProjection() async throws {
        let fixture = try await makeGroupRenameFixture(fails: false)
        let rename = Task {
            try await fixture.coordinator.renameGroupConversation(
                forUserID: fixture.userID,
                conversationID: fixture.conversationID,
                title: "Requested rename"
            )
        }
        try await fixture.transport.waitUntilRenameStarted()

        let newer = Conversation(
            id: fixture.conversationID,
            title: "Newer synced title",
            participantUserIds: [fixture.userID, fixture.peerUserID, fixture.thirdUserID],
            unreadCount: 7,
            updatedAt: fixture.responseUpdatedAt.addingTimeInterval(60),
            conversationType: SecureMessagingWire.groupConversationType,
            groupMemberRoles: [
                fixture.userID: .owner,
                fixture.peerUserID: .admin,
                fixture.thirdUserID: .member,
            ]
        )
        try await fixture.store.update { state in
            state.conversations = [newer]
            state.groupProjectionUpdatedAt = [
                fixture.conversationID: newer.updatedAt,
            ]
        }

        await fixture.transport.releaseRename()
        let committed = try await rename.value

        XCTAssertEqual(committed, newer)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.conversations, [newer])
    }

    func testCurrentRenameResponseAtomicallyReplacesGroupProjection() async throws {
        let fixture = try await makeGroupRenameFixture(fails: false)
        let rename = Task {
            try await fixture.coordinator.renameGroupConversation(
                forUserID: fixture.userID,
                conversationID: fixture.conversationID,
                title: "Requested rename"
            )
        }
        try await fixture.transport.waitUntilRenameStarted()
        await fixture.transport.releaseRename()

        let committed = try await rename.value
        XCTAssertEqual(committed.title, "Requested rename")
        XCTAssertEqual(committed.participantUserIds, [fixture.userID, fixture.peerUserID])
        XCTAssertEqual(committed.unreadCount, fixture.initialConversation.unreadCount)
        XCTAssertEqual(committed.updatedAt, fixture.responseUpdatedAt)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.conversations, [committed])
        XCTAssertEqual(
            snapshot.groupProjectionUpdatedAt?[fixture.conversationID],
            fixture.responseUpdatedAt
        )
    }

    func testFailedRenameDoesNotOptimisticallyChangeGroupProjection() async throws {
        let fixture = try await makeGroupRenameFixture(fails: true)
        let rename = Task {
            try await fixture.coordinator.renameGroupConversation(
                forUserID: fixture.userID,
                conversationID: fixture.conversationID,
                title: "Requested rename"
            )
        }
        try await fixture.transport.waitUntilRenameStarted()

        var snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.conversations, [fixture.initialConversation])

        await fixture.transport.releaseRename()
        do {
            _ = try await rename.value
            XCTFail("A failed mutation must not commit its requested title")
        } catch is SuspendedGroupRenameTransport.Failure {
            // Expected.
        }

        snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.conversations, [fixture.initialConversation])
        XCTAssertNil(snapshot.groupProjectionUpdatedAt)
    }

    func testOlderSyncProjectionCannotOverwriteNewerGroupMutation() async throws {
        let newerUpdatedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-24T12:01:00Z")
        )
        let newer = Conversation(
            id: syncConversationID,
            title: "Newer mutation title",
            participantUserIds: [syncUserID],
            unreadCount: 4,
            updatedAt: newerUpdatedAt,
            conversationType: SecureMessagingWire.groupConversationType,
            groupMemberRoles: [syncUserID: .owner]
        )
        let fixture = try await makeSyncConversationLoadFixture(
            event: conversationUpdatedSyncEvent(),
            conversationBehavior: .response(syncConversationDTO(
                type: SecureMessagingWire.groupConversationType,
                title: "Older synced title"
            )),
            localConversations: [newer],
            groupProjectionUpdatedAt: [syncConversationID: newerUpdatedAt]
        )

        _ = try await fixture.coordinator.sync(forUserID: fixture.userID)

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.conversations, [newer])
        XCTAssertEqual(
            snapshot.groupProjectionUpdatedAt?[syncConversationID],
            newerUpdatedAt
        )
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, fixture.nextCursor)
    }

    func testSyncSelfMemberAddedMaterializesGroup() async throws {
        let fixture = try await makeSyncConversationLoadFixture(
            event: memberAddedSyncEvent(subjectUserID: syncUserID),
            conversationBehavior: .response(syncConversationDTO(
                type: SecureMessagingWire.groupConversationType
            ))
        )

        _ = try await fixture.coordinator.sync(forUserID: fixture.userID)

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, fixture.nextCursor)
        XCTAssertEqual(snapshot.conversations.map(\.id), [fixture.conversationID])
        XCTAssertTrue(snapshot.conversations.first?.isGroup == true)
        XCTAssertEqual(snapshot.messages.count, 1)
        let requestCount = await fixture.transport.conversationRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSyncMissingSelfMemberAddDoesNotReenableRetainedGroup() async throws {
        let retained = Conversation(
            id: syncConversationID,
            title: "Weekend Trip",
            participantUserIds: [
                syncPeerUserID,
                "10000000-0000-4000-8000-000000000103",
            ],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_777_200_000),
            conversationType: SecureMessagingWire.groupConversationType
        )
        let fixture = try await makeSyncConversationLoadFixture(
            event: memberAddedSyncEvent(subjectUserID: syncUserID),
            conversationBehavior: .structuredNotFound,
            localConversations: [retained]
        )

        _ = try await fixture.coordinator.sync(forUserID: fixture.userID)

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, fixture.nextCursor)
        XCTAssertEqual(snapshot.conversations, [retained])
        XCTAssertTrue(snapshot.messages.isEmpty)
        let requestCount = await fixture.transport.conversationRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSyncNonSelfMemberAddedDoesNotResurrectMissingLocalGroup() async throws {
        let fixture = try await makeSyncConversationLoadFixture(
            event: memberAddedSyncEvent(subjectUserID: syncPeerUserID),
            conversationBehavior: .unexpected
        )

        _ = try await fixture.coordinator.sync(forUserID: fixture.userID)

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, fixture.nextCursor)
        XCTAssertTrue(snapshot.conversations.isEmpty)
        XCTAssertTrue(snapshot.messages.isEmpty)
        let requestCount = await fixture.transport.conversationRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testMembershipRoleChangeRefreshesAuthoritativeGroupProjection() async throws {
        let retained = Conversation(
            id: syncConversationID,
            title: "Old title",
            participantUserIds: [syncUserID, syncPeerUserID],
            unreadCount: 4,
            updatedAt: Date(timeIntervalSince1970: 1_777_200_000),
            conversationType: SecureMessagingWire.groupConversationType,
            groupMemberRoles: [syncUserID: .owner, syncPeerUserID: .member]
        )
        let fixture = try await makeSyncConversationLoadFixture(
            event: memberRoleChangedSyncEvent(subjectUserID: syncPeerUserID, role: "admin"),
            conversationBehavior: .response(syncConversationDTO(
                type: SecureMessagingWire.groupConversationType,
                title: "Current title",
                peerRole: "admin"
            )),
            localConversations: [retained]
        )

        _ = try await fixture.coordinator.sync(forUserID: fixture.userID)

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, fixture.nextCursor)
        XCTAssertEqual(snapshot.conversations.first?.title, "Current title")
        XCTAssertEqual(snapshot.conversations.first?.unreadCount, 4)
        XCTAssertEqual(snapshot.conversations.first?.updatedAt, retained.updatedAt)
        XCTAssertEqual(snapshot.conversations.first?.groupRole(for: syncPeerUserID), .admin)
        XCTAssertEqual(
            snapshot.groupProjectionUpdatedAt?[syncConversationID],
            ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z")
        )
        XCTAssertTrue(snapshot.messages.isEmpty)
        let roleChangeRequestCount = await fixture.transport.conversationRequestCount()
        XCTAssertEqual(roleChangeRequestCount, 1)
    }

    func testDelayedSelfAddThenPromotionUsesCurrentAuthoritativeRole() async throws {
        let fixture = try await makeSyncConversationLoadFixture(
            events: [
                memberAddedSyncEvent(
                    subjectUserID: syncUserID,
                    role: "member",
                    eventID: "106"
                ),
                memberRoleChangedSyncEvent(
                    subjectUserID: syncUserID,
                    role: "admin",
                    eventID: "107"
                ),
            ],
            conversationBehavior: .response(syncConversationDTO(
                type: SecureMessagingWire.groupConversationType,
                localRole: "admin"
            ))
        )

        _ = try await fixture.coordinator.sync(forUserID: fixture.userID)

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.conversations.first?.groupRole(for: syncUserID), .admin)
        XCTAssertEqual(snapshot.messages.count, 1)
        let requestCount = await fixture.transport.conversationRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testDelayedRoleChangeThenRemovalKeepsLatestServerRoster() async throws {
        let retained = Conversation(
            id: syncConversationID,
            title: "Old title",
            participantUserIds: [syncUserID, syncPeerUserID],
            unreadCount: 2,
            updatedAt: Date(timeIntervalSince1970: 1_777_200_000),
            conversationType: SecureMessagingWire.groupConversationType,
            groupMemberRoles: [syncUserID: .owner, syncPeerUserID: .member]
        )
        let fixture = try await makeSyncConversationLoadFixture(
            events: [
                memberRoleChangedSyncEvent(
                    subjectUserID: syncPeerUserID,
                    role: "admin",
                    eventID: "108"
                ),
                memberRemovedSyncEvent(subjectUserID: syncPeerUserID, eventID: "109"),
            ],
            conversationBehavior: .response(syncConversationDTO(
                type: SecureMessagingWire.groupConversationType,
                title: "Current title",
                includePeer: false
            )),
            localConversations: [retained]
        )

        _ = try await fixture.coordinator.sync(forUserID: fixture.userID)

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.conversations.first?.title, "Current title")
        XCTAssertEqual(snapshot.conversations.first?.participantUserIds, [syncUserID])
        XCTAssertNil(snapshot.conversations.first?.groupRole(for: syncPeerUserID))
        XCTAssertEqual(snapshot.conversations.first?.unreadCount, 2)
        XCTAssertEqual(snapshot.messages.count, 1)
    }

    func testDelayedRoleChangesConvergeToCurrentServerRole() async throws {
        let retained = Conversation(
            id: syncConversationID,
            title: "Weekend Trip",
            participantUserIds: [syncUserID, syncPeerUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_777_200_000),
            conversationType: SecureMessagingWire.groupConversationType,
            groupMemberRoles: [syncUserID: .owner, syncPeerUserID: .member]
        )
        let fixture = try await makeSyncConversationLoadFixture(
            events: [
                memberRoleChangedSyncEvent(
                    subjectUserID: syncPeerUserID,
                    role: "admin",
                    eventID: "110"
                ),
                memberRoleChangedSyncEvent(
                    subjectUserID: syncPeerUserID,
                    role: "member",
                    eventID: "111"
                ),
            ],
            conversationBehavior: .response(syncConversationDTO(
                type: SecureMessagingWire.groupConversationType,
                peerRole: "member"
            )),
            localConversations: [retained]
        )

        _ = try await fixture.coordinator.sync(forUserID: fixture.userID)

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.conversations.first?.groupRole(for: syncPeerUserID), .member)
        let requestCount = await fixture.transport.conversationRequestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testMembershipRemovalUpdatesRosterWithoutGroupRolloutAdmission() async throws {
        let retained = Conversation(
            id: syncConversationID,
            title: "Weekend Trip",
            participantUserIds: [syncUserID, syncPeerUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_777_200_000),
            conversationType: SecureMessagingWire.groupConversationType,
            groupMemberRoles: [syncUserID: .owner, syncPeerUserID: .member]
        )
        let fixture = try await makeSyncConversationLoadFixture(
            event: memberRemovedSyncEvent(subjectUserID: syncPeerUserID),
            conversationBehavior: .unexpected,
            localConversations: [retained]
        )

        _ = try await fixture.coordinator.sync(forUserID: fixture.userID)

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.conversations.first?.participantUserIds, [syncUserID])
        XCTAssertNil(snapshot.conversations.first?.groupRole(for: syncPeerUserID))
        XCTAssertEqual(snapshot.messages.count, 1)
        let removalRequestCount = await fixture.transport.conversationRequestCount()
        XCTAssertEqual(removalRequestCount, 0)
    }

    func testRemoteSelfRemovalAbandonsQueuedGroupCommandsAndClearsFanout() async throws {
        let retained = Conversation(
            id: syncConversationID,
            title: "Weekend Trip",
            participantUserIds: [syncUserID, syncPeerUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_777_200_000),
            conversationType: SecureMessagingWire.groupConversationType,
            groupMemberRoles: [syncUserID: .owner, syncPeerUserID: .member]
        )
        let fixture = try await makeSyncConversationLoadFixture(
            event: memberRemovedSyncEvent(subjectUserID: syncUserID),
            conversationBehavior: .unexpected,
            localConversations: [retained]
        )
        let messageID = UUID(uuidString: "80000000-0000-4000-8000-000000000101")!
        let createdAt = Date(timeIntervalSince1970: 1_777_200_001)
        let fanout = SecureMessagingCommittedFanout(
            clientMessageID: messageID.uuidString.lowercased(),
            conversationID: syncConversationID,
            rosterRevision: "v1:sha256:" + String(repeating: "a", count: 64),
            replyToMessageID: nil,
            rosterDevices: [],
            envelopes: []
        )
        try await fixture.store.update { state in
            state.messages = [LocalMessage(
                id: messageID,
                conversationId: syncConversationID,
                senderId: syncUserID,
                body: "Queued before removal",
                createdAt: createdAt,
                sentAt: nil,
                state: .queued,
                failureReason: nil,
                isOutgoing: true
            )]
            state.outbox = [OfflineCommand(
                id: UUID(uuidString: "90000000-0000-4000-8000-000000000101")!,
                kind: .secureMessage,
                createdAt: createdAt,
                nextAttemptAt: createdAt,
                attemptCount: 0,
                conversationId: syncConversationID,
                messageId: messageID,
                recipientUserIds: [syncPeerUserID],
                recipientName: "Weekend Trip",
                video: nil,
                expiresAt: nil,
                secureMessageFanout: fanout
            )]
        }

        _ = try await fixture.coordinator.sync(forUserID: fixture.userID)

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.conversations.first?.participantUserIds, [syncPeerUserID])
        XCTAssertTrue(snapshot.outbox.isEmpty)
        XCTAssertEqual(snapshot.messages.first?.state, .failed)
        XCTAssertEqual(
            snapshot.messages.first?.failureReason,
            "You left this group before this message was sent."
        )
    }

    func testLegacyConversationMemberEventNameDoesNotAdvanceCursor() async throws {
        var event = memberAddedSyncEvent(subjectUserID: syncPeerUserID)
        event["type"] = "conversation.member.added"
        let fixture = try await makeSyncConversationLoadFixture(
            event: event,
            conversationBehavior: .unexpected
        )

        do {
            _ = try await fixture.coordinator.sync(forUserID: fixture.userID)
            XCTFail("An obsolete membership event name must fail closed")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .unsupportedEvent("conversation.member.added"))
        }
        let snapshot = await fixture.store.snapshot()
        XCTAssertNil(snapshot.secureMessaging?.syncCursor)
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

    func testDirectMessageLocalConversationPolicyRequiresOneCanonicalTwoPartyThread() {
        let localUserID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
        let recipientUserID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"
        let thirdUserID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee5"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = Conversation(
            id: "cccccccc-cccc-4ccc-8ccc-ccccccccccc3",
            title: "Expected direct thread",
            participantUserIds: [recipientUserID, localUserID],
            unreadCount: 0,
            updatedAt: date
        )
        let twoMemberGroup = Conversation(
            id: "dddddddd-dddd-4ddd-8ddd-ddddddddddd4",
            title: "Not a direct thread",
            participantUserIds: [localUserID, recipientUserID],
            unreadCount: 0,
            updatedAt: date,
            conversationType: SecureMessagingWire.groupConversationType
        )
        let threePartyThread = Conversation(
            id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee6",
            title: "Malformed direct thread",
            participantUserIds: [localUserID, recipientUserID, thirdUserID],
            unreadCount: 0,
            updatedAt: date
        )
        let noncanonical = Conversation(
            id: "abcdefab-cdef-4abc-8def-abcdefabcde7".uppercased(),
            title: "Noncanonical thread",
            participantUserIds: [localUserID, recipientUserID],
            unreadCount: 0,
            updatedAt: date
        )
        let unknownType = Conversation(
            id: "abababab-abab-4aba-8aba-abababababab",
            title: "Unknown server thread",
            participantUserIds: [localUserID, recipientUserID],
            unreadCount: 0,
            updatedAt: date,
            conversationType: "channel"
        )

        XCTAssertEqual(
            DirectMessageLocalConversationPolicy.resolve(
                conversations: [
                    twoMemberGroup,
                    threePartyThread,
                    noncanonical,
                    expected,
                ],
                currentUserID: localUserID,
                recipientUserID: recipientUserID
            ),
            .existing(expected)
        )
        XCTAssertEqual(
            DirectMessageLocalConversationPolicy.resolve(
                conversations: [noncanonical],
                currentUserID: localUserID,
                recipientUserID: recipientUserID
            ),
            .missing
        )
        XCTAssertEqual(
            DirectMessageLocalConversationPolicy.resolve(
                conversations: [unknownType],
                currentUserID: localUserID,
                recipientUserID: recipientUserID
            ),
            .invalid,
            "An unknown explicit server type must never be downgraded to a direct chat."
        )

        let duplicate = Conversation(
            id: "ffffffff-ffff-4fff-8fff-fffffffffff8",
            title: "Duplicate direct thread",
            participantUserIds: [localUserID, recipientUserID],
            unreadCount: 0,
            updatedAt: date.addingTimeInterval(1)
        )
        XCTAssertEqual(
            DirectMessageLocalConversationPolicy.resolve(
                conversations: [expected, duplicate],
                currentUserID: localUserID,
                recipientUserID: recipientUserID
            ),
            .ambiguous
        )
    }

    func testDeferredTextRejectsUnknownExplicitConversationTypeBeforeNetworkOrWrite() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000081"
        let recipientUserID = "10000000-0000-4000-8000-000000000082"
        let conversationID = "30000000-0000-4000-8000-000000000081"
        let store = try await makeStore(userID: localUserID)
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            state.conversations = [Conversation(
                id: conversationID,
                title: "Unsupported channel",
                participantUserIds: [localUserID, recipientUserID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_756_800_000),
                conversationType: "channel"
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
            _ = try await coordinator.queueDeferredText(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "Unsupported channel",
                text: "Must remain local and unqueued"
            )
            XCTFail("An unknown server conversation type must fail closed")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .invalidConversation)
        }

        let networkCallCount = await transport.networkCallCount()
        XCTAssertEqual(networkCallCount, 0)
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
    }

    func testReplacementAccountActivationSupersedesOldFlightAndKeepsOutboxRunnable() async throws {
        let oldUserID = "10000000-0000-4000-8000-000000000091"
        let replacementUserID = "10000000-0000-4000-8000-000000000092"
        let oldAccountGeneration = UUID(uuidString: "60000000-0000-4000-8000-000000000091")!
        let replacementAccountGeneration = UUID(
            uuidString: "60000000-0000-4000-8000-000000000092"
        )!
        let oldSessionID = "70000000-0000-4000-8000-000000000091"
        let replacementSessionID = "70000000-0000-4000-8000-000000000092"
        let store = try await makeStore(userID: oldUserID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let replacementStatus = enrolledStatus(bundle: provisioned.bundle)
        let replacementBinding = try SecureMessagingMapper.enrollmentBinding(
            from: replacementStatus,
            userID: replacementUserID
        )
        let replacementCrypto = try await engine.bindEnrollment(
            replacementBinding,
            to: provisioned.state
        )
        let transport = SupersededActivationTransport(status: replacementStatus)
        let coordinator = SecureMessagingCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1
        )

        let oldActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: oldAccountGeneration,
                sessionID: oldSessionID
            ) {
                try await coordinator.activate(forUserID: oldUserID)
            }
        }
        try await transport.waitUntilFirstStatusStarted()

        let queued = OfflineCommand(
            id: UUID(uuidString: "90000000-0000-4000-8000-000000000092")!,
            kind: .secureMessage,
            createdAt: Date(timeIntervalSince1970: 1_756_800_000),
            nextAttemptAt: Date(timeIntervalSince1970: 1_756_800_000),
            attemptCount: 0,
            conversationId: "30000000-0000-4000-8000-000000000092",
            messageId: UUID(uuidString: "80000000-0000-4000-8000-000000000092")!,
            recipientUserIds: ["10000000-0000-4000-8000-000000000093"],
            recipientName: "Replacement recipient",
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil
        )
        var replacement = PersistedState.empty
        replacement.profile = UserProfile(
            id: replacementUserID,
            name: "Replacement user",
            email: nil,
            phone: "+256700000092",
            tag: nil,
            kycStatus: nil,
            paymentPinSet: nil,
            mfaEnabled: nil,
            profileSetupRequired: false
        )
        replacement.communicationOwnerUserID = replacementUserID
        replacement.secureMessaging = replacementCrypto
        replacement.outbox = [queued]
        try await store.replace(replacement)

        let replacementActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: replacementAccountGeneration,
                sessionID: replacementSessionID
            ) {
                try await coordinator.activate(forUserID: replacementUserID)
            }
        }
        try await transport.waitUntilSecondStatusStarted()

        // Let the cancelled former flight unwind while replacement activation is still live.
        // Its stale cleanup and stale result must neither clear nor escape across generation 2.
        await transport.releaseFirstStatus()
        do {
            _ = try await oldActivation.value
            XCTFail("The superseded account must not finish activation")
        } catch is CancellationError {
            // Expected: AppModel treats cancellation as an obsolete flush, not a session error.
        }

        // A second replacement-account caller must still join the live generation-2 flight. If
        // stale generation-1 cleanup cleared it, this call would incorrectly issue status #3.
        let coalescedReplacementActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: replacementAccountGeneration,
                sessionID: replacementSessionID
            ) {
                try await coordinator.activate(forUserID: replacementUserID)
            }
        }
        for _ in 0..<10 { await Task.yield() }
        let requestsWhileReplacementIsSuspended = await transport.statusRequestCount()
        XCTAssertEqual(requestsWhileReplacementIsSuspended, 2)

        await transport.releaseSecondStatus()
        let activated = try await replacementActivation.value
        let coalesced = try await coalescedReplacementActivation.value
        XCTAssertEqual(activated.enrollment?.userID, replacementUserID)
        XCTAssertEqual(coalesced.enrollment?.userID, replacementUserID)
        let live = await store.snapshot()
        XCTAssertEqual(live.profile?.id, replacementUserID)
        XCTAssertEqual(live.outbox.first?.failureDisposition, nil)
        XCTAssertEqual(
            OutboxPolicy.readyCommands(live.outbox, at: Date()).map(\.id),
            [queued.id],
            "The active replacement session must retain an automatically drainable command."
        )
        let statusRequestCount = await transport.statusRequestCount()
        XCTAssertEqual(statusRequestCount, 2)
        let finalSnapshot = await store.snapshot()
        XCTAssertEqual(finalSnapshot.profile?.id, replacementUserID)
    }

    func testABAAccountReplacementKeepsFinalActivationFlightOwnedByItsExactLifetime() async throws {
        let userA = "10000000-0000-4000-8000-000000000081"
        let userB = "10000000-0000-4000-8000-000000000082"
        let firstGeneration = UUID(uuidString: "60000000-0000-4000-8000-000000000081")!
        let middleGeneration = UUID(uuidString: "60000000-0000-4000-8000-000000000082")!
        let finalGeneration = UUID(uuidString: "60000000-0000-4000-8000-000000000083")!
        let firstSession = "70000000-0000-4000-8000-000000000081"
        let middleSession = "70000000-0000-4000-8000-000000000082"
        let finalSession = "70000000-0000-4000-8000-000000000083"
        let store = try await makeStore(userID: userA)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let status = enrolledStatus(bundle: provisioned.bundle)
        let bindingA = try SecureMessagingMapper.enrollmentBinding(from: status, userID: userA)
        let bindingB = try SecureMessagingMapper.enrollmentBinding(from: status, userID: userB)
        let cryptoA = try await engine.bindEnrollment(bindingA, to: provisioned.state)
        let cryptoB = try await engine.bindEnrollment(bindingB, to: provisioned.state)
        try await store.update { $0.secureMessaging = cryptoA }
        let transport = SupersededActivationTransport(
            firstStatus: status,
            replacementStatus: status,
            finalStatus: status
        )
        let coordinator = SecureMessagingCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1
        )

        let firstActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: firstGeneration,
                sessionID: firstSession
            ) {
                try await coordinator.activate(forUserID: userA)
            }
        }
        try await transport.waitUntilFirstStatusStarted()

        var middleState = PersistedState.empty
        middleState.profile = UserProfile(
            id: userB,
            name: "Middle user",
            email: nil,
            phone: "+256700000082",
            tag: nil,
            kycStatus: nil,
            paymentPinSet: nil,
            mfaEnabled: nil,
            profileSetupRequired: false
        )
        middleState.communicationOwnerUserID = userB
        middleState.secureMessaging = cryptoB
        try await store.replace(middleState)
        let middleActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: middleGeneration,
                sessionID: middleSession
            ) {
                try await coordinator.activate(forUserID: userB)
            }
        }
        try await transport.waitUntilSecondStatusStarted()

        var finalState = PersistedState.empty
        finalState.profile = UserProfile(
            id: userA,
            name: "Final user A",
            email: nil,
            phone: "+256700000081",
            tag: nil,
            kycStatus: nil,
            paymentPinSet: nil,
            mfaEnabled: nil,
            profileSetupRequired: false
        )
        finalState.communicationOwnerUserID = userA
        finalState.secureMessaging = cryptoA
        try await store.replace(finalState)
        let finalActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: finalGeneration,
                sessionID: finalSession
            ) {
                try await coordinator.activate(forUserID: userA)
            }
        }
        try await transport.waitUntilThirdStatusStarted()

        await transport.releaseFirstStatus()
        await transport.releaseSecondStatus()
        for activation in [firstActivation, middleActivation] {
            do {
                _ = try await activation.value
                XCTFail("A superseded A→B flight must not publish into the final A lifetime")
            } catch is CancellationError {
                // Both obsolete generations normalize their result to cancellation.
            }
        }

        let coalescedFinalActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: finalGeneration,
                sessionID: finalSession
            ) {
                try await coordinator.activate(forUserID: userA)
            }
        }
        for _ in 0..<10 { await Task.yield() }
        let requestCountBeforeFinalRelease = await transport.statusRequestCount()
        XCTAssertEqual(requestCountBeforeFinalRelease, 3)

        await transport.releaseThirdStatus()
        let activated = try await finalActivation.value
        let coalesced = try await coalescedFinalActivation.value
        XCTAssertEqual(activated.enrollment, bindingA)
        XCTAssertEqual(coalesced.enrollment, bindingA)
        let live = await store.snapshot()
        XCTAssertEqual(live.profile?.id, userA)
        XCTAssertEqual(live.secureMessaging?.enrollment, bindingA)
    }

    func testSameUserReplacementSessionSupersedesStaleSuccessfulActivation() async throws {
        let userID = "10000000-0000-4000-8000-000000000094"
        // Hold the account generation fixed so this regression independently proves that the
        // authenticated server session participates in the single-flight identity.
        let accountGeneration = UUID(uuidString: "60000000-0000-4000-8000-000000000094")!
        let oldSessionID = "70000000-0000-4000-8000-000000000094"
        let replacementSessionID = "70000000-0000-4000-8000-000000000095"
        let store = try await makeStore(userID: userID)
        let engine = SecureMessagingCryptoEngine()

        let oldProvisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let oldStatus = enrolledStatus(bundle: oldProvisioned.bundle)
        let oldBinding = try SecureMessagingMapper.enrollmentBinding(
            from: oldStatus,
            userID: userID
        )
        let oldCrypto = try await engine.bindEnrollment(
            oldBinding,
            to: oldProvisioned.state
        )
        try await store.update { $0.secureMessaging = oldCrypto }

        let replacementProvisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let replacementStatus = enrolledStatus(bundle: replacementProvisioned.bundle)
        let replacementBinding = try SecureMessagingMapper.enrollmentBinding(
            from: replacementStatus,
            userID: userID
        )
        let replacementCrypto = try await engine.bindEnrollment(
            replacementBinding,
            to: replacementProvisioned.state
        )
        let transport = SupersededActivationTransport(
            firstStatus: oldStatus,
            replacementStatus: replacementStatus
        )
        let coordinator = SecureMessagingCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1
        )

        let staleActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: accountGeneration,
                sessionID: oldSessionID
            ) {
                try await coordinator.activate(forUserID: userID)
            }
        }
        try await transport.waitUntilFirstStatusStarted()

        let queued = OfflineCommand(
            id: UUID(uuidString: "90000000-0000-4000-8000-000000000094")!,
            kind: .secureMessage,
            createdAt: Date(timeIntervalSince1970: 1_756_800_000),
            nextAttemptAt: Date(timeIntervalSince1970: 1_756_800_000),
            attemptCount: 0,
            conversationId: "30000000-0000-4000-8000-000000000094",
            messageId: UUID(uuidString: "80000000-0000-4000-8000-000000000094")!,
            recipientUserIds: ["10000000-0000-4000-8000-000000000096"],
            recipientName: "Replacement recipient",
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil
        )
        try await store.update {
            $0.secureMessaging = replacementCrypto
            $0.outbox = [queued]
        }

        let replacementActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: accountGeneration,
                sessionID: replacementSessionID
            ) {
                try await coordinator.activate(forUserID: userID)
            }
        }
        try await transport.waitUntilSecondStatusStarted()
        await transport.releaseFirstStatus()
        do {
            _ = try await staleActivation.value
            XCTFail("A successful response from the replaced session must stay cancelled")
        } catch is CancellationError {
            // The replacement scope owns the slot and the same-user store now.
        }

        await transport.releaseSecondStatus()
        let activated = try await replacementActivation.value

        XCTAssertEqual(activated.enrollment, replacementBinding)
        let statusRequestCount = await transport.statusRequestCount()
        XCTAssertEqual(statusRequestCount, 2)
        let live = await store.snapshot()
        XCTAssertEqual(live.secureMessaging?.enrollment, replacementBinding)
        XCTAssertEqual(live.outbox.map(\.id), [queued.id])
        XCTAssertEqual(
            OutboxPolicy.readyCommands(live.outbox, at: Date()).map(\.id),
            [queued.id]
        )
    }

    func testSameUserReplacementGenerationDoesNotInheritStaleActivationError() async throws {
        let userID = "10000000-0000-4000-8000-000000000097"
        let oldGeneration = UUID(uuidString: "60000000-0000-4000-8000-000000000097")!
        let replacementGeneration = UUID(
            uuidString: "60000000-0000-4000-8000-000000000098"
        )!
        // Deliberately retain the same server session id: account generation must independently
        // prevent a logout/recovery boundary from inheriting the older flight's terminal error.
        let sessionID = "70000000-0000-4000-8000-000000000097"
        let store = try await makeStore(userID: userID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let status = enrolledStatus(bundle: provisioned.bundle)
        let binding = try SecureMessagingMapper.enrollmentBinding(from: status, userID: userID)
        let crypto = try await engine.bindEnrollment(binding, to: provisioned.state)
        try await store.update { $0.secureMessaging = crypto }
        let transport = SupersededActivationTransport(
            firstStatus: status,
            replacementStatus: status,
            firstRequestFails: true
        )
        let coordinator = SecureMessagingCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1
        )

        let staleActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: oldGeneration,
                sessionID: sessionID
            ) {
                try await coordinator.activate(forUserID: userID)
            }
        }
        try await transport.waitUntilFirstStatusStarted()

        let replacementActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: replacementGeneration,
                sessionID: sessionID
            ) {
                try await coordinator.activate(forUserID: userID)
            }
        }
        try await transport.waitUntilSecondStatusStarted()
        await transport.releaseFirstStatus()
        do {
            _ = try await staleActivation.value
            XCTFail("The replaced account generation must not surface its stale error")
        } catch is CancellationError {
            // Superseded errors are normalized to cancellation for the obsolete caller.
        }

        await transport.releaseSecondStatus()
        let activated = try await replacementActivation.value

        XCTAssertEqual(activated.enrollment, binding)
        let statusRequestCount = await transport.statusRequestCount()
        XCTAssertEqual(statusRequestCount, 2)
        let live = await store.snapshot()
        XCTAssertEqual(live.secureMessaging?.enrollment, binding)
    }

    func testSameUserReplacementSessionSupersedesStaleSyncFlight() async throws {
        let userID = "10000000-0000-4000-8000-000000000090"
        let accountGeneration = UUID(uuidString: "60000000-0000-4000-8000-000000000090")!
        let oldSessionID = "70000000-0000-4000-8000-000000000090"
        let replacementSessionID = "70000000-0000-4000-8000-000000000089"
        let store = try await makeStore(userID: userID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let status = enrolledStatus(bundle: provisioned.bundle)
        let binding = try SecureMessagingMapper.enrollmentBinding(from: status, userID: userID)
        let crypto = try await engine.bindEnrollment(binding, to: provisioned.state)
        try await store.update { $0.secureMessaging = crypto }
        let transport = SupersededActivationTransport(status: status)
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1
        )

        let staleSync = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: accountGeneration,
                sessionID: oldSessionID
            ) {
                try await coordinator.sync(forUserID: userID)
            }
        }
        try await transport.waitUntilFirstStatusStarted()

        let replacementSync = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: accountGeneration,
                sessionID: replacementSessionID
            ) {
                try await coordinator.sync(forUserID: userID)
            }
        }
        try await transport.waitUntilSecondStatusStarted()
        await transport.releaseFirstStatus()
        do {
            _ = try await staleSync.value
            XCTFail("The replacement session must not join the stale same-user sync")
        } catch is CancellationError {
            // The obsolete sync is cancelled without affecting the replacement flight.
        }

        await transport.releaseSecondStatus()
        let result = try await replacementSync.value
        XCTAssertEqual(result.pages, 1)
        let statusRequestCount = await transport.statusRequestCount()
        XCTAssertEqual(statusRequestCount, 2)
        let live = await store.snapshot()
        XCTAssertEqual(live.secureMessaging?.enrollment, binding)
    }

    func testProcessActivationFailsClosedWithoutCompleteAuthenticatedScope() async throws {
        let userID = "10000000-0000-4000-8000-000000000099"
        let store = try await makeStore(userID: userID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let status = enrolledStatus(bundle: provisioned.bundle)
        let transport = SupersededActivationTransport(status: status)
        let coordinator = SecureMessagingCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1,
            requiresAuthenticatedActivationScope: true
        )

        do {
            _ = try await coordinator.activate(forUserID: userID)
            XCTFail("The process-wide coordinator must reject an unbound activation")
        } catch let error as SecureMessagingActivationError {
            XCTAssertEqual(error, .accountChanged)
        }
        do {
            _ = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: UUID(
                    uuidString: "60000000-0000-4000-8000-000000000099"
                )!,
                sessionID: "70000000-0000-4000-8000-000000000099"
            ) {
                try await coordinator.activate(forUserID: userID)
            }
            XCTFail("A process-wide activation scope without a protected-store lease must fail")
        } catch let error as SecureMessagingActivationError {
            XCTAssertEqual(error, .accountChanged)
        }

        let exchange = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1,
            requiresAuthenticatedActivationScope: true
        )
        do {
            _ = try await exchange.sync(forUserID: userID)
            XCTFail("The process-wide exchange sync must reject an unbound operation")
        } catch let error as SecureMessagingActivationError {
            XCTAssertEqual(error, .accountChanged)
        }
        do {
            _ = try await exchange.prepareDeferredMessage(
                commandID: UUID(),
                forUserID: userID
            )
            XCTFail("The process-wide outbox preparation must reject an unbound operation")
        } catch let error as SecureMessagingActivationError {
            XCTAssertEqual(error, .accountChanged)
        }
        do {
            _ = try await exchange.sendQueuedMessage(
                commandID: UUID(),
                forUserID: userID
            )
            XCTFail("The process-wide outbox send must reject an unbound operation")
        } catch let error as SecureMessagingActivationError {
            XCTAssertEqual(error, .accountChanged)
        }

        let statusRequestCount = await transport.statusRequestCount()
        XCTAssertEqual(statusRequestCount, 0)
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

    func testExistingDirectTextAndMediaEnterOutboxBeforeEnrollmentWithoutNetwork() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000015"
        let recipientUserID = "10000000-0000-4000-8000-000000000016"
        let conversationID = "30000000-0000-4000-8000-000000000015"
        let store = try await makeStore(userID: localUserID)
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            state.secureMessaging = nil
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
        let queuedSnapshot = await store.snapshot()
        let resolution = DirectMessageLocalConversationPolicy.resolve(
            conversations: queuedSnapshot.conversations,
            currentUserID: localUserID,
            recipientUserID: recipientUserID
        )
        guard case .existing(let existingConversation) = resolution else {
            XCTFail("The canonical two-party conversation must be selected for local queueing")
            return
        }

        let text = try await coordinator.queueDeferredText(
            forUserID: localUserID,
            conversationID: existingConversation.id,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            text: "held until keys recover"
        )
        let mediaBytes = Data(repeating: 0x7a, count: 32_000)
        let media = try await coordinator.queueDeferredImage(
            forUserID: localUserID,
            conversationID: existingConversation.id,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            mediaData: mediaBytes,
            mediaType: "audio/mp4",
            caption: nil
        )

        let queueNetworkCallCount = await transport.networkCallCount()
        XCTAssertEqual(
            queueNetworkCallCount,
            0,
            "Local queueing must not activate E2EE or touch messaging transport before flush"
        )
        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.secureMessaging)
        XCTAssertEqual(snapshot.messages.map(\.id), [text.clientMessageID, media.clientMessageID])
        XCTAssertTrue(snapshot.messages.allSatisfy { $0.state == .queued })
        XCTAssertEqual(snapshot.outbox.count, 2)
        XCTAssertTrue(snapshot.outbox.allSatisfy { $0.secureMessageFanout == nil })
        let queuedMedia = try XCTUnwrap(
            snapshot.messages.first(where: { $0.id == media.clientMessageID })
        )
        XCTAssertEqual(queuedMedia.attachmentData, mediaBytes)
        let localRecord = try XCTUnwrap(queuedMedia.localMediaRecords?.first)
        XCTAssertEqual(localRecord.availabilityState, .localOriginal)
        XCTAssertEqual(localRecord.uploadState, .pending)
        XCTAssertNil(localRecord.remoteEncryptedObjectID)
        let locallyResolved = try XCTUnwrap(SecureMediaLoadPolicy.resolvePendingSingle(
            messageID: queuedMedia.id,
            conversationId: queuedMedia.conversationId,
            in: snapshot.messages
        ))
        XCTAssertEqual(locallyResolved.attachmentID, localRecord.id)
        XCTAssertEqual(locallyResolved.inlineData, mediaBytes)
        XCTAssertNil(locallyResolved.localStorageKey)
    }

    func testPreEnrollmentQueueRejectsContradictoryCommunicationOwner() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000017"
        let otherUserID = "10000000-0000-4000-8000-000000000018"
        let recipientUserID = "10000000-0000-4000-8000-000000000019"
        let conversationID = "30000000-0000-4000-8000-000000000017"
        let store = try await makeStore(userID: localUserID)
        try await store.update { state in
            state.communicationOwnerUserID = otherUserID
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

        do {
            _ = try await coordinator.queueDeferredText(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "ExampleContact",
                text: "must not cross accounts"
            )
            XCTFail("A contradictory local communication owner must fail closed")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .invalidConversation)
        }

        let rejectedQueueNetworkCallCount = await transport.networkCallCount()
        XCTAssertEqual(rejectedQueueNetworkCallCount, 0)
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
    }

    func testScheduledTextSurvivesRelaunchLocallyEncryptedAndUnsealedUntilDue() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000091"
        let recipientUserID = "10000000-0000-4000-8000-000000000092"
        let conversationID = "30000000-0000-4000-8000-000000000091"
        let clientMessageID = UUID(uuidString: "40000000-0000-4000-8000-000000000091")!
        let plaintext = "Keep this scheduled secret on this iPhone"
        let requestedDate = Date().addingTimeInterval(3_600)
        let expectedDate = ScheduledSendPolicy.canonicalMinute(requestedDate)
        let store = try await makeStore(userID: localUserID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(userID: localUserID)
        let originalConversationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "Scheduled recipient",
                participantUserIds: [localUserID, recipientUserID],
                unreadCount: 0,
                updatedAt: originalConversationDate
            )]
        }
        let transport = OfflineExchangeTransport()
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )

        let first = try await coordinator.queueDeferredText(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "Scheduled recipient",
            text: plaintext,
            clientMessageID: clientMessageID,
            deliverAt: requestedDate
        )

        XCTAssertEqual(first.clientMessageID, clientMessageID)
        let initialNetworkCallCount = await transport.networkCallCount()
        XCTAssertEqual(initialNetworkCallCount, 0)
        let snapshot = await store.snapshot()
        let message = try XCTUnwrap(snapshot.messages.first)
        let command = try XCTUnwrap(snapshot.outbox.first)
        XCTAssertEqual(message.body, plaintext)
        XCTAssertEqual(message.scheduledAt, expectedDate)
        XCTAssertEqual(command.scheduledAt, expectedDate)
        XCTAssertEqual(command.nextAttemptAt, expectedDate)
        XCTAssertNil(command.secureMessageFanout, "Signal encryption must wait until the item is due.")
        XCTAssertEqual(snapshot.conversations.first?.updatedAt, originalConversationDate)
        XCTAssertTrue(OutboxPolicy.readyCommands(snapshot.outbox, at: Date()).isEmpty)

        let stateURL = temporaryDirectory.appendingPathComponent("state.secure")
        let protectedBytes = try Data(contentsOf: stateURL)
        XCTAssertNil(
            protectedBytes.range(of: Data(plaintext.utf8)),
            "Scheduled plaintext must never appear unencrypted in the state file."
        )
        let reopened = SecureLocalStore(
            stateURL: stateURL,
            keyData: Data(repeating: 0x91, count: 32)
        )
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.messages.first?.body, plaintext)
        XCTAssertEqual(restored.outbox.first?.id, command.id)
        XCTAssertEqual(restored.outbox.first?.scheduledAt, expectedDate)
        XCTAssertNil(restored.outbox.first?.secureMessageFanout)

        // A retry after process uncertainty resolves to the same durable identity only when its
        // complete intent—including the promised minute—matches.
        let replay = try await coordinator.queueDeferredText(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "Scheduled recipient",
            text: plaintext,
            clientMessageID: clientMessageID,
            deliverAt: requestedDate
        )
        XCTAssertEqual(replay.clientMessageID, clientMessageID)
        do {
            _ = try await coordinator.queueDeferredText(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "Scheduled recipient",
                text: plaintext,
                clientMessageID: clientMessageID,
                deliverAt: requestedDate.addingTimeInterval(60)
            )
            XCTFail("A stable message id must not alias a different scheduled minute.")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .invalidConversation)
        }
        do {
            _ = try await coordinator.queueDeferredText(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "Scheduled recipient",
                text: "Do not send a stale schedule now",
                deliverAt: Date().addingTimeInterval(-60)
            )
            XCTFail("A stale fresh schedule must fail rather than becoming an immediate send.")
        } catch let error as SecureMessagingCryptoError {
            XCTAssertEqual(error, .invalidContent)
        }
        let final = await store.snapshot()
        XCTAssertEqual(final.messages.count, 1)
        XCTAssertEqual(final.outbox.count, 1)
        let finalNetworkCallCount = await transport.networkCallCount()
        XCTAssertEqual(finalNetworkCallCount, 0)
    }

    func testDeferredReactionDoesNotAdvanceConversationActivity() async throws {
        let localUserID = "10000000-0000-0000-0000-000000000019"
        let recipientUserID = "10000000-0000-0000-0000-000000000020"
        let conversationID = "30000000-0000-0000-0000-000000000019"
        let targetMessageID = "40000000-0000-0000-0000-000000000019"
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try await makeStore(userID: localUserID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(
            userID: localUserID,
            serverDeviceID: "20000000-0000-4000-8000-000000000019"
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
            state.messages = [LocalMessage(
                id: UUID(),
                serverMessageId: targetMessageID,
                conversationId: conversationID,
                senderId: recipientUserID,
                body: "Original message",
                createdAt: originalDate,
                sentAt: originalDate,
                state: .received,
                failureReason: nil,
                isOutgoing: false
            )]
        }
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: OfflineExchangeTransport(),
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )
        let reaction = try XCTUnwrap(KitMessageReaction(
            operation: .add,
            targetServerMessageID: targetMessageID,
            emoji: "👍"
        ))

        _ = try await coordinator.queueDeferredText(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            text: reaction.encoded
        )

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.conversations.first?.updatedAt, originalDate)
        XCTAssertTrue(snapshot.messages.contains(where: { $0.body == reaction.encoded }))
    }

    func testGroupDeferredTextQueuesForEveryOtherMemberAndFailsClosedElsewhere() async throws {
        let localUserID = "10000000-0000-0000-0000-000000000031"
        let memberB = "10000000-0000-0000-0000-000000000032"
        let memberC = "10000000-0000-0000-0000-000000000033"
        let groupConversationID = "30000000-0000-0000-0000-000000000031"
        let directConversationID = "30000000-0000-0000-0000-000000000032"
        let store = try await makeStore(userID: localUserID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = SecureMessagingEnrollmentBinding(
            userID: localUserID,
            serverDeviceID: "20000000-0000-0000-0000-000000000031",
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
            state.conversations = [
                Conversation(
                    id: groupConversationID,
                    title: "Weekend Trip",
                    participantUserIds: [localUserID, memberB, memberC],
                    unreadCount: 0,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    conversationType: SecureMessagingWire.groupConversationType
                ),
                Conversation(
                    id: directConversationID,
                    title: "ExampleContact",
                    participantUserIds: [localUserID, memberB],
                    unreadCount: 0,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
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
            conversationID: groupConversationID,
            expectedRecipientUserID: nil,
            title: "Weekend Trip",
            text: "hello group"
        )
        let snapshot = await store.snapshot()
        let command = try XCTUnwrap(snapshot.outbox.first)
        XCTAssertEqual(result.conversation.id, groupConversationID)
        XCTAssertEqual(command.conversationId, groupConversationID)
        XCTAssertEqual(command.recipientUserIds, [memberB, memberC].sorted())
        let transportCallCount = await transport.networkCallCount()
        XCTAssertEqual(transportCallCount, 0)

        // A nil recipient into a DIRECT thread fails closed…
        do {
            _ = try await coordinator.queueDeferredText(
                forUserID: localUserID,
                conversationID: directConversationID,
                expectedRecipientUserID: nil,
                title: "ExampleContact",
                text: "must not queue"
            )
            XCTFail("A direct thread must always pin its single recipient")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .invalidConversation)
        }
        // …and a pinned direct recipient into a GROUP thread fails closed too.
        do {
            _ = try await coordinator.queueDeferredText(
                forUserID: localUserID,
                conversationID: groupConversationID,
                expectedRecipientUserID: memberB,
                title: "Weekend Trip",
                text: "must not queue"
            )
            XCTFail("A group thread has no single pinned recipient")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .invalidConversation)
        }
        let finalSnapshot = await store.snapshot()
        XCTAssertEqual(finalSnapshot.messages.count, 1)
        XCTAssertEqual(finalSnapshot.outbox.count, 1)
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
            state.communicationOwnerUserID = localUserID
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
        let retainedShareItemID = UUID()
        let draftWriterID = UUID()
        let draftClearVersion = ConversationDraftWriteVersion(
            writerID: draftWriterID,
            sequence: 2
        )

        let result = try await coordinator.queueDeferredImage(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            mediaData: jpeg,
            mediaType: "image/jpeg",
            caption: "  Offline receipt  ",
            clientMessageID: retainedShareItemID
        )
        try await store.update { state in
            state.conversationDrafts = [
                conversationID: ConversationDraft(
                    body: "Offline receipt",
                    updatedAt: Date(),
                    writeVersion: ConversationDraftWriteVersion(
                        writerID: draftWriterID,
                        sequence: 1
                    )
                ),
            ]
        }
        let retry = try await coordinator.queueDeferredImage(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            mediaData: jpeg,
            mediaType: "image/jpeg",
            caption: "Offline receipt",
            clientMessageID: retainedShareItemID,
            submittedDraftBody: "Offline receipt",
            draftClearVersion: draftClearVersion
        )
        do {
            _ = try await coordinator.queueDeferredImage(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "ExampleContact",
                mediaData: jpeg,
                mediaType: "image/jpeg",
                caption: "Different attachment",
                clientMessageID: retainedShareItemID
            )
            XCTFail("a same-ID attachment collision must not be acknowledged as a retry")
        } catch {
            XCTAssertEqual(
                error as? SecureMessagingExchangeError,
                .invalidConversation
            )
        }

        let networkCallCount = await transport.networkCallCount()
        XCTAssertEqual(networkCallCount, 0)
        let snapshot = await store.snapshot()
        XCTAssertEqual(retry.clientMessageID, result.clientMessageID)
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.outbox.count, 1)
        XCTAssertEqual(snapshot.conversationDrafts?[conversationID]?.body, "")
        XCTAssertEqual(
            snapshot.conversationDrafts?[conversationID]?.writeVersion,
            draftClearVersion
        )
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

    func testProtectedFileSingleMediaStableIDReplaysExactlyAndRejectsCollision() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000073"
        let recipientUserID = "10000000-0000-4000-8000-000000000074"
        let conversationID = "30000000-0000-4000-8000-000000000073"
        let clientMessageID = UUID(uuidString: "60000000-0000-4000-8000-000000000073")!
        let mediaID = UUID(uuidString: "70000000-0000-4000-8000-000000000073")!
        let collisionMediaID = UUID(uuidString: "70000000-0000-4000-8000-000000000074")!
        let pdf = Data("%PDF-1.7\nprotected original".utf8)
        let collisionPDF = Data("%PDF-1.7\ndifferent original".utf8)
        let originalURL = temporaryDirectory.appendingPathComponent("original.pdf")
        let collisionURL = temporaryDirectory.appendingPathComponent("collision.pdf")
        try pdf.write(to: originalURL, options: .atomic)
        try collisionPDF.write(to: collisionURL, options: .atomic)

        let store = try await makeStore(userID: localUserID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(userID: localUserID)
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "Peer",
                participantUserIds: [localUserID, recipientUserID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_755_604_800)
            )]
        }
        let blobs = InMemoryMediaBlobStore(
            seed: [:],
            protectedFiles: [
                mediaID.uuidString.lowercased(): originalURL,
                collisionMediaID.uuidString.lowercased(): collisionURL,
            ]
        )
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: OfflineExchangeTransport(),
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(forUserID: localUserID)
        )

        let queued = try await coordinator.queueDeferredImage(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "Peer",
            mediaData: nil,
            mediaType: "application/pdf",
            caption: "Statement",
            localStorageKey: mediaID.uuidString.lowercased(),
            localMediaID: mediaID,
            plaintextByteSize: pdf.count,
            localStorageKind: .protectedFile,
            clientMessageID: clientMessageID
        )
        let replay = try await coordinator.queueDeferredImage(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "Peer",
            mediaData: nil,
            mediaType: "application/pdf",
            caption: "Statement",
            localStorageKey: mediaID.uuidString.lowercased(),
            localMediaID: mediaID,
            plaintextByteSize: pdf.count,
            localStorageKind: .protectedFile,
            clientMessageID: clientMessageID
        )

        XCTAssertEqual(replay.clientMessageID, queued.clientMessageID)
        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.outbox.count, 1)
        XCTAssertEqual(snapshot.messages.first?.localMediaRecords?.first?.id, mediaID.uuidString.lowercased())

        do {
            _ = try await coordinator.queueDeferredImage(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "Peer",
                mediaData: nil,
                mediaType: "application/pdf",
                caption: "Statement",
                localStorageKey: collisionMediaID.uuidString.lowercased(),
                localMediaID: collisionMediaID,
                plaintextByteSize: collisionPDF.count,
                localStorageKind: .protectedFile,
                clientMessageID: clientMessageID
            )
            XCTFail("a stable message id must not alias a different protected file")
        } catch SecureMessagingExchangeError.invalidConversation {
            // Expected: the existing message identity is bound to the original protected file.
        }

        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.outbox.count, 1)
        XCTAssertEqual(snapshot.messages.first?.localMediaRecords?.first?.id, mediaID.uuidString.lowercased())
    }

    func testSingleMediaQueueRejectsAnotherDraftOutputButConsumesItsExactDraft() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000071"
        let recipientUserID = "10000000-0000-4000-8000-000000000072"
        let conversationID = "30000000-0000-4000-8000-000000000071"
        let otherConversationID = "30000000-0000-4000-8000-000000000072"
        let offeredMediaID = UUID(uuidString: "70000000-0000-4000-8000-000000000071")!
        let otherSourceID = UUID(uuidString: "70000000-0000-4000-8000-000000000072")!
        let media = Data(repeating: 0x71, count: 512)
        let writerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let exactAttachment = ConversationDraftMediaAttachment(
            id: offeredMediaID,
            storageKind: .encryptedBlob,
            mediaType: "image/jpeg",
            originalMediaType: nil,
            byteCount: media.count,
            displayName: "Photo.jpg",
            duration: nil,
            acceptedAt: Date(timeIntervalSince1970: 1_755_604_800),
            clientMessageID: nil,
            preprocessingOutputStorageKey: nil
        )
        let conflictingAttachment = ConversationDraftMediaAttachment(
            id: otherSourceID,
            storageKind: .protectedFile,
            mediaType: "image/jpeg",
            originalMediaType: "image/heic",
            byteCount: media.count,
            displayName: "Other photo",
            duration: nil,
            acceptedAt: Date(timeIntervalSince1970: 1_755_604_800),
            clientMessageID: nil,
            preprocessingOutputStorageKey: offeredMediaID.uuidString.lowercased()
        )
        let store = try await makeStore(userID: localUserID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(userID: localUserID)
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            state.secureMessaging = crypto
            state.conversations = [conversationID, otherConversationID].map { id in
                Conversation(
                    id: id,
                    title: "Peer",
                    participantUserIds: [localUserID, recipientUserID],
                    unreadCount: 0,
                    updatedAt: Date(timeIntervalSince1970: 1_755_604_800)
                )
            }
            state.conversationDrafts = [
                otherConversationID: ConversationDraft(
                    body: "Other draft",
                    updatedAt: Date(),
                    writeVersion: ConversationDraftWriteVersion(
                        writerID: UUID(),
                        sequence: 1
                    ),
                    mediaAttachments: [conflictingAttachment]
                ),
            ]
        }
        let blobs = InMemoryMediaBlobStore(seed: [
            offeredMediaID.uuidString.lowercased(): media,
        ])
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: OfflineExchangeTransport(),
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(forUserID: localUserID)
        )

        do {
            _ = try await coordinator.queueDeferredImage(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "Peer",
                mediaData: media,
                mediaType: "image/jpeg",
                caption: "Caption",
                localStorageKey: offeredMediaID.uuidString.lowercased(),
                localMediaID: offeredMediaID,
                localStorageKind: .encryptedBlob
            )
            XCTFail("another draft's preprocessing output must block queue admission")
        } catch {
            // Expected: no storage key can acquire a second durable owner.
        }
        var snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
        XCTAssertEqual(
            snapshot.conversationDrafts?[otherConversationID]?.mediaAttachments,
            [conflictingAttachment]
        )

        let currentVersion = ConversationDraftWriteVersion(writerID: writerID, sequence: 1)
        let clearVersion = ConversationDraftWriteVersion(writerID: writerID, sequence: 2)
        try await store.update { state in
            state.conversationDrafts = [
                conversationID: ConversationDraft(
                    body: "Caption",
                    updatedAt: Date(),
                    writeVersion: currentVersion,
                    mediaAttachments: [exactAttachment]
                ),
            ]
        }
        let differentMediaID = UUID(uuidString: "70000000-0000-4000-8000-000000000079")!
        do {
            _ = try await coordinator.queueDeferredImage(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "Peer",
                mediaData: media,
                mediaType: "image/jpeg",
                caption: "Caption",
                localStorageKey: differentMediaID.uuidString.lowercased(),
                localMediaID: differentMediaID,
                localStorageKind: .encryptedBlob,
                submittedDraftBody: "Caption",
                submittedDraftMediaAttachments: [exactAttachment],
                draftClearVersion: clearVersion
            )
            XCTFail("an exact stored manifest must not exempt different queued media")
        } catch {
            // Expected: caller-supplied draft metadata is bound to the queued storage identity.
        }
        snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertEqual(
            snapshot.conversationDrafts?[conversationID]?.mediaAttachments,
            [exactAttachment]
        )
        _ = try await coordinator.queueDeferredImage(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "Peer",
            mediaData: media,
            mediaType: "image/jpeg",
            caption: "Caption",
            localStorageKey: offeredMediaID.uuidString.lowercased(),
            localMediaID: offeredMediaID,
            localStorageKind: .encryptedBlob,
            submittedDraftBody: "Caption",
            submittedDraftMediaAttachments: [exactAttachment],
            draftClearVersion: clearVersion
        )

        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.outbox.count, 1)
        XCTAssertEqual(snapshot.conversationDrafts?[conversationID]?.body, "")
        XCTAssertNil(snapshot.conversationDrafts?[conversationID]?.mediaAttachments)
        XCTAssertEqual(snapshot.conversationDrafts?[conversationID]?.writeVersion, clearVersion)
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
        let mediaID = messageID.uuidString.lowercased()
        let outboundKey = Data(
            (0..<SecureMediaAttachmentCipher.keyMaterialBytes).map(UInt8.init)
        )
        let localMediaRecord = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: mediaID,
            messageID: messageID,
            conversationID: conversationID,
            mediaType: "image/jpeg",
            fileSize: media.count,
            localStorageKey: localStorageKey,
            storesInline: false,
            now: createdAt,
            outboundKeyMaterial: outboundKey
        ))
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
            ),
            localMediaRecords: [localMediaRecord]
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
                byteCount: { key, userID in
                    key == localStorageKey && userID == localUserID ? media.count : nil
                },
                protectedOriginalURL: { _, _, _ in nil },
                duplicateIfAbsent: { _, _, _ in .conflict },
                removeDuplicate: { _, _, _ in false },
                remove: { key, _ in await removals.record(key) }
            )
        )

        do {
            _ = try await coordinator.prepareDeferredMessage(
                commandID: commandID,
                forUserID: localUserID
            )
            XCTFail("A conflicting cache duplicate must stop the descriptor checkpoint")
        } catch SecureMediaAttachmentError.invalidMedia {
            // Expected.
        }

        let snapshot = await store.snapshot()
        let retainedMessage = try XCTUnwrap(snapshot.messages.first)
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(retainedMessage.pendingAttachment, pendingMessage.pendingAttachment)
        XCTAssertEqual(retainedMessage.attachmentData, pendingMessage.attachmentData)
        XCTAssertEqual(retainedMessage.body, pendingMessage.body)
        XCTAssertEqual(retainedMessage.state, .queued)
        let retainedRecord = try XCTUnwrap(retainedMessage.localMediaRecords?.first)
        XCTAssertEqual(retainedRecord.id, mediaID)
        XCTAssertEqual(retainedRecord.localStorageKey, localStorageKey)
        XCTAssertEqual(retainedRecord.outboundKeyMaterialBase64, outboundKey.base64EncodedString())
        XCTAssertEqual(retainedRecord.uploadState, .uploading)
        XCTAssertEqual(retainedRecord.availabilityState, .localOriginal)
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

    func testRemoteIdentityLifecycleResumesOnlyAffectedPendingSend() async throws {
        let userID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let otherUserID = "10000000-0000-4000-8000-000000000003"
        let conversationID = "30000000-0000-4000-8000-000000000042"
        let peerDeviceID = "20000000-0000-4000-8000-000000000042"
        let nextCursor = "cursor-after-identity-change"
        let store = try await makeStore(userID: userID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let status = enrolledStatus(bundle: provisioned.bundle)
        let messageID = UUID(uuidString: "40000000-0000-4000-8000-000000000042")!
        let otherMessageID = UUID(uuidString: "40000000-0000-4000-8000-000000000043")!
        let createdAt = Date(timeIntervalSince1970: 1_755_604_800)
        var affected = OfflineCommand(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000042")!,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: messageID,
            recipientUserIds: [peerUserID],
            recipientName: "Peer",
            video: nil,
            expiresAt: nil
        )
        var unaffected = OfflineCommand(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000043")!,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: createdAt,
            attemptCount: 0,
            conversationId: "30000000-0000-4000-8000-000000000043",
            messageId: otherMessageID,
            recipientUserIds: [otherUserID],
            recipientName: "Other peer",
            video: nil,
            expiresAt: nil
        )
        affected.failureDisposition = .awaitingIdentityRefresh
        affected.lastFailureReason = SecureMessagingCryptoError.identityChanged.localizedDescription
        unaffected.failureDisposition = .awaitingIdentityRefresh
        unaffected.lastFailureReason = SecureMessagingCryptoError.identityChanged.localizedDescription
        try await store.update { state in
            state.secureMessaging = provisioned.state
            state.outbox = [affected, unaffected]
            state.messages = [
                LocalMessage(
                    id: messageID,
                    conversationId: conversationID,
                    senderId: userID,
                    body: "Pending for changed identity",
                    createdAt: createdAt,
                    sentAt: nil,
                    state: .queued,
                    failureReason: nil,
                    isOutgoing: true
                ),
                LocalMessage(
                    id: otherMessageID,
                    conversationId: unaffected.conversationId!,
                    senderId: userID,
                    body: "Pending for another identity",
                    createdAt: createdAt,
                    sentAt: nil,
                    state: .queued,
                    failureReason: nil,
                    isOutgoing: true
                ),
            ]
        }
        let responseObject: [String: Any] = [
            "events": [[
                "id": "42",
                "type": "identity.changed",
                "resource_type": "messaging_device",
                "resource_id": peerDeviceID,
                "occurred_at": "2026-08-20T13:00:00Z",
                "data": [
                    "device_id": peerDeviceID,
                    "user_id": peerUserID,
                    "enrollment_epoch": 2,
                    "signal_device_id": 2,
                    "registration_id": 1_002,
                    "protocol_version": SecureMessagingWire.protocolVersion,
                    "bundle_version": 2,
                    "identity_key_sha256": String(repeating: "d", count: 64),
                    "previous_identity_key_sha256": String(repeating: "c", count: 64),
                    "roster_refresh_required": true,
                    "transitioned_at": "2026-08-20T13:00:00Z",
                    "transition_hash": String(repeating: "e", count: 64),
                ],
            ]],
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
        let conversation = syncConversationDTO(type: SecureMessagingWire.directConversationType)
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

        let beforeSync = Date()
        _ = try await coordinator.sync(forUserID: userID)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, nextCursor)
        XCTAssertNil(snapshot.outbox[0].failureDisposition)
        XCTAssertGreaterThanOrEqual(snapshot.outbox[0].nextAttemptAt, beforeSync)
        XCTAssertEqual(snapshot.messages[0].state, .queued)
        XCTAssertEqual(snapshot.outbox[1].failureDisposition, .awaitingIdentityRefresh)
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

    func testSyncAndHistoryContinuationFenceRejectsSameUserReplacementScopesAndStaleRuns() {
        let userID = "10000000-0000-4000-8000-000000000069"
        let firstGeneration = UUID(uuidString: "60000000-0000-4000-8000-000000000069")!
        let replacementGeneration = UUID(
            uuidString: "60000000-0000-4000-8000-000000000070"
        )!
        let first = SecureMessagingActivationIdentity(
            userID: userID,
            accountGeneration: firstGeneration,
            sessionID: "70000000-0000-4000-8000-000000000069",
            admissionGeneration: 3
        )
        let replacementSession = SecureMessagingActivationIdentity(
            userID: userID,
            accountGeneration: firstGeneration,
            sessionID: "70000000-0000-4000-8000-000000000070",
            admissionGeneration: 3
        )
        let replacementAccountGeneration = SecureMessagingActivationIdentity(
            userID: userID,
            accountGeneration: replacementGeneration,
            sessionID: first.sessionID,
            admissionGeneration: 3
        )
        let replacementAdmissionGeneration = SecureMessagingActivationIdentity(
            userID: userID,
            accountGeneration: firstGeneration,
            sessionID: first.sessionID,
            admissionGeneration: 4
        )

        XCTAssertTrue(SecureMessagingScopedWorkFence.accepts(
            expectedIdentity: first,
            expectedGeneration: 4,
            currentIdentity: first,
            currentGeneration: 4
        ))
        XCTAssertFalse(SecureMessagingScopedWorkFence.accepts(
            expectedIdentity: first,
            expectedGeneration: 4,
            currentIdentity: replacementSession,
            currentGeneration: 4
        ), "A delayed history retry must not survive a same-user session replacement")
        XCTAssertFalse(SecureMessagingScopedWorkFence.accepts(
            expectedIdentity: first,
            expectedGeneration: 4,
            currentIdentity: replacementAccountGeneration,
            currentGeneration: 4
        ), "A delayed history retry must not survive a new account lifetime")
        XCTAssertFalse(SecureMessagingScopedWorkFence.accepts(
            expectedIdentity: first,
            expectedGeneration: 4,
            currentIdentity: replacementAdmissionGeneration,
            currentGeneration: 4
        ), "A protected-store lease replacement must invalidate inherited messaging work")
        XCTAssertFalse(SecureMessagingScopedWorkFence.accepts(
            expectedIdentity: first,
            expectedGeneration: 4,
            currentIdentity: first,
            currentGeneration: 5
        ), "A stale completion cannot requeue after its exact scope was superseded")
    }

    func testReplacementSessionCancelsScheduledHistoryContinuationBeforeItRuns() async throws {
        let userID = "10000000-0000-4000-8000-000000000071"
        let accountGeneration = UUID(
            uuidString: "60000000-0000-4000-8000-000000000071"
        )!
        let originalSessionID = "70000000-0000-4000-8000-000000000071"
        let replacementSessionID = "70000000-0000-4000-8000-000000000072"
        let store = try await makeStore(userID: userID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let status = enrolledStatus(bundle: provisioned.bundle)
        let binding = try SecureMessagingMapper.enrollmentBinding(from: status, userID: userID)
        let crypto = try await engine.bindEnrollment(binding, to: provisioned.state)
        try await store.update { $0.secureMessaging = crypto }
        let transport = SupersededActivationTransport(status: status)
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1
        )

        await SecureMessagingActivationBinding.withAuthenticatedScope(
            accountGeneration: accountGeneration,
            sessionID: originalSessionID
        ) {
            await coordinator.scheduleHistoryContinuationForTesting(
                forUserID: userID,
                delayNanoseconds: 5_000_000_000
            )
        }
        let scheduled = await coordinator.historyContinuationOwnershipForTesting()
        XCTAssertTrue(scheduled.scheduled)
        XCTAssertFalse(scheduled.running)

        let replacementActivation = Task {
            try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: accountGeneration,
                sessionID: replacementSessionID
            ) {
                try await coordinator.activate(forUserID: userID)
            }
        }
        try await transport.waitUntilFirstStatusStarted()

        let cancelled = await coordinator.historyContinuationOwnershipForTesting()
        XCTAssertFalse(cancelled.scheduled)
        XCTAssertFalse(cancelled.running)

        await transport.releaseFirstStatus()
        try await replacementActivation.value
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyRequests = await transport.messagingConversationListRequestCount()
        XCTAssertEqual(historyRequests, 0)
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

    func testHistoricalGroupRosterPolicyAllowsMembershipChurnButCurrentRosterStaysExact() {
        let currentUserID = "10000000-0000-4000-8000-000000000081"
        let departedUserID = "10000000-0000-4000-8000-000000000082"
        let addedUserID = "10000000-0000-4000-8000-000000000083"
        let historicalMembers: Set<String> = [currentUserID, departedUserID]
        let currentMembers: Set<String> = [currentUserID, addedUserID]

        XCTAssertTrue(SecureMessagingMapper.rosterMembershipIsValid(
            historicalMembers,
            use: .historical,
            currentUserID: currentUserID,
            expectedCurrentMemberUserIDs: currentMembers,
            allowHistoricalGroupMembershipChurn: true
        ))
        XCTAssertFalse(SecureMessagingMapper.rosterMembershipIsValid(
            historicalMembers,
            use: .historical,
            currentUserID: currentUserID,
            expectedCurrentMemberUserIDs: currentMembers,
            allowHistoricalGroupMembershipChurn: false
        ), "A direct conversation's historical roster must remain exact")
        XCTAssertFalse(SecureMessagingMapper.rosterMembershipIsValid(
            historicalMembers,
            use: .current,
            currentUserID: currentUserID,
            expectedCurrentMemberUserIDs: currentMembers,
            allowHistoricalGroupMembershipChurn: true
        ), "The group-history allowance must never relax a live fanout roster")
        XCTAssertFalse(SecureMessagingMapper.rosterMembershipIsValid(
            [departedUserID, addedUserID],
            use: .historical,
            currentUserID: currentUserID,
            expectedCurrentMemberUserIDs: currentMembers,
            allowHistoricalGroupMembershipChurn: true
        ), "Even an old group roster must contain the local account")
        XCTAssertTrue(SecureMessagingMapper.rosterMembershipIsValid(
            [currentUserID],
            use: .historical,
            currentUserID: currentUserID,
            expectedCurrentMemberUserIDs: [currentUserID],
            allowHistoricalGroupMembershipChurn: true
        ), "A retained group can have one-member current and historical snapshots")
        XCTAssertTrue(SecureMessagingMapper.rosterMembershipIsValid(
            [currentUserID],
            use: .historical,
            currentUserID: currentUserID,
            expectedCurrentMemberUserIDs: currentMembers,
            allowHistoricalGroupMembershipChurn: true
        ), "The historical roster itself may predate every other active member")
        XCTAssertTrue(SecureMessagingMapper.rosterMembershipIsValid(
            historicalMembers,
            use: .historical,
            currentUserID: currentUserID,
            expectedCurrentMemberUserIDs: [currentUserID],
            allowHistoricalGroupMembershipChurn: true
        ), "The current retained group may have shrunk to one member")
        XCTAssertFalse(SecureMessagingMapper.rosterMembershipIsValid(
            [currentUserID],
            use: .current,
            currentUserID: currentUserID,
            expectedCurrentMemberUserIDs: [currentUserID],
            allowHistoricalGroupMembershipChurn: true
        ), "A live outbound roster still requires at least two members")
    }

    func testHistoricalOriginalRosterBindsDepartedSenderAndAllowsLegacyMetadata() throws {
        let fixture = try makeHistoricalSenderBindingFixture()
        let currentGroupMembers: Set<String> = [
            "10000000-0000-4000-8000-000000000091",
            "10000000-0000-4000-8000-000000000092",
        ]
        XCTAssertFalse(currentGroupMembers.contains(fixture.identity.senderUserID))
        let validatedSender = try SecureMessagingMapper.validatedHistoricalSender(
            from: fixture.dto,
            identity: fixture.identity,
            roster: fixture.roster
        )
        let legacyMetadata = SecureMessagingRetainedMessageMetadata(
            clientMessageID: fixture.identity.clientMessageID,
            senderUserID: nil,
            senderDeviceID: fixture.identity.senderDeviceID,
            senderEnrollmentEpoch: fixture.identity.senderEnrollmentEpoch,
            senderSignalDeviceID: fixture.identity.senderSignalDeviceID,
            rosterRevision: fixture.identity.rosterRevision,
            kind: fixture.identity.kind,
            replyToMessageID: fixture.identity.replyToMessageID
        )

        XCTAssertTrue(SecureMessagingMapper.retainedMetadataMatches(
            legacyMetadata,
            identity: fixture.identity,
            validatedSender: validatedSender
        ))
        let mismatchedSenderMetadata = SecureMessagingRetainedMessageMetadata(
            clientMessageID: legacyMetadata.clientMessageID,
            senderUserID: "10000000-0000-4000-8000-000000000099",
            senderDeviceID: legacyMetadata.senderDeviceID,
            senderEnrollmentEpoch: legacyMetadata.senderEnrollmentEpoch,
            senderSignalDeviceID: legacyMetadata.senderSignalDeviceID,
            rosterRevision: legacyMetadata.rosterRevision,
            kind: legacyMetadata.kind,
            replyToMessageID: legacyMetadata.replyToMessageID
        )
        XCTAssertFalse(SecureMessagingMapper.retainedMetadataMatches(
            mismatchedSenderMetadata,
            identity: fixture.identity,
            validatedSender: validatedSender
        ))
        let mismatchedLegacyMetadata = SecureMessagingRetainedMessageMetadata(
            clientMessageID: legacyMetadata.clientMessageID,
            senderUserID: nil,
            senderDeviceID: "20000000-0000-4000-8000-000000000098",
            senderEnrollmentEpoch: legacyMetadata.senderEnrollmentEpoch,
            senderSignalDeviceID: legacyMetadata.senderSignalDeviceID,
            rosterRevision: legacyMetadata.rosterRevision,
            kind: legacyMetadata.kind,
            replyToMessageID: legacyMetadata.replyToMessageID
        )
        XCTAssertFalse(SecureMessagingMapper.retainedMetadataMatches(
            mismatchedLegacyMetadata,
            identity: fixture.identity,
            validatedSender: validatedSender
        ), "A missing sender field must not weaken any legacy identity field")
    }

    func testHistoricalOriginalRosterRejectsForgedSenderIdentityAndDeviceFields() throws {
        let forgedUser = try makeHistoricalSenderBindingFixture(
            senderUserID: "10000000-0000-4000-8000-000000000099"
        )
        XCTAssertThrowsError(try SecureMessagingMapper.validatedHistoricalSender(
            from: forgedUser.dto,
            identity: forgedUser.identity,
            roster: forgedUser.roster
        ))

        let forgedDevice = try makeHistoricalSenderBindingFixture(
            senderDeviceID: "20000000-0000-4000-8000-000000000099"
        )
        XCTAssertThrowsError(try SecureMessagingMapper.validatedHistoricalSender(
            from: forgedDevice.dto,
            identity: forgedDevice.identity,
            roster: forgedDevice.roster
        ))

        for forged in [
            try makeHistoricalSenderBindingFixture(senderSignalDeviceID: 7),
            try makeHistoricalSenderBindingFixture(senderRegistrationID: 999),
            try makeHistoricalSenderBindingFixture(senderBundleVersion: 999),
            try makeHistoricalSenderBindingFixture(
                senderIdentityKeySHA256: String(repeating: "f", count: 64)
            ),
        ] {
            XCTAssertThrowsError(try SecureMessagingMapper.validatedHistoricalSender(
                from: forged.dto,
                identity: forged.identity,
                roster: forged.roster
            ))
        }
    }

    func testPeerAuthoredSystemNoticeInHistoryBackfillIsSuppressedAndAcknowledged() throws {
        let forgedNotice = try XCTUnwrap(KitSystemMessage(
            kind: .memberAdded,
            subjectUserID: "10000000-0000-4000-8000-000000000095",
            actorUserID: "10000000-0000-4000-8000-000000000054"
        )).encoded
        let fixture = try makeHistoryDescriptorFixture(body: forgedNotice)
        XCTAssertEqual(
            try SecureMessagingHistoryBackfillCodec.authenticate(
                fixture.descriptor,
                incoming: fixture.incoming
            ).text,
            forgedNotice,
            "The reserved-text policy, not malformed history data, must cause suppression"
        )

        switch try SecureMessagingExchangeCoordinator.historyDescriptorDisposition(
            fixture.descriptor,
            incoming: fixture.incoming
        ) {
        case .suppressed(let acknowledgementMessageID):
            XCTAssertEqual(acknowledgementMessageID, fixture.incoming.original.messageID)
        case .authenticated:
            XCTFail("Peer-authored history must not materialize a trusted lifecycle notice")
        }
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
            senderUserID: userID,
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

        let legacyMetadata = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: nil,
            senderDeviceID: metadata.senderDeviceID,
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: metadata.kind,
            replyToMessageID: metadata.replyToMessageID
        )
        var legacyMessage = recovered
        legacyMessage.secureMessagingHistory = legacyMetadata
        var legacyState = PersistedState.empty
        legacyState.messages = [legacyMessage]
        SecureMessagingExchangeCoordinator.reconcileRecoveredHistoryMessages(
            [recovered],
            currentDeviceID: currentDeviceID,
            into: &legacyState
        )
        XCTAssertEqual(legacyState.messages[0].secureMessagingHistory, metadata)

        let wrongSenderMetadata = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: "10000000-0000-4000-8000-000000000099",
            senderDeviceID: metadata.senderDeviceID,
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: metadata.kind,
            replyToMessageID: metadata.replyToMessageID
        )
        var wrongSenderMessage = recovered
        wrongSenderMessage.secureMessagingHistory = wrongSenderMetadata
        var wrongSenderState = PersistedState.empty
        wrongSenderState.messages = [wrongSenderMessage]
        SecureMessagingExchangeCoordinator.reconcileRecoveredHistoryMessages(
            [recovered],
            currentDeviceID: currentDeviceID,
            into: &wrongSenderState
        )
        XCTAssertEqual(
            wrongSenderState.messages[0].secureMessagingHistory,
            wrongSenderMetadata
        )

        var otherDeviceState = PersistedState.empty
        otherDeviceState.messages = [local]
        var otherDeviceMetadata = metadata
        otherDeviceMetadata = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: metadata.senderUserID,
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

    private func makeHistoryDescriptorFixture(body: String = "history text") throws -> (
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
            body: body,
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

    private func makeHistoricalSenderBindingFixture(
        senderUserID: String = "10000000-0000-4000-8000-000000000093",
        senderDeviceID: String = "20000000-0000-4000-8000-000000000093",
        senderSignalDeviceID: Int = 2,
        senderRegistrationID: Int = 93,
        senderBundleVersion: Int = 3,
        senderIdentityKeySHA256: String = String(repeating: "d", count: 64)
    ) throws -> (
        dto: EncryptedMessageDTO,
        identity: SecureMessagingHistoryMessageIdentity,
        roster: SecureMessagingRosterSnapshot
    ) {
        let conversationID = "30000000-0000-4000-8000-000000000093"
        let rosterRevision = "v1:sha256:\(String(repeating: "c", count: 64))"
        let localUserID = "10000000-0000-4000-8000-000000000091"
        let localDeviceID = "20000000-0000-4000-8000-000000000091"
        let departedUserID = "10000000-0000-4000-8000-000000000093"
        let departedDeviceID = "20000000-0000-4000-8000-000000000093"
        let localIdentity = String(repeating: "b", count: 64)
        let departedIdentity = String(repeating: "d", count: 64)
        let localSignedPreKey = Data(
            [UInt8(5)] + Array(repeating: UInt8(0x11), count: 32)
        )
        let departedSignedPreKey = Data(
            [UInt8(5)] + Array(repeating: UInt8(0x21), count: 32)
        )
        let devices = [
            SecureMessagingRosterDevice(
                address: SecureMessagingAddress(
                    userID: localUserID,
                    serverDeviceID: localDeviceID,
                    signalDeviceID: 1
                ),
                registrationID: 91,
                identityKeySHA256: localIdentity
            ),
            SecureMessagingRosterDevice(
                address: SecureMessagingAddress(
                    userID: departedUserID,
                    serverDeviceID: departedDeviceID,
                    signalDeviceID: 2
                ),
                registrationID: 93,
                identityKeySHA256: departedIdentity
            ),
        ]
        let roster = SecureMessagingRosterSnapshot(
            use: .historical,
            conversationID: conversationID,
            rosterRevision: rosterRevision,
            devices: devices,
            frozenDevices: [
                localDeviceID: SecureMessagingFrozenRosterDevice(
                    enrollmentEpoch: nil,
                    bundleVersion: 2,
                    signedPreKeyID: 1,
                    signedPreKeyPublicKey: localSignedPreKey,
                    signedPreKeySHA256: SecureMessagingValidation.sha256Hex(localSignedPreKey),
                    signedPreKeySignature: Data(repeating: 0x12, count: 64)
                ),
                departedDeviceID: SecureMessagingFrozenRosterDevice(
                    enrollmentEpoch: nil,
                    bundleVersion: 3,
                    signedPreKeyID: 2,
                    signedPreKeyPublicKey: departedSignedPreKey,
                    signedPreKeySHA256: SecureMessagingValidation.sha256Hex(
                        departedSignedPreKey
                    ),
                    signedPreKeySignature: Data(repeating: 0x22, count: 64)
                ),
            ]
        )
        let dto = EncryptedMessageDTO(
            id: "70000000-0000-4000-8000-000000000093",
            conversationId: conversationID,
            clientMessageId: "80000000-0000-4000-8000-000000000093",
            sender: EncryptedMessageSenderDTO(id: senderUserID, name: "Former member"),
            senderDeviceId: senderDeviceID,
            senderEnrollmentEpoch: 4,
            senderSignalDeviceId: senderSignalDeviceID,
            senderRegistrationId: senderRegistrationID,
            senderProtocolVersion: SecureMessagingWire.protocolVersion,
            senderBundleVersion: senderBundleVersion,
            senderIdentityKeySha256: senderIdentityKeySHA256,
            rosterRevision: rosterRevision,
            kind: SecureMessagingMessageKind.encrypted.rawValue,
            replyToMessageId: nil,
            envelope: nil,
            attachments: [],
            reactions: [],
            sentAt: "2026-08-20T12:00:00Z",
            revokedAt: nil
        )
        return (
            dto,
            try SecureMessagingMapper.historyCandidateIdentity(
                from: dto,
                expectedConversationID: conversationID
            ),
            roster
        )
    }

    private var syncUserID: String { "10000000-0000-4000-8000-000000000101" }
    private var syncPeerUserID: String { "10000000-0000-4000-8000-000000000102" }
    private var syncConversationID: String { "30000000-0000-4000-8000-000000000101" }
    private var syncNextCursor: String { "cursor-after-conversation-load" }

    private func conversationUpdatedSyncEvent() -> [String: Any] {
        [
            "id": "101",
            "type": "conversation.updated",
            "conversation_id": syncConversationID,
            "resource_type": "conversation",
            "resource_id": syncConversationID,
            "occurred_at": "2026-08-24T12:00:00Z",
        ]
    }

    private func messageCreatedSyncEvent() -> [String: Any] {
        let messageID = "70000000-0000-4000-8000-000000000101"
        return [
            "id": "102",
            "type": "message.created",
            "conversation_id": syncConversationID,
            "resource_type": "message",
            "resource_id": messageID,
            "data": [
                "id": messageID,
                "conversation_id": syncConversationID,
            ],
            "occurred_at": "2026-08-24T12:00:01Z",
        ]
    }

    private func encryptedMessageCreatedSyncEventForQuarantine() -> [String: Any] {
        let messageID = "70000000-0000-4000-8000-000000000106"
        return [
            "id": "106",
            "type": "message.created",
            "conversation_id": syncConversationID,
            "resource_type": "message",
            "resource_id": messageID,
            "data": [
                "id": messageID,
                "conversation_id": syncConversationID,
                "envelope": ["ciphertext": "AA=="],
            ],
            "occurred_at": "2026-08-24T12:00:06Z",
        ]
    }

    private func memberAddedSyncEvent(
        subjectUserID: String,
        role: String? = nil,
        eventID: String = "103"
    ) -> [String: Any] {
        [
            "id": eventID,
            "type": "membership.added",
            "conversation_id": syncConversationID,
            "resource_type": "conversation_member",
            "resource_id": "60000000-0000-4000-8000-000000000101",
            "data": [
                "user_id": subjectUserID,
                "role": role ?? (subjectUserID == syncUserID ? "owner" : "member"),
            ],
            "occurred_at": "2026-08-24T12:00:02Z",
        ]
    }

    private func memberRoleChangedSyncEvent(
        subjectUserID: String,
        role: String,
        eventID: String = "104"
    ) -> [String: Any] {
        [
            "id": eventID,
            "type": "membership.role_changed",
            "conversation_id": syncConversationID,
            "resource_type": "conversation_member",
            "resource_id": "60000000-0000-4000-8000-000000000101",
            "data": ["user_id": subjectUserID, "role": role],
            "occurred_at": "2026-08-24T12:00:03Z",
        ]
    }

    private func memberRemovedSyncEvent(
        subjectUserID: String,
        eventID: String = "105"
    ) -> [String: Any] {
        [
            "id": eventID,
            "type": "membership.removed",
            "conversation_id": syncConversationID,
            "resource_type": "conversation_member",
            "resource_id": "60000000-0000-4000-8000-000000000101",
            "data": ["user_id": subjectUserID],
            "occurred_at": "2026-08-24T12:00:04Z",
        ]
    }

    private func syncConversationDTO(
        type: String,
        title: String = "Weekend Trip",
        localRole: String = "owner",
        peerRole: String = "member",
        includePeer: Bool = true
    ) -> MessagingConversationDTO {
        var members: [MessagingConversationMemberDTO?] = [
            MessagingConversationMemberDTO(
                userId: syncUserID,
                name: "Secure User",
                role: localRole,
                joinedAt: "2026-08-24T11:00:00Z"
            ),
        ]
        if includePeer {
            members.append(MessagingConversationMemberDTO(
                userId: syncPeerUserID,
                name: "Peer",
                role: peerRole,
                joinedAt: "2026-08-24T11:00:00Z"
            ))
        }
        return MessagingConversationDTO(
            id: syncConversationID,
            type: type,
            title: type == SecureMessagingWire.groupConversationType ? title : nil,
            parentId: nil,
            createdBy: syncUserID,
            role: localRole,
            members: members,
            createdAt: "2026-08-24T11:00:00Z",
            updatedAt: "2026-08-24T12:00:00Z"
        )
    }

    private func makeGroupRenameFixture(fails: Bool) async throws -> GroupRenameFixture {
        let userID = "10000000-0000-4000-8000-000000000201"
        let peerUserID = "10000000-0000-4000-8000-000000000202"
        let thirdUserID = "10000000-0000-4000-8000-000000000203"
        let conversationID = "30000000-0000-4000-8000-000000000201"
        let localDeviceID = "20000000-0000-4000-8000-000000000201"
        let peerDeviceID = "20000000-0000-4000-8000-000000000202"
        let responseTimestamp = "2026-08-24T12:00:00Z"
        let responseUpdatedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: responseTimestamp)
        )
        let initialConversation = Conversation(
            id: conversationID,
            title: "Original title",
            participantUserIds: [userID, peerUserID],
            unreadCount: 7,
            updatedAt: responseUpdatedAt.addingTimeInterval(-60),
            conversationType: SecureMessagingWire.groupConversationType,
            groupMemberRoles: [userID: .owner, peerUserID: .member]
        )
        let response = MessagingConversationDTO(
            id: conversationID,
            type: SecureMessagingWire.groupConversationType,
            title: "Requested rename",
            parentId: nil,
            createdBy: userID,
            role: MessagingGroupRole.owner.rawValue,
            members: [
                MessagingConversationMemberDTO(
                    userId: userID,
                    name: "Secure User",
                    role: MessagingGroupRole.owner.rawValue,
                    joinedAt: "2026-08-24T11:00:00Z"
                ),
                MessagingConversationMemberDTO(
                    userId: peerUserID,
                    name: "Peer",
                    role: MessagingGroupRole.member.rawValue,
                    joinedAt: "2026-08-24T11:00:00Z"
                ),
            ],
            createdAt: "2026-08-24T11:00:00Z",
            updatedAt: responseTimestamp
        )
        let rosterData = try JSONSerialization.data(withJSONObject: [
            "conversation_id": conversationID,
            "devices": [
                ["device_id": localDeviceID, "user_id": userID],
                [
                    "device_id": peerDeviceID,
                    "user_id": peerUserID,
                    "client": [
                        "platform": "android",
                        "capabilities": [
                            MessagingGroupCapabilityPolicy.deviceCapabilityKey: true,
                        ],
                    ],
                ],
            ],
        ])
        let roster = try JSONDecoder().decode(MessagingDeviceRosterDTO.self, from: rosterData)
        let store = try await makeStore(userID: userID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(
            userID: userID,
            serverDeviceID: localDeviceID
        )
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.secureMessaging = crypto
            state.conversations = [initialConversation]
        }
        let transport = SuspendedGroupRenameTransport(
            conversationID: conversationID,
            expectedTitle: "Requested rename",
            roster: roster,
            result: fails ? .failure : .success(response)
        )
        return GroupRenameFixture(
            userID: userID,
            peerUserID: peerUserID,
            thirdUserID: thirdUserID,
            conversationID: conversationID,
            responseUpdatedAt: responseUpdatedAt,
            initialConversation: initialConversation,
            store: store,
            coordinator: SecureMessagingExchangeCoordinator(
                transport: transport,
                store: store,
                engine: SecureMessagingCryptoEngine(),
                provisioningPreKeyCount: 1
            ),
            transport: transport
        )
    }

    private func makeSyncConversationLoadFixture(
        event: [String: Any],
        conversationBehavior: SyncConversationLoadTransport.ConversationBehavior,
        localConversations: [Conversation] = [],
        groupProjectionUpdatedAt: [String: Date]? = nil
    ) async throws -> SyncConversationLoadFixture {
        try await makeSyncConversationLoadFixture(
            events: [event],
            conversationBehavior: conversationBehavior,
            localConversations: localConversations,
            groupProjectionUpdatedAt: groupProjectionUpdatedAt
        )
    }

    private func makeSyncConversationLoadFixture(
        events: [[String: Any]],
        conversationBehavior: SyncConversationLoadTransport.ConversationBehavior,
        localConversations: [Conversation] = [],
        groupProjectionUpdatedAt: [String: Date]? = nil
    ) async throws -> SyncConversationLoadFixture {
        let store = try await makeStore(userID: syncUserID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        try await store.update { state in
            state.secureMessaging = provisioned.state
            state.conversations = localConversations
            state.groupProjectionUpdatedAt = groupProjectionUpdatedAt
        }
        let responseObject: [String: Any] = [
            "events": events,
            "page": [
                "next_cursor": syncNextCursor,
                "has_more": false,
                "limit": SecureMessagingWire.maximumSyncPage,
            ],
        ]
        let response = try JSONDecoder().decode(
            MessagingSyncDTO.self,
            from: JSONSerialization.data(withJSONObject: responseObject)
        )
        let transport = SyncConversationLoadTransport(
            status: enrolledStatus(bundle: provisioned.bundle),
            response: response,
            conversationBehavior: conversationBehavior
        )
        return SyncConversationLoadFixture(
            userID: syncUserID,
            conversationID: syncConversationID,
            nextCursor: syncNextCursor,
            store: store,
            coordinator: SecureMessagingExchangeCoordinator(
                transport: transport,
                store: store,
                engine: engine,
                provisioningPreKeyCount: 1
            ),
            transport: transport
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
        peerName: String,
        peerAvatarURL: String? = nil,
        peerVerification: AccountVerificationDTO? = nil
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
                    joinedAt: "2026-08-22T10:00:00Z",
                    avatarUrl: peerAvatarURL,
                    verification: peerVerification
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

    // MARK: Media-message v2 outbound pipeline (contract v0.4, 449925d9…)

    /// One share-sheet hand-off of 2+ items and a caption becomes exactly one durable
    /// projection: one LocalMessage whose id is the wire client_message_id, one OfflineCommand,
    /// zero network calls — and re-offering the same durable share-batch id replays that exact
    /// projection instead of minting a second message.
    func testDeferredMediaBatchQueuesOneMessageOneCommandAndReplaysTheShareBatchID() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000043"
        let recipientUserID = "10000000-0000-4000-8000-000000000044"
        let conversationID = "30000000-0000-4000-8000-000000000043"
        let sharedBatchID = UUID(uuidString: "80000000-0000-4000-8000-000000000043")!
        let caption = "Two receipts, one message"
        let firstParkKey = "70000000-0000-4000-8000-000000000043"
        let secondParkKey = "70000000-0000-4000-8000-000000000044"
        let firstPlaintext = Data(repeating: 0xA1, count: 300)
        let secondPlaintext = Data(repeating: 0xB2, count: 517)
        let blobs = InMemoryMediaBlobStore(seed: [
            firstParkKey: firstPlaintext,
            secondParkKey: secondPlaintext,
        ])
        var keyByte: UInt8 = 0x40
        let batch = try KitMediaMessageV2OutboundBatch.queued(
            attachments: [
                .init(
                    mediaType: "image/jpeg",
                    plaintextByteSize: firstPlaintext.count,
                    localStorageKey: firstParkKey
                ),
                .init(
                    mediaType: "video/mp4",
                    plaintextByteSize: secondPlaintext.count,
                    localStorageKey: secondParkKey
                ),
            ],
            rawCaption: caption,
            keyMaterialFactory: {
                keyByte += 1
                return Data(repeating: keyByte, count: 64)
            }
        )
        let store = try await makeStore(userID: localUserID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(userID: localUserID)
        try await store.update { state in
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [localUserID, recipientUserID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_755_604_800)
            )]
        }
        let transport = OfflineExchangeTransport()
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(forUserID: localUserID)
        )

        let first = try await coordinator.queueDeferredMediaBatch(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            batch: batch,
            clientMessageID: sharedBatchID
        )
        // The share extension retries with the same durable batch id and identical content.
        let replay = try await coordinator.queueDeferredMediaBatch(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            batch: batch,
            clientMessageID: sharedBatchID
        )

        XCTAssertEqual(first.clientMessageID, sharedBatchID)
        XCTAssertEqual(replay.clientMessageID, sharedBatchID)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.outbox.count, 1)
        let message = try XCTUnwrap(snapshot.messages.first)
        let command = try XCTUnwrap(snapshot.outbox.first)
        XCTAssertEqual(message.id, sharedBatchID)
        XCTAssertEqual(message.body, caption)
        XCTAssertEqual(message.pendingMediaBatch, batch)
        XCTAssertEqual(message.state, .queued)
        XCTAssertTrue(message.isOutgoing)
        XCTAssertEqual(command.kind, .secureMessage)
        XCTAssertEqual(command.messageId, sharedBatchID)
        XCTAssertEqual(command.conversationId, conversationID)
        XCTAssertNil(command.secureMessageFanout)
        let networkCalls = await transport.networkCallCount()
        XCTAssertEqual(networkCalls, 0, "airplane-mode queueing must touch no endpoint")
        // The replay recognized its own projection, so neither park was retired as scratch.
        let survivingKeys = await blobs.storageKeys()
        XCTAssertEqual(survivingKeys, [firstParkKey, secondParkKey])
    }

    func testDeferredMediaBatchRejectsParkKeyOwnedByAnotherDraft() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000073"
        let recipientUserID = "10000000-0000-4000-8000-000000000074"
        let conversationID = "30000000-0000-4000-8000-000000000073"
        let otherConversationID = "30000000-0000-4000-8000-000000000074"
        let firstParkKey = "70000000-0000-4000-8000-000000000073"
        let secondParkKey = "70000000-0000-4000-8000-000000000074"
        let firstPlaintext = Data(repeating: 0x73, count: 300)
        let secondPlaintext = Data(repeating: 0x74, count: 517)
        let batch = try KitMediaMessageV2OutboundBatch.queued(
            attachments: [
                .init(
                    attachmentID: firstParkKey,
                    mediaType: "image/jpeg",
                    plaintextByteSize: firstPlaintext.count,
                    localStorageKey: firstParkKey
                ),
                .init(
                    attachmentID: secondParkKey,
                    mediaType: "video/mp4",
                    plaintextByteSize: secondPlaintext.count,
                    localStorageKey: secondParkKey
                ),
            ],
            rawCaption: "Offline batch",
            keyMaterialFactory: {
                Data(repeating: 0x73, count: SecureMediaAttachmentCipher.keyMaterialBytes)
            }
        )
        let draftAttachment = ConversationDraftMediaAttachment(
            id: UUID(uuidString: firstParkKey)!,
            storageKind: .encryptedBlob,
            mediaType: "image/jpeg",
            originalMediaType: nil,
            byteCount: firstPlaintext.count,
            displayName: "Reserved photo",
            duration: nil,
            acceptedAt: Date(),
            clientMessageID: nil,
            preprocessingOutputStorageKey: nil
        )
        let store = try await makeStore(userID: localUserID)
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            var crypto = SecureMessagingPersistentState.empty
            crypto.enrollment = raceEnrollment(userID: localUserID)
            state.secureMessaging = crypto
            state.conversations = [conversationID, otherConversationID].map { id in
                Conversation(
                    id: id,
                    title: "Peer",
                    participantUserIds: [localUserID, recipientUserID],
                    unreadCount: 0,
                    updatedAt: Date(timeIntervalSince1970: 1_755_604_800)
                )
            }
            state.conversationDrafts = [
                otherConversationID: ConversationDraft(
                    body: "Reserved",
                    updatedAt: Date(),
                    writeVersion: ConversationDraftWriteVersion(
                        writerID: UUID(),
                        sequence: 1
                    ),
                    mediaAttachments: [draftAttachment]
                ),
            ]
        }
        let blobs = InMemoryMediaBlobStore(seed: [
            firstParkKey: firstPlaintext,
            secondParkKey: secondPlaintext,
        ])
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: OfflineExchangeTransport(),
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(forUserID: localUserID)
        )

        do {
            _ = try await coordinator.queueDeferredMediaBatch(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "Peer",
                batch: batch
            )
            XCTFail("a batch must not reuse another draft's local media key")
        } catch {
            // Expected: the draft remains the sole durable owner.
        }

        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
        XCTAssertEqual(snapshot.conversationDrafts?[otherConversationID]?.mediaAttachments, [draftAttachment])
        let retainedKeys = await blobs.storageKeys()
        XCTAssertEqual(retainedKeys, [firstParkKey, secondParkKey])
    }

    func testDeferredMediaBatchRejectsOutputKeyOwnedByAnotherRecordsSpoolID() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000083"
        let recipientUserID = "10000000-0000-4000-8000-000000000084"
        let conversationID = "30000000-0000-4000-8000-000000000083"
        let existingConversationID = "30000000-0000-4000-8000-000000000084"
        let firstSourceKey = "70000000-0000-4000-8000-000000000083"
        let secondSourceKey = "70000000-0000-4000-8000-000000000084"
        let collidingSpoolID = "70000000-0000-4000-8000-000000000085"
        let existingSourceKey = "70000000-0000-4000-8000-000000000086"
        let firstBytes = Data(repeating: 0x83, count: 300)
        let secondBytes = Data(repeating: 0x84, count: 517)
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-preprocess-source-\(UUID().uuidString).heic"
        )
        try firstBytes.write(to: firstURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: firstURL) }
        let job = LocalMediaPreprocessingJob(
            kind: .imageJPEG,
            sources: [LocalMediaOriginalSource(
                storageKey: firstSourceKey,
                mediaType: "image/heic",
                fileSize: firstBytes.count,
                duration: nil
            )],
            outputStorageKey: collidingSpoolID,
            outputMediaType: "image/jpeg"
        )
        let batch = try KitMediaMessageV2OutboundBatch.queued(
            attachments: [
                .init(
                    attachmentID: firstSourceKey,
                    mediaType: "image/jpeg",
                    plaintextByteSize: firstBytes.count,
                    localStorageKey: firstSourceKey
                ),
                .init(
                    attachmentID: secondSourceKey,
                    mediaType: "application/pdf",
                    plaintextByteSize: secondBytes.count,
                    localStorageKey: secondSourceKey
                ),
            ],
            rawCaption: "Two files",
            keyMaterialFactory: {
                Data(repeating: 0x83, count: SecureMediaAttachmentCipher.keyMaterialBytes)
            }
        )
        let store = try await makeStore(userID: localUserID)
        let existingMessageID = UUID()
        let existingRecord = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: collidingSpoolID,
            messageID: existingMessageID,
            conversationID: existingConversationID,
            mediaType: "application/pdf",
            fileSize: 1_024,
            localStorageKey: existingSourceKey,
            storesInline: false,
            now: Date(),
            localStorageKind: .protectedFile
        ))
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(userID: localUserID)
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            state.secureMessaging = crypto
            state.conversations = [conversationID, existingConversationID].map { id in
                Conversation(
                    id: id,
                    title: "Peer",
                    participantUserIds: [localUserID, recipientUserID],
                    unreadCount: 0,
                    updatedAt: Date()
                )
            }
            state.messages = [LocalMessage(
                id: existingMessageID,
                conversationId: existingConversationID,
                senderId: localUserID,
                body: "Existing document",
                createdAt: Date(),
                sentAt: nil,
                state: .queued,
                failureReason: nil,
                isOutgoing: true,
                pendingAttachment: LocalPendingAttachment(
                    mediaType: "application/pdf",
                    caption: nil,
                    localStorageKey: existingSourceKey,
                    byteCount: 1_024
                ),
                localMediaRecords: [existingRecord]
            )]
        }
        let blobs = InMemoryMediaBlobStore(
            seed: [secondSourceKey: secondBytes],
            protectedFiles: [firstSourceKey: firstURL]
        )
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: OfflineExchangeTransport(),
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(forUserID: localUserID)
        )

        do {
            _ = try await coordinator.queueDeferredMediaBatch(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "Peer",
                batch: batch,
                localStorageKinds: [.protectedFile, .encryptedBlob],
                preprocessingJobs: [job, nil]
            )
            XCTFail("a preprocessing output cannot alias another record's ciphertext-spool id")
        } catch {
            // Expected: no file/object key may gain a second durable owner.
        }

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertTrue(snapshot.outbox.isEmpty)
        XCTAssertEqual(snapshot.messages.first?.localMediaRecords?.first?.id, collidingSpoolID)
    }

    func testDeferredMediaBatchRejectsOutputAliasingSiblingAttachmentID() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000091"
        let recipientUserID = "10000000-0000-4000-8000-000000000092"
        let conversationID = "30000000-0000-4000-8000-000000000091"
        let firstAttachmentID = "70000000-0000-4000-8000-000000000091"
        let firstSourceKey = "70000000-0000-4000-8000-000000000092"
        let secondAttachmentID = "70000000-0000-4000-8000-000000000093"
        let secondSourceKey = "70000000-0000-4000-8000-000000000094"
        let job = LocalMediaPreprocessingJob(
            kind: .imageJPEG,
            sources: [LocalMediaOriginalSource(
                storageKey: firstSourceKey,
                mediaType: "image/heic",
                fileSize: 300,
                duration: nil
            )],
            outputStorageKey: secondAttachmentID,
            outputMediaType: "image/jpeg"
        )
        let batch = try KitMediaMessageV2OutboundBatch.queued(
            attachments: [
                .init(
                    attachmentID: firstAttachmentID,
                    mediaType: "image/jpeg",
                    plaintextByteSize: 300,
                    localStorageKey: firstSourceKey
                ),
                .init(
                    attachmentID: secondAttachmentID,
                    mediaType: "application/pdf",
                    plaintextByteSize: 517,
                    localStorageKey: secondSourceKey
                ),
            ],
            rawCaption: nil,
            keyMaterialFactory: {
                Data(repeating: 0x91, count: SecureMediaAttachmentCipher.keyMaterialBytes)
            }
        )
        let store = try await makeStore(userID: localUserID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(userID: localUserID)
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "Peer",
                participantUserIds: [localUserID, recipientUserID],
                unreadCount: 0,
                updatedAt: Date()
            )]
        }
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: OfflineExchangeTransport(),
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: InMemoryMediaBlobStore(seed: [:]).access(forUserID: localUserID)
        )

        do {
            _ = try await coordinator.queueDeferredMediaBatch(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "Peer",
                batch: batch,
                localStorageKinds: [.protectedFile, .encryptedBlob],
                preprocessingJobs: [job, nil]
            )
            XCTFail("one item's output cannot alias a sibling attachment/spool identity")
        } catch {
            // Expected before any media read or durable queue mutation.
        }

        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
    }

    func testIdempotentMediaBatchRetryNeverDeletesAnotherDraftsParkedBytes() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000075"
        let recipientUserID = "10000000-0000-4000-8000-000000000076"
        let conversationID = "30000000-0000-4000-8000-000000000075"
        let otherConversationID = "30000000-0000-4000-8000-000000000076"
        let stableMessageID = UUID(uuidString: "80000000-0000-4000-8000-000000000075")!
        let originalKeys = [
            "70000000-0000-4000-8000-000000000075",
            "70000000-0000-4000-8000-000000000076",
        ]
        let retryKeys = [
            "70000000-0000-4000-8000-000000000077",
            "70000000-0000-4000-8000-000000000078",
        ]
        let payloads = [Data(repeating: 0x75, count: 300), Data(repeating: 0x76, count: 517)]
        func batch(keys: [String]) throws -> KitMediaMessageV2OutboundBatch {
            try KitMediaMessageV2OutboundBatch.queued(
                attachments: [
                    .init(
                        mediaType: "image/jpeg",
                        plaintextByteSize: payloads[0].count,
                        localStorageKey: keys[0]
                    ),
                    .init(
                        mediaType: "video/mp4",
                        plaintextByteSize: payloads[1].count,
                        localStorageKey: keys[1]
                    ),
                ],
                rawCaption: "Same logical batch",
                keyMaterialFactory: {
                    Data(repeating: 0x75, count: SecureMediaAttachmentCipher.keyMaterialBytes)
                }
            )
        }
        let originalBatch = try batch(keys: originalKeys)
        let replayBatch = try batch(keys: retryKeys)
        let store = try await makeStore(userID: localUserID)
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            var crypto = SecureMessagingPersistentState.empty
            crypto.enrollment = raceEnrollment(userID: localUserID)
            state.secureMessaging = crypto
            state.conversations = [conversationID, otherConversationID].map { id in
                Conversation(
                    id: id,
                    title: "Peer",
                    participantUserIds: [localUserID, recipientUserID],
                    unreadCount: 0,
                    updatedAt: Date(timeIntervalSince1970: 1_755_604_800)
                )
            }
        }
        let blobs = InMemoryMediaBlobStore(seed: [
            originalKeys[0]: payloads[0], originalKeys[1]: payloads[1],
            retryKeys[0]: payloads[0], retryKeys[1]: payloads[1],
        ])
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: OfflineExchangeTransport(),
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(forUserID: localUserID)
        )
        _ = try await coordinator.queueDeferredMediaBatch(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "Peer",
            batch: originalBatch,
            clientMessageID: stableMessageID
        )
        let draftAttachment = ConversationDraftMediaAttachment(
            id: UUID(uuidString: retryKeys[0])!,
            storageKind: .encryptedBlob,
            mediaType: "image/jpeg",
            originalMediaType: nil,
            byteCount: payloads[0].count,
            displayName: "Still composing.jpg",
            duration: nil,
            acceptedAt: Date(),
            clientMessageID: nil,
            preprocessingOutputStorageKey: nil
        )
        try await store.update { state in
            state.conversationDrafts = [
                otherConversationID: ConversationDraft(
                    body: "Still composing",
                    updatedAt: Date(),
                    writeVersion: ConversationDraftWriteVersion(
                        writerID: UUID(),
                        sequence: 1
                    ),
                    mediaAttachments: [draftAttachment]
                ),
            ]
        }

        do {
            _ = try await coordinator.queueDeferredMediaBatch(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "Peer",
                batch: replayBatch,
                clientMessageID: stableMessageID
            )
            XCTFail("idempotent replay must not consume storage owned by another draft")
        } catch {
            // Expected: fail closed rather than delete a live draft's bytes as retry scratch.
        }

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.outbox.count, 1)
        XCTAssertEqual(snapshot.conversationDrafts?[otherConversationID]?.mediaAttachments, [draftAttachment])
        let retainedKeys = await blobs.storageKeys()
        XCTAssertEqual(
            retainedKeys,
            Set(originalKeys + retryKeys)
        )
    }

    /// Flush end-to-end up to the send boundary: the fresh capabilities+roster admission gate
    /// passes, every item uploads exactly once in ascending attachment-id order, and one
    /// KITMEDIA2 descriptor carrying the caption becomes the durable body — all before any
    /// send POST. A relaunch-style second flush replays from the sealed body without
    /// re-uploading a single byte.
    func testDeferredMediaBatchFlushUploadsInAscendingIDOrderAndSealsOneDescriptorBeforeAnySend() async throws {
        let fixture = try await makeMediaBatchFlushFixture(mediaMessageEnabled: true)
        let queuedSnapshot = await fixture.store.snapshot()
        let commandID = try XCTUnwrap(queuedSnapshot.outbox.first?.id)

        do {
            _ = try await fixture.coordinator.prepareDeferredMessage(
                commandID: commandID,
                forUserID: fixture.userID
            )
            XCTFail("The injected roster outage must stop the flush after the durable seal")
        } catch let error as APIErrorPayload {
            XCTAssertEqual(error.code, "MESSAGING_TEMPORARILY_UNAVAILABLE")
        }

        // §5: ciphertext left the device once per item, ordered by ascending attachment id —
        // computed here independently of the production upload-order helper.
        let uploads = await fixture.transport.uploadedItems()
        let expectedUploadOrder = fixture.batch.items
            .sorted { $0.attachmentID < $1.attachmentID }
            .map(\.mediaType)
        XCTAssertEqual(uploads.map(\.mediaType), expectedUploadOrder)
        XCTAssertEqual(
            uploads.map(\.clientMediaID),
            fixture.batch.items.sorted { $0.attachmentID < $1.attachmentID }
                .map(\.attachmentID)
        )
        XCTAssertEqual(uploads.count, 2)

        let sealedSnapshot = await fixture.store.snapshot()
        XCTAssertEqual(sealedSnapshot.messages.count, 1)
        XCTAssertEqual(sealedSnapshot.outbox.count, 1)
        let message = try XCTUnwrap(sealedSnapshot.messages.first)
        let command = try XCTUnwrap(sealedSnapshot.outbox.first)
        XCTAssertEqual(message.id, fixture.queued.clientMessageID)
        XCTAssertEqual(command.messageId, fixture.queued.clientMessageID)
        XCTAssertNil(message.pendingMediaBatch)
        XCTAssertNil(command.secureMessageFanout)
        // Exactly one sealed descriptor: same caption, both items in display order, and the
        // exact server-issued upload triples the transport returned.
        let sealed = try XCTUnwrap(KitMediaMessageV2Descriptor.parse(message.body))
        XCTAssertEqual(sealed.caption, fixture.caption)
        XCTAssertEqual(sealed.items.map(\.mediaType), fixture.batch.items.map(\.mediaType))
        XCTAssertEqual(
            Set(sealed.items.map { "\($0.storageKey)|\($0.ciphertextByteSize)|\($0.ciphertextSHA256)" }),
            Set(uploads.map { "\($0.storageKey)|\($0.byteSize)|\($0.ciphertextSha256)" })
        )
        XCTAssertEqual(
            KitMediaMessageFamilyPolicy.attachmentRequests(for: message.body).count,
            2,
            "the sealed body alone must yield the canonical outer rows"
        )
        let sendsAfterSeal = await fixture.transport.sendCount()
        XCTAssertEqual(sendsAfterSeal, 0)
        // Checkpointing adds a server-keyed copy but retains each permanent sender original.
        let survivingKeys = await fixture.blobs.storageKeys()
        XCTAssertEqual(
            survivingKeys,
            Set(uploads.map(\.storageKey))
                .union(fixture.batch.items.map(\.localStorageKey))
        )

        // Crash-resume: the sealed body is sufficient; nothing uploads twice.
        do {
            _ = try await fixture.coordinator.prepareDeferredMessage(
                commandID: commandID,
                forUserID: fixture.userID
            )
            XCTFail("The injected roster outage must remain active on the resume pass")
        } catch let error as APIErrorPayload {
            XCTAssertEqual(error.code, "MESSAGING_TEMPORARILY_UNAVAILABLE")
        }
        let uploadsAfterResume = await fixture.transport.uploadedItems()
        XCTAssertEqual(uploadsAfterResume.count, 2)
        let resumed = await fixture.store.snapshot()
        XCTAssertEqual(resumed.messages.first?.body, message.body)
        let sendsAfterResume = await fixture.transport.sendCount()
        XCTAssertEqual(sendsAfterResume, 0)
    }

    func testDeferredMediaBatchRejectsMismatchedClientMediaIDEcho() async throws {
        let fixture = try await makeMediaBatchFlushFixture(
            mediaMessageEnabled: true,
            echoesMismatchedClientMediaID: true
        )
        let queuedSnapshot = await fixture.store.snapshot()
        let commandID = try XCTUnwrap(queuedSnapshot.outbox.first?.id)

        do {
            _ = try await fixture.coordinator.prepareDeferredMessage(
                commandID: commandID,
                forUserID: fixture.userID
            )
            XCTFail("A mismatched upload identity echo must fail closed")
        } catch SecureMediaAttachmentError.serverMetadataMismatch {
            // Expected.
        }

        let uploads = await fixture.transport.uploadedItems()
        XCTAssertEqual(uploads.count, 1)
        let snapshot = await fixture.store.snapshot()
        XCTAssertNotNil(snapshot.messages.first?.pendingMediaBatch)
        XCTAssertNil(KitMediaMessageV2Descriptor.parse(snapshot.messages.first?.body ?? ""))
        let survivingKeys = await fixture.blobs.storageKeys()
        XCTAssertEqual(
            survivingKeys,
            Set(fixture.batch.items.map(\.localStorageKey))
        )
    }

    /// §6/§7 fail-closed: a capabilities document without the v2 feature makes the flush-time
    /// admission gate refuse the whole message before any upload — never splitting it, never
    /// downgrading it — and the queued projection survives untouched for a later retry.
    func testDeferredMediaBatchFlushFailsClosedBeforeAnyUploadWhenCapabilityIsWithdrawn() async throws {
        let fixture = try await makeMediaBatchFlushFixture(mediaMessageEnabled: false)
        let queuedSnapshot = await fixture.store.snapshot()
        let commandID = try XCTUnwrap(queuedSnapshot.outbox.first?.id)
        let queuedMessage = try XCTUnwrap(queuedSnapshot.messages.first)
        let queuedCommand = try XCTUnwrap(queuedSnapshot.outbox.first)

        do {
            _ = try await fixture.coordinator.prepareDeferredMessage(
                commandID: commandID,
                forUserID: fixture.userID
            )
            XCTFail("A withdrawn v2 capability must fail the whole message closed")
        } catch SecureMessagingExchangeError.mediaMessageCapabilityUnavailable {
            // Expected: the atomic admission gate answered no before any side effect.
        }

        let uploadCount = await fixture.transport.uploadCount()
        XCTAssertEqual(uploadCount, 0)
        let sendCount = await fixture.transport.sendCount()
        XCTAssertEqual(sendCount, 0)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.messages, [queuedMessage])
        XCTAssertEqual(snapshot.outbox, [queuedCommand])
        XCTAssertEqual(queuedMessage.body, fixture.caption)
        XCTAssertEqual(queuedMessage.pendingMediaBatch, fixture.batch)
        let survivingKeys = await fixture.blobs.storageKeys()
        XCTAssertEqual(
            survivingKeys,
            Set(fixture.batch.items.map(\.localStorageKey)),
            "every parked plaintext must survive a refused flush"
        )
    }

    /// §6's roster leg of the same atomic gate, distinct from the server-flag leg above: the
    /// server advertises the feature and a coherent media_message block, but one recipient
    /// device in the fresh roster does not attest the v2 device capability. Admission is
    /// unanimous, so the flush must fail closed with the identical zero-side-effect guarantee —
    /// exactly zero attachment uploads and zero send POSTs, the queued message and command
    /// byte-identical, and every parked plaintext surviving — after actually consulting the
    /// roster (one fetch), proving the refusal came from the incompatible roster and the
    /// message was never split or downgraded for the capable devices.
    func testDeferredMediaBatchFlushFailsClosedWithZeroUploadsAndZeroSendsWhenARosterDeviceLacksV2() async throws {
        let fixture = try await makeMediaBatchFlushFixture(
            mediaMessageEnabled: true,
            recipientDeviceSupportsMediaMessageV2: false
        )
        let queuedSnapshot = await fixture.store.snapshot()
        let commandID = try XCTUnwrap(queuedSnapshot.outbox.first?.id)
        let queuedMessage = try XCTUnwrap(queuedSnapshot.messages.first)
        let queuedCommand = try XCTUnwrap(queuedSnapshot.outbox.first)

        do {
            _ = try await fixture.coordinator.prepareDeferredMessage(
                commandID: commandID,
                forUserID: fixture.userID
            )
            XCTFail("A roster with a v2-incapable device must fail the whole message closed")
        } catch SecureMessagingExchangeError.mediaMessageCapabilityUnavailable {
            // Expected: the unanimous roster attestation answered no before any side effect.
        }

        let rosterCallCount = await fixture.transport.rosterCallCount()
        XCTAssertEqual(rosterCallCount, 1, "the refusal must come from a consulted fresh roster")
        let uploadCount = await fixture.transport.uploadCount()
        XCTAssertEqual(uploadCount, 0)
        let sendCount = await fixture.transport.sendCount()
        XCTAssertEqual(sendCount, 0)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.messages, [queuedMessage])
        XCTAssertEqual(snapshot.outbox, [queuedCommand])
        XCTAssertEqual(queuedMessage.body, fixture.caption)
        XCTAssertEqual(queuedMessage.pendingMediaBatch, fixture.batch)
        let survivingKeys = await fixture.blobs.storageKeys()
        XCTAssertEqual(
            survivingKeys,
            Set(fixture.batch.items.map(\.localStorageKey)),
            "every parked plaintext must survive a refused flush"
        )
    }

    /// The send boundary: one committed fanout for a sealed KITMEDIA2 body becomes exactly one
    /// send POST whose client_message_id is the LocalMessage id, whose attachment rows are the
    /// §5 canonical outer rows (ascending id, not display order), and whose encoded bytes carry
    /// neither the caption nor any attachment key material.
    func testSealedMediaBatchSendPostsExactlyOnceWithCanonicalRowsAndNoCaptionOnTheWire() async throws {
        let userID = "10000000-0000-4000-8000-000000000045"
        let recipientUserID = "10000000-0000-4000-8000-000000000046"
        let localDeviceID = "20000000-0000-4000-8000-000000000045"
        let recipientDeviceID = "20000000-0000-4000-8000-000000000046"
        let conversationID = "30000000-0000-4000-8000-000000000045"
        let clientMessageID = "80000000-0000-4000-8000-000000000045"
        let rosterRevision = "v1:sha256:\(String(repeating: "d", count: 64))"
        let caption = "Caption stays inside the sealed descriptor"
        let createdAt = Date(timeIntervalSince1970: 1_755_604_800)
        // Display order deliberately reverses the canonical outer order.
        let displayedFirst = KitMediaMessageV2Descriptor.Item(
            attachmentID: "22222222-2222-4222-8222-222222222222",
            storageKey: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            mediaType: "video/mp4",
            ciphertextByteSize: Int64(2_097_152 + 64 - (2_097_152 % 16)),
            ciphertextSHA256: "fedcba" + String(repeating: "2", count: 58),
            keyMaterial: Data(repeating: 0x42, count: 64),
            plaintextByteSize: 2_097_152
        )
        let displayedSecond = KitMediaMessageV2Descriptor.Item(
            attachmentID: "11111111-1111-4111-8111-111111111111",
            storageKey: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            mediaType: "image/jpeg",
            ciphertextByteSize: Int64(1_048_576 + 64 - (1_048_576 % 16)),
            ciphertextSHA256: "abcdef" + String(repeating: "1", count: 58),
            keyMaterial: Data(repeating: 0x41, count: 64),
            plaintextByteSize: 1_048_576
        )
        let descriptor = try XCTUnwrap(KitMediaMessageV2Descriptor(
            items: [displayedFirst, displayedSecond],
            caption: caption
        ))
        let expectedRows = try XCTUnwrap(descriptor.attachmentRequests)
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
            body: descriptor.encoded,
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true
        )
        let command = OfflineCommand(
            id: UUID(uuidString: "90000000-0000-4000-8000-000000000045")!,
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
        crypto.enrollment = raceEnrollment(userID: userID, serverDeviceID: localDeviceID)
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
        let serverMessageID = "70000000-0000-4000-8000-000000000045"
        let transport = RecordingMediaSendTransport { request in
            EncryptedMessageDTO(
                id: serverMessageID,
                conversationId: conversationID,
                clientMessageId: request.clientMessageId,
                sender: EncryptedMessageSenderDTO(id: userID, name: "Secure User"),
                senderDeviceId: localDeviceID,
                senderEnrollmentEpoch: 1,
                senderSignalDeviceId: 1,
                senderRegistrationId: 42,
                senderProtocolVersion: SecureMessagingWire.protocolVersion,
                senderBundleVersion: 1,
                senderIdentityKeySha256: String(repeating: "a", count: 64),
                rosterRevision: request.rosterRevision,
                kind: request.kind.rawValue,
                replyToMessageId: request.replyToMessageId,
                envelope: nil,
                attachments: request.attachments.map {
                    EncryptedAttachmentDTO(
                        id: $0.id,
                        storageKey: $0.storageKey,
                        mediaType: $0.mediaType,
                        byteSize: $0.byteSize,
                        ciphertextSha256: $0.ciphertextSha256,
                        encryptionMetadataCiphertext: nil
                    )
                },
                reactions: [],
                sentAt: "2026-08-19T12:00:15Z",
                revokedAt: nil
            )
        }
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )

        _ = try await coordinator.sendQueuedMessage(commandID: command.id, forUserID: userID)

        let requests = await transport.sentRequests()
        XCTAssertEqual(requests.count, 1, "one committed fanout is exactly one send POST")
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.clientMessageId, clientMessageID)
        XCTAssertEqual(request.kind, .encryptedAttachment)
        XCTAssertEqual(request.rosterRevision, rosterRevision)
        XCTAssertEqual(request.attachments, expectedRows)
        XCTAssertEqual(
            request.attachments.map(\.id),
            [
                "11111111-1111-4111-8111-111111111111",
                "22222222-2222-4222-8222-222222222222",
            ],
            "outer rows ride in canonical ascending-id order, not display order"
        )
        XCTAssertEqual(request.envelopes.count, 1)
        let conversationIDs = await transport.sentConversationIDs()
        XCTAssertEqual(conversationIDs, [conversationID])
        // Leak fence: the caption and every attachment key travel only inside the encrypted
        // descriptor; the outer request must carry none of those bytes.
        let wireBytes = try JSONEncoder().encode(request)
        let wireText = try XCTUnwrap(String(data: wireBytes, encoding: .utf8))
        XCTAssertFalse(wireText.contains(caption))
        XCTAssertFalse(wireText.contains("KITMEDIA2"))
        XCTAssertFalse(wireText.contains(Data(repeating: 0x41, count: 64).base64EncodedString()))
        XCTAssertFalse(wireText.contains(Data(repeating: 0x42, count: 64).base64EncodedString()))

        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.outbox.isEmpty)
        let sent = try XCTUnwrap(snapshot.messages.first)
        XCTAssertEqual(sent.state, .sent)
        XCTAssertEqual(sent.serverMessageId, serverMessageID)
        XCTAssertEqual(sent.body, descriptor.encoded, "the sealed body survives the send verbatim")
    }

    func testExpiredSingleMediaReferenceReopensSameIdentityAndRetainedOriginal() async throws {
        let userID = "10000000-0000-4000-8000-000000000055"
        let recipientUserID = "10000000-0000-4000-8000-000000000056"
        let conversationID = "30000000-0000-4000-8000-000000000055"
        let clientMessageID = "80000000-0000-4000-8000-000000000055"
        let mediaID = "40000000-0000-4000-8000-000000000055"
        let expiredStorageKey = "50000000-0000-4000-8000-000000000055"
        let keyMaterial = Data(repeating: 0x5a, count: SecureMediaAttachmentCipher.keyMaterialBytes)
        let plaintext = Data(repeating: 0x41, count: 300)
        let ciphertextSize = Int64(plaintext.count + 64 - (plaintext.count % 16))
        let descriptor = try KitMediaMessageDescriptor(
            attachmentID: mediaID,
            storageKey: expiredStorageKey,
            mediaType: "image/jpeg",
            ciphertextByteSize: ciphertextSize,
            ciphertextSHA256: String(repeating: "a", count: 64),
            keyMaterial: keyMaterial,
            plaintextByteSize: plaintext.count,
            caption: "Receipt"
        )
        let createdAt = Date(timeIntervalSince1970: 1_755_604_800)
        let record = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: mediaID,
            messageID: UUID(uuidString: clientMessageID)!,
            conversationID: conversationID,
            mediaType: descriptor.mediaType,
            fileSize: plaintext.count,
            localStorageKey: mediaID,
            storesInline: false,
            now: createdAt,
            outboundKeyMaterial: keyMaterial,
            localStorageKind: .encryptedBlob
        ))
        var staged = LocalMessage(
            id: UUID(uuidString: clientMessageID)!,
            conversationId: conversationID,
            senderId: userID,
            body: "Receipt",
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(
                mediaType: descriptor.mediaType,
                caption: descriptor.caption,
                localStorageKey: mediaID,
                byteCount: plaintext.count
            ),
            localMediaRecords: [record]
        )
        XCTAssertTrue(LocalMediaRecordPolicy.markUploading(&staged, attachmentID: mediaID))
        XCTAssertTrue(LocalMediaRecordPolicy.markUploaded(
            &staged,
            attachmentID: mediaID,
            remoteStorageKey: expiredStorageKey
        ))
        staged.body = descriptor.encoded
        staged.pendingAttachment = nil

        let fanout = SecureMessagingCommittedFanout(
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            rosterRevision: "v1:sha256:\(String(repeating: "d", count: 64))",
            replyToMessageID: nil,
            rosterDevices: [],
            envelopes: [SecureMessagingOutboundEnvelope(
                recipientDeviceID: "20000000-0000-4000-8000-000000000056",
                envelopeType: SecureMessagingEnvelopeType.message.rawValue,
                ciphertext: Data([1, 2, 3])
            )]
        )
        let command = OfflineCommand(
            id: UUID(uuidString: "90000000-0000-4000-8000-000000000055")!,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: staged.id,
            recipientUserIds: [recipientUserID],
            recipientName: "Peer",
            video: nil,
            expiresAt: nil,
            secureMessageFanout: fanout
        )
        let store = try await makeStore(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.conversations = [Conversation(
                id: conversationID,
                title: "Peer",
                participantUserIds: [userID, recipientUserID],
                unreadCount: 0,
                updatedAt: createdAt
            )]
            state.messages = [staged]
            state.outbox = [command]
        }
        let blobs = InMemoryMediaBlobStore(seed: [
            mediaID: plaintext,
            expiredStorageKey: plaintext,
        ])
        let transport = RecordingMediaSendTransport { _ in
            throw APIErrorPayload(
                code: "ATTACHMENT_REFERENCE_INVALID",
                message: "The attachment expired.",
                httpStatus: 422
            )
        }
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(forUserID: userID)
        )

        do {
            _ = try await coordinator.sendQueuedMessage(commandID: command.id, forUserID: userID)
            XCTFail("an expired attachment reference must reopen instead of being accepted")
        } catch SecureMessagingExchangeError.mediaMessageBlobExpired {
            // Expected: the outbox owner schedules the same command for another flush.
        }

        let reopenedState = await store.snapshot()
        let reopenedMessage = try XCTUnwrap(reopenedState.messages.first)
        let reopenedCommand = try XCTUnwrap(reopenedState.outbox.first)
        let reopenedRecord = try XCTUnwrap(reopenedMessage.localMediaRecords?.first)
        XCTAssertEqual(reopenedMessage.id, staged.id)
        XCTAssertEqual(reopenedMessage.body, "Receipt")
        XCTAssertEqual(reopenedMessage.pendingAttachment?.localStorageKey, mediaID)
        XCTAssertEqual(reopenedMessage.pendingAttachment?.byteCount, plaintext.count)
        XCTAssertNil(reopenedCommand.secureMessageFanout)
        XCTAssertEqual(reopenedRecord.id, mediaID)
        XCTAssertEqual(reopenedRecord.localStorageKey, mediaID)
        XCTAssertEqual(reopenedRecord.outboundKeyMaterialBase64, descriptor.keyMaterialBase64)
        XCTAssertNil(reopenedRecord.remoteEncryptedObjectID)
        XCTAssertEqual(reopenedRecord.uploadState, .pending)
        XCTAssertEqual(reopenedRecord.encryptionState, .pending)
        XCTAssertTrue(reopenedRecord.isStructurallyValid)
        let retainedOriginal = await blobs.read(mediaID)
        let orphanedExpiredCopy = await blobs.read(expiredStorageKey)
        XCTAssertEqual(retainedOriginal, plaintext)
        // The state mutation has released this key, but deletion is deliberately deferred to the
        // age-gated orphan sweep so a concurrent writer cannot claim it during the CAS suspension.
        XCTAssertEqual(orphanedExpiredCopy, plaintext)
    }

    func testExpiredBatchReferencesRebindToRetainedOriginalsWithoutChangingIdentity() async throws {
        let userID = "10000000-0000-4000-8000-000000000065"
        let recipientUserID = "10000000-0000-4000-8000-000000000066"
        let conversationID = "30000000-0000-4000-8000-000000000065"
        let clientMessageID = "80000000-0000-4000-8000-000000000065"
        let firstMediaID = "11111111-1111-4111-8111-111111111165"
        let secondMediaID = "22222222-2222-4222-8222-222222222265"
        let firstExpiredKey = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa65"
        let secondExpiredKey = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb65"
        let firstPlaintext = Data(repeating: 0x31, count: 301)
        let secondPlaintext = Data(repeating: 0x32, count: 514)
        let firstKey = Data(repeating: 0x61, count: SecureMediaAttachmentCipher.keyMaterialBytes)
        let secondKey = Data(repeating: 0x62, count: SecureMediaAttachmentCipher.keyMaterialBytes)
        func ciphertextSize(_ plaintextSize: Int) -> Int64 {
            Int64(plaintextSize + 64 - (plaintextSize % 16))
        }
        let descriptor = try XCTUnwrap(KitMediaMessageV2Descriptor(
            items: [
                KitMediaMessageV2Descriptor.Item(
                    attachmentID: firstMediaID,
                    storageKey: firstExpiredKey,
                    mediaType: "image/jpeg",
                    ciphertextByteSize: ciphertextSize(firstPlaintext.count),
                    ciphertextSHA256: String(repeating: "a", count: 64),
                    keyMaterial: firstKey,
                    plaintextByteSize: firstPlaintext.count
                ),
                KitMediaMessageV2Descriptor.Item(
                    attachmentID: secondMediaID,
                    storageKey: secondExpiredKey,
                    mediaType: "application/pdf",
                    ciphertextByteSize: ciphertextSize(secondPlaintext.count),
                    ciphertextSHA256: String(repeating: "b", count: 64),
                    keyMaterial: secondKey,
                    plaintextByteSize: secondPlaintext.count
                ),
            ],
            caption: "Two retained originals"
        ))
        let createdAt = Date(timeIntervalSince1970: 1_755_604_800)
        let messageUUID = try XCTUnwrap(UUID(uuidString: clientMessageID))
        let firstRecord = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: firstMediaID,
            messageID: messageUUID,
            conversationID: conversationID,
            mediaType: descriptor.items[0].mediaType,
            fileSize: firstPlaintext.count,
            localStorageKey: firstMediaID,
            storesInline: false,
            now: createdAt,
            outboundKeyMaterial: firstKey,
            localStorageKind: .encryptedBlob
        ))
        let secondRecord = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: secondMediaID,
            messageID: messageUUID,
            conversationID: conversationID,
            mediaType: descriptor.items[1].mediaType,
            fileSize: secondPlaintext.count,
            localStorageKey: secondMediaID,
            storesInline: false,
            now: createdAt,
            outboundKeyMaterial: secondKey,
            localStorageKind: .encryptedBlob
        ))
        var staged = LocalMessage(
            id: messageUUID,
            conversationId: conversationID,
            senderId: userID,
            body: descriptor.encoded,
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            localMediaRecords: [firstRecord, secondRecord]
        )
        for item in descriptor.items {
            XCTAssertTrue(LocalMediaRecordPolicy.markUploading(
                &staged,
                attachmentID: item.attachmentID
            ))
            XCTAssertTrue(LocalMediaRecordPolicy.markUploaded(
                &staged,
                attachmentID: item.attachmentID,
                remoteStorageKey: item.storageKey
            ))
        }
        let fanout = SecureMessagingCommittedFanout(
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            rosterRevision: "v1:sha256:\(String(repeating: "d", count: 64))",
            replyToMessageID: nil,
            rosterDevices: [],
            envelopes: [SecureMessagingOutboundEnvelope(
                recipientDeviceID: "20000000-0000-4000-8000-000000000066",
                envelopeType: SecureMessagingEnvelopeType.message.rawValue,
                ciphertext: Data([1, 2, 3])
            )]
        )
        let command = OfflineCommand(
            id: UUID(uuidString: "90000000-0000-4000-8000-000000000065")!,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: staged.id,
            recipientUserIds: [recipientUserID],
            recipientName: "Peer",
            video: nil,
            expiresAt: nil,
            secureMessageFanout: fanout
        )
        let store = try await makeStore(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.conversations = [Conversation(
                id: conversationID,
                title: "Peer",
                participantUserIds: [userID, recipientUserID],
                unreadCount: 0,
                updatedAt: createdAt
            )]
            state.messages = [staged]
            state.outbox = [command]
        }
        let blobs = InMemoryMediaBlobStore(seed: [
            firstMediaID: firstPlaintext,
            secondMediaID: secondPlaintext,
            firstExpiredKey: firstPlaintext,
            secondExpiredKey: secondPlaintext,
        ])
        let transport = RecordingMediaSendTransport { _ in
            throw APIErrorPayload(
                code: "ATTACHMENT_REFERENCE_INVALID",
                message: "The attachments expired.",
                httpStatus: 422
            )
        }
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(forUserID: userID)
        )

        do {
            _ = try await coordinator.sendQueuedMessage(commandID: command.id, forUserID: userID)
            XCTFail("expired batch references must reopen rather than be accepted")
        } catch SecureMessagingExchangeError.mediaMessageBlobExpired {
            // Expected: the same command will retry the same logical message and media ids.
        }

        let reopenedState = await store.snapshot()
        let reopenedMessage = try XCTUnwrap(reopenedState.messages.first)
        let reopenedCommand = try XCTUnwrap(reopenedState.outbox.first)
        let reopenedBatch = try XCTUnwrap(reopenedMessage.pendingMediaBatch)
        XCTAssertEqual(reopenedMessage.id, staged.id)
        XCTAssertEqual(reopenedMessage.body, descriptor.caption)
        XCTAssertNil(reopenedCommand.secureMessageFanout)
        XCTAssertEqual(reopenedBatch.items.map(\.attachmentID), descriptor.items.map(\.attachmentID))
        XCTAssertEqual(reopenedBatch.items.map(\.localStorageKey), [firstMediaID, secondMediaID])
        XCTAssertTrue(reopenedBatch.items.allSatisfy { !$0.isUploaded })
        let reopenedRecords = try XCTUnwrap(reopenedMessage.localMediaRecords)
        XCTAssertEqual(reopenedRecords.map(\.id), [firstMediaID, secondMediaID])
        XCTAssertTrue(reopenedRecords.allSatisfy {
            $0.remoteEncryptedObjectID == nil
                && $0.uploadState == .pending
                && $0.encryptionState == .pending
                && $0.availabilityState == .localOriginal
                && $0.isStructurallyValid
        })
        let retainedFirst = await blobs.read(firstMediaID)
        let retainedSecond = await blobs.read(secondMediaID)
        let orphanedFirstRemoteCopy = await blobs.read(firstExpiredKey)
        let orphanedSecondRemoteCopy = await blobs.read(secondExpiredKey)
        XCTAssertEqual(retainedFirst, firstPlaintext)
        XCTAssertEqual(retainedSecond, secondPlaintext)
        // Reopening releases both keys atomically. Their bytes stay until the age-gated orphan
        // sweep, avoiding an inline-delete race with a draft or queue writer claiming either key.
        XCTAssertEqual(orphanedFirstRemoteCopy, firstPlaintext)
        XCTAssertEqual(orphanedSecondRemoteCopy, secondPlaintext)
    }

    /// Shared setup for the flush-stage tests: a queued two-item batch with caption, a real
    /// provisioned enrollment (activation must succeed), an in-memory blob store holding both
    /// parked plaintexts, and a transport whose roster answers once — enough for the flush-time
    /// admission gate — then fails 503 so the pipeline stops deterministically after the seal,
    /// before Signal session work that would need real recipient key material.
    private func makeMediaBatchFlushFixture(
        mediaMessageEnabled: Bool,
        recipientDeviceSupportsMediaMessageV2: Bool = true,
        echoesMismatchedClientMediaID: Bool = false
    ) async throws -> MediaBatchFlushFixture {
        let localUserID = "10000000-0000-4000-8000-000000000041"
        let recipientUserID = "10000000-0000-4000-8000-000000000042"
        let localDeviceID = "20000000-0000-0000-0000-000000000001"
        let recipientDeviceID = "20000000-0000-4000-8000-000000000042"
        let conversationID = "30000000-0000-4000-8000-000000000041"
        let caption = "Family dinner receipts"
        let firstParkKey = "70000000-0000-4000-8000-000000000041"
        let secondParkKey = "70000000-0000-4000-8000-000000000042"
        let firstPlaintext = Data((0 ..< 300).map { UInt8($0 % 251) })
        let secondPlaintext = Data((0 ..< 517).map { UInt8(($0 * 7) % 251) })
        let blobs = InMemoryMediaBlobStore(seed: [
            firstParkKey: firstPlaintext,
            secondParkKey: secondPlaintext,
        ])
        var keyByte: UInt8 = 0x50
        let batch = try KitMediaMessageV2OutboundBatch.queued(
            attachments: [
                .init(
                    mediaType: "image/jpeg",
                    plaintextByteSize: firstPlaintext.count,
                    localStorageKey: firstParkKey
                ),
                .init(
                    mediaType: "video/mp4",
                    plaintextByteSize: secondPlaintext.count,
                    localStorageKey: secondParkKey
                ),
            ],
            rawCaption: caption,
            keyMaterialFactory: {
                keyByte += 1
                return Data(repeating: keyByte, count: 64)
            }
        )
        let store = try await makeStore(userID: localUserID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let status = enrolledStatus(bundle: provisioned.bundle)
        let binding = try SecureMessagingMapper.enrollmentBinding(
            from: status,
            userID: localUserID
        )
        let enrolled = try await engine.bindEnrollment(binding, to: provisioned.state)
        try await store.update { state in
            state.secureMessaging = enrolled
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [localUserID, recipientUserID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_755_604_800)
            )]
        }
        let transport = MediaBatchFlushTransport(
            status: status,
            conversation: directConversationDTO(
                id: conversationID,
                userID: localUserID,
                peerID: recipientUserID,
                peerName: "ExampleContact"
            ),
            capabilitiesDocument: try mediaMessageCapabilitiesDocument(
                enabled: mediaMessageEnabled
            ),
            roster: try mediaBatchRoster(conversationID: conversationID, rows: [
                mediaBatchDeviceRow(deviceID: localDeviceID, userID: localUserID),
                mediaBatchDeviceRow(
                    deviceID: recipientDeviceID,
                    userID: recipientUserID,
                    supportsMediaMessageV2: recipientDeviceSupportsMediaMessageV2
                ),
            ]),
            echoesMismatchedClientMediaID: echoesMismatchedClientMediaID
        )
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1,
            mediaBlobs: blobs.access(forUserID: localUserID)
        )
        let queued = try await coordinator.queueDeferredMediaBatch(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            batch: batch
        )
        return MediaBatchFlushFixture(
            userID: localUserID,
            caption: caption,
            batch: batch,
            store: store,
            coordinator: coordinator,
            transport: transport,
            blobs: blobs,
            queued: queued
        )
    }

    /// The §6 capabilities document, coherent and enabled — or with the feature withdrawn
    /// entirely, which the gate must read as an unavailable capability, not an error.
    private func mediaMessageCapabilitiesDocument(enabled: Bool) throws -> CapabilitiesDTO {
        var messaging: [String: Any] = [
            "ready": true,
            "version": SecureMessagingWire.protocolVersion,
            "suite": SecureMessagingWire.protocolSuite,
            "post_quantum": true,
            "rich_media": [
                "ready": true,
                "profile": MessagingRichMediaCapabilityPolicy.profile,
                "supported_platforms": ["ios"],
                "minimum_ios_version": MessagingRichMediaCapabilityPolicy.minimumIOSRelease,
                "minimum_ciphertext_bytes": SecureMessagingWire.minimumAttachmentCiphertextBytes,
                "maximum_plaintext_bytes": SecureMediaAttachmentCipher.maximumPlaintextBytes,
                "maximum_ciphertext_bytes": SecureMessagingWire.maximumAttachmentCiphertextBytes,
                "large_attachment_capability": MessagingRichMediaCapabilityPolicy
                    .extendedSizeDeviceCapabilityKey,
                "large_attachment_supported_platforms": ["ios"],
                "large_attachment_minimum_ios_version": MessagingRichMediaCapabilityPolicy
                    .extendedSizeMinimumIOSRelease,
                "media_types": SecureMessagingWire.allowedAttachmentMediaTypes.sorted(),
            ],
        ]
        var features: [String: Any] = [:]
        if enabled {
            features[MessagingMediaMessageV2CapabilityPolicy.featureKey] = true
            let coherentBlock: [String: Any] = [
                "profile": MessagingMediaMessageV2CapabilityPolicy.profile,
                "ready": true,
                "max_attachments": KitMediaMessageV2Descriptor.maximumAttachmentCount,
                "max_descriptor_bytes": KitMediaMessageV2Descriptor.maximumDescriptorUTF8Bytes,
                "max_caption_utf8_bytes": KitMediaMessageV2Descriptor.maximumCaptionUTF8Bytes,
                "min_attachment_ciphertext_bytes":
                    KitMediaMessageV2Descriptor.minimumAttachmentCiphertextBytes,
                "max_attachment_ciphertext_bytes":
                    KitMediaMessageV2Descriptor.maximumAttachmentCiphertextBytes,
                "max_aggregate_ciphertext_bytes":
                    KitMediaMessageV2Descriptor.maximumAggregateCiphertextBytes,
            ]
            messaging["media_message"] = coherentBlock
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "api_version": "v1",
            "currency": ["code": "UGX", "scale": "2"],
            "features": features,
            "protocols": ["messaging": messaging],
        ])
        return try JSONDecoder().decode(CapabilitiesDTO.self, from: data)
    }

    private func mediaBatchDeviceRow(
        deviceID: String,
        userID: String,
        supportsMediaMessageV2: Bool = true
    ) -> [String: Any] {
        let capabilities: [String: Bool] = [
            MessagingMediaMessageV2CapabilityPolicy.deviceCapabilityKey: supportsMediaMessageV2,
            MessagingRichMediaCapabilityPolicy.deviceCapabilityKey: true,
            MessagingRichMediaCapabilityPolicy.extendedSizeDeviceCapabilityKey: true,
        ]
        let client: [String: Any] = [
            "platform": "android",
            "version": "0.2.31",
            "capabilities": capabilities,
        ]
        return ["device_id": deviceID, "user_id": userID, "client": client]
    }

    private func mediaBatchRoster(
        conversationID: String,
        rows: [[String: Any]]
    ) throws -> MessagingDeviceRosterDTO {
        let data = try JSONSerialization.data(withJSONObject: [
            "conversation_id": conversationID,
            "devices": rows,
        ])
        return try JSONDecoder().decode(MessagingDeviceRosterDTO.self, from: data)
    }
}

private struct GroupRenameFixture {
    let userID: String
    let peerUserID: String
    let thirdUserID: String
    let conversationID: String
    let responseUpdatedAt: Date
    let initialConversation: Conversation
    let store: SecureLocalStore
    let coordinator: SecureMessagingExchangeCoordinator
    let transport: SuspendedGroupRenameTransport
}

private actor SuspendedGroupRenameTransport: SecureMessagingExchangeTransport {
    enum Result: Sendable {
        case success(MessagingConversationDTO)
        case failure
    }

    enum Failure: Error {
        case rejected
        case unexpectedNetworkCall
        case expectedRequestDidNotStart
    }

    private let conversationID: String
    private let expectedTitle: String
    private let roster: MessagingDeviceRosterDTO
    private let result: Result
    private var renameStarted = false
    private var renameReleased = false
    private var renameWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        conversationID: String,
        expectedTitle: String,
        roster: MessagingDeviceRosterDTO,
        result: Result
    ) {
        self.conversationID = conversationID
        self.expectedTitle = expectedTitle
        self.roster = roster
        self.result = result
    }

    func waitUntilRenameStarted() async throws {
        for _ in 0..<500 {
            if renameStarted { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.expectedRequestDidNotStart
    }

    func releaseRename() {
        renameReleased = true
        let waiters = renameWaiters
        renameWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func suspendRename() async {
        renameStarted = true
        if renameReleased { return }
        await withCheckedContinuation { continuation in
            renameWaiters.append(continuation)
        }
    }

    private func reject<T>() throws -> T { throw Failure.unexpectedNetworkCall }

    func renameGroupMessagingConversation(
        conversationId: String,
        title: String
    ) async throws -> MessagingConversationDTO {
        guard conversationId == conversationID, title == expectedTitle else {
            return try reject()
        }
        await suspendRename()
        switch result {
        case .success(let response): return response
        case .failure: throw Failure.rejected
        }
    }

    func messagingDeviceRoster(
        conversationId: String
    ) async throws -> MessagingDeviceRosterDTO {
        guard conversationId == conversationID else { return try reject() }
        return roster
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
        case suspendedCreateConversation(MessagingConversationDTO)
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
        case .createConversation, .suspendedCreateConversation,
                .sendSuccess, .sendStaleRoster, .readReceipt:
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
        case .conversation, .conversationFailure, .createConversation,
                .suspendedCreateConversation, .readReceipt:
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
        switch scenario {
        case .createConversation(let response):
            requestedDirectMemberIDs.append(request.memberIds)
            return response
        case .suspendedCreateConversation(let response):
            requestedDirectMemberIDs.append(request.memberIds)
            await suspendExpectedRequest()
            return response
        case .conversation, .conversationFailure, .sendSuccess, .sendStaleRoster, .readReceipt:
            return try reject()
        }
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

private struct SyncConversationLoadFixture {
    let userID: String
    let conversationID: String
    let nextCursor: String
    let store: SecureLocalStore
    let coordinator: SecureMessagingExchangeCoordinator
    let transport: SyncConversationLoadTransport
}

private actor SyncConversationLoadTransport: SecureMessagingExchangeTransport {
    enum ConversationBehavior: Sendable {
        case response(MessagingConversationDTO)
        case structuredNotFound
        case temporaryUnavailable
        case unstructuredNotFound
        case unexpected
    }

    enum Failure: Error {
        case unexpectedNetworkCall
    }

    private let status: MessagingKeyStatusDTO
    private let response: MessagingSyncDTO
    private let conversationBehavior: ConversationBehavior
    private var conversationRequests = 0

    init(
        status: MessagingKeyStatusDTO,
        response: MessagingSyncDTO,
        conversationBehavior: ConversationBehavior
    ) {
        self.status = status
        self.response = response
        self.conversationBehavior = conversationBehavior
    }

    func conversationRequestCount() -> Int { conversationRequests }

    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO { status }

    func messagingConversation(id: String) async throws -> MessagingConversationDTO {
        conversationRequests += 1
        switch conversationBehavior {
        case .response(let dto):
            guard dto.id == id else { throw Failure.unexpectedNetworkCall }
            return dto
        case .structuredNotFound:
            throw APIErrorPayload(
                code: "CONVERSATION_NOT_FOUND",
                message: "The conversation was not found.",
                httpStatus: 404
            )
        case .temporaryUnavailable:
            throw APIErrorPayload(
                code: "MESSAGING_TEMPORARILY_UNAVAILABLE",
                message: "Please retry.",
                httpStatus: 503
            )
        case .unstructuredNotFound:
            throw APIClientError.httpResponse(status: 404, retryAfter: nil)
        case .unexpected:
            throw Failure.unexpectedNetworkCall
        }
    }

    func messagingConversations() async throws -> MessagingConversationListDTO {
        MessagingConversationListDTO(items: [])
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

    enum ClientMediaEcho {
        case correct
        case missing
        case mismatched
    }

    let status: MessagingKeyStatusDTO
    let conversation: MessagingConversationDTO
    let clientMediaEcho: ClientMediaEcho
    private var uploads = 0

    init(
        status: MessagingKeyStatusDTO,
        conversation: MessagingConversationDTO,
        clientMediaEcho: ClientMediaEcho = .correct
    ) {
        self.status = status
        self.conversation = conversation
        self.clientMediaEcho = clientMediaEcho
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
    ) async throws -> MessagingAttachmentUploadDTO { try reject() }

    func uploadMessagingAttachment(
        mediaType: String,
        ciphertext: Data,
        clientMediaID: String,
        ciphertextSHA256: String
    ) async throws -> MessagingAttachmentUploadDTO {
        guard mediaType == "image/jpeg",
              !ciphertext.isEmpty,
              SecureMessagingWirePolicy.isCanonicalUUID(clientMediaID),
              ciphertextSHA256 == SecureMessagingValidation.sha256Hex(ciphertext)
        else {
            throw Failure.unexpectedNetworkCall
        }
        uploads += 1
        let echo: String? = switch clientMediaEcho {
        case .correct: clientMediaID
        case .missing: nil
        case .mismatched: "ffffffff-ffff-4fff-8fff-ffffffffffff"
        }
        return MessagingAttachmentUploadDTO(
            storageKey: "90000000-0000-4000-8000-000000000017",
            byteSize: Int64(ciphertext.count),
            ciphertextSha256: ciphertextSHA256,
            clientMediaId: echo
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

/// Holds the former account's status request even after task cancellation, matching a transport
/// whose underlying system callback cannot abort synchronously. A second request must therefore
/// be allowed to activate the replacement account without waiting for or inheriting that flight.
private actor SupersededActivationTransport: SecureMessagingExchangeTransport {
    enum Failure: Error {
        case expectedFirstRequestDidNotStart
        case expectedThirdRequestDidNotStart
        case staleRequest
        case unexpectedMutation
    }

    private let firstStatus: MessagingKeyStatusDTO
    private let replacementStatus: MessagingKeyStatusDTO
    private let finalStatus: MessagingKeyStatusDTO?
    private let firstRequestFails: Bool
    private var statusRequests = 0
    private var firstStatusStarted = false
    private var firstStatusReleased = false
    private var firstStatusWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondStatusStarted = false
    private var secondStatusReleased = false
    private var secondStatusWaiters: [CheckedContinuation<Void, Never>] = []
    private var thirdStatusStarted = false
    private var thirdStatusReleased = false
    private var thirdStatusWaiters: [CheckedContinuation<Void, Never>] = []
    private var messagingConversationListRequests = 0

    init(status: MessagingKeyStatusDTO) {
        firstStatus = status
        replacementStatus = status
        finalStatus = nil
        firstRequestFails = false
    }

    init(
        firstStatus: MessagingKeyStatusDTO,
        replacementStatus: MessagingKeyStatusDTO,
        finalStatus: MessagingKeyStatusDTO? = nil,
        firstRequestFails: Bool = false
    ) {
        self.firstStatus = firstStatus
        self.replacementStatus = replacementStatus
        self.finalStatus = finalStatus
        self.firstRequestFails = firstRequestFails
    }

    func waitUntilFirstStatusStarted() async throws {
        for _ in 0..<500 {
            if firstStatusStarted { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.expectedFirstRequestDidNotStart
    }

    func releaseFirstStatus() {
        firstStatusReleased = true
        let waiters = firstStatusWaiters
        firstStatusWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilSecondStatusStarted() async throws {
        for _ in 0..<500 {
            if secondStatusStarted { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.expectedFirstRequestDidNotStart
    }

    func releaseSecondStatus() {
        secondStatusReleased = true
        let waiters = secondStatusWaiters
        secondStatusWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilThirdStatusStarted() async throws {
        for _ in 0..<500 {
            if thirdStatusStarted { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.expectedThirdRequestDidNotStart
    }

    func releaseThirdStatus() {
        thirdStatusReleased = true
        let waiters = thirdStatusWaiters
        thirdStatusWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func statusRequestCount() -> Int { statusRequests }

    func messagingConversationListRequestCount() -> Int {
        messagingConversationListRequests
    }

    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO {
        statusRequests += 1
        let requestNumber = statusRequests
        if requestNumber == 1 {
            firstStatusStarted = true
            if !firstStatusReleased {
                await withCheckedContinuation { continuation in
                    firstStatusWaiters.append(continuation)
                }
            }
        } else if requestNumber == 2 {
            secondStatusStarted = true
            if !secondStatusReleased {
                await withCheckedContinuation { continuation in
                    secondStatusWaiters.append(continuation)
                }
            }
        } else if requestNumber == 3, finalStatus != nil {
            thirdStatusStarted = true
            if !thirdStatusReleased {
                await withCheckedContinuation { continuation in
                    thirdStatusWaiters.append(continuation)
                }
            }
        }
        if requestNumber == 1 {
            if firstRequestFails { throw Failure.staleRequest }
            return firstStatus
        }
        if requestNumber == 3, let finalStatus { return finalStatus }
        return replacementStatus
    }

    func publishMessagingKeyBundle(
        _ request: PublishMessagingKeyBundleRequest
    ) async throws -> MessagingKeyStatusDTO {
        throw Failure.unexpectedMutation
    }

    func resetMessagingEnrollment(
        _ request: ResetMessagingEnrollmentRequest
    ) async throws -> ResetMessagingEnrollmentDTO {
        throw Failure.unexpectedMutation
    }

    func messagingConversations() async throws -> MessagingConversationListDTO {
        messagingConversationListRequests += 1
        return MessagingConversationListDTO(items: [])
    }

    func messagingConversation(id: String) async throws -> MessagingConversationDTO {
        throw Failure.unexpectedMutation
    }

    func createDirectMessagingConversation(
        _ request: CreateDirectMessagingConversationRequest
    ) async throws -> MessagingConversationDTO {
        throw Failure.unexpectedMutation
    }

    func messagingDeviceRoster(
        conversationId: String
    ) async throws -> MessagingDeviceRosterDTO {
        throw Failure.unexpectedMutation
    }

    func historicalMessagingDeviceRoster(
        conversationId: String,
        rosterRevision: String
    ) async throws -> MessagingDeviceRosterDTO {
        throw Failure.unexpectedMutation
    }

    func consumeMessagingKeyBundles(
        conversationId: String,
        request: ConsumeMessagingKeyBundlesRequest
    ) async throws -> ConsumedMessagingKeyBundlesDTO {
        throw Failure.unexpectedMutation
    }

    func sendEncryptedMessage(
        conversationId: String,
        request: SendEncryptedMessageRequest
    ) async throws -> EncryptedMessageDTO {
        throw Failure.unexpectedMutation
    }

    func uploadMessagingAttachment(
        mediaType: String,
        ciphertext: Data
    ) async throws -> MessagingAttachmentUploadDTO {
        throw Failure.unexpectedMutation
    }

    func downloadMessagingAttachment(
        storageKey: String,
        expectedByteSize: Int64
    ) async throws -> Data {
        throw Failure.unexpectedMutation
    }

    func syncEncryptedMessages(
        cursor: String?,
        limit: Int
    ) async throws -> MessagingSyncDTO {
        MessagingSyncDTO(
            events: [],
            page: CursorPage(
                nextCursor: cursor ?? "sync-cursor-1",
                hasMore: false,
                limit: limit
            )
        )
    }

    func acknowledgeMessageDelivery(
        _ request: AcknowledgeMessageDeliveryRequest
    ) async throws -> MessageDeliveryAcknowledgementDTO {
        throw Failure.unexpectedMutation
    }

    func markMessagingConversationRead(
        conversationId: String,
        request: MarkMessagingConversationReadRequest
    ) async throws -> MessagingReadReceiptDTO {
        throw Failure.unexpectedMutation
    }
}

private struct MediaBatchFlushFixture {
    let userID: String
    let caption: String
    let batch: KitMediaMessageV2OutboundBatch
    let store: SecureLocalStore
    let coordinator: SecureMessagingExchangeCoordinator
    let transport: MediaBatchFlushTransport
    let blobs: InMemoryMediaBlobStore
    let queued: SecureMessagingQueueResult
}

private struct MediaBatchRecordedUpload: Equatable, Sendable {
    let mediaType: String
    let clientMediaID: String
    let storageKey: String
    let byteSize: Int64
    let ciphertextSha256: String
}

/// Suspends the first metadata read so tests can rotate the authenticated store lease after a
/// media queue operation has started but before its durable projection is committed.
private actor SuspendedMediaValidationBlobStore {
    enum Failure: Error {
        case expectedValidationDidNotStart
    }

    private let userID: String
    private let blobs: [String: Data]
    private let protectedOriginalURLs: [String: URL]
    private var validationStarted = false
    private var validationReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        userID: String,
        seed: [String: Data],
        protectedOriginalURLs: [String: URL] = [:]
    ) {
        self.userID = userID
        blobs = seed
        self.protectedOriginalURLs = protectedOriginalURLs
    }

    func waitUntilValidationStarted() async throws {
        for _ in 0..<500 {
            if validationStarted { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.expectedValidationDidNotStart
    }

    func releaseValidation() {
        validationReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func suspendFirstValidationIfNeeded() async {
        guard !validationStarted else { return }
        validationStarted = true
        if validationReleased { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    private func read(_ storageKey: String, for requestedUserID: String) -> Data? {
        guard requestedUserID == userID else { return nil }
        return blobs[storageKey]
    }

    private func byteCount(_ storageKey: String, for requestedUserID: String) async -> Int? {
        guard requestedUserID == userID else { return nil }
        await suspendFirstValidationIfNeeded()
        return blobs[storageKey]?.count
    }

    private func protectedOriginalURL(
        _ storageKey: String,
        for requestedUserID: String,
        expectedByteCount: Int
    ) -> URL? {
        guard requestedUserID == userID,
              blobs[storageKey]?.count == expectedByteCount
        else { return nil }
        return protectedOriginalURLs[storageKey]
    }

    nonisolated func access() -> SecureMediaBlobStoreAccess {
        SecureMediaBlobStoreAccess(
            read: { storageKey, userID in
                await self.read(storageKey, for: userID)
            },
            byteCount: { storageKey, userID in
                await self.byteCount(storageKey, for: userID)
            },
            protectedOriginalURL: { storageKey, userID, expectedByteCount in
                await self.protectedOriginalURL(
                    storageKey,
                    for: userID,
                    expectedByteCount: expectedByteCount
                )
            },
            duplicateIfAbsent: { _, _, _ in .sourceMissing },
            removeDuplicate: { _, _, _ in false },
            remove: { _, _ in }
        )
    }
}

/// Dict-backed stand-in for `SecureMediaFileCache` behind `SecureMediaBlobStoreAccess`,
/// preserving the cache's non-overwriting semantics: `duplicate` classifies an existing
/// destination by byte comparison instead of replacing it, and `removeDuplicate` deletes only
/// while an identical survivor remains readable — the outcomes the upload loop's checkpoint
/// choreography depends on.
private actor InMemoryMediaBlobStore {
    private var blobs: [String: Data]
    private var protectedFiles: [String: URL]

    init(seed: [String: Data], protectedFiles: [String: URL] = [:]) {
        blobs = seed
        self.protectedFiles = protectedFiles
    }

    func read(_ storageKey: String) -> Data? { blobs[storageKey] }

    func byteCount(_ storageKey: String) -> Int? {
        if let data = blobs[storageKey] { return data.count }
        guard let url = protectedFiles[storageKey] else { return nil }
        return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    func protectedOriginalURL(_ storageKey: String, expectedByteCount: Int) -> URL? {
        guard let url = protectedFiles[storageKey],
              byteCount(storageKey) == expectedByteCount
        else { return nil }
        return url
    }

    func duplicate(fromKey: String, toKey: String) -> SecureMediaDuplicateOutcome {
        guard let source = blobs[fromKey] else { return .sourceMissing }
        if let existing = blobs[toKey] {
            return existing == source ? .alreadyIdentical : .conflict
        }
        blobs[toKey] = source
        return .stored
    }

    func removeDuplicate(_ key: String, keeping survivorKey: String) -> Bool {
        guard key != survivorKey,
              let doomed = blobs[key],
              let survivor = blobs[survivorKey],
              doomed == survivor
        else { return false }
        blobs.removeValue(forKey: key)
        return true
    }

    func remove(_ storageKey: String) {
        blobs.removeValue(forKey: storageKey)
    }

    func storageKeys() -> Set<String> { Set(blobs.keys) }

    /// The coordinator seam, pinned to one account: any other user id reads nothing and
    /// mutates nothing.
    nonisolated func access(forUserID expectedUserID: String) -> SecureMediaBlobStoreAccess {
        SecureMediaBlobStoreAccess(
            read: { key, userID in
                guard userID == expectedUserID else { return nil }
                return await self.read(key)
            },
            byteCount: { key, userID in
                guard userID == expectedUserID else { return nil }
                return await self.byteCount(key)
            },
            protectedOriginalURL: { key, userID, expectedByteCount in
                guard userID == expectedUserID else { return nil }
                return await self.protectedOriginalURL(key, expectedByteCount: expectedByteCount)
            },
            duplicateIfAbsent: { fromKey, toKey, userID in
                guard userID == expectedUserID else { return .sourceMissing }
                return await self.duplicate(fromKey: fromKey, toKey: toKey)
            },
            removeDuplicate: { key, survivor, userID in
                guard userID == expectedUserID else { return false }
                return await self.removeDuplicate(key, keeping: survivor)
            },
            remove: { key, userID in
                guard userID == expectedUserID else { return }
                await self.remove(key)
            }
        )
    }
}

/// Serves exactly what the flush stage needs: key status, the direct conversation, one
/// §7-fresh capabilities document, and a roster that answers once — enough for the flush-time
/// admission gate — then fails 503, so the pipeline stops deterministically inside the text
/// hand-off, after the durable seal and before Signal session work that would need real
/// recipient key material. Uploads mint per-call storage keys and echo real ciphertext facts;
/// a send is counted and refused, because reaching it would already falsify the test.
private actor MediaBatchFlushTransport: SecureMessagingExchangeTransport {
    enum Failure: Error { case unexpectedNetworkCall }

    private let status: MessagingKeyStatusDTO
    private let conversation: MessagingConversationDTO
    private let capabilitiesDocument: CapabilitiesDTO
    private let roster: MessagingDeviceRosterDTO
    private let echoesMismatchedClientMediaID: Bool
    private var rosterCalls = 0
    private var uploads: [MediaBatchRecordedUpload] = []
    private var sends = 0

    init(
        status: MessagingKeyStatusDTO,
        conversation: MessagingConversationDTO,
        capabilitiesDocument: CapabilitiesDTO,
        roster: MessagingDeviceRosterDTO,
        echoesMismatchedClientMediaID: Bool = false
    ) {
        self.status = status
        self.conversation = conversation
        self.capabilitiesDocument = capabilitiesDocument
        self.roster = roster
        self.echoesMismatchedClientMediaID = echoesMismatchedClientMediaID
    }

    func uploadedItems() -> [MediaBatchRecordedUpload] { uploads }
    func uploadCount() -> Int { uploads.count }
    func sendCount() -> Int { sends }
    func rosterCallCount() -> Int { rosterCalls }

    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO { status }

    func capabilities() async throws -> CapabilitiesDTO { capabilitiesDocument }

    func messagingConversation(id: String) async throws -> MessagingConversationDTO {
        guard id == conversation.id else { throw Failure.unexpectedNetworkCall }
        return conversation
    }

    func messagingDeviceRoster(
        conversationId: String
    ) async throws -> MessagingDeviceRosterDTO {
        guard conversationId == conversation.id else { throw Failure.unexpectedNetworkCall }
        rosterCalls += 1
        guard rosterCalls == 1 else {
            throw APIErrorPayload(
                code: "MESSAGING_TEMPORARILY_UNAVAILABLE",
                message: "Please retry.",
                httpStatus: 503
            )
        }
        return roster
    }

    func uploadMessagingAttachment(
        mediaType: String,
        ciphertext: Data
    ) async throws -> MessagingAttachmentUploadDTO {
        throw Failure.unexpectedNetworkCall
    }

    func uploadMessagingAttachment(
        mediaType: String,
        ciphertext: Data,
        clientMediaID: String,
        ciphertextSHA256: String
    ) async throws -> MessagingAttachmentUploadDTO {
        guard !ciphertext.isEmpty,
              SecureMessagingWirePolicy.isCanonicalUUID(clientMediaID),
              ciphertextSHA256 == SecureMessagingValidation.sha256Hex(ciphertext)
        else { throw Failure.unexpectedNetworkCall }
        let upload = MediaBatchRecordedUpload(
            mediaType: mediaType,
            clientMediaID: clientMediaID,
            storageKey: String(format: "9a000000-0000-4000-8000-%012d", uploads.count + 1),
            byteSize: Int64(ciphertext.count),
            ciphertextSha256: ciphertextSHA256
        )
        uploads.append(upload)
        return MessagingAttachmentUploadDTO(
            storageKey: upload.storageKey,
            byteSize: upload.byteSize,
            ciphertextSha256: upload.ciphertextSha256,
            clientMediaId: echoesMismatchedClientMediaID
                ? "ffffffff-ffff-4fff-8fff-ffffffffffff"
                : clientMediaID
        )
    }

    func sendEncryptedMessage(
        conversationId: String,
        request: SendEncryptedMessageRequest
    ) async throws -> EncryptedMessageDTO {
        sends += 1
        throw Failure.unexpectedNetworkCall
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

/// Records every send POST and answers with a caller-supplied echo of the request, so the
/// strict outbound response validator can pass without a network. Everything else rejects:
/// a committed fanout must need nothing but the send endpoint.
private actor RecordingMediaSendTransport: SecureMessagingExchangeTransport {
    enum Failure: Error { case unexpectedNetworkCall }

    private let respond: @Sendable (SendEncryptedMessageRequest) throws -> EncryptedMessageDTO
    private var recordedConversationIDs: [String] = []
    private var recordedRequests: [SendEncryptedMessageRequest] = []

    init(
        respond: @escaping @Sendable (SendEncryptedMessageRequest) throws -> EncryptedMessageDTO
    ) {
        self.respond = respond
    }

    func sentRequests() -> [SendEncryptedMessageRequest] { recordedRequests }
    func sentConversationIDs() -> [String] { recordedConversationIDs }

    func sendEncryptedMessage(
        conversationId: String,
        request: SendEncryptedMessageRequest
    ) async throws -> EncryptedMessageDTO {
        recordedConversationIDs.append(conversationId)
        recordedRequests.append(request)
        return try respond(request)
    }

    private func reject<T>() throws -> T { throw Failure.unexpectedNetworkCall }

    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO { try reject() }

    func publishMessagingKeyBundle(
        _ request: PublishMessagingKeyBundleRequest
    ) async throws -> MessagingKeyStatusDTO { try reject() }

    func resetMessagingEnrollment(
        _ request: ResetMessagingEnrollmentRequest
    ) async throws -> ResetMessagingEnrollmentDTO { try reject() }

    func messagingConversations() async throws -> MessagingConversationListDTO { try reject() }

    func messagingConversation(id: String) async throws -> MessagingConversationDTO {
        try reject()
    }

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
