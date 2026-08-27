import Foundation

struct MessagingAPIEndpoint {
    let path: String
    let method: String
    let queryItems: [URLQueryItem]

    static let enrollmentReset = MessagingAPIEndpoint(
        path: "messaging/enrollment/reset",
        method: "POST"
    )
    static let keyStatus = MessagingAPIEndpoint(path: "messaging/keys/status", method: "GET")
    static let publishKeys = MessagingAPIEndpoint(path: "messaging/keys", method: "PUT")
    static let conversations = MessagingAPIEndpoint(
        path: "messaging/conversations",
        method: "GET"
    )
    static let createConversation = MessagingAPIEndpoint(
        path: "messaging/conversations",
        method: "POST"
    )
    private static let syncBase = MessagingAPIEndpoint(path: "messaging/sync", method: "GET")
    static let deliveryAcknowledgements = MessagingAPIEndpoint(
        path: "messaging/messages/delivery-acks",
        method: "POST"
    )
    static let attachments = MessagingAPIEndpoint(
        path: "messaging/attachments",
        method: "POST"
    )

    init(path: String, method: String, queryItems: [URLQueryItem] = []) {
        self.path = path
        self.method = method
        self.queryItems = queryItems
    }

    static func conversation(_ conversationId: String) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)",
            method: "GET"
        )
    }

    static func updateConversation(_ conversationId: String) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)",
            method: "PATCH"
        )
    }

    static func conversationPhoto(
        _ conversationId: String,
        method: String
    ) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/photo",
            method: method
        )
    }

    static func conversationMembers(_ conversationId: String) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/members",
            method: "POST"
        )
    }

    static func conversationMember(
        conversationId: String,
        userId: String
    ) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        try requireUUID(userId, field: "group member ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/members/\(userId)",
            method: "DELETE"
        )
    }

    static func roster(_ conversationId: String) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/device-roster",
            method: "GET"
        )
    }

    static func historicalRoster(
        conversationId: String,
        rosterRevision: String
    ) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        guard SecureMessagingWirePolicy.isRosterRevision(rosterRevision) else {
            throw SecureMessagingContractError.invalid("roster revision")
        }
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/device-roster/\(rosterRevision)",
            method: "GET"
        )
    }

    static func keyBundles(_ conversationId: String) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/key-bundles",
            method: "POST"
        )
    }

    static func messages(_ conversationId: String) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/messages",
            method: "POST"
        )
    }

    static func historyCandidates(
        conversationId: String,
        targetDeviceId: String,
        targetEnrollmentEpoch: Int64,
        cursor: String?,
        limit: Int
    ) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        try requireUUID(targetDeviceId, field: "history target device ID")
        guard targetEnrollmentEpoch > 0,
              (1 ... SecureMessagingWire.maximumHistoryPage).contains(limit),
              cursor.map({ $0.count <= 4_096 }) ?? true
        else { throw SecureMessagingContractError.invalid("history query") }
        var queryItems = [
            URLQueryItem(name: "target_device_id", value: targetDeviceId),
            URLQueryItem(name: "target_enrollment_epoch", value: String(targetEnrollmentEpoch)),
        ]
        if let cursor { queryItems.append(URLQueryItem(name: "after", value: cursor)) }
        queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/history-backfill/candidates",
            method: "GET",
            queryItems: queryItems
        )
    }

    static func historyEnvelope(
        conversationId: String,
        messageId: String
    ) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        try requireUUID(messageId, field: "message ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/messages/\(messageId)/history-envelopes",
            method: "POST"
        )
    }

    static func messageInfo(
        conversationId: String,
        messageId: String
    ) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        try requireUUID(messageId, field: "message ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/messages/\(messageId)/info",
            method: "GET"
        )
    }

    static func sync(cursor: String?, limit: Int) throws -> MessagingAPIEndpoint {
        guard (1 ... SecureMessagingWire.maximumSyncPage).contains(limit),
              cursor.map({ $0.count <= 2_048 }) ?? true
        else { throw SecureMessagingContractError.invalid("sync query") }
        var queryItems: [URLQueryItem] = []
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        return MessagingAPIEndpoint(
            path: syncBase.path,
            method: syncBase.method,
            queryItems: queryItems
        )
    }

    static func readReceipt(_ conversationId: String) throws -> MessagingAPIEndpoint {
        try requireUUID(conversationId, field: "conversation ID")
        return MessagingAPIEndpoint(
            path: "messaging/conversations/\(conversationId)/read-receipts",
            method: "POST"
        )
    }

    static func attachment(_ storageKey: String) throws -> MessagingAPIEndpoint {
        try requireUUID(storageKey, field: "attachment storage key")
        return MessagingAPIEndpoint(
            path: "messaging/attachments/\(storageKey)",
            method: "GET"
        )
    }

    private static func requireUUID(_ value: String, field: String) throws {
        guard SecureMessagingWirePolicy.isCanonicalUUID(value) else {
            throw SecureMessagingContractError.invalid(field)
        }
    }
}

