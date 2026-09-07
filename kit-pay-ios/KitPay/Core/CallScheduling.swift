import Foundation

enum ScheduledCallStatus: String, Codable, Sendable {
    case scheduled, queued, started, cancelled, skipped

    var isPending: Bool { self == .scheduled || self == .queued }
    var label: String {
        switch self {
        case .scheduled: return "Scheduled"
        case .queued: return "Starting soon"
        case .started: return "Started"
        case .cancelled: return "Cancelled"
        case .skipped: return "Did not start"
        }
    }
}

enum ScheduledCallResponse: String, Codable, Sendable {
    case invited, accepted, declined

    var label: String {
        switch self {
        case .invited: return "Invited"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        }
    }
}

enum ScheduledCallType: String, Codable, CaseIterable, Sendable {
    case voice, video
    var label: String { self == .video ? "Video" : "Voice" }
}

struct ScheduledCallParticipantDTO: Decodable, Identifiable, Sendable {
    let userId: String
    let name: String
    let response: ScheduledCallResponse
    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name, response
    }
}

struct ScheduledCallDTO: Decodable, Identifiable, Sendable {
    let id: String
    let clientScheduleId: String
    let organizerUserId: String
    let title: String?
    let type: ScheduledCallType
    let conversationId: String?
    let startsAt: String
    let status: ScheduledCallStatus
    let revision: Int
    let callId: String?
    let myResponse: ScheduledCallResponse
    let participants: [ScheduledCallParticipantDTO]
    let serverTime: String

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "\(type.label) call" : trimmed
    }
    var startDate: Date? { CallSchedulingPolicy.date(startsAt) }
    func isOrganizer(_ userID: String?) -> Bool {
        userID?.caseInsensitiveCompare(organizerUserId) == .orderedSame
    }

    enum CodingKeys: String, CodingKey {
        case id, title, type, status, revision, participants
        case clientScheduleId = "client_schedule_id"
        case organizerUserId = "organizer_user_id"
        case conversationId = "conversation_id"
        case startsAt = "starts_at"
        case callId = "call_id"
        case myResponse = "my_response"
        case serverTime = "server_time"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        clientScheduleId = try values.decode(String.self, forKey: .clientScheduleId)
        organizerUserId = try values.decode(String.self, forKey: .organizerUserId)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        type = try values.decode(ScheduledCallType.self, forKey: .type)
        conversationId = try values.decodeIfPresent(String.self, forKey: .conversationId)
        startsAt = try values.decode(String.self, forKey: .startsAt)
        status = try values.decode(ScheduledCallStatus.self, forKey: .status)
        revision = try values.decode(Int.self, forKey: .revision)
        callId = try values.decodeIfPresent(String.self, forKey: .callId)
        myResponse = try values.decode(ScheduledCallResponse.self, forKey: .myResponse)
        participants = try values.decode([ScheduledCallParticipantDTO].self, forKey: .participants)
        serverTime = try values.decode(String.self, forKey: .serverTime)
        let participantIDs = participants.map { $0.userId.lowercased() }
        guard UUID(uuidString: id) != nil, UUID(uuidString: clientScheduleId) != nil,
              UUID(uuidString: organizerUserId) != nil, revision >= 1,
              CallSchedulingPolicy.date(startsAt) != nil, CallSchedulingPolicy.date(serverTime) != nil,
              (1 ... 21).contains(participants.count),
              participants.allSatisfy({ UUID(uuidString: $0.userId) != nil }),
              Set(participantIDs).count == participantIDs.count,
              participantIDs.contains(organizerUserId.lowercased()),
              status != .started || callId.flatMap({ UUID(uuidString: $0) }) != nil
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid scheduled call identity, time, revision, or audience."))
        }
    }
}

struct ScheduledCallPage: Decodable, Sendable {
    let items: [ScheduledCallDTO]
    let page: CursorPage
}

