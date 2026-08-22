import Foundation

struct CommunicationPreferencesDTO: Codable, Equatable, Sendable {
    let version: Int
    let phoneDiscoverable: Bool
    let directMessageRequestsEnabled: Bool
    /// Retained for wire compatibility. Call admission is governed by account eligibility and
    /// directional blocks; clients must not present this value as an effective call-blocking rule.
    let incomingCallsEnabled: Bool
    let updatedAt: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case phoneDiscoverable = "phone_discoverable"
        case directMessageRequestsEnabled = "direct_message_requests_enabled"
        case incomingCallsEnabled = "incoming_calls_enabled"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        try CommunicationPrivacyDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let updatedAt = try container.decode(String.self, forKey: .updatedAt)
        guard version >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Communication preference versions must be positive."
            )
        }
        guard CommunicationPrivacyTimestamp.date(from: updatedAt) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .updatedAt,
                in: container,
                debugDescription: "Communication preference timestamps must be RFC 3339 values."
            )
        }

        self.version = version
        phoneDiscoverable = try container.decode(Bool.self, forKey: .phoneDiscoverable)
        directMessageRequestsEnabled = try container.decode(
            Bool.self,
            forKey: .directMessageRequestsEnabled
        )
        incomingCallsEnabled = try container.decode(Bool.self, forKey: .incomingCallsEnabled)
        self.updatedAt = updatedAt
    }
}

struct UpdateCommunicationPreferencesRequest: Encodable, Equatable, Sendable {
    let version: Int
    let phoneDiscoverable: Bool?
    let directMessageRequestsEnabled: Bool?
    /// Compatibility-only wire field. Setting it does not create a local call-admission guarantee.
    let incomingCallsEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case version
        case phoneDiscoverable = "phone_discoverable"
        case directMessageRequestsEnabled = "direct_message_requests_enabled"
        case incomingCallsEnabled = "incoming_calls_enabled"
    }

    init(
        version: Int,
        phoneDiscoverable: Bool? = nil,
        directMessageRequestsEnabled: Bool? = nil,
        incomingCallsEnabled: Bool? = nil
    ) throws {
        guard version >= 1 else {
            throw CommunicationPrivacyContractError.invalidPreferenceVersion
        }
        guard phoneDiscoverable != nil
            || directMessageRequestsEnabled != nil
            || incomingCallsEnabled != nil
        else {
            throw CommunicationPrivacyContractError.emptyPreferenceUpdate
        }
        self.version = version
        self.phoneDiscoverable = phoneDiscoverable
        self.directMessageRequestsEnabled = directMessageRequestsEnabled
        self.incomingCallsEnabled = incomingCallsEnabled
    }
}

/// One independently versioned preference edit. Keeping transition validation beside the wire
/// models makes the optimistic-lock contract testable without teaching UI state about server
/// version rules.
enum CommunicationPreferenceChange: Equatable, Sendable {
    case phoneDiscovery(Bool)
    case messageRequests(Bool)

    func request(version: Int) throws -> UpdateCommunicationPreferencesRequest {
        switch self {
        case .phoneDiscovery(let enabled):
            return try UpdateCommunicationPreferencesRequest(
                version: version,
                phoneDiscoverable: enabled
            )
        case .messageRequests(let enabled):
            return try UpdateCommunicationPreferencesRequest(
                version: version,
                directMessageRequestsEnabled: enabled
            )
        }
    }

    func isSatisfied(by preferences: CommunicationPreferencesDTO) -> Bool {
        switch self {
        case .phoneDiscovery(let enabled):
            return preferences.phoneDiscoverable == enabled
        case .messageRequests(let enabled):
            return preferences.directMessageRequestsEnabled == enabled
        }
    }

    /// The backend keeps no-op writes at the same version and increments a real edit exactly once.
    /// Fields omitted by this patch must remain unchanged.
    func isValidTransition(
        from previous: CommunicationPreferencesDTO,
        to updated: CommunicationPreferencesDTO
    ) -> Bool {
        let expectedVersion: Int
        if isSatisfied(by: previous) {
            expectedVersion = previous.version
        } else {
            let increment = previous.version.addingReportingOverflow(1)
            guard !increment.overflow else { return false }
            expectedVersion = increment.partialValue
        }
        guard updated.version == expectedVersion, isSatisfied(by: updated) else {
            return false
        }
        switch self {
        case .phoneDiscovery:
            return updated.directMessageRequestsEnabled
                    == previous.directMessageRequestsEnabled
                && updated.incomingCallsEnabled == previous.incomingCallsEnabled
        case .messageRequests:
            return updated.phoneDiscoverable == previous.phoneDiscoverable
                && updated.incomingCallsEnabled == previous.incomingCallsEnabled
        }
    }
}

