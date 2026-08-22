import Foundation

enum AccountDeletionContract {
    static let capabilityKey = "account_deletion"
    static let purpose = "account_deletion"
    static let confirmation = "DELETE"
    static let acceptedState = "accepted"
    static let pendingAccountStatus = "deletion_pending"
    static let fallbackURLString = "https://pay.kit.africa/account-deletion"

    static func protectedFlowAvailable(features: [String: Bool?]?) -> Bool {
        features?[capabilityKey] == true
    }

    static func trustedDeletionURL(_ value: String) -> URL? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: value),
              components.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              components.host?.caseInsensitiveCompare("pay.kit.africa") == .orderedSame,
              components.path == "/account-deletion",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url,
              url.absoluteString == value
        else { return nil }
        return url
    }

    static var trustedFallbackURL: URL? {
        trustedDeletionURL(fallbackURLString)
    }

    static func canonicalAccountID(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        return identifier.uuidString.lowercased()
    }

    static func validPIN(_ value: String) -> Bool {
        value.range(of: #"\A[0-9]{4}\z"#, options: .regularExpression) != nil
    }

    static func validStepUpToken(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && (64 ... 256).contains(value.utf8.count)
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
    }
}

/// Crash-safe ownership for the local cleanup that follows an accepted deletion receipt.
/// The marker contains no access token, refresh token, message content, or profile data and is
/// stored in the device-only Keychain before any local account projection is erased.
struct PendingAcceptedAccountDeletion: Codable, Equatable, Sendable {
    let accountID: String
    let sessionID: String
    let receiptID: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case accountID = "account_id"
        case sessionID = "session_id"
        case receiptID = "receipt_id"
    }

    init(accountID: String, sessionID: String, receiptID: String) throws {
        guard let canonicalAccountID = Self.canonicalUUID(accountID),
              let canonicalSessionID = Self.canonicalUUID(sessionID),
              let canonicalReceiptID = Self.canonicalUUID(receiptID)
        else { throw AccountDeletionPurgeMarkerError.invalidMarker }
        self.accountID = canonicalAccountID
        self.sessionID = canonicalSessionID
        self.receiptID = canonicalReceiptID
    }

    init(from decoder: Decoder) throws {
        try AccountDeletionDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(String.self, forKey: .accountID),
            sessionID: container.decode(String.self, forKey: .sessionID),
            receiptID: container.decode(String.self, forKey: .receiptID)
        )
    }

    private static func canonicalUUID(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        return identifier.uuidString.lowercased()
    }
}

/// Durable fence written before the irreversible request leaves the device. If the process dies
/// before an accepted receipt is persisted, cached account state remains hidden rather than being
/// restored offline under credentials the server may already have revoked.
struct PendingAccountDeletionAttempt: Codable, Equatable, Sendable {
    let accountID: String
    let sessionID: String
    let attemptID: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case accountID = "account_id"
        case sessionID = "session_id"
        case attemptID = "attempt_id"
    }

    init(accountID: String, sessionID: String, attemptID: String) throws {
        guard let canonicalAccountID = AccountDeletionContract.canonicalAccountID(accountID),
              let canonicalSessionID = AccountDeletionContract.canonicalAccountID(sessionID),
              let canonicalAttemptID = AccountDeletionContract.canonicalAccountID(attemptID)
        else { throw AccountDeletionPurgeMarkerError.invalidMarker }
        self.accountID = canonicalAccountID
        self.sessionID = canonicalSessionID
        self.attemptID = canonicalAttemptID
    }

    init(from decoder: Decoder) throws {
        try AccountDeletionDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: container.decode(String.self, forKey: .accountID),
            sessionID: container.decode(String.self, forKey: .sessionID),
            attemptID: container.decode(String.self, forKey: .attemptID)
        )
    }

    func matches(_ accepted: PendingAcceptedAccountDeletion) -> Bool {
        accountID == accepted.accountID && sessionID == accepted.sessionID
    }
}

enum AccountDeletionPurgeMarkerError: Error, Equatable {
    case invalidMarker
    case conflictingMarker
    case persistenceVerificationFailed
}

