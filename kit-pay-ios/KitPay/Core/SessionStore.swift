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
    private var cached: SessionTokens?
    private var refreshAttempt: SessionRefreshAttempt?

    init(
        account: String = "kit-pay-session-v1",
        refreshAttemptAccount: String = "kit-pay-session-refresh-attempt-v1"
    ) {
        self.account = account
        self.refreshAttemptAccount = refreshAttemptAccount
        if let data = try? KeychainStore.data(for: account) {
            cached = try? JSONDecoder().decode(SessionTokens.self, from: data)
        }
        if let data = try? KeychainStore.data(for: refreshAttemptAccount) {
            refreshAttempt = try? JSONDecoder().decode(SessionRefreshAttempt.self, from: data)
        }
    }

    func current() -> SessionTokens? { cached }

    func save(_ session: SessionTokens) throws {
        try persist(session)
    }

    /// Atomically installs a freshly authenticated account only while no other session owns the
    /// Keychain slot. A late login response can therefore never replace a restored/newer account.
    func saveIfEmpty(_ session: SessionTokens) throws -> Bool {
        guard cached == nil else { return false }
        try persist(session)
        return true
    }

    /// Rewrites metadata for the exact credentials currently installed (used to migrate older
    /// unbound Keychain records without opening an account-replacement race).
    func replaceIfCurrent(_ expected: SessionTokens, with replacement: SessionTokens) throws -> Bool {
        guard cached == expected else { return false }
        try persist(replacement)
        return true
    }

    func replayNonce(for session: SessionTokens) throws -> String {
        if let refreshAttempt, SessionRefreshReplayPolicy.matches(refreshAttempt, session: session) {
            return refreshAttempt.replayNonce
        }
        let attempt = SessionRefreshAttempt(
            sessionId: session.sessionId,
            refreshTokenFingerprint: SessionRefreshReplayPolicy.tokenFingerprint(session.refreshToken),
            replayNonce: UUID().uuidString.lowercased()
        )
        let data = try JSONEncoder().encode(attempt)
        try KeychainStore.set(data, for: refreshAttemptAccount)
        refreshAttempt = attempt
        return attempt.replayNonce
    }

    func saveAfterRefresh(_ session: SessionTokens) throws {
        guard let current = cached,
              current.sessionId.caseInsensitiveCompare(session.sessionId) == .orderedSame,
              let accountID = current.accountId,
              let boundSession = session.bound(to: accountID)
        else { throw StoreError.accountChanged }
        try persist(boundSession)
    }

    /// Removes only the credentials installed by the failed/stale adoption. If another sign-in or
    /// refresh has won the slot, its session survives.
    @discardableResult
    func clearIfCurrent(_ expected: SessionTokens) throws -> Bool {
        guard cached == expected else { return false }
        try clear()
        return true
    }

    /// Resolves the credential generation named by a durable accepted-deletion marker without
    /// conflating absence with a replacement session.
    func acceptedDeletionDisposition(
        accountID: String,
        sessionID: String
    ) throws -> AcceptedAccountDeletionSessionDisposition {
        let candidate: SessionTokens?
        if let cached {
            candidate = cached
        } else if let data = try KeychainStore.data(for: account) {
            candidate = try JSONDecoder().decode(SessionTokens.self, from: data)
        } else {
            candidate = nil
        }
        let pendingRefresh: SessionRefreshAttempt?
        if let refreshAttempt {
            pendingRefresh = refreshAttempt
        } else if let data = try KeychainStore.data(for: refreshAttemptAccount) {
            pendingRefresh = try JSONDecoder().decode(SessionRefreshAttempt.self, from: data)
        } else {
            pendingRefresh = nil
        }
        guard let candidate else {
            guard let pendingRefresh else { return .alreadyAbsent }
            return pendingRefresh.sessionId.caseInsensitiveCompare(sessionID) == .orderedSame
                ? .exactTarget
                : .conflict
        }
        guard candidate.sessionId.caseInsensitiveCompare(sessionID) == .orderedSame,
              candidate.accountId?.caseInsensitiveCompare(accountID) == .orderedSame
        else { return .conflict }
        if let pendingRefresh,
           pendingRefresh.sessionId.caseInsensitiveCompare(sessionID) != .orderedSame {
            return .conflict
        }
        return .exactTarget
    }

    /// Clears only the exact credential generation named by the deletion marker. A replacement
    /// session is reported as a conflict and remains untouched.
    func clearAcceptedDeletionTarget(
        accountID: String,
        sessionID: String
    ) throws -> AcceptedAccountDeletionSessionCleanupResult {
        switch try acceptedDeletionDisposition(accountID: accountID, sessionID: sessionID) {
        case .alreadyAbsent:
            return .alreadyAbsent
        case .conflict:
            return .conflict
        case .exactTarget:
            try clear()
            guard try acceptedDeletionDisposition(
                accountID: accountID,
                sessionID: sessionID
            ) == .alreadyAbsent else { throw StoreError.accountChanged }
            return .cleared
        }
    }

    func clear() throws {
        // Clear in-memory authority first even if either Keychain deletion
        // later fails; callers must never keep using credentials after logout.
        if let revoked = cached,
           let accountID = revoked.accountId {
            MessagingBackgroundAttachmentUploader.shared.cancelTransfers(
                accountID: accountID,
                sessionID: revoked.sessionId
            )
        }
        cached = nil
        refreshAttempt = nil
        var firstError: Error?
        do { try KeychainStore.remove(account) } catch { firstError = error }
        do { try KeychainStore.remove(refreshAttemptAccount) } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    private func persist(_ session: SessionTokens) throws {
        let data = try JSONEncoder().encode(session)
        try KeychainStore.set(data, for: account)
        cached = session
        // Credential persistence succeeded; stale replay metadata is harmless
        // because it is token-bound and must not turn sign-in into a failure.
        try? KeychainStore.remove(refreshAttemptAccount)
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