struct CommunicationBlockDTO: Codable, Equatable, Sendable {
    let userId: String
    let blocked: Bool
    let blockedAt: String?
    let unblockedAt: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case userId = "user_id"
        case blocked
        case blockedAt = "blocked_at"
        case unblockedAt = "unblocked_at"
    }

    init(from decoder: Decoder) throws {
        try CommunicationPrivacyDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawUserId = try container.decode(String.self, forKey: .userId)
        guard rawUserId == rawUserId.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: rawUserId)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .userId,
                in: container,
                debugDescription: "Blocked users require a valid public UUID."
            )
        }
        guard container.contains(.blockedAt), container.contains(.unblockedAt) else {
            let missingKey: CodingKeys = container.contains(.blockedAt) ? .unblockedAt : .blockedAt
            throw DecodingError.keyNotFound(
                missingKey,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Block timestamps must be present, including null values."
                )
            )
        }

        let blocked = try container.decode(Bool.self, forKey: .blocked)
        let blockedAt = try container.decodeIfPresent(String.self, forKey: .blockedAt)
        let unblockedAt = try container.decodeIfPresent(String.self, forKey: .unblockedAt)
        let blockedDate = try CommunicationPrivacyDecoding.validatedTimestamp(
            blockedAt,
            forKey: .blockedAt,
            in: container
        )
        let unblockedDate = try CommunicationPrivacyDecoding.validatedTimestamp(
            unblockedAt,
            forKey: .unblockedAt,
            in: container
        )

        if blocked {
            guard blockedDate != nil, unblockedDate == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .blocked,
                    in: container,
                    debugDescription: "An active block requires only a blocked timestamp."
                )
            }
        } else {
            let hasNoHistory = blockedDate == nil && unblockedDate == nil
            let hasCompleteHistory = blockedDate != nil && unblockedDate != nil
            guard hasNoHistory || hasCompleteHistory else {
                throw DecodingError.dataCorruptedError(
                    forKey: .blocked,
                    in: container,
                    debugDescription: "An inactive block requires complete or empty timestamp history."
                )
            }
            if let blockedDate, let unblockedDate, unblockedDate < blockedDate {
                throw DecodingError.dataCorruptedError(
                    forKey: .unblockedAt,
                    in: container,
                    debugDescription: "A block cannot be removed before it was created."
                )
            }
        }

        userId = identifier.uuidString.lowercased()
        self.blocked = blocked
        self.blockedAt = blockedAt
        self.unblockedAt = unblockedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encode(blocked, forKey: .blocked)
        if let blockedAt {
            try container.encode(blockedAt, forKey: .blockedAt)
        } else {
            try container.encodeNil(forKey: .blockedAt)
        }
        if let unblockedAt {
            try container.encode(unblockedAt, forKey: .unblockedAt)
        } else {
            try container.encodeNil(forKey: .unblockedAt)
        }
    }
}

struct CommunicationBlockPageDTO: Decodable, Equatable, Sendable {
    struct Page: Decodable, Equatable, Sendable {
        let nextCursor: String?
        let hasMore: Bool
        let limit: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case nextCursor = "next_cursor"
            case hasMore = "has_more"
            case limit
        }