/// Serializes one accepted-deletion marker independently of the encrypted projection it guards.
/// Keychain persistence lets a later launch retry even when the state-file purge was interrupted.
actor AcceptedAccountDeletionPurgeStore {
    static let shared = AcceptedAccountDeletionPurgeStore()

    typealias Load = @Sendable () throws -> Data?
    typealias Save = @Sendable (Data) throws -> Void
    typealias Remove = @Sendable () throws -> Void

    private let load: Load
    private let save: Save
    private let remove: Remove

    init(
        load: @escaping Load = {
            try KeychainStore.data(for: "kit-pay-accepted-account-deletion-v1")
        },
        save: @escaping Save = {
            try KeychainStore.set($0, for: "kit-pay-accepted-account-deletion-v1")
        },
        remove: @escaping Remove = {
            try KeychainStore.remove("kit-pay-accepted-account-deletion-v1")
        }
    ) {
        self.load = load
        self.save = save
        self.remove = remove
    }

    func pending() throws -> PendingAcceptedAccountDeletion? {
        guard let data = try load() else { return nil }
        do {
            return try JSONDecoder().decode(PendingAcceptedAccountDeletion.self, from: data)
        } catch {
            throw AccountDeletionPurgeMarkerError.invalidMarker
        }
    }

    func schedule(_ marker: PendingAcceptedAccountDeletion) throws {
        if let existing = try pending() {
            guard existing == marker else {
                throw AccountDeletionPurgeMarkerError.conflictingMarker
            }
            return
        }
        try save(JSONEncoder().encode(marker))
        guard try pending() == marker else {
            throw AccountDeletionPurgeMarkerError.persistenceVerificationFailed
        }
    }

    @discardableResult
    func completeIfCurrent(_ marker: PendingAcceptedAccountDeletion) throws -> Bool {
        guard try pending() == marker else { return false }
        try remove()
        guard try load() == nil else {
            throw AccountDeletionPurgeMarkerError.persistenceVerificationFailed
        }
        return true
    }
}

actor AccountDeletionAttemptStore {
    static let shared = AccountDeletionAttemptStore()

    typealias Load = @Sendable () throws -> Data?
    typealias Save = @Sendable (Data) throws -> Void
    typealias Remove = @Sendable () throws -> Void

    private let load: Load
    private let save: Save
    private let remove: Remove

    init(
        load: @escaping Load = {
            try KeychainStore.data(for: "kit-pay-account-deletion-attempt-v1")
        },
        save: @escaping Save = {
            try KeychainStore.set($0, for: "kit-pay-account-deletion-attempt-v1")
        },
        remove: @escaping Remove = {
            try KeychainStore.remove("kit-pay-account-deletion-attempt-v1")
        }
    ) {
        self.load = load
        self.save = save
        self.remove = remove
    }

    func pending() throws -> PendingAccountDeletionAttempt? {
        guard let data = try load() else { return nil }
        do {
            return try JSONDecoder().decode(PendingAccountDeletionAttempt.self, from: data)
        } catch {
            throw AccountDeletionPurgeMarkerError.invalidMarker
        }
    }

    func schedule(_ marker: PendingAccountDeletionAttempt) throws {
        if let existing = try pending() {
            guard existing == marker else {
                throw AccountDeletionPurgeMarkerError.conflictingMarker
            }
            return
        }
        try save(JSONEncoder().encode(marker))
        guard try pending() == marker else {
            throw AccountDeletionPurgeMarkerError.persistenceVerificationFailed
        }
    }

    @discardableResult
    func completeIfCurrent(_ marker: PendingAccountDeletionAttempt) throws -> Bool {
        guard try pending() == marker else { return false }
        try remove()
        guard try load() == nil else {
            throw AccountDeletionPurgeMarkerError.persistenceVerificationFailed
        }
        return true
    }
}

enum AccountDeletionContractError: LocalizedError, Equatable {
    case invalidPreflight
    case invalidConfirmation
    case invalidPIN
    case invalidStepUp
    case invalidReceipt

    var errorDescription: String? {
        switch self {
        case .invalidPreflight:
            "Protected account deletion is currently unavailable."
        case .invalidConfirmation:
            "Type DELETE exactly to continue."
        case .invalidPIN:
            "Enter your four-digit wallet PIN."
        case .invalidStepUp:
            "Kit Pay could not verify this account deletion approval."
        case .invalidReceipt:
            "Kit Pay could not confirm the account deletion request."
        }
    }
}

enum AccountDeletionSubmissionError: LocalizedError, Equatable {
    case unavailable
    case operationInProgress
    case accountChanged
    case completionUncertain
    case acceptedForPreviousSession
    case acceptedButLocalCleanupFailed

    var requiresSupportResolution: Bool {
        self == .completionUncertain
    }

