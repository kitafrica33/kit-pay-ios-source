import Foundation

protocol ContactSyncUploading: Sendable {
    func syncContacts(_ contacts: [ContactSyncEntry]) async throws -> ContactListDTO
}

extension APIClient: ContactSyncUploading {
    func searchKitUsers(
        query: String,
        limit: Int = KitUserDirectorySearch.resultLimit
    ) async throws -> KitUserSearchResultListDTO {
        guard let queryItems = KitUserDirectorySearch.queryItems(query: query, limit: limit)
        else { throw APIClientError.invalidResponse }
        return try await send(
            path: "search",
            method: "GET",
            body: ContactSearchRequest(),
            queryItems: queryItems
        )
    }

    func syncContacts(_ contacts: [ContactSyncEntry]) async throws -> ContactListDTO {
        // Protocol callers cannot prove that their source is a complete device
        // snapshot, so the compatibility path is deliberately non-destructive.
        try await syncContacts(contacts, scope: .partial) { _ in }
    }

    func syncContacts(
        _ contacts: [ContactSyncEntry],
        scope: ContactSyncSnapshotScope,
        progress: @escaping @Sendable (ContactSyncProgress) async -> Void
    ) async throws -> ContactListDTO {
        guard contacts.count <= ContactSyncSnapshot.serverLimit else {
            throw ContactSyncError.snapshotTooLarge(limit: ContactSyncSnapshot.serverLimit)
        }

        let clientSyncId = UUID().uuidString.lowercased()
        let opened: ContactSyncSessionResponse = try await send(
            path: "contacts/sync/sessions",
            method: "POST",
            body: BeginContactSyncRequest(
                clientSyncId: clientSyncId,
                totalContactCount: contacts.count,
                snapshotScope: scope
            )
        )
        try validate(
            opened.sync,
            clientSyncId: clientSyncId,
            contactCount: contacts.count,
            scope: scope
        )

        let chunkSize = opened.sync.chunkSize
        guard chunkSize > 0, chunkSize <= 500 else { throw APIClientError.invalidResponse }
        let totalProgressUnits = max(2, opened.sync.totalChunkCount + 2)
        await progress(
            ContactSyncProgress(
                phase: .uploading,
                completedUnitCount: 0,
                totalUnitCount: totalProgressUnits
            )
        )

        for chunkIndex in 0 ..< opened.sync.totalChunkCount {
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, contacts.count)
            guard start < end else { throw APIClientError.invalidResponse }
            let response: ContactSyncChunkResponse = try await send(
                path: "contacts/sync/sessions/\(opened.sync.id)/chunks/\(chunkIndex)",
                method: "PUT",
                body: ContactSyncChunkRequest(contacts: Array(contacts[start ..< end]))
            )
            try validate(
                response.sync,
                clientSyncId: clientSyncId,
                contactCount: contacts.count,
                scope: scope
            )
            guard response.chunk.index == chunkIndex,
                  response.chunk.inputCount == end - start,
                  response.chunk.acceptedCount <= response.chunk.inputCount
            else { throw APIClientError.invalidResponse }
            await progress(
                ContactSyncProgress(
                    phase: .uploading,
                    completedUnitCount: chunkIndex + 1,
                    totalUnitCount: totalProgressUnits
                )
            )
        }

        await progress(
            ContactSyncProgress(
                phase: .finalizing,
                completedUnitCount: opened.sync.totalChunkCount + 1,
                totalUnitCount: totalProgressUnits
            )
        )
        let finalized: ContactSyncSessionResponse = try await send(
            path: "contacts/sync/sessions/\(opened.sync.id)/finalize",
            method: "POST",
            body: FinalizeContactSyncRequest()
        )
        try validate(
            finalized.sync,
            clientSyncId: clientSyncId,
            contactCount: contacts.count,
            scope: scope
        )
        guard finalized.sync.status == "finalized",
              finalized.sync.missingChunkIndexes.isEmpty,
              finalized.sync.receivedContactCount == contacts.count,
              finalized.sync.storedContactCount != nil
        else { throw APIClientError.invalidResponse }