struct CreateScheduledCallRequest: Encodable, Equatable, Sendable {
    let clientScheduleId: String
    let recipientUserIds: [String]
    let type: ScheduledCallType
    let startsAt: String
    let title: String?
    let conversationId: String?

    enum CodingKeys: String, CodingKey {
        case clientScheduleId = "client_schedule_id"
        case recipientUserIds = "recipient_user_ids"
        case startsAt = "starts_at"
        case conversationId = "conversation_id"
        case type, title
    }
}

struct UpdateScheduledCallRequest: Encodable, Sendable {
    let revision: Int
    let recipientUserIds: [String]
    let startsAt: String
    let title: String?

    enum CodingKeys: String, CodingKey {
        case recipientUserIds = "recipient_user_ids"
        case startsAt = "starts_at"
        case revision, title
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(revision, forKey: .revision)
        try values.encode(recipientUserIds, forKey: .recipientUserIds)
        try values.encode(startsAt, forKey: .startsAt)
        // Clearing a title must send null; omitting it means leave it unchanged.
        try values.encode(title, forKey: .title)
    }
}

struct CallRecipientChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum CallSchedulingPolicy {
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func recipientIDs(_ choices: [CallRecipientChoice], excluding userID: String?) -> [String]? {
        let ids = choices.compactMap { UUID(uuidString: $0.id)?.uuidString.lowercased() }
        guard ids.count == choices.count, (1 ... 20).contains(ids.count),
              Set(ids).count == ids.count,
              !ids.contains(userID?.lowercased() ?? "") else { return nil }
        return ids.sorted()
    }

    static func validNewStart(_ date: Date, now: Date = Date()) -> Bool {
        guard let year = Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: now) else { return false }
        return date > now && date <= year
    }
}

struct CallInviteLinkDTO: Decodable, Sendable {
    let id: String
    let token: String
    let shareUrl: String
    let expiresAt: String

    var validatedShareURL: URL? {
        guard let url = URL(string: shareUrl), CallInvitationLink.token(from: url) == token else { return nil }
        return url
    }

    enum CodingKeys: String, CodingKey {
        case id, token
        case shareUrl = "share_url"
        case expiresAt = "expires_at"
    }
}

struct CallInviteInspectionDTO: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable { case call, scheduledCall = "scheduled_call" }
    let kind: Kind
    let scheduledCall: ScheduledCallDTO?
    let call: CallDTO?
    let expiresAt: String
    let serverTime: String

    var liveCallID: String? {
        switch kind {
        case .call: return call?.id
        case .scheduledCall: return scheduledCall?.status == .started ? scheduledCall?.callId : nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, call
        case scheduledCall = "scheduled_call"
        case expiresAt = "expires_at"
        case serverTime = "server_time"
    }
}

/// Kept in memory only. A URL opens a review; it never authorizes a call connection.
enum CallInvitationLink {
    static func validToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
        }
    }

    static func token(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "kitpay", components.host == "call-invites",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.hasPrefix("/") else { return nil }
        let token = String(components.percentEncodedPath.dropFirst())
        guard validToken(token), url.absoluteString == "kitpay://call-invites/\(token)" else { return nil }
        return token
    }
}

struct CallInvitationIntent: Identifiable, Equatable {
    let id: UUID
    let token: String
    var accountID: String?
}

struct CallInvitationInbox {
    private(set) var pending: CallInvitationIntent?

    mutating func receive(token: String, accountID: String?) {
        guard CallInvitationLink.validToken(token) else { return }
        // Preserve the first signed-out intent until sign-in and review are possible.
        if pending != nil && pending?.accountID == nil { return }
        pending = CallInvitationIntent(id: UUID(), token: token, accountID: accountID?.lowercased())
    }

    mutating func bind(to accountID: String) {
        guard pending?.accountID == nil else {
            if pending?.accountID != accountID.lowercased() { clear() }
            return
        }
        pending?.accountID = accountID.lowercased()
    }

    mutating func clear() { pending = nil }
}
