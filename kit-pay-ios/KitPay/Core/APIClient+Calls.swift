import Foundation

/// Validates and accumulates the authenticated cursor contract used by `GET /calls`.
/// A large finite ceiling prevents a faulty service from keeping a refresh alive forever while
/// still retaining up to 100,000 server calls for encrypted offline presentation.
struct CallHistoryPageAccumulator {
    static let pageLimit = 100
    static let maximumPages = 1_000
    static let maximumCursorLength = 2_048

    private let requestedLimit: Int
    private let maximumPageCount: Int
    private var seenCallIDs: Set<String> = []
    private var seenCursors: Set<String> = []
    private(set) var calls: [CallDTO] = []
    private(set) var nextCursor: String?
    private(set) var pageCount = 0

    struct ValidatedPage {
        let calls: [CallDTO]
        let nextCursor: String?
        let hasMore: Bool
    }

    init(
        requestedLimit: Int = Self.pageLimit,
        maximumPageCount: Int = Self.maximumPages
    ) {
        precondition((1 ... Self.pageLimit).contains(requestedLimit))
        precondition(maximumPageCount > 0)
        self.requestedLimit = requestedLimit
        self.maximumPageCount = maximumPageCount
    }

    /// Returns `true` only when the server has explicitly declared the history complete.
    mutating func append(_ response: CallPage) throws -> Bool {
        guard pageCount < maximumPageCount else { throw APIClientError.invalidResponse }
        let validated = try Self.validate(response, requestedLimit: requestedLimit)
        if validated.hasMore {
            guard pageCount + 1 < maximumPageCount,
                  let cursor = validated.nextCursor,
                  !seenCursors.contains(cursor)
            else { throw APIClientError.invalidResponse }
        }

        for call in validated.calls {
            let identity = call.id.lowercased()
            guard seenCallIDs.insert(identity).inserted else { continue }
            calls.append(call)
        }
        pageCount += 1
        nextCursor = validated.nextCursor
        if let continuation = validated.nextCursor {
            seenCursors.insert(continuation)
        }
        return !validated.hasMore
    }

    /// Validates one newest page without requiring the caller to traverse its continuation. Chat
    /// opening uses this path so recent calls appear promptly while older encrypted rows remain
    /// available and a separately throttled task performs the complete backfill.
    static func validateNewestPage(
        _ response: CallPage,
        requestedLimit: Int = Self.pageLimit
    ) throws -> [CallDTO] {
        try validate(response, requestedLimit: requestedLimit).calls
    }

    private static func validate(
        _ response: CallPage,
        requestedLimit: Int
    ) throws -> ValidatedPage {
        guard (1 ... Self.pageLimit).contains(requestedLimit),
              let items = response.items,
              let page = response.page,
              let hasMore = page.hasMore,
              let responseLimit = page.limit,
              responseLimit == requestedLimit,
              items.count <= responseLimit
        else { throw APIClientError.invalidResponse }

        let continuation: String?
        if hasMore {
            guard let cursor = page.nextCursor,
                  !cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  cursor.count <= Self.maximumCursorLength
            else { throw APIClientError.invalidResponse }
            continuation = cursor
        } else {
            continuation = nil
        }

        var seenIDs: Set<String> = []
        let deduplicated = items.filter { seenIDs.insert($0.id.lowercased()).inserted }
        return ValidatedPage(
            calls: deduplicated,
            nextCursor: continuation,
            hasMore: hasMore
        )
    }
}

extension APIClient {
    func call(id: String) async throws -> CallDTO {
        try await send(path: "calls/\(id)", method: "GET", body: CallEmptyBody())
    }

    func acceptCall(id: String, holdCallID: String? = nil, holdCallRevision: Int? = nil) async throws -> CallSessionDTO {
        try await send(path: "calls/\(id)/accept", method: "POST",
                       body: CallAcceptanceRequest(holdCallId: holdCallID, holdCallRevision: holdCallRevision))
    }

    func holdCall(id: String, revision: Int?, reason: CallHoldReason) async throws -> CallDTO {
        try await send(path: "calls/\(id)/hold", method: "POST",
                       body: CallHoldRequest(holdRevision: revision,
                           holdReason: reason == .interruption ? "interruption" : "manual"))
    }

    func resumeCall(id: String, holdCallID: String? = nil, revision: Int? = nil, holdCallRevision: Int? = nil) async throws -> CallSessionDTO {
        try await send(path: "calls/\(id)/resume", method: "POST",
                       body: CallResumeRequest(holdCallId: holdCallID, holdRevision: revision, holdCallRevision: holdCallRevision))
    }

    func declineCall(id: String) async throws -> CallDTO {
        try await send(path: "calls/\(id)/decline", method: "POST", body: CallEmptyBody())
    }

    func endCall(id: String, reason: String = "completed") async throws -> CallDTO {
        try await send(
            path: "calls/\(id)/end",
            method: "POST",
            body: EndCallRequest(reason: reason)
        )
    }

    func callToken(id: String) async throws -> RTCDetails {
        try await send(path: "calls/\(id)/token", method: "POST", body: CallEmptyBody())
    }

    func inviteToCall(id: String, recipientUserIds: [String]) async throws -> CallDTO {
        try await send(
            path: "calls/\(id)/invite",
            method: "POST",
            body: InviteCallParticipantsRequest(recipientUserIds: recipientUserIds)
        )
    }

    /// Cancels a process-only attempt by its stable idempotency key. The server keeps a scoped
    /// tombstone, so this is safe both before and after a racing POST /calls reaches the backend.
    func cancelCallAttempt(clientCallId: String) async throws -> CancelCallAttemptDTO {
        guard let identifier = UUID(
            uuidString: clientCallId.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { throw APIClientError.invalidURL }
        return try await send(
            path: "calls/client-attempts/\(identifier.uuidString.lowercased())/cancel",
            method: "POST",
            body: CallEmptyBody()
        )
    }
}

private struct CallEmptyBody: Encodable {}

struct CallAcceptanceRequest: Encodable {
    let holdCallId: String?
    var holdCallRevision: Int? = nil
    let supportsHold = true
    enum CodingKeys: String, CodingKey {
        case holdCallId = "hold_call_id"
        case holdCallRevision = "hold_call_revision"
        case supportsHold = "supports_hold"
    }
}

struct CallHoldRequest: Encodable {
    let holdRevision: Int?
    let holdReason: String
    enum CodingKeys: String, CodingKey {
        case holdRevision = "hold_revision"
        case holdReason = "hold_reason"
    }
}

struct CallResumeRequest: Encodable {
    let holdCallId: String?
    let holdRevision: Int?
    var holdCallRevision: Int? = nil
    enum CodingKeys: String, CodingKey {
        case holdCallId = "hold_call_id"
        case holdCallRevision = "hold_call_revision"
        case holdRevision = "hold_revision"
    }
}

struct EndCallRequest: Encodable, Equatable {
    let reason: String
}

struct InviteCallParticipantsRequest: Encodable, Equatable {
    let recipientUserIds: [String]

    enum CodingKeys: String, CodingKey {
        case recipientUserIds = "recipient_user_ids"
    }
}

struct CancelCallAttemptDTO: Decodable, Equatable {
    let clientCallId: String
    let cancelled: Bool

    enum CodingKeys: String, CodingKey {
        case clientCallId = "client_call_id"
        case cancelled
    }
}