extension APIClient {
    /// Enrollment reset intentionally remains available outside the messaging protocol feature
    /// gate on the server, but it is still authenticated and session-bound here.
    func resetMessagingEnrollment(
        _ request: ResetMessagingEnrollmentRequest
    ) async throws -> ResetMessagingEnrollmentDTO {
        let endpoint = MessagingAPIEndpoint.enrollmentReset
        return try await send(path: endpoint.path, method: endpoint.method, body: request)
    }

    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO {
        let endpoint = MessagingAPIEndpoint.keyStatus
        return try await send(path: endpoint.path, method: endpoint.method, body: MessagingEmptyBody())
    }

    func publishMessagingKeyBundle(
        _ request: PublishMessagingKeyBundleRequest
    ) async throws -> MessagingKeyStatusDTO {
        let endpoint = MessagingAPIEndpoint.publishKeys
        return try await send(path: endpoint.path, method: endpoint.method, body: request)
    }

    func messagingConversations() async throws -> MessagingConversationListDTO {
        let endpoint = MessagingAPIEndpoint.conversations
        return try await send(path: endpoint.path, method: endpoint.method, body: MessagingEmptyBody())
    }

    func messagingConversation(id: String) async throws -> MessagingConversationDTO {
        let endpoint = try MessagingAPIEndpoint.conversation(id)
        return try await send(path: endpoint.path, method: endpoint.method, body: MessagingEmptyBody())
    }

    func createDirectMessagingConversation(
        _ request: CreateDirectMessagingConversationRequest
    ) async throws -> MessagingConversationDTO {
        let endpoint = MessagingAPIEndpoint.createConversation
        return try await send(path: endpoint.path, method: endpoint.method, body: request)
    }

    func createGroupMessagingConversation(
        memberIds: [String],
        title: String
    ) async throws -> MessagingConversationDTO {
        let endpoint = MessagingAPIEndpoint.createConversation
        let request = try CreateDirectMessagingConversationRequest(
            groupMemberIds: memberIds,
            title: title
        )
        return try await send(path: endpoint.path, method: endpoint.method, body: request)
    }