        init(from decoder: Decoder) throws {
            try CommunicationPrivacyDecoding.rejectUnknownKeys(
                from: decoder,
                allowed: CodingKeys.allCases.map(\.rawValue)
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.nextCursor) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.nextCursor,
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Block pages require an explicit continuation value."
                    )
                )
            }
            let nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            let hasMore = try container.decode(Bool.self, forKey: .hasMore)
            let limit = try container.decode(Int.self, forKey: .limit)
            guard (1 ... CommunicationBlockPageAccumulator.pageLimit).contains(limit) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .limit,
                    in: container,
                    debugDescription: "Block page limits must be between 1 and 100."
                )
            }

            if hasMore {
                guard let nextCursor,
                      CommunicationPrivacyCursor.isValid(nextCursor)
                else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .nextCursor,
                        in: container,
                        debugDescription: "A continuing block page requires a bounded opaque cursor."
                    )
                }
            } else if nextCursor != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .nextCursor,
                    in: container,
                    debugDescription: "A terminal block page cannot provide another cursor."
                )
            }

            self.nextCursor = nextCursor
            self.hasMore = hasMore
            self.limit = limit
        }
    }

    let items: [CommunicationBlockDTO]
    let page: Page

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case items, page
    }

    init(from decoder: Decoder) throws {
        try CommunicationPrivacyDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decode([CommunicationBlockDTO].self, forKey: .items)
        let page = try container.decode(Page.self, forKey: .page)
        guard items.count <= page.limit, items.allSatisfy(\.blocked) else {
            throw DecodingError.dataCorruptedError(
                forKey: .items,
                in: container,
                debugDescription: "Active block pages must fit the requested limit."
            )
        }
        self.items = items
        self.page = page
    }
}

/// Validates and accumulates every page from `GET /communications/blocks`. The finite ceiling
/// prevents a malformed service from keeping a refresh alive indefinitely while allowing a large
/// account to retain up to 10,000 active blocks without an unbounded request chain.
struct CommunicationBlockPageAccumulator {
    static let pageLimit = 100
    static let maximumPages = 100
    static let maximumCursorLength = 2_048

    private let requestedLimit: Int
    private let maximumPageCount: Int
    private var seenUserIds: Set<String> = []
    private var seenCursors: Set<String> = []
    private(set) var blocks: [CommunicationBlockDTO] = []
    private(set) var nextCursor: String?
    private(set) var pageCount = 0

    init(
        requestedLimit: Int = Self.pageLimit,
        maximumPageCount: Int = Self.maximumPages
    ) {
        precondition((1 ... Self.pageLimit).contains(requestedLimit))
        precondition(maximumPageCount > 0)
        self.requestedLimit = requestedLimit
        self.maximumPageCount = maximumPageCount
    }

    /// Returns `true` only when the server explicitly marks the accumulated result complete.
    mutating func append(_ response: CommunicationBlockPageDTO) throws -> Bool {
        guard pageCount < maximumPageCount,
              response.page.limit == requestedLimit,
              response.items.count <= requestedLimit,
              response.items.allSatisfy(\.blocked)
        else { throw CommunicationPrivacyContractError.invalidBlockPage }

        let continuation: String?
        if response.page.hasMore {
            guard pageCount + 1 < maximumPageCount,
                  let cursor = response.page.nextCursor,
                  CommunicationPrivacyCursor.isValid(cursor),
                  !seenCursors.contains(cursor)
            else { throw CommunicationPrivacyContractError.invalidBlockPage }
            continuation = cursor
        } else {
            guard response.page.nextCursor == nil else {
                throw CommunicationPrivacyContractError.invalidBlockPage
            }
            continuation = nil
        }

        for block in response.items {
            guard seenUserIds.insert(block.userId).inserted else { continue }
            blocks.append(block)
        }
        pageCount += 1
        nextCursor = continuation
        if let continuation { seenCursors.insert(continuation) }
        return !response.page.hasMore
    }
}

struct CommunicationBlockedPerson: Equatable, Identifiable, Sendable {
    let userId: String
    let displayName: String
    let detail: String?
    let avatarURL: String?

    var id: String { userId }
}

struct CommunicationBlockCandidate: Equatable, Identifiable, Sendable {
    let userId: String
    let displayName: String
    let detail: String?
    let avatarURL: String?

    var id: String { userId }
}

/// Last server-confirmed privacy authority, retained only inside `SecureLocalStore`'s encrypted,
/// account-bound projection. This keeps blocks effective in offline recipient pickers without
/// treating cached state as authority for any server mutation.
struct CommunicationPrivacyCache: Codable, Equatable, Sendable {
    static let maximumBlockCount =
        CommunicationBlockPageAccumulator.pageLimit
            * CommunicationBlockPageAccumulator.maximumPages