        await progress(
            ContactSyncProgress(
                phase: .refreshing,
                completedUnitCount: totalProgressUnits - 1,
                totalUnitCount: totalProgressUnits
            )
        )
        let result = try await allContacts()
        await progress(
            ContactSyncProgress(
                phase: .complete,
                completedUnitCount: totalProgressUnits,
                totalUnitCount: totalProgressUnits
            )
        )
        return result
    }

    func allContacts() async throws -> ContactListDTO {
        let pageLimit = 500
        let maximumPages = ContactSyncSnapshot.serverLimit / pageLimit
        var cursor: String?
        var seenCursors: Set<String> = []
        var contacts: [WalletContactDTO] = []

        for _ in 0 ..< maximumPages {
            var queryItems = [URLQueryItem(name: "limit", value: String(pageLimit))]
            if let cursor {
                queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let response: ContactListDTO = try await send(
                path: "contacts",
                method: "GET",
                body: ContactPageRequest(),
                queryItems: queryItems
            )
            guard let items = response.items,
                  let page = response.page,
                  let responseLimit = page.limit,
                  let hasMore = page.hasMore,
                  responseLimit > 0,
                  responseLimit <= pageLimit,
                  items.count <= responseLimit
            else { throw APIClientError.invalidResponse }
            guard contacts.count + items.count <= ContactSyncSnapshot.serverLimit else {
                throw APIClientError.invalidResponse
            }
            contacts.append(contentsOf: items)

            guard hasMore else {
                return ContactListDTO(items: contacts, page: page)
            }
            guard let next = page.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !next.isEmpty,
                  seenCursors.insert(next).inserted
            else { throw APIClientError.invalidResponse }
            cursor = next
        }

        throw APIClientError.invalidResponse
    }

    private func validate(
        _ sync: ContactSyncSessionDTO,
        clientSyncId: String,
        contactCount: Int,
        scope: ContactSyncSnapshotScope
    ) throws {
        guard UUID(uuidString: sync.id) != nil,
              sync.clientSyncId.caseInsensitiveCompare(clientSyncId) == .orderedSame,
              sync.snapshotScope == scope,
              sync.generation > 0,
              ["open", "finalized"].contains(sync.status),
              sync.chunkSize > 0,
              sync.chunkSize <= 500,
              sync.totalContactCount == contactCount,
              sync.totalChunkCount == (contactCount + sync.chunkSize - 1) / sync.chunkSize,
              sync.receivedContactCount <= contactCount,
              sync.receivedChunkCount <= sync.totalChunkCount,
              sync.acceptedContactCount <= sync.receivedContactCount,
              sync.missingChunkIndexes.allSatisfy({
                  $0 >= 0 && $0 < sync.totalChunkCount
              })
        else { throw APIClientError.invalidResponse }
    }
}

private struct BeginContactSyncRequest: Encodable {
    let clientSyncId: String
    let totalContactCount: Int
    let snapshotScope: ContactSyncSnapshotScope

    enum CodingKeys: String, CodingKey {
        case clientSyncId = "client_sync_id"
        case totalContactCount = "total_contact_count"
        case snapshotScope = "snapshot_scope"
    }
}

private struct ContactSyncChunkRequest: Encodable {
    let contacts: [ContactSyncEntry]
}

private struct FinalizeContactSyncRequest: Encodable {}
private struct ContactPageRequest: Encodable {}
private struct ContactSearchRequest: Encodable {}

private struct ContactSyncSessionResponse: Decodable {
    let sync: ContactSyncSessionDTO
}

private struct ContactSyncChunkResponse: Decodable {
    let sync: ContactSyncSessionDTO
    let chunk: ContactSyncChunkDTO
}

private struct ContactSyncSessionDTO: Decodable {
    let id: String
    let clientSyncId: String
    let snapshotScope: ContactSyncSnapshotScope
    let generation: Int
    let status: String
    let chunkSize: Int
    let totalContactCount: Int
    let totalChunkCount: Int
    let receivedContactCount: Int
    let receivedChunkCount: Int
    let acceptedContactCount: Int
    let storedContactCount: Int?
    let missingChunkIndexes: [Int]
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id, generation, status
        case clientSyncId = "client_sync_id"
        case snapshotScope = "snapshot_scope"
        case chunkSize = "chunk_size"
        case totalContactCount = "total_contact_count"
        case totalChunkCount = "total_chunk_count"
        case receivedContactCount = "received_contact_count"
        case receivedChunkCount = "received_chunk_count"
        case acceptedContactCount = "accepted_contact_count"
        case storedContactCount = "stored_contact_count"
        case missingChunkIndexes = "missing_chunk_indexes"
        case expiresAt = "expires_at"
    }
}

private struct ContactSyncChunkDTO: Decodable {
    let index: Int
    let inputCount: Int
    let acceptedCount: Int
    let replayed: Bool

    enum CodingKeys: String, CodingKey {
        case index, replayed
        case inputCount = "input_count"
        case acceptedCount = "accepted_count"
    }
}