    var deletionWasAccepted: Bool {
        self == .acceptedForPreviousSession || self == .acceptedButLocalCleanupFailed
    }

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Protected account deletion is currently unavailable."
        case .operationInProgress:
            "An account deletion request is already in progress."
        case .accountChanged:
            "The signed-in account changed before deletion could be submitted."
        case .completionUncertain:
            "Kit Pay could not confirm whether the request was accepted. Do not submit it again. Use account deletion support to resolve this safely."
        case .acceptedForPreviousSession:
            "The deletion request was accepted for the previous signed-in session."
        case .acceptedButLocalCleanupFailed:
            "The deletion request was accepted, but this device could not finish removing local account data."
        }
    }
}

enum AccountSignOutDataPolicy: Equatable {
    case ordinaryLogout
    case acceptedAccountDeletion

    var preserveCommunicationHistory: Bool {
        switch self {
        case .ordinaryLogout: true
        case .acceptedAccountDeletion: false
        }
    }
}

struct AccountDeletionRequirementDTO: Codable, Equatable, Sendable, Identifiable {
    let code: String
    let message: String

    var id: String { code }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code, message
    }

    init(from decoder: Decoder) throws {
        try AccountDeletionDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        guard AccountDeletionDecoding.isSafeText(code, maximumUTF8Count: 80),
              AccountDeletionDecoding.isSafeText(message, maximumUTF8Count: 500)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .message,
                in: container,
                debugDescription: "Account deletion requirements must contain bounded text."
            )
        }
        self.code = code
        self.message = message
    }
}

struct AccountDeletionNoticeDTO: Codable, Equatable, Sendable {
    let version: String
    let publicURL: String
    let deletedCategories: [String]
    let retainedCategories: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case publicURL = "public_url"
        case deletedCategories = "deleted_categories"
        case retainedCategories = "retained_categories"
    }

    init(from decoder: Decoder) throws {
        try AccountDeletionDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .version)
        let publicURL = try container.decode(String.self, forKey: .publicURL)
        let deletedCategories = try container.decode([String].self, forKey: .deletedCategories)
        let retainedCategories = try container.decode([String].self, forKey: .retainedCategories)
        guard version.range(
            of: #"^kit-account-deletion-[0-9]{4}-(?:0[1-9]|1[0-2])$"#,
            options: .regularExpression
        ) != nil,
              AccountDeletionContract.trustedDeletionURL(publicURL) != nil,
              AccountDeletionDecoding.validCategoryList(deletedCategories),
              AccountDeletionDecoding.validCategoryList(retainedCategories)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "The account deletion notice is not trusted."
            )
        }
        self.version = version
        self.publicURL = publicURL
        self.deletedCategories = deletedCategories
        self.retainedCategories = retainedCategories
    }
}

struct AccountDeletionStepUpDTO: Codable, Equatable, Sendable {
    let purpose: String
    let intent: [String: String?]

    var accountID: String {
        guard let storedValue = intent["account_id"],
              let accountID = storedValue
        else { return "" }
        return accountID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case purpose, intent
    }

    init(from decoder: Decoder) throws {
        try AccountDeletionDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let purpose = try container.decode(String.self, forKey: .purpose)
        let intent = try container.decode([String: String?].self, forKey: .intent)
        let accountID = intent["account_id"] ?? nil
        let action = intent["action"] ?? nil
        guard purpose == AccountDeletionContract.purpose,
              Set(intent.keys) == ["account_id", "action"],
              let accountID,
              let identifier = UUID(uuidString: accountID),
              identifier.uuidString.lowercased() == accountID,
              action == "delete_account"
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .intent,
                in: container,
                debugDescription: "The deletion authorization is not bound to one account."
            )
        }
        self.purpose = purpose
        self.intent = intent
    }
}

struct AccountDeletionPreflightDTO: Codable, Equatable, Sendable {
    let state: String
    let canRequest: Bool
    let requiresSupport: Bool?
    let closureRequirements: [AccountDeletionRequirementDTO]
    let stepUp: AccountDeletionStepUpDTO
    let confirmationText: String
    let notice: AccountDeletionNoticeDTO