    func renameGroupMessagingConversation(
        conversationId: String,
        title: String
    ) async throws -> MessagingConversationDTO {
        let endpoint = try MessagingAPIEndpoint.updateConversation(conversationId)
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: try RenameMessagingGroupRequest(title: title)
        )
    }

    func updateGroupMessagingConversationDescription(
        conversationId: String,
        description: String?
    ) async throws -> MessagingConversationDTO {
        let endpoint = try MessagingAPIEndpoint.updateConversation(conversationId)
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: try UpdateMessagingGroupDescriptionRequest(description: description)
        )
    }

    func attachGroupMessagingConversationPhoto(
        conversationId: String,
        assetId: String
    ) async throws -> MessagingConversationDTO {
        let endpoint = try MessagingAPIEndpoint.conversationPhoto(conversationId, method: "PUT")
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: try AttachMessagingGroupPhotoRequest(assetId: assetId)
        )
    }

    /// APIClient's DELETE policy guarantees the request carries no JSON body, matching the
    /// backend's strict bodyless contract for this endpoint.
    func removeGroupMessagingConversationPhoto(
        conversationId: String
    ) async throws -> MessagingConversationDTO {
        let endpoint = try MessagingAPIEndpoint.conversationPhoto(conversationId, method: "DELETE")
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: MessagingEmptyBody()
        )
    }

    func addGroupMessagingConversationMember(
        conversationId: String,
        userId: String
    ) async throws -> MessagingConversationDTO {
        let endpoint = try MessagingAPIEndpoint.conversationMembers(conversationId)
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: try AddMessagingGroupMemberRequest(userId: userId)
        )
    }

    /// The backend deliberately admits this DELETE when the group rollout flag is dark or a
    /// roster device is incompatible. It is the safety exit for both self-leave and moderation,
    /// and APIClient's DELETE policy guarantees the request has no JSON body.
    func removeGroupMessagingConversationMember(
        conversationId: String,
        userId: String
    ) async throws -> MessagingConversationDTO {
        let endpoint = try MessagingAPIEndpoint.conversationMember(
            conversationId: conversationId,
            userId: userId
        )
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: MessagingEmptyBody()
        )
    }

    func messagingDeviceRoster(conversationId: String) async throws -> MessagingDeviceRosterDTO {
        let endpoint = try MessagingAPIEndpoint.roster(conversationId)
        return try await send(path: endpoint.path, method: endpoint.method, body: MessagingEmptyBody())
    }

    func historicalMessagingDeviceRoster(
        conversationId: String,
        rosterRevision: String
    ) async throws -> MessagingDeviceRosterDTO {
        let endpoint = try MessagingAPIEndpoint.historicalRoster(
            conversationId: conversationId,
            rosterRevision: rosterRevision
        )
        return try await send(path: endpoint.path, method: endpoint.method, body: MessagingEmptyBody())
    }

    func consumeMessagingKeyBundles(
        conversationId: String,
        request: ConsumeMessagingKeyBundlesRequest
    ) async throws -> ConsumedMessagingKeyBundlesDTO {
        let endpoint = try MessagingAPIEndpoint.keyBundles(conversationId)
        return try await send(path: endpoint.path, method: endpoint.method, body: request)
    }

    func sendEncryptedMessage(
        conversationId: String,
        request: SendEncryptedMessageRequest
    ) async throws -> EncryptedMessageDTO {
        let endpoint = try MessagingAPIEndpoint.messages(conversationId)
        return try await send(path: endpoint.path, method: endpoint.method, body: request)
    }

    func messagingHistoryBackfillCandidates(
        conversationId: String,
        targetDeviceId: String,
        targetEnrollmentEpoch: Int64,
        cursor: String? = nil,
        limit: Int = SecureMessagingWire.maximumHistoryPage
    ) async throws -> MessagingHistoryBackfillCandidatesDTO {
        let endpoint = try MessagingAPIEndpoint.historyCandidates(
            conversationId: conversationId,
            targetDeviceId: targetDeviceId,
            targetEnrollmentEpoch: targetEnrollmentEpoch,
            cursor: cursor,
            limit: limit
        )
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: MessagingEmptyBody(),
            queryItems: endpoint.queryItems
        )
    }

    func storeMessagingHistoryEnvelope(
        conversationId: String,
        messageId: String,
        request: StoreMessagingHistoryEnvelopeRequest
    ) async throws -> MessagingHistoryEnvelopeResultDTO {
        let endpoint = try MessagingAPIEndpoint.historyEnvelope(
            conversationId: conversationId,
            messageId: messageId
        )
        return try await send(path: endpoint.path, method: endpoint.method, body: request)
    }

    func syncEncryptedMessages(
        cursor: String? = nil,
        limit: Int = SecureMessagingWire.maximumSyncPage
    ) async throws -> MessagingSyncDTO {
        let endpoint = try MessagingAPIEndpoint.sync(cursor: cursor, limit: limit)
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: MessagingEmptyBody(),
            queryItems: endpoint.queryItems
        )
    }

    func acknowledgeMessageDelivery(
        _ request: AcknowledgeMessageDeliveryRequest
    ) async throws -> MessageDeliveryAcknowledgementDTO {
        let endpoint = MessagingAPIEndpoint.deliveryAcknowledgements
        return try await send(path: endpoint.path, method: endpoint.method, body: request)
    }

    /// Sent, delivered and read moments for one message. The server answers this only to the
    /// person who sent it, so a 403 here is the contract working rather than a failure to explain.
    func messagingMessageInfo(
        conversationId: String,
        messageId: String
    ) async throws -> MessagingMessageInfoDTO {
        let endpoint = try MessagingAPIEndpoint.messageInfo(
            conversationId: conversationId,
            messageId: messageId
        )
        return try await send(path: endpoint.path, method: endpoint.method, body: MessagingEmptyBody())
    }

    func markMessagingConversationRead(
        conversationId: String,
        request: MarkMessagingConversationReadRequest
    ) async throws -> MessagingReadReceiptDTO {
        let endpoint = try MessagingAPIEndpoint.readReceipt(conversationId)
        return try await send(path: endpoint.path, method: endpoint.method, body: request)
    }

    func uploadMessagingAttachment(
        mediaType: String,
        ciphertext: Data
    ) async throws -> MessagingAttachmentUploadDTO {
        guard SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
              ciphertext.count >= Int(SecureMessagingWire.minimumAttachmentCiphertextBytes),
              ciphertext.count <= Int(SecureMessagingWire.maximumAttachmentCiphertextBytes)
        else { throw SecureMessagingContractError.invalid("attachment upload") }
        let endpoint = MessagingAPIEndpoint.attachments
        return try await sendMultipart(
            path: endpoint.path,
            fields: ["media_type": mediaType],
            fileField: "ciphertext",
            fileName: "encrypted-attachment.bin",
            fileContentType: "application/octet-stream",
            fileData: ciphertext
        )
    }

    func downloadMessagingAttachment(
        storageKey: String,
        expectedByteSize: Int64
    ) async throws -> Data {
        guard expectedByteSize >= SecureMessagingWire.minimumAttachmentCiphertextBytes,
              expectedByteSize <= SecureMessagingWire.maximumAttachmentCiphertextBytes
        else { throw SecureMessagingContractError.invalid("attachment download size") }
        let endpoint = try MessagingAPIEndpoint.attachment(storageKey)
        let data = try await downloadAuthenticatedData(
            path: endpoint.path,
            maximumBytes: Int(expectedByteSize)
        )
        guard data.count == Int(expectedByteSize) else {
            throw SecureMediaAttachmentError.serverMetadataMismatch
        }
        return data
    }
}

private struct MessagingEmptyBody: Encodable {}
