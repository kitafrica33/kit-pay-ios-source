import Foundation

enum CommunicationPrivacyAPIEndpoint: Equatable {
    case preferences
    case blocks(cursor: String?, limit: Int)
    case block(userID: String)

    var path: String {
        switch self {
        case .preferences:
            "communications/preferences"
        case .blocks:
            "communications/blocks"
        case .block(let userID):
            "communications/blocks/\(userID)"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case .preferences, .block:
            return []
        case .blocks(let cursor, let limit):
            var items = [URLQueryItem(name: "limit", value: String(limit))]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            return items
        }
    }

    static func block(rawUserID: String) throws -> Self {
        guard let userID = CommunicationPrivacyIdentifier.canonicalUUID(rawUserID) else {
            throw APIClientError.invalidURL
        }
        return .block(userID: userID)
    }
}

extension APIClient {
    func communicationPreferences() async throws -> CommunicationPreferencesDTO {
        let endpoint = CommunicationPrivacyAPIEndpoint.preferences
        return try await send(
            path: endpoint.path,
            method: "GET",
            body: CommunicationPrivacyEmptyBody(),
            queryItems: endpoint.queryItems
        )
    }

    func updateCommunicationPreferences(
        _ request: UpdateCommunicationPreferencesRequest
    ) async throws -> CommunicationPreferencesDTO {
        let endpoint = CommunicationPrivacyAPIEndpoint.preferences
        let updated: CommunicationPreferencesDTO = try await send(
            path: endpoint.path,
            method: "PATCH",
            body: request,
            queryItems: endpoint.queryItems
        )
        let increment = request.version.addingReportingOverflow(1)
        guard updated.version == request.version
                || (!increment.overflow && updated.version == increment.partialValue),
              request.phoneDiscoverable.map({ updated.phoneDiscoverable == $0 }) ?? true,
              request.directMessageRequestsEnabled.map({
                  updated.directMessageRequestsEnabled == $0
              }) ?? true,
              request.incomingCallsEnabled.map({ updated.incomingCallsEnabled == $0 }) ?? true
        else { throw APIClientError.invalidResponse }
        return updated
    }

    func communicationBlocks() async throws -> [CommunicationBlockDTO] {
        var accumulator = CommunicationBlockPageAccumulator()
        while true {
            try Task.checkCancellation()
            let endpoint = CommunicationPrivacyAPIEndpoint.blocks(
                cursor: accumulator.nextCursor,
                limit: CommunicationBlockPageAccumulator.pageLimit
            )
            let page: CommunicationBlockPageDTO = try await send(
                path: endpoint.path,
                method: "GET",
                body: CommunicationPrivacyEmptyBody(),
                queryItems: endpoint.queryItems
            )
            if try accumulator.append(page) { return accumulator.blocks }
        }
    }

    func blockCommunicationUser(userID rawUserID: String) async throws -> CommunicationBlockDTO {
        let endpoint = try CommunicationPrivacyAPIEndpoint.block(rawUserID: rawUserID)
        let response: CommunicationBlockDTO = try await send(
            path: endpoint.path,
            method: "PUT",
            body: CommunicationPrivacyEmptyBody()
        )
        guard case .block(let expectedUserID) = endpoint,
              response.userId == expectedUserID,
              response.blocked,
              response.blockedAt != nil,
              response.unblockedAt == nil
        else { throw APIClientError.invalidResponse }
        return response
    }

    func unblockCommunicationUser(userID rawUserID: String) async throws -> CommunicationBlockDTO {
        let endpoint = try CommunicationPrivacyAPIEndpoint.block(rawUserID: rawUserID)
        let response: CommunicationBlockDTO = try await send(
            path: endpoint.path,
            method: "DELETE",
            body: CommunicationPrivacyEmptyBody()
        )
        guard case .block(let expectedUserID) = endpoint,
              response.userId == expectedUserID,
              !response.blocked
        else { throw APIClientError.invalidResponse }
        return response
    }
}

private struct CommunicationPrivacyEmptyBody: Encodable {}
