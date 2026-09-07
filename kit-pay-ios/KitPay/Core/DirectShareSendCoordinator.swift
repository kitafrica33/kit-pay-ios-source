import CryptoKit
import Foundation

/// Sends from the extension using the same Signal engine, canonical wire mapper and validators
/// as the app. Each uncertain HTTP retry reuses a journaled request, never a fresh ratchet fork.
actor DirectShareSendCoordinator {
    static let shared = DirectShareSendCoordinator()
    private let broker: MessagingProcessBroker
    private let transport: any DirectShareTransporting
    private let engine: SecureMessagingCryptoEngine
    private struct Operation: Hashable {
        let id: UUID
        let scope: MessagingProcessBroker.Scope
    }
    private var running: [Operation: Task<Void, Error>] = [:]

    init(
        broker: MessagingProcessBroker = .shared,
        transport: any DirectShareTransporting = DirectShareHTTPTransport.shared,
        engine: SecureMessagingCryptoEngine = .shared
    ) {
        self.broker = broker
        self.transport = transport
        self.engine = engine
    }

    func enqueue(
        id: UUID,
        ownerAccountID: String,
        destination: SharedInboxDestination,
        items: [SharedInboxItem],
        text: String?,
        expectedScope: MessagingProcessBroker.Scope? = nil
    ) throws {
        try Task.checkCancellation()
        let scope = try broker.scope()
        guard expectedScope.map({ $0 == scope }) ?? true,
              scope.accountID == ownerAccountID,
              SharedInboxPolicy.isValidDestination(destination),
              items.count <= SharedInboxPolicy.maximumItems,
              SharedInboxPolicy.batchFits(items),
              Set(items.map(\.id)).count == items.count,
              items.allSatisfy(SharedInboxPolicy.isValidItemMetadata),
              !items.isEmpty || SharedInboxPolicy.carriedText(text) != nil,
              text.map({ !SharedInboxPolicy.exceedsTextLimit($0) }) ?? true
        else { throw SharedInboxError.unreadable }
        let inputSHA256 = try DirectShareSendRecord.inputFingerprint(destination: destination, items: items, text: text)
        if try broker.containsEnqueued(id: id, inputSHA256: inputSHA256, scope: scope) { return }
        guard try broker.approvedDestinations(scope: scope).contains(destination) else { throw SharedInboxError.signedOut }
        do {
            let media = try items.map { item -> DirectShareSendRecord.Media in
                let source = try DirectShareSendRecord.stagingStore.fileURL(for: item, in: id)
                try MessagingProcessBroker.synchronizeFile(source)
                return DirectShareSendRecord.Media(
                    item: item, keyMaterial: try SecureMediaAttachmentCipher.randomKeyMaterial()
                )
            }
            try broker.updateOutgoing(scope: scope) { record in
                try Task.checkCancellation()
                if try record.containsEnqueued(id: id, inputSHA256: inputSHA256, scope: scope) { return }
                let retainedBytes = record.outgoing.reduce(0) { result, send in
                    result + send.media.reduce(0) { $0 + $1.item.byteCount }
                }
                let offeredBytes = items.reduce(0) { $0 + $1.byteCount }
                guard record.outgoing.count < DirectShareSendRecord.maximumPendingSends,
                      offeredBytes <= SharedInboxPolicy.maximumRetainedBytes - retainedBytes
                else { throw SharedInboxError.inboxFull }
                record.outgoing.append(DirectShareSendRecord(
                    id: id, generation: scope.generation, accountID: scope.accountID,
                    sessionID: scope.sessionID, destination: destination, createdAt: Date(),
                    text: text, media: media
                ))
            }
        } catch {
            // The sibling may have confirmed/imported this exact input while our staging read
            // or durable enqueue was finishing. Only its current-scope match resolves uncertainty.
            if (try? broker.containsEnqueued(id: id, inputSHA256: inputSHA256, scope: scope)) == true { return }
            throw error
        }
    }

    /// Returns only after the backend's exact encrypted-message receipt validates. The sheet
    /// must not describe an upload or a local queue write as successful delivery.
    func send(id: UUID, expectedScope: MessagingProcessBroker.Scope? = nil) async throws {
        let scope = try broker.scope(), operation = Operation(id: id, scope: scope)
        guard expectedScope.map({ $0 == scope }) ?? true else { throw MessagingProcessBroker.Failure.accountChanged }
        if try broker.isConfirmed(id: id, scope: scope) { return }
        let existing = running[operation]
        let task = existing ?? Task { try await self.performSend(id: id, scope: scope) }
        if existing == nil { running[operation] = task }
        defer { if existing == nil { running[operation] = nil } }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            _ = try broker.snapshot(scope: scope)
        } catch {
            // A sibling's verified send may have been imported while any network/crypto await
            // was in flight, including between its POST and our queue update. Keep the original
            // scope: a replacement account, session or privacy lease cannot satisfy this result.
            if (try? broker.isConfirmed(id: id, scope: scope)) == true { return }
            throw error
        }
    }

    /// The app calls this after authenticated foreground/restore. The extension also discovers
    /// interrupted work here. No timer can bypass a locked, revoked or replaced account.
    func resumePending() async {
        guard let scope = try? broker.scope(), let snapshot = try? broker.snapshot(scope: scope) else { return }
        for pending in snapshot.outgoing where !pending.isComplete {
            guard !Task.isCancelled else { return }
            do { try await send(id: pending.id) } catch { continue }
        }
#if !KIT_SHARE_EXTENSION
        // Copy into the private sender-original cache before the store consumes the recovery
        // record. The original staging remains owned by the journal until its private commit.
        guard let completed = try? broker.snapshot(scope: scope).outgoing else { return }
        for record in completed where record.isComplete && !record.readyForPrivateImport {
            do {
                for media in record.media {
                    _ = try broker.snapshot(scope: scope)
                    let source = try DirectShareSendRecord.stagingStore.fileURL(for: media.item, in: record.id)
                    _ = try await SecureMediaFileCache.shared.importProtectedOriginal(
                        from: source, forStorageKey: media.item.id.uuidString.lowercased(),
                        userID: scope.accountID, mediaType: media.item.mediaType,
                        expectedByteCount: media.item.byteCount, moveSource: false
                    )
                }
                try update(record.id, scope: scope) { $0.localMediaImported = true }
            } catch { continue }
        }
#endif
    }

    private func pending(_ id: UUID, scope: MessagingProcessBroker.Scope) throws -> DirectShareSendRecord {
        guard let record = try broker.snapshot(scope: scope).outgoing.first(where: { $0.id == id }),
              record.generation == scope.generation, record.accountID == scope.accountID,
              record.sessionID == scope.sessionID
        else { throw MessagingProcessBroker.Failure.accountChanged }
        return record
    }

    private func update(
        _ id: UUID,
        scope: MessagingProcessBroker.Scope,
        mutation: (inout DirectShareSendRecord) throws -> Void
    ) throws {
        try broker.updateOutgoing(scope: scope) { record in
            guard let index = record.outgoing.firstIndex(where: { $0.id == id }),
                  record.outgoing[index].generation == scope.generation,
                  record.outgoing[index].sessionID == scope.sessionID
            else { throw MessagingProcessBroker.Failure.accountChanged }
            try mutation(&record.outgoing[index])
        }
    }

    private func performSend(id: UUID, scope: MessagingProcessBroker.Scope) async throws {
        if try broker.isConfirmed(id: id, scope: scope) { return }
        var send = try pending(id, scope: scope)
        if send.isComplete { return }
        try requireCurrentDestination(send, scope: scope)
        if send.fanout == nil {
            let conversation: ValidatedDirectConversation
            let admission: (SecureMessagingRosterSnapshot, SecureMessagingPersistentState)
            if let conversationID = send.conversation?.id ?? send.destination.conversationID {
                async let resolved = resolveConversation(send, scope: scope)
                async let facts = readAdmission(conversationID: conversationID, scope: scope)
                conversation = try await resolved
                admission = try await validateAdmission(
                    send, conversation: conversation, scope: scope, facts: facts
                )
            } else {
                conversation = try await resolveConversation(send, scope: scope)
                admission = try await validateAdmission(send, conversation: conversation, scope: scope)
            }
            try update(id, scope: scope) { $0.conversation = conversation }
            // Media admission precedes expensive work and refreshes after uploads. Text consumes
            // this same one-use read, avoiding duplicate status/capability/roster round trips.
            // Network transfers can overlap; encryption remains streaming and concurrency is
            // capped at two so a multi-file share cannot exhaust the extension's memory budget.
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                for index in 0 ..< min(2, send.media.count) {
                    next += 1
                    group.addTask { try await self.prepareAndUploadMedia(id, index: index, scope: scope) }
                }
                while try await group.next() != nil {
                    if next < send.media.count {
                        let index = next
                        next += 1
                        group.addTask { try await self.prepareAndUploadMedia(id, index: index, scope: scope) }
                    }
                }
            }
            try await seal(id, conversation: conversation, scope: scope,
                           admission: send.media.isEmpty ? admission : nil)
            send = try pending(id, scope: scope)
        } else {
            // Even an exact retry cannot use a revoked/reset device identity. Read status
            // without altering the persisted fanout; the extension never re-enrolls devices.
            let features = try await transport.capabilities(scope: scope)
            try await validateServerEnrollment(scope: scope, features: features)
            guard try broker.snapshot(scope: scope).crypto?.enrollment == send.enrollment else {
                throw SecureMessagingExchangeError.invalidAccount
            }
        }
        guard let fanout = send.fanout, let body = send.body,
              let bytes = send.wireRequest, let enrollment = send.enrollment
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        if try broker.isConfirmed(id: id, scope: scope) { return }
        try requireCurrentDestination(send, scope: scope)
        let response: EncryptedMessageDTO
        do {
            response = try await transport.request(
                MessagingAPIEndpoint.messages(fanout.conversationID), body: bytes, scope: scope
            )
        } catch let error as APIErrorPayload {
            // Only authenticated, definitive contract rejections permit a new fanout. A lost
            // response, timeout, malformed receipt or generic HTTP failure ALWAYS retains bytes.
            let rosterRejected = ["MESSAGING_ROSTER_CHANGED", "DEVICE_ENVELOPES_INCOMPLETE",
                                  "MESSAGING_ROSTER_PROTOCOL_MISMATCH"].contains(error.code)
            let attachmentExpired = error.code == "ATTACHMENT_REFERENCE_INVALID" && !send.media.isEmpty
            if (400 ... 499).contains(error.httpStatus ?? 0), rosterRejected || attachmentExpired {
                try update(id, scope: scope) { current in
                    guard !current.isComplete else { return }
                    guard current.wireRequest == bytes, current.fanout == fanout else {
                        throw MessagingProcessBroker.Failure.staleState
                    }
                    current.fanout = nil
                    current.wireRequest = nil
                    current.enrollment = nil
                    if attachmentExpired {
                        for index in current.media.indices { current.media[index].storageKey = nil }
                    }
                }
            }
            throw error
        }
        if try broker.isConfirmed(id: id, scope: scope) { return }
        let echo = try SecureMessagingOutboundValidation.validate(
            response, fanout: fanout, expectedPlaintext: body,
            expectedAttachments: KitMediaMessageFamilyPolicy.attachmentRequests(for: body),
            userID: scope.accountID, enrollment: enrollment
        )
        try update(id, scope: scope) { current in
            guard current.fanout == fanout, current.wireRequest == bytes else {
                throw MessagingProcessBroker.Failure.staleState
            }
            current.serverMessageID = echo.serverMessageID
            current.sentAt = echo.sentAt
            current.historyMetadata = echo.historyMetadata
        }
    }

    private func requireCurrentDestination(
        _ send: DirectShareSendRecord, scope: MessagingProcessBroker.Scope
    ) throws {
        guard try broker.approvedDestinations(scope: scope).contains(where: {
                  $0.id == send.destination.id && $0.kind == send.destination.kind
                      && $0.recipientUserID == send.destination.recipientUserID
              })
        else { throw SharedInboxError.signedOut }
    }

    private func resolveConversation(
        _ send: DirectShareSendRecord,
        scope: MessagingProcessBroker.Scope
    ) async throws -> ValidatedDirectConversation {
        let dto: MessagingConversationDTO
        if let conversationID = send.conversation?.id ?? send.destination.conversationID {
            dto = try await transport.send(
                MessagingAPIEndpoint.conversation(conversationID), body: DirectShareEmptyBody(), scope: scope
            )
        } else {
            guard send.destination.kind == .contact, let recipient = send.destination.recipientUserID else {
                throw SharedInboxError.unreadable
            }
            let features = try await transport.capabilities(scope: scope)
            try await validateServerEnrollment(scope: scope, features: features)
            let clientID = features.protocols?.messaging?.offlineDirectCreation?.supportsReviewedV1 == true
                ? send.id.uuidString.lowercased() : nil
            dto = try await transport.send(
                .createConversation,
                body: CreateDirectMessagingConversationRequest(memberId: recipient, clientConversationId: clientID),
                scope: scope
            )
        }
        let validated = try SecureMessagingConversationValidation.validate(
            dto, currentUserID: scope.accountID,
            expectedRecipientUserID: send.destination.recipientUserID,
            fallbackTitle: send.destination.displayName
        )
        if let expected = send.conversation?.id ?? send.destination.conversationID {
            guard validated.id == expected else { throw SecureMessagingExchangeError.invalidConversation }
        }
        guard validated.isGroup == (send.destination.kind == .group) else {
            throw SecureMessagingExchangeError.invalidConversation
        }
        return validated
    }

    private struct AdmissionFacts {
        let features: DirectShareCapabilitiesDTO
        let status: MessagingKeyStatusDTO
        let roster: MessagingDeviceRosterDTO
    }

    private func readAdmission(
        conversationID: String, scope: MessagingProcessBroker.Scope
    ) async throws -> AdmissionFacts {
        async let features = transport.capabilities(scope: scope)
        async let status: MessagingKeyStatusDTO = transport.send(
            .keyStatus, body: DirectShareEmptyBody(), scope: scope
        )
        async let roster: MessagingDeviceRosterDTO = transport.send(
            MessagingAPIEndpoint.roster(conversationID), body: DirectShareEmptyBody(), scope: scope
        )
        return try await AdmissionFacts(features: features, status: status, roster: roster)
    }

    @discardableResult
    private func validateAdmission(
        _ send: DirectShareSendRecord,
        conversation: ValidatedDirectConversation,
        scope: MessagingProcessBroker.Scope,
        facts suppliedFacts: AdmissionFacts? = nil
    ) async throws -> (SecureMessagingRosterSnapshot, SecureMessagingPersistentState) {
        guard let crypto = try broker.snapshot(scope: scope).crypto,
              let enrollment = crypto.enrollment, enrollment.userID == scope.accountID
        else { throw SecureMessagingExchangeError.invalidAccount }
        let facts: AdmissionFacts
        if let suppliedFacts { facts = suppliedFacts }
        else { facts = try await readAdmission(conversationID: conversation.id, scope: scope) }
        let features = facts.features, dto = facts.roster, status = facts.status
        guard features.supportsFeature("messaging"),
              features.protocols?.messaging?.supportsReviewedV2 == true
        else { throw SecureMessagingExchangeError.invalidAccount }
        guard status.enrolled == true,
              try SecureMessagingMapper.enrollmentBinding(from: status, userID: scope.accountID) == enrollment,
              crypto.pendingPublication == nil
        else { throw SecureMessagingExchangeError.invalidAccount }
        if conversation.isGroup {
            guard features.supportsFeature(MessagingGroupCapabilityPolicy.featureKey),
                  MessagingGroupCapabilityPolicy.supports(
                roster: dto, conversationID: conversation.id, currentDeviceID: enrollment.serverDeviceID,
                memberUserIDs: conversation.memberUserIDs
            ) else { throw SecureMessagingExchangeError.groupCapabilityUnavailable }
        }
        if send.media.count > 1 {
            guard MessagingMediaMessageV2CapabilityPolicy.admitsComposition(
                capabilities: features, roster: dto, conversationID: conversation.id,
                currentDeviceID: enrollment.serverDeviceID, currentUserID: scope.accountID,
                memberUserIDs: conversation.memberUserIDs,
                items: send.media.map { .init(mediaType: $0.item.mediaType, plaintextByteSize: $0.item.byteCount) }
            ) else { throw SecureMessagingExchangeError.mediaMessageCapabilityUnavailable }
        } else if let media = send.media.first {
            guard features.enablesMessagingRichMedia,
                  MessagingRichMediaCapabilityPolicy.supportsAcrossRoster(
                    mediaType: media.item.mediaType, roster: dto, conversationID: conversation.id,
                    currentDeviceID: enrollment.serverDeviceID, memberUserIDs: conversation.memberUserIDs
                  ),
                  MessagingRichMediaCapabilityPolicy.supportsPlaintextByteSize(
                    media.item.byteCount, roster: dto, conversationID: conversation.id,
                    currentDeviceID: enrollment.serverDeviceID, memberUserIDs: conversation.memberUserIDs
                  )
            else { throw SecureMessagingExchangeError.richMediaCapabilityUnavailable }
        }
        let roster = try SecureMessagingMapper.roster(
            from: dto, use: .current, expectedConversationID: conversation.id,
            currentDeviceID: enrollment.serverDeviceID, currentUserID: scope.accountID,
            expectedMemberUserIDs: conversation.memberUserIDs
        )
        return (roster, crypto)
    }

    private func validateServerEnrollment(
        scope: MessagingProcessBroker.Scope, features: DirectShareCapabilitiesDTO
    ) async throws {
        guard features.supportsFeature("messaging"),
              features.protocols?.messaging?.supportsReviewedV2 == true,
              let crypto = try broker.snapshot(scope: scope).crypto,
              let enrollment = crypto.enrollment, crypto.pendingPublication == nil
        else { throw SecureMessagingExchangeError.invalidAccount }
        let status: MessagingKeyStatusDTO = try await transport.send(
            .keyStatus, body: DirectShareEmptyBody(), scope: scope
        )
        guard status.enrolled == true,
              try SecureMessagingMapper.enrollmentBinding(from: status, userID: scope.accountID) == enrollment
        else { throw SecureMessagingExchangeError.invalidAccount }
    }

    private func prepareAndUploadMedia(
        _ id: UUID, index: Int, scope: MessagingProcessBroker.Scope
    ) async throws {
        let send = try pending(id, scope: scope)
        guard send.media.indices.contains(index) else { throw SharedInboxError.unreadable }
        let media = send.media[index]
        let source = try DirectShareSendRecord.stagingStore.fileURL(for: media.item, in: id)
        let ciphertext = source.deletingLastPathComponent().appendingPathComponent(
            "\(media.item.id.uuidString.lowercased()).ciphertext"
        )
        let attachmentID = media.item.id.uuidString.lowercased()
        if media.storageKey != nil, media.ciphertextBytes != nil, media.ciphertextSHA256 != nil {
            return // A validated upload survives ordinary retries and roster changes.
        }
        let encrypted = try await Task.detached(priority: .userInitiated) {
            if let bytes = media.ciphertextBytes, let hash = media.ciphertextSHA256,
               try Self.verifiedCiphertext(ciphertext, bytes: bytes, sha256: hash) {
                return SecureMediaAttachmentCipher.EncryptedFile(
                    ciphertextByteSize: bytes, ciphertextSHA256: hash, plaintextByteSize: media.item.byteCount
                )
            }
            let temporary = ciphertext.deletingLastPathComponent().appendingPathComponent(
                ".\(UUID().uuidString.lowercased()).encrypting"
            )
            defer { try? FileManager.default.removeItem(at: temporary) }
            let result = try SecureMediaAttachmentCipher.encryptFile(
                plaintextURL: source, ciphertextURL: temporary,
                expectedPlaintextByteSize: media.item.byteCount,
                keyMaterial: media.keyMaterial, attachmentID: attachmentID
            )
            // The cipher derives its IV from permanent attachment ID + retained key material.
            // If recovery reconstructs a lost spool, the result must match the prior commitment.
            if let expectedBytes = media.ciphertextBytes, let expectedHash = media.ciphertextSHA256 {
                guard result.ciphertextByteSize == expectedBytes, result.ciphertextSHA256 == expectedHash else {
                    throw SecureMediaAttachmentError.serverMetadataMismatch
                }
            }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path
            )
            try MessagingProcessBroker.synchronizeFile(temporary)
            try MessagingProcessBroker.durableMove(temporary, to: ciphertext)
            return result
        }.value
        try update(id, scope: scope) { current in
            guard current.media[index].item == media.item, current.media[index].keyMaterial == media.keyMaterial else {
                throw MessagingProcessBroker.Failure.staleState
            }
            current.media[index].ciphertextBytes = encrypted.ciphertextByteSize
            current.media[index].ciphertextSHA256 = encrypted.ciphertextSHA256
        }
        let uploaded = try await transport.upload(
            ciphertextURL: ciphertext, attachmentID: attachmentID, mediaType: media.item.mediaType,
            byteSize: encrypted.ciphertextByteSize, sha256: encrypted.ciphertextSHA256, scope: scope
        )
        guard let validated = SecureMessagingAttachmentUploadResponsePolicy.validate(
            uploaded, attachmentID: attachmentID, ciphertextByteSize: encrypted.ciphertextByteSize,
            ciphertextSHA256: encrypted.ciphertextSHA256
        ) else { throw SecureMediaAttachmentError.serverMetadataMismatch }
        try update(id, scope: scope) { $0.media[index].storageKey = validated.storageKey }
    }

    nonisolated private static func verifiedCiphertext(_ url: URL, bytes: Int64, sha256: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == bytes else { return false }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while let chunk = try input.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            guard count <= bytes else { return false }
            digest.update(data: chunk)
        }
        return count == bytes && digest.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }

    private func seal(
        _ id: UUID, conversation: ValidatedDirectConversation, scope: MessagingProcessBroker.Scope,
        admission: (SecureMessagingRosterSnapshot, SecureMessagingPersistentState)? = nil
    ) async throws {
        var oneUseAdmission = admission
        for _ in 0 ..< 8 {
            let send = try pending(id, scope: scope)
            if send.fanout != nil { return }
            try requireCurrentDestination(send, scope: scope)
            let admitted: (SecureMessagingRosterSnapshot, SecureMessagingPersistentState)
            if let ready = oneUseAdmission { admitted = ready; oneUseAdmission = nil }
            else { admitted = try await validateAdmission(send, conversation: conversation, scope: scope) }
            let (roster, initial) = admitted
            guard let enrollment = initial.enrollment else { throw SecureMessagingExchangeError.invalidAccount }
            let sender = SecureMessagingAddress(
                userID: enrollment.userID, serverDeviceID: enrollment.serverDeviceID,
                signalDeviceID: enrollment.signalDeviceID
            )
            let recipients = try roster.recipients(excluding: enrollment.serverDeviceID)
            var prepared = initial
            let missing = try await engine.recipientsRequiringSession(
                currentState: prepared, localSender: sender, recipients: recipients
            )
            if !missing.isEmpty {
                let ids = Set(missing.map(\.address.serverDeviceID))
                let consumed: ConsumedMessagingKeyBundlesDTO = try await transport.send(
                    MessagingAPIEndpoint.keyBundles(conversation.id),
                    body: ConsumeMessagingKeyBundlesRequest(deviceIds: ids.sorted()), scope: scope
                )
                let bundles = try SecureMessagingMapper.remoteBundles(
                    from: consumed, roster: roster, requestedRemoteDeviceIDs: ids,
                    localDeviceID: enrollment.serverDeviceID
                )
                prepared = try await engine.establishSessions(
                    currentState: prepared, localSender: sender, bundles: bundles
                )
            }
            let body = try body(for: send)
            let encrypted = try await engine.encryptText(
                currentState: prepared, sender: sender, conversationID: conversation.id,
                clientMessageID: id.uuidString.lowercased(), rosterRevision: roster.rosterRevision,
                replyToMessageID: nil, text: body, recipients: recipients
            )
            let request = try SecureMessagingMapper.sendRequest(
                from: encrypted.fanout, plaintext: body,
                attachments: KitMediaMessageFamilyPolicy.attachmentRequests(for: body)
            )
            let bytes = try JSONEncoder().encode(request)
            do {
                try broker.updateOutgoing(scope: scope) { shared in
                    guard let index = shared.outgoing.firstIndex(where: { $0.id == id }) else {
                        throw MessagingProcessBroker.Failure.accountChanged
                    }
                    if shared.outgoing[index].fanout != nil { return }
                    guard shared.crypto == initial else { throw SecureMessagingCryptoError.staleState }
                    var next = encrypted.state
                    next.cachedRosters[roster.rosterRevision] = roster
                    try next.advanceTransactionRevision(after: initial)
                    shared.crypto = next
                    shared.outgoing[index].body = body
                    shared.outgoing[index].fanout = encrypted.fanout
                    shared.outgoing[index].wireRequest = bytes
                    shared.outgoing[index].enrollment = enrollment
                }
                return
            } catch SecureMessagingCryptoError.staleState { continue }
        }
        throw SecureMessagingExchangeError.retryLimitExceeded
    }

    private func body(for send: DirectShareSendRecord) throws -> String {
        if send.media.isEmpty {
            guard let text = SharedInboxPolicy.carriedText(send.text),
                  SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(text)
            else { throw SecureMessagingCryptoError.invalidContent }
            return text
        }
        let descriptors = try send.media.map { media -> KitMediaMessageDescriptor in
            guard let storageKey = media.storageKey, let bytes = media.ciphertextBytes,
                  let sha256 = media.ciphertextSHA256 else { throw SecureMediaAttachmentError.invalidMedia }
            return try KitMediaMessageDescriptor(
                attachmentID: media.item.id.uuidString.lowercased(), storageKey: storageKey,
                mediaType: media.item.mediaType, ciphertextByteSize: bytes,
                ciphertextSHA256: sha256, keyMaterial: media.keyMaterial,
                plaintextByteSize: media.item.byteCount, caption: send.media.count == 1 ? send.text : nil
            )
        }
        if descriptors.count == 1 { return descriptors[0].encoded }
        let items = descriptors.map {
            KitMediaMessageV2Descriptor.Item(
                attachmentID: $0.attachmentID, storageKey: $0.storageKey, mediaType: $0.mediaType,
                ciphertextByteSize: $0.ciphertextByteSize, ciphertextSHA256: $0.ciphertextSHA256,
                keyMaterialBase64: $0.keyMaterialBase64, plaintextByteSize: $0.plaintextByteSize
            )
        }
        let caption = send.text.map(KitMediaMessageCaptionPolicy.strippingBoundaryScalars).flatMap { $0.isEmpty ? nil : $0 }
        guard let descriptor = KitMediaMessageV2Descriptor(items: items, caption: caption) else {
            throw SecureMediaAttachmentError.invalidDescriptor
        }
        return descriptor.encoded
    }
}