    let ownerUserId: String
    let preferences: CommunicationPreferencesDTO
    let blocks: [CommunicationBlockDTO]
    let refreshedAt: Date

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ownerUserId = "owner_user_id"
        case preferences, blocks
        case refreshedAt = "refreshed_at"
    }

    init?(
        ownerUserId: String,
        preferences: CommunicationPreferencesDTO,
        blocks: [CommunicationBlockDTO],
        refreshedAt: Date = Date()
    ) {
        guard let ownerUserId = CommunicationPrivacyIdentifier.canonicalUUID(ownerUserId),
              blocks.count <= Self.maximumBlockCount,
              blocks.allSatisfy({ $0.blocked && $0.userId != ownerUserId }),
              Set(blocks.map(\.userId)).count == blocks.count
        else { return nil }
        self.ownerUserId = ownerUserId
        self.preferences = preferences
        self.blocks = blocks
        self.refreshedAt = refreshedAt
    }

    init(from decoder: Decoder) throws {
        try CommunicationPrivacyDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawOwnerUserId = try container.decode(String.self, forKey: .ownerUserId)
        let preferences = try container.decode(
            CommunicationPreferencesDTO.self,
            forKey: .preferences
        )
        let blocks = try container.decode([CommunicationBlockDTO].self, forKey: .blocks)
        let refreshedAt = try container.decode(Date.self, forKey: .refreshedAt)
        guard let cache = Self(
            ownerUserId: rawOwnerUserId,
            preferences: preferences,
            blocks: blocks,
            refreshedAt: refreshedAt
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .blocks,
                in: container,
                debugDescription: "Communication privacy cache ownership is invalid."
            )
        }
        self = cache
    }
}

enum CommunicationPrivacyAccessDecision: Equatable, Sendable {
    case allowed
    case blocked
    case unavailable
}

/// Outbound messaging and calling are allowed only from a complete server-confirmed projection
/// belonging to the current account. A missing, malformed, cross-account, or partially loaded
/// projection therefore fails closed while an encrypted cached projection remains useful offline.
enum CommunicationPrivacyAccessPolicy {
    static func isCompleteProjection(
        ownerUserID: String?,
        hasLoadedCompleteProjection: Bool,
        blocks: [CommunicationBlockDTO]
    ) -> Bool {
        guard hasLoadedCompleteProjection,
              let ownerUserID = CommunicationPrivacyIdentifier.canonicalUUID(ownerUserID),
              blocks.count <= CommunicationPrivacyCache.maximumBlockCount,
              blocks.allSatisfy({ $0.blocked && $0.userId != ownerUserID }),
              Set(blocks.map(\.userId)).count == blocks.count
        else { return false }
        return true
    }

    static func decision(
        ownerUserID: String?,
        recipientUserID: String?,
        hasLoadedCompleteProjection: Bool,
        blocks: [CommunicationBlockDTO]
    ) -> CommunicationPrivacyAccessDecision {
        guard isCompleteProjection(
                  ownerUserID: ownerUserID,
                  hasLoadedCompleteProjection: hasLoadedCompleteProjection,
                  blocks: blocks
              ),
              let ownerUserID = CommunicationPrivacyIdentifier.canonicalUUID(ownerUserID),
              let recipientUserID = CommunicationPrivacyIdentifier.canonicalUUID(recipientUserID),
              ownerUserID != recipientUserID
        else { return .unavailable }
        return blocks.contains(where: { $0.userId == recipientUserID }) ? .blocked : .allowed
    }

    static func decision(
        ownerUserID: String?,
        recipientUserID: String?,
        cache: CommunicationPrivacyCache?
    ) -> CommunicationPrivacyAccessDecision {
        guard let ownerUserID = CommunicationPrivacyIdentifier.canonicalUUID(ownerUserID),
              let cache,
              cache.ownerUserId == ownerUserID
        else { return .unavailable }
        return decision(
            ownerUserID: ownerUserID,
            recipientUserID: recipientUserID,
            hasLoadedCompleteProjection: true,
            blocks: cache.blocks
        )
    }
}

