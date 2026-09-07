import CryptoKit
import Foundation

struct SessionRefreshAttempt: Codable, Equatable, Sendable {
    let sessionId: String
    let refreshTokenFingerprint: String
    let replayNonce: String
}

enum SessionRefreshReplayPolicy {
    static func tokenFingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func matches(_ attempt: SessionRefreshAttempt, session: SessionTokens) -> Bool {
        attempt.sessionId.caseInsensitiveCompare(session.sessionId) == .orderedSame
            && attempt.refreshTokenFingerprint == tokenFingerprint(session.refreshToken)
            && UUID(uuidString: attempt.replayNonce) != nil
    }
}

actor SessionStore {
    static let shared = SessionStore()
    private let account: String
    private let refreshAttemptAccount: String
    private let broker: MessagingProcessBroker?
    private var cached: SessionTokens?
    private var refreshAttempt: SessionRefreshAttempt?
    private var sharedAuthority: MessagingProcessBroker.Authority?

    init(
        account: String = "kit-pay-session-v1",
        refreshAttemptAccount: String = "kit-pay-session-refresh-attempt-v1",
        messagingBroker: MessagingProcessBroker? = nil
    ) {
        self.account = account
        self.refreshAttemptAccount = refreshAttemptAccount
        broker = messagingBroker ?? (account == "kit-pay-session-v1" && refreshAttemptAccount == "kit-pay-session-refresh-attempt-v1"
            ? .shared : nil)
        // Isolated test stores retain their private Keychain namespace. Production authority is
        // reloaded under the cross-process lock for EVERY observation and mutation.
        if broker == nil {
            if let data = try? KeychainStore.data(for: account) {
                cached = try? JSONDecoder().decode(SessionTokens.self, from: data)
            }
            if let data = try? KeychainStore.data(for: refreshAttemptAccount) {
                refreshAttempt = try? JSONDecoder().decode(SessionRefreshAttempt.self, from: data)
            }
        }
    }

    private func withCurrent<T>(_ operation: () throws -> T) throws -> T {
        guard let broker else { return try operation() }
        return try broker.withLock { locked in
            var authority = try locked.authorityLocked()
#if !KIT_SHARE_EXTENSION
            if authority == nil {
                // A single, locked migration. A durable tombstone after logout prevents an old
                // private credential from ever being resurrected by a second process.
                let legacy = try KeychainStore.data(for: account).map {
                    try JSONDecoder().decode(SessionTokens.self, from: $0)
                }
                let replay = try KeychainStore.data(for: refreshAttemptAccount).map {
                    try JSONDecoder().decode(SessionRefreshAttempt.self, from: $0)
                }
                var migrated = MessagingProcessBroker.Authority.revoked
                migrated.session = legacy
                migrated.refreshAttempt = replay
                migrated.allowsLegacyMessagingImport = legacy != nil
                try locked.saveAuthorityLocked(migrated)
                authority = migrated
                try? KeychainStore.remove(account)
                try? KeychainStore.remove(refreshAttemptAccount)
            }
#endif
            sharedAuthority = authority
            cached = authority?.session
            refreshAttempt = authority?.refreshAttempt
            return try operation()
        }
    }

    func current() -> SessionTokens? {
        do { return try withCurrent { cached } }
        catch { cached = nil; refreshAttempt = nil; return nil }
    }

    func save(_ session: SessionTokens) throws {
        try withCurrent { try persistLocked(session) }
    }

    func saveIfEmpty(_ session: SessionTokens) throws -> Bool {
        try withCurrent {
            guard cached == nil else { return false }
            try persistLocked(session)
            return true
        }
    }

    func replaceIfCurrent(_ expected: SessionTokens, with replacement: SessionTokens) throws -> Bool {
        try withCurrent {
            guard cached == expected else { return false }
            try persistLocked(replacement)
            return true
        }
    }

    func replayNonce(for session: SessionTokens) throws -> String {
        try withCurrent {
            guard cached == session else { throw StoreError.accountChanged }
            if let refreshAttempt, SessionRefreshReplayPolicy.matches(refreshAttempt, session: session) {
                return refreshAttempt.replayNonce
            }
            let attempt = SessionRefreshAttempt(
                sessionId: session.sessionId,
                refreshTokenFingerprint: SessionRefreshReplayPolicy.tokenFingerprint(session.refreshToken),
                replayNonce: UUID().uuidString.lowercased()
            )
            if let broker, var authority = sharedAuthority {
                authority.refreshAttempt = attempt
                try broker.saveAuthorityLocked(authority)
                sharedAuthority = authority
            } else {
                try KeychainStore.set(JSONEncoder().encode(attempt), for: refreshAttemptAccount)
            }
            refreshAttempt = attempt
            return attempt.replayNonce
        }
    }

    /// Both processes use the same persisted replay nonce. If the sibling already installed a
    /// newer generation of this same session, adopt it; never replace it with an older response.
    func adoptRefresh(_ replacement: SessionTokens, ifCurrent expected: SessionTokens) throws -> SessionTokens {
        try withCurrent {
            guard let current = cached,
                  current.sessionId.caseInsensitiveCompare(expected.sessionId) == .orderedSame,
                  current.accountId == expected.accountId,
                  let accountID = current.accountId,
                  replacement.sessionId.caseInsensitiveCompare(current.sessionId) == .orderedSame,
                  let bound = replacement.bound(to: accountID)
            else { throw StoreError.accountChanged }
            if current != expected { return current }
            try persistLocked(bound)
            return bound
        }
    }

    func saveAfterRefresh(_ session: SessionTokens) throws {
        try withCurrent {
            guard let current = cached,
                  current.sessionId.caseInsensitiveCompare(session.sessionId) == .orderedSame,
                  let accountID = current.accountId,
                  let bound = session.bound(to: accountID)
            else { throw StoreError.accountChanged }
            try persistLocked(bound)
        }
    }

    @discardableResult
    func clearIfCurrent(_ expected: SessionTokens) throws -> Bool {
        try withCurrent {
            guard cached == expected else { return false }
            try clearLocked()
            return true
        }
    }

    func acceptedDeletionDisposition(accountID: String, sessionID: String) throws
        -> AcceptedAccountDeletionSessionDisposition {
        try withCurrent { deletionDispositionLocked(accountID: accountID, sessionID: sessionID) }
    }

    private func deletionDispositionLocked(accountID: String, sessionID: String)
        -> AcceptedAccountDeletionSessionDisposition {
        guard let candidate = cached else {
            guard let refreshAttempt else { return .alreadyAbsent }
            return refreshAttempt.sessionId.caseInsensitiveCompare(sessionID) == .orderedSame
                ? .exactTarget : .conflict
        }
        guard candidate.sessionId.caseInsensitiveCompare(sessionID) == .orderedSame,
              candidate.accountId?.caseInsensitiveCompare(accountID) == .orderedSame
        else { return .conflict }
        if let refreshAttempt,
           refreshAttempt.sessionId.caseInsensitiveCompare(sessionID) != .orderedSame { return .conflict }
        return .exactTarget
    }

    func clearAcceptedDeletionTarget(accountID: String, sessionID: String) throws
        -> AcceptedAccountDeletionSessionCleanupResult {
        try withCurrent {
            switch deletionDispositionLocked(accountID: accountID, sessionID: sessionID) {
            case .alreadyAbsent:
                // A durable revocation can succeed before file removal fails. The deletion
                // marker must keep retrying these owner-bound receipts even without tokens.
                if let broker {
                    let owner = accountID.lowercased()
                    try broker.consumeRetiredHistoryLocked(accountID: owner)
                    try broker.consumePrivateReceiptLocked(accountID: owner)
                    if let record = try broker.recordLocked(), record.accountID == owner {
                        try broker.purgeRevokedGenerationLocked(record.generation, preserveConfirmedHistory: false)
                    }
                }
                return .alreadyAbsent
            case .conflict: return .conflict
            case .exactTarget:
                try clearLocked(preserveCommunicationHistory: false)
                return .cleared
            }
        }
    }

    func clear() throws { try withCurrent { try clearLocked() } }

    private func clearLocked(preserveCommunicationHistory: Bool = true) throws {
        let revoked = cached
        cached = nil
        refreshAttempt = nil
        if let broker {
            let generation = sharedAuthority?.generation
            let tombstone = MessagingProcessBroker.Authority.revoked
            // Revoke cross-process authority BEFORE deleting old records or returning success.
            if let generation { try broker.revokeSessionLocked(generation: generation) }
            else { try broker.denySharingLocked() }
            if !preserveCommunicationHistory, let accountID = revoked?.accountId?.lowercased() {
                try broker.consumeRetiredHistoryLocked(accountID: accountID)
                try broker.consumePrivateReceiptLocked(accountID: accountID)
            }
            do { try broker.saveAuthorityLocked(tombstone) }
            catch {
                if let generation {
                    try? broker.purgeRevokedGenerationLocked(generation, preserveConfirmedHistory: preserveCommunicationHistory)
                }
                throw error
            }
            sharedAuthority = tombstone
            if let generation {
                try broker.purgeRevokedGenerationLocked(generation, preserveConfirmedHistory: preserveCommunicationHistory)
            }
        }
#if !KIT_SHARE_EXTENSION
        if let revoked, let accountID = revoked.accountId {
            MessagingBackgroundAttachmentUploader.shared.cancelTransfers(
                accountID: accountID, sessionID: revoked.sessionId
            )
        }
#endif
        var firstError: Error?
        do { try KeychainStore.remove(account) } catch { firstError = error }
        do { try KeychainStore.remove(refreshAttemptAccount) } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    private func persistLocked(_ session: SessionTokens) throws {
        if let broker {
            var authority = sharedAuthority ?? .revoked
            let old = authority.session
            if old?.sessionId.caseInsensitiveCompare(session.sessionId) != .orderedSame
                || (old?.accountId != nil && old?.accountId != session.accountId) {
                authority.generation = UUID()
                authority.sharingEnabled = false
                authority.sharingGeneration = UUID()
                authority.requiresBiometricUnlock = nil
                authority.biometricDomainState = nil
                authority.allowsLegacyMessagingImport = false
                try broker.revokeSessionLocked(generation: sharedAuthority?.generation ?? UUID())
                if let previous = sharedAuthority?.generation {
                    try broker.purgeRevokedGenerationLocked(previous)
                }
            }
            authority.session = session
            authority.refreshAttempt = nil
            try broker.saveAuthorityLocked(authority)
            sharedAuthority = authority
        } else {
            try KeychainStore.set(JSONEncoder().encode(session), for: account)
            try? KeychainStore.remove(refreshAttemptAccount)
        }
        cached = session
        refreshAttempt = nil
    }
}

enum AcceptedAccountDeletionSessionDisposition: Equatable {
    case exactTarget
    case alreadyAbsent
    case conflict
}

enum AcceptedAccountDeletionSessionCleanupResult: Equatable {
    case cleared
    case alreadyAbsent
    case conflict
}