    var purpose: String { stepUp.purpose }
    var intent: [String: String?] { stepUp.intent }
    var accountID: String { stepUp.accountID }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case state
        case canRequest = "can_request"
        case requiresSupport = "requires_support"
        case closureRequirements = "closure_requirements"
        case stepUp = "step_up"
        case confirmationText = "confirmation_text"
        case notice
    }

    init(from decoder: Decoder) throws {
        try AccountDeletionDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        let canRequest = try container.decode(Bool.self, forKey: .canRequest)
        let requiresSupport = try container.decodeIfPresent(Bool.self, forKey: .requiresSupport)
        let closureRequirements = try container.decode(
            [AccountDeletionRequirementDTO].self,
            forKey: .closureRequirements
        )
        let stepUp = try container.decode(AccountDeletionStepUpDTO.self, forKey: .stepUp)
        let confirmationText = try container.decode(String.self, forKey: .confirmationText)
        let notice = try container.decode(AccountDeletionNoticeDTO.self, forKey: .notice)
        guard state == "available",
              canRequest,
              confirmationText == AccountDeletionContract.confirmation,
              closureRequirements.count <= 32,
              Set(closureRequirements.map(\.code)).count == closureRequirements.count
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Account deletion is not available under this response."
            )
        }
        self.state = state
        self.canRequest = canRequest
        self.requiresSupport = requiresSupport
        self.closureRequirements = closureRequirements
        self.stepUp = stepUp
        self.confirmationText = confirmationText
        self.notice = notice
    }
}

struct RequestAccountDeletionDTO: Encodable, Equatable, Sendable {
    let confirmation: String

    init(confirmation: String) throws {
        guard confirmation == AccountDeletionContract.confirmation else {
            throw AccountDeletionContractError.invalidConfirmation
        }
        self.confirmation = confirmation
    }
}

struct AccountDeletionReceiptDTO: Codable, Equatable, Sendable {
    let receiptID: String
    let state: String
    let accountStatus: String
    let requestedAt: String
    let requiresSupport: Bool?
    let closureRequirements: [AccountDeletionRequirementDTO]
    let notice: AccountDeletionNoticeDTO

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case receiptID = "receipt_id"
        case state
        case accountStatus = "account_status"
        case requestedAt = "requested_at"
        case requiresSupport = "requires_support"
        case closureRequirements = "closure_requirements"
        case notice
    }

    init(from decoder: Decoder) throws {
        try AccountDeletionDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let receiptID = try container.decode(String.self, forKey: .receiptID)
        let state = try container.decode(String.self, forKey: .state)
        let accountStatus = try container.decode(String.self, forKey: .accountStatus)
        let requestedAt = try container.decode(String.self, forKey: .requestedAt)
        let requiresSupport = try container.decodeIfPresent(Bool.self, forKey: .requiresSupport)
        let closureRequirements = try container.decode(
            [AccountDeletionRequirementDTO].self,
            forKey: .closureRequirements
        )
        let notice = try container.decode(AccountDeletionNoticeDTO.self, forKey: .notice)
        guard let identifier = UUID(uuidString: receiptID),
              identifier.uuidString.lowercased() == receiptID,
              state == AccountDeletionContract.acceptedState,
              accountStatus == AccountDeletionContract.pendingAccountStatus,
              AccountDeletionDecoding.isRFC3339(requestedAt),
              closureRequirements.count <= 32,
              Set(closureRequirements.map(\.code)).count == closureRequirements.count
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "The account deletion receipt is not an accepted request."
            )
        }
        self.receiptID = receiptID
        self.state = state
        self.accountStatus = accountStatus
        self.requestedAt = requestedAt
        self.requiresSupport = requiresSupport
        self.closureRequirements = closureRequirements
        self.notice = notice
    }
}

@MainActor
final class AccountDeletionSubmissionGate {
    private(set) var isSubmitting = false

    func begin() -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        return true
    }

    func finish() {
        isSubmitting = false
    }
}

private enum AccountDeletionDecoding {
    static func rejectUnknownKeys(from decoder: Decoder, allowed: [String]) throws {
        let container = try decoder.container(keyedBy: AccountDeletionAnyCodingKey.self)
        let allowedKeys = Set(allowed)
        guard let unknown = container.allKeys.first(where: {
            !allowedKeys.contains($0.stringValue)
        }) else { return }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath + [unknown],
                debugDescription: "Unsupported account deletion field: \(unknown.stringValue)."
            )
        )
    }

    static func isSafeText(_ value: String, maximumUTF8Count: Int) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && value.utf8.count <= maximumUTF8Count
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    static func validCategoryList(_ values: [String]) -> Bool {
        values.count <= 64
            && Set(values).count == values.count
            && values.allSatisfy { isSafeText($0, maximumUTF8Count: 200) }
    }

    static func isRFC3339(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(
                of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,
                options: .regularExpression
              ) != nil
        else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}

private struct AccountDeletionAnyCodingKey: CodingKey {
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