enum CommunicationBlockedPersonResolver {
    static func resolve(
        blocks: [CommunicationBlockDTO],
        contacts: [WalletContactDTO],
        conversations: [Conversation],
        currentUserID: String?
    ) -> [CommunicationBlockedPerson] {
        let contactByUserId = contacts.reduce(into: [String: WalletContactDTO]()) { result, contact in
            guard let userId = ContactRecipientDirectory.recipientUserId(for: contact) else { return }
            if let existing = result[userId] {
                result[userId] = preferredContact(existing, contact)
            } else {
                result[userId] = contact
            }
        }
        let currentUserId = canonicalUUID(currentUserID)
        var seenUserIds: Set<String> = []

        return blocks.compactMap { block in
            guard block.blocked, seenUserIds.insert(block.userId).inserted else { return nil }
            let contact = contactByUserId[block.userId]
            let conversationTitle = directConversationTitle(
                for: block.userId,
                currentUserId: currentUserId,
                conversations: conversations
            )
            let contactName = contact?.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName: String
            if let contactName, !contactName.isEmpty {
                displayName = contactName
            } else {
                displayName = conversationTitle ?? "Kit Pay user"
            }
            return CommunicationBlockedPerson(
                userId: block.userId,
                displayName: displayName,
                detail: detail(for: contact),
                avatarURL: contact?.avatarURL
            )
        }
    }

    private static func preferredContact(
        _ existing: WalletContactDTO,
        _ candidate: WalletContactDTO
    ) -> WalletContactDTO {
        let existingName = existing.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateName = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if existingName.isEmpty != candidateName.isEmpty {
            return existingName.isEmpty ? candidate : existing
        }
        if (existing.tag == nil) != (candidate.tag == nil) {
            return existing.tag == nil ? candidate : existing
        }
        if (existing.avatarURL == nil) != (candidate.avatarURL == nil) {
            return existing.avatarURL == nil ? candidate : existing
        }
        return existing
    }

    private static func directConversationTitle(
        for targetUserId: String,
        currentUserId: String?,
        conversations: [Conversation]
    ) -> String? {
        guard let currentUserId else { return nil }
        for conversation in conversations {
            let members = conversation.participantUserIds.compactMap(canonicalUUID)
            guard members.count == conversation.participantUserIds.count,
                  members.count == 2,
                  Set(members) == Set([currentUserId, targetUserId])
            else { continue }
            let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private static func detail(for contact: WalletContactDTO?) -> String? {
        guard let contact else { return nil }
        if let rawTag = contact.tag?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let tag = rawTag.hasPrefix("@") ? String(rawTag.dropFirst()) : rawTag
            if (3 ... 32).contains(tag.count),
               tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
                return "@\(tag)"
            }
        }
        let phone = contact.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        return phone.isEmpty ? nil : phone
    }

    private static func canonicalUUID(_ rawValue: String?) -> String? {
        guard let rawValue,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: rawValue)
        else { return nil }
        return identifier.uuidString.lowercased()
    }
}

/// Produces one stable, searchable row per currently visible Kit Pay contact. Raw address-book
/// rows can contain the same member more than once, so the picker deduplicates by public user ID
/// and never offers the signed-in or already-blocked account.
enum CommunicationBlockCandidateResolver {
    static func resolve(
        contacts: [WalletContactDTO],
        blocks: [CommunicationBlockDTO],
        currentUserID: String?
    ) -> [CommunicationBlockCandidate] {
        guard let currentUserID = CommunicationPrivacyIdentifier.canonicalUUID(currentUserID)
        else { return [] }
        let blockedUserIDs = Set(blocks.lazy.filter(\.blocked).map(\.userId))
        var contactsByUserID: [String: WalletContactDTO] = [:]
        contactsByUserID.reserveCapacity(min(contacts.count, 10_000))

        for contact in contacts where contact.isKitUser == true {
            guard let userID = ContactRecipientDirectory.recipientUserId(for: contact),
                  userID != currentUserID,
                  !blockedUserIDs.contains(userID)
            else { continue }
            if let existing = contactsByUserID[userID] {
                contactsByUserID[userID] = preferredContact(existing, contact)
            } else {
                contactsByUserID[userID] = contact
            }
        }

        return contactsByUserID.map { userID, contact in
            CommunicationBlockCandidate(
                userId: userID,
                displayName: contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? "Kit Pay user",
                detail: detail(for: contact),
                avatarURL: contact.avatarURL
            )
        }.sorted { lhs, rhs in
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.userId < rhs.userId
        }
    }

