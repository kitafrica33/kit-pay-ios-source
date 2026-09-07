import Foundation

extension APIClient {
    func scheduledCalls(cursor: String? = nil) async throws -> ScheduledCallPage {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(path: "scheduled-calls", method: "GET", body: CallSchedulingEmptyBody(), queryItems: query)
    }

    func scheduledCall(id: String) async throws -> ScheduledCallDTO {
        try await send(path: "scheduled-calls/\(try callSchedulingID(id))", method: "GET", body: CallSchedulingEmptyBody())
    }

    func createScheduledCall(_ request: CreateScheduledCallRequest) async throws -> ScheduledCallDTO {
        try await send(path: "scheduled-calls", method: "POST", body: request)
    }

    func updateScheduledCall(id: String, request: UpdateScheduledCallRequest) async throws -> ScheduledCallDTO {
        try await send(path: "scheduled-calls/\(try callSchedulingID(id))", method: "PATCH", body: request)
    }

    func cancelScheduledCall(id: String, revision: Int) async throws -> ScheduledCallDTO {
        try await send(path: "scheduled-calls/\(try callSchedulingID(id))/cancel", method: "POST", body: CallScheduleRevisionRequest(revision: revision))
    }

    func respondToScheduledCall(id: String, response: ScheduledCallResponse) async throws -> ScheduledCallDTO {
        guard response != .invited else { throw APIClientError.invalidResponse }
        return try await send(path: "scheduled-calls/\(try callSchedulingID(id))/respond", method: "POST", body: CallScheduleResponseRequest(response: response))
    }

    func createScheduledCallInviteLink(id: String) async throws -> CallInviteLinkDTO {
        try await send(path: "scheduled-calls/\(try callSchedulingID(id))/invite-link", method: "POST", body: CallSchedulingEmptyBody())
    }

    func createCallInviteLink(id: String) async throws -> CallInviteLinkDTO {
        try await send(path: "calls/\(try callSchedulingID(id))/invite-link", method: "POST", body: CallSchedulingEmptyBody())
    }

    func inspectCallInvitation(token: String) async throws -> CallInviteInspectionDTO {
        guard CallInvitationLink.validToken(token) else { throw APIClientError.invalidURL }
        return try await send(path: "call-invite-links/\(token)", method: "GET", body: CallSchedulingEmptyBody())
    }

    /// Only call through AppModel.joinCallInvitation after the user reviews a live invitation.
    func joinCallInvitation(token: String, holdCallID: String?, holdCallRevision: Int?) async throws -> CallSessionDTO {
        guard CallInvitationLink.validToken(token) else { throw APIClientError.invalidURL }
        let result: LiveCallInvitationResponse = try await send(path: "call-invite-links/\(token)", method: "POST",
            body: CallAcceptanceRequest(holdCallId: holdCallID, holdCallRevision: holdCallRevision))
        guard result.kind == "call", result.call.participantState == "joined", !result.call.isHeld else {
            throw APIClientError.invalidResponse
        }
        return CallSessionDTO(call: result.call, rtc: result.rtc, heldCall: result.heldCall, serverTime: result.serverTime)
    }

    func revokeCallInviteLink(id: String) async throws {
        let result: CallInviteRevocationDTO = try await send(path: "call-invite-links/\(try callSchedulingID(id))/revoke", method: "POST", body: CallSchedulingEmptyBody())
        guard result.revoked else { throw APIClientError.invalidResponse }
    }

    private func callSchedulingID(_ raw: String) throws -> String {
        guard let id = UUID(uuidString: raw) else { throw APIClientError.invalidURL }
        return id.uuidString.lowercased()
    }
}

private struct CallSchedulingEmptyBody: Encodable {}
private struct CallScheduleRevisionRequest: Encodable { let revision: Int }
private struct CallScheduleResponseRequest: Encodable { let response: ScheduledCallResponse }
private struct CallInviteRevocationDTO: Decodable { let revoked: Bool }
private struct LiveCallInvitationResponse: Decodable {
    let kind: String
    let call: CallDTO
    let rtc: RTCDetails
    let heldCall: CallDTO?
    let serverTime: String?
    enum CodingKeys: String, CodingKey {
        case kind, call, rtc
        case heldCall = "held_call"
        case serverTime = "server_time"
    }
}
