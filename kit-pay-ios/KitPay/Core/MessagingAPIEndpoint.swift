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
    static let attachmentUploads = MessagingAPIEndpoint(
        path: "messaging/attachment-uploads",
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

    static func attachmentUpload(
        _ uploadID: String,
        method: String = "GET"
    ) throws -> MessagingAPIEndpoint {
        try requireUUID(uploadID, field: "attachment upload ID")
        return MessagingAPIEndpoint(
            path: "messaging/attachment-uploads/\(uploadID)",
            method: method
        )
    }

    static func completeAttachmentUpload(_ uploadID: String) throws -> MessagingAPIEndpoint {
        try requireUUID(uploadID, field: "attachment upload ID")
        return MessagingAPIEndpoint(
            path: "messaging/attachment-uploads/\(uploadID)/complete",
            method: "POST"
        )
    }

    private static func requireUUID(_ value: String, field: String) throws {
        guard SecureMessagingWirePolicy.isCanonicalUUID(value) else {
            throw SecureMessagingContractError.invalid(field)
        }
    }
}