    private static func preferredContact(
        _ existing: WalletContactDTO,
        _ candidate: WalletContactDTO
    ) -> WalletContactDTO {
        let existingName = existing.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateName = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if existingName.isEmpty != candidateName.isEmpty {
            return existingName.isEmpty ? candidate : existing
        }
        if (existing.tag == nil) != (candidate.tag == nil) {
            return existing.tag == nil ? candidate : existing
        }
        if (existing.avatarURL == nil) != (candidate.avatarURL == nil) {
            return existing.avatarURL == nil ? candidate : existing
        }
        return existing
    }

    private static func detail(for contact: WalletContactDTO) -> String? {
        if let rawTag = contact.tag?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let tag = rawTag.hasPrefix("@") ? String(rawTag.dropFirst()) : rawTag
            if (3 ... 32).contains(tag.count),
               tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
                return "@\(tag)"
            }
        }
        let phone = contact.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        return phone.isEmpty ? nil : phone
    }
}

enum CommunicationPrivacyOperation: CaseIterable, Equatable, Hashable, Sendable {
    case load
    case updatePreferences
    case block
    case unblock
}

enum CommunicationPrivacyErrorCopy {
    static func message(for error: Error, operation: CommunicationPrivacyOperation) -> String {
        if let payload = error as? APIErrorPayload {
            switch payload.code.uppercased() {
            case "COMMUNICATION_PREFERENCES_VERSION_CONFLICT":
                return "Your communication settings changed elsewhere. Refresh them before trying again."
            case "COMMUNICATION_TARGET_UNAVAILABLE":
                return "This person is unavailable for this action."
            case "ACCOUNT_RESTRICTED":
                return "Communication privacy changes are unavailable for this account."
            default:
                if isRateLimited(status: payload.httpStatus, code: payload.code) {
                    return rateLimitedMessage
                }
            }
        }
        if let clientError = error as? APIClientError {
            switch clientError {
            case .signedOut:
                return "Sign in again to manage communication privacy."
            case .httpStatus(let status):
                if isRateLimited(status: status, code: nil) { return rateLimitedMessage }
            case .httpResponse(let status, _):
                if isRateLimited(status: status, code: nil) { return rateLimitedMessage }
            case .invalidResponse, .invalidPayload, .invalidURL:
                break
            }
        }

        switch operation {
        case .load:
            return "Kit Pay could not load your communication privacy settings. Please try again."
        case .updatePreferences:
            return "Kit Pay could not save your communication settings. Refresh them and try again."
        case .block:
            return "Kit Pay could not block this person. Please try again."
        case .unblock:
            return "Kit Pay could not unblock this person. Please try again."
        }
    }

    private static let rateLimitedMessage =
        "Too many requests were made. Please wait a moment and try again."

    private static func isRateLimited(status: Int?, code: String?) -> Bool {
        if status == 429 { return true }
        guard let code = code?.uppercased() else { return false }
        return code == "TOO_MANY_REQUESTS" || code.contains("RATE_LIMIT")
    }
}

enum CommunicationPrivacyContractError: Error, Equatable {
    case invalidPreferenceVersion
    case emptyPreferenceUpdate
    case invalidBlockPage
}

enum CommunicationPrivacyIdentifier {
    static func canonicalUUID(_ rawValue: String?) -> String? {
        guard let rawValue,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: rawValue)
        else { return nil }
        return identifier.uuidString.lowercased()
    }
}

private enum CommunicationPrivacyCursor {
    static func isValid(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= CommunicationBlockPageAccumulator.maximumCursorLength
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}

private enum CommunicationPrivacyTimestamp {
    static func date(from value: String) -> Date? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#,
                options: .regularExpression
              ) != nil
        else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private enum CommunicationPrivacyDecoding {
    static func rejectUnknownKeys(from decoder: Decoder, allowed: [String]) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowedKeys = Set(allowed)
        guard let unknown = container.allKeys.first(where: { !allowedKeys.contains($0.stringValue) })
        else { return }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath + [unknown],
                debugDescription: "Unsupported communication privacy field: \(unknown.stringValue)."
            )
        )
    }

    static func validatedTimestamp<Key: CodingKey>(
        _ value: String?,
        forKey key: Key,
        in container: KeyedDecodingContainer<Key>
    ) throws -> Date? {
        guard let value else { return nil }
        guard let date = CommunicationPrivacyTimestamp.date(from: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Communication block timestamps must be RFC 3339 values."
            )
        }
        return date
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
