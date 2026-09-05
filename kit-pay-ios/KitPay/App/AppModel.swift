import Combine
import BackgroundTasks
import CallKit
import Contacts
import AVFoundation
import Foundation
import ImageIO
import UIKit

struct SecureMessagingSyncErrorOwnership {
    typealias Attempt = UInt64

    private var latestAttempt: Attempt = 0
    private var resetFloor: Attempt = 0
    private var latestSuccessfulAttempt: Attempt = 0
    private(set) var errorAttempt: Attempt?
    private(set) var errorMessage: String?

    mutating func begin() -> Attempt {
        latestAttempt &+= 1
        return latestAttempt
    }

    mutating func record(_ message: String, for attempt: Attempt) -> String? {
        guard attempt > resetFloor,
              attempt <= latestAttempt,
              attempt > latestSuccessfulAttempt,
              errorAttempt.map({ attempt >= $0 }) ?? true
        else { return nil }
        errorAttempt = attempt
        errorMessage = message
        return message
    }

    mutating func resolve(
        _ attempt: Attempt,
        visibleMessage: String?
    ) -> String? {
        guard attempt > resetFloor, attempt <= latestAttempt else { return visibleMessage }
        latestSuccessfulAttempt = max(latestSuccessfulAttempt, attempt)
        guard let errorAttempt,
              errorAttempt <= attempt,
              let errorMessage
        else { return visibleMessage }
        self.errorAttempt = nil
        self.errorMessage = nil
        return visibleMessage == errorMessage ? nil : visibleMessage
    }

    mutating func reset() {
        resetFloor = latestAttempt
        latestSuccessfulAttempt = max(latestSuccessfulAttempt, resetFloor)
        errorAttempt = nil
        errorMessage = nil
    }
}

/// Visible-chat synchronization remains durable REST, but realtime becomes its primary wake-up
/// signal when advertised. A low-frequency timer still retries read receipts and recovers from
/// missed socket hints; legacy servers keep a bounded polling cadence.
enum VisibleConversationMessagingPolicy {
    static func newestUnreadIncomingServerMessageID(
        conversationID: String,
        conversations: [Conversation],
        messages: [LocalMessage]
    ) -> String? {
        guard conversations.contains(where: {
            $0.id == conversationID && $0.unreadCount > 0
        }) else { return nil }
        return messages
            .filter {
                $0.conversationId == conversationID
                    && !$0.isOutgoing
                    && $0.serverMessageId != nil
                    && $0.state == .received
            }
            .max(by: {
                let leftDate = $0.sentAt ?? $0.createdAt
                let rightDate = $1.sentAt ?? $1.createdAt
                if leftDate != rightDate { return leftDate < rightDate }
                return ($0.serverMessageId ?? "") < ($1.serverMessageId ?? "")
            })?
            .serverMessageId
    }

    static func shouldPublishAfterSync(
        attemptedBoundary: String?,
        currentBoundary: String?
    ) -> Bool {
        guard let currentBoundary else { return false }
        return currentBoundary != attemptedBoundary
    }
}

/// Resolves only an unambiguous, server-addressable direct thread for the local-first composer.
/// A duplicate must never be selected by recency because doing so could bind the message to a
/// different server conversation than the sender opened.
enum DirectMessageLocalConversationPolicy {
    enum Resolution: Equatable {
        case missing
        case existing(Conversation)
        case invalid
        case ambiguous
    }

    static func resolve(
        conversations: [Conversation],
        currentUserID: String,
        recipientUserID: String
    ) -> Resolution {
        guard SecureMessagingValidation.isCanonicalUUID(currentUserID),
              SecureMessagingValidation.isCanonicalUUID(recipientUserID),
              currentUserID != recipientUserID
        else { return .invalid }
        let participantIDs = Set([currentUserID, recipientUserID])
        let structurallyMatching = conversations.filter { conversation in
            guard SecureMessagingValidation.isCanonicalUUID(conversation.id),
                  conversation.participantUserIds.count == 2,
                  conversation.participantUserIds.allSatisfy({
                      SecureMessagingValidation.isCanonicalUUID($0)
                  })
            else { return false }
            return Set(conversation.participantUserIds) == participantIDs
        }
        // `nil` is the backward-compatible encoding written before conversation types became
        // durable. Every explicit value is server-owned: accepting an unknown non-"group" value
        // (for example, a future "channel") as a direct thread — or silently creating a second
        // thread around it — could bind plaintext intent to semantics this client never reviewed.
        guard !structurallyMatching.contains(where: { conversation in
            guard let type = conversation.conversationType else { return false }
            return type != SecureMessagingWire.directConversationType
                && type != SecureMessagingWire.groupConversationType
        }) else { return .invalid }
        let matches = structurallyMatching.filter {
            $0.conversationType == nil
                || $0.conversationType == SecureMessagingWire.directConversationType
        }
        switch matches.count {
        case 0: return .missing
        case 1: return .existing(matches[0])
        default: return .ambiguous
        }
    }
}

/// Pure admission and routing decisions shared by the new-message UI and AppModel. Keeping this
/// boundary free of network or singleton state makes the local-first invariant executable: a
/// missing current E2EE enrollment never disables composition, while a known privacy block and
/// an ambiguous/unknown local thread still fail before any queue mutation.
enum NewMessageComposerPolicy {
    enum DirectRoute: Equatable {
        case create
        case existing(Conversation)
        case blocked
        case invalid
    }

    static func canSubmit(
        appMutationsAllowed: Bool,
        localQueueAvailable: Bool,
        body: String
    ) -> Bool {
        appMutationsAllowed
            && localQueueAvailable
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func directRoute(
        conversations: [Conversation],
        currentUserID: String,
        recipientUserID: String,
        privacyAllowsLocalQueue: Bool
    ) -> DirectRoute {
        guard privacyAllowsLocalQueue else { return .blocked }
        switch DirectMessageLocalConversationPolicy.resolve(
            conversations: conversations,
            currentUserID: currentUserID,
            recipientUserID: recipientUserID
        ) {
        case .missing:
            return .create
        case .existing(let conversation):
            return .existing(conversation)
        case .invalid, .ambiguous:
            return .invalid
        }
    }

    static func navigationConversation(
        after result: SecureMessagingQueueResult?
    ) -> Conversation? {
        result?.conversation
    }
}

struct ActiveCallInvitationContext: Equatable {
    let call: CallRecord
    let callID: String
    let participantUserIDs: Set<String>

    var canInviteAnotherParticipant: Bool {
        participantUserIDs.count < ActiveCallInvitationPolicy.maximumParticipantCount
    }
}

enum CommunicationPrivacyMutation: Equatable {
    case preference
    case block(String)
    case unblock(String)
}

private struct CommunicationPrivacyAccountContext {
    let accountEpoch: UUID
    let userID: String
    let sessionID: String
}

private enum CommunicationPreferenceSaveResult {
    case updated(CommunicationPreferencesDTO)
    case refreshedAfterConflict(CommunicationPreferencesDTO)
}

private enum SecureMessageSubmissionKind {
    case userText
    case paymentEvent
    /// The mirror image of `paymentEvent`: a group payment's announcement or an answer to one,
    /// allowed only in a group thread and never in a one-to-one chat.
    case groupPaymentEvent
    /// A collaborative group request card, contribution receipt, or terminal status event.
    case groupPaymentRequestEvent
    case reactionEvent
    /// A correction to the wording of one's own already-sent message, allowed only through the
    /// typed edit boundary and only inside the fifteen minutes the server also enforces.
    case editEvent
}

private struct CommunicationPreferenceConflictRefreshFailure: Error {}

private struct SecurityPreferencesAccountContext {
    let accountEpoch: UUID
    let userID: String
    let sessionID: String
}

private enum SecurityPreferencesSaveResult {
    case updated(SecurityPreferencesDTO)
    case refreshedAfterConflict(SecurityPreferencesDTO)
}

private struct SecurityPreferencesConflictRefreshFailure: Error {}

private enum CommunicationPrivacyMessageAdmissionFailure: LocalizedError {
    case blocked
    case invalidRecipient

    var errorDescription: String? {
        switch self {
        case .blocked:
            return "Unblock this account before retrying this message."
        case .invalidRecipient:
            return "This message no longer has one valid Kit Pay recipient."
        }
    }
}

/// Keeps the in-call people picker and its authenticated response handling on the same strict
/// backend-call identity. A partial, duplicate, bound, terminal, or oversized local projection is
/// not enough authority to send an invitation.
enum ActiveCallInvitationPolicy {
    static let maximumParticipantCount = 21

    static func context(
        for activeCall: ActiveCallPresentation?,
        calls: [CallRecord],
        currentUserID: String?
    ) -> ActiveCallInvitationContext? {
        guard let activeCall,
              activeCall.conversationId == nil,
              let callID = canonicalUUID(activeCall.id),
              let currentUserID = canonicalUUID(currentUserID)
        else { return nil }

        let matches = calls.filter { canonicalUUID($0.id) == callID }
        guard matches.count == 1,
              let call = matches.first,
              call.state == .active,
              call.conversationId == nil,
              var participantUserIDs = canonicalRoster(call.participantUserIds)
        else { return nil }

        participantUserIDs.insert(currentUserID)
        guard participantUserIDs.count <= maximumParticipantCount else { return nil }
        return ActiveCallInvitationContext(
            call: call,
            callID: callID,
            participantUserIDs: participantUserIDs
        )
    }

    static func canonicalRecipientID(_ value: String) -> String? {
        canonicalUUID(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func canInvite(
        recipientUserID: String,
        in context: ActiveCallInvitationContext
    ) -> Bool {
        guard context.canInviteAnotherParticipant,
              let recipientUserID = canonicalRecipientID(recipientUserID)
        else { return false }
        return !context.participantUserIDs.contains(recipientUserID)
    }

    static func accepts(
        response: CallDTO,
        expectedContext: ActiveCallInvitationContext,
        invitedRecipientID: String,
        currentUserID: String
    ) -> Bool {
        guard let expectedCallID = canonicalUUID(expectedContext.callID),
              canonicalUUID(response.id) == expectedCallID,
              ["ringing", "active"].contains(response.state.lowercased()),
              response.conversationId == nil,
              let invitedRecipientID = canonicalRecipientID(invitedRecipientID),
              let currentUserID = canonicalUUID(currentUserID),
              let responseParticipantIDs = response.participantUserIds,
              var participantUserIDs = canonicalRoster(responseParticipantIDs),
              !participantUserIDs.contains(currentUserID),
              participantUserIDs.contains(invitedRecipientID),
              let expectedParticipantUserIDs = canonicalRoster(
                  Array(expectedContext.participantUserIDs)
              )
        else { return false }

        participantUserIDs.insert(currentUserID)
        return participantUserIDs.count <= maximumParticipantCount
            && expectedParticipantUserIDs.isSubset(of: participantUserIDs)
    }

    private static func canonicalRoster(_ values: [String]) -> Set<String>? {
        guard values.count <= maximumParticipantCount else { return nil }
        var result: Set<String> = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let participantID = canonicalUUID(value),
                  result.insert(participantID).inserted
            else { return nil }
        }
        return result
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        return identifier.uuidString.lowercased()
    }
}

private struct AuthenticatedSecurityContext {
    let accountEpoch: UUID
    let userID: String
    let sessionID: String
}

/// Exact ownership boundary for one customer wallet-history refresh. View tasks are deliberately
/// absent: SwiftUI may cancel `.task` and `.refreshable` work as views move on and off screen, but
/// an authenticated response must still reach the encrypted local store while this identity is
/// current. A different account, session, or selected wallet is the only valid replacement.
struct WalletHistoryRefreshKey: Equatable {
    let accountEpoch: UUID
    let userID: String
    let sessionID: String
    let walletID: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountEpoch == rhs.accountEpoch
            && lhs.userID == rhs.userID
            && lhs.sessionID == rhs.sessionID
            && WalletIdentityResolver.identifiersMatch(lhs.walletID, rhs.walletID)
    }
}

private struct WalletHistoryRefreshFlight {
    let id: UUID
    let key: WalletHistoryRefreshKey
    let task: Task<Void, Never>
}

enum AccountSignOutResult: Equatable {
    case completed
    case contextChanged
    case localCleanupFailed

    static func cleanupResult(
        sessionCleanupSucceeded: Bool,
        projectionCleanupSucceeded: Bool,
        mediaCacheCleanupSucceeded: Bool,
        diagnosticsCleanupSucceeded: Bool,
        acceptedDeletionCleanupSucceeded: Bool
    ) -> Self {
        sessionCleanupSucceeded
            && projectionCleanupSucceeded
            && mediaCacheCleanupSucceeded
            && diagnosticsCleanupSucceeded
            && acceptedDeletionCleanupSucceeded
            ? .completed
            : .localCleanupFailed
    }
}

enum ProfileEmailOperation: Equatable {
    case requestingCode
    case verifyingCode
}

private enum MFAManagementError: LocalizedError {
    case offline
    case unavailable
    case invalidResponse
    case recoveryCodesUncertain

    var errorDescription: String? {
        switch self {
        case .offline:
            "Connect to the internet to manage two-step verification."
        case .unavailable:
            "Finish securing this sign-in before changing two-step verification."
        case .invalidResponse:
            "The security change could not be verified. Please try again."
        case .recoveryCodesUncertain:
            "Kit may have replaced your recovery codes, but the new set could not be received safely. Use a fresh authenticator code to generate another set."
        }
    }
}

enum PasswordResetSubmissionOutcome: Equatable {
    case completed
    case completionUncertain
    case failed
}

enum IrreversibleAuthenticationMutationPolicy {
    static func completionIsUncertain(after error: Error) -> Bool {
        if let payload = error as? APIErrorPayload {
            guard let status = payload.httpStatus else { return false }
            return status == 408 || status >= 500
        }
        if let apiError = error as? APIClientError {
            switch apiError {
            case .invalidResponse:
                return true
            case .invalidPayload(let status):
                return (200 ... 299).contains(status) || status == 408 || status >= 500
            case .httpStatus(let status):
                return status == 408 || status >= 500
            case .httpResponse(let status, _):
                return status == 408 || status >= 500
            case .signedOut, .invalidURL:
                return false
            }
        }
        if let authError = error as? AuthUIError, case .invalidResponse = authError {
            return true
        }
        return error is URLError || error is CancellationError
    }
}

/// Pull-to-refresh is owned by SwiftUI, which may cancel its task when the refresh control is
/// dismissed, the view changes, or a newer refresh supersedes it. URLSession can surface that
/// cancellation either as `CancellationError` or as `URLError.cancelled`; neither is a customer
/// failure and neither should become the app-wide alert.
enum RefreshCancellationPolicy {
    static func shouldSuppress(_ error: Error, taskIsCancelled: Bool) -> Bool {
        if taskIsCancelled || error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return containsCancellationNSError(error as NSError, depth: 0)
    }

    private static func containsCancellationNSError(_ error: NSError, depth: Int) -> Bool {
        guard depth < 4 else { return false }
        if error.domain == NSURLErrorDomain,
           error.code == URLError.Code.cancelled.rawValue {
            return true
        }
        if error.domain == NSCocoaErrorDomain,
           error.code == NSUserCancelledError {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return containsCancellationNSError(underlying, depth: depth + 1)
    }
}

/// Transport failures that mean "the network is not usable right now" rather than "something is
/// wrong with your account".
///
/// A session resumed at launch, or one resumed after the biometric prompt has been sitting on
/// screen, routinely finishes its first requests after the connection has already gone. Turning
/// that into a modal "The request timed out." is noise the customer can do nothing about — the
/// connectivity pill already says the app is offline, and the next refresh recovers on its own.
/// A refresh the customer explicitly pulled still reports these, because there they asked a
/// question and deserve an answer.
enum TransientTransportErrorPolicy {
    static func isTransient(_ error: Error) -> Bool {
        containsTransientNSError(error as NSError, depth: 0)
    }

    /// Whether an automatic, non-user-initiated load should stay silent about this failure.
    static func shouldSuppressAutomatically(_ error: Error, isUserInitiated: Bool) -> Bool {
        !isUserInitiated && isTransient(error)
    }

    private static let transientCodes: Set<Int> = [
        URLError.Code.timedOut.rawValue,
        URLError.Code.cannotConnectToHost.rawValue,
        URLError.Code.cannotFindHost.rawValue,
        URLError.Code.dnsLookupFailed.rawValue,
        URLError.Code.networkConnectionLost.rawValue,
        URLError.Code.notConnectedToInternet.rawValue,
        URLError.Code.internationalRoamingOff.rawValue,
        URLError.Code.dataNotAllowed.rawValue,
        URLError.Code.callIsActive.rawValue,
        URLError.Code.resourceUnavailable.rawValue,
    ]

    private static func containsTransientNSError(_ error: NSError, depth: Int) -> Bool {
        guard depth < 4 else { return false }
        if error.domain == NSURLErrorDomain, transientCodes.contains(error.code) {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return containsTransientNSError(underlying, depth: depth + 1)
    }
}

/// Which network path updates deserve reconnect work.
///
/// `NWPathMonitor` republishes `.satisfied` for changes that are not a reconnection at all — an
/// interface coming up alongside the one already carrying traffic, a VPN attaching, expensive or
/// constrained status flipping, a DNS change. The handler used to treat every one of those as a
/// fresh reconnect, so a phone walking between cells could run capabilities, bootstrap, wallets,
/// transactions, call history, push-token replay and a contact sync several times over, on
/// exactly the connection least able to afford it. Only a real transition does that work now.
enum ConnectivityTransitionPolicy {
    enum Transition: Equatable {
        /// Connectivity became usable after being absent or unknown: run reconnect work.
        case recovered
        /// Connectivity was lost: suspend anything that needs the network.
        case lost
        /// The path changed but the app's reachability did not.
        case unchanged
    }

    /// - Parameter previousOnline: the last observed reachability, or `nil` before the first
    ///   path update. The first `satisfied` update is still a recovery, so a launch that races
    ///   the monitor keeps bootstrapping.
    static func transition(previousOnline: Bool?, isOnline: Bool) -> Transition {
        guard previousOnline != isOnline else { return .unchanged }
        return isOnline ? .recovered : .lost
    }
}

/// Admission for the authenticated account projection (profile, wallets and wallet history).
///
/// Communication assurance is deliberately not an input. Bootstrap is the authority that can
/// restore a stale cached assurance projection, so requiring the cached communication decision
/// before bootstrap creates a deadlock: the request that would repair assurance can never run.
/// Communication side effects retain their own stricter gates after the financial projection has
/// committed.
enum AuthenticatedProjectionRefreshPolicy {
    static func permits(
        isSigningOut: Bool,
        isSignedIn: Bool,
        isOnline: Bool,
        accountSetupComplete: Bool,
        isSubmittingAccountDeletion: Bool,
        acceptedAccountDeletionCleanupBlocked: Bool,
        protectedLocalStateRecoveryBlocked: Bool,
        unresolvedAccountDeletionAttemptBlocked: Bool
    ) -> Bool {
        !isSigningOut
            && isSignedIn
            && isOnline
            && accountSetupComplete
            && !isSubmittingAccountDeletion
            && !acceptedAccountDeletionCleanupBlocked
            && !protectedLocalStateRecoveryBlocked
            && !unresolvedAccountDeletionAttemptBlocked
    }
}

/// Admits one authoritative bootstrap after a real background visit.
///
/// SwiftUI reports `.active` again after transient interruptions such as Control Center and
/// permission alerts. Those transitions never call `didEnterBackground()`, so they cannot turn a
/// cached wallet refresh into a foreground refresh storm. A real background visit advances the
/// generation; concurrent active callbacks can claim that generation only once, and a short
/// throttle absorbs rapid app-switcher churn without forgetting the outstanding refresh.
struct ForegroundAuthoritativeRefreshGate {
    enum Admission: Equatable {
        case none
        case wait(TimeInterval)
        case start(generation: UInt64)
    }

    static let minimumStartInterval: TimeInterval = 10

    private(set) var backgroundGeneration: UInt64 = 0
    private(set) var completedGeneration: UInt64 = 0
    private(set) var inFlightGeneration: UInt64?
    private(set) var lastStartedAt: Date?

    var hasPendingRefresh: Bool {
        completedGeneration < backgroundGeneration
    }

    mutating func didEnterBackground() {
        backgroundGeneration &+= 1
    }

    mutating func admission(
        at now: Date,
        appIsActive: Bool,
        isOnline: Bool,
        sessionIsEligible: Bool
    ) -> Admission {
        guard appIsActive,
              isOnline,
              sessionIsEligible,
              hasPendingRefresh,
              inFlightGeneration == nil
        else { return .none }

        if let lastStartedAt {
            let elapsed = now.timeIntervalSince(lastStartedAt)
            let remaining = Self.minimumStartInterval - elapsed
            if remaining > 0 { return .wait(remaining) }
        }

        let generation = backgroundGeneration
        inFlightGeneration = generation
        lastStartedAt = now
        return .start(generation: generation)
    }

    /// Records a bootstrap only through the background generation captured before its request.
    /// A response that began before a newer background visit cannot satisfy that newer visit.
    mutating func authoritativeRefreshDidCommit(upTo generation: UInt64) {
        completedGeneration = max(
            completedGeneration,
            min(generation, backgroundGeneration)
        )
        if let inFlightGeneration,
           inFlightGeneration <= completedGeneration {
            self.inFlightGeneration = nil
        }
    }

    func hasCompleted(generation: UInt64) -> Bool {
        completedGeneration >= generation
    }

    /// Releases a failed or cancelled attempt without consuming its pending generation.
    mutating func finishAttempt(generation: UInt64) {
        guard inFlightGeneration == generation else { return }
        inFlightGeneration = nil
    }

    mutating func reset() {
        self = Self()
    }
}

/// A merge invitation is a non-idempotent signalling request whose response can be lost after the
/// backend has already updated the roster. Only narrowly ambiguous failures justify one read-back;
/// definitive authorization, validation, and not-found failures remain failures.
enum WaitingCallMergeInvitationReconciliationPolicy {
    static func shouldReconcile(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        if let payload = error as? APIErrorPayload {
            if payload.code.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("CALL_PARTICIPANTS_UNCHANGED") == .orderedSame {
                return true
            }
            guard let status = payload.httpStatus else { return false }
            return isAmbiguousHTTPStatus(status)
        }
        if let clientError = error as? APIClientError {
            switch clientError {
            case .invalidResponse:
                return true
            case .invalidPayload(let status):
                return (200 ... 299).contains(status) || isAmbiguousHTTPStatus(status)
            case .httpStatus(let status):
                return isAmbiguousHTTPStatus(status)
            case .httpResponse(let status, _):
                return isAmbiguousHTTPStatus(status)
            case .signedOut, .invalidURL:
                return false
            }
        }
        return false
    }

    static func accepts(
        response: CallDTO,
        expectedContext: ActiveCallInvitationContext,
        invitedRecipientID: String,
        currentUserID: String
    ) -> Bool {
        response.state.caseInsensitiveCompare("active") == .orderedSame
            && ActiveCallInvitationPolicy.accepts(
                response: response,
                expectedContext: expectedContext,
                invitedRecipientID: invitedRecipientID,
                currentUserID: currentUserID
            )
    }

    private static func isAmbiguousHTTPStatus(_ status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500 ... 599).contains(status)
    }
}

/// Linearizes cancellation against the synchronous encrypted-store mutation used to publish a
/// merged roster. AppModel owns the higher-level actor state, while SecureLocalStore executes its
/// mutation closure on a different executor; this narrow lock prevents a cancelled merge token
/// from becoming valid again between the final actor check and that closure.
private final class WaitingCallMergeOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeOperationID: UUID?

    func activate(_ operationID: UUID) {
        lock.lock()
        activeOperationID = operationID
        lock.unlock()
    }

    func isCurrent(_ operationID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeOperationID == operationID
    }

    @discardableResult
    func invalidate(_ operationID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeOperationID == operationID else { return false }
        activeOperationID = nil
        return true
    }

    /// The mutation is intentionally synchronous and small. Holding the lock gives cancellation
    /// and commit one deterministic ordering: a cancellation that wins first prevents the write;
    /// a write that wins first was still authorized at its exact linearization point.
    func performIfCurrent(
        _ operationID: UUID,
        _ mutation: () throws -> Void
    ) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeOperationID == operationID else { return false }
        try mutation()
        return true
    }
}

private struct WaitingCallMergeResultSignal {
    let operationID: UUID
    let continuation: AsyncStream<Bool>.Continuation
}

enum AuthenticationChallengeRecoveryPolicy {
    static func preservesChallenge(afterResendFailure error: Error) -> Bool {
        if AuthenticationChallengeErrorPolicy.isTerminal(error) { return false }
        if let payload = error as? APIErrorPayload {
            guard let status = payload.httpStatus else { return true }
            return (400 ... 499).contains(status) && status != 408
        }
        if let apiError = error as? APIClientError {
            switch apiError {
            case .invalidPayload(let status), .httpStatus(let status),
                 .httpResponse(let status, _):
                return (400 ... 499).contains(status) && status != 408
            case .signedOut, .invalidResponse, .invalidURL:
                return false
            }
        }
        return false
    }
}

/// Main-actor admission shared by local-access and financial biometric prompts. The owner token is
/// acquired synchronously before an actor hop so reentrant callers cannot pass a stale Bool check.
struct BiometricAuthenticationOperationGate {
    private(set) var activeOperationID: UUID?

    var isActive: Bool { activeOperationID != nil }

    mutating func begin() -> UUID? {
        guard activeOperationID == nil else { return nil }
        let operationID = UUID()
        activeOperationID = operationID
        return operationID
    }

    func owns(_ operationID: UUID) -> Bool {
        activeOperationID == operationID
    }

    @discardableResult
    mutating func finish(_ operationID: UUID) -> Bool {
        guard owns(operationID) else { return false }
        activeOperationID = nil
        return true
    }
}

/// A returning-sign-in response may unlock local account content only while it belongs to the
/// foreground lifetime that started it. Entering the background invalidates a suspended
/// LocalAuthentication response even when the framework delivers success afterward.
struct ReturningSignInBiometricAuthorizationFence {
    typealias Token = UInt64

    private(set) var generation: Token = 0

    func capture() -> Token { generation }

    mutating func invalidate() {
        generation &+= 1
    }

    func authorizes(_ token: Token) -> Bool {
        token == generation
    }
}

/// A successful local-auth response may reveal Home only if it belongs to the currently visible
/// Home visit. Leaving Home or entering the background invalidates every earlier response.
struct HomeBiometricAuthorizationFence {
    typealias Token = UInt64

    private(set) var generation: Token = 0

    func capture() -> Token { generation }

    mutating func invalidate() {
        generation &+= 1
    }

    func authorizes(_ token: Token, homeIsSelected: Bool) -> Bool {
        homeIsSelected && token == generation
    }
}

/// Orders overlapping capability requests by completed, authoritative results. Cancellation does
/// not advance the resolved generation, so an older in-flight request may still supply the last
/// confirmed value after a newer waiter is cancelled.
struct CapabilitiesRequestResolutionTracker {
    typealias Token = UInt64

    private(set) var nextGeneration: Token = 0
    private(set) var latestResolvedGeneration: Token = 0

    mutating func begin() -> Token {
        nextGeneration &+= 1
        return nextGeneration
    }

    mutating func accepts(_ token: Token, cancelled: Bool) -> Bool {
        guard !cancelled, token >= latestResolvedGeneration else { return false }
        latestResolvedGeneration = token
        return true
    }

    mutating func invalidate() {
        nextGeneration &+= 1
        latestResolvedGeneration = nextGeneration
    }
}

enum MediaHydrationPolicy {
    /// A KITMEDIA2 message may carry eight items. One pass must therefore admit several complete
    /// messages instead of hydrating half an album and deferring the rest for five minutes.
    static let maximumItemsPerPass = 32
    /// Bound radio, CPU and temporary ciphertext pressure while still overlapping independent
    /// downloads. Each task persists its own stable media identity and revalidates after awaits.
    static let maximumConcurrentDownloads = 4
    static let retryDelay: TimeInterval = 5 * 60
    static let maximumReceivedCacheBytes: Int64 = 512 * 1_024 * 1_024
    static let targetReceivedCacheBytes: Int64 = 384 * 1_024 * 1_024
    static let recentAccessProtection: TimeInterval = 5 * 60
    private static let reserveBytes: Int64 = 64 * 1_024 * 1_024

    /// Downloaded ciphertext and unpublished plaintext briefly coexist. Leave a fixed safety
    /// reserve as well as twice the declared plaintext size; insufficient space leaves the
    /// durable record pending instead of beginning a transfer that cannot publish atomically.
    static func hasCapacity(plaintextByteCount: Int, volumeURL: URL) -> Bool {
        guard plaintextByteCount > 0 else { return false }
        let available = try? volumeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        guard let available else { return true }
        let bytes = Int64(plaintextByteCount)
        let required = reserveBytes + min(Int64.max - reserveBytes, bytes * 2)
        return available >= required
    }
}

enum MediaPreprocessingPolicy {
    /// One pass is bounded so foreground work cannot monopolize local media processing.
    static let maximumItemsPerPass = 8
    /// Two independent jobs overlap file I/O and codec work while keeping peak image/video
    /// memory predictable on older devices. Per-message completion remains serialized by the
    /// encrypted store actor, and immutable media/output IDs make each job independent.
    static let maximumConcurrentJobs = 2
    static let retryDelay: TimeInterval = 30

    /// Content validation for an output that may have been published immediately before a
    /// process death. Size and filename are not authority: a JPEG must both carry the JPEG
    /// signature and decode through ImageIO, while a voice assembly must be a playable asset
    /// with an audio track and a finite positive duration. This work stays off the main actor.
    static func isValidPublishedOutput(
        at fileURL: URL,
        for job: LocalMediaPreprocessingJob
    ) async -> Bool {
        guard job.isStructurallyValid else { return false }
        switch job.kind {
        case .imageJPEG:
            return await Task.detached(priority: .utility) {
                guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
                defer { try? handle.close() }
                guard let signature = try? handle.read(upToCount: 3),
                      signature == Data([0xff, 0xd8, 0xff])
                else { return false }
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(
                          fileURL as CFURL,
                          sourceOptions
                      ),
                      CGImageSourceGetCount(source) > 0,
                      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
                else { return false }
                let decodeOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2,
                ]
                return CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    decodeOptions as CFDictionary
                ) != nil
            }.value
        case .voiceAssembly:
            let hasMPEG4Container = await Task.detached(priority: .utility) {
                guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
                defer { try? handle.close() }
                guard let header = try? handle.read(upToCount: 8), header.count == 8 else {
                    return false
                }
                return Data(header[4 ..< 8]) == Data("ftyp".utf8)
            }.value
            guard hasMPEG4Container else { return false }
            let asset = AVURLAsset(url: fileURL)
            do {
                async let isPlayable = asset.load(.isPlayable)
                async let duration = asset.load(.duration)
                async let audioTracks = asset.loadTracks(withMediaType: .audio)
                let (playable, loadedDuration, tracks) = try await (
                    isPlayable,
                    duration,
                    audioTracks
                )
                let seconds = loadedDuration.seconds
                return playable && !tracks.isEmpty && seconds.isFinite && seconds > 0
            } catch {
                return false
            }
        }
    }

    private static func canonicalOwnershipKeys(_ rawKeys: [String]) -> [String] {
        rawKeys.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() }
    }

    private static func rawRecordStorageKeys(_ record: LocalMediaRecord) -> [String] {
        canonicalOwnershipKeys([
            record.id,
            record.localStorageKey,
            record.remoteEncryptedObjectID,
            record.resumableUpload?.storageKey,
        ].compactMap { $0 }
            + (record.originalSources?.map(\.storageKey) ?? [])
            + [record.preprocessingJob?.outputStorageKey].compactMap { $0 })
    }

    private static func nonRecordStorageKeys(_ message: LocalMessage) -> [String] {
        var keys = [message.pendingAttachment?.localStorageKey].compactMap { $0 }
        if let batch = message.pendingMediaBatch {
            keys.append(contentsOf: batch.items.flatMap {
                [$0.attachmentID, $0.localStorageKey, $0.storageKey].compactMap { $0 }
            })
        }
        if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
            keys.append(descriptor.storageKey)
            keys.append(descriptor.attachmentID)
        }
        if let descriptor = KitMediaMessageV2Descriptor.parse(message.body) {
            keys.append(contentsOf: descriptor.items.map(\.storageKey))
            keys.append(contentsOf: descriptor.items.map(\.attachmentID))
        }
        return canonicalOwnershipKeys(keys)
    }

    /// A newly minted preprocessing destination is admitted only while no persisted draft or
    /// message refers to it, including malformed legacy records whose normal projections fail
    /// structural validation. The check and state re-key run inside one store transaction.
    static func isOutputStorageKeyUnowned(
        _ storageKey: String,
        in state: PersistedState
    ) -> Bool {
        guard UUID(uuidString: storageKey)?.uuidString.lowercased() == storageKey,
              !ConversationDraftPolicy.localMediaStorageKeysOwnedByDrafts(in: state)
                  .contains(storageKey)
        else { return false }
        return state.messages.allSatisfy { message in
            !(message.localMediaRecords ?? []).contains {
                rawRecordStorageKeys($0).contains(storageKey)
            } && !nonRecordStorageKeys(message).contains(storageKey)
        }
    }

    /// A preprocessing retry may replace only its own unpublished output. Drafts and any other
    /// message are independent owners even when damaged legacy state aliases the same UUID.
    static func canReplaceOutput(
        storageKey: String,
        ownedBy messageID: UUID,
        attachmentID: String,
        expectedJob: LocalMediaPreprocessingJob,
        in state: PersistedState
    ) -> Bool {
        guard UUID(uuidString: storageKey)?.uuidString.lowercased() == storageKey,
              expectedJob.isStructurallyValid,
              expectedJob.outputStorageKey == storageKey,
              ConversationDraftPolicy.localMediaStorageKeysOwnedByDrafts(in: state)
                  .contains(storageKey) == false,
              state.messages.filter({ $0.id == messageID }).count == 1,
              state.messages.contains(where: { $0.id == messageID })
        else { return false }
        let recordOwners = state.messages.flatMap { message in
            (message.localMediaRecords ?? []).compactMap { record
                -> (outerMessageID: UUID, record: LocalMediaRecord)? in
                rawRecordStorageKeys(record).contains(storageKey)
                    ? (message.id, record)
                    : nil
            }
        }
        guard recordOwners.count == 1, let owner = recordOwners.first else { return false }
        let nonRecordOwners = state.messages.flatMap { message -> [(UUID, String)] in
            nonRecordStorageKeys(message)
                .filter { $0 == storageKey }
                .map { (message.id, $0) }
        }
        return nonRecordOwners.isEmpty
            && owner.outerMessageID == messageID
            && owner.record.messageID == messageID
            && owner.record.id == attachmentID
            && owner.record.id != storageKey
            && owner.record.preprocessingJob == expectedJob
            && owner.record.isStructurallyValid
    }
}

struct RestoredConversationDraftMediaAttachment {
    let manifest: ConversationDraftMediaAttachment
    let data: Data?
    let localFileURL: URL?
}

/// Revalidates main-actor account ownership after crossing the SessionStore actor boundary.
/// Returning session data is insufficient by itself: sign-out or a same-user replacement login
/// can rotate the local account lifetime while the lookup is suspended.
@MainActor
enum OutboxContextRevalidator {
    static func validate(
        localContextIsCurrent: () -> Bool,
        loadCurrentSession: () async -> SessionTokens?,
        sessionIsCurrent: (SessionTokens) -> Bool
    ) async -> Bool {
        guard localContextIsCurrent(),
              let currentSession = await loadCurrentSession(),
              localContextIsCurrent()
        else { return false }
        return sessionIsCurrent(currentSession)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: PersistedState = .empty
    /// Revision of the projection currently published in `state`. Every publish must go through
    /// `publishLatestState()`, which drops projections older than this — a snapshot captured
    /// before a suspension point must never roll back a newer publish (that was the root cause
    /// of sent bubbles, inbound messages, and freshly created conversations "disappearing").
    private var publishedStateRevision: UInt64 = 0
    @Published private(set) var capabilities: CapabilitiesDTO?
    @Published private(set) var isSignedIn = false
    @Published private(set) var isOnline = false
    @Published private(set) var isLoading = true
    @Published private(set) var accountSetupStep: AccountSetupStep?
    @Published private(set) var isCompletingAccountSetup = false
    @Published private(set) var isUpdatingProfile = false
    @Published var lastError: String?
    /// A validated inbound link waiting for the sign-in screen to act on it.
    @Published private(set) var pendingDeepLink: KitDeepLink?
    @Published private(set) var pendingPhone: String?
    @Published private(set) var pendingChallenge: AuthChallenge?
    @Published private(set) var pendingChallengeReceivedAt: Date?
    @Published var selectedTab = 0
    @Published private(set) var kycStatus: KYCStatus?
    @Published private(set) var sessionAssurance: SessionAssuranceDTO?
    @Published private(set) var callContacts: [CallableContact] = []
    @Published private(set) var callWaitingState = CallWaitingState()
    @Published private(set) var contactSyncState: AutomaticContactSyncState = .idle
    @Published private(set) var biometricKind: KitBiometricKind = .biometrics
    @Published private(set) var biometricUnlockEnabled = false
    @Published private(set) var biometricAccessState: KitBiometricGateState = .notRequired
    @Published private(set) var homeBiometricState: KitBiometricGateState = .notRequired
    @Published private(set) var isConfiguringBiometrics = false
    @Published private(set) var biometricErrorMessage: String?
    @Published private(set) var isRefreshingRegisteredDevices = false
    @Published private(set) var revokingRegisteredDeviceID: String?
    @Published private(set) var deviceManagementErrorMessage: String?
    @Published private(set) var securityPreferences: SecurityPreferencesDTO?
    @Published private(set) var isLoadingSecurityPreferences = false
    @Published private(set) var isUpdatingSecurityPreferences = false
    @Published private(set) var securityPreferencesErrorMessage: String?
    @Published private(set) var communicationPreferences: CommunicationPreferencesDTO?
    @Published private(set) var communicationBlocks: [CommunicationBlockDTO] = []
    @Published private(set) var isLoadingCommunicationPrivacy = false
    @Published private(set) var communicationPrivacyMutation: CommunicationPrivacyMutation?
    @Published private(set) var communicationPrivacyErrorMessage: String?
    @Published private(set) var hasLoadedCommunicationPrivacy = false
    @Published private(set) var profileEmailOperation: ProfileEmailOperation?
    @Published private(set) var isSubmittingAccountDeletion = false
    @Published private(set) var acceptedAccountDeletionCleanupBlocked = false
    @Published private(set) var protectedLocalStateRecoveryBlocked = false
    @Published private(set) var protectedLocalStateRecoveryRequiresSupport = false
    @Published private(set) var unresolvedAccountDeletionAttemptBlocked = false
    @Published private(set) var messageConversationNavigationRequest:
        MessageConversationNavigationRequest?
    /// A validated payment-claim alert that belongs to this account but not to one exact local
    /// group conversation. Home consumes it by opening the authoritative wallet activity surface.
    @Published private(set) var walletClaimNavigationRequest: WalletClaimNavigationRequest?
    /// A one-shot ask from another tab (Home's starter checklist) to open the new-message
    /// contact picker. An identity rather than a Bool so repeat taps re-trigger consumption.
    @Published private(set) var pendingNewMessageComposeID: UUID?
    /// Files (or a link) another app shared into Kit Pay, waiting for the customer to say which
    /// chat they are for. Drives the destination picker over the chats list.
    @Published private(set) var pendingSharedInboxBatch: SharedInboxBatch?
    /// A share that now has a destination, on its way to that conversation's composer.
    @Published private(set) var sharedInboxDelivery: SharedInboxDelivery?
    /// Compose-only first-contact identity for a shared payload. It never enters protected state
    /// by itself; explicit Send commits it atomically with the media bubble and outbox command.
    @Published private(set) var sharedInboxProvisionalConversation: Conversation?
    @Published private(set) var isBackingUpMessages = false
    @Published private(set) var isRestoringMessages = false
    @Published private(set) var isDeletingMessageBackup = false
    @Published private(set) var messageBackupReplacementAvailable = false
    @Published private(set) var messageBackupOperationError: String?
    @Published private(set) var messageBackupRefreshScheduleState:
        MessageBackupRefreshScheduleState = .inactive
    /// A decryptable iCloud backup exists and local history is empty; drives the restore prompt.
    @Published var availableBackupToRestore: MessageBackupSummary?
    /// True when the sign-in gate should offer PIN recovery because biometrics are locked out,
    /// unavailable, or the local enrollment can no longer succeed.
    @Published private(set) var biometricSignInPermanentlyUnavailable = false

    private let api: APIClient
    private let sessions: SessionStore
    private let store: SecureLocalStore
    private let biometrics: KitBiometricAuthenticator
    private let acceptedAccountDeletionPurges: AcceptedAccountDeletionPurgeStore
    private let accountDeletionAttempts: AccountDeletionAttemptStore
    private let contactSource: any DeviceContactsProviding
    private let pushRegistrations = PushRegistrationManager.shared
    private let connectivity = ConnectivityMonitor()
    private var observers: [NSObjectProtocol] = []
    /// Only one replay drains a given authenticated account at a time. A replacement sign-in may
    /// start its own drain while an older network request is unwinding; the epoch fence prevents
    /// that stale task from committing into the replacement account.
    private var flushingAccountEpoch: UUID?
    private var locallyTerminatedCallIds: Set<String> = []
    /// Answers that arrived before this device could name the call they belong to. Placing a
    /// call is a `POST /calls` whose response carries the call id and a socket that is already
    /// live, so on a slow uplink the callee can pick up while that response is still in
    /// flight. Held by exact call id, oldest first, and claimed the moment a response names
    /// its call; anything else ages out of the bounded buffer without ever being applied.
    private var pendingCallAnswers: [(callId: String, signal: CallAnswerSignal?)] = []
    private var accountEpoch = UUID()
    /// Financial recovery and encrypted-card draining share one main-actor single flight. A
    /// replacement account may start a new pass; every write remains fenced by account/session.
    private var isRecoveringFinancialChatReceipts = false
    private var financialChatReceiptRecoveryNeedsAnotherPass = false
    private var capabilitiesRequestTracker = CapabilitiesRequestResolutionTracker()
    private var messagingDeferredFeatureScope: MessagingDeferredFeatureScope?
    private var messagingDeferredFeatureSnapshot = MessagingDeferredFeatureSnapshot()
    private var kycRequestGeneration: UInt64 = 0
    private var communicationPrivacyRequestGeneration: UInt64 = 0
    private var contactDirectoryRevision: UInt64 = 0
    /// Forces a server-side contact eligibility recheck after a block transition even when an
    /// older contact sync was already in flight with an unchanged address-book fingerprint.
    private var contactAuthorizationRevision: UInt64 = 0
    private var refreshedContactAuthorizationRevision: UInt64 = 0
    private var contactSyncTask: Task<Bool, Never>?
    /// Records whether the active sync is guaranteed to consult the authenticated server. A
    /// recipient picker can upgrade an in-flight background/cache-eligible pass when needed.
    private var contactSyncCurrentTaskForcesServerRefresh = false
    private var contactSyncGeneration: UInt64 = 0
    private var contactChangeDebounceTask: Task<Void, Never>?
    private var resolvingSharedInboxBatchID: UUID?
    private var contactSyncNeedsAnotherPass = false
    private var didRequestContactsAtLaunch = false
    private var isApplyingAccountDiscoveryChoice = false
    private var activeConversationID: String?
    private var visibleConversationSyncTask: Task<Void, Never>?
    private var visibleConversationSleepTask: Task<Void, Never>?
    private var visibleConversationSyncWakePending = false
    private var visibleConversationSyncGeneration: UInt64 = 0
    private var visibleConversationRealtimeDisconnectedAt: Date?
    private var realtimeMessagingSyncTask: Task<Void, Never>?
    private var realtimeMessagingSyncNeedsRun = false
    private var realtimeMessagingSyncGeneration: UInt64 = 0
    private var realtimeMessagingSyncFingerprint: String?
    private var expiredBackgroundContactTasks: Set<ObjectIdentifier> = []
    private var expiredBackgroundCommunicationTasks: Set<ObjectIdentifier> = []
    private var restoreTask: Task<Void, Never>?
    private var profileUpdateTask: Task<Bool, Never>?
    private var profileUpdateTaskID: UUID?
    private var profileAvatarResumeTask: Task<Void, Never>?
    private var profileAvatarResumeTaskID: UUID?
    private var profileEmailOperationID: UUID?
    private var accountDeletionSubmissionID: UUID?
    private var volatileAcceptedAccountDeletion: PendingAcceptedAccountDeletion?
    private var privacyQuarantineTargetAccountID: String?
    private var deferredInvalidatedSessionID: String?
    private var authenticatedRefreshCount = 0
    private var profileAvatarResumeRequestedAfterRefresh = false
    /// A real background visit must reconcile cached wallet and account state when the protected
    /// foreground is visible again. The gate coalesces duplicate SwiftUI callbacks and retains the
    /// request while offline; connectivity recovery already performs the same bootstrap.
    private var foregroundAuthoritativeRefreshGate = ForegroundAuthoritativeRefreshGate()
    private var foregroundAuthoritativeRefreshTask: Task<Void, Never>?
    private var foregroundAuthoritativeRefreshTaskID: UUID?
    /// Model-owned so cancellation of a SwiftUI caller cannot discard a successful transactions
    /// response before it is durably committed. Concurrent refreshes for the same identity join
    /// this flight; changing account, session, or selected wallet cancels and replaces it.
    private var walletHistoryRefreshFlight: WalletHistoryRefreshFlight?
    private var appIsInBackground = false
    /// Mirrors what `ProfileAvatarCache` was last told, so publishing state stays a cheap
    /// comparison instead of an actor hop on every projection.
    private var avatarCacheAccountID: String?
    private var avatarCacheAccountSynced = false
    /// The own-profile photo already handed to the avatar cache, so warming it is a comparison
    /// rather than a repeated fetch on every publish.
    private var warmedOwnAvatarURL: String?
    private var callEventDrainTask: Task<Void, Never>?
    private let protectedCallRecoveryLatch = ProtectedCallRecoveryLatch()
    private var protectedCallRecoveryTicket = ProtectedCallRecoveryLatch.Ticket.initial
    private var protectedCallRecoveryResetSequence: UInt64 = 0
    private var callHistoryRefreshTask: Task<Void, Never>?
    private var callHistoryRefreshGeneration: UInt64 = 0
    private var callHistoryBackfillTask: Task<Void, Never>?
    private var callHistoryBackfillGeneration: UInt64 = 0
    private var callHistoryBackfillRetryNotBefore: Date?
    private var queuedCallEvents: [CallLifecycleEvent] = []
    private var callSystemEventDrainTask: Task<Void, Never>?
    private var outboxWakeTask: Task<Void, Never>?
    private var communicationReplayTask: Task<Bool, Never>?
    private var mediaPreprocessingTask: Task<Void, Never>?
    private var mediaPreprocessingGeneration: UInt64 = 0
    private var mediaHydrationTask: Task<Void, Never>?
    private var mediaHydrationGeneration: UInt64 = 0
    /// Main-actor reservations cover plaintext + transient ciphertext overlap across concurrent
    /// hydrations. Per-download free-space checks alone let four 200 MiB items all observe the
    /// same pre-download capacity and overcommit the volume.
    private var receivedMediaHydrationReservations: [UUID: Int] = [:]
    private var automaticBackupBackgroundTransitionTask: Task<Void, Never>?
    private var automaticBackupBackgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var queuedCallSystemActions: [CallSystemAction] = []
    private var receivedCallEventIds: Set<UUID> = []
    private var receivedCallEventOrder: [UUID] = []
    private var hasConnectivityStatus = false
    private var isSigningOut = false
    /// Invalidates responses from an authentication request whose UI flow was abandoned while the
    /// network call was suspended. This value is process-local and contains no credential material.
    private var authenticationAttempt = UUID()
    private var didResumeAuthenticatedSession = false
    private var biometricAuthenticationGate = BiometricAuthenticationOperationGate()
    private var returningSignInBiometricAuthorizationFence =
        ReturningSignInBiometricAuthorizationFence()
    private var homeBiometricAuthorizationFence = HomeBiometricAuthorizationFence()
    /// PIN recovery is also offered for a temporary system lockout, but only terminal key or
    /// enrollment failures should remove the stored biometric credential after PIN verification.
    private var biometricPINRecoveryRequiresEnrollmentRemoval = false
    private var biometricAuthenticationInProgress: Bool {
        biometricAuthenticationGate.isActive
    }
    private var secureMessagingSyncError = SecureMessagingSyncErrorOwnership()
    private var callMediaAccountLease: CallMediaAccountLease?
    private let waitingCallMergeOperationGate = WaitingCallMergeOperationGate()
    private var waitingCallMergeOperationID: UUID?
    private var waitingCallMergeAttempt: CallWaitingMergeAttempt?
    private var waitingCallMergeTask: Task<Bool, Never>?
    private var waitingCallMergeResultSignal: WaitingCallMergeResultSignal?
    private var ephemeralOutgoingCallGate = EphemeralOutgoingCallAttemptGate()
    private var ephemeralOutgoingCallTask: Task<Void, Never>?
    private var ephemeralOutgoingCallTaskID: UUID?
    private var ephemeralOutgoingCallResumePending = false
    private var outgoingCallRingDeadlineGate = OutgoingCallRingDeadlineGate()
    private var outgoingCallRingDeadlineTask: Task<Void, Never>?
    private var pendingEphemeralCallCancellations: [String: EphemeralOutgoingCallAttempt] = [:]
    private var ephemeralCallCancellationTask: Task<Void, Never>?
    private var conversationDraftWriterID = UUID()
    private var conversationDraftWriteSequence: UInt64 = 0
    private var deviceManagementGeneration: UInt64 = 0
    private var securityPreferencesRequestGeneration: UInt64 = 0
    /// Process-only authority established from a capability response bound to the current signed-
    /// in session. Demo content is projected in memory and is never written to protected storage.
    private var authenticatedAppReviewDemoOwnerID: String?

    /// Guards the one-shot starter-message milestone write from re-entrant publishes.
    private var isRecordingStarterMessageMilestone = false

    var phoneOTPAvailable: Bool {
        capabilities?.supportsPhoneOTP == true
    }

    var emailPasswordAvailable: Bool {
        capabilities?.supportsEmailPassword == true
    }

    var emailRecoveryAvailable: Bool {
        capabilities?.supportsEmailRecovery == true
    }

    var authenticatorMFAAvailable: Bool {
        capabilities?.supportsMFA == true
    }

    init(
        api: APIClient = .shared,
        sessions: SessionStore = .shared,
        store: SecureLocalStore = .shared,
        biometrics: KitBiometricAuthenticator = .shared,
        acceptedAccountDeletionPurges: AcceptedAccountDeletionPurgeStore = .shared,
        accountDeletionAttempts: AccountDeletionAttemptStore = .shared,
        contactSource: any DeviceContactsProviding = SystemDeviceContactsProvider()
    ) {
        self.api = api
        self.sessions = sessions
        self.store = store
        self.biometrics = biometrics
        self.acceptedAccountDeletionPurges = acceptedAccountDeletionPurges
        self.accountDeletionAttempts = accountDeletionAttempts
        self.contactSource = contactSource

#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            let fixtureState = AppStoreScreenshotFixture.state
            state = fixtureState
            sessionAssurance = fixtureState.sessionAssurance
            publishedStateRevision = 1
            capabilities = AppStoreScreenshotFixture.capabilities
            communicationPreferences = AppStoreScreenshotFixture.communicationPreferences
            communicationBlocks = []
            hasLoadedCommunicationPrivacy = true
            callContacts = AppStoreScreenshotFixture.callContacts
            isSignedIn = true
            isOnline = true
            isLoading = false
            return
        }
#endif

        ContactBackgroundRefreshScheduler.shared.installHandler { [weak self] task in
            Task { @MainActor in await self?.handleBackgroundContactRefresh(task) }
        }
        CommunicationBackgroundReplayScheduler.shared.installHandler { [weak self] task in
            Task { @MainActor in await self?.handleBackgroundCommunicationReplay(task) }
        }
        MessagingBackgroundAttachmentUploader.shared.installBackgroundEventsRecoveryHandler {
            [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion()
                    return
                }
                await self.recoverCompletedBackgroundMediaUpload()
                completion()
            }
        }

        MessageBackupRefreshScheduler.shared.installHandler { [weak self] task in
            // `setTaskCompleted` must run exactly once even if expiration races completion.
            let completion = BackgroundTaskCompletionLatch(task)
            let work = Task { @MainActor in
                guard let self else {
                    completion.finish(success: false)
                    return
                }
                if let restoreTask = self.restoreTask { await restoreTask.value }
                guard !Task.isCancelled else { return }
                let result = await self.runAutomaticMessageBackupIfDue()
                // A backup that simply wasn't due is still a successful check-in; reporting
                // failure would deflate the scheduler's priority for future runs.
                completion.finish(
                    success: !Task.isCancelled && result.backgroundTaskSucceeded
                )
            }
            task.expirationHandler = { [weak self] in
                work.cancel()
                completion.finish(success: false)
                // iOS consumed this request when it launched it. If expiration wins before the
                // automatic runner reaches its own rescheduling defer, preserve the selected
                // cadence by arming the next eligible opportunity again.
                Task { @MainActor in self?.scheduleAutomaticMessageBackupRefresh() }
            }
        }

        connectivity.onChange = { [weak self] online in
            Task { @MainActor in
                guard let self else { return }
                let transition = ConnectivityTransitionPolicy.transition(
                    previousOnline: self.hasConnectivityStatus ? self.isOnline : nil,
                    isOnline: online
                )
                self.isOnline = online
                self.hasConnectivityStatus = true
                switch transition {
                case .unchanged:
                    return
                case .recovered:
                    // The first path update can arrive while launch restoration is still
                    // resolving an accepted-account-deletion marker. Capabilities may use an
                    // available authenticated session, so never let reconnect work read or send
                    // cached credentials before that privacy barrier has completed.
                    guard let restoreTask = self.restoreTask else { return }
                    await restoreTask.value
                    guard !self.isSigningOut,
                          !self.isSubmittingAccountDeletion,
                          !self.acceptedAccountDeletionCleanupBlocked,
                          !self.protectedLocalStateRecoveryBlocked,
                          !self.unresolvedAccountDeletionAttemptBlocked
                    else { return }
                    if let currentUserID = self.profile?.id {
                        // Connectivity recovery is an explicit wake signal for registrations that
                        // stopped after bounded transient attempts. Move only this account's
                        // durable deadlines forward; cached Apple tokens below then coalesce the
                        // actual backend retry through PushRegistrationManager.
                        await self.pushRegistrations.expediteDeferredRetries(
                            accountID: currentUserID
                        )
                    }
                    NotificationCoordinator.shared.retryRemoteRegistrationIfNeeded()
                    NotificationCoordinator.shared.replayCurrentPushTokens()
                    await MessageNotificationActionDispatcher.shared.replayPending()
                    await ClaimablePaymentNotificationActionDispatcher.shared.replayPending()
                    self.scheduleEphemeralCallCancellationDrain()
                    if AuthenticatedProjectionRefreshPolicy.permits(
                        isSigningOut: self.isSigningOut,
                        isSignedIn: self.isSignedIn,
                        isOnline: self.isOnline,
                        accountSetupComplete: self.accountSetupStep == nil,
                        isSubmittingAccountDeletion: self.isSubmittingAccountDeletion,
                        acceptedAccountDeletionCleanupBlocked:
                            self.acceptedAccountDeletionCleanupBlocked,
                        protectedLocalStateRecoveryBlocked:
                            self.protectedLocalStateRecoveryBlocked,
                        unresolvedAccountDeletionAttemptBlocked:
                            self.unresolvedAccountDeletionAttemptBlocked
                    ) {
                        await self.refresh()
                        if self.communicationAccessGranted,
                           self.appReviewDemoMutationsAllowed,
                           self.capabilities != nil {
                            // A launch-time capability failure leaves authenticated session
                            // resume deliberately incomplete. Reconnection may have repaired the
                            // projection above; finish the same fenced resume now so APNs/VoIP,
                            // outbox replay and call recovery do not remain dormant forever.
                            if !self.didResumeAuthenticatedSession {
                                await self.resumeAuthenticatedSessionIfNeeded()
                            }
                            guard self.didResumeAuthenticatedSession,
                                  self.appReviewDemoMutationsAllowed,
                                  self.capabilities != nil
                            else { return }
                            self.resumeEphemeralOutgoingCallIfPossible()
                            await self.flushOutbox()
                            self.scheduleAutomaticContactSync()
                            _ = await self.runAutomaticMessageBackupIfDue()
                            // The refresh/sync above may have hydrated the exact conversation that
                            // was missing during the first recovery replay.
                            await MessageNotificationActionDispatcher.shared.replayPending()
                            await ClaimablePaymentNotificationActionDispatcher.shared.replayPending()
                        }
                    } else if self.isSignedIn {
                        // Incomplete accounts do not enter the full session-resume path, but
                        // still need an authenticated capability decision before setup writes.
                        _ = await self.reloadCapabilities()
                    } else {
                        _ = await self.reloadCapabilities()
                    }
                case .lost:
                    self.suspendEphemeralOutgoingCallSubmission()
                    self.outboxWakeTask?.cancel()
                    self.outboxWakeTask = nil
                    self.mediaHydrationGeneration &+= 1
                    self.mediaHydrationTask?.cancel()
                    self.mediaHydrationTask = nil
                }
            }
        }
        connectivity.start()

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .kitSessionInvalidated,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let invalidatedSessionID = notification.object as? String else { return }
                Task { @MainActor in
                    await self?.handleSessionInvalidation(invalidatedSessionID)
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .CNContactStoreDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.contactsDidChange() }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .kitPushTokenReceived,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let registration = notification.object as? PushTokenRegistration else { return }
                Task { @MainActor in
                    await self?.registerPushToken(registration.token, provider: registration.provider)
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .kitCallLifecycleEvent,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let event = notification.object as? CallLifecycleEvent else { return }
                // Delivery is explicitly on the main queue. Enter the actor synchronously so the
                // cache's incoming-before-action order cannot be changed by independent Tasks.
                MainActor.assumeIsolated {
                    self?.enqueueCallLifecycleEvent(event)
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .kitCallMediaFailed,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let failure = notification.object as? CallMediaFailure else { return }
                Task { @MainActor in await self?.handleCallMediaFailure(failure) }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .kitCallRemoteParticipantConnected,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let callID = notification.object as? String else { return }
                MainActor.assumeIsolated {
                    guard let self, let lease = self.callMediaAccountLease else { return }
                    self.cancelOutgoingCallRingDeadline(
                        backendCallID: callID,
                        lease: lease
                    )
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .kitPendingOutgoingCallEnded,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let clientCallID = notification.object as? String else { return }
                Task { @MainActor in
                    self?.cancelEphemeralOutgoingCall(
                        clientCallID: clientCallID,
                        dismissPresentation: false
                    )
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .kitRemoteWakeReceived,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let remoteEnd = notification.object as? RemoteCallMediaEndedWake {
                    // CallMediaCoordinator posts this synchronously on MainActor immediately after
                    // clearing its presentation. Retire the waiter before a newer call can appear.
                    MainActor.assumeIsolated {
                        self?.handleRemoteCallMediaEndedWake(remoteEnd)
                    }
                    Task { @MainActor in await self?.refresh() }
                    return
                }
                if let payload = notification.object as? [AnyHashable: Any],
                   let answered = CallAnsweredPush(payload: payload) {
                    // The push fallback of the answer signal. Applied directly — the refresh
                    // that used to be this wake's only effect still runs, but off the path
                    // between the callee picking up and this device reflecting it.
                    MainActor.assumeIsolated {
                        self?.handleCallAnswerSignal(
                            callId: answered.callId,
                            signal: answered.signal
                        )
                    }
                    Task { @MainActor in await self?.refresh() }
                    return
                }
                Task { @MainActor in
                    guard let self else { return }
                    if SecureMessagingRemoteWake(notification.object) != nil {
                        await self.syncSecureMessagingIfPermitted(
                            presentsVisibleMessageNotifications: true
                        )
                    } else {
                        await self.refresh()
                    }
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .kitPushTokenInvalidated,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let provider = notification.object as? String else { return }
                Task { @MainActor in await self?.unregisterPushToken(provider: provider) }
            }
        )

        Task { [weak self] in
            await SecureMessagingWakeDispatcher.shared.install { [weak self] _ in
                guard let self else { return .failed }
                return await self.handleSecureMessagingWake()
            }
        }

        restoreTask = Task { [weak self] in await self?.restore() }
        Task { [weak self] in
            await MessageNotificationActionDispatcher.shared.install { [weak self] action in
                guard let self else { return .retry }
                return await self.handleMessageNotificationAction(action)
            }
        }
        Task { [weak self] in
            await ClaimablePaymentNotificationActionDispatcher.shared.install { [weak self] action in
                guard let self else { return .retry }
                return await self.handleClaimablePaymentNotificationAction(action)
            }
        }
        NotificationCoordinator.shared.replayPendingCallEvents()
    }

    private func handleSecureMessagingWake() async -> UIBackgroundFetchResult {
        if let restoreTask { await restoreTask.value }
        // Local transforms must not become a process-wide gate. Commands whose own media still
        // needs preprocessing are parked by `awaitingMediaPreprocessing`; every other
        // conversation can sync and drain immediately. The preprocessing task schedules a
        // second wake/flush after it publishes each finished representation.
        schedulePendingMediaPreprocessing()
        let result = await syncSecureMessagingIfPermitted(
            presentsVisibleMessageNotifications: true
        )
        await drainReadyOutbox()
        return result
    }

    deinit {
        contactSyncTask?.cancel()
        contactChangeDebounceTask?.cancel()
        restoreTask?.cancel()
        profileUpdateTask?.cancel()
        profileAvatarResumeTask?.cancel()
        callEventDrainTask?.cancel()
        callHistoryRefreshTask?.cancel()
        callHistoryBackfillTask?.cancel()
        walletHistoryRefreshFlight?.task.cancel()
        callSystemEventDrainTask?.cancel()
        waitingCallMergeTask?.cancel()
        visibleConversationSyncTask?.cancel()
        outboxWakeTask?.cancel()
        communicationReplayTask?.cancel()
        mediaPreprocessingTask?.cancel()
        ephemeralOutgoingCallTask?.cancel()
        outgoingCallRingDeadlineTask?.cancel()
        ephemeralCallCancellationTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var profile: UserProfile? { state.profile }
    var appReviewDemoIsActive: Bool {
        guard let ownerID = authenticatedAppReviewDemoOwnerID,
              isSignedIn,
              profile?.id.caseInsensitiveCompare(ownerID) == .orderedSame
        else { return false }
        return true
    }
    var appReviewDemoMutationsAllowed: Bool {
        AppReviewDemoMutationPolicy.allowsAccountMutation(
            isSignedIn: isSignedIn,
            hasAuthenticatedCapabilities: capabilities != nil,
            isDemoActive: appReviewDemoIsActive
        )
    }
    func isReadOnlyAppReviewDemoConversation(_ conversationID: String) -> Bool {
        AppReviewDemoMutationPolicy.conversationIsReadOnly(
            conversationID,
            isDemoActive: appReviewDemoIsActive
        )
    }
    func isReadOnlyAppReviewDemoCall(_ callID: String) -> Bool {
        AppReviewDemoMutationPolicy.callIsReadOnly(
            callID,
            isDemoActive: appReviewDemoIsActive
        )
    }
    @discardableResult
    private func rejectAppReviewDemoMutation() -> Bool {
        guard appReviewDemoMutationsAllowed else {
            lastError = AppReviewDemoMutationPolicy.readOnlyMessage
            return true
        }
        return false
    }
    var waitingCall: AuthenticatedWaitingCall? { callWaitingState.waitingCall }
    var isMergingWaitingCall: Bool { callWaitingState.isMerging }
    var communicationSurfacesConcealed: Bool {
        isSubmittingAccountDeletion
            || acceptedAccountDeletionCleanupBlocked
            || protectedLocalStateRecoveryBlocked
            || unresolvedAccountDeletionAttemptBlocked
    }
    var isManagingProfileEmail: Bool { profileEmailOperation != nil }
    var contactDirectory: [WalletContactDTO] { state.contacts ?? [] }
    var registeredDevices: [DeviceDTO] { state.registeredDevices ?? [] }
    var verifyIdentityOnNewLogin: Bool {
        securityPreferences?.verifyIdentityOnNewLogin ?? false
    }
    var hasLoadedSecurityPreferences: Bool { securityPreferences != nil }
    var isManagingSecurityPreferences: Bool {
        isLoadingSecurityPreferences || isUpdatingSecurityPreferences
    }
    var communicationContactDirectory: [WalletContactDTO] {
        contactDirectory.filter { contact in
            if let userID = ContactRecipientDirectory.recipientUserId(for: contact) {
                return communicationPrivacyAllowsOutbound(to: userID)
            }
            // A malformed row claiming to be a Kit Pay account is not downgraded into an invite.
            return contact.isKitUser != true
        }
    }
    var phoneIdentityContext: PhoneIdentityContext {
        PhoneIdentityContext(
            referencePhone: profile?.phone,
            countryISOCode: profile?.countryCode ?? Locale.current.region?.identifier
        )
    }
    var selectedWallet: Wallet? {
        if let selected = WalletIdentityResolver.wallet(
            matching: state.selectedWalletId,
            in: state.wallets
        ) {
            return selected
        }
        return state.wallets.first(where: { $0.isPrimary == true }) ?? state.wallets.first
    }
    var queuedCount: Int {
        state.outbox.filter { $0.failureDisposition != .requiresUserRetry }.count
    }
    var pinnedConversationIds: Set<String> { Set(state.pinnedConversationIds ?? []) }
    var mutedConversationIds: Set<String> { Set(state.mutedConversationIds ?? []) }
    var messageBackupPreferences: MessageBackupPreferences {
        state.messageBackupPreferences ?? .default
    }
    var biometricDisplayName: String { biometricKind.displayName }
    var biometricSymbolName: String { biometricKind.symbolName }
    var financialApprovalUsesBiometrics: Bool {
        KitFinancialStepUpApprovalPolicy.method(
            biometricsEnabled: biometricUnlockEnabled
        ) == .biometricSignature
    }
    /// Authenticated communication is intentionally available before account KYC. A restricted
    /// session may chat, call and manage its account; it still cannot cross a financial guard.
    var communicationAccessGranted: Bool {
        guard let profile else { return false }
        return sessionAssurance?.grantsCommunicationAccess(
            accountKYCStatus: kycStatus?.accountStatus ?? profile.kycStatus
        ) == true
    }
    /// Account-wide KYC unlocks money. Public verification (`profile.verification`) is a separate
    /// server designation and must never influence this decision.
    var hasVerifiedIdentityForMoney: Bool {
        MoneyIdentityAccessPolicy.isVerified(
            liveAccountStatus: kycStatus?.accountStatus,
            cachedProfileStatus: profile?.kycStatus
        )
    }
    /// Money movement needs both account-wide KYC and the existing device/login assurance.
    /// Public verification is intentionally unrelated to this authorization boundary.
    var financialAccessGranted: Bool {
        moneyActionAccessRequirement == .allowed
    }
    var moneyActionAccessRequirement: MoneyActionAccessRequirement {
        MoneyActionAccessPolicy.requirement(
            identityVerified: hasVerifiedIdentityForMoney,
            sessionGrantsFullAccess: sessionAssurance?.grantsFullAccess == true,
            scopedCommunication: sessionAssurance?.communicationAccess,
            scopedFinancial: sessionAssurance?.financialAccess
        )
    }
    /// Read-only App Review sessions may inspect the server-approved financial projection while
    /// every money-moving action remains denied.
    var financialDataAccessGranted: Bool {
        MoneyActionAccessPolicy.permitsFinancialData(
            identityVerified: hasVerifiedIdentityForMoney,
            sessionGrantsFullAccess: sessionAssurance?.grantsFullAccess == true,
            scopedCommunication: sessionAssurance?.communicationAccess,
            scopedFinancial: sessionAssurance?.financialAccess
        )
    }
    var requiresBiometricSignIn: Bool {
        isSignedIn
            && accountSetupStep == nil
            && biometricUnlockEnabled
            && biometricAccessState != .authorized
    }
    var homeAccessGranted: Bool {
        !biometricUnlockEnabled
            || homeBiometricState == .notRequired
            || homeBiometricState == .authorized
    }
    /// While a working biometric enrollment exists, biometrics are the only unlock method the UI
    /// offers; a transient failure (cancel, lockout) keeps this true so the PIN is never
    /// requested behind an enrolled user's back. Terminal enrollment failures disable
    /// `biometricUnlockEnabled` first, which flips this to false and legitimizes the PIN path.
    var loginUnlockSupportsBiometrics: Bool {
        biometricUnlockEnabled
            && !biometricSignInPermanentlyUnavailable
            && sessionAssurance?.loginUnlock.supportsBiometricSignature == true
    }
    /// Secure messaging remains fail-closed unless the server advertises the reviewed wire
    /// protocol and this device owns the active enrollment. Build 5 enables that reviewed path
    /// so TestFlight devices can exercise real encrypted delivery and recovery end to end.
    var secureMessagingAvailable: Bool {
        secureMessagingReleasePermitted
            && hasCurrentSecureMessagingEnrollment
    }
    /// Local composition does not require a live Signal enrollment. The protected outbox is the
    /// first destination for a send, and `flushOutbox` activates/repairs E2EE before it can create
    /// a fanout or touch the message transport. Keeping this separate from
    /// `secureMessagingAvailable` prevents a missing/rotating enrollment from disabling the
    /// composer while retaining the no-plaintext-network invariant.
    var secureMessagingLocalQueueAvailable: Bool {
        SecureMessagingLocalQueueReleasePolicy.permits(
            buildEnabled: SecureMessagingReleaseGate.enabled
        )
            && isSignedIn
            && !isSigningOut
            && accountSetupStep == nil
            && communicationAccessGranted
            && !communicationSurfacesConcealed
    }
    private var secureMessagingReleasePermitted: Bool {
        guard SecureMessagingReleaseGate.enabled else { return false }
        if let capabilities {
            return capabilities.supportsFeature("messaging")
                && capabilities.protocols?.messaging?.supportsReviewedV2 == true
        }
        // Capabilities are nil while discovery is (re)loading — at session resume, after a
        // failed reload on flaky networks, and offline. An enrolled device may keep composing
        // and queueing locally through that window regardless of connectivity. Dispatch requires
        // a restored authenticated projection and current roster, and the server authoritatively
        // rechecks both before accepting encrypted envelopes, so this only prevents the composer
        // flapping to "temporarily unavailable" every time discovery restarts.
        return state.secureMessaging?.enrollment?.userID == profile?.id
    }

    private var hasCurrentSecureMessagingEnrollment: Bool {
        state.secureMessaging?.enrollment?.userID == profile?.id
    }
    /// Group mutations stay fail-closed until the server advertises the reviewed protocol and
    /// group feature. Enrollment is recovered later by the same secure flush boundary as direct
    /// messages; unlike composing into an existing thread, group creation is never permitted
    /// through a capability-discovery gap.
    var messagingGroupsEnabled: Bool {
        secureMessagingReleasePermitted
            && capabilities?.supportsFeature(MessagingGroupCapabilityPolicy.featureKey) == true
    }
    /// Existing group messages are safe to commit locally during a capability-discovery gap unless
    /// this exact account/session last confirmed a withdrawal. The local flush gate requires an
    /// authenticated capability projection, the coordinator validates the current device roster,
    /// and the server atomically rechecks its feature gate and roster before accepting ciphertext.
    var messagingGroupLocalQueueEnabled: Bool {
        secureMessagingLocalQueueAvailable
            && messagingDeferredFeatureSnapshot.allowsLocalQueue(
                .groups,
                advertisedCapability: capabilities.map { _ in messagingGroupsEnabled },
                in: messagingDeferredFeatureScope
            )
    }
    var messagingReactionsEnabled: Bool {
        secureMessagingReleasePermitted
            && MessagingReactionCapabilityPolicy.isEnabled(features: capabilities?.features)
    }
    var messagingReactionLocalQueueEnabled: Bool {
        secureMessagingLocalQueueAvailable
            && messagingDeferredFeatureSnapshot.allowsLocalQueue(
                .reactions,
                advertisedCapability: capabilities.map { _ in messagingReactionsEnabled },
                in: messagingDeferredFeatureScope
            )
    }
    var messagingMessageEditsEnabled: Bool {
        secureMessagingReleasePermitted
            && MessagingMessageEditCapabilityPolicy.isEnabled(features: capabilities?.features)
    }
    var messagingMessageEditLocalQueueEnabled: Bool {
        secureMessagingLocalQueueAvailable
            && messagingDeferredFeatureSnapshot.allowsLocalQueue(
                .messageEdits,
                advertisedCapability: capabilities.map { _ in messagingMessageEditsEnabled },
                in: messagingDeferredFeatureScope
            )
    }
    /// Live capability discovery is authoritative. During a cold offline relaunch (or a transient
    /// refresh failure), only the encrypted receipt issued to this exact account/session keeps
    /// first-contact text and media queueable; an unproven account remains fail-closed.
    var messagingOfflineDirectCreationLocalQueueEnabled: Bool {
        guard secureMessagingLocalQueueAvailable,
              isSignedIn,
              !isSigningOut,
              let scope = messagingDeferredFeatureScope,
              scope.accountEpoch == accountEpoch,
              profile?.id.caseInsensitiveCompare(scope.userID) == .orderedSame,
              state.communicationOwnerUserID?.caseInsensitiveCompare(scope.userID)
                  == .orderedSame
        else { return false }
        if capabilities != nil, !appReviewDemoMutationsAllowed { return false }
        return MessagingOfflineDirectCreationCapabilityPolicy.allowsLocalQueue(
            authoritativeCapabilities: capabilities,
            receipt: state.messagingOfflineDirectCreationCapabilityReceipt,
            in: scope
        )
    }
    /// A live writable response permits the legacy online create-before-queue path. Offline, the
    /// direct-creation receipt is the only durable proof that this account may create the local
    /// provisional thread, so the UI cannot offer a send that the queue boundary must reject.
    var newDirectMessageCompositionAllowed: Bool {
        if messagingOfflineDirectCreationLocalQueueEnabled { return true }
        return isOnline
            && secureMessagingLocalQueueAvailable
            && appReviewDemoMutationsAllowed
    }

    private func bindDeferredMessagingFeatures(to scope: MessagingDeferredFeatureScope) {
        messagingDeferredFeatureScope = scope
        messagingDeferredFeatureSnapshot.bind(to: scope)
    }

    private func resetDeferredMessagingFeatures() {
        messagingDeferredFeatureScope = nil
        messagingDeferredFeatureSnapshot.reset()
    }

    var messagingRealtimeConfiguration: KitRealtimeConfiguration? {
        guard appReviewDemoMutationsAllowed, secureMessagingAvailable else { return nil }
        return capabilities?.protocols?.realtime?.validatedConfiguration
    }
    var messagingRealtimeLifecycleIdentity: String {
        [
            profile?.id ?? "signed-out",
            messagingRealtimeConfiguration?.lifecycleIdentity ?? "polling",
            String(isSignedIn),
            String(accountSetupStep == nil),
            String(communicationAccessGranted),
            String(requiresBiometricSignIn),
            String(communicationPreferences?.messagingPresenceVisible ?? false),
        ].joined(separator: ":")
    }
    var realtimeVisibleConversationID: String? { activeConversationID }
    var messagingRealtimeAvailable: Bool {
        messagingRealtimeConfiguration != nil
            && KitPresenceCenter.shared.hasProductionTransport
    }
    var messagingPresenceEnabled: Bool {
        messagingRealtimeConfiguration?.presenceEnabled == true
            && KitPresenceCenter.shared.hasProductionTransport
    }
    var messagingSendFailureMessage: String { CustomerFacingMessagingCopy.sendFailure }
    var callsFeatureEnabled: Bool { CallLifecyclePolicy.featureEnabled(capabilities) }
    /// The picker is a read/recovery surface, so a missing capability response must not make its
    /// own retry action unreachable. Known demo ownership and an explicit Calls withdrawal remain
    /// fail-closed, and `queueCall` revalidates all mutation authority before it creates anything.
    var callReadinessPickerAvailable: Bool {
        CallReadinessSurfacePolicy.permitsPicker(
            signedIn: isSignedIn,
            signingOut: isSigningOut,
            accountSetupComplete: accountSetupStep == nil,
            communicationAccessGranted: communicationAccessGranted,
            communicationSurfacesConcealed: communicationSurfacesConcealed,
            isDemoActive: appReviewDemoIsActive,
            callsExplicitlyWithdrawn: capabilities?.featureIsWithdrawn("calls") == true
        )
    }

    func callReadinessAllowsRecipientAction(_ rawUserID: String?) -> Bool {
        guard let recipientUserID = CommunicationPrivacyIdentifier.canonicalUUID(rawUserID),
              recipientUserID != CommunicationPrivacyIdentifier.canonicalUUID(profile?.id)
        else { return false }
        let privacyDecision = CommunicationPrivacyAccessPolicy.decision(
            ownerUserID: profile?.id,
            recipientUserID: recipientUserID,
            hasLoadedCompleteProjection: hasUsableCommunicationPrivacyProjection,
            blocks: communicationBlocks
        )
        return CallReadinessSurfacePolicy.permitsRecipientAction(
            pickerPermitted: callReadinessPickerAvailable,
            privacyDecision: privacyDecision
        )
    }

    var mayCreateCall: Bool {
        appReviewDemoMutationsAllowed && CallLifecyclePolicy.mayCreateCall(
            signedIn: isSignedIn,
            online: isOnline,
            capabilities: capabilities
        )
    }

    private func enqueueCallLifecycleEvent(_ event: CallLifecycleEvent) {
        guard receivedCallEventIds.insert(event.id).inserted else { return }
        guard appReviewDemoMutationsAllowed,
              !communicationSurfacesConcealed
        else {
            NotificationCoordinator.shared.acknowledgeCallEvent(event.id)
            return
        }
        let requiresAuthenticatedIncomingFirst: Bool
        if case .systemAction(let action) = event {
            requiresAuthenticatedIncomingFirst = callSystemActionRequiresAuthenticatedIncomingFirst(
                action
            )
        } else {
            requiresAuthenticatedIncomingFirst = false
        }
        receivedCallEventOrder.append(event.id)
        while receivedCallEventOrder.count > 128 {
            receivedCallEventIds.remove(receivedCallEventOrder.removeFirst())
        }
        if case .systemAction(let action) = event,
           action.kind == .decline || action.kind == .end || action.kind == .timedOut {
            if let lease = callMediaAccountLease {
                cancelOutgoingCallRingDeadline(
                    backendCallID: action.callId,
                    lease: lease
                )
            }
            // Cancellation intent must be visible while an earlier answer request is suspended.
            // Otherwise accepted media could reconnect briefly after the user has hung up.
            locallyTerminatedCallIds.insert(action.callId.lowercased())
        }
        if case .incoming = event {
            // This client supports one CallKit/media admission at a time. Prioritize the real
            // incoming call over an offline/provisional outgoing screen and fence any late POST.
            cancelEphemeralOutgoingCall(dismissPresentation: true)
        }
        if case .systemAction(let action) = event,
           action.kind == .answer,
           !requiresAuthenticatedIncomingFirst {
            // The answer event can be restored independently of its incoming notice. Repeat the
            // cancellation synchronously so a stale pending client ID can never poison media.
            cancelEphemeralOutgoingCall(dismissPresentation: true)
        }
        if case .systemAction(let action) = event,
           action.kind == .answer,
           !requiresAuthenticatedIncomingFirst,
           let lease = callMediaAccountLease {
            CallMediaCoordinator.shared.presentConnecting(
                incomingPresentation(for: action),
                lease: lease
            )
        }
        if case .systemAction(let action) = event,
           action.kind != .timedOut,
           !requiresAuthenticatedIncomingFirst {
            queuedCallSystemActions.append(action)
            startCallSystemEventDrainIfNeeded()
            return
        }
        queuedCallEvents.append(event)
        startCallEventDrainIfNeeded()
    }

    private func startCallEventDrainIfNeeded() {
        guard callEventDrainTask == nil else { return }
        let recoveryTicket = protectedCallRecoveryTicket
        let recoveryAccountEpoch = accountEpoch
        callEventDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.protectedCallRecoveryTicket == recoveryTicket,
                   self.accountEpoch == recoveryAccountEpoch {
                    self.callEventDrainTask = nil
                }
            }
            guard await self.awaitProtectedCallRecovery(
                ticket: recoveryTicket,
                accountEpoch: recoveryAccountEpoch
            ) else { return }
            while !Task.isCancelled,
                  self.protectedCallRecoveryTicket == recoveryTicket,
                  self.accountEpoch == recoveryAccountEpoch,
                  !self.queuedCallEvents.isEmpty {
                let event = self.queuedCallEvents.removeFirst()
                guard !self.acceptedAccountDeletionCleanupBlocked,
                      !self.protectedLocalStateRecoveryBlocked,
                      !self.unresolvedAccountDeletionAttemptBlocked
                else {
                    NotificationCoordinator.shared.acknowledgeCallEvent(event.id)
                    continue
                }
                switch event {
                case .verificationRequested(let request):
                    await self.verifyIncomingCallOwnership(request)
                case .incoming(let notice):
                    await self.recordAuthenticatedIncomingCall(notice.call)
                case .systemAction(let action):
                    await self.handleCallSystemAction(action)
                }
                NotificationCoordinator.shared.acknowledgeCallEvent(event.id)
            }
        }
    }

    private func startCallSystemEventDrainIfNeeded() {
        guard callSystemEventDrainTask == nil else { return }
        let recoveryTicket = protectedCallRecoveryTicket
        let recoveryAccountEpoch = accountEpoch
        callSystemEventDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.protectedCallRecoveryTicket == recoveryTicket,
                   self.accountEpoch == recoveryAccountEpoch {
                    self.callSystemEventDrainTask = nil
                }
            }
            guard await self.awaitProtectedCallRecovery(
                ticket: recoveryTicket,
                accountEpoch: recoveryAccountEpoch
            ) else { return }
            while !Task.isCancelled,
                  self.protectedCallRecoveryTicket == recoveryTicket,
                  self.accountEpoch == recoveryAccountEpoch,
                  !self.queuedCallSystemActions.isEmpty {
                let action = self.queuedCallSystemActions.removeFirst()
                if self.isSubmittingAccountDeletion
                    || self.acceptedAccountDeletionCleanupBlocked
                    || self.protectedLocalStateRecoveryBlocked
                    || self.unresolvedAccountDeletionAttemptBlocked {
                    await self.retireBlockedCallActionIfOwned(action)
                } else {
                    await self.handleCallSystemAction(action)
                }
                NotificationCoordinator.shared.acknowledgeCallEvent(action.eventId)
            }
        }
    }

    private func awaitProtectedCallRecovery(
        ticket: ProtectedCallRecoveryLatch.Ticket,
        accountEpoch expectedAccountEpoch: UUID
    ) async -> Bool {
        let expectedSession = await sessions.current()
        guard !Task.isCancelled,
              protectedCallRecoveryTicket == ticket,
              accountEpoch == expectedAccountEpoch
        else { return false }

        let resolution = await protectedCallRecoveryLatch.wait(for: ticket)
        guard !Task.isCancelled,
              resolution != .superseded,
              protectedCallRecoveryTicket == ticket,
              accountEpoch == expectedAccountEpoch
        else { return false }

        let currentSession = await sessions.current()
        guard !Task.isCancelled,
              protectedCallRecoveryTicket == ticket,
              accountEpoch == expectedAccountEpoch
        else { return false }

        switch resolution {
        case .ready:
            guard let currentSession,
                  let expectedUserID = currentSession.accountId,
                  let lease = callMediaAccountLease,
                  lease.accountEpoch == expectedAccountEpoch,
                  lease.userID.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  lease.sessionID.caseInsensitiveCompare(currentSession.sessionId) == .orderedSame
            else { return false }
            if let expectedSession,
               !SessionAccountBindingPolicy.identifiesSameAccountSession(
                   expectedSession,
                   currentSession
               ) {
                return false
            }
            return true
        case .unavailable:
            return false
        case .superseded:
            return false
        }
    }

    private func incomingPresentation(for action: CallSystemAction) -> ActiveCallPresentation {
        let storedCall = state.calls.first {
            $0.id.caseInsensitiveCompare(action.callId) == .orderedSame
        }
        let avatarURL = callParticipantAvatarURL(
            for: storedCall?.participantUserIds,
            identities: storedCall?.participantIdentities
        )
        if let presentation = action.presentation {
            return ActiveCallPresentation(
                id: presentation.id,
                conversationId: presentation.conversationId,
                participantName: presentation.participantName,
                participantAvatarURL: presentation.participantAvatarURL ?? avatarURL,
                participantVerification: presentation.participantVerification
                    ?? callParticipantVerification(
                        for: storedCall?.participantUserIds,
                        identities: storedCall?.participantIdentities
                    ),
                video: presentation.video,
                direction: presentation.direction
            )
        }
        return ActiveCallPresentation(
            id: action.callId,
            participantName: storedCall?.name ?? "Kit Pay contact",
            participantAvatarURL: avatarURL,
            participantVerification: callParticipantVerification(
                for: storedCall?.participantUserIds,
                identities: storedCall?.participantIdentities
            ),
            video: storedCall?.isVideoCall ?? false,
            direction: "incoming"
        )
    }

    /// Waiting-call actions must stay behind the authenticated incoming notice that authorizes the
    /// caller identity used by Merge. An Answer action is also moved to that ordered lane whenever
    /// it targets a different in-memory call, so it can never replace an existing media session.
    private func callSystemActionRequiresAuthenticatedIncomingFirst(
        _ action: CallSystemAction
    ) -> Bool {
        switch action.kind {
        case .mergeWaiting:
            return true
        case .answer:
            return callActionTargetsDifferentActiveMediaCall(action)
        case .decline, .end, .timedOut:
            return false
        }
    }

    private func callActionTargetsDifferentActiveMediaCall(
        _ action: CallSystemAction
    ) -> Bool {
        guard let activeCallID = CallMediaCoordinator.shared.activeCall?.id else { return false }
        // Once media exists, malformed ownership is contradictory rather than equivalent. Route
        // it through the different-call rejection path so it can never replace current media.
        guard let canonicalActiveCallID = canonicalCallID(activeCallID),
              let canonicalActionCallID = canonicalCallID(action.callId)
        else { return true }
        return canonicalActiveCallID != canonicalActionCallID
    }

    private func canonicalCallID(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        return identifier.uuidString.lowercased()
    }

    private func callOwnsActiveMedia(callID: String) -> Bool {
        guard let callID = canonicalCallID(callID) else { return false }
        if let presentedCallID = CallMediaCoordinator.shared.activeCall?.id,
           let presentedCallID = canonicalCallID(presentedCallID) {
            return presentedCallID == callID
        }
        return state.calls.contains {
            canonicalCallID($0.id) == callID && $0.state == .active
        }
    }

    private func callParticipantAvatarURL(
        for participantUserIds: [String]?,
        identities: [String: AccountIdentityProjection]? = nil
    ) -> String? {
        guard let remoteUserId = participantUserIds?.first(where: {
            $0.caseInsensitiveCompare(profile?.id ?? "") != .orderedSame
        }) else { return nil }
        if let identity = identities?[remoteUserId.lowercased()],
           identity.isValid,
           let avatarURL = identity.avatarURL {
            return avatarURL
        }
        return contactAvatarURL(forUserID: remoteUserId)
    }

    private func callParticipantVerification(
        for participantUserIds: [String]?,
        identities: [String: AccountIdentityProjection]? = nil
    ) -> AccountVerificationDesignation? {
        let remoteUserIds = participantUserIds?.filter {
            $0.caseInsensitiveCompare(profile?.id ?? "") != .orderedSame
        } ?? []
        // A call-level name can claim one person's designation only when the authenticated roster
        // has one remote account. Multi-person calls keep per-participant badges on their named
        // tiles; borrowing the first member's badge for a group title would be misleading.
        guard remoteUserIds.count == 1, let remoteUserId = remoteUserIds.first else { return nil }
        if let identity = identities?[remoteUserId.lowercased()],
           identity.isValid,
           let verification = identity.verification?.designation {
            return verification
        }
        return contactVerification(forUserID: remoteUserId)
    }

    func callParticipantAvatarURL(for call: CallRecord) -> String? {
        callParticipantAvatarURL(
            for: call.participantUserIds,
            identities: call.participantIdentities
        )
    }

    func callParticipantVerification(
        for call: CallRecord
    ) -> AccountVerificationDesignation? {
        callParticipantVerification(
            for: call.participantUserIds,
            identities: call.participantIdentities
        )
    }

    /// The profile photo the contact directory holds for a Kit Pay user, if any.
    ///
    /// The directory is part of the persisted projection, so this keeps answering offline — the
    /// photo itself then comes from `ProfileAvatarCache`, which is why a face still appears in
    /// call history with no network.
    func contactAvatarURL(forUserID userID: String?) -> String? {
        guard let userID else { return nil }
        let rawValue: String?
        if let profile, profile.id.caseInsensitiveCompare(userID) == .orderedSame {
            // The signed-in customer is never in their own contact directory, so their photo has
            // to come from the profile or a group list would show them as initials alone.
            rawValue = profile.avatarURL
        } else {
            rawValue = contactDirectory.first(where: { contact in
                guard let recipientUserID = ContactRecipientDirectory.recipientUserId(for: contact)
                else { return false }
                return recipientUserID.caseInsensitiveCompare(userID) == .orderedSame
            })?.avatarURL ?? persistedAccountIdentity(forUserID: userID)?.avatarURL
        }
        return ProfileAvatarCache.validatedURL(rawValue)?.absoluteString
    }

    /// The public verification designation published for a user, if any.
    ///
    /// Like avatar resolution, this reads only the authenticated profile/contact projection and
    /// remains available offline. It deliberately never consults KYC, legal-name, phone, or email
    /// verification: those checks grant capabilities, not Kit's public blue badge.
    func contactVerification(forUserID userID: String?) -> AccountVerificationDesignation? {
        guard let userID else { return nil }
        if let profile, profile.id.caseInsensitiveCompare(userID) == .orderedSame {
            return profile.verification?.designation
        }
        return contactDirectory.first(where: { contact in
            guard let recipientUserID = ContactRecipientDirectory.recipientUserId(for: contact)
            else { return false }
            return recipientUserID.caseInsensitiveCompare(userID) == .orderedSame
        })?.verification?.designation
            ?? persistedAccountIdentity(forUserID: userID)?.verification?.designation
    }

    private func persistedAccountIdentity(forUserID rawUserID: String) -> AccountIdentityProjection? {
        guard rawUserID == rawUserID.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: rawUserID)
        else { return nil }
        let userID = identifier.uuidString.lowercased()
        let conversationIdentity = state.conversations
            .filter { $0.memberIdentity(for: userID) != nil }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .memberIdentity(for: userID)
        if let conversationIdentity, conversationIdentity.isValid {
            return conversationIdentity
        }
        let callIdentity = state.calls
            .filter { $0.participantIdentities?[userID] != nil }
            .max(by: { $0.startedAt < $1.startedAt })?
            .participantIdentities?[userID]
        guard callIdentity?.isValid == true else { return nil }
        return callIdentity
    }

    private func resumeAcceptedAccountDeletionCleanupBeforeRestore() async -> Bool {
        var deletionAttempt: PendingAccountDeletionAttempt?
        do {
            deletionAttempt = try await accountDeletionAttempts.pending()
        } catch {
            if error as? AccountDeletionPurgeMarkerError == .invalidMarker {
                await blockUnresolvedAccountDeletionAttempt()
            } else {
                await blockProtectedLocalStateRecovery()
            }
            return false
        }
        if let deletionAttempt {
            privacyQuarantineTargetAccountID = deletionAttempt.accountID
            clearAllCallWaitingState()
            NotificationCoordinator.shared.beginPrivacyQuarantine(
                targetAccountID: deletionAttempt.accountID
            )
        }

        let pending: PendingAcceptedAccountDeletion?
        let markerIsDurable: Bool
        do {
            if let stored = try await acceptedAccountDeletionPurges.pending() {
                pending = stored
                markerIsDurable = true
            } else if let volatileAcceptedAccountDeletion {
                pending = volatileAcceptedAccountDeletion
                do {
                    try await acceptedAccountDeletionPurges.schedule(
                        volatileAcceptedAccountDeletion
                    )
                    markerIsDurable = true
                } catch {
                    markerIsDurable = false
                }
            } else {
                pending = nil
                markerIsDurable = false
            }
        } catch {
            if error as? AccountDeletionPurgeMarkerError == .invalidMarker {
                await concealUnresolvedAcceptedAccountDeletionProjection()
                lastError =
                    "This device could not finish removing data for an accepted account deletion. "
                    + "Retry secure account-deletion cleanup before signing in again."
            } else {
                await blockProtectedLocalStateRecovery()
            }
            return false
        }

        if let pending {
            privacyQuarantineTargetAccountID = pending.accountID
            clearAllCallWaitingState()
            NotificationCoordinator.shared.beginPrivacyQuarantine(
                targetAccountID: pending.accountID
            )
            guard markerIsDurable else {
                await concealUnresolvedAcceptedAccountDeletionProjection()
                lastError =
                    "This device could not safely schedule accepted account-deletion cleanup. "
                    + "Retry secure account-deletion cleanup before signing in again."
                return false
            }
            guard LocalMediaPerformanceMonitor.shared.suspendRecordingAndClearReport() else {
                await concealUnresolvedAcceptedAccountDeletionProjection()
                acceptedAccountDeletionCleanupBlocked = true
                lastError =
                    "This device could not clear protected media diagnostics for the deleted account. "
                    + "Retry secure account-deletion cleanup before signing in again."
                isLoading = true
                return false
            }
        }

        switch await store.prepareForRestore() {
        case .ready:
            await store.resolveProtectedStateRecoveryConcealment()
            protectedLocalStateRecoveryBlocked = false
            protectedLocalStateRecoveryRequiresSupport = false
        case .temporarilyUnavailable:
            if pending != nil || acceptedAccountDeletionCleanupBlocked {
                await concealUnresolvedAcceptedAccountDeletionProjection()
                lastError =
                    "Unlock this device, then retry secure account-deletion cleanup."
            } else if deletionAttempt != nil {
                await blockUnresolvedAccountDeletionAttempt()
            } else {
                await blockProtectedLocalStateRecovery()
            }
            return false
        case .invalid:
            if pending != nil || acceptedAccountDeletionCleanupBlocked {
                await concealUnresolvedAcceptedAccountDeletionProjection()
                lastError =
                    "This device could not read protected data required to finish account deletion. "
                    + "Retry secure account-deletion cleanup before signing in again."
            } else if deletionAttempt != nil {
                await blockUnresolvedAccountDeletionAttempt()
            } else {
                await blockProtectedLocalStateRecovery(requiresSupport: true)
            }
            return false
        }

        guard let pending else {
            if let deletionAttempt {
                // Projection/session absence cannot prove that the irreversible request was
                // accepted. Only a durably verified accepted marker authorizes destructive
                // cleanup; an attempt-only launch therefore remains support-blocked.
                privacyQuarantineTargetAccountID = deletionAttempt.accountID
                await blockUnresolvedAccountDeletionAttempt()
                return false
            }
            if acceptedAccountDeletionCleanupBlocked {
                do {
                    guard try await store
                        .resolveAcceptedDeletionConcealmentAfterVerifiedEmptyState()
                    else {
                        await concealUnresolvedAcceptedAccountDeletionProjection()
                        lastError =
                            "This device is still finishing an accepted account deletion. "
                            + "No account data is available until local cleanup completes."
                        return false
                    }
                } catch {
                    await concealUnresolvedAcceptedAccountDeletionProjection()
                    lastError =
                        "This device could not finish removing data for an accepted account deletion. "
                        + "Retry secure account-deletion cleanup before signing in again."
                    return false
                }
            }
            acceptedAccountDeletionCleanupBlocked = false
            unresolvedAccountDeletionAttemptBlocked = false
            return true
        }

        if let deletionAttempt, !deletionAttempt.matches(pending) {
            privacyQuarantineTargetAccountID = nil
            await blockUnresolvedAccountDeletionAttempt()
            return false
        }

        await store.concealStateForUnresolvedAcceptedAccountDeletion()

        guard await finishAcceptedAccountDeletionLocalPurge(pending) else {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            acceptedAccountDeletionCleanupBlocked = true
            lastError =
                "This device is still finishing an accepted account deletion. "
                + "No account data is available until local cleanup completes."
            isLoading = true
            return false
        }
        let revokedMediaLease = callMediaAccountLease.flatMap { lease in
            lease.userID.caseInsensitiveCompare(pending.accountID) == .orderedSame
                ? lease
                : nil
        }
        if revokedMediaLease != nil {
            cancelOutgoingCallRingDeadline(lease: revokedMediaLease)
            callMediaAccountLease = nil
            await CallMediaCoordinator.shared.resetForSignOut(revoking: revokedMediaLease)
        }
        await pushRegistrations.reset(accountID: pending.accountID)
        do {
            _ = try await biometrics.removeEnrollmentForAcceptedAccountDeletion(
                userID: pending.accountID,
                installationID: installationID()
            )
        } catch {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            lastError =
                "This device is still finishing secure account-deletion cleanup. "
                + "Unlock it and retry before signing in again."
            return false
        }
        // Successful exact-target cleanup proves that no replacement session or projection owns
        // this process. Retire Apple delivery as a signed-out device so a deleted account cannot
        // keep producing generic PushKit calls after its durable markers are removed.
        NotificationCoordinator.shared.suspendRegistrationAfterSignOut()
        let targetFingerprint = MessageNotificationContract.accountFingerprint(
            for: pending.accountID
        )
        await NotificationCoordinator.shared.clearMessageNotifications(
            accountFingerprint: targetFingerprint
        )
        await retireClaimNotificationStateAtAccountBoundary()
        // Keep the accepted marker authoritative until the suspended diagnostics writer has
        // serialized a final clear. A relaunch can then safely repeat the whole exact-target purge.
        guard LocalMediaPerformanceMonitor.shared.clearReport() else {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            acceptedAccountDeletionCleanupBlocked = true
            lastError =
                "This device could not clear protected media diagnostics for the deleted account. "
                + "Retry secure account-deletion cleanup before signing in again."
            isLoading = true
            return false
        }
        // Retire the ambiguity fence first. If the process dies before the accepted marker is
        // removed, the accepted marker remains sufficient authority to repeat exact-target cleanup.
        if let deletionAttempt {
            do {
                guard try await accountDeletionAttempts.completeIfCurrent(deletionAttempt) else {
                    throw AccountDeletionPurgeMarkerError.conflictingMarker
                }
            } catch {
                await blockUnresolvedAccountDeletionAttempt()
                return false
            }
        }
        do {
            guard try await acceptedAccountDeletionPurges.completeIfCurrent(pending) else {
                throw AccountDeletionPurgeMarkerError.conflictingMarker
            }
        } catch {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            acceptedAccountDeletionCleanupBlocked = true
            lastError =
                "This device is still finishing an accepted account deletion. "
                + "No account data is available until local cleanup completes."
            isLoading = true
            return false
        }
        if volatileAcceptedAccountDeletion == pending {
            volatileAcceptedAccountDeletion = nil
        }
        if volatileAcceptedAccountDeletion != nil {
            return await resumeAcceptedAccountDeletionCleanupBeforeRestore()
        }
        privacyQuarantineTargetAccountID = nil
        unresolvedAccountDeletionAttemptBlocked = false
        acceptedAccountDeletionCleanupBlocked = false
        return true
    }

    /// The only sanctioned way to publish store state to the UI. Fetches the latest projection
    /// at the moment of assignment and refuses to publish anything older than what is already
    /// on screen, so concurrent tasks that suspended between "snapshot" and "assign" can never
    /// roll the visible chat list or conversation back to a stale projection.
    @discardableResult
    func publishLatestState() async -> PersistedState {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive { return state }
#endif
        let projection = await store.projection()
        guard projection.revision >= publishedStateRevision else { return state }
        publishedStateRevision = projection.revision
        var displayedState = appReviewDemoProjectedState(from: projection.state)
        displayedState.transactions =
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(
                displayedState.transactions,
                selectedWalletID: displayedState.selectedWalletId,
                wallets: displayedState.wallets
            )
        state = displayedState
        syncAvatarCacheAccount()
        publishSharedDestinationsIfPossible()
        recordStarterMessageMilestoneIfNeeded(from: projection.state)
        return displayedState
    }

    /// Persists the account-bound "first message actually sent" milestone the first time the
    /// durable store shows one, so later chat deletion or history pagination cannot resurrect
    /// the starter checklist. Reads the RAW store projection: App Review demo rows are injected
    /// only into the displayed copy and can never reach this write.
    private func recordStarterMessageMilestoneIfNeeded(from persisted: PersistedState) {
        guard persisted.starterFirstMessageAt == nil,
              persisted.profile != nil,
              !isRecordingStarterMessageMilestone,
              HomeStarterChecklistPolicy.hasSentFirstMessage(messages: persisted.messages)
        else { return }
        isRecordingStarterMessageMilestone = true
        Task { [weak self] in
            guard let self else { return }
            defer { isRecordingStarterMessageMilestone = false }
            try? await store.update { state in
                guard state.starterFirstMessageAt == nil,
                      HomeStarterChecklistPolicy.hasSentFirstMessage(messages: state.messages)
                else { return }
                state.starterFirstMessageAt = Date()
            }
            await publishLatestState()
        }
    }

    /// Confirms starter milestones from the optional server contract, which can only add: a
    /// server-completed milestone sets the same persisted account-bound marker a locally
    /// observed milestone sets, while a missing capability, a malformed or wrong-account
    /// payload, `eligible` false, a bad policy version, an unknown or duplicate key, an unknown
    /// status, and fetch failures all leave the honest device-local evidence in charge.
    /// `verify_identity` is validated as part of the payload but maps to nothing here — KYC
    /// keeps its own server-owned contract. A background confirmation signal on purpose — it
    /// never surfaces an error and never touches KYC or device state.
    private func confirmStarterMilestonesFromServerIfSupported(
        accountEpoch expectedAccountEpoch: UUID,
        sessionID expectedSessionID: String,
        userID expectedUserID: String
    ) async {
        guard capabilities?.supportsFeature(StarterMilestonesDTO.capabilityKey) == true,
              state.starterFirstMessageAt == nil || state.starterFirstTransactionAt == nil
        else { return }
        guard let checklist = try? await APIClientSessionBinding.$sessionID.withValue(
            expectedSessionID,
            operation: { try await api.starterMilestones() }
        ) else { return }
        // The payload has to speak for the signed-in account and be eligible before any key
        // counts; those checks live in the DTO so the contract test can hold them still.
        guard let confirmed = checklist.confirmedMilestoneKeys(forAccountID: expectedUserID),
              !confirmed.isEmpty,
              await callHistoryContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                sessionID: expectedSessionID,
                userID: expectedUserID
              )
        else { return }
        try? await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame
            else { throw StoreError.accountChanged }
            if confirmed.contains(StarterMilestonesDTO.sendFirstMessageMilestoneKey),
               persisted.starterFirstMessageAt == nil {
                persisted.starterFirstMessageAt = Date()
            }
            if confirmed.contains(StarterMilestonesDTO.makeFirstTransactionMilestoneKey),
               persisted.starterFirstTransactionAt == nil {
                persisted.starterFirstTransactionAt = Date()
            }
        }
        guard await callHistoryContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            sessionID: expectedSessionID,
            userID: expectedUserID
        ) else { return }
        await publishLatestState()
    }

    /// Points the profile-photo cache at whichever account is on screen.
    ///
    /// Cached faces are encrypted per account, so the cache has to learn the owner before any
    /// avatar loads — and has to forget it the moment the state stops carrying a profile, or the
    /// next person to sign in on this device would read the previous one's photos.
    private func syncAvatarCacheAccount() {
        // Sign-out publishes state once more before `isSignedIn` flips, so a plain `isSignedIn`
        // check here would hand the account back to the cache moments after it was purged.
        let signedInForDisplay = isSignedIn && !isSigningOut && !isSubmittingAccountDeletion
        let ownerID = signedInForDisplay ? profile?.id : nil
        // The first publish always tells the cache, even when the answer is "nobody": until it
        // hears that, the cache holds photo requests back waiting for an owner that would never
        // arrive on a signed-out launch.
        if !avatarCacheAccountSynced || ownerID != avatarCacheAccountID {
            avatarCacheAccountSynced = true
            avatarCacheAccountID = ownerID
            if ownerID == nil { warmedOwnAvatarURL = nil }
            Task { await ProfileAvatarCache.shared.setAccount(ownerID) }
        }
        guard signedInForDisplay else { return }
        warmOwnAvatar()
    }

    /// Pulls the account holder's own photo into the same encrypted cache every other face uses.
    ///
    /// Their photo would otherwise only be fetched by whichever screen happens to draw it, which
    /// on a cold launch is a race against the projection publishing an owner — the one avatar in
    /// the app that could end up re-downloaded every time instead of read from disk. Warming it
    /// here also covers the moment straight after they upload a new one.
    private func warmOwnAvatar() {
        guard let avatarURL = ProfileAvatarCache.validatedURL(profile?.avatarURL)?.absoluteString,
              avatarURL != warmedOwnAvatarURL
        else { return }
        warmedOwnAvatarURL = avatarURL
        Task { _ = await ProfileAvatarCache.shared.image(for: avatarURL) }
    }

    private func appReviewDemoProjectedState(from persisted: PersistedState) -> PersistedState {
        guard let ownerID = authenticatedAppReviewDemoOwnerID,
              isSignedIn,
              !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked
        else { return persisted }
        return AppReviewDemoContent.projectedState(
            from: persisted,
            authenticatedOwnerID: ownerID
        )
    }

    /// Keeps an unresolved accepted-deletion projection inaccessible without erasing a newer,
    /// conflicting owner's durable state. Recovery may reveal it only after the marker is safely
    /// resolved; every direct store snapshot remains empty in the meantime.
    private func concealUnresolvedAcceptedAccountDeletionProjection() async {
        activeConversationID = nil
        stopVisibleConversationSync()
        await store.concealStateForUnresolvedAcceptedAccountDeletion()
        await enterCommunicationPrivacyQuarantine()
        await publishLatestState()
        isSignedIn = false
        resetDeferredMessagingFeatures()
        acceptedAccountDeletionCleanupBlocked = true
        protectedLocalStateRecoveryBlocked = false
        protectedLocalStateRecoveryRequiresSupport = false
        unresolvedAccountDeletionAttemptBlocked = false
        isLoading = true
    }

    private func blockProtectedLocalStateRecovery(requiresSupport: Bool = false) async {
        activeConversationID = nil
        stopVisibleConversationSync()
        await store.concealStateForProtectedStateRecovery()
        await enterCommunicationPrivacyQuarantine()
        await publishLatestState()
        isSignedIn = false
        resetDeferredMessagingFeatures()
        protectedLocalStateRecoveryBlocked = true
        protectedLocalStateRecoveryRequiresSupport = requiresSupport
        unresolvedAccountDeletionAttemptBlocked = false
        isLoading = true
        lastError = nil
    }

    private func blockUnresolvedAccountDeletionAttempt() async {
        activeConversationID = nil
        stopVisibleConversationSync()
        await store.concealStateForUnresolvedAcceptedAccountDeletion()
        await enterCommunicationPrivacyQuarantine()
        await publishLatestState()
        isSignedIn = false
        resetDeferredMessagingFeatures()
        unresolvedAccountDeletionAttemptBlocked = true
        acceptedAccountDeletionCleanupBlocked = false
        protectedLocalStateRecoveryBlocked = false
        protectedLocalStateRecoveryRequiresSupport = false
        isLoading = true
        lastError = nil
    }

    private func enterCommunicationPrivacyQuarantine() async {
        authenticatedAppReviewDemoOwnerID = nil
        let targetAccountID = privacyQuarantineTargetAccountID
        if targetAccountID == nil
            || profile?.id.caseInsensitiveCompare(targetAccountID ?? "") == .orderedSame {
            resetTransientChatMediaForAccountBoundary()
        }
        clearAllCallWaitingState()
        NotificationCoordinator.shared.beginPrivacyQuarantine(
            targetAccountID: targetAccountID
        )
        if let targetAccountID,
           let targetLease = callMediaAccountLease,
           targetLease.userID.caseInsensitiveCompare(targetAccountID) == .orderedSame {
            cancelOutgoingCallRingDeadline(lease: targetLease)
            callMediaAccountLease = nil
            didResumeAuthenticatedSession = false
            await CallMediaCoordinator.shared.resetForSignOut(revoking: targetLease)
        }
        let targetFingerprint = MessageNotificationContract.accountFingerprint(
            for: targetAccountID
        )
        await NotificationCoordinator.shared.clearMessageNotifications(
            accountFingerprint: targetFingerprint
        )
        // Claim alerts have no owner digest, so selective retention cannot be proven while local
        // ownership is quarantined. Remove every visible claim alert; a tap already journaled by
        // the delegate remains durable unless this becomes a real account boundary.
        await NotificationCoordinator.shared.clearClaimablePaymentNotifications()
        callEventDrainTask?.cancel()
        callEventDrainTask = nil
        callSystemEventDrainTask?.cancel()
        callSystemEventDrainTask = nil
        for event in queuedCallEvents {
            NotificationCoordinator.shared.acknowledgeCallEvent(event.id)
        }
        for action in queuedCallSystemActions {
            NotificationCoordinator.shared.acknowledgeCallEvent(action.eventId)
        }
        queuedCallEvents.removeAll()
        queuedCallSystemActions.removeAll()
    }

    private func retireClaimNotificationStateAtAccountBoundary() async {
        await ClaimablePaymentNotificationActionDispatcher.shared.invalidateAllPendingActions()
        await NotificationCoordinator.shared.clearClaimablePaymentNotifications()
    }

    func retryProtectedLocalStateRecovery() async {
        guard protectedLocalStateRecoveryBlocked else { return }
        guard await resetProtectedCallRecoveryCycle(retiringQueuedEvents: false) else { return }
        await restore()
    }

    func retryAcceptedAccountDeletionCleanup() async {
        guard acceptedAccountDeletionCleanupBlocked else { return }
        lastError = nil
        isLoading = true
        guard await resumeAcceptedAccountDeletionCleanupBeforeRestore() else { return }
        guard await resetProtectedCallRecoveryCycle(retiringQueuedEvents: true) else { return }
        await restore()
    }

    @discardableResult
    private func resetProtectedCallRecoveryCycle(
        retiringQueuedEvents: Bool
    ) async -> Bool {
        guard protectedCallRecoveryResetSequence < UInt64.max else { return false }
        protectedCallRecoveryResetSequence += 1
        let resetSequence = protectedCallRecoveryResetSequence
        callEventDrainTask?.cancel()
        callEventDrainTask = nil
        callSystemEventDrainTask?.cancel()
        callSystemEventDrainTask = nil
        if retiringQueuedEvents {
            for event in queuedCallEvents {
                NotificationCoordinator.shared.acknowledgeCallEvent(event.id)
            }
            for action in queuedCallSystemActions {
                NotificationCoordinator.shared.acknowledgeCallEvent(action.eventId)
            }
            queuedCallEvents.removeAll()
            queuedCallSystemActions.removeAll()
        }
        let reset = await protectedCallRecoveryLatch.reset(requestSequence: resetSequence)
        guard protectedCallRecoveryResetSequence == resetSequence,
              reset.accepted
        else { return false }
        protectedCallRecoveryTicket = reset.ticket
        if !retiringQueuedEvents {
            if !queuedCallEvents.isEmpty { startCallEventDrainIfNeeded() }
            if !queuedCallSystemActions.isEmpty { startCallSystemEventDrainIfNeeded() }
        }
        return true
    }

    private func releaseProtectedCallRecovery(
        ticket: ProtectedCallRecoveryLatch.Ticket,
        lease: CallMediaAccountLease
    ) async -> Bool {
        guard protectedCallRecoveryTicket == ticket,
              callMediaAccountLease == lease,
              await outboxContextIsCurrent(
                  accountEpoch: lease.accountEpoch,
                  userID: lease.userID,
                  sessionID: lease.sessionID
              )
        else { return false }
        var readyTicket = ticket
        let existingCycleBecameReady = await protectedCallRecoveryLatch.resolve(
            .ready,
            for: readyTicket
        )
        if !existingCycleBecameReady {
            guard protectedCallRecoveryTicket == readyTicket,
                  callMediaAccountLease == lease,
                  await outboxContextIsCurrent(
                      accountEpoch: lease.accountEpoch,
                      userID: lease.userID,
                      sessionID: lease.sessionID
                  )
            else { return false }
            guard await resetProtectedCallRecoveryCycle(retiringQueuedEvents: false) else {
                return false
            }
            readyTicket = protectedCallRecoveryTicket
            guard await protectedCallRecoveryLatch.resolve(.ready, for: readyTicket) else {
                return false
            }
        }
        guard protectedCallRecoveryTicket == readyTicket,
              callMediaAccountLease == lease,
              await outboxContextIsCurrent(
                  accountEpoch: lease.accountEpoch,
                  userID: lease.userID,
                  sessionID: lease.sessionID
              )
        else { return false }
        if !queuedCallEvents.isEmpty { startCallEventDrainIfNeeded() }
        if !queuedCallSystemActions.isEmpty { startCallSystemEventDrainIfNeeded() }
        return true
    }

    /// Finishes one exact accepted-deletion target without touching a replacement account or a
    /// newer session. A durable marker is retired only after both protected state and the named
    /// Keychain credential generation are absent.
    private func finishAcceptedAccountDeletionLocalPurge(
        _ pending: PendingAcceptedAccountDeletion
    ) async -> Bool {
        let initialSessionDisposition: AcceptedAccountDeletionSessionDisposition
        do {
            initialSessionDisposition = try await sessions.acceptedDeletionDisposition(
                accountID: pending.accountID,
                sessionID: pending.sessionID
            )
        } catch {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            return false
        }
        guard initialSessionDisposition != .conflict else {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            return false
        }

        let projectionResult: AcceptedAccountDeletionProjectionPurgeResult
        do {
            projectionResult = try await store.purgeAcceptedAccountDeletion(
                accountID: pending.accountID
            )
        } catch {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            return false
        }
        guard projectionResult != .ownerConflict else {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            return false
        }

        if initialSessionDisposition == .exactTarget {
            do {
                guard try await sessions.clearAcceptedDeletionTarget(
                    accountID: pending.accountID,
                    sessionID: pending.sessionID
                ) == .cleared
                else {
                    await concealUnresolvedAcceptedAccountDeletionProjection()
                    return false
                }
            } catch {
                await concealUnresolvedAcceptedAccountDeletionProjection()
                return false
            }
        }
        do {
            guard try await sessions.acceptedDeletionDisposition(
                accountID: pending.accountID,
                sessionID: pending.sessionID
            ) == .alreadyAbsent
            else {
                await concealUnresolvedAcceptedAccountDeletionProjection()
                return false
            }
        } catch {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            return false
        }

        do {
            try await SecureMediaFileCache.shared.purge(forUserID: pending.accountID)
            try await ProfileAvatarCache.shared.purge(forUserID: pending.accountID)
            try MessageBackupKeyStore.removeKey(forUserID: pending.accountID)
            try SupportDraftStore.shared.purgeAccount(accountID: pending.accountID)
            try SupportPaymentStore.shared.purgeAccount(accountID: pending.accountID)
        } catch {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            return false
        }
        // Removing the synchronizable key is the cryptographic deletion boundary. CloudKit
        // record deletion is best-effort because an accepted account deletion must still finish
        // locally while iCloud is signed out or temporarily unavailable.
        Task {
            try? await MessageBackupManager.shared.deleteBackup(forUserID: pending.accountID)
        }

        return true
    }

    func restore() async {
        let recoveryLatch = protectedCallRecoveryLatch
        let recoveryTicket = protectedCallRecoveryTicket
        let recoveryAccountEpoch = accountEpoch
        var recoverySessionID: String?
        defer {
            let hasExactLease = recoverySessionID.map { expectedSessionID in
                callMediaAccountLease?.accountEpoch == recoveryAccountEpoch
                    && callMediaAccountLease?.sessionID.caseInsensitiveCompare(expectedSessionID)
                        == .orderedSame
            } ?? false
            let resolution: ProtectedCallRecoveryLatch.Resolution = hasExactLease
                ? .ready
                : .unavailable
            Task { await recoveryLatch.resolve(resolution, for: recoveryTicket) }
        }
        guard await resumeAcceptedAccountDeletionCleanupBeforeRestore() else { return }
        let restorationAccountEpoch = accountEpoch
        var restoredState = await store.snapshot()
        var migratedState = restoredState
        let ownerBeforeMigration = migratedState.communicationOwnerUserID
        if let restoredProfile = migratedState.profile {
            migratedState.bindAuthenticatedProfile(restoredProfile)
        }
        let ownerWasMigrated = migratedState.communicationOwnerUserID != ownerBeforeMigration
        let removedLegacyCallAttempts = OutboxPolicy.removeLegacyCallAttempts(
            in: &migratedState
        )
        let hardenedCustomerTransactions =
            CustomerTransactionPresentationPolicy.hardenCustomerTransactions(
                from: &migratedState.transactions
            )
        let originalTransferChatReceipts = migratedState.pendingTransferChatReceipts ?? []
        var hardenedTransferChatReceipts = originalTransferChatReceipts
        TransferChatReceiptRecoveryPolicy.sanitize(
            &hardenedTransferChatReceipts,
            ownerUserID: migratedState.communicationOwnerUserID ?? migratedState.profile?.id,
            now: Date()
        )
        migratedState.pendingTransferChatReceipts = hardenedTransferChatReceipts.isEmpty
            ? nil
            : hardenedTransferChatReceipts
        let originalPaymentRequestChatReceipts =
            migratedState.pendingPaymentRequestChatReceipts ?? []
        var hardenedPaymentRequestChatReceipts = originalPaymentRequestChatReceipts
        PaymentRequestChatReceiptRecoveryPolicy.sanitize(
            &hardenedPaymentRequestChatReceipts,
            ownerUserID: migratedState.communicationOwnerUserID ?? migratedState.profile?.id,
            now: Date()
        )
        migratedState.pendingPaymentRequestChatReceipts =
            hardenedPaymentRequestChatReceipts.isEmpty ? nil : hardenedPaymentRequestChatReceipts
        let originalPaymentRequestResolutionReceipts =
            migratedState.pendingPaymentRequestResolutionChatReceipts ?? []
        var hardenedPaymentRequestResolutionReceipts = originalPaymentRequestResolutionReceipts
        PaymentRequestResolutionChatReceiptRecoveryPolicy.sanitize(
            &hardenedPaymentRequestResolutionReceipts,
            ownerUserID: migratedState.communicationOwnerUserID ?? migratedState.profile?.id,
            now: Date()
        )
        migratedState.pendingPaymentRequestResolutionChatReceipts =
            hardenedPaymentRequestResolutionReceipts.isEmpty
                ? nil
                : hardenedPaymentRequestResolutionReceipts
        let originalGroupPaymentReceipts = migratedState.pendingGroupPaymentChatReceipts ?? []
        var hardenedGroupPaymentReceipts = originalGroupPaymentReceipts
        GroupPaymentChatReceiptRecoveryPolicy.sanitize(
            &hardenedGroupPaymentReceipts,
            ownerUserID: migratedState.communicationOwnerUserID ?? migratedState.profile?.id,
            now: Date()
        )
        migratedState.pendingGroupPaymentChatReceipts = hardenedGroupPaymentReceipts.isEmpty
            ? nil
            : hardenedGroupPaymentReceipts
        let originalGroupContributionReceipts =
            migratedState.pendingGroupContributionChatReceipts ?? []
        var hardenedGroupContributionReceipts = originalGroupContributionReceipts
        GroupContributionChatReceiptRecoveryPolicy.sanitize(
            &hardenedGroupContributionReceipts,
            ownerUserID: migratedState.communicationOwnerUserID ?? migratedState.profile?.id,
            now: Date()
        )
        migratedState.pendingGroupContributionChatReceipts =
            hardenedGroupContributionReceipts.isEmpty ? nil : hardenedGroupContributionReceipts
        let hardenedFinancialChatReceiptRecovery =
            hardenedTransferChatReceipts != originalTransferChatReceipts
                || hardenedPaymentRequestChatReceipts != originalPaymentRequestChatReceipts
                || hardenedPaymentRequestResolutionReceipts
                    != originalPaymentRequestResolutionReceipts
                || hardenedGroupPaymentReceipts != originalGroupPaymentReceipts
                || hardenedGroupContributionReceipts != originalGroupContributionReceipts
        let mediaRecoveryDate = Date()
        let recoveredLocalMediaRecords = migratedState.messages.indices.reduce(into: 0) {
            count, index in
            if LocalMediaRecordPolicy.migrateAndRecover(
                &migratedState.messages[index],
                now: mediaRecoveryDate
            ) {
                count += 1
            }
        }
        let inlineReceivedMediaCompaction: LegacyInlineReceivedMediaCompaction?
        if let restoredUserID = migratedState.profile?.id {
            let prepared = await LegacyInlineReceivedMediaCompactionPolicy.prepare(
                state: migratedState,
                forUserID: restoredUserID,
                cache: .shared,
                now: mediaRecoveryDate
            )
            migratedState = prepared.state
            inlineReceivedMediaCompaction = prepared
        } else {
            inlineReceivedMediaCompaction = nil
        }
        if OutboxPolicy.quarantineMessagesWithoutServerConversation(in: &migratedState) > 0
            || ownerWasMigrated
            || removedLegacyCallAttempts > 0
            || hardenedCustomerTransactions > 0
            || hardenedFinancialChatReceiptRecovery
            || recoveredLocalMediaRecords > 0
            || inlineReceivedMediaCompaction?.didPromote == true {
            do {
                try await store.replace(migratedState)
            } catch {
                // Never replace an unreadable protected-state file with an
                // empty projection merely to perform a legacy migration.
            }
            // Even if the best-effort rewrite fails, this process must never replay a legacy
            // durable call attempt. A later launch repeats the same fail-closed migration.
            restoredState = migratedState
        }
        // Cache originals stay eviction-leased through the complete state write. Once the store
        // owns their `.protectedFile` records (or the write has failed and the inline rows remain
        // authoritative), ordinary cache ownership and the age-gated orphan sweep take over.
        if let inlineReceivedMediaCompaction {
            await inlineReceivedMediaCompaction.releaseProtectedOriginalLeases(
                using: .shared
            )
        }
        // Queueing writes a protected original before committing its message/outbox row. A
        // process death in that narrow gap can therefore leave an orphan, but a concurrent or
        // just-created original must never be swept. Reconcile only files older than a full day,
        // cap work per activation, and retain every key reachable from the authoritative store.
        if let restoredUserID = restoredState.profile?.id {
            let authoritative = await store.snapshot()
            if authoritative.profile?.id == restoredUserID {
                let retainedKeys = Set(
                    authoritative.messages.flatMap(\.localMediaStorageKeys)
                ).union(
                    authoritative.conversationDrafts?.values
                        .flatMap(\.localMediaStorageKeys) ?? []
                )
                let retainedSpoolKeys = Set(
                    authoritative.messages.flatMap { message in
                        (message.localMediaRecords ?? []).compactMap { record in
                            record.ciphertextSpoolByteSize != nil
                                && record.ciphertextSpoolSHA256 != nil
                                ? record.id
                                : nil
                        }
                    }
                )
                _ = await SecureMediaFileCache.shared.removeUnreferenced(
                    retainingStorageKeys: retainedKeys,
                    retainingCiphertextSpoolKeys: retainedSpoolKeys,
                    forUserID: restoredUserID,
                    modifiedBefore: Date().addingTimeInterval(-24 * 60 * 60),
                    maximumRemovals: 64
                )
            }
        }
        var restoredSession = await sessions.current()
        recoverySessionID = restoredSession?.sessionId
        if let session = restoredSession, session.accountId == nil {
            let expectedProjection = await store.snapshot()
            let expectedProfileID = expectedProjection.profile?.id
            let expectedOwnerID = expectedProjection.communicationOwnerUserID
            // A cached profile cannot authenticate a legacy Keychain record: older app versions
            // could be interrupted between their independent session/profile writes. Resolve the
            // account with these exact credentials before binding or exposing any cached work.
            do {
                let bootstrap = try await APIClientSessionBinding.$sessionID.withValue(
                    session.sessionId
                ) {
                    try await api.bootstrap()
                }
                guard let boundSession = SessionAccountBindingPolicy.bindLegacySession(
                    session,
                    authenticatedProfile: bootstrap.user
                ),
                    try await sessions.replaceIfCurrent(session, with: boundSession)
                else { throw StoreError.accountChanged }

                let selectedID = WalletIdentityResolver.authoritativeSelectionID(
                    preferred: bootstrap.selectedWalletId,
                    in: bootstrap.wallets
                )
                guard await restoredSessionContextIsCurrent(
                    accountEpoch: restorationAccountEpoch,
                    session: boundSession
                ) else { throw StoreError.accountChanged }
                try await store.update { persisted in
                    guard SessionAccountBindingPolicy.restorationProjectionMatches(
                        persisted,
                        expectedProfileID: expectedProfileID,
                        expectedOwnerID: expectedOwnerID
                    ) else { throw StoreError.accountChanged }
                    persisted.bindAuthenticatedProfile(bootstrap.user)
                    persisted.sessionAssurance = bootstrap.resolvedSessionAssurance
                    persisted.replaceAuthoritativeWalletProjection(
                        bootstrap.wallets,
                        selectedWalletID: selectedID
                    )
                }
                guard await restoredSessionContextIsCurrent(
                    accountEpoch: restorationAccountEpoch,
                    session: boundSession
                ) else { throw StoreError.accountChanged }
                let authenticatedState = await store.snapshot()
                guard await restoredSessionContextIsCurrent(
                    accountEpoch: restorationAccountEpoch,
                    session: boundSession
                ) else { throw StoreError.accountChanged }
                restoredState = authenticatedState
                restoredSession = boundSession
            } catch {
                guard await retireFailedRestoredSession(
                    session,
                    accountEpoch: restorationAccountEpoch
                ) else { return }
                await retireClaimNotificationStateAtAccountBoundary()
                await publishLatestState()
                _ = await reloadCapabilities()
                lastError = "Your saved sign-in could not be verified safely. Sign in again."
                isLoading = false
                return
            }
        }

        if let session = restoredSession,
           !SessionAccountBindingPolicy.matches(session, profile: restoredState.profile) {
            let expectedProjection = await store.snapshot()
            let expectedProfileID = expectedProjection.profile?.id
            let expectedOwnerID = expectedProjection.communicationOwnerUserID
            // Authentication persists the account-bound Keychain record before the protected
            // profile file. If iOS terminates in that narrow window, rebuild only from an
            // authenticated bootstrap that proves the same account ID.
            do {
                guard let expectedAccountID = session.accountId else {
                    throw StoreError.accountChanged
                }
                let bootstrap = try await APIClientSessionBinding.$sessionID.withValue(
                    session.sessionId
                ) {
                    try await api.bootstrap()
                }
                let currentSession = await sessions.current()
                guard bootstrap.user.id.caseInsensitiveCompare(expectedAccountID) == .orderedSame,
                      let currentSession,
                      currentSession.sessionId.caseInsensitiveCompare(session.sessionId)
                        == .orderedSame,
                      currentSession.accountId?.caseInsensitiveCompare(expectedAccountID)
                        == .orderedSame
                else { throw StoreError.accountChanged }
                let selectedID = WalletIdentityResolver.authoritativeSelectionID(
                    preferred: bootstrap.selectedWalletId,
                    in: bootstrap.wallets
                )
                guard await restoredSessionContextIsCurrent(
                    accountEpoch: restorationAccountEpoch,
                    session: currentSession
                ) else { throw StoreError.accountChanged }
                try await store.update { persisted in
                    guard SessionAccountBindingPolicy.restorationProjectionMatches(
                        persisted,
                        expectedProfileID: expectedProfileID,
                        expectedOwnerID: expectedOwnerID
                    ) else { throw StoreError.accountChanged }
                    persisted.bindAuthenticatedProfile(bootstrap.user)
                    persisted.sessionAssurance = bootstrap.resolvedSessionAssurance
                    persisted.replaceAuthoritativeWalletProjection(
                        bootstrap.wallets,
                        selectedWalletID: selectedID
                    )
                }
                guard await restoredSessionContextIsCurrent(
                    accountEpoch: restorationAccountEpoch,
                    session: currentSession
                ) else { throw StoreError.accountChanged }
                let authenticatedState = await store.snapshot()
                guard await restoredSessionContextIsCurrent(
                    accountEpoch: restorationAccountEpoch,
                    session: currentSession
                ) else { throw StoreError.accountChanged }
                restoredState = authenticatedState
            } catch {
                guard await retireFailedRestoredSession(
                    session,
                    accountEpoch: restorationAccountEpoch
                ) else { return }
                await retireClaimNotificationStateAtAccountBoundary()
                await publishLatestState()
                _ = await reloadCapabilities()
                lastError = "Your saved sign-in could not be restored safely. Sign in again."
                isLoading = false
                return
            }
        }

        if let restoredSession {
            guard await restoredSessionContextIsCurrent(
                accountEpoch: restorationAccountEpoch,
                session: restoredSession
            ) else {
                await failRestoredSession(
                    restoredSession,
                    accountEpoch: restorationAccountEpoch,
                    message: "Your saved sign-in could not be restored safely. Sign in again."
                )
                return
            }
        } else {
            guard !Task.isCancelled,
                  !isSigningOut,
                  accountEpoch == restorationAccountEpoch
            else { return }
        }
        await publishLatestState()
        restoreCommunicationPrivacyCache()
        locallyTerminatedCallIds.formUnion(
            state.outbox.compactMap(OutboxPolicy.terminationReplay).map(\.callId)
        )
        rebuildCallContacts()
        // Nothing in a freshly launched process is hosting a call, so any record still claiming to
        // ring or be connected is left over from a crash and would otherwise block calling forever.
        await reapAbandonedCallRecords()
        if let restoredSession,
           let restoredUserID = restoredSession.accountId,
           SessionAccountBindingPolicy.matches(restoredSession, profile: state.profile) {
            let restorationContext = AuthenticatedSecurityContext(
                accountEpoch: restorationAccountEpoch,
                userID: restoredUserID,
                sessionID: restoredSession.sessionId
            )
            // Resolve the local gate before publishing a signed-in state. Otherwise RootView can
            // render cached account content during the Keychain/LocalAuthentication suspension.
            guard await loadBiometricConfiguration(
                context: restorationContext,
                requiresSignedIn: false
            ), await restoredSessionContextIsCurrent(
                accountEpoch: restorationAccountEpoch,
                session: restoredSession
            ) else {
                await failRestoredSession(
                    restoredSession,
                    accountEpoch: restorationAccountEpoch,
                    message: "Your saved sign-in could not be restored safely. Sign in again."
                )
                return
            }
            let cachedAssurance = restoredState.sessionAssurance
            sessionAssurance = cachedAssurance
            accountSetupStep = AccountSetupPolicy.restoredStep(
                user: state.profile,
                assurance: cachedAssurance
            )
            capabilities = nil
            authenticatedAppReviewDemoOwnerID = nil
            await api.setAppReviewDemoReadOnly(true, sessionID: restoredSession.sessionId)
            isSignedIn = true
            bindDeferredMessagingFeatures(to: MessagingDeferredFeatureScope(
                accountEpoch: restorationAccountEpoch,
                userID: restoredUserID,
                sessionID: restoredSession.sessionId
            ))
            do {
                let liveAssurance = try await APIClientSessionBinding.$sessionID.withValue(
                    restoredSession.sessionId
                ) {
                    try await api.sessionAssurance()
                }
                guard await authenticatedSecurityContextIsCurrent(restorationContext) else {
                    await failRestoredSession(
                        restoredSession,
                        accountEpoch: restorationAccountEpoch,
                        message: "Your saved sign-in could not be restored safely. Sign in again."
                    )
                    return
                }
                sessionAssurance = liveAssurance
                try? await store.update { persisted in
                    guard persisted.profile?.id.caseInsensitiveCompare(restoredUserID)
                            == .orderedSame,
                          persisted.communicationOwnerUserID?.caseInsensitiveCompare(
                            restoredUserID
                          ) == .orderedSame
                    else {
                        throw StoreError.accountChanged
                    }
                    persisted.sessionAssurance = liveAssurance
                }
                let updatedState = await store.snapshot()
                guard updatedState.profile?.id.caseInsensitiveCompare(restoredUserID)
                        == .orderedSame,
                      await authenticatedSecurityContextIsCurrent(restorationContext)
                else { return }
                await publishLatestState()
            } catch {
                guard await authenticatedSecurityContextIsCurrent(restorationContext) else {
                    await failRestoredSession(
                        restoredSession,
                        accountEpoch: restorationAccountEpoch,
                        message: "Your saved sign-in could not be restored safely. Sign in again."
                    )
                    return
                }
                // A previously server-confirmed, encrypted projection may be viewed offline on
                // this same installation. Live mutations still fail closed and reconnection
                // refreshes the session before draining the outbox.
                if let apiError = error as? APIClientError, case .signedOut = apiError {
                    sessionAssurance = nil
                } else {
                    sessionAssurance = cachedAssurance
                }
                accountSetupStep = AccountSetupPolicy.restoredStep(
                    user: state.profile,
                    assurance: sessionAssurance
                )
                if !communicationAccessGranted {
                    lastError = error.localizedDescription
                    isLoading = false
                    return
                }
            }
            guard await authenticatedSecurityContextIsCurrent(restorationContext) else { return }
            accountSetupStep = AccountSetupPolicy.restoredStep(
                user: state.profile,
                assurance: sessionAssurance
            )
            guard await reloadCapabilities() else {
                isLoading = false
                return
            }
            await prepareProtectedCallRecoveryIfPermitted(
                context: restorationContext,
                recoveryTicket: recoveryTicket
            )
            if accountSetupStep == nil, biometricUnlockEnabled {
                biometricAccessState = .locked
                homeBiometricState = .locked
                isLoading = false
                guard await authenticateBiometrically(for: .returningSignIn) else { return }
                guard await authenticatedSecurityContextIsCurrent(restorationContext) else {
                    return
                }
            }
            await resumeAuthenticatedSessionIfNeeded()
        } else if let restoredSession {
            await failRestoredSession(
                restoredSession,
                accountEpoch: restorationAccountEpoch,
                message: "Your saved sign-in could not be matched to its account. Sign in again."
            )
        } else {
            await retireClaimNotificationStateAtAccountBoundary()
            _ = await reloadCapabilities()
            isLoading = false
        }
    }

    private func restoredSessionContextIsCurrent(
        accountEpoch expectedAccountEpoch: UUID,
        session expectedSession: SessionTokens
    ) async -> Bool {
        guard !Task.isCancelled,
              !isSigningOut,
              accountEpoch == expectedAccountEpoch
        else { return false }
        guard let currentSession = await sessions.current() else { return false }
        return !Task.isCancelled
            && !isSigningOut
            && accountEpoch == expectedAccountEpoch
            && SessionAccountBindingPolicy.identifiesSameAccountSession(
                currentSession,
                expectedSession
            )
    }

    private func retireFailedRestoredSession(
        _ failedSession: SessionTokens,
        accountEpoch expectedAccountEpoch: UUID
    ) async -> Bool {
        guard !Task.isCancelled,
              !isSigningOut,
              accountEpoch == expectedAccountEpoch
        else { return false }
        if let currentSession = await sessions.current() {
            guard !Task.isCancelled,
                  !isSigningOut,
                  accountEpoch == expectedAccountEpoch,
                  SessionAccountBindingPolicy.sameServerSession(
                    currentSession,
                    failedSession
                  )
            else { return false }
            // `SessionStore.clear()` revokes its in-memory authority before removing the
            // Keychain records. A Keychain deletion error must not strand launch forever after
            // that revocation, but a replacement session must still survive this stale cleanup.
            _ = try? await sessions.clearIfCurrent(currentSession)
            guard !Task.isCancelled,
                  !isSigningOut,
                  accountEpoch == expectedAccountEpoch,
                  await sessions.current() == nil
            else { return false }
        }
        guard !Task.isCancelled,
              !isSigningOut,
              accountEpoch == expectedAccountEpoch,
              await sessions.current() == nil
        else { return false }
        try? await store.clearFinancialAndSessionProjections(
            preserveCommunicationHistory: true
        )
        let finalSession = await sessions.current()
        return !Task.isCancelled
            && !isSigningOut
            && accountEpoch == expectedAccountEpoch
            && finalSession == nil
    }

    private func failRestoredSession(
        _ failedSession: SessionTokens,
        accountEpoch expectedAccountEpoch: UUID,
        message: String
    ) async {
        guard await retireFailedRestoredSession(
            failedSession,
            accountEpoch: expectedAccountEpoch
        ) else { return }
        guard accountEpoch == expectedAccountEpoch, !isSigningOut else { return }
        activeConversationID = nil
        stopVisibleConversationSync()
        isSignedIn = false
        resetTransientChatMediaForAccountBoundary()
        await retireClaimNotificationStateAtAccountBoundary()
        resetDeferredMessagingFeatures()
        sessionAssurance = nil
        accountSetupStep = nil
        biometricUnlockEnabled = false
        biometricAccessState = .notRequired
        homeBiometricState = .notRequired
        locallyTerminatedCallIds.removeAll()
        pendingCallAnswers.removeAll()
        await publishLatestState()
        rebuildCallContacts()
        _ = await reloadCapabilities()
        lastError = message
        isLoading = false
    }

    func requestOTP(phone: String) async {
        guard !isSignedIn else {
            lastError = "Sign out before signing in with another phone number."
            return
        }
        guard phoneOTPAvailable else {
            lastError = "Phone sign-in is not available right now."
            return
        }
        guard !isLoading else { return }
        guard let normalized = UgandaMobileMoneyPhone.e164Value(from: phone) else {
            lastError = "Enter a valid Uganda mobile number."
            return
        }
        let attempt = beginAuthenticationRequest()
        defer { finishAuthenticationRequest(attempt) }
        do {
            let result = try await api.requestPhoneOTP(phone: normalized, device: deviceRegistration())
            guard authenticationAttempt == attempt else { return }
            let challenge = try requiredChallenge(from: result, type: "phone_otp")
            pendingPhone = normalized
            pendingChallenge = challenge
            pendingChallengeReceivedAt = Date()
        } catch {
            recordAuthenticationError(error, for: attempt)
        }
    }

    func verifyOTP(code: String) async {
        _ = await verifyAuthenticationCode(code)
    }

    @discardableResult
    func loginWithEmail(email: String, password: String) async -> Bool {
        guard !isSignedIn else {
            lastError = "Sign out before signing in with another account."
            return false
        }
        guard emailPasswordAvailable else {
            lastError = "Email sign-in is not available right now."
            return false
        }
        guard !isLoading else { return false }
        let normalizedEmail = EmailAccountValidation.normalizeEmail(email).lowercased()
        guard EmailAccountValidation.isValidEmail(normalizedEmail) else {
            lastError = "Enter a valid email address."
            return false
        }
        guard !password.isEmpty else {
            lastError = "Enter your password."
            return false
        }
        let attempt = beginAuthenticationRequest()
        defer { finishAuthenticationRequest(attempt) }
        do {
            let result = try await api.loginWithEmail(
                email: normalizedEmail,
                password: password,
                device: deviceRegistration()
            )
            guard authenticationAttempt == attempt else { return false }
            try await handleAuthenticationResult(
                result,
                allowingChallengeKind: .twoFactor,
                attempt: attempt
            )
            return true
        } catch {
            recordAuthenticationError(error, for: attempt)
            return false
        }
    }

    @discardableResult
    func verifyAuthenticationCode(_ code: String) async -> Bool {
        guard !isSignedIn else {
            lastError = "Sign out before signing in with another account."
            return false
        }
        guard !isLoading else { return false }
        guard let challenge = pendingChallenge else {
            lastError = "Request a new sign-in code."
            return false
        }
        guard !AuthenticationChallengeTimingPolicy.isExpired(challenge) else {
            clearPendingAuthentication()
            lastError = "This sign-in code has expired. Request a new one."
            return false
        }

        guard let challengeKind = challenge.kind else {
            resetPendingAuthentication()
            lastError = "Kit returned an unsupported sign-in challenge. Start again."
            return false
        }
        guard let submittedCode = AuthenticationCodePolicy.normalizedCode(code, for: challenge) else {
            lastError = challengeKind == .twoFactor
                && challenge.method?.caseInsensitiveCompare("totp") == .orderedSame
                ? "Enter a six-digit authenticator code or a complete recovery code."
                : "Enter the complete six-digit verification code."
            return false
        }
        switch challengeKind {
        case .phoneOTP:
            guard let phone = pendingPhone else {
                lastError = "Request a new code for your phone number."
                return false
            }
            let attempt = beginAuthenticationRequest(preservingChallenge: true)
            defer { finishAuthenticationRequest(attempt) }
            do {
                let result = try await api.verifyPhoneOTP(
                    challengeId: challenge.id,
                    phone: phone,
                    code: submittedCode,
                    device: deviceRegistration()
                )
                guard authenticationAttempt == attempt else { return false }
                try await handleAuthenticationResult(
                    result,
                    allowingChallengeKind: .twoFactor,
                    attempt: attempt
                )
                return true
            } catch {
                recordAuthenticationError(error, for: attempt)
                return false
            }
        case .twoFactor:
            let attempt = beginAuthenticationRequest(preservingChallenge: true)
            defer { finishAuthenticationRequest(attempt) }
            do {
                let result = try await api.verifyTwoFactor(
                    challengeId: challenge.id,
                    code: submittedCode
                )
                guard authenticationAttempt == attempt else { return false }
                try await handleAuthenticationResult(result, attempt: attempt)
                return true
            } catch {
                recordAuthenticationError(error, for: attempt)
                return false
            }
        }
    }

    func resetPendingAuthentication() {
        guard !isLoading else { return }
        authenticationAttempt = UUID()
        clearPendingAuthentication()
    }

    func pendingAuthenticationChallengeIsExpired(at date: Date = Date()) -> Bool {
        guard let pendingChallenge else { return false }
        return AuthenticationChallengeTimingPolicy.isExpired(pendingChallenge, at: date)
    }

    func pendingAuthenticationResendDelay(at date: Date = Date()) -> Int? {
        guard let pendingChallenge,
              let pendingChallengeReceivedAt
        else { return nil }
        return AuthenticationChallengeTimingPolicy.secondsUntilResend(
            for: pendingChallenge,
            receivedAt: pendingChallengeReceivedAt,
            now: date
        )
    }

    @discardableResult
    func resendPhoneAuthenticationCode() async -> Bool {
        guard !isSignedIn, !isLoading,
              let challenge = pendingChallenge,
              challenge.kind == .phoneOTP,
              let phone = pendingPhone,
              let receivedAt = pendingChallengeReceivedAt
        else { return false }
        guard !AuthenticationChallengeTimingPolicy.isExpired(challenge) else {
            clearPendingAuthentication()
            lastError = "This sign-in code has expired. Request a new one."
            return false
        }
        guard let resendDelay = AuthenticationChallengeTimingPolicy.secondsUntilResend(
            for: challenge,
            receivedAt: receivedAt
        ), resendDelay == 0 else { return false }

        let attempt = beginAuthenticationRequest(preservingChallenge: true)
        defer { finishAuthenticationRequest(attempt) }
        do {
            let result = try await api.requestPhoneOTP(
                phone: phone,
                device: deviceRegistration()
            )
            guard authenticationAttempt == attempt else { return false }
            let renewed = try requiredChallenge(from: result, type: "phone_otp")
            let receivedAt = Date()
            guard AuthenticationChallengeContractPolicy.acceptsPhoneRenewal(
                from: challenge,
                to: renewed,
                at: receivedAt
            ) else {
                clearPendingAuthentication()
                throw AuthUIError.invalidResponse
            }
            pendingChallenge = renewed
            pendingChallengeReceivedAt = receivedAt
            return true
        } catch {
            guard authenticationAttempt == attempt else { return false }
            if AuthenticationChallengeErrorPolicy.isTerminal(error) {
                clearPendingAuthentication()
                lastError = error.localizedDescription
            } else if AuthenticationChallengeRecoveryPolicy.preservesChallenge(
                afterResendFailure: error
            ) {
                // A structured client/rate-limit rejection proves that no replacement challenge
                // was issued. Keep the old code usable and preserve the server's retry guidance.
                lastError = error.localizedDescription
            } else {
                // A transport or server failure can occur after renewal. Keeping the old ID would
                // let a newly delivered code cross an ambiguous challenge boundary.
                clearPendingAuthentication()
                lastError = "We couldn't confirm the verification request. Start again and use the latest message."
            }
            return false
        }
    }

    private func clearPendingAuthentication() {
        pendingChallenge = nil
        pendingPhone = nil
        pendingChallengeReceivedAt = nil
    }

    func verifyEmail(token: String) async -> String? {
        guard !isSignedIn, !isLoading else { return nil }
        guard EmailAccountValidation.isValidOpaqueToken(token) else {
            lastError = "Paste the complete verification token from your email."
            return nil
        }
        let attempt = beginAuthenticationRequest()
        defer { finishAuthenticationRequest(attempt) }
        do {
            let result = try await api.verifyEmail(token: token)
            guard authenticationAttempt == attempt else { return nil }
            guard let verifiedEmail = EmailAccountResponsePolicy.verifiedEmail(from: result)
            else { throw AuthUIError.invalidResponse }
            return verifiedEmail
        } catch {
            recordAuthenticationError(error, for: attempt)
            return nil
        }
    }

    func requestPasswordReset(email: String) async -> String? {
        guard !isSignedIn else { return nil }
        guard emailRecoveryAvailable else {
            lastError = "Email password recovery is not available right now."
            return nil
        }
        guard !isLoading else { return nil }
        guard EmailAccountValidation.isValidEmail(email) else {
            lastError = "Enter a valid email address."
            return nil
        }
        let attempt = beginAuthenticationRequest()
        defer { finishAuthenticationRequest(attempt) }
        do {
            let result = try await api.requestPasswordReset(email: email)
            guard authenticationAttempt == attempt else { return nil }
            return result.message
                ?? "If an account exists for that address, password reset instructions will be sent."
        } catch {
            recordAuthenticationError(error, for: attempt)
            return nil
        }
    }

    func resetPassword(
        token: String,
        password: String,
        passwordConfirmation: String
    ) async -> PasswordResetSubmissionOutcome {
        guard !isSignedIn, !isLoading else { return .failed }
        if let validationError = EmailAccountValidation.passwordResetError(
            token: token,
            password: password,
            passwordConfirmation: passwordConfirmation
        ) {
            lastError = emailAccountValidationMessage(validationError, reset: true)
            return .failed
        }
        let attempt = beginAuthenticationRequest()
        defer { finishAuthenticationRequest(attempt) }
        do {
            let result = try await api.resetPassword(
                token: token,
                password: password,
                passwordConfirmation: passwordConfirmation
            )
            guard authenticationAttempt == attempt else { return .failed }
            guard result.passwordReset == true else { throw AuthUIError.invalidResponse }
            return .completed
        } catch {
            guard authenticationAttempt == attempt else { return .failed }
            if IrreversibleAuthenticationMutationPolicy.completionIsUncertain(after: error) {
                lastError = nil
                return .completionUncertain
            }
            recordAuthenticationError(error, for: attempt)
            return .failed
        }
    }

    private func beginAuthenticationRequest(preservingChallenge: Bool = false) -> UUID {
        let attempt = UUID()
        authenticationAttempt = attempt
        if !preservingChallenge {
            clearPendingAuthentication()
        }
        lastError = nil
        isLoading = true
        return attempt
    }

    private func finishAuthenticationRequest(_ attempt: UUID) {
        guard authenticationAttempt == attempt else { return }
        isLoading = false
    }

    private func recordAuthenticationError(_ error: Error, for attempt: UUID) {
        guard authenticationAttempt == attempt else { return }
        if AuthenticationChallengeErrorPolicy.isTerminal(error) {
            clearPendingAuthentication()
        }
        lastError = error.localizedDescription
    }

    private func requiredChallenge(from result: AuthResult, type: String) throws -> AuthChallenge {
        let expectedKind: AuthChallengeKind
        switch type.lowercased() {
        case "otp", "phone_otp": expectedKind = .phoneOTP
        case "two_factor": expectedKind = .twoFactor
        default: throw AuthUIError.invalidResponse
        }
        guard result.state.caseInsensitiveCompare("challenge_required") == .orderedSame,
              result.session == nil,
              result.user == nil,
              let challenge = result.challenge,
              AuthenticationChallengeContractPolicy.isValid(
                challenge,
                expectedKind: expectedKind
              )
        else { throw AuthUIError.invalidResponse }
        return challenge
    }

    private func handleAuthenticationResult(
        _ result: AuthResult,
        allowingChallengeKind: AuthChallengeKind? = nil,
        attempt: UUID
    ) async throws {
        switch AuthResultPolicy.disposition(for: result) {
        case .challengeRequired(let kind):
            guard kind == allowingChallengeKind,
                  let challenge = result.challenge,
                  AuthenticationChallengeContractPolicy.isValid(
                    challenge,
                    expectedKind: kind
                  )
            else { throw AuthUIError.invalidResponse }
            guard authenticationAttempt == attempt else { return }
            pendingPhone = nil
            pendingChallenge = challenge
            pendingChallengeReceivedAt = Date()
        case .authenticated:
            try await adoptAuthenticatedResult(result, attempt: attempt)
        case .invalid:
            throw AuthUIError.invalidResponse
        }
    }

    private func adoptAuthenticatedResult(_ result: AuthResult, attempt: UUID) async throws {
        guard result.state.caseInsensitiveCompare("authenticated") == .orderedSame,
              result.challenge == nil,
              let session = result.session,
              let user = result.user,
              let boundSession = session.bound(to: user.id)
        else { throw AuthUIError.invalidResponse }
        guard authenticationAttempt == attempt else { return }
        guard LocalMediaPerformanceMonitor.shared.suspendRecordingAndClearReport() else {
            throw AuthUIError.localDiagnosticsCleanupFailed
        }
        do {
            guard try await sessions.saveIfEmpty(boundSession) else {
                throw AuthUIError.staleResponse
            }
            // Retire the previous credential lifetime before the new profile can be exposed.
            // A parked capability grant either commits before this atomic withdrawal and is
            // cleared, or reaches the store afterwards with an obsolete opaque ticket.
            try await store.retireMessagingOfflineDirectCreationCapabilityContext(
                clearingPersistedReceipt: true
            )
            // Persisting the authenticated session creates the first possible write authority.
            // Fence it before any subsequent suspension; only a successful authenticated
            // non-demo capability response may release the fence.
            await api.setAppReviewDemoReadOnly(true, sessionID: boundSession.sessionId)
            try await store.update { persisted in
                persisted.bindAuthenticatedProfile(user)
                persisted.sessionAssurance = result.sessionAssurance
            }
        } catch {
            _ = try? await sessions.clearIfCurrent(boundSession)
            throw error
        }
        guard authenticationAttempt == attempt else {
            _ = try? await sessions.clearIfCurrent(boundSession)
            throw AuthUIError.staleResponse
        }
        cancelEphemeralOutgoingCall(dismissPresentation: true)
        cancelOutgoingCallRingDeadline()
        clearAllCallWaitingState()
        activeConversationID = nil
        stopVisibleConversationSync()
        resetForegroundAuthoritativeRefresh()
        cancelWalletHistoryRefresh()
        pendingDeepLink = nil
        resetTransientChatMediaForAccountBoundary()
        accountEpoch = UUID()
        resetDeferredMessagingFeatures()
        guard await resetProtectedCallRecoveryCycle(retiringQueuedEvents: true) else {
            throw AuthUIError.staleResponse
        }
        resetCommunicationPrivacyState()
        resetSecurityPreferencesState()
        secureMessagingSyncError.reset()
        kycRequestGeneration &+= 1
        kycStatus = nil
        capabilities = nil
        authenticatedAppReviewDemoOwnerID = nil
        sessionAssurance = result.sessionAssurance
        contactDirectoryRevision &+= 1
        await publishLatestState()
        isSignedIn = true
        LocalMediaPerformanceMonitor.shared.resumeRecordingForFreshAccount()
        bindDeferredMessagingFeatures(to: MessagingDeferredFeatureScope(
            accountEpoch: accountEpoch,
            userID: user.id,
            sessionID: boundSession.sessionId
        ))
        let authenticatedContext = AuthenticatedSecurityContext(
            accountEpoch: accountEpoch,
            userID: user.id,
            sessionID: boundSession.sessionId
        )
        accountSetupStep = AccountSetupPolicy.initialStep(
            afterAuthentication: user,
            assurance: nil
        )
        didResumeAuthenticatedSession = false
        pendingChallenge = nil
        pendingPhone = nil
        pendingChallengeReceivedAt = nil
        guard await loadBiometricConfiguration(context: authenticatedContext),
              authenticationAttempt == attempt,
              await authenticatedSecurityContextIsCurrent(authenticatedContext)
        else { return }
        if sessionAssurance == nil {
            let assurance = try await APIClientSessionBinding.$sessionID.withValue(
                boundSession.sessionId
            ) {
                try await api.sessionAssurance()
            }
            guard authenticationAttempt == attempt,
                  await authenticatedSecurityContextIsCurrent(authenticatedContext)
            else { return }
            sessionAssurance = assurance
        }
        accountSetupStep = AccountSetupPolicy.initialStep(
            afterAuthentication: user,
            assurance: sessionAssurance
        )
        guard await reloadCapabilities(),
              authenticationAttempt == attempt,
              await authenticatedSecurityContextIsCurrent(authenticatedContext)
        else { return }
        biometricAccessState = accountSetupStep == nil && biometricUnlockEnabled
            ? .locked
            : .authorized
        homeBiometricState = biometricUnlockEnabled ? .locked : .notRequired
        if accountSetupStep == nil, biometricUnlockEnabled {
            guard await authenticateBiometrically(for: .returningSignIn) else { return }
            guard authenticationAttempt == attempt,
                  await authenticatedSecurityContextIsCurrent(authenticatedContext)
            else { return }
        }
        await resumeAuthenticatedSessionIfNeeded()
    }

    func loadAccountDeletionPreflight() async throws -> AccountDeletionPreflightDTO {
        guard accountDeletionSubmissionID == nil else {
            throw AccountDeletionSubmissionError.operationInProgress
        }
        let context = try await captureAccountDeletionContext()
        let response = try await APIClientSessionBinding.$sessionID.withValue(
            context.sessionID
        ) {
            try await api.accountDeletionPreflight()
        }
        guard accountDeletionSubmissionID == nil,
              await authenticatedSecurityContextIsCurrent(context),
              AccountDeletionContract.canonicalAccountID(context.userID) == response.accountID
        else { throw AccountDeletionSubmissionError.accountChanged }
        return response
    }

    /// Submits the irreversible request and erases local communication history only after a
    /// strict, authenticated `accepted`/`deletion_pending` receipt for this exact account session.
    func submitAccountDeletion(
        preflight: AccountDeletionPreflightDTO,
        confirmation: String,
        pin: String
    ) async throws -> AccountDeletionReceiptDTO {
        guard appReviewDemoMutationsAllowed else {
            throw AppReviewDemoMutationError.readOnly
        }
        guard confirmation == AccountDeletionContract.confirmation,
              confirmation == preflight.confirmationText
        else { throw AccountDeletionContractError.invalidConfirmation }
        if !AccountDeletionContract.validPIN(pin) {
            throw AccountDeletionContractError.invalidPIN
        }

        let context = try await captureAccountDeletionContext()
        let operationID = try beginAccountDeletionSubmission(
            targetAccountID: context.userID
        )
        defer { finishAccountDeletionSubmission(operationID) }
        guard AccountDeletionContract.canonicalAccountID(context.userID) == preflight.accountID,
              preflight.purpose == AccountDeletionContract.purpose
        else { throw AccountDeletionContractError.invalidPreflight }

        let approval = try await authorizeFinancialStepUp(
            purpose: preflight.purpose,
            intent: preflight.intent,
            pin: pin,
            reason: "Approve permanent Kit Pay account deletion"
        )
        guard await accountDeletionOperationIsCurrent(operationID, context: context) else {
            throw AccountDeletionSubmissionError.accountChanged
        }
        guard AccountDeletionContract.validStepUpToken(approval.stepUpToken) else {
            throw AccountDeletionContractError.invalidStepUp
        }

        let deletionAttempt: PendingAccountDeletionAttempt
        do {
            deletionAttempt = try PendingAccountDeletionAttempt(
                accountID: context.userID,
                sessionID: context.sessionID,
                attemptID: UUID().uuidString
            )
            try await accountDeletionAttempts.schedule(deletionAttempt)
        } catch {
            throw AccountDeletionSubmissionError.unavailable
        }
        privacyQuarantineTargetAccountID = deletionAttempt.accountID
        await enterCommunicationPrivacyQuarantine()
        guard await accountDeletionOperationIsCurrent(operationID, context: context) else {
            do {
                guard try await accountDeletionAttempts.completeIfCurrent(deletionAttempt)
                else { throw AccountDeletionPurgeMarkerError.persistenceVerificationFailed }
            } catch {
                await blockUnresolvedAccountDeletionAttempt()
                throw AccountDeletionSubmissionError.completionUncertain
            }
            throw AccountDeletionSubmissionError.accountChanged
        }

        let receipt: AccountDeletionReceiptDTO
        do {
            receipt = try await APIClientSessionBinding.$sessionID.withValue(
                context.sessionID
            ) {
                try await api.requestAccountDeletion(
                    preflight: preflight,
                    confirmation: confirmation,
                    stepUpToken: approval.stepUpToken
                )
            }
        } catch {
            if IrreversibleAuthenticationMutationPolicy.completionIsUncertain(after: error) {
                await blockUnresolvedAccountDeletionAttempt()
                throw AccountDeletionSubmissionError.completionUncertain
            }
            do {
                guard try await accountDeletionAttempts.completeIfCurrent(deletionAttempt)
                else {
                    await blockUnresolvedAccountDeletionAttempt()
                    throw AccountDeletionSubmissionError.completionUncertain
                }
            } catch let submissionError as AccountDeletionSubmissionError {
                throw submissionError
            } catch {
                await blockUnresolvedAccountDeletionAttempt()
                throw AccountDeletionSubmissionError.completionUncertain
            }
            await resumeCommunicationAfterDefiniteAccountDeletionFailure(
                context: context,
                operationID: operationID
            )
            throw error
        }

        guard receipt.state == AccountDeletionContract.acceptedState,
              receipt.accountStatus == AccountDeletionContract.pendingAccountStatus
        else {
            await blockUnresolvedAccountDeletionAttempt()
            throw AccountDeletionSubmissionError.completionUncertain
        }

        let pendingDeletion: PendingAcceptedAccountDeletion
        do {
            pendingDeletion = try PendingAcceptedAccountDeletion(
                accountID: context.userID,
                sessionID: context.sessionID,
                receiptID: receipt.receiptID
            )
        } catch {
            await concealUnresolvedAcceptedAccountDeletionProjection()
            acceptedAccountDeletionCleanupBlocked = true
            isLoading = true
            throw AccountDeletionSubmissionError.acceptedButLocalCleanupFailed
        }

        let markerIsDurable: Bool
        do {
            try await acceptedAccountDeletionPurges.schedule(pendingDeletion)
            markerIsDurable = true
            if volatileAcceptedAccountDeletion == pendingDeletion {
                volatileAcceptedAccountDeletion = nil
            }
        } catch {
            // The receipt is irreversible, but projection/session absence alone cannot recreate
            // that proof after a crash. Never start destructive cleanup until the accepted marker
            // has been written and read back successfully.
            markerIsDurable = false
            volatileAcceptedAccountDeletion = pendingDeletion
        }

        guard markerIsDurable else {
            privacyQuarantineTargetAccountID = pendingDeletion.accountID
            await concealUnresolvedAcceptedAccountDeletionProjection()
            acceptedAccountDeletionCleanupBlocked = true
            isLoading = true
            throw AccountDeletionSubmissionError.acceptedButLocalCleanupFailed
        }

        // Receipt acceptance is irreversible. Ignore view-task cancellation from this point, but
        // never erase a replacement account that won the session slot while the POST was in flight.
        guard await accountDeletionContextStillOwnsSession(
            context,
            operationID: operationID
        ) else {
            // A replacement session/account now owns the app. The durable marker is the only
            // authority allowed to retry on launch after proving that replacement is absent; do
            // not perform any destructive cleanup from this stale completion.
            await concealUnresolvedAcceptedAccountDeletionProjection()
            acceptedAccountDeletionCleanupBlocked = true
            isLoading = true
            throw markerIsDurable
                ? AccountDeletionSubmissionError.acceptedForPreviousSession
                : AccountDeletionSubmissionError.acceptedButLocalCleanupFailed
        }

        let signOutResult = await performSignOut(
            removeBiometricCredential: true,
            dataPolicy: .acceptedAccountDeletion,
            expectedContext: context,
            acceptedDeletion: pendingDeletion,
            acceptedDeletionMarkerIsDurable: markerIsDurable,
            acceptedDeletionAttempt: deletionAttempt
        )
        switch signOutResult {
        case .completed:
            return receipt
        case .contextChanged:
            await concealUnresolvedAcceptedAccountDeletionProjection()
            acceptedAccountDeletionCleanupBlocked = true
            isLoading = true
            throw AccountDeletionSubmissionError.acceptedForPreviousSession
        case .localCleanupFailed:
            await concealUnresolvedAcceptedAccountDeletionProjection()
            acceptedAccountDeletionCleanupBlocked = true
            isLoading = true
            throw AccountDeletionSubmissionError.acceptedButLocalCleanupFailed
        }
    }

    private func captureAccountDeletionContext() async throws
        -> AuthenticatedSecurityContext {
        guard isOnline,
              AccountDeletionContract.protectedFlowAvailable(
                features: capabilities?.features
              ),
              !isSigningOut,
              isSignedIn,
              !isUpdatingProfile,
              profileEmailOperation == nil,
              accountSetupStep == nil,
              !requiresBiometricSignIn,
              sessionAssurance?.grantsFullAccess == true,
              let profile,
              AccountDeletionContract.canonicalAccountID(profile.id) != nil,
              let session = await sessions.current(),
              session.accountId?.caseInsensitiveCompare(profile.id) == .orderedSame
        else { throw AccountDeletionSubmissionError.unavailable }
        let context = AuthenticatedSecurityContext(
            accountEpoch: accountEpoch,
            userID: profile.id,
            sessionID: session.sessionId
        )
        guard await authenticatedSecurityContextIsCurrent(context) else {
            throw AccountDeletionSubmissionError.accountChanged
        }
        return context
    }

    private func beginAccountDeletionSubmission(targetAccountID: String) throws -> UUID {
        guard accountDeletionSubmissionID == nil,
              !isSubmittingAccountDeletion,
              flushingAccountEpoch == nil
        else {
            throw AccountDeletionSubmissionError.operationInProgress
        }
        let operationID = UUID()
        accountDeletionSubmissionID = operationID
        isSubmittingAccountDeletion = true
        privacyQuarantineTargetAccountID = targetAccountID
        clearAllCallWaitingState()
        NotificationCoordinator.shared.beginPrivacyQuarantine(
            targetAccountID: targetAccountID
        )
        return operationID
    }

    private func finishAccountDeletionSubmission(_ operationID: UUID) {
        guard accountDeletionSubmissionID == operationID else { return }
        accountDeletionSubmissionID = nil
        isSubmittingAccountDeletion = false
        if let invalidatedSessionID = deferredInvalidatedSessionID {
            deferredInvalidatedSessionID = nil
            Task { @MainActor [weak self] in
                await self?.handleSessionInvalidation(invalidatedSessionID)
            }
        } else {
            Task { @MainActor [weak self] in
                await self?.resumeAuthenticatedSessionIfNeeded()
            }
        }
    }

    private func handleSessionInvalidation(_ invalidatedSessionID: String) async {
        guard isSignedIn else { return }
        if isSubmittingAccountDeletion {
            deferredInvalidatedSessionID = invalidatedSessionID
            return
        }
        guard !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked
        else { return }
        let currentSessionID = await sessions.current()?.sessionId
        let invalidatesCurrentSession = SessionRefreshPolicy.shouldApplyInvalidation(
            invalidatedSessionID: invalidatedSessionID,
            currentSessionID: currentSessionID
        ) || (currentSessionID == nil
            && callMediaAccountLease?.sessionID.caseInsensitiveCompare(invalidatedSessionID)
                == .orderedSame)
        guard invalidatesCurrentSession else { return }
        await signOut(removeBiometricCredential: false)
        guard !isSignedIn,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked
        else { return }
        lastError = "Your Kit Pay session expired. Sign in again to continue."
    }

    private func resumeCommunicationAfterDefiniteAccountDeletionFailure(
        context: AuthenticatedSecurityContext,
        operationID: UUID
    ) async {
        guard await accountDeletionOperationIsCurrent(operationID, context: context) else {
            return
        }
        do {
            guard try await accountDeletionAttempts.pending() == nil else { return }
        } catch {
            return
        }
        privacyQuarantineTargetAccountID = nil
        NotificationCoordinator.shared.resumeRegistration(
            afterOwnershipRecoveryFor: context.userID
        )
    }

    private func accountDeletionOperationIsCurrent(
        _ operationID: UUID,
        context: AuthenticatedSecurityContext
    ) async -> Bool {
        guard accountDeletionSubmissionID == operationID,
              isSubmittingAccountDeletion,
              AccountDeletionContract.protectedFlowAvailable(
                features: capabilities?.features
              )
        else { return false }
        return await authenticatedSecurityContextIsCurrent(context)
    }

    /// Unlike ordinary mutation fences, a confirmed irreversible receipt must finish cleanup even
    /// if SwiftUI cancels the initiating task. This check deliberately ignores task cancellation.
    private func accountDeletionContextStillOwnsSession(
        _ context: AuthenticatedSecurityContext,
        operationID: UUID
    ) async -> Bool {
        guard accountDeletionSubmissionID == operationID,
              isSubmittingAccountDeletion,
              !isSigningOut,
              isSignedIn,
              accountEpoch == context.accountEpoch,
              profile?.id.caseInsensitiveCompare(context.userID) == .orderedSame,
              let currentSession = await sessions.current()
        else { return false }
        return !isSigningOut
            && isSignedIn
            && accountEpoch == context.accountEpoch
            && currentSession.sessionId.caseInsensitiveCompare(context.sessionID) == .orderedSame
            && currentSession.accountId?.caseInsensitiveCompare(context.userID) == .orderedSame
    }

    func signOut(removeBiometricCredential: Bool = true) async {
        _ = await performSignOut(
            removeBiometricCredential: removeBiometricCredential,
            dataPolicy: .ordinaryLogout,
            expectedContext: nil
        )
    }

    /// Accepts an inbound `kitwallet://` link.
    ///
    /// Both routes complete a pre-authentication flow, so a link that arrives while somebody is
    /// already signed in is dropped rather than queued: acting on it later would drag a signed-in
    /// customer to a sign-out-shaped screen for a token that is no longer theirs. Nothing is
    /// submitted here — the link only chooses a screen and fills the field.
    func handleDeepLink(_ url: URL) {
        guard let link = KitDeepLink.parse(url) else { return }
        guard !isSignedIn,
              !requiresBiometricSignIn,
              !acceptedAccountDeletionCleanupBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              !protectedLocalStateRecoveryBlocked
        else { return }
        pendingDeepLink = link
    }

    /// Called by the screen that has applied the link.
    func consumeDeepLink(_ link: KitDeepLink) {
        guard pendingDeepLink == link else { return }
        pendingDeepLink = nil
    }

    // MARK: Sharing into Kit Pay

    /// Whether a share from another app can be offered a destination right now.
    ///
    /// Everything the share extension stages belongs to whoever was signed in when they shared it.
    /// A locked, half-set-up, or signing-out app has no chat to put it in and no business showing a
    /// list of chats, so the batch simply waits — or, on sign-out, is destroyed.
    private var canDeliverSharedContent: Bool {
        isSignedIn
            && accountSetupStep == nil
            && !requiresBiometricSignIn
            && !isSigningOut
            && !isSubmittingAccountDeletion
            && !acceptedAccountDeletionCleanupBlocked
            && !unresolvedAccountDeletionAttemptBlocked
            && !protectedLocalStateRecoveryBlocked
    }

    /// Gives the extension a small, account-bound address book it can render while this process is
    /// suspended. It contains five recent chats followed by other eligible Kit Pay contacts and
    /// groups. The extension receives no phone numbers, group roster, messages, credentials, or
    /// key material; every opaque route UUID is revalidated here when the app becomes active.
    private func publishSharedDestinationsIfPossible() {
        guard canDeliverSharedContent,
              appReviewDemoMutationsAllowed,
              secureMessagingAvailable,
              hasUsableCommunicationPrivacyProjection,
              let rawAccountID = profile?.id,
              let accountID = SharedInboxPolicy.canonicalAccountID(rawAccountID),
              SharedInboxStore.shared.setActiveAccountID(accountID)
        else {
            // Recipient names are convenience data, not an entitlement to bypass the app's lock.
            // Keep the opaque account binding so a share can still wait safely, but expose no
            // directory while biometric/setup/privacy gates are closed.
            SharedInboxStore.shared.clearDestinations()
            return
        }

        let currentUserID = profile?.id
        let directory = contactDirectory
        let recentCandidates = state.conversations.compactMap {
            conversation -> (destination: SharedInboxDestination, updatedAt: Date)? in
                guard !isReadOnlyAppReviewDemoConversation(conversation.id),
                      let conversationID = SharedInboxPolicy.canonicalConversationID(
                          conversation.id
                      )
                else { return nil }
                let identity = ConversationContactPresentationPolicy.presentation(
                    for: conversation,
                    currentUserID: currentUserID,
                    contacts: directory
                )
                guard let displayName = SharedInboxPolicy.destinationDisplayName(
                    identity.displayName
                ) else { return nil }

                if conversation.isGroup {
                    guard messagingGroupLocalQueueEnabled else { return nil }
                    let memberIDs = conversation.participantUserIds.compactMap {
                        SharedInboxPolicy.canonicalAccountID($0)
                    }
                    guard memberIDs.count == conversation.participantUserIds.count,
                          Set(memberIDs).count == memberIDs.count,
                          memberIDs.count >= 2,
                          memberIDs.contains(accountID)
                    else { return nil }
                    return (SharedInboxDestination(
                        conversationID: conversationID,
                        recipientUserID: nil,
                        displayName: displayName,
                        kind: .group,
                        memberCount: memberIDs.count,
                        avatarURL: SharedInboxPolicy.destinationAvatarURL(
                            conversation.groupPhotoURL
                        )
                    ), conversation.updatedAt)
                }

                guard let rawRecipientUserID = identity.recipientUserID,
                      let recipientUserID = SharedInboxPolicy.canonicalAccountID(
                          rawRecipientUserID
                      ),
                      communicationPrivacyAllowsOutbound(to: recipientUserID),
                      !isCommunicationBlocked(userID: recipientUserID)
                else { return nil }
                return (SharedInboxDestination(
                    conversationID: conversationID,
                    recipientUserID: recipientUserID,
                    displayName: displayName,
                    kind: .direct,
                    memberCount: nil,
                    avatarURL: SharedInboxPolicy.destinationAvatarURL(identity.avatarURL)
                ), conversation.updatedAt)
            }
        let contactDestinations = ContactRecipientDirectory
            .ordered(communicationContactDirectory, context: phoneIdentityContext)
            .compactMap { contact -> SharedInboxDestination? in
                guard let rawRecipientUserID = ContactRecipientDirectory.recipientUserId(for: contact),
                      let recipientUserID = SharedInboxPolicy.canonicalAccountID(
                          rawRecipientUserID
                      ),
                      recipientUserID.caseInsensitiveCompare(accountID) != .orderedSame,
                      communicationPrivacyAllowsOutbound(to: recipientUserID),
                      !isCommunicationBlocked(userID: recipientUserID),
                      let displayName = SharedInboxPolicy.destinationDisplayName(contact.name)
                else { return nil }
                return SharedInboxDestination(
                    conversationID: nil,
                    recipientUserID: recipientUserID,
                    displayName: displayName,
                    kind: .contact,
                    memberCount: nil,
                    avatarURL: SharedInboxPolicy.destinationAvatarURL(contact.avatarURL)
                )
            }
        let destinations = SharedInboxPolicy.orderedDestinations(
            recentCandidates: recentCandidates,
            contacts: contactDestinations
        )
        guard SharedInboxStore.shared.setDestinations(
            destinations,
            forAccountID: accountID
        ) else {
            SharedInboxStore.shared.clearDestinations()
            return
        }
    }

    /// Looks for anything the share sheet left in the app group container. Called on launch and on
    /// every return to the foreground; a share extension cannot open its containing app itself.
    ///
    /// Oldest batch first: someone who shared twice before switching apps gets both, in the order
    /// they shared them, rather than one silently displacing the other.
    func refreshSharedInbox() {
        guard canDeliverSharedContent else {
            SharedInboxStore.shared.clearDestinations()
            return
        }
        guard appReviewDemoMutationsAllowed else {
            // The read-only review account cannot send anything, so a staged share would sit in
            // front of a picker that refuses every choice.
            SharedInboxStore.shared.removeAll()
            SharedInboxStore.shared.clearActiveAccount()
            return
        }
        guard let accountID = profile?.id,
              SharedInboxStore.shared.setActiveAccountID(accountID)
        else { return }
        publishSharedDestinationsIfPossible()
        let now = Date()
        if let delivery = sharedInboxDelivery,
           SharedInboxPolicy.isExpired(receivedAt: delivery.batch.receivedAt, now: now) {
            sharedInboxDelivery = nil
            sharedInboxProvisionalConversation = nil
            SharedInboxStore.shared.remove(batchID: delivery.batch.id)
        }
        if let batch = pendingSharedInboxBatch,
           SharedInboxPolicy.isExpired(receivedAt: batch.receivedAt, now: now) {
            pendingSharedInboxBatch = nil
            SharedInboxStore.shared.remove(batchID: batch.id)
        }
        guard sharedInboxDelivery == nil else { return }
        if pendingSharedInboxBatch == nil {
            pendingSharedInboxBatch = SharedInboxStore.shared
                .pendingBatches(forAccountID: accountID)
                .first
        }
        if let batch = pendingSharedInboxBatch {
            let startedConversationIDs = durableSharedInboxConversationIDs(for: batch)
            if startedConversationIDs.count == 1,
               let conversationID = startedConversationIDs.first {
                routeSharedInbox(to: conversationID)
                return
            }
            if startedConversationIDs.count > 1 {
                lastError = "This staged share has conflicting local delivery records. Remove it and share again."
                return
            }
        }
        routeRequestedSharedInboxDestinationIfPossible()
    }

    /// A share sends as exactly one message under the batch UUID, whatever its shape —
    /// text-only, one attachment, or a 2–8 batch — so that one UUID is the only durable
    /// footprint to look for. The protected local projection is the durable truth after a
    /// process restart: if that message already exists, the batch is pinned to its
    /// conversation and can never be re-routed into a duplicate/collision. (Item UUIDs are
    /// composer staging tags and never become message IDs.)
    private func durableSharedInboxConversationIDs(for batch: SharedInboxBatch) -> Set<String> {
        Set(state.messages.compactMap { message in
            guard message.isOutgoing, message.id == batch.id else { return nil }
            return SharedInboxPolicy.canonicalConversationID(message.conversationId)
        })
    }

    func sharedInboxHasDurablyQueuedContent(_ batch: SharedInboxBatch) -> Bool {
        !durableSharedInboxConversationIDs(for: batch).isEmpty
    }

    /// A share-extension choice is a request, never authority. Existing chats are resolved only
    /// from protected local state. A contact without a thread goes through the authenticated,
    /// capability-gated provisional composer when available. Older servers retain authenticated,
    /// server-idempotent creation while online; offline their staged bytes remain queued.
    private func routeRequestedSharedInboxDestinationIfPossible() {
        guard let batch = pendingSharedInboxBatch,
              let destination = batch.destination,
              canDeliverSharedContent
        else { return }

        let routePrivacyAllows = destination.kind == .group
            || (communicationPrivacyAllowsOutbound(to: destination.recipientUserID)
                && !isCommunicationBlocked(userID: destination.recipientUserID))
        guard routePrivacyAllows else { return }
        if let conversationID = destination.conversationID,
           let conversation = state.conversations.first(where: {
               $0.id.caseInsensitiveCompare(conversationID) == .orderedSame
           }), let currentAccountID = profile?.id,
           SharedInboxPolicy.destinationRequest(
               destination,
               matchesConversationID: conversation.id,
               isGroup: conversation.isGroup,
               participantUserIDs: conversation.participantUserIds,
               currentAccountID: currentAccountID
           ) {
            routeSharedInbox(to: conversation.id)
            return
        }
        guard destination.kind != .group,
              let recipientUserID = destination.recipientUserID
        else { return }
        if let conversation = existingDirectConversationForSharedInbox(
            recipientUserID: recipientUserID
        ) {
            routeSharedInbox(to: conversation.id)
            return
        }
        if messagingOfflineDirectCreationLocalQueueEnabled,
           let currentUserID = profile?.id,
           let provisional = ProvisionalDirectConversationPolicy.make(
               id: destination.conversationID ?? UUID().uuidString.lowercased(),
               localUserID: currentUserID,
               recipientUserID: recipientUserID,
               title: destination.displayName,
               createdAt: batch.receivedAt
           ) {
            routeSharedInbox(to: provisional)
            return
        }
        guard isOnline,
              secureMessagingAvailable,
              communicationPrivacyAllowsOutbound(to: recipientUserID),
              !isCommunicationBlocked(userID: recipientUserID),
              resolvingSharedInboxBatchID != batch.id
        else { return }
        resolvingSharedInboxBatchID = batch.id
        Task { [weak self] in
            await self?.resolveSharedInboxContactDestination(
                batchID: batch.id,
                recipientUserID: recipientUserID,
                title: destination.displayName
            )
            if self?.resolvingSharedInboxBatchID == batch.id {
                self?.resolvingSharedInboxBatchID = nil
            }
        }
    }

    private func existingDirectConversationForSharedInbox(
        recipientUserID: String
    ) -> Conversation? {
        guard let currentUserID = SharedInboxPolicy.canonicalAccountID(profile?.id),
              let recipientUserID = SharedInboxPolicy.canonicalAccountID(recipientUserID)
        else { return nil }
        let participants = Set([currentUserID, recipientUserID])
        return state.conversations
            .filter {
                !$0.isGroup
                    && Set($0.participantUserIds.compactMap {
                        SharedInboxPolicy.canonicalAccountID($0)
                    }) == participants
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func resolveSharedInboxContactDestination(
        batchID: UUID,
        recipientUserID: String,
        title: String
    ) async {
        guard pendingSharedInboxBatch?.id == batchID,
              canDeliverSharedContent,
              isOnline,
              secureMessagingAvailable,
              let currentUserID = profile?.id
        else { return }
        let expectedAccountEpoch = accountEpoch
        guard let commitAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
            forAccountID: currentUserID
        ), let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: currentUserID,
            sessionID: expectedSessionID,
            commitAdmission: commitAdmission
        ) else { return }

        do {
            let created = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: expectedAccountEpoch,
                sessionID: expectedSessionID,
                commitAdmission: commitAdmission
            ) {
                try await SecureMessagingExchangeCoordinator.shared.ensureDirectConversation(
                    forUserID: currentUserID,
                    recipientUserID: recipientUserID,
                    title: title,
                    commitAdmission: commitAdmission
                )
            }
            guard pendingSharedInboxBatch?.id == batchID,
                  ProtectedCommunicationAdmissionGate.shared.permits(commitAdmission),
                  await outboxContextIsCurrent(
                      accountEpoch: expectedAccountEpoch,
                      userID: currentUserID,
                      sessionID: expectedSessionID
                  )
            else { return }
            await publishLatestState()
            guard pendingSharedInboxBatch?.id == batchID,
                  let resolved = existingDirectConversationForSharedInbox(
                      recipientUserID: recipientUserID
                  ),
                  resolved.id.caseInsensitiveCompare(created.id) == .orderedSame
            else { return }
            routeSharedInbox(to: resolved.id)
        } catch is CancellationError {
            return
        } catch {
            // Keep the batch intact and the ordinary destination picker usable. A transient
            // network failure must never turn a staged share into a disappearance.
            guard pendingSharedInboxBatch?.id == batchID,
                  await outboxContextIsCurrent(
                      accountEpoch: expectedAccountEpoch,
                      userID: currentUserID,
                      sessionID: expectedSessionID
                  )
            else { return }
        }
    }

    /// The chat the customer chose for the share now in front of them.
    func routeSharedInbox(to conversationID: String) {
        guard let batch = pendingSharedInboxBatch,
              canDeliverSharedContent,
              let conversation = state.conversations.first(where: {
                  $0.id.caseInsensitiveCompare(conversationID) == .orderedSame
              })
        else { return }
        routeSharedInbox(to: conversation, batch: batch)
    }

    /// Routes a share into either a stored conversation or a compose-only provisional direct
    /// thread. The latter remains in memory and in the staged batch destination only; cancelling
    /// persists no empty conversation, while Send promotes all local state in one transaction.
    private func routeSharedInbox(
        to conversation: Conversation,
        batch: SharedInboxBatch? = nil
    ) {
        guard let batch = batch ?? pendingSharedInboxBatch,
              pendingSharedInboxBatch?.id == batch.id,
              canDeliverSharedContent,
              sharedInboxConversationIsEligible(conversation),
              !conversation.isProvisionalDirect
                || messagingOfflineDirectCreationLocalQueueEnabled
        else { return }
        let durableConversationIDs = durableSharedInboxConversationIDs(for: batch)
        let canonicalConversationID = SharedInboxPolicy.canonicalConversationID(conversation.id)
        guard durableConversationIDs.isEmpty
                || (canonicalConversationID.map { durableConversationIDs == Set([$0]) } == true)
        else {
            lastError = "Part of this share is already queued in another conversation. Finish it there or discard what remains."
            return
        }
        guard let destination = sharedInboxDestinationRequest(for: conversation) else { return }
        let pinnedBatch: SharedInboxBatch
        do {
            // Persist the validated destination before the queue attempt. The whole share is
            // one queue commit under the batch UUID, so if the process dies mid-send, both the
            // manifest and that stable message identity independently force a retried share
            // back into this exact conversation.
            pinnedBatch = try SharedInboxStore.shared.pinDestination(
                for: batch,
                to: destination
            )
        } catch {
            lastError = "Kit Pay could not safely save this chat choice. Nothing was queued. Try again."
            return
        }
        pendingSharedInboxBatch = nil
        sharedInboxProvisionalConversation = conversation.isProvisionalDirect
            ? conversation
            : nil
        sharedInboxDelivery = SharedInboxDelivery(
            conversationID: conversation.id,
            batch: pinnedBatch
        )
        selectedTab = MainTabIndex.messages
        messageConversationNavigationRequest = MessageConversationNavigationRequest(
            conversationID: conversation.id
        )
    }

    private func sharedInboxDestinationRequest(
        for conversation: Conversation
    ) -> SharedInboxDestinationRequest? {
        guard let conversationID = SharedInboxPolicy.canonicalConversationID(conversation.id),
              let currentAccountID = SharedInboxPolicy.canonicalAccountID(profile?.id),
              let displayName = SharedInboxPolicy.destinationDisplayName(
                  ConversationContactPresentationPolicy.presentation(
                      for: conversation,
                      currentUserID: currentAccountID,
                      contacts: contactDirectory
                  ).displayName
              )
        else { return nil }
        let participants = Set(conversation.participantUserIds.compactMap {
            SharedInboxPolicy.canonicalAccountID($0)
        })
        if conversation.isGroup {
            return SharedInboxDestinationRequest(
                kind: .group,
                conversationID: conversationID,
                recipientUserID: nil,
                displayName: displayName
            )
        }
        guard let recipientUserID = participants.first(where: { $0 != currentAccountID }) else {
            return nil
        }
        return SharedInboxDestinationRequest(
            kind: .direct,
            conversationID: conversationID,
            recipientUserID: recipientUserID,
            displayName: displayName
        )
    }

    func sharedInboxConversationIsEligible(_ conversation: Conversation) -> Bool {
        guard secureMessagingAvailable,
              let currentAccountID = SharedInboxPolicy.canonicalAccountID(profile?.id)
        else {
            return false
        }
        let canonicalParticipants = conversation.participantUserIds.compactMap {
            SharedInboxPolicy.canonicalAccountID($0)
        }
        let participants = Set(canonicalParticipants)
        guard canonicalParticipants.count == conversation.participantUserIds.count,
              participants.count == conversation.participantUserIds.count,
              participants.contains(currentAccountID)
        else { return false }
        if conversation.isGroup {
            return messagingGroupLocalQueueEnabled && participants.count >= 2
        }
        guard participants.count == 2,
              let recipientUserID = participants.first(where: { $0 != currentAccountID })
        else { return false }
        return communicationPrivacyAllowsOutbound(to: recipientUserID)
            && !isCommunicationBlocked(userID: recipientUserID)
    }

    /// Returns authority for the one compose-only share route that may create a local direct
    /// conversation. Capability, staged-batch destination, recipient and in-memory projection
    /// must all agree; ordinary callers cannot turn an arbitrary missing UUID into a thread.
    private func sharedInboxProvisionalRecipient(conversationID: String) -> String? {
        guard messagingOfflineDirectCreationLocalQueueEnabled,
              state.conversations.allSatisfy({
                  $0.id.caseInsensitiveCompare(conversationID) != .orderedSame
              }),
              let delivery = sharedInboxDelivery,
              delivery.conversationID.caseInsensitiveCompare(conversationID) == .orderedSame,
              let destination = delivery.batch.destination,
              destination.kind == .direct,
              destination.conversationID?.caseInsensitiveCompare(conversationID)
                  == .orderedSame,
              let recipient = SharedInboxPolicy.canonicalAccountID(
                  destination.recipientUserID
              ),
              let provisional = sharedInboxProvisionalConversation,
              provisional.id.caseInsensitiveCompare(conversationID) == .orderedSame,
              provisional.isProvisionalDirect,
              provisional.pendingDirectRecipientUserID == recipient
        else { return nil }
        return recipient
    }

    /// Called only after every selected shared item is durably represented in the local outbox.
    /// At that point its protected handoff copy is redundant and can be removed.
    func consumeSharedInboxDelivery(_ id: UUID) {
        guard let delivery = sharedInboxDelivery, delivery.id == id else { return }
        sharedInboxDelivery = nil
        sharedInboxProvisionalConversation = nil
        SharedInboxStore.shared.remove(batchID: delivery.batch.id)
        // A second share that arrived while the first was being placed can be offered now.
        refreshSharedInbox()
    }

    /// Returns an unreadable or currently-too-large delivery to the destination picker without
    /// deleting it. The customer can choose another chat (for example, one whose composer is
    /// empty) or explicitly cancel; an implementation failure never silently discards plaintext.
    func retrySharedInboxDelivery(_ id: UUID) {
        guard let delivery = sharedInboxDelivery, delivery.id == id else { return }
        sharedInboxDelivery = nil
        sharedInboxProvisionalConversation = nil
        pendingSharedInboxBatch = delivery.batch
    }

    /// The customer explicitly removed an applied share instead of sending it. This is the only
    /// pre-outbox path that destroys the protected handoff after it has reached a composer.
    func discardSharedInboxDelivery(_ id: UUID) {
        guard let delivery = sharedInboxDelivery, delivery.id == id else { return }
        sharedInboxDelivery = nil
        sharedInboxProvisionalConversation = nil
        SharedInboxStore.shared.remove(batchID: delivery.batch.id)
        refreshSharedInbox()
    }

    /// The customer closed the destination picker without choosing a chat.
    func discardPendingSharedInbox() {
        guard let batch = pendingSharedInboxBatch else { return }
        pendingSharedInboxBatch = nil
        SharedInboxStore.shared.remove(batchID: batch.id)
        refreshSharedInbox()
    }

    /// Nothing shared into the previous account may survive into the next one.
    private func purgeSharedInbox() {
        resolvingSharedInboxBatchID = nil
        pendingSharedInboxBatch = nil
        sharedInboxDelivery = nil
        sharedInboxProvisionalConversation = nil
        SharedInboxStore.shared.removeAll()
        SharedInboxStore.shared.clearActiveAccount()
    }

    /// Drops every HTTP response the app cached for the account that is going away. Avatar images
    /// are the only account-bound bytes that live outside the encrypted store.
    private func purgeSharedResponseCache() {
        URLCache.shared.removeAllCachedResponses()
    }

    /// Invoked synchronously after the account/attempt guard and before teardown suspends.
    /// No delayed observer can apply this cleanup to a replacement account.
    private func resetTransientChatMediaForAccountBoundary() {
        ChatMediaAccountLifetime.invalidate()
        VoiceNotePlayer.shared.stop()
        VoiceNoteDraftRegistry.shared.resetForAccountBoundary()
        ChatVideoPictureInPicture.shared.stopForAccountBoundary()
    }

    @discardableResult
    private func performSignOut(
        removeBiometricCredential: Bool,
        dataPolicy: AccountSignOutDataPolicy,
        expectedContext: AuthenticatedSecurityContext?,
        acceptedDeletion: PendingAcceptedAccountDeletion? = nil,
        acceptedDeletionMarkerIsDurable: Bool = false,
        acceptedDeletionAttempt: PendingAccountDeletionAttempt? = nil
    ) async -> AccountSignOutResult {
        let isAcceptedDeletion = dataPolicy == .acceptedAccountDeletion
        guard !isSigningOut,
              isAcceptedDeletion == (acceptedDeletion != nil),
              isAcceptedDeletion == (acceptedDeletionAttempt != nil),
              !isAcceptedDeletion || expectedContext != nil,
              isAcceptedDeletion || accountDeletionSubmissionID == nil
        else { return .contextChanged }
        if let expectedContext {
            guard isSignedIn,
                  accountEpoch == expectedContext.accountEpoch,
                  profile?.id.caseInsensitiveCompare(expectedContext.userID) == .orderedSame
            else { return .contextChanged }
        }
        isSigningOut = true
        resetTransientChatMediaForAccountBoundary()
        // Diagnostics have no account identifiers, but their exact event times and media sizes
        // still belong only to the account that produced them. A filesystem failure is retried
        // and blocks any later account adoption in `adoptAuthenticatedResult`.
        _ = LocalMediaPerformanceMonitor.shared.suspendRecordingAndClearReport()
        resetForegroundAuthoritativeRefresh()
        cancelWalletHistoryRefresh()
        // Revoke the non-idempotent waiting invitation before sign-out reaches its first await.
        // The normal teardown below still clears the retained waiting presentation and CallKit.
        cancelWaitingCallMergeOperation()
        authenticationAttempt = UUID()
        activeConversationID = nil
        stopVisibleConversationSync()
        defer { isSigningOut = false }
        let signedOutUserID = expectedContext?.userID ?? profile?.id
        let signedOutInstallationID = installationID()
        let revokedMediaLease = callMediaAccountLease
        let provisionalCallID = ephemeralOutgoingCallGate.attempt?.clientCallIDString
        let activeBackendCallID = CallMediaCoordinator.shared.activeCall?.id
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let callToEndOnSignOut: String?
        if let activeBackendCallID,
           UUID(uuidString: activeBackendCallID) != nil,
           activeBackendCallID.caseInsensitiveCompare(provisionalCallID ?? "") != .orderedSame {
            callToEndOnSignOut = activeBackendCallID.lowercased()
        } else {
            callToEndOnSignOut = nil
        }
        let cancelledOutgoingAttempt = cancelEphemeralOutgoingCall(
            dismissPresentation: true
        )
        cancelOutgoingCallRingDeadline()
        callMediaAccountLease = nil
        // Revoke every in-flight account fence before the first suspension, then let both
        // user-initiated and silent avatar work unwind before credentials or encrypted state
        // are cleared.
        accountEpoch = UUID()
        resetDeferredMessagingFeatures()
        // Rotate the protected-store fence and withdraw its receipt before teardown continues.
        // A completion already parked at the AppModel-to-store hop is rejected by the new context.
        try? await store.retireMessagingOfflineDirectCreationCapabilityContext(
            clearingPersistedReceipt: true
        )
        guard await resetProtectedCallRecoveryCycle(retiringQueuedEvents: true) else {
            return .contextChanged
        }
        capabilitiesRequestTracker.invalidate()
        authenticatedAppReviewDemoOwnerID = nil
        capabilities = nil
        resetCommunicationPrivacyState()
        resetSecurityPreferencesState()
        var acceptedDeletionLocalCleanupSucceeded = true
        if let acceptedDeletion {
            let accountDataCleanupSucceeded = await
                finishAcceptedAccountDeletionLocalPurge(acceptedDeletion)
            acceptedDeletionLocalCleanupSucceeded = accountDataCleanupSucceeded
            // Publish only the post-cleanup projection; an exact-target write failure is already
            // concealed by SecureLocalStore, while an ownership conflict remains marker-blocked.
            await publishLatestState()
            guard acceptedDeletionLocalCleanupSucceeded else {
                return .localCleanupFailed
            }
        }
        await cancelAllProfileWorkAndWait()
        deviceManagementGeneration &+= 1
        isRefreshingRegisteredDevices = false
        revokingRegisteredDeviceID = nil
        deviceManagementErrorMessage = nil
        // Revoke CallKit/media admission before any account teardown request is made. Nothing
        // from this account may survive into a replacement sign-in.
        clearAllCallWaitingState()
        NotificationCoordinator.shared.beginAccountSignOut()
        await retireClaimNotificationStateAtAccountBoundary()
        callEventDrainTask?.cancel()
        callEventDrainTask = nil
        callSystemEventDrainTask?.cancel()
        callSystemEventDrainTask = nil
        for event in queuedCallEvents {
            NotificationCoordinator.shared.acknowledgeCallEvent(event.id)
        }
        for action in queuedCallSystemActions {
            NotificationCoordinator.shared.acknowledgeCallEvent(action.eventId)
        }
        queuedCallEvents.removeAll()
        queuedCallSystemActions.removeAll()
        await CallMediaCoordinator.shared.resetForSignOut(revoking: revokedMediaLease)
        if !isAcceptedDeletion,
           let callToEndOnSignOut,
           let revokedMediaLease,
           isOnline {
            _ = try? await APIClientSessionBinding.$sessionID.withValue(
                revokedMediaLease.sessionID
            ) {
                try await api.endCall(id: callToEndOnSignOut, reason: "cancelled")
            }
        }
        if !isAcceptedDeletion, let cancelledOutgoingAttempt {
            await cancelEphemeralCallOnServerOnce(cancelledOutgoingAttempt)
        }
        let signedOutSessionID: String?
        if let expectedContext {
            signedOutSessionID = expectedContext.sessionID
        } else if let revokedMediaLease {
            signedOutSessionID = revokedMediaLease.sessionID
        } else {
            signedOutSessionID = await sessions.current()?.sessionId
        }
        if let signedOutUserID {
            await pushRegistrations.reset(accountID: signedOutUserID)
        }
        if !isAcceptedDeletion, isSignedIn, let pushSessionID = signedOutSessionID {
            await unregisterApplePushProvidersBeforeSignOut(sessionID: pushSessionID)
            _ = try? await APIClientSessionBinding.$sessionID.withValue(pushSessionID) {
                try await api.logout()
            }
        }
        NotificationCoordinator.shared.suspendRegistrationAfterSignOut()
        contactSyncTask?.cancel()
        contactSyncTask = nil
        contactSyncCurrentTaskForcesServerRefresh = false
        contactSyncGeneration &+= 1
        contactChangeDebounceTask?.cancel()
        contactChangeDebounceTask = nil
        contactSyncNeedsAnotherPass = false
        contactSyncState = .idle
        callHistoryRefreshTask?.cancel()
        callHistoryRefreshTask = nil
        callHistoryRefreshGeneration &+= 1
        callHistoryBackfillTask?.cancel()
        callHistoryBackfillTask = nil
        callHistoryBackfillGeneration &+= 1
        callHistoryBackfillRetryNotBefore = nil
        outboxWakeTask?.cancel()
        outboxWakeTask = nil
        communicationReplayTask?.cancel()
        communicationReplayTask = nil
        mediaPreprocessingGeneration &+= 1
        mediaPreprocessingTask?.cancel()
        mediaPreprocessingTask = nil
        mediaHydrationGeneration &+= 1
        mediaHydrationTask?.cancel()
        mediaHydrationTask = nil
        automaticBackupBackgroundTransitionTask?.cancel()
        finishAutomaticBackupBackgroundTransition()
        CommunicationBackgroundReplayScheduler.shared.cancel()
        MessageBackupRefreshScheduler.shared.cancel()
        ephemeralCallCancellationTask?.cancel()
        ephemeralCallCancellationTask = nil
        pendingEphemeralCallCancellations.removeAll()
        secureMessagingSyncError.reset()
        kycRequestGeneration &+= 1
        kycStatus = nil
        sessionAssurance = nil
        contactDirectoryRevision &+= 1
        if removeBiometricCredential {
            if isAcceptedDeletion,
               acceptedDeletionLocalCleanupSucceeded,
               let acceptedDeletion {
                do {
                    _ = try await biometrics.removeEnrollmentForAcceptedAccountDeletion(
                        userID: acceptedDeletion.accountID,
                        installationID: signedOutInstallationID
                    )
                } catch {
                    acceptedDeletionLocalCleanupSucceeded = false
                }
            } else if !isAcceptedDeletion, let signedOutUserID, let signedOutSessionID {
                do {
                    try await biometrics.disable(
                        forUserID: signedOutUserID,
                        sessionID: signedOutSessionID,
                        installationID: signedOutInstallationID
                    )
                } catch {
                    await biometrics.removeAnyEnrollment()
                }
            } else if !isAcceptedDeletion {
                await biometrics.removeAnyEnrollment()
            }
        }
        let sessionCleanupSucceeded: Bool
        if isAcceptedDeletion {
            sessionCleanupSucceeded = acceptedDeletionLocalCleanupSucceeded
        } else {
            do {
                try await sessions.clear()
                sessionCleanupSucceeded = true
            } catch {
                sessionCleanupSucceeded = false
            }
        }
        let projectionCleanupSucceeded: Bool
        if isAcceptedDeletion {
            projectionCleanupSucceeded = acceptedDeletionLocalCleanupSucceeded
        } else {
            do {
                try await store.clearFinancialAndSessionProjections(
                    preserveCommunicationHistory: dataPolicy.preserveCommunicationHistory
                )
                projectionCleanupSucceeded = true
            } catch {
                projectionCleanupSucceeded = false
            }
        }
        var mediaCacheCleanupSucceeded = true
        if !isAcceptedDeletion, let signedOutUserID {
            do {
                try await SecureMediaFileCache.shared.purge(forUserID: signedOutUserID)
            } catch {
                mediaCacheCleanupSucceeded = false
            }
        }
        // Profile photos outlive a session on purpose, so faces are still there offline and on
        // relaunch — which makes clearing them at sign-out mandatory, not optional. Both the
        // sealed files and the account's wrapping key go, so the ciphertext left in any stale
        // backup or snapshot is unopenable.
        avatarCacheAccountID = nil
        avatarCacheAccountSynced = true
        warmedOwnAvatarURL = nil
        await ProfileAvatarCache.shared.setAccount(nil)
        if let signedOutUserID {
            do {
                try await ProfileAvatarCache.shared.purge(forUserID: signedOutUserID)
            } catch {
                mediaCacheCleanupSucceeded = false
            }
        }
        // Builds before `ProfileAvatarCache` fetched avatars with `URLSession.shared`, which
        // writes them into the shared URLCache on disk in the clear. Clearing it retires those
        // copies so a signed-out — or deleted — customer's photo, and their contacts' photos,
        // cannot be re-displayed to whoever signs in next.
        purgeSharedResponseCache()
        // Anything the share sheet staged is plaintext chosen by the customer who is leaving, for
        // a chat that is about to disappear. It never carries over to the next account.
        purgeSharedInbox()
        await publishLatestState()
        isSignedIn = false
        accountSetupStep = nil
        isCompletingAccountSetup = false
        pendingPhone = nil
        pendingChallenge = nil
        pendingChallengeReceivedAt = nil
        callContacts = []
        activeConversationID = nil
        messageConversationNavigationRequest = nil
        walletClaimNavigationRequest = nil
        let deletedAccountFingerprint = acceptedDeletion.flatMap {
            MessageNotificationContract.accountFingerprint(for: $0.accountID)
        }
        await NotificationCoordinator.shared.clearMessageNotifications(
            accountFingerprint: deletedAccountFingerprint
        )
        // Catch a claim response delivered during remote token teardown as well as the intents
        // retired when the account boundary began.
        await retireClaimNotificationStateAtAccountBoundary()
        // The monitor was suspended before teardown. This final serialized clear runs after media
        // producers have been cancelled, and is the authoritative account-boundary result.
        let diagnosticsCleanupSucceeded = LocalMediaPerformanceMonitor.shared.clearReport()
        if isAcceptedDeletion, !diagnosticsCleanupSucceeded {
            acceptedDeletionLocalCleanupSucceeded = false
        }
        if let acceptedDeletion, acceptedDeletionLocalCleanupSucceeded {
            if let acceptedDeletionAttempt {
                do {
                    acceptedDeletionLocalCleanupSucceeded = try await
                        accountDeletionAttempts.completeIfCurrent(acceptedDeletionAttempt)
                } catch {
                    acceptedDeletionLocalCleanupSucceeded = false
                }
            }
            if acceptedDeletionLocalCleanupSucceeded, acceptedDeletionMarkerIsDurable {
                do {
                    acceptedDeletionLocalCleanupSucceeded = try await
                        acceptedAccountDeletionPurges.completeIfCurrent(acceptedDeletion)
                } catch {
                    acceptedDeletionLocalCleanupSucceeded = false
                }
            }
            if acceptedDeletionLocalCleanupSucceeded,
               volatileAcceptedAccountDeletion == acceptedDeletion {
                volatileAcceptedAccountDeletion = nil
            }
            if acceptedDeletionLocalCleanupSucceeded {
                privacyQuarantineTargetAccountID = nil
            }
        }
        if isAcceptedDeletion, !acceptedDeletionLocalCleanupSucceeded {
            await concealUnresolvedAcceptedAccountDeletionProjection()
        }
        locallyTerminatedCallIds.removeAll()
        pendingCallAnswers.removeAll()
        didResumeAuthenticatedSession = false
        biometricUnlockEnabled = false
        biometricAccessState = .notRequired
        homeBiometricState = .notRequired
        biometricErrorMessage = nil
        biometricSignInPermanentlyUnavailable = false
        biometricPINRecoveryRequiresEnrollmentRemoval = false
        availableBackupToRestore = nil
        messageBackupReplacementAvailable = false
        messageBackupOperationError = nil
        messageBackupRefreshScheduleState = .inactive
        acceptedAccountDeletionCleanupBlocked = isAcceptedDeletion
            && !acceptedDeletionLocalCleanupSucceeded
        isLoading = acceptedAccountDeletionCleanupBlocked
        let result = AccountSignOutResult.cleanupResult(
            sessionCleanupSucceeded: sessionCleanupSucceeded,
            projectionCleanupSucceeded: projectionCleanupSucceeded,
            mediaCacheCleanupSucceeded: mediaCacheCleanupSucceeded,
            diagnosticsCleanupSucceeded: diagnosticsCleanupSucceeded,
            acceptedDeletionCleanupSucceeded: !isAcceptedDeletion
                || acceptedDeletionLocalCleanupSucceeded
        )
        if result == .completed {
            // The signed-in projection was cleared before credentials. Repopulate only the public
            // sign-in capabilities after teardown, so onboarding never reuses the departed
            // account's cohort response and does not remain disabled until another path change.
            _ = await reloadCapabilities()
        }
        return result
    }

    func refreshRegisteredDevices() async {
        guard !isRefreshingRegisteredDevices,
              revokingRegisteredDeviceID == nil,
              !isSigningOut,
              isSignedIn
        else { return }
        guard isOnline else {
            deviceManagementErrorMessage = DeviceManagementError.unavailable.localizedDescription
            return
        }
        guard let expectedUserID = profile?.id else { return }

        let expectedAccountEpoch = accountEpoch
        deviceManagementGeneration &+= 1
        let expectedGeneration = deviceManagementGeneration
        isRefreshingRegisteredDevices = true
        deviceManagementErrorMessage = nil
        defer {
            if deviceManagementGeneration == expectedGeneration {
                // Invalidate bootstrap/device reads that began while this operation was active.
                deviceManagementGeneration &+= 1
                isRefreshingRegisteredDevices = false
            }
        }
        guard let expectedSessionID = await sessions.current()?.sessionId,
              await deviceManagementContextIsCurrent(
                generation: expectedGeneration,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else { return }

        do {
            let response = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.registeredDevices()
            }
            guard let devices = RegisteredDevicePolicy.validated(response.items) else {
                throw DeviceManagementError.invalidServiceResponse
            }
            guard await deviceManagementContextIsCurrent(
                generation: expectedGeneration,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            try await store.update { persisted in
                guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame
                else { throw StoreError.accountChanged }
                persisted.replaceRegisteredDeviceProjection(devices)
            }
            guard await deviceManagementContextIsCurrent(
                generation: expectedGeneration,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            await publishLatestState()
            deviceManagementErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard await deviceManagementContextIsCurrent(
                generation: expectedGeneration,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            deviceManagementErrorMessage = deviceManagementFailureMessage(
                error,
                operation: .refresh
            )
        }
    }

    func revokeRegisteredDevice(id: String) async {
        guard appReviewDemoMutationsAllowed else {
            deviceManagementErrorMessage = AppReviewDemoMutationPolicy.readOnlyMessage
            return
        }
        guard !isRefreshingRegisteredDevices,
              revokingRegisteredDeviceID == nil,
              !isSigningOut,
              isSignedIn
        else { return }
        guard let deviceID = RegisteredDevicePolicy.canonicalID(id) else {
            deviceManagementErrorMessage = DeviceManagementError.invalidDevice.localizedDescription
            return
        }
        guard let validatedDevices = RegisteredDevicePolicy.validated(registeredDevices) else {
            deviceManagementErrorMessage = DeviceManagementError.invalidServiceResponse
                .localizedDescription
            return
        }
        let matchingDevices = validatedDevices.filter { $0.id == deviceID }
        guard matchingDevices.count == 1, let device = matchingDevices.first else {
            deviceManagementErrorMessage = DeviceManagementError.invalidDevice.localizedDescription
            return
        }
        guard RegisteredDevicePolicy.canRevoke(device) else {
            deviceManagementErrorMessage = DeviceManagementError.currentDevice.localizedDescription
            return
        }
        guard isOnline else {
            deviceManagementErrorMessage = DeviceManagementError.unavailable.localizedDescription
            return
        }
        guard let expectedUserID = profile?.id else { return }

        let expectedAccountEpoch = accountEpoch
        deviceManagementGeneration &+= 1
        let expectedGeneration = deviceManagementGeneration
        revokingRegisteredDeviceID = deviceID
        deviceManagementErrorMessage = nil
        defer {
            if deviceManagementGeneration == expectedGeneration {
                // Invalidate bootstrap/device reads that began before remote revocation settled.
                deviceManagementGeneration &+= 1
                revokingRegisteredDeviceID = nil
            }
        }
        guard let expectedSessionID = await sessions.current()?.sessionId,
              await deviceManagementContextIsCurrent(
                generation: expectedGeneration,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else { return }

        var revocationConfirmed = false
        do {
            do {
                try await APIClientSessionBinding.$sessionID.withValue(expectedSessionID) {
                    try await api.revokeRegisteredDevice(id: deviceID)
                }
                revocationConfirmed = true
            } catch let payload as APIErrorPayload
                where payload.code.caseInsensitiveCompare("DEVICE_NOT_FOUND") == .orderedSame {
                // A previously removed installation is already in the requested terminal state.
                // Remove the stale encrypted projection after the same account/session fences.
                revocationConfirmed = true
            }

            guard await deviceManagementContextIsCurrent(
                generation: expectedGeneration,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            try await store.update { persisted in
                guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame
                else { throw StoreError.accountChanged }
                let currentDevices = persisted.registeredDevices
                    .flatMap { RegisteredDevicePolicy.validated($0) }
                    ?? validatedDevices
                if let persistedDevice = currentDevices.first(where: { $0.id == deviceID }),
                   !RegisteredDevicePolicy.canRevoke(persistedDevice) {
                    throw DeviceManagementError.currentDevice
                }
                persisted.replaceRegisteredDeviceProjection(
                    currentDevices.filter { $0.id != deviceID }
                )
            }
            guard await deviceManagementContextIsCurrent(
                generation: expectedGeneration,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            await publishLatestState()
            deviceManagementErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard await deviceManagementContextIsCurrent(
                generation: expectedGeneration,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            deviceManagementErrorMessage = deviceManagementFailureMessage(
                error,
                operation: revocationConfirmed ? .persistConfirmedRevocation : .revoke
            )
        }
    }

    private enum DeviceManagementOperation {
        case refresh
        case revoke
        case persistConfirmedRevocation
    }

    private func deviceManagementContextIsCurrent(
        generation expectedGeneration: UInt64,
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async -> Bool {
        guard !Task.isCancelled,
              !isSigningOut,
              isSignedIn,
              deviceManagementGeneration == expectedGeneration,
              accountEpoch == expectedAccountEpoch,
              profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
              await sessions.current()?.sessionId == expectedSessionID
        else { return false }
        return !Task.isCancelled
            && !isSigningOut
            && isSignedIn
            && deviceManagementGeneration == expectedGeneration
            && accountEpoch == expectedAccountEpoch
            && profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame
    }

    private func deviceManagementFailureMessage(
        _ error: Error,
        operation: DeviceManagementOperation
    ) -> String {
        if !isOnline { return DeviceManagementError.unavailable.localizedDescription }
        if let managementError = error as? DeviceManagementError {
            return managementError.localizedDescription
        }
        if let payload = error as? APIErrorPayload {
            switch payload.code.uppercased() {
            case "CURRENT_DEVICE_REQUIRES_LOGOUT":
                return DeviceManagementError.currentDevice.localizedDescription
            case "DEVICE_NOT_FOUND":
                return DeviceManagementError.invalidDevice.localizedDescription
            default:
                break
            }
        }
        switch operation {
        case .refresh:
            return DeviceManagementError.invalidServiceResponse.localizedDescription
        case .revoke:
            return DeviceManagementError.revocationFailed.localizedDescription
        case .persistConfirmedRevocation:
            return "This device was signed out, but the saved list could not be updated. Refresh to check again."
        }
    }

    func loadSecurityPreferences(force: Bool = false) async {
        guard !isManagingSecurityPreferences,
              !isSigningOut,
              isSignedIn
        else { return }
        if !force, securityPreferences != nil { return }
        guard isOnline else {
            securityPreferencesErrorMessage =
                "Connect to the internet to load this security setting."
            return
        }

        securityPreferencesRequestGeneration &+= 1
        let generation = securityPreferencesRequestGeneration
        isLoadingSecurityPreferences = true
        securityPreferencesErrorMessage = nil
        defer {
            if securityPreferencesRequestGeneration == generation {
                isLoadingSecurityPreferences = false
            }
        }
        guard let context = await securityPreferencesContext() else {
            if securityPreferencesRequestGeneration == generation {
                securityPreferencesErrorMessage =
                    "Sign in again to manage this security setting."
            }
            return
        }

        do {
            let preferences = try await APIClientSessionBinding.$sessionID.withValue(
                context.sessionID
            ) {
                try await api.securityPreferences()
            }
            guard securityPreferencesRequestGeneration == generation,
                  await securityPreferencesContextIsCurrent(context)
            else { return }
            securityPreferences = preferences
        } catch is CancellationError {
            return
        } catch {
            guard securityPreferencesRequestGeneration == generation,
                  await securityPreferencesContextIsCurrent(context)
            else { return }
            securityPreferencesErrorMessage = securityPreferencesFailureMessage(
                error,
                operation: .load
            )
        }
    }

    func setVerifyIdentityOnNewLogin(_ enabled: Bool) async {
        guard appReviewDemoMutationsAllowed else {
            securityPreferencesErrorMessage = AppReviewDemoMutationPolicy.readOnlyMessage
            return
        }
        guard !isManagingSecurityPreferences else { return }
        if securityPreferences == nil {
            await loadSecurityPreferences()
        }
        guard let current = securityPreferences,
              !isManagingSecurityPreferences
        else { return }
        guard current.verifyIdentityOnNewLogin != enabled else {
            securityPreferencesErrorMessage = nil
            return
        }
        guard isOnline else {
            securityPreferencesErrorMessage =
                "Connect to the internet to update this security setting."
            return
        }

        securityPreferencesRequestGeneration &+= 1
        let generation = securityPreferencesRequestGeneration
        isUpdatingSecurityPreferences = true
        securityPreferencesErrorMessage = nil
        defer {
            if securityPreferencesRequestGeneration == generation {
                isUpdatingSecurityPreferences = false
            }
        }
        guard let context = await securityPreferencesContext() else {
            if securityPreferencesRequestGeneration == generation {
                securityPreferencesErrorMessage =
                    "Sign in again to update this security setting."
            }
            return
        }

        do {
            let result = try await saveSecurityPreferences(
                enabled: enabled,
                current: current,
                context: context,
                generation: generation
            )
            guard securityPreferencesRequestGeneration == generation,
                  await securityPreferencesContextIsCurrent(context)
            else { return }
            switch result {
            case .updated(let preferences):
                securityPreferences = preferences
            case .refreshedAfterConflict(let preferences):
                securityPreferences = preferences
                securityPreferencesErrorMessage =
                    "This setting changed on another device. The latest choice is shown; review it and try again."
            }
        } catch is CancellationError {
            return
        } catch is SecurityPreferencesConflictRefreshFailure {
            guard securityPreferencesRequestGeneration == generation,
                  await securityPreferencesContextIsCurrent(context)
            else { return }
            securityPreferences = nil
            securityPreferencesErrorMessage =
                "This setting changed on another device, but the latest choice could not be loaded. Refresh and try again."
        } catch {
            guard securityPreferencesRequestGeneration == generation,
                  await securityPreferencesContextIsCurrent(context)
            else { return }
            securityPreferencesErrorMessage = securityPreferencesFailureMessage(
                error,
                operation: .update
            )
        }
    }

    private func saveSecurityPreferences(
        enabled: Bool,
        current: SecurityPreferencesDTO,
        context: SecurityPreferencesAccountContext,
        generation: UInt64
    ) async throws -> SecurityPreferencesSaveResult {
        do {
            let request = try UpdateSecurityPreferencesRequest(
                version: current.version,
                verifyIdentityOnNewLogin: enabled
            )
            let updated = try await APIClientSessionBinding.$sessionID.withValue(
                context.sessionID
            ) {
                try await api.updateSecurityPreferences(request)
            }
            guard SecurityPreferencesUpdatePolicy.isValidTransition(
                from: current,
                to: updated,
                requestedValue: enabled
            ) else { throw APIClientError.invalidResponse }
            return .updated(updated)
        } catch let error as APIErrorPayload
            where error.code.caseInsensitiveCompare(
                "SECURITY_PREFERENCES_VERSION_CONFLICT"
            ) == .orderedSame {
            let latest: SecurityPreferencesDTO
            do {
                latest = try await APIClientSessionBinding.$sessionID.withValue(
                    context.sessionID
                ) {
                    try await api.securityPreferences()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SecurityPreferencesConflictRefreshFailure()
            }
            guard securityPreferencesRequestGeneration == generation,
                  await securityPreferencesContextIsCurrent(context)
            else { throw CancellationError() }
            // Never replay a stale edit over the newer choice made by another session.
            return .refreshedAfterConflict(latest)
        }
    }

    private func securityPreferencesContext() async -> SecurityPreferencesAccountContext? {
        guard !isSigningOut,
              isSignedIn,
              accountSetupStep == nil,
              sessionAssurance?.grantsFullAccess == true,
              let userID = profile?.id
        else { return nil }
        let expectedAccountEpoch = accountEpoch
        guard let sessionID = await sessions.current()?.sessionId,
              !isSigningOut,
              isSignedIn,
              accountSetupStep == nil,
              sessionAssurance?.grantsFullAccess == true,
              accountEpoch == expectedAccountEpoch,
              profile?.id.caseInsensitiveCompare(userID) == .orderedSame
        else { return nil }
        return SecurityPreferencesAccountContext(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: sessionID
        )
    }

    private func securityPreferencesContextIsCurrent(
        _ context: SecurityPreferencesAccountContext
    ) async -> Bool {
        guard !Task.isCancelled,
              !isSigningOut,
              isSignedIn,
              accountSetupStep == nil,
              sessionAssurance?.grantsFullAccess == true,
              accountEpoch == context.accountEpoch,
              profile?.id.caseInsensitiveCompare(context.userID) == .orderedSame,
              await sessions.current()?.sessionId == context.sessionID
        else { return false }
        return !Task.isCancelled
            && !isSigningOut
            && isSignedIn
            && accountEpoch == context.accountEpoch
            && profile?.id.caseInsensitiveCompare(context.userID) == .orderedSame
    }

    private func resetSecurityPreferencesState() {
        securityPreferencesRequestGeneration &+= 1
        securityPreferences = nil
        isLoadingSecurityPreferences = false
        isUpdatingSecurityPreferences = false
        securityPreferencesErrorMessage = nil
    }

    private enum SecurityPreferencesOperation: Equatable {
        case load
        case update
    }

    private func securityPreferencesFailureMessage(
        _ error: Error,
        operation: SecurityPreferencesOperation
    ) -> String {
        if !isOnline {
            return operation == .load
                ? "Connect to the internet to load this security setting."
                : "Connect to the internet to update this security setting."
        }
        if let payload = error as? APIErrorPayload,
           payload.code.caseInsensitiveCompare("ACCOUNT_RESTRICTED") == .orderedSame {
            return "This security setting is unavailable for this account."
        }
        if let clientError = error as? APIClientError,
           case .signedOut = clientError {
            return "Sign in again to manage this security setting."
        }
        return operation == .load
            ? "Kit Pay could not load this security setting. Please try again."
            : "Kit Pay could not update this security setting. Please try again."
    }

    func refreshMFAStatus() async throws -> Bool {
        let context = try await captureAuthenticatedSecurityContext()
        let updated = try await APIClientSessionBinding.$sessionID.withValue(
            context.sessionID
        ) {
            try await api.currentProfile()
        }
        guard updated.id.caseInsensitiveCompare(context.userID) == .orderedSame,
              await authenticatedSecurityContextIsCurrent(context)
        else { throw APIClientError.signedOut }
        guard let enabled = updated.mfaEnabled else {
            throw MFAManagementError.invalidResponse
        }
        await cacheMFAStatus(enabled, context: context)
        return enabled
    }

    func beginTOTPEnrollment() async throws -> TOTPEnrollmentDTO {
        guard appReviewDemoMutationsAllowed else {
            throw AppReviewDemoMutationError.readOnly
        }
        let context = try await captureAuthenticatedSecurityContext()
        let enrollment = try await APIClientSessionBinding.$sessionID.withValue(
            context.sessionID
        ) {
            try await api.enrollTOTP()
        }
        guard await authenticatedSecurityContextIsCurrent(context) else {
            throw APIClientError.signedOut
        }
        guard TOTPEnrollmentPolicy.isValid(enrollment) else {
            throw MFAManagementError.invalidResponse
        }
        return enrollment
    }

    func confirmTOTPEnrollment(code: String) async throws -> [String] {
        guard appReviewDemoMutationsAllowed else {
            throw AppReviewDemoMutationError.readOnly
        }
        guard let normalizedCode = MFAFactorCodePolicy.normalizedSixDigitCode(code) else {
            throw APIErrorPayload(
                code: "MFA_CODE_INVALID",
                message: "Enter the complete six-digit authenticator code."
            )
        }
        let context = try await captureAuthenticatedSecurityContext()
        let result = try await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
            try await api.confirmTOTP(code: normalizedCode)
        }
        guard await authenticatedSecurityContextIsCurrent(context) else {
            throw APIClientError.signedOut
        }
        guard result.enabled == true,
              let recoveryCodes = MFAFactorCodePolicy.validatedRecoveryCodes(result.recoveryCodes)
        else { throw MFAManagementError.invalidResponse }
        await cacheMFAStatus(true, context: context)
        return recoveryCodes
    }

    func regenerateMFARecoveryCodes(code: String) async throws -> [String] {
        guard appReviewDemoMutationsAllowed else {
            throw AppReviewDemoMutationError.readOnly
        }
        guard let normalizedCode = MFAFactorCodePolicy.normalizedFactorCode(code) else {
            throw APIErrorPayload(
                code: "MFA_CODE_INVALID",
                message: "Enter a current authenticator code or a complete recovery code."
            )
        }
        let context = try await captureAuthenticatedSecurityContext()
        let result: MFARecoveryCodesDTO
        do {
            result = try await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
                try await api.regenerateMFARecoveryCodes(code: normalizedCode)
            }
        } catch {
            if IrreversibleAuthenticationMutationPolicy.completionIsUncertain(after: error) {
                throw MFAManagementError.recoveryCodesUncertain
            }
            throw error
        }
        guard await authenticatedSecurityContextIsCurrent(context) else {
            throw APIClientError.signedOut
        }
        guard let recoveryCodes = MFAFactorCodePolicy.validatedRecoveryCodes(result.recoveryCodes)
        else { throw MFAManagementError.recoveryCodesUncertain }
        return recoveryCodes
    }

    func disableTOTP(code: String) async throws {
        guard appReviewDemoMutationsAllowed else {
            throw AppReviewDemoMutationError.readOnly
        }
        guard let normalizedCode = MFAFactorCodePolicy.normalizedFactorCode(code) else {
            throw APIErrorPayload(
                code: "MFA_CODE_INVALID",
                message: "Enter a current authenticator code or a complete recovery code."
            )
        }
        let context = try await captureAuthenticatedSecurityContext()
        let result = try await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
            try await api.disableTOTP(code: normalizedCode)
        }
        guard await authenticatedSecurityContextIsCurrent(context) else {
            throw APIClientError.signedOut
        }
        guard result.enabled == false else { throw MFAManagementError.invalidResponse }
        await cacheMFAStatus(false, context: context)
    }

    private func captureAuthenticatedSecurityContext() async throws
        -> AuthenticatedSecurityContext {
        guard isOnline else { throw MFAManagementError.offline }
        guard authenticatorMFAAvailable,
              isSignedIn,
              accountSetupStep == nil,
              sessionAssurance?.grantsFullAccess == true,
              let userID = profile?.id,
              let session = await sessions.current(),
              session.accountId?.caseInsensitiveCompare(userID) == .orderedSame
        else { throw MFAManagementError.unavailable }
        let context = AuthenticatedSecurityContext(
            accountEpoch: accountEpoch,
            userID: userID,
            sessionID: session.sessionId
        )
        guard await authenticatedSecurityContextIsCurrent(context) else {
            throw MFAManagementError.unavailable
        }
        return context
    }

    private func authenticatedSecurityContextIsCurrent(
        _ context: AuthenticatedSecurityContext
    ) async -> Bool {
        await sessionOwnershipContextIsCurrent(context, requiresSignedIn: true)
    }

    private func sessionOwnershipContextIsCurrent(
        _ context: AuthenticatedSecurityContext,
        requiresSignedIn: Bool
    ) async -> Bool {
        guard !Task.isCancelled,
              !isSigningOut,
              !requiresSignedIn || isSignedIn,
              accountEpoch == context.accountEpoch,
              profile?.id.caseInsensitiveCompare(context.userID) == .orderedSame,
              let currentSession = await sessions.current()
        else { return false }
        return !Task.isCancelled
            && (!requiresSignedIn || isSignedIn)
            && !isSigningOut
            && accountEpoch == context.accountEpoch
            && currentSession.sessionId.caseInsensitiveCompare(context.sessionID) == .orderedSame
            && currentSession.accountId?.caseInsensitiveCompare(context.userID) == .orderedSame
    }

    private func cacheMFAStatus(
        _ enabled: Bool,
        context: AuthenticatedSecurityContext
    ) async {
        guard await authenticatedSecurityContextIsCurrent(context) else { return }
        do {
            try await store.update { persisted in
                guard persisted.profile?.id.caseInsensitiveCompare(context.userID) == .orderedSame
                else { throw StoreError.accountChanged }
                persisted.profile?.mfaEnabled = enabled
            }
            let updatedState = await store.snapshot()
            guard updatedState.profile?.id.caseInsensitiveCompare(context.userID) == .orderedSame,
                  await authenticatedSecurityContextIsCurrent(context)
            else { return }
            await publishLatestState()
        } catch {
            // The server result remains authoritative. Keep this process accurate even if the
            // encrypted cache cannot be rewritten; the next profile refresh repairs persistence.
            guard await authenticatedSecurityContextIsCurrent(context),
                  state.profile?.id.caseInsensitiveCompare(context.userID) == .orderedSame
            else { return }
            // Deliberate in-memory overlay: the store write failed, so the funnel has nothing
            // newer to publish — this flag must ride on the published state directly.
            var updatedState = state
            updatedState.profile?.mfaEnabled = enabled
            state = updatedState
        }
    }

    @discardableResult
    func setBiometricUnlockEnabled(_ enabled: Bool) async -> Bool {
        guard appReviewDemoMutationsAllowed else {
            biometricErrorMessage = AppReviewDemoMutationPolicy.readOnlyMessage
            return false
        }
        guard !isConfiguringBiometrics,
              isSignedIn,
              accountSetupStep == nil,
              sessionAssurance?.grantsFullAccess == true,
              let userID = profile?.id,
              let session = await sessions.current()
        else { return false }
        if enabled == biometricUnlockEnabled { return true }

        let expectedAccountEpoch = accountEpoch
        let expectedSessionID = session.sessionId
        let expectedInstallationID = installationID()
        isConfiguringBiometrics = true
        biometricErrorMessage = nil
        var serverCredentialRemoved = false
        defer { isConfiguringBiometrics = false }

        do {
            if enabled {
                let availability = await biometrics.availability()
                biometricKind = availability.kind
                guard availability.isAvailable else {
                    throw KitBiometricError.unavailable
                }
                biometricKind = try await biometrics.enable(
                    forUserID: userID,
                    sessionID: expectedSessionID,
                    installationID: expectedInstallationID
                )
                let publicKeyPEM = try await biometrics.publicKeyPEM(
                    forUserID: userID,
                    sessionID: expectedSessionID,
                    installationID: expectedInstallationID
                )
                let registration = try await api.enrollBiometricKey(
                    publicKeyPEM: publicKeyPEM,
                    attestation: [
                        "platform": "ios",
                        "key_storage": "secure_enclave",
                        "access_control": "biometry_current_set",
                    ]
                )
                guard registration.algorithm?.caseInsensitiveCompare("ES256") == .orderedSame else {
                    throw KitBiometricError.storage
                }
            } else {
                _ = try await api.removeBiometricKey()
                serverCredentialRemoved = true
                try await biometrics.disable(
                    forUserID: userID,
                    sessionID: expectedSessionID,
                    installationID: expectedInstallationID
                )
            }
            let updatedAssurance = try await api.sessionAssurance()

            guard isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id == userID,
                  await sessions.current()?.sessionId == expectedSessionID
            else {
                await biometrics.removeAnyEnrollment()
                throw KitBiometricError.accountChanged
            }
            sessionAssurance = updatedAssurance
            biometricUnlockEnabled = enabled
            biometricSignInPermanentlyUnavailable = false
            biometricPINRecoveryRequiresEnrollmentRemoval = false
            biometricAccessState = enabled ? .authorized : .notRequired
            homeBiometricState = enabled ? .locked : .notRequired
            return true
        } catch {
            if enabled {
                _ = try? await api.removeBiometricKey()
                await biometrics.removeAnyEnrollment()
            } else if serverCredentialRemoved {
                await biometrics.removeAnyEnrollment()
                biometricUnlockEnabled = false
                biometricAccessState = .notRequired
                homeBiometricState = .notRequired
            }
            biometricErrorMessage = error.localizedDescription
            return false
        }
    }

    func retryBiometricSignIn() async {
        guard requiresBiometricSignIn else { return }
        guard await authenticateBiometrically(for: .returningSignIn) else {
            isLoading = false
            return
        }
        await resumeAuthenticatedSessionIfNeeded()
    }

    @discardableResult
    func retrySignInWithPIN(_ pin: String) async -> Bool {
        guard isSignedIn,
              accountSetupStep == nil,
              sessionAssurance?.grantsFullAccess == true,
              biometricAccessState != .authorizing,
              isValidPaymentPin(pin),
              let expectedSessionID = await sessions.current()?.sessionId
        else { return false }
        let expectedAccountEpoch = accountEpoch
        biometricAccessState = .authorizing
        biometricErrorMessage = nil
        do {
            let result = try await api.unlockSession(pin: pin)
            guard result.method.caseInsensitiveCompare("pin") == .orderedSame,
                  result.sessionAssurance.grantsFullAccess,
                  isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  await sessions.current()?.sessionId == expectedSessionID
            else { throw AccountSetupError.sessionNotUnlocked }
            sessionAssurance = result.sessionAssurance
            biometricAccessState = .authorized
            if selectedTab == MainTabIndex.home { homeBiometricState = .authorized }
            if biometricSignInPermanentlyUnavailable {
                if biometricPINRecoveryRequiresEnrollmentRemoval {
                    // A changed or missing key can never authenticate again. Remove only those
                    // terminal enrollments; a system lockout remains enrolled after PIN recovery.
                    await biometrics.removeAnyEnrollment()
                    _ = try? await api.removeBiometricKey()
                    biometricUnlockEnabled = false
                    homeBiometricState = .notRequired
                }
                biometricSignInPermanentlyUnavailable = false
                biometricPINRecoveryRequiresEnrollmentRemoval = false
                biometricErrorMessage = nil
            }
            await resumeAuthenticatedSessionIfNeeded()
            return true
        } catch {
            guard isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  await sessions.current()?.sessionId == expectedSessionID
            else { return false }
            biometricAccessState = .locked
            biometricErrorMessage = error.localizedDescription
            return false
        }
    }

    func applicationDidEnterBackgroundSecurely() {
#if DEBUG && APP_STORE_SCREENSHOTS
        guard !AppStoreScreenshotFixture.isActive else { return }
#endif
        appIsInBackground = true
        foregroundAuthoritativeRefreshGate.didEnterBackground()
        KitPresenceCenter.shared.setForeground(false)
        stopVisibleConversationSync()
        cancelRealtimeMessagingSync()
        suspendEphemeralOutgoingCallSubmission()
        // Re-arm first, then make one bounded best-effort attempt while iOS still grants this
        // foreground-to-background transition execution time. The backup path itself rechecks
        // account epoch/session ownership before every durable write, and biometric locking below
        // conceals UI without invalidating that authenticated background lease.
        scheduleAutomaticMessageBackupRefresh()
        startAutomaticBackupBackgroundTransitionIfNeeded()
        returningSignInBiometricAuthorizationFence.invalidate()
        homeBiometricAuthorizationFence.invalidate()
        guard isSignedIn, accountSetupStep == nil, biometricUnlockEnabled else { return }
        biometricAccessState = .locked
        homeBiometricState = .locked
        biometricErrorMessage = nil
    }

    private func startAutomaticBackupBackgroundTransitionIfNeeded() {
        guard automaticBackupBackgroundTransitionTask == nil,
              MessageBackupBackgroundTransitionPolicy.shouldAttempt(
                  isSignedIn: isSignedIn,
                  setupComplete: accountSetupStep == nil,
                  isOnline: isOnline,
                  frequency: messageBackupPreferences.frequency,
                  messageCount: state.messages.count
              )
        else { return }
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "africa.kit.pay.message-backup"
        ) { [weak self] in
            Task { @MainActor in
                self?.automaticBackupBackgroundTransitionTask?.cancel()
                self?.finishAutomaticBackupBackgroundTransition()
            }
        }
        guard identifier != .invalid else { return }
        automaticBackupBackgroundTaskIdentifier = identifier
        automaticBackupBackgroundTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.runAutomaticMessageBackupIfDue()
            self.finishAutomaticBackupBackgroundTransition()
        }
    }

    private func finishAutomaticBackupBackgroundTransition() {
        automaticBackupBackgroundTransitionTask = nil
        guard automaticBackupBackgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(automaticBackupBackgroundTaskIdentifier)
        automaticBackupBackgroundTaskIdentifier = .invalid
    }

    func applicationDidBecomeActiveSecurely() async {
#if DEBUG && APP_STORE_SCREENSHOTS
        guard !AppStoreScreenshotFixture.isActive else { return }
#endif
        appIsInBackground = false
        if let restoreTask { await restoreTask.value }
        if protectedLocalStateRecoveryBlocked {
            await retryProtectedLocalStateRecovery()
        }
        guard !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked
        else { return }
        if isSignedIn,
           accountSetupStep == nil,
           biometricUnlockEnabled,
           biometricAccessState == .locked,
           !biometricAuthenticationInProgress {
            guard await authenticateBiometrically(for: .returningSignIn) else { return }
            await resumeAuthenticatedSessionIfNeeded()
        }
        applicationDidBecomeActive()
        // Re-arm process-death recovery without bypassing the durable push backoff. Notification
        // opens waiting for biometric/session restoration receive one account-fenced replay here.
        NotificationCoordinator.shared.replayCurrentPushTokens()
        await MessageNotificationActionDispatcher.shared.replayPending()
        await ClaimablePaymentNotificationActionDispatcher.shared.replayPending()
        scheduleForegroundAuthoritativeRefreshIfNeeded()
    }

    /// Starts at most one foreground bootstrap task. The request remains pending when the phone is
    /// offline and is retried by the next foreground callback; the connectivity recovery path also
    /// performs an authoritative refresh as soon as a usable path returns.
    private func scheduleForegroundAuthoritativeRefreshIfNeeded() {
        guard foregroundAuthoritativeRefreshGate.hasPendingRefresh,
              foregroundAuthoritativeRefreshTask == nil
        else { return }
        let taskID = UUID()
        foregroundAuthoritativeRefreshTaskID = taskID
        foregroundAuthoritativeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainForegroundAuthoritativeRefresh()
            self.finishForegroundAuthoritativeRefreshTask(taskID)
        }
    }

    private func drainForegroundAuthoritativeRefresh() async {
        while !Task.isCancelled {
            let sessionIsEligible = AuthenticatedProjectionRefreshPolicy.permits(
                isSigningOut: isSigningOut,
                isSignedIn: isSignedIn,
                isOnline: isOnline,
                accountSetupComplete: accountSetupStep == nil,
                isSubmittingAccountDeletion: isSubmittingAccountDeletion,
                acceptedAccountDeletionCleanupBlocked: acceptedAccountDeletionCleanupBlocked,
                protectedLocalStateRecoveryBlocked: protectedLocalStateRecoveryBlocked,
                unresolvedAccountDeletionAttemptBlocked: unresolvedAccountDeletionAttemptBlocked
            ) && !requiresBiometricSignIn
            switch foregroundAuthoritativeRefreshGate.admission(
                at: Date(),
                appIsActive: !appIsInBackground,
                isOnline: isOnline,
                sessionIsEligible: sessionIsEligible
            ) {
            case .none:
                return
            case .wait(let delay):
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                } catch {
                    return
                }
            case .start(let generation):
                await refresh()
                if !didResumeAuthenticatedSession,
                   communicationAccessGranted,
                   appReviewDemoMutationsAllowed,
                   capabilities != nil {
                    // If launch resume stopped at a transient discovery failure, a later
                    // foreground refresh must complete registration and communication recovery
                    // rather than merely repopulating the capability value.
                    await resumeAuthenticatedSessionIfNeeded()
                }
                let committed = foregroundAuthoritativeRefreshGate.hasCompleted(
                    generation: generation
                )
                foregroundAuthoritativeRefreshGate.finishAttempt(generation: generation)
                // Do not spin against a transient bootstrap failure. The generation remains
                // pending for connectivity recovery or the next true foreground transition.
                if !committed { return }
            }
        }
    }

    private func finishForegroundAuthoritativeRefreshTask(_ taskID: UUID) {
        guard foregroundAuthoritativeRefreshTaskID == taskID else { return }
        foregroundAuthoritativeRefreshTask = nil
        foregroundAuthoritativeRefreshTaskID = nil
    }

    private func resetForegroundAuthoritativeRefresh() {
        foregroundAuthoritativeRefreshTask?.cancel()
        foregroundAuthoritativeRefreshTask = nil
        foregroundAuthoritativeRefreshTaskID = nil
        foregroundAuthoritativeRefreshGate.reset()
    }

    func homeDidBecomeActive() async {
        guard selectedTab == MainTabIndex.home,
              isSignedIn,
              accountSetupStep == nil,
              !requiresBiometricSignIn
        else { return }
        guard biometricUnlockEnabled else {
            homeBiometricState = .notRequired
            return
        }
        guard homeBiometricState != .authorized else { return }
        _ = await authenticateBiometrically(for: .home)
    }

    func homeDidResignActive() {
        homeBiometricAuthorizationFence.invalidate()
        guard biometricUnlockEnabled else {
            homeBiometricState = .notRequired
            return
        }
        homeBiometricState = .locked
    }

    func authorizePaymentRequestSubmission() async -> Bool {
        guard appReviewDemoMutationsAllowed,
              isSignedIn,
              financialAccessGranted,
              !requiresBiometricSignIn
        else { return false }
        guard biometricUnlockEnabled else { return true }
        return await authenticateBiometrically(for: .paymentRequest)
    }

    /// Commits an exact, account-bound transfer intent before the financial POST and retains it
    /// until the server-confirmed card is durable in the normal E2EE outbox. The step-up bearer
    /// token is deliberately never copied into protected state. Retrying an ambiguous result
    /// obtains a fresh approval but reuses the journal's deterministic idempotency key.
    func submitTransferWithDurableChatReceipt(
        from wallet: Wallet,
        to contact: WalletContactDTO,
        amount: String,
        note: String?,
        conversationID rawConversationID: String?,
        stepUpToken: String
    ) async throws -> WalletTransaction {
        guard appReviewDemoMutationsAllowed,
              isSignedIn,
              isOnline,
              accountSetupStep == nil,
              !requiresBiometricSignIn,
              financialAccessGranted,
              !stepUpToken.isEmpty,
              let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId,
              let currentWallet = state.wallets.first(where: {
                  $0.id.caseInsensitiveCompare(wallet.id) == .orderedSame
                      && $0.currency == wallet.currency
              }),
              let destinationWalletID = contact.receivingWalletId,
              let recipientUserID = ContactRecipientDirectory.recipientUserId(for: contact)
        else { throw TransferChatReceiptRecoveryError.invalidIntent }

        let conversationID: String?
        if let rawConversationID {
            guard let identifier = UUID(
                uuidString: rawConversationID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ) else { throw TransferChatReceiptRecoveryError.invalidIntent }
            let canonical = identifier.uuidString.lowercased()
            let owner = UUID(uuidString: expectedUserID)?.uuidString.lowercased()
            guard let owner,
                  let conversation = state.conversations.first(where: {
                      $0.id.caseInsensitiveCompare(canonical) == .orderedSame
                  }),
                  !conversation.isGroup,
                  Set(conversation.participantUserIds.compactMap {
                      UUID(uuidString: $0)?.uuidString.lowercased()
                  }) == Set([owner, recipientUserID])
            else { throw TransferChatReceiptRecoveryError.invalidIntent }
            conversationID = canonical
        } else {
            conversationID = nil
        }

        guard let candidate = TransferChatReceiptRecoveryRecord(
            ownerUserID: expectedUserID,
            sourceWalletID: currentWallet.id,
            destinationWalletID: destinationWalletID,
            recipientUserID: recipientUserID,
            recipientName: contact.name,
            conversationID: conversationID,
            amount: amount,
            currency: currentWallet.currency,
            note: note
        ) else { throw TransferChatReceiptRecoveryError.invalidIntent }

        let expectedAccountEpoch = accountEpoch
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { throw TransferChatReceiptRecoveryError.accountChanged }

        var recovery: TransferChatReceiptRecoveryRecord?
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw TransferChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingTransferChatReceipts ?? []
            guard let selected = TransferChatReceiptRecoveryPolicy.insertOrReuse(
                candidate,
                in: &records
            ) else { throw TransferChatReceiptRecoveryError.recoveryCapacityReached }
            persisted.pendingTransferChatReceipts = records
            recovery = selected
        }
        guard let recovery else { throw TransferChatReceiptRecoveryError.invalidIntent }
        await publishLatestState()

        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else {
            await discardPreparedTransferChatReceipt(
                recovery.id,
                ownerUserID: expectedUserID
            )
            throw TransferChatReceiptRecoveryError.accountChanged
        }

        // A prior attempt crossed the durable submitted boundary. Resolve that exact key and
        // payload first; only an authoritative not-found response allows this fresh approval to
        // submit the mutation again.
        if recovery.phase != .prepared {
            do {
                let recovered = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.recoverTransfer(
                        walletId: recovery.sourceWalletID,
                        destinationWalletId: recovery.destinationWalletID,
                        amount: recovery.amount,
                        note: recovery.note,
                        idempotencyKey: recovery.idempotencyKey
                    )
                }
                try await confirmTransferChatReceipt(
                    recovered,
                    recovery: recovery,
                    evidence: .exactRecovery,
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
                await recoverAndDrainFinancialChatReceipts()
                return recovered
            } catch {
                guard recovery.phase == .submitted,
                      TransferChatReceiptRecoveryPolicy.recoveryDecision(for: error)
                        == .notCommitted
                else { throw error }
            }
        }

        // This durable transition is the point of no return for cleanup. A crash after this write
        // is recovered by the exact read-only endpoint; no background path repeats the transfer.
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw TransferChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingTransferChatReceipts ?? []
            if recovery.phase == .prepared {
                guard TransferChatReceiptRecoveryPolicy.markSubmitted(
                    recordID: recovery.id,
                    in: &records
                ) else { throw TransferChatReceiptRecoveryError.unconfirmedTransfer }
            } else {
                guard records.contains(where: {
                    $0.id == recovery.id && $0.phase == .submitted
                }) else { throw TransferChatReceiptRecoveryError.unconfirmedTransfer }
            }
            persisted.pendingTransferChatReceipts = records
        }
        await publishLatestState()

        do {
            let transaction = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.transfer(
                    walletId: recovery.sourceWalletID,
                    destinationWalletId: recovery.destinationWalletID,
                    amount: recovery.amount,
                    note: recovery.note,
                    idempotencyKey: recovery.idempotencyKey,
                    stepUpToken: stepUpToken
                )
            }
            try await confirmTransferChatReceipt(
                transaction,
                recovery: recovery,
                evidence: .directResponse,
                accountEpoch: expectedAccountEpoch,
                ownerUserID: expectedUserID,
                sessionID: expectedSessionID
            )
            await recoverAndDrainFinancialChatReceipts()
            return transaction
        } catch {
            if TransferChatReceiptRecoveryPolicy.isDefinitiveRejection(error),
               await outboxContextIsCurrent(
                   accountEpoch: expectedAccountEpoch,
                   userID: expectedUserID,
                   sessionID: expectedSessionID
               ) {
                await retireUncommittedTransferChatReceipt(
                    recovery.id,
                    ownerUserID: expectedUserID
                )
            }
            throw error
        }
    }

    /// Used only before a POST or after an authoritative server rejection. Every ambiguous result
    /// keeps its frozen idempotency authority for exact recovery or a verbatim explicit retry.
    private func confirmTransferChatReceipt(
        _ transaction: WalletTransaction,
        recovery: TransferChatReceiptRecoveryRecord,
        evidence: TransferChatReceiptConfirmation.Evidence,
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async throws {
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { throw TransferChatReceiptRecoveryError.accountChanged }
        guard let confirmation = TransferChatReceiptConfirmation(
            transaction: transaction,
            recovery: recovery,
            evidence: evidence
        ) else { throw TransferChatReceiptRecoveryError.unconfirmedTransfer }
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw TransferChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingTransferChatReceipts ?? []
            guard TransferChatReceiptRecoveryPolicy.storeConfirmation(
                confirmation,
                for: recovery.id,
                in: &records
            ) else { throw TransferChatReceiptRecoveryError.unconfirmedTransfer }
            persisted.pendingTransferChatReceipts = records
        }
        await publishLatestState()
    }

    private func discardPreparedTransferChatReceipt(
        _ recordID: UUID,
        ownerUserID: String
    ) async {
        do {
            try await store.update { persisted in
                guard persisted.communicationOwnerUserID?.caseInsensitiveCompare(ownerUserID)
                        == .orderedSame,
                      persisted.profile.map({
                          $0.id.caseInsensitiveCompare(ownerUserID) == .orderedSame
                      }) ?? true
                else { return }
                var records = persisted.pendingTransferChatReceipts ?? []
                records.removeAll { $0.id == recordID && $0.phase == .prepared }
                persisted.pendingTransferChatReceipts = records.isEmpty ? nil : records
            }
            await publishLatestState()
        } catch {
            // A failed cleanup is harmless: prepared records cannot trigger an automatic POST and
            // are the only phase eligible for age-based pruning.
        }
    }

    private func retireUncommittedTransferChatReceipt(
        _ recordID: UUID,
        ownerUserID: String
    ) async {
        do {
            try await store.update { persisted in
                guard persisted.communicationOwnerUserID?.caseInsensitiveCompare(ownerUserID)
                        == .orderedSame
                else { return }
                var records = persisted.pendingTransferChatReceipts ?? []
                _ = TransferChatReceiptRecoveryPolicy.retireNotCommitted(
                    recordID: recordID,
                    in: &records
                )
                persisted.pendingTransferChatReceipts = records.isEmpty ? nil : records
            }
            await publishLatestState()
        } catch {
            // Retaining a proven-uncommitted key is safe and preserves fail-closed behavior.
        }
    }

    /// Immediate requests persist their exact financial/chat intent before submission. Scheduled
    /// requests deliberately continue through the lower-level create method below because their
    /// existing outbox payload already persists the exact server confirmation before messaging.
    func createPaymentRequestWithDurableChatReceipt(
        destinationWalletID: String,
        requestedFromUserID: String,
        recipientName: String,
        conversationID rawConversationID: String?,
        amount: String,
        note: String?,
        idempotencyKey: String
    ) async throws -> PaymentRequestDTO {
        guard appReviewDemoMutationsAllowed,
              isSignedIn,
              isOnline,
              accountSetupStep == nil,
              !requiresBiometricSignIn,
              financialAccessGranted,
              let expectedWallet = state.wallets.first(where: {
                  $0.id.caseInsensitiveCompare(destinationWalletID) == .orderedSame
              }),
              let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId,
              let recipientUUID = UUID(
                  uuidString: requestedFromUserID.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              recipientUUID.uuidString.caseInsensitiveCompare(expectedUserID) != .orderedSame
        else { throw PaymentRequestSubmissionError.invalidRecipient }
        let recipientUserID = recipientUUID.uuidString.lowercased()
        let conversationID: String?
        if let rawConversationID {
            guard let canonical = FinancialRecoveryValidation.canonicalUUID(rawConversationID),
                  directConversationIsBound(
                      canonical,
                      ownerUserID: expectedUserID,
                      peerUserID: recipientUserID
                  )
            else { throw PaymentRequestSubmissionError.invalidRecipient }
            conversationID = canonical
        } else {
            conversationID = nil
        }
        guard let candidate = PaymentRequestChatReceiptRecoveryRecord(
            ownerUserID: expectedUserID,
            destinationWalletID: expectedWallet.id,
            recipientUserID: recipientUserID,
            recipientName: recipientName,
            conversationID: conversationID,
            amount: amount,
            currency: expectedWallet.currency,
            note: note,
            idempotencyKey: idempotencyKey
        ) else { throw PaymentRequestSubmissionError.invalidRecipient }

        let expectedAccountEpoch = accountEpoch
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { throw PaymentRequestSubmissionError.accountChanged }

        var recovery: PaymentRequestChatReceiptRecoveryRecord?
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw PaymentRequestSubmissionError.accountChanged }
            var records = persisted.pendingPaymentRequestChatReceipts ?? []
            guard let selected = PaymentRequestChatReceiptRecoveryPolicy.insertOrReuse(
                candidate,
                in: &records
            ) else { throw PaymentRequestSubmissionError.recoveryCapacityReached }
            persisted.pendingPaymentRequestChatReceipts = records
            recovery = selected
        }
        guard let recovery else { throw PaymentRequestSubmissionError.unconfirmedRequest }
        await publishLatestState()

        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else {
            await discardPreparedPaymentRequestChatReceipt(
                recovery.id,
                ownerUserID: expectedUserID
            )
            throw PaymentRequestSubmissionError.accountChanged
        }

        if recovery.phase != .prepared {
            do {
                let request = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.recoverPaymentRequestCreation(
                        destinationWalletId: recovery.destinationWalletID,
                        requestedFromUserId: recovery.recipientUserID,
                        amount: recovery.amount,
                        note: recovery.note,
                        expiresAt: recovery.expiresAt,
                        idempotencyKey: recovery.idempotencyKey
                    )
                }
                try await confirmPaymentRequestChatReceipt(
                    request,
                    recovery: recovery,
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
                await recoverAndDrainFinancialChatReceipts()
                return request
            } catch {
                guard recovery.phase == .submitted,
                      PaymentRequestChatReceiptRecoveryPolicy.recoveryDecision(for: error)
                        == .notCommitted
                else { throw error }
            }
        }

        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw PaymentRequestSubmissionError.accountChanged }
            var records = persisted.pendingPaymentRequestChatReceipts ?? []
            if recovery.phase == .prepared {
                guard PaymentRequestChatReceiptRecoveryPolicy.markSubmitted(
                    recordID: recovery.id,
                    in: &records
                ) else { throw PaymentRequestSubmissionError.unconfirmedRequest }
            } else {
                guard records.contains(where: {
                    $0.id == recovery.id && $0.phase == .submitted
                }) else { throw PaymentRequestSubmissionError.unconfirmedRequest }
            }
            persisted.pendingPaymentRequestChatReceipts = records
        }
        await publishLatestState()

        do {
            let request = try await createPaymentRequest(
                destinationWalletID: recovery.destinationWalletID,
                requestedFromUserID: recovery.recipientUserID,
                amount: recovery.amount,
                note: recovery.note,
                idempotencyKey: recovery.idempotencyKey
            )
            try await confirmPaymentRequestChatReceipt(
                request,
                recovery: recovery,
                accountEpoch: expectedAccountEpoch,
                ownerUserID: expectedUserID,
                sessionID: expectedSessionID
            )
            await recoverAndDrainFinancialChatReceipts()
            return request
        } catch {
            if FinancialChatReceiptRecoveryPolicy.mutationWasDefinitivelyRejected(error),
               await outboxContextIsCurrent(
                   accountEpoch: expectedAccountEpoch,
                   userID: expectedUserID,
                   sessionID: expectedSessionID
               ) {
                await retireUncommittedPaymentRequestChatReceipt(
                    recovery.id,
                    ownerUserID: expectedUserID
                )
            }
            throw error
        }
    }

    /// Creates a financial request only for the authenticated account/session captured before the
    /// network call. Scheduled outbox execution uses this lower-level path.
    func createPaymentRequest(
        destinationWalletID: String,
        requestedFromUserID: String,
        amount: String,
        note: String?,
        idempotencyKey: String
    ) async throws -> PaymentRequestDTO {
        guard appReviewDemoMutationsAllowed else {
            throw AppReviewDemoMutationError.readOnly
        }
        guard isSignedIn,
              isOnline,
              accountSetupStep == nil,
              !requiresBiometricSignIn,
              financialAccessGranted,
              let expectedWallet = state.wallets.first(where: {
                  $0.id.caseInsensitiveCompare(destinationWalletID) == .orderedSame
              }),
              let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId,
              let recipientUUID = UUID(
                  uuidString: requestedFromUserID.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              recipientUUID.uuidString.caseInsensitiveCompare(expectedUserID) != .orderedSame
        else { throw PaymentRequestSubmissionError.invalidRecipient }
        let expectedAccountEpoch = accountEpoch
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { throw PaymentRequestSubmissionError.accountChanged }
        let canonicalRecipient = recipientUUID.uuidString.lowercased()

        let request = try await APIClientSessionBinding.$sessionID.withValue(expectedSessionID) {
            try await api.createPaymentRequest(
                destinationWalletId: destinationWalletID,
                requestedFromUserId: canonicalRecipient,
                amount: amount,
                note: note,
                idempotencyKey: idempotencyKey
            )
        }
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { throw PaymentRequestSubmissionError.accountChanged }
        guard UUID(uuidString: request.id) != nil,
              request.type == "payment_request",
              request.knownStatus == .pending,
              request.destinationWalletId.caseInsensitiveCompare(destinationWalletID)
                == .orderedSame,
              request.requestedFromUserId?.caseInsensitiveCompare(canonicalRecipient)
                == .orderedSame,
              request.amount == amount,
              request.currency == expectedWallet.currency,
              KitPaymentMessage(action: .request, paymentRequest: request) != nil
        else { throw PaymentRequestSubmissionError.unconfirmedRequest }
        return request
    }

    private func confirmPaymentRequestChatReceipt(
        _ request: PaymentRequestDTO,
        recovery: PaymentRequestChatReceiptRecoveryRecord,
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async throws {
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ), let confirmation = PaymentRequestChatReceiptConfirmation(
            request: request,
            recovery: recovery
        ) else { throw PaymentRequestSubmissionError.unconfirmedRequest }
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw PaymentRequestSubmissionError.accountChanged }
            var records = persisted.pendingPaymentRequestChatReceipts ?? []
            guard PaymentRequestChatReceiptRecoveryPolicy.storeConfirmation(
                confirmation,
                for: recovery.id,
                in: &records
            ) else { throw PaymentRequestSubmissionError.unconfirmedRequest }
            persisted.pendingPaymentRequestChatReceipts = records
        }
        await publishLatestState()
    }

    private func discardPreparedPaymentRequestChatReceipt(
        _ recordID: UUID,
        ownerUserID: String
    ) async {
        await removePaymentRequestChatReceipt(
            recordID,
            ownerUserID: ownerUserID,
            onlyPrepared: true
        )
    }

    private func retireUncommittedPaymentRequestChatReceipt(
        _ recordID: UUID,
        ownerUserID: String
    ) async {
        await removePaymentRequestChatReceipt(
            recordID,
            ownerUserID: ownerUserID,
            onlyPrepared: false
        )
    }

    private func removePaymentRequestChatReceipt(
        _ recordID: UUID,
        ownerUserID: String,
        onlyPrepared: Bool
    ) async {
        do {
            try await store.update { persisted in
                guard persisted.communicationOwnerUserID?.caseInsensitiveCompare(ownerUserID)
                        == .orderedSame
                else { return }
                var records = persisted.pendingPaymentRequestChatReceipts ?? []
                if onlyPrepared {
                    records.removeAll { $0.id == recordID && $0.phase == .prepared }
                } else {
                    _ = PaymentRequestChatReceiptRecoveryPolicy.retireNotCommitted(
                        recordID: recordID,
                        in: &records
                    )
                }
                persisted.pendingPaymentRequestChatReceipts = records.isEmpty ? nil : records
            }
            await publishLatestState()
        } catch {
            // Retention is fail-closed and cannot move money by itself.
        }
    }

    private func directConversationIsBound(
        _ conversationID: String,
        ownerUserID: String,
        peerUserID: String
    ) -> Bool {
        guard let owner = FinancialRecoveryValidation.canonicalUUID(ownerUserID),
              let peer = FinancialRecoveryValidation.canonicalUUID(peerUserID),
              let conversation = state.conversations.first(where: {
                  $0.id.caseInsensitiveCompare(conversationID) == .orderedSame
              }),
              !conversation.isGroup
        else { return false }
        return Set(conversation.participantUserIds.compactMap(
            { FinancialRecoveryValidation.canonicalUUID($0) }
        )) == Set([owner, peer])
    }

    func submitGroupPaymentWithDurableChatReceipt(
        conversationID: String,
        body: CreateGroupPaymentBody,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> GroupPaymentDTO {
        guard appReviewDemoMutationsAllowed,
              isSignedIn,
              isOnline,
              accountSetupStep == nil,
              !requiresBiometricSignIn,
              financialAccessGranted,
              !stepUpToken.isEmpty,
              let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId,
              let conversation = state.conversations.first(where: {
                  $0.id.caseInsensitiveCompare(conversationID) == .orderedSame
              }),
              conversation.isGroup,
              let wallet = state.wallets.first(where: {
                  $0.id.caseInsensitiveCompare(body.sourceWalletId) == .orderedSame
              })
        else { throw FinancialChatReceiptRecoveryError.invalidIntent }
        let owner = FinancialRecoveryValidation.canonicalUUID(expectedUserID)
        let expectedRecipients: [String]
        if let requested = body.recipients {
            expectedRecipients = requested.compactMap {
                FinancialRecoveryValidation.canonicalUUID($0.userId)
            }
        } else {
            expectedRecipients = conversation.participantUserIds.compactMap {
                FinancialRecoveryValidation.canonicalUUID($0)
            }.filter { $0 != owner }
        }
        guard let candidate = GroupPaymentChatReceiptRecoveryRecord(
            ownerUserID: expectedUserID,
            conversationID: conversation.id,
            expectedRecipientUserIDs: expectedRecipients,
            currency: wallet.currency,
            body: body,
            idempotencyKey: idempotencyKey
        ) else { throw FinancialChatReceiptRecoveryError.invalidIntent }

        let expectedAccountEpoch = accountEpoch
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { throw FinancialChatReceiptRecoveryError.accountChanged }
        var recovery: GroupPaymentChatReceiptRecoveryRecord?
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw FinancialChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingGroupPaymentChatReceipts ?? []
            guard let selected = GroupPaymentChatReceiptRecoveryPolicy.insertOrReuse(
                candidate,
                in: &records
            ) else { throw FinancialChatReceiptRecoveryError.recoveryCapacityReached }
            persisted.pendingGroupPaymentChatReceipts = records
            recovery = selected
        }
        guard let recovery else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
        await publishLatestState()

        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else {
            await removePreparedGroupPaymentChatReceipt(recovery.id, ownerUserID: expectedUserID)
            throw FinancialChatReceiptRecoveryError.accountChanged
        }

        if recovery.phase != .prepared {
            do {
                let payment = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.recoverGroupPaymentCreation(
                        conversationId: recovery.conversationID,
                        body: recovery.body,
                        idempotencyKey: recovery.idempotencyKey
                    )
                }
                try await confirmGroupPaymentChatReceipt(
                    payment,
                    recovery: recovery,
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
                await recoverAndDrainFinancialChatReceipts()
                return payment
            } catch {
                guard recovery.phase == .submitted,
                      GroupPaymentChatReceiptRecoveryPolicy.recoveryDecision(for: error)
                        == .notCommitted
                else { throw error }
            }
        }

        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw FinancialChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingGroupPaymentChatReceipts ?? []
            if recovery.phase == .prepared {
                guard GroupPaymentChatReceiptRecoveryPolicy.markSubmitted(
                    recordID: recovery.id,
                    in: &records
                ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
            } else {
                guard records.contains(where: {
                    $0.id == recovery.id && $0.phase == .submitted
                }) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
            }
            persisted.pendingGroupPaymentChatReceipts = records
        }
        await publishLatestState()

        do {
            let payment = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.createGroupPayment(
                    conversationId: recovery.conversationID,
                    body: recovery.body,
                    idempotencyKey: recovery.idempotencyKey,
                    stepUpToken: stepUpToken
                )
            }
            try await confirmGroupPaymentChatReceipt(
                payment,
                recovery: recovery,
                accountEpoch: expectedAccountEpoch,
                ownerUserID: expectedUserID,
                sessionID: expectedSessionID
            )
            await recoverAndDrainFinancialChatReceipts()
            return payment
        } catch {
            if FinancialChatReceiptRecoveryPolicy.mutationWasDefinitivelyRejected(error),
               await outboxContextIsCurrent(
                   accountEpoch: expectedAccountEpoch,
                   userID: expectedUserID,
                   sessionID: expectedSessionID
               ) {
                await retireUncommittedGroupPaymentChatReceipt(
                    recovery.id,
                    ownerUserID: expectedUserID
                )
            }
            throw error
        }
    }

    func submitGroupContributionWithDurableChatReceipt(
        request: GroupPaymentRequestDTO,
        conversationID: String,
        announcementSenderUserID: String,
        sourceWallet: Wallet,
        amount: String,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> GroupPaymentRequestContributionResultDTO {
        guard appReviewDemoMutationsAllowed,
              isSignedIn,
              isOnline,
              accountSetupStep == nil,
              !requiresBiometricSignIn,
              financialAccessGranted,
              !stepUpToken.isEmpty,
              let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId,
              let conversation = state.conversations.first(where: {
                  $0.id.caseInsensitiveCompare(conversationID) == .orderedSame
              }),
              conversation.isGroup,
              conversation.participantUserIds.contains(where: {
                  $0.caseInsensitiveCompare(expectedUserID) == .orderedSame
              }),
              request.isStructurallyValid,
              GroupPaymentRequestAuthorityPolicy.matchesContext(
                  request,
                  conversationID: conversation.id,
                  announcementSenderID: announcementSenderUserID
              ),
              request.requesterUserId.caseInsensitiveCompare(expectedUserID) != .orderedSame,
              state.wallets.contains(where: {
                  $0.id.caseInsensitiveCompare(sourceWallet.id) == .orderedSame
                      && $0.currency == sourceWallet.currency
              }),
              request.currency == sourceWallet.currency
        else { throw FinancialChatReceiptRecoveryError.invalidIntent }
        guard let candidate = GroupContributionChatReceiptRecoveryRecord(
            ownerUserID: expectedUserID,
            conversationID: conversation.id,
            announcementSenderUserID: announcementSenderUserID,
            requestID: request.id,
            sourceWalletID: sourceWallet.id,
            amount: amount,
            currency: request.currency,
            idempotencyKey: idempotencyKey
        ) else { throw FinancialChatReceiptRecoveryError.invalidIntent }

        let expectedAccountEpoch = accountEpoch
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { throw FinancialChatReceiptRecoveryError.accountChanged }
        var recovery: GroupContributionChatReceiptRecoveryRecord?
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw FinancialChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingGroupContributionChatReceipts ?? []
            guard let selected = GroupContributionChatReceiptRecoveryPolicy.insertOrReuse(
                candidate,
                in: &records
            ) else { throw FinancialChatReceiptRecoveryError.recoveryCapacityReached }
            persisted.pendingGroupContributionChatReceipts = records
            recovery = selected
        }
        guard let recovery else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
        await publishLatestState()

        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else {
            await removePreparedGroupContributionChatReceipt(
                recovery.id,
                ownerUserID: expectedUserID
            )
            throw FinancialChatReceiptRecoveryError.accountChanged
        }

        if recovery.phase != .prepared {
            do {
                let result = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.recoverGroupPaymentRequestContribution(
                        id: recovery.requestID,
                        sourceWalletId: recovery.sourceWalletID,
                        amount: recovery.amount,
                        idempotencyKey: recovery.idempotencyKey
                    )
                }
                try await confirmGroupContributionChatReceipt(
                    result,
                    recovery: recovery,
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
                await recoverAndDrainFinancialChatReceipts()
                return result
            } catch {
                guard recovery.phase == .submitted,
                      GroupContributionChatReceiptRecoveryPolicy.recoveryDecision(for: error)
                        == .notCommitted
                else { throw error }
            }
        }

        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw FinancialChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingGroupContributionChatReceipts ?? []
            if recovery.phase == .prepared {
                guard GroupContributionChatReceiptRecoveryPolicy.markSubmitted(
                    recordID: recovery.id,
                    in: &records
                ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
            } else {
                guard records.contains(where: {
                    $0.id == recovery.id && $0.phase == .submitted
                }) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
            }
            persisted.pendingGroupContributionChatReceipts = records
        }
        await publishLatestState()

        do {
            let result = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.contributeToGroupPaymentRequest(
                    id: recovery.requestID,
                    sourceWalletId: recovery.sourceWalletID,
                    amount: recovery.amount,
                    idempotencyKey: recovery.idempotencyKey,
                    stepUpToken: stepUpToken
                )
            }
            try await confirmGroupContributionChatReceipt(
                result,
                recovery: recovery,
                accountEpoch: expectedAccountEpoch,
                ownerUserID: expectedUserID,
                sessionID: expectedSessionID
            )
            await recoverAndDrainFinancialChatReceipts()
            return result
        } catch {
            if FinancialChatReceiptRecoveryPolicy.mutationWasDefinitivelyRejected(error),
               await outboxContextIsCurrent(
                   accountEpoch: expectedAccountEpoch,
                   userID: expectedUserID,
                   sessionID: expectedSessionID
               ) {
                await retireUncommittedGroupContributionChatReceipt(
                    recovery.id,
                    ownerUserID: expectedUserID
                )
            }
            throw error
        }
    }

    private func confirmGroupPaymentChatReceipt(
        _ payment: GroupPaymentDTO,
        recovery: GroupPaymentChatReceiptRecoveryRecord,
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async throws {
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ), let confirmation = GroupPaymentChatReceiptConfirmation(
            payment: payment,
            recovery: recovery
        ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw FinancialChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingGroupPaymentChatReceipts ?? []
            guard GroupPaymentChatReceiptRecoveryPolicy.storeConfirmation(
                confirmation,
                for: recovery.id,
                in: &records
            ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
            persisted.pendingGroupPaymentChatReceipts = records
        }
        await publishLatestState()
    }

    private func confirmGroupContributionChatReceipt(
        _ result: GroupPaymentRequestContributionResultDTO,
        recovery: GroupContributionChatReceiptRecoveryRecord,
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async throws {
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ), let confirmation = GroupContributionChatReceiptConfirmation(
            result: result,
            recovery: recovery
        ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw FinancialChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingGroupContributionChatReceipts ?? []
            guard GroupContributionChatReceiptRecoveryPolicy.storeConfirmation(
                confirmation,
                for: recovery.id,
                in: &records
            ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
            persisted.pendingGroupContributionChatReceipts = records
        }
        await publishLatestState()
    }

    private func removePreparedGroupPaymentChatReceipt(
        _ recordID: UUID,
        ownerUserID: String
    ) async {
        await mutateGroupPaymentChatReceipts(ownerUserID: ownerUserID) { records in
            records.removeAll { $0.id == recordID && $0.phase == .prepared }
        }
    }

    private func retireUncommittedGroupPaymentChatReceipt(
        _ recordID: UUID,
        ownerUserID: String
    ) async {
        await mutateGroupPaymentChatReceipts(ownerUserID: ownerUserID) { records in
            _ = GroupPaymentChatReceiptRecoveryPolicy.retireNotCommitted(
                recordID: recordID,
                in: &records
            )
        }
    }

    private func mutateGroupPaymentChatReceipts(
        ownerUserID: String,
        _ mutation: (inout [GroupPaymentChatReceiptRecoveryRecord]) -> Void
    ) async {
        do {
            try await store.update { persisted in
                guard persisted.communicationOwnerUserID?.caseInsensitiveCompare(ownerUserID)
                        == .orderedSame
                else { return }
                var records = persisted.pendingGroupPaymentChatReceipts ?? []
                mutation(&records)
                persisted.pendingGroupPaymentChatReceipts = records.isEmpty ? nil : records
            }
            await publishLatestState()
        } catch {}
    }

    private func removePreparedGroupContributionChatReceipt(
        _ recordID: UUID,
        ownerUserID: String
    ) async {
        await mutateGroupContributionChatReceipts(ownerUserID: ownerUserID) { records in
            records.removeAll { $0.id == recordID && $0.phase == .prepared }
        }
    }

    private func retireUncommittedGroupContributionChatReceipt(
        _ recordID: UUID,
        ownerUserID: String
    ) async {
        await mutateGroupContributionChatReceipts(ownerUserID: ownerUserID) { records in
            _ = GroupContributionChatReceiptRecoveryPolicy.retireNotCommitted(
                recordID: recordID,
                in: &records
            )
        }
    }

    private func mutateGroupContributionChatReceipts(
        ownerUserID: String,
        _ mutation: (inout [GroupContributionChatReceiptRecoveryRecord]) -> Void
    ) async {
        do {
            try await store.update { persisted in
                guard persisted.communicationOwnerUserID?.caseInsensitiveCompare(ownerUserID)
                        == .orderedSame
                else { return }
                var records = persisted.pendingGroupContributionChatReceipts ?? []
                mutation(&records)
                persisted.pendingGroupContributionChatReceipts = records.isEmpty ? nil : records
            }
            await publishLatestState()
        } catch {}
    }

    func payPaymentRequestWithDurableChatReceipt(
        _ request: PaymentRequestDTO,
        descriptor: KitPaymentMessage,
        from wallet: Wallet,
        conversationID: String,
        recipientUserID: String,
        recipientName: String,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> PaymentRequestDTO {
        try await submitPaymentRequestResolutionWithDurableChatReceipt(
            request,
            descriptor: descriptor,
            sourceWallet: wallet,
            conversationID: conversationID,
            recipientUserID: recipientUserID,
            recipientName: recipientName,
            operation: .paid,
            idempotencyKey: idempotencyKey
        ) { recovery in
            guard !stepUpToken.isEmpty, let sourceWalletID = recovery.sourceWalletID else {
                throw FinancialChatReceiptRecoveryError.invalidIntent
            }
            return try await self.api.payPaymentRequest(
                requestId: recovery.requestID,
                sourceWalletId: sourceWalletID,
                idempotencyKey: recovery.idempotencyKey,
                stepUpToken: stepUpToken
            )
        }
    }

    func cancelPaymentRequestWithDurableChatReceipt(
        _ request: PaymentRequestDTO,
        descriptor: KitPaymentMessage,
        conversationID: String,
        recipientUserID: String,
        recipientName: String,
        idempotencyKey: String
    ) async throws -> PaymentRequestDTO {
        try await submitPaymentRequestResolutionWithDurableChatReceipt(
            request,
            descriptor: descriptor,
            sourceWallet: nil,
            conversationID: conversationID,
            recipientUserID: recipientUserID,
            recipientName: recipientName,
            operation: .cancelled,
            idempotencyKey: idempotencyKey
        ) { recovery in
            try await self.api.cancelPaymentRequest(
                requestId: recovery.requestID,
                idempotencyKey: recovery.idempotencyKey
            )
        }
    }

    private func submitPaymentRequestResolutionWithDurableChatReceipt(
        _ request: PaymentRequestDTO,
        descriptor: KitPaymentMessage,
        sourceWallet: Wallet?,
        conversationID: String,
        recipientUserID: String,
        recipientName: String,
        operation: PaymentRequestResolutionRecoveryOperation,
        idempotencyKey: String,
        mutation: (PaymentRequestResolutionChatReceiptRecoveryRecord) async throws
            -> PaymentRequestDTO
    ) async throws -> PaymentRequestDTO {
        guard appReviewDemoMutationsAllowed,
              isSignedIn,
              isOnline,
              accountSetupStep == nil,
              !requiresBiometricSignIn,
              financialAccessGranted,
              let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId,
              directConversationIsBound(
                  conversationID,
                  ownerUserID: expectedUserID,
                  peerUserID: recipientUserID
              ),
              request.knownStatus == .pending,
              descriptor.action == .request,
              descriptor.matchesAuthoritativeRequest(request)
        else { throw FinancialChatReceiptRecoveryError.invalidIntent }
        switch operation {
        case .paid:
            guard request.requestedFromUserId?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame,
                  let sourceWallet,
                  state.wallets.contains(where: {
                      $0.id.caseInsensitiveCompare(sourceWallet.id) == .orderedSame
                          && $0.currency == sourceWallet.currency
                  }),
                  sourceWallet.currency == request.currency
            else { throw FinancialChatReceiptRecoveryError.invalidIntent }
        case .cancelled:
            guard sourceWallet == nil,
                  request.requestedFromUserId?.caseInsensitiveCompare(recipientUserID)
                    == .orderedSame,
                  state.wallets.contains(where: {
                      $0.id.caseInsensitiveCompare(request.destinationWalletId) == .orderedSame
                          && $0.currency == request.currency
                  })
            else { throw FinancialChatReceiptRecoveryError.invalidIntent }
        }
        guard let candidate = PaymentRequestResolutionChatReceiptRecoveryRecord(
            ownerUserID: expectedUserID,
            conversationID: conversationID,
            recipientUserID: recipientUserID,
            recipientName: recipientName,
            request: request,
            descriptor: descriptor,
            sourceWalletID: sourceWallet?.id,
            operation: operation,
            idempotencyKey: idempotencyKey
        ) else { throw FinancialChatReceiptRecoveryError.invalidIntent }

        let expectedAccountEpoch = accountEpoch
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { throw FinancialChatReceiptRecoveryError.accountChanged }
        var recovery: PaymentRequestResolutionChatReceiptRecoveryRecord?
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw FinancialChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingPaymentRequestResolutionChatReceipts ?? []
            guard let selected = PaymentRequestResolutionChatReceiptRecoveryPolicy.insertOrReuse(
                candidate,
                in: &records
            ) else { throw FinancialChatReceiptRecoveryError.recoveryCapacityReached }
            persisted.pendingPaymentRequestResolutionChatReceipts = records
            recovery = selected
        }
        guard let recovery else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
        await publishLatestState()

        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else {
            await removePreparedPaymentRequestResolutionChatReceipt(
                recovery.id,
                ownerUserID: expectedUserID
            )
            throw FinancialChatReceiptRecoveryError.accountChanged
        }

        if recovery.phase != .prepared {
            let latest = try await APIClientSessionBinding.$sessionID.withValue(expectedSessionID) {
                try await api.paymentRequest(id: recovery.requestID)
            }
            if let confirmation = PaymentRequestResolutionChatReceiptConfirmation(
                request: latest,
                recovery: recovery
            ) {
                try await storePaymentRequestResolutionConfirmation(
                    confirmation,
                    recovery: recovery,
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
                await recoverAndDrainFinancialChatReceipts()
                return latest
            }
            guard recovery.phase == .submitted, latest.knownStatus == .pending else {
                throw FinancialChatReceiptRecoveryError.unconfirmedResult
            }
        }

        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw FinancialChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingPaymentRequestResolutionChatReceipts ?? []
            if recovery.phase == .prepared {
                guard PaymentRequestResolutionChatReceiptRecoveryPolicy.markSubmitted(
                    recordID: recovery.id,
                    in: &records
                ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
            } else {
                guard records.contains(where: {
                    $0.id == recovery.id && $0.phase == .submitted
                }) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
            }
            persisted.pendingPaymentRequestResolutionChatReceipts = records
        }
        await publishLatestState()

        do {
            let result = try await APIClientSessionBinding.$sessionID.withValue(expectedSessionID) {
                try await mutation(recovery)
            }
            guard let confirmation = PaymentRequestResolutionChatReceiptConfirmation(
                request: result,
                recovery: recovery
            ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
            try await storePaymentRequestResolutionConfirmation(
                confirmation,
                recovery: recovery,
                accountEpoch: expectedAccountEpoch,
                ownerUserID: expectedUserID,
                sessionID: expectedSessionID
            )
            await recoverAndDrainFinancialChatReceipts()
            return result
        } catch {
            if FinancialChatReceiptRecoveryPolicy.mutationWasDefinitivelyRejected(error),
               await outboxContextIsCurrent(
                   accountEpoch: expectedAccountEpoch,
                   userID: expectedUserID,
                   sessionID: expectedSessionID
               ) {
                await retireUncommittedPaymentRequestResolutionChatReceipt(
                    recovery.id,
                    ownerUserID: expectedUserID
                )
            }
            throw error
        }
    }

    private func storePaymentRequestResolutionConfirmation(
        _ confirmation: PaymentRequestResolutionChatReceiptConfirmation,
        recovery: PaymentRequestResolutionChatReceiptRecoveryRecord,
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async throws {
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { throw FinancialChatReceiptRecoveryError.accountChanged }
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw FinancialChatReceiptRecoveryError.accountChanged }
            var records = persisted.pendingPaymentRequestResolutionChatReceipts ?? []
            guard PaymentRequestResolutionChatReceiptRecoveryPolicy.storeConfirmation(
                confirmation,
                for: recovery.id,
                in: &records
            ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
            persisted.pendingPaymentRequestResolutionChatReceipts = records
        }
        await publishLatestState()
    }

    private func removePreparedPaymentRequestResolutionChatReceipt(
        _ recordID: UUID,
        ownerUserID: String
    ) async {
        await mutatePaymentRequestResolutionChatReceipts(ownerUserID: ownerUserID) { records in
            records.removeAll { $0.id == recordID && $0.phase == .prepared }
        }
    }

    private func retireUncommittedPaymentRequestResolutionChatReceipt(
        _ recordID: UUID,
        ownerUserID: String
    ) async {
        await mutatePaymentRequestResolutionChatReceipts(ownerUserID: ownerUserID) { records in
            _ = PaymentRequestResolutionChatReceiptRecoveryPolicy.retireUncommitted(
                recordID: recordID,
                in: &records
            )
        }
    }

    private func mutatePaymentRequestResolutionChatReceipts(
        ownerUserID: String,
        _ mutation: (inout [PaymentRequestResolutionChatReceiptRecoveryRecord]) -> Void
    ) async {
        do {
            try await store.update { persisted in
                guard persisted.communicationOwnerUserID?.caseInsensitiveCompare(ownerUserID)
                        == .orderedSame
                else { return }
                var records = persisted.pendingPaymentRequestResolutionChatReceipts ?? []
                mutation(&records)
                persisted.pendingPaymentRequestResolutionChatReceipts = records.isEmpty
                    ? nil
                    : records
            }
            await publishLatestState()
        } catch {}
    }

    func authorizeFinancialStepUp(
        purpose: String,
        intent: [String: String?],
        pin: String,
        reason: String
    ) async throws -> StepUpVerificationDTO {
        guard appReviewDemoMutationsAllowed else {
            throw AppReviewDemoMutationError.readOnly
        }
        guard isSignedIn,
              isOnline,
              accountSetupStep == nil,
              !requiresBiometricSignIn,
              financialAccessGranted,
              let expectedUserID = profile?.id
        else { throw APIClientError.signedOut }

        let expectedAccountEpoch = accountEpoch
        // Snapshot the enrolled mode for this attempt. A failed or cancelled biometric
        // signature must never be retried with the PIN behind the user's back.
        let method = KitFinancialStepUpApprovalPolicy.method(
            purpose: purpose,
            biometricsEnabled: biometricUnlockEnabled
        )
        if method == .pin,
           pin.range(of: #"^[0-9]{4}$"#, options: .regularExpression) == nil {
            throw KitFinancialStepUpError.invalidPIN
        }
        let biometricOperationID: UUID?
        if method == .biometricSignature {
            guard let operationID = biometricAuthenticationGate.begin() else {
                throw KitFinancialStepUpError.authorizationInProgress
            }
            biometricOperationID = operationID
            biometricErrorMessage = nil
        } else {
            biometricOperationID = nil
        }
        defer {
            if let biometricOperationID {
                biometricAuthenticationGate.finish(biometricOperationID)
            }
        }

        guard let session = await sessions.current() else {
            throw APIClientError.signedOut
        }
        let expectedSessionID = session.sessionId
        let expectedInstallationID = installationID()
        guard isSignedIn,
              accountEpoch == expectedAccountEpoch,
              profile?.id == expectedUserID
        else { throw KitFinancialStepUpError.accountChanged }

        do {
            let initialChallenge = try await api.createStepUp(
                purpose: purpose,
                intent: intent
            )
            let challenge = try await KitFinancialStepUpChallengeResolver.resolve(
                initial: initialChallenge,
                purpose: purpose,
                intent: intent,
                method: method,
                repairBiometricEnrollment: {
                    try await self.repairServerBiometricEnrollment(
                        expectedUserID: expectedUserID,
                        expectedSessionID: expectedSessionID,
                        expectedInstallationID: expectedInstallationID,
                        expectedAccountEpoch: expectedAccountEpoch
                    )
                },
                createReplacementChallenge: {
                    try await self.api.createStepUp(
                        purpose: purpose,
                        intent: intent
                    )
                }
            )
            guard isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id == expectedUserID,
                  await sessions.current()?.sessionId == expectedSessionID
            else { throw KitFinancialStepUpError.accountChanged }

            let verification: StepUpVerificationDTO
            switch method {
            case .biometricSignature:
                let signature = try await biometrics.sign(
                    signingPayload: challenge.signingPayload,
                    userID: expectedUserID,
                    sessionID: expectedSessionID,
                    installationID: expectedInstallationID,
                    reason: reason
                )
                guard isSignedIn,
                      accountEpoch == expectedAccountEpoch,
                      profile?.id == expectedUserID,
                      await sessions.current()?.sessionId == expectedSessionID
                else { throw KitFinancialStepUpError.accountChanged }
                verification = try await api.verifyStepUp(
                    challengeId: challenge.id,
                    nonce: challenge.nonce,
                    signature: signature
                )
            case .pin:
                verification = try await api.verifyStepUp(
                    challengeId: challenge.id,
                    pin: pin
                )
            }

            try KitFinancialStepUpBinding.validate(
                verification,
                method: method
            )
            guard isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id == expectedUserID,
                  await sessions.current()?.sessionId == expectedSessionID
            else { throw KitFinancialStepUpError.accountChanged }
            return verification
        } catch {
            if method == .biometricSignature {
                biometricErrorMessage = error.localizedDescription
                if let biometricError = error as? KitBiometricError,
                   [.biometricSetChanged, .enrollmentMissing, .keyMissing, .notEnrolled,
                    .unavailable, .passcodeNotSet].contains(biometricError) {
                    await biometrics.removeAnyEnrollment()
                    biometricUnlockEnabled = false
                    biometricAccessState = .notRequired
                    homeBiometricState = .notRequired
                }
            }
            throw error
        }
    }

    private func repairServerBiometricEnrollment(
        expectedUserID: String,
        expectedSessionID: String,
        expectedInstallationID: String,
        expectedAccountEpoch: UUID
    ) async throws {
        guard isSignedIn,
              biometricUnlockEnabled,
              accountSetupStep == nil,
              sessionAssurance?.grantsFullAccess == true,
              accountEpoch == expectedAccountEpoch,
              profile?.id == expectedUserID,
              installationID() == expectedInstallationID,
              await sessions.current()?.sessionId == expectedSessionID
        else { throw KitFinancialStepUpError.accountChanged }

        let publicKeyPEM = try await biometrics.publicKeyPEM(
            forUserID: expectedUserID,
            sessionID: expectedSessionID,
            installationID: expectedInstallationID
        )
        guard isSignedIn,
              accountEpoch == expectedAccountEpoch,
              profile?.id == expectedUserID,
              installationID() == expectedInstallationID,
              await sessions.current()?.sessionId == expectedSessionID
        else { throw KitFinancialStepUpError.accountChanged }

        let registration = try await api.enrollBiometricKey(
            publicKeyPEM: publicKeyPEM,
            attestation: [
                "platform": "ios",
                "key_storage": "secure_enclave",
                "access_control": "biometry_current_set",
            ]
        )
        guard registration.algorithm?.caseInsensitiveCompare("ES256") == .orderedSame,
              registration.removed != true
        else { throw KitFinancialStepUpError.approvalMethodUnavailable }

        let updatedAssurance: SessionAssuranceDTO
        if let responseAssurance = registration.sessionAssurance {
            updatedAssurance = responseAssurance
        } else {
            updatedAssurance = try await api.sessionAssurance()
        }
        guard isSignedIn,
              accountEpoch == expectedAccountEpoch,
              profile?.id == expectedUserID,
              installationID() == expectedInstallationID,
              await sessions.current()?.sessionId == expectedSessionID
        else { throw KitFinancialStepUpError.accountChanged }
        guard updatedAssurance.grantsFullAccess,
              updatedAssurance.loginUnlock.supportsBiometricSignature
        else { throw KitFinancialStepUpError.approvalMethodUnavailable }
        sessionAssurance = updatedAssurance
    }

    private func loadBiometricConfiguration(
        context: AuthenticatedSecurityContext,
        requiresSignedIn: Bool = true
    ) async -> Bool {
        guard await sessionOwnershipContextIsCurrent(
            context,
            requiresSignedIn: requiresSignedIn
        ) else { return false }
        biometricErrorMessage = nil
        biometricSignInPermanentlyUnavailable = false
        biometricPINRecoveryRequiresEnrollmentRemoval = false
        let availability = await biometrics.availability()
        guard await sessionOwnershipContextIsCurrent(
            context,
            requiresSignedIn: requiresSignedIn
        ) else { return false }
        let storedEnrollmentEnabled = await biometrics.isEnabled(
            forUserID: context.userID,
            sessionID: context.sessionID,
            installationID: installationID()
        )
        guard await sessionOwnershipContextIsCurrent(
            context,
            requiresSignedIn: requiresSignedIn
        ) else { return false }
        if !storedEnrollmentEnabled {
            // Remove only material owned by this account. A stale load must never delete an
            // enrollment created by a replacement sign-in while the actor call was suspended.
            try? await biometrics.disable(
                forUserID: context.userID,
                sessionID: context.sessionID,
                installationID: installationID()
            )
            guard await sessionOwnershipContextIsCurrent(
                context,
                requiresSignedIn: requiresSignedIn
            ) else { return false }
        }
        biometricErrorMessage = nil
        biometricKind = availability.kind
        // An enrolled account remains gated even if LocalAuthentication is temporarily
        // unavailable. The verified PIN path may recover it; treating this as `.notRequired`
        // would reveal protected account data without either factor.
        biometricUnlockEnabled = storedEnrollmentEnabled
        biometricAccessState = storedEnrollmentEnabled ? .locked : .notRequired
        homeBiometricState = storedEnrollmentEnabled ? .locked : .notRequired
        if storedEnrollmentEnabled, !availability.isAvailable {
            biometricErrorMessage = availability.unavailableMessage
            biometricSignInPermanentlyUnavailable = true
        }
        return true
    }

    private func authenticateBiometrically(
        for purpose: KitBiometricPurpose
    ) async -> Bool {
        guard biometricUnlockEnabled,
              isSignedIn,
              let userID = profile?.id
        else { return !biometricUnlockEnabled }

        guard let operationID = biometricAuthenticationGate.begin() else { return false }
        let expectedAccountEpoch = accountEpoch
        let expectedInstallationID = installationID()
        let expectedReturningSignInAuthorization =
            returningSignInBiometricAuthorizationFence.capture()
        let expectedHomeAuthorization = homeBiometricAuthorizationFence.capture()
        biometricErrorMessage = nil
        switch purpose {
        case .returningSignIn: biometricAccessState = .authorizing
        case .home: homeBiometricState = .authorizing
        case .paymentRequest: break
        }
        defer { biometricAuthenticationGate.finish(operationID) }

        guard let session = await sessions.current() else {
            guard biometricAuthenticationGate.owns(operationID) else { return false }
            switch purpose {
            case .returningSignIn:
                biometricAccessState = .locked
            case .home:
                if homeBiometricAuthorizationFence.authorizes(
                    expectedHomeAuthorization,
                    homeIsSelected: selectedTab == MainTabIndex.home
                ) {
                    homeBiometricState = .locked
                }
            case .paymentRequest:
                break
            }
            return false
        }
        let expectedSessionID = session.sessionId

        guard biometricAuthenticationGate.owns(operationID),
              !Task.isCancelled,
              isSignedIn,
              accountEpoch == expectedAccountEpoch,
              profile?.id == userID
        else { return false }
        if case .returningSignIn = purpose,
           !returningSignInBiometricAuthorizationFence.authorizes(
               expectedReturningSignInAuthorization
           ) {
            return false
        }
        if case .home = purpose,
           !homeBiometricAuthorizationFence.authorizes(
               expectedHomeAuthorization,
               homeIsSelected: selectedTab == MainTabIndex.home
           ) {
            return false
        }

        do {
            let kind = try await biometrics.authenticate(
                userID: userID,
                sessionID: expectedSessionID,
                installationID: expectedInstallationID,
                reason: purpose.reason(using: biometricKind)
            )
            guard biometricAuthenticationGate.owns(operationID),
                  isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id == userID,
                  await sessions.current()?.sessionId == expectedSessionID
            else { throw KitBiometricError.accountChanged }
            if case .returningSignIn = purpose,
               !returningSignInBiometricAuthorizationFence.authorizes(
                   expectedReturningSignInAuthorization
               ) {
                return false
            }
            biometricKind = kind
            biometricSignInPermanentlyUnavailable = false
            biometricPINRecoveryRequiresEnrollmentRemoval = false
            switch purpose {
            case .returningSignIn:
                biometricAccessState = .authorized
                if homeBiometricAuthorizationFence.authorizes(
                    expectedHomeAuthorization,
                    homeIsSelected: selectedTab == MainTabIndex.home
                ) {
                    homeBiometricState = .authorized
                }
            case .home:
                guard homeBiometricAuthorizationFence.authorizes(
                    expectedHomeAuthorization,
                    homeIsSelected: selectedTab == MainTabIndex.home
                ) else { return false }
                homeBiometricState = .authorized
            case .paymentRequest:
                break
            }
            return true
        } catch {
            guard biometricAuthenticationGate.owns(operationID) else { return false }
            if case .returningSignIn = purpose,
               !returningSignInBiometricAuthorizationFence.authorizes(
                   expectedReturningSignInAuthorization
               ) {
                return false
            }
            if case .home = purpose,
               !homeBiometricAuthorizationFence.authorizes(
                   expectedHomeAuthorization,
                   homeIsSelected: selectedTab == MainTabIndex.home
               ) {
                return false
            }
            biometricErrorMessage = error.localizedDescription
            if let biometricError = error as? KitBiometricError,
               [.lockedOut, .biometricSetChanged, .enrollmentMissing, .keyMissing,
                .notEnrolled, .unavailable, .passcodeNotSet].contains(biometricError) {
                // Lockout is recoverable without deleting enrollment. Key/enrollment failures
                // are terminal and are retired only after the server verifies the user's PIN.
                biometricSignInPermanentlyUnavailable = true
                biometricPINRecoveryRequiresEnrollmentRemoval = biometricError != .lockedOut
            }
            switch purpose {
            case .returningSignIn: biometricAccessState = .locked
            case .home: homeBiometricState = .locked
            case .paymentRequest: break
            }
            return false
        }
    }

    private func resumeAuthenticatedSessionIfNeeded() async {
        guard isSignedIn,
              !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              accountSetupStep == nil,
              communicationAccessGranted,
              !requiresBiometricSignIn,
              let expectedUserID = profile?.id
        else {
            isLoading = false
            return
        }
        let expectedAccountEpoch = accountEpoch
        guard let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else {
            if accountEpoch == expectedAccountEpoch,
               profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame {
                didResumeAuthenticatedSession = false
                isLoading = false
            }
            return
        }
        privacyQuarantineTargetAccountID = nil
        if didResumeAuthenticatedSession {
            let recoveryTicket = protectedCallRecoveryTicket
            guard let lease = callMediaAccountLease,
                  lease.accountEpoch == expectedAccountEpoch,
                  lease.userID.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  lease.sessionID.caseInsensitiveCompare(expectedSessionID) == .orderedSame,
                  await releaseProtectedCallRecovery(ticket: recoveryTicket, lease: lease),
                  callMediaAccountLease == lease,
                  await outboxContextIsCurrent(
                      accountEpoch: expectedAccountEpoch,
                      userID: expectedUserID,
                      sessionID: expectedSessionID
                  )
            else {
                didResumeAuthenticatedSession = false
                isLoading = false
                return
            }
            NotificationCoordinator.shared.resumeRegistration(
                afterOwnershipRecoveryFor: expectedUserID
            )
            await MessageNotificationActionDispatcher.shared.replayPending()
            await ClaimablePaymentNotificationActionDispatcher.shared.replayPending()
            isLoading = false
            return
        }
        didResumeAuthenticatedSession = true
        let lease = CallMediaAccountLease(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        )
        guard CallMediaCoordinator.shared.activateAccountLease(lease) else {
            didResumeAuthenticatedSession = false
            isLoading = false
            return
        }
        if ephemeralOutgoingCallGate.attempt?.lease != lease {
            cancelEphemeralOutgoingCall(dismissPresentation: true)
        }
        callMediaAccountLease = lease
        // No authenticated write may leave the device until this session's capability cohort is
        // known. This also covers a first launch where no previous demo fence exists yet.
        await api.setAppReviewDemoReadOnly(true, sessionID: expectedSessionID)
        capabilities = nil
        await refresh()
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { return }
        guard communicationAccessGranted,
              appReviewDemoMutationsAllowed,
              capabilities != nil
        else {
            didResumeAuthenticatedSession = false
            isLoading = false
            return
        }
        let recoveryTicket = protectedCallRecoveryTicket
        guard await releaseProtectedCallRecovery(ticket: recoveryTicket, lease: lease),
              callMediaAccountLease == lease,
              await outboxContextIsCurrent(
                  accountEpoch: expectedAccountEpoch,
                  userID: expectedUserID,
                  sessionID: expectedSessionID
              )
        else {
            didResumeAuthenticatedSession = false
            isLoading = false
            return
        }
        NotificationCoordinator.shared.requestAuthorizationAndRegister(
            forAccountID: expectedUserID
        )
        NotificationCoordinator.shared.replayCurrentPushTokens()
        try? await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw StoreError.accountChanged }
            OutboxPolicy.resumeSessionDeferredCommands(in: &persisted, at: Date())
        }
        let resumedState = await store.snapshot()
        guard resumedState.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
              resumedState.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                == .orderedSame,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else { return }
        await publishLatestState()
        schedulePendingMediaPreprocessing()
        scheduleOutboxWake()
        if isOnline { await flushOutbox() }
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { return }
        await MessageNotificationActionDispatcher.shared.replayPending()
        await ClaimablePaymentNotificationActionDispatcher.shared.replayPending()
        isLoading = false
        scheduleAutomaticContactSync()
        Task { [weak self] in
            await self?.checkForRestorableBackup()
            await self?.runAutomaticMessageBackupIfDue()
        }
    }

    /// Restores the exact account/session call lease before the app-owned interface asks for
    /// biometric unlock. This is deliberately narrower than full session resume: it lets PushKit
    /// authenticate and CallKit answer a Lock Screen call, but does not unlock wallet, messaging,
    /// outbox, or foreground UI state.
    private func prepareProtectedCallRecoveryIfPermitted(
        context: AuthenticatedSecurityContext,
        recoveryTicket: ProtectedCallRecoveryLatch.Ticket
    ) async {
        guard ProtectedCallRecoveryPolicy.permits(
            isSignedIn: isSignedIn,
            isSigningOut: isSigningOut,
            accountSetupComplete: accountSetupStep == nil,
            sessionGrantsFullAccess: communicationAccessGranted,
            hasAuthenticatedCapabilities: capabilities != nil,
            accountMutationsAllowed: appReviewDemoMutationsAllowed,
            callsFeatureEnabled: callsFeatureEnabled,
            communicationSurfacesConcealed: communicationSurfacesConcealed,
            localInterfaceRequiresBiometricUnlock: requiresBiometricSignIn
        ), accountEpoch == context.accountEpoch,
           profile?.id.caseInsensitiveCompare(context.userID) == .orderedSame,
           let currentSession = await sessions.current(),
           currentSession.sessionId.caseInsensitiveCompare(context.sessionID) == .orderedSame,
           currentSession.accountId?.caseInsensitiveCompare(context.userID) == .orderedSame,
           await outboxContextIsCurrent(
               accountEpoch: context.accountEpoch,
               userID: context.userID,
               sessionID: context.sessionID
           )
        else { return }

        let lease = CallMediaAccountLease(
            accountEpoch: context.accountEpoch,
            userID: context.userID,
            sessionID: context.sessionID
        )
        guard callMediaAccountLease == nil || callMediaAccountLease == lease,
              CallMediaCoordinator.shared.activateAccountLease(lease)
        else { return }
        callMediaAccountLease = lease
        guard await releaseProtectedCallRecovery(ticket: recoveryTicket, lease: lease),
              callMediaAccountLease == lease,
              await outboxContextIsCurrent(
                  accountEpoch: context.accountEpoch,
                  userID: context.userID,
                  sessionID: context.sessionID
              )
        else { return }
        NotificationCoordinator.shared.resumeRegistration(
            afterOwnershipRecoveryFor: context.userID
        )
        NotificationCoordinator.shared.replayCurrentPushTokens()
    }

    private func unregisterApplePushProvidersBeforeSignOut(sessionID: String) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in ["apns", "apns_voip"] {
                group.addTask { [api] in
                    _ = try? await APIClientSessionBinding.$sessionID.withValue(sessionID) {
                        try await api.unregisterPushToken(provider: provider)
                    }
                }
            }
            await group.waitForAll()
        }
    }

    /// - Parameter userInitiated: `true` only when the customer pulled to refresh. Automatic
    ///   refreshes — launch, session resume, returning from the biometric prompt — stay silent
    ///   about transient transport failures instead of raising an alert nobody can act on.
    func refresh(userInitiated: Bool = false) async {
        guard AuthenticatedProjectionRefreshPolicy.permits(
            isSigningOut: isSigningOut,
            isSignedIn: isSignedIn,
            isOnline: isOnline,
            accountSetupComplete: accountSetupStep == nil,
            isSubmittingAccountDeletion: isSubmittingAccountDeletion,
            acceptedAccountDeletionCleanupBlocked: acceptedAccountDeletionCleanupBlocked,
            protectedLocalStateRecoveryBlocked: protectedLocalStateRecoveryBlocked,
            unresolvedAccountDeletionAttemptBlocked: unresolvedAccountDeletionAttemptBlocked
        ) else { return }
        guard let expectedSessionID = await sessions.current()?.sessionId,
              let expectedUserID = profile?.id
        else { return }
        let expectedAccountEpoch = accountEpoch
        let foregroundGenerationAtStart =
            foregroundAuthoritativeRefreshGate.backgroundGeneration
        authenticatedRefreshCount += 1
        if state.pendingProfileAvatarAttachment != nil {
            profileAvatarResumeRequestedAfterRefresh = true
        }
        defer {
            authenticatedRefreshCount -= 1
            if authenticatedRefreshCount == 0,
               profileAvatarResumeRequestedAfterRefresh {
                profileAvatarResumeRequestedAfterRefresh = false
                schedulePendingProfileAvatarResume()
            }
        }

        // Bootstrap owns the profile projection while it is in flight. Cancel a silent avatar
        // retry promptly, then restart it after all overlapping refreshes have committed.
        await cancelProfileAvatarResumeAndWait()
        guard isOnline,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else { return }
        // Capability discovery governs communication/provider release gates, but it is not an
        // authority for the authenticated wallet projection. Start it independently so a slow or
        // failed capability request cannot delay bootstrap or leave Recent activity empty while
        // the wallet API is healthy. `reloadCapabilities` owns its account/session fence; gated
        // features remain fail-closed until the task succeeds.
        let capabilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.reloadCapabilities()
        }
        guard !Task.isCancelled,
              !isSigningOut,
              isSignedIn,
              isOnline,
              accountEpoch == expectedAccountEpoch,
              await sessions.current()?.sessionId == expectedSessionID
        else { return }
        // Already-confirmed communication state may resume immediately while discovery refreshes.
        // Its own feature and identity fences still fail closed, and the post-discovery wake below
        // catches a feature that becomes available only in the new response.
        if communicationAccessGranted {
            resumeEphemeralOutgoingCallIfPossible()
        }

        // Wake durable communication work without putting finance behind it. A resumable media
        // upload or E2EE recovery can legitimately take minutes; bootstrap and wallet history
        // must still refresh immediately and independently on the same foreground visit.
        if communicationAccessGranted {
            scheduleOutboxWake()
        }
        guard !Task.isCancelled,
              !isSigningOut,
              isSignedIn,
              isOnline,
              accountEpoch == expectedAccountEpoch,
              profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
              await sessions.current()?.sessionId == expectedSessionID
        else { return }
        if communicationAccessGranted {
            requestCallMicrophonePermissionInForeground()
        }
        let expectedDeviceManagementGeneration = deviceManagementGeneration
        let expectedDeviceProjectionRevision = state.currentRegisteredDeviceProjectionRevision
        do {
            let bootstrap = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.bootstrap()
            }
            let selectedId = WalletIdentityResolver.authoritativeSelectionID(
                preferred: bootstrap.selectedWalletId,
                in: bootstrap.wallets
            )
            let verifiedDevices = RegisteredDevicePolicy.validated(bootstrap.devices)
            try Task.checkCancellation()
            guard isSignedIn,
                  !isSigningOut,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  bootstrap.user.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  await sessions.current()?.sessionId == expectedSessionID
            else { return }
            let canCommitDeviceProjection = verifiedDevices != nil
                && deviceManagementGeneration == expectedDeviceManagementGeneration
                && !isRefreshingRegisteredDevices
                && revokingRegisteredDeviceID == nil
            try await store.update { persisted in
                guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame
                else { throw AccountSetupError.accountChanged }
                persisted.bindAuthenticatedProfile(bootstrap.user)
                persisted.sessionAssurance = bootstrap.resolvedSessionAssurance
                persisted.replaceAuthoritativeWalletProjection(
                    bootstrap.wallets,
                    selectedWalletID: selectedId
                )
                if canCommitDeviceProjection,
                   let verifiedDevices,
                   persisted.currentRegisteredDeviceProjectionRevision
                        == expectedDeviceProjectionRevision {
                    persisted.replaceRegisteredDeviceProjection(verifiedDevices)
                }
            }
            guard await callHistoryContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                sessionID: expectedSessionID,
                userID: expectedUserID
            ) else { return }
            await publishLatestState()
            sessionAssurance = bootstrap.resolvedSessionAssurance
            foregroundAuthoritativeRefreshGate.authoritativeRefreshDidCommit(
                upTo: foregroundGenerationAtStart
            )
            accountSetupStep = AccountSetupPolicy.reconcile(
                accountSetupStep,
                with: bootstrap.user,
                assurance: sessionAssurance
            )
            // A finalized photo may still be scanning after a previous suspension. Resume it in
            // its own single-flight task so an ordinary refresh never waits for the poll window.
            schedulePendingProfileAvatarResume()
        } catch {
            if RefreshCancellationPolicy.shouldSuppress(
                error,
                taskIsCancelled: Task.isCancelled
            ) { return }
            if TransientTransportErrorPolicy.shouldSuppressAutomatically(
                error,
                isUserInitiated: userInitiated
            ) { return }
            guard !Task.isCancelled,
                  !isSigningOut,
                  isSignedIn,
                  isOnline,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  await sessions.current()?.sessionId == expectedSessionID
            else { return }
            lastError = error.localizedDescription
            return
        }

        // Wallet history is an independent customer-facing projection. Keep it ahead of privacy,
        // E2EE and media synchronization so a slow communication lane can never leave an empty or
        // stale Recent transactions section after bootstrap has already refreshed the balance.
        await refreshSelectedWalletTransactions(
            accountEpoch: expectedAccountEpoch,
            sessionID: expectedSessionID,
            userID: expectedUserID
        )

        // Communication work uses the newly confirmed capability projection when available, but
        // it can no longer sit in front of the independent customer-finance refresh above.
        _ = await capabilityRefreshTask.value
        guard await callHistoryContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            sessionID: expectedSessionID,
            userID: expectedUserID
        ) else { return }
        // Bootstrap has now replaced cached assurance with the server-authoritative projection.
        // Finance is already current; only communication work depends on this separate decision.
        guard communicationAccessGranted else { return }
        resumeEphemeralOutgoingCallIfPossible()
        scheduleOutboxWake()

        // Communication blocks are account-wide authorization state. Refresh them before
        // rebuilding recipient pickers so a stale local contact cannot remain selectable.
        await loadCommunicationPrivacy()

        // Call history is deliberately independent from wallet/bootstrap and secure messaging.
        // A malformed deep cursor can neither hide refreshed balances nor stop encrypted messages.
        if callsFeatureEnabled {
            scheduleVisibleConversationCallHistoryRefresh()
            scheduleCompleteCallHistoryBackfillIfNeeded()
        } else {
            rebuildCallContacts(remote: [])
        }

        _ = await syncSecureMessagingIfPermitted(
            presentsVisibleMessageNotifications: true
        )
        guard await callHistoryContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            sessionID: expectedSessionID,
            userID: expectedUserID
        ) else { return }

        await confirmStarterMilestonesFromServerIfSupported(
            accountEpoch: expectedAccountEpoch,
            sessionID: expectedSessionID,
            userID: expectedUserID
        )

        if callsFeatureEnabled {
            await loadCallContacts()
        }
    }

    /// Explicit recovery for a call surface whose capability or privacy projection is missing.
    /// Nothing is made permissive: capabilities are fetched under the current authenticated
    /// session, privacy remains authoritative, and `resumeAuthenticatedSessionIfNeeded` retains
    /// the App Review transport fence before it restores push/call/outbox work.
    func retryCommunicationReadiness() async {
        guard !isSigningOut,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted
        else {
            lastError = "Sign in again to restore calls and messages."
            return
        }
        guard isOnline else {
            lastError = "Connect to the internet to restore calling."
            return
        }

        lastError = nil
        let capabilitiesRecovered = await reloadCapabilities()
        await loadCommunicationPrivacy()
        guard capabilitiesRecovered, capabilities != nil else { return }
        if !didResumeAuthenticatedSession {
            await resumeAuthenticatedSessionIfNeeded()
        }
    }

    /// Starts or joins the model-owned refresh for the current wallet. The unstructured task is
    /// intentionally independent from its SwiftUI caller: dismissing a refresh control or
    /// replacing a view must not cancel an authenticated response between HTTP 200 and the local
    /// store commit. Exact identity changes still revoke the flight through its context fence.
    private func refreshSelectedWalletTransactions(
        accountEpoch expectedAccountEpoch: UUID,
        sessionID expectedSessionID: String,
        userID expectedUserID: String
    ) async {
        guard let selectedWalletID = state.selectedWalletId,
              let selectedWallet = WalletIdentityResolver.wallet(
                  matching: selectedWalletID,
                  in: state.wallets
              )
        else { return }

        let key = WalletHistoryRefreshKey(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID,
            walletID: selectedWallet.id
        )
        if let flight = walletHistoryRefreshFlight, flight.key == key {
            await flight.task.value
            return
        }

        walletHistoryRefreshFlight?.task.cancel()
        let flightID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSelectedWalletTransactionsRefresh(
                key: key,
                selectedWallet: selectedWallet
            )
            self.finishWalletHistoryRefresh(id: flightID)
        }
        walletHistoryRefreshFlight = WalletHistoryRefreshFlight(
            id: flightID,
            key: key,
            task: task
        )
        await task.value
    }

    /// Runs exclusively inside the model-owned flight above. `Task.isCancelled` therefore means
    /// the account/session/wallet owner changed, never merely that a SwiftUI view disappeared.
    private func performSelectedWalletTransactionsRefresh(
        key: WalletHistoryRefreshKey,
        selectedWallet: Wallet
    ) async {
        do {
            let firstPage = try await APIClientSessionBinding.$sessionID.withValue(
                key.sessionID
            ) {
                try await api.transactions(walletId: key.walletID)
            }
            guard case .replace(let transactions) = CustomerTransactionPresentationPolicy
                .pageReplacement(for: firstPage, wallet: selectedWallet)
            else { return }
            guard await callHistoryContextIsCurrent(
                accountEpoch: key.accountEpoch,
                sessionID: key.sessionID,
                userID: key.userID
            ), WalletIdentityResolver.identifiersMatch(
                state.selectedWalletId,
                key.walletID
            ) else { return }
            try await store.update { persisted in
                guard persisted.profile?.id.caseInsensitiveCompare(key.userID)
                        == .orderedSame,
                      WalletIdentityResolver.identifiersMatch(
                          persisted.selectedWalletId,
                          key.walletID
                      )
                else { throw StoreError.accountChanged }
                persisted.transactions = transactions
                // The page above is only the latest slice of one wallet, so the starter
                // checklist's account-wide milestone is remembered the moment a settled
                // movement is seen in server-confirmed rows — and never recomputed away.
                // Demo content is projected in memory only and can never reach this write.
                if persisted.starterFirstTransactionAt == nil,
                   HomeStarterChecklistPolicy.hasMadeFirstTransaction(
                       transactions: transactions
                   ) {
                    persisted.starterFirstTransactionAt = Date()
                }
            }
            guard await callHistoryContextIsCurrent(
                accountEpoch: key.accountEpoch,
                sessionID: key.sessionID,
                userID: key.userID
            ), WalletIdentityResolver.identifiersMatch(
                state.selectedWalletId,
                key.walletID
            ) else { return }
            await publishLatestState()
        } catch {
            if RefreshCancellationPolicy.shouldSuppress(
                error,
                taskIsCancelled: Task.isCancelled
            ) { return }
            guard await callHistoryContextIsCurrent(
                accountEpoch: key.accountEpoch,
                sessionID: key.sessionID,
                userID: key.userID
            ), WalletIdentityResolver.identifiersMatch(
                state.selectedWalletId,
                key.walletID
            ) else { return }
            lastError = error.localizedDescription
        }
    }

    private func finishWalletHistoryRefresh(id: UUID) {
        guard walletHistoryRefreshFlight?.id == id else { return }
        walletHistoryRefreshFlight = nil
    }

    private func cancelWalletHistoryRefresh() {
        walletHistoryRefreshFlight?.task.cancel()
        walletHistoryRefreshFlight = nil
    }

    private func loadCompleteCallHistory(
        accountEpoch expectedAccountEpoch: UUID,
        sessionID expectedSessionID: String,
        userID expectedUserID: String
    ) async throws -> [CallDTO] {
        // Return only after an authenticated terminal page. A cancellation, account switch, or
        // malformed cursor leaves the previously complete encrypted cache untouched.
        var accumulator = CallHistoryPageAccumulator()
        while true {
            try Task.checkCancellation()
            guard isOnline,
                  await callHistoryContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                sessionID: expectedSessionID,
                userID: expectedUserID
            ) else { throw CancellationError() }

            let page = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.calls(
                    cursor: accumulator.nextCursor,
                    limit: CallHistoryPageAccumulator.pageLimit
                )
            }

            try Task.checkCancellation()
            guard isOnline,
                  await callHistoryContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                sessionID: expectedSessionID,
                userID: expectedUserID
            ) else { throw CancellationError() }
            if try accumulator.append(page) {
                return accumulator.calls
            }
        }
    }

    private func callHistoryContextIsCurrent(
        accountEpoch expectedAccountEpoch: UUID,
        sessionID expectedSessionID: String,
        userID expectedUserID: String
    ) async -> Bool {
        guard !Task.isCancelled,
              !isSigningOut,
              isSignedIn,
              accountEpoch == expectedAccountEpoch,
              profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame
        else { return false }
        guard await sessions.current()?.sessionId == expectedSessionID else { return false }
        return !Task.isCancelled
            && !isSigningOut
            && isSignedIn
            && accountEpoch == expectedAccountEpoch
            && profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame
    }

    func realtimeSessionID(for userID: String) async -> String? {
        guard isSignedIn,
              !isSigningOut,
              accountSetupStep == nil,
              communicationAccessGranted,
              !requiresBiometricSignIn,
              messagingRealtimeConfiguration != nil,
              profile?.id.caseInsensitiveCompare(userID) == .orderedSame,
              let session = await sessions.current(),
              session.accountId?.caseInsensitiveCompare(userID) == .orderedSame
        else { return nil }
        return session.sessionId
    }

    /// Conflates realtime hints to one active durable REST sync plus at most one rerun. The
    /// socket carries no cursor or content; this remains the only path that mutates messaging
    /// projection state, and every pass is fenced to the account/session that received the hint.
    func requestRealtimeMessagingSync(userID: String, sessionID: String) {
        guard UIApplication.shared.applicationState == .active,
              KitPresenceCenter.shared.isLive,
              messagingRealtimeConfiguration != nil,
              profile?.id.caseInsensitiveCompare(userID) == .orderedSame
        else { return }
        // The visible-conversation loop performs the same account-fenced durable sync and also
        // publishes read receipts. Wake that single owner instead of racing it with another sync.
        if activeConversationID != nil {
            wakeVisibleConversationSync()
            return
        }
        let context = AuthenticatedSecurityContext(
            accountEpoch: accountEpoch,
            userID: userID,
            sessionID: sessionID
        )
        let fingerprint = [accountEpoch.uuidString, userID.lowercased(), sessionID.lowercased()]
            .joined(separator: ":")

        if let existing = realtimeMessagingSyncFingerprint, existing != fingerprint {
            realtimeMessagingSyncGeneration &+= 1
            realtimeMessagingSyncTask?.cancel()
            realtimeMessagingSyncTask = nil
            realtimeMessagingSyncNeedsRun = false
        }
        realtimeMessagingSyncFingerprint = fingerprint
        realtimeMessagingSyncNeedsRun = true
        guard realtimeMessagingSyncTask == nil else { return }

        realtimeMessagingSyncGeneration &+= 1
        let generation = realtimeMessagingSyncGeneration
        realtimeMessagingSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.realtimeMessagingSyncGeneration == generation {
                    self.realtimeMessagingSyncTask = nil
                    self.realtimeMessagingSyncNeedsRun = false
                    self.realtimeMessagingSyncFingerprint = nil
                }
            }
            while self.realtimeMessagingSyncNeedsRun {
                self.realtimeMessagingSyncNeedsRun = false
                guard self.realtimeMessagingSyncGeneration == generation,
                      UIApplication.shared.applicationState == .active,
                      KitPresenceCenter.shared.isLive,
                      await self.authenticatedSecurityContextIsCurrent(context)
                else { return }
                _ = await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
                    await self.syncSecureMessagingIfPermitted(
                        presentsVisibleMessageNotifications: true,
                        reportsFailure: false,
                        expectedContext: context
                    )
                }
            }
        }
    }

    private func cancelRealtimeMessagingSync() {
        realtimeMessagingSyncGeneration &+= 1
        realtimeMessagingSyncTask?.cancel()
        realtimeMessagingSyncTask = nil
        realtimeMessagingSyncNeedsRun = false
        realtimeMessagingSyncFingerprint = nil
    }

    @discardableResult
    private func syncSecureMessagingIfPermitted(
        presentsVisibleMessageNotifications: Bool = false,
        reportsFailure: Bool = true,
        expectedContext: AuthenticatedSecurityContext? = nil
    ) async -> UIBackgroundFetchResult {
        if let expectedContext,
           !(await authenticatedSecurityContextIsCurrent(expectedContext)) {
            return .noData
        }
        guard secureMessagingReleasePermitted,
              isSignedIn,
              isOnline,
              accountSetupStep == nil,
              communicationAccessGranted,
              let userID = profile?.id
        else { return .noData }
        let context: AuthenticatedSecurityContext
        if let expectedContext {
            guard expectedContext.userID.caseInsensitiveCompare(userID) == .orderedSame,
                  await authenticatedSecurityContextIsCurrent(expectedContext)
            else { return .noData }
            context = expectedContext
        } else {
            guard let session = await sessions.current(),
                  session.accountId?.caseInsensitiveCompare(userID) == .orderedSame
            else { return .noData }
            context = AuthenticatedSecurityContext(
                accountEpoch: accountEpoch,
                userID: userID,
                sessionID: session.sessionId
            )
            guard await authenticatedSecurityContextIsCurrent(context) else { return .noData }
        }
        guard let communicationAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
            forAccountID: userID
        ) else { return .noData }
        let syncAttempt = secureMessagingSyncError.begin()
        do {
            let previousServerMessageIDs: Set<String>
            if presentsVisibleMessageNotifications {
                previousServerMessageIDs = Set(
                    (await store.snapshot()).messages.compactMap(\.serverMessageId)
                )
            } else {
                previousServerMessageIDs = []
            }
            let result = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: context.accountEpoch,
                sessionID: context.sessionID,
                commitAdmission: communicationAdmission
            ) {
                try await SecureMessagingExchangeCoordinator.shared.activate(forUserID: userID)
                return try await SecureMessagingExchangeCoordinator.shared.sync(
                    forUserID: userID
                )
            }
            let latestState = await store.snapshot()
            if !(await authenticatedSecurityContextIsCurrent(context)) {
                return .noData
            }
            await publishLatestState()
            // A verified remote-identity lifecycle event can atomically release commands that
            // were waiting for that exact recipient. Re-arm replay from the newly published
            // projection; many sync entry points are polling/UI paths with no later outbox drain.
            scheduleOutboxWake()
            // A read-only recovery endpoint may have recovered a server-confirmed financial
            // result whose chat card was interrupted by process death. Cross it into the same
            // encrypted outbox only after this account's Signal state has activated and synced.
            await recoverAndDrainFinancialChatReceipts()
            await enforceReceivedMediaCacheBudget()
            schedulePendingMediaHydration()
            lastError = secureMessagingSyncError.resolve(
                syncAttempt,
                visibleMessage: lastError
            )
            if presentsVisibleMessageNotifications, result.receivedMessages > 0 {
                let suppressedConversationID = UIApplication.shared.applicationState == .active
                    ? activeConversationID
                    : nil
                let descriptors = VisibleMessageNotificationPolicy.descriptors(
                    previousServerMessageIDs: previousServerMessageIDs,
                    messages: latestState.messages,
                    suppressedConversationID: suppressedConversationID,
                    ownerUserID: latestState.communicationOwnerUserID ?? userID,
                    mutedConversationIDs: Set(latestState.mutedConversationIds ?? [])
                )
                await VisibleMessageNotificationCoordinator.shared.schedule(descriptors)
            }
            return result.receivedMessages > 0 || result.appliedTransitions > 0
                ? .newData
                : .noData
        } catch {
            if RefreshCancellationPolicy.shouldSuppress(
                error,
                taskIsCancelled: Task.isCancelled
            ) {
                return .noData
            }
            if reportsFailure {
                let message = error.localizedDescription
                if let ownedMessage = secureMessagingSyncError.record(message, for: syncAttempt) {
                    lastError = ownedMessage
                }
            }
            return .failed
        }
    }

    func setConversationVisible(_ conversationID: String, visible: Bool) {
#if DEBUG && APP_STORE_SCREENSHOTS
        guard !AppStoreScreenshotFixture.isActive else { return }
#endif
        guard !isReadOnlyAppReviewDemoConversation(conversationID) else { return }
        guard let uuid = UUID(uuidString: conversationID) else { return }
        let canonical = uuid.uuidString.lowercased()
        guard canonical.caseInsensitiveCompare(conversationID) == .orderedSame else { return }
        if visible {
            KitPresenceCenter.shared.observeConversation(canonical)
            if activeConversationID != canonical || visibleConversationSyncTask == nil {
                activeConversationID = canonical
                startVisibleConversationSync(for: canonical)
            }
            scheduleVisibleConversationCallHistoryRefresh()
            let accountFingerprint = MessageNotificationContract.accountFingerprint(
                for: profile?.id
            )
            Task {
                await NotificationCoordinator.shared.clearMessageNotifications(
                    accountFingerprint: accountFingerprint,
                    conversationID: canonical
                )
            }
        } else if activeConversationID == canonical {
            KitPresenceCenter.shared.unobserveConversation(canonical)
            activeConversationID = nil
            stopVisibleConversationSync()
        }
    }

    private func startVisibleConversationSync(for conversationID: String) {
        visibleConversationSleepTask?.cancel()
        visibleConversationSleepTask = nil
        visibleConversationSyncTask?.cancel()
        visibleConversationSyncWakePending = false
        visibleConversationSyncGeneration &+= 1
        let generation = visibleConversationSyncGeneration
        visibleConversationSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.visibleConversationSyncGeneration == generation {
                    self.visibleConversationSyncTask = nil
                }
            }
            guard self.activeConversationID == conversationID,
                  self.isSignedIn,
                  let userID = self.profile?.id,
                  let session = await self.sessions.current(),
                  session.accountId?.caseInsensitiveCompare(userID) == .orderedSame
            else { return }
            let context = AuthenticatedSecurityContext(
                accountEpoch: self.accountEpoch,
                userID: userID,
                sessionID: session.sessionId
            )

            while await self.visibleConversationContextIsCurrent(
                conversationID: conversationID,
                generation: generation,
                context: context
            ) {
                self.visibleConversationSyncWakePending = false
                if self.isOnline {
                    // Existing unread state is published immediately on presentation. Keeping
                    // the attempted boundary lets a failed POST wait for the next cadence while
                    // still publishing a genuinely newer message discovered by this sync.
                    let boundaryBeforeSync = VisibleConversationMessagingPolicy
                        .newestUnreadIncomingServerMessageID(
                            conversationID: conversationID,
                            conversations: self.state.conversations,
                            messages: self.state.messages
                        )
                    if let boundaryBeforeSync {
                        await self.publishVisibleConversationReadReceipt(
                            conversationID: conversationID,
                            messageID: boundaryBeforeSync,
                            generation: generation,
                            context: context
                        )
                    }
                    guard await self.visibleConversationContextIsCurrent(
                        conversationID: conversationID,
                        generation: generation,
                        context: context
                    ) else { return }
                    _ = await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
                        await self.syncSecureMessagingIfPermitted(
                            presentsVisibleMessageNotifications: true,
                            reportsFailure: false,
                            expectedContext: context
                        )
                    }
                    guard await self.visibleConversationContextIsCurrent(
                        conversationID: conversationID,
                        generation: generation,
                        context: context
                    ) else { return }
                    let boundaryAfterSync = VisibleConversationMessagingPolicy
                        .newestUnreadIncomingServerMessageID(
                            conversationID: conversationID,
                            conversations: self.state.conversations,
                            messages: self.state.messages
                        )
                    if VisibleConversationMessagingPolicy.shouldPublishAfterSync(
                        attemptedBoundary: boundaryBeforeSync,
                        currentBoundary: boundaryAfterSync
                    ), let boundaryAfterSync {
                        await self.publishVisibleConversationReadReceipt(
                            conversationID: conversationID,
                            messageID: boundaryAfterSync,
                            generation: generation,
                            context: context
                        )
                    }
                }

                guard await self.visibleConversationContextIsCurrent(
                    conversationID: conversationID,
                    generation: generation,
                    context: context
                ) else { return }
                if self.visibleConversationSyncWakePending { continue }

                let now = Date()
                let hasRealtimeConfiguration = self.messagingRealtimeConfiguration != nil
                let isRealtimeLive = hasRealtimeConfiguration
                    && KitPresenceCenter.shared.isLive
                self.updateVisibleConversationDisconnectClock(
                    hasRealtimeConfiguration: hasRealtimeConfiguration,
                    isLive: isRealtimeLive,
                    now: now
                )
                let disconnectedFor = self.visibleConversationRealtimeDisconnectedAt.map {
                    max(0, now.timeIntervalSince($0))
                } ?? 0
                let interval = KitRealtimePollingPolicy.interval(
                    hasRealtimeConfiguration: hasRealtimeConfiguration,
                    isLive: isRealtimeLive,
                    disconnectedFor: disconnectedFor
                )
                let sleepTask = Task<Void, Never> {
                    try? await Task.sleep(for: .seconds(interval))
                }
                self.visibleConversationSleepTask = sleepTask
                await sleepTask.value
                if self.visibleConversationSyncGeneration == generation {
                    self.visibleConversationSleepTask = nil
                }
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func stopVisibleConversationSync() {
        visibleConversationSyncGeneration &+= 1
        visibleConversationSleepTask?.cancel()
        visibleConversationSleepTask = nil
        visibleConversationSyncTask?.cancel()
        visibleConversationSyncTask = nil
        visibleConversationSyncWakePending = false
    }

    /// Wakes a sleeping visible-chat recovery loop without cancelling an in-flight durable sync.
    /// Repeated Reverb nudges collapse into one extra pass.
    private func wakeVisibleConversationSync() {
        guard let activeConversationID else { return }
        guard visibleConversationSyncTask != nil else {
            startVisibleConversationSync(for: activeConversationID)
            return
        }
        visibleConversationSyncWakePending = true
        visibleConversationSleepTask?.cancel()
    }

    func realtimeMessagingConnectionDidChange(isLive: Bool, now: Date = Date()) {
        updateVisibleConversationDisconnectClock(
            hasRealtimeConfiguration: messagingRealtimeConfiguration != nil,
            isLive: isLive,
            now: now
        )
        wakeVisibleConversationSync()
    }

    private func updateVisibleConversationDisconnectClock(
        hasRealtimeConfiguration: Bool,
        isLive: Bool,
        now: Date
    ) {
        guard hasRealtimeConfiguration else {
            visibleConversationRealtimeDisconnectedAt = nil
            return
        }
        if isLive {
            visibleConversationRealtimeDisconnectedAt = nil
        } else if visibleConversationRealtimeDisconnectedAt == nil {
            visibleConversationRealtimeDisconnectedAt = now
        }
    }

    private func visibleConversationContextIsCurrent(
        conversationID: String,
        generation: UInt64,
        context: AuthenticatedSecurityContext
    ) async -> Bool {
        guard visibleConversationSyncGeneration == generation,
              activeConversationID == conversationID,
              UIApplication.shared.applicationState == .active
        else { return false }
        return await authenticatedSecurityContextIsCurrent(context)
    }

    private func publishVisibleConversationReadReceipt(
        conversationID: String,
        messageID: String,
        generation: UInt64,
        context: AuthenticatedSecurityContext
    ) async {
        guard !isReadOnlyAppReviewDemoConversation(conversationID),
              secureMessagingAvailable,
              isOnline,
              let conversation = MessageNotificationConversationPolicy.conversation(
                  id: conversationID,
                  in: state.conversations
              ),
              let recipientUserID = MessageNotificationConversationPolicy.recipientUserID(
                  in: conversation,
                  currentUserID: context.userID
              ),
              communicationPrivacyAllowsOutbound(to: recipientUserID),
              VisibleConversationMessagingPolicy.newestUnreadIncomingServerMessageID(
                  conversationID: conversationID,
                  conversations: state.conversations,
                  messages: state.messages
              ) == messageID,
              await authenticatedSecurityContextIsCurrent(context),
              activeConversationID == conversationID
        else { return }
        do {
            try await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
                try await SecureMessagingExchangeCoordinator.shared.markConversationRead(
                    conversationID: conversationID,
                    throughServerMessageID: messageID,
                    forUserID: context.userID
                )
            }
            let latest = await store.snapshot()
            guard latest.profile?.id.caseInsensitiveCompare(context.userID) == .orderedSame,
                  await visibleConversationContextIsCurrent(
                      conversationID: conversationID,
                      generation: generation,
                      context: context
                  )
            else { return }
            await publishLatestState()
        } catch is CancellationError {
            return
        } catch {
            // Keep the durable unread counter unchanged. The next foreground cadence retries the
            // exact newest inbound boundary without presenting transient transport noise.
        }
    }

    func canOpenConversation(for activeCall: ActiveCallPresentation?) -> Bool {
        if activeCallConversation(for: activeCall) != nil { return true }
        guard appReviewDemoMutationsAllowed,
              isOnline,
              secureMessagingAvailable,
              let target = activeCallConversationCreationTarget(for: activeCall)
        else { return false }
        return communicationPrivacyAllowsOutbound(to: target.recipientUserID)
    }

    func unreadMessageCount(for activeCall: ActiveCallPresentation?) -> Int {
        guard let activeCall,
              activeCallConversation(for: activeCall) != nil
        else { return 0 }
        return ActiveCallConversationPolicy.unreadCount(
            callID: activeCall.id,
            explicitConversationID: activeCall.conversationId,
            calls: state.calls,
            conversations: state.conversations,
            currentUserID: profile?.id
        )
    }

    /// Reuses an exact local conversation or asks the authenticated messaging service to
    /// idempotently create the sole remote participant's direct conversation. The caller minimizes
    /// the call only after the validated server projection is durably stored and re-fenced to the
    /// same account/session.
    @discardableResult
    func openConversation(for activeCall: ActiveCallPresentation?) async -> Bool {
        guard !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              isSignedIn,
              accountSetupStep == nil,
              let currentUserID = profile?.id,
              let canonicalCurrentUserID = MessageNotificationContract.canonicalUUID(
                  currentUserID
              ),
              MessageNotificationContract.canonicalUUID(state.communicationOwnerUserID)
                == canonicalCurrentUserID,
              let activeCall,
              CallMediaCoordinator.shared.activeCall?.id.caseInsensitiveCompare(activeCall.id)
                == .orderedSame
        else { return false }

        if let conversation = activeCallConversation(for: activeCall) {
            routeToConversation(conversation)
            return true
        }

        guard appReviewDemoMutationsAllowed,
              isOnline,
              secureMessagingAvailable,
              let target = activeCallConversationCreationTarget(for: activeCall),
              communicationPrivacyDenialMessage(
                for: target.recipientUserID,
                blockedMessage: "Unblock this account before starting a chat."
              ) == nil
        else { return false }
        let expectedAccountEpoch = accountEpoch
        guard let commitAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
            forAccountID: currentUserID
        ), let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: currentUserID,
            sessionID: expectedSessionID,
            commitAdmission: commitAdmission
        ) else { return false }

        do {
            let created = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: expectedAccountEpoch,
                sessionID: expectedSessionID,
                commitAdmission: commitAdmission
            ) {
                try await SecureMessagingExchangeCoordinator.shared.ensureDirectConversation(
                    forUserID: currentUserID,
                    recipientUserID: target.recipientUserID,
                    title: activeCall.participantName,
                    expectedConversationID: target.expectedConversationID,
                    commitAdmission: commitAdmission
                )
            }
            guard ProtectedCommunicationAdmissionGate.shared.permits(commitAdmission),
                  await outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: currentUserID,
                    sessionID: expectedSessionID
                  ),
                  CallMediaCoordinator.shared.activeCall?.id.caseInsensitiveCompare(activeCall.id)
                    == .orderedSame
            else { return false }
            let latest = await store.snapshot()
            guard latest.profile?.id.caseInsensitiveCompare(currentUserID) == .orderedSame,
                  latest.communicationOwnerUserID?.caseInsensitiveCompare(currentUserID)
                    == .orderedSame
            else { return false }
            await publishLatestState()
            guard let resolved = activeCallConversation(for: activeCall),
                  resolved.id.caseInsensitiveCompare(created.id) == .orderedSame
            else { return false }
            routeToConversation(resolved)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: currentUserID,
                sessionID: expectedSessionID
            ) else { return false }
            lastError = CustomerFacingMessagingCopy.openConversationFailure
            return false
        }
    }

    /// Switches to Messages and asks the chats list to open its contact picker — the starter
    /// checklist's route into a first message.
    func requestNewMessageCompose() {
        selectedTab = MainTabIndex.messages
        pendingNewMessageComposeID = UUID()
    }

    func consumeNewMessageComposeRequest(_ id: UUID) {
        guard pendingNewMessageComposeID == id else { return }
        pendingNewMessageComposeID = nil
    }

    @discardableResult
    func requestConversationNavigation(
        conversationID: String,
        messageID: UUID? = nil
    ) -> Bool {
        guard !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              isSignedIn,
              accountSetupStep == nil,
              let currentUserID = profile?.id,
              let canonicalCurrentUserID = MessageNotificationContract.canonicalUUID(
                  currentUserID
              ),
              MessageNotificationContract.canonicalUUID(state.communicationOwnerUserID)
                == canonicalCurrentUserID,
              let conversation = MessageNotificationConversationPolicy.conversation(
                  id: conversationID,
                  in: state.conversations
              )
        else { return false }
        if let messageID {
            let matches = state.messages.filter {
                $0.id == messageID
                    && MessageNotificationContract.canonicalUUID($0.conversationId)
                        == MessageNotificationContract.canonicalUUID(conversation.id)
            }
            guard matches.count == 1 else { return false }
        }
        selectedTab = MainTabIndex.messages
        messageConversationNavigationRequest = MessageConversationNavigationRequest(
            conversationID: conversation.id,
            messageID: messageID
        )
        return true
    }

    private func routeToConversation(_ conversation: Conversation) {
        _ = requestConversationNavigation(conversationID: conversation.id)
    }

    private func activeCallConversation(
        for activeCall: ActiveCallPresentation?
    ) -> Conversation? {
        guard let activeCall else { return nil }
        return ActiveCallConversationPolicy.conversation(
            callID: activeCall.id,
            explicitConversationID: activeCall.conversationId,
            calls: state.calls,
            conversations: state.conversations,
            currentUserID: profile?.id
        )
    }

    /// Resolves a chat binding through the same strict path used by the call screen. Newer call
    /// handoffs carry a conversation id directly; older one-to-one calls may use their exact
    /// persisted call roster only when it maps to one unambiguous direct conversation.
    func resolvedConversationID(forActiveCall activeCall: ActiveCallPresentation?) -> String? {
        activeCallConversation(for: activeCall)?.id
    }

    private func activeCallConversationCreationTarget(
        for activeCall: ActiveCallPresentation?
    ) -> ActiveCallConversationPolicy.CreationTarget? {
        guard let activeCall else { return nil }
        return ActiveCallConversationPolicy.creationTarget(
            callID: activeCall.id,
            explicitConversationID: activeCall.conversationId,
            calls: state.calls,
            conversations: state.conversations,
            currentUserID: profile?.id
        )
    }

    func consumeMessageConversationNavigationRequest(_ requestID: UUID) {
        guard messageConversationNavigationRequest?.id == requestID else { return }
        messageConversationNavigationRequest = nil
    }

    func consumeWalletClaimNavigationRequest(_ requestID: UUID) {
        guard walletClaimNavigationRequest?.id == requestID else { return }
        walletClaimNavigationRequest = nil
    }

    private func handleMessageNotificationAction(
        _ action: MessageNotificationAction
    ) async -> MessageNotificationActionHandlingResult {
        // Accepted-deletion recovery is the first protected-state access barrier. Inline replies
        // must not inspect SessionStore or SecureLocalStore until that launch recovery completes.
        if let restoreTask { await restoreTask.value }
        // A response may outlive its original account across termination. Retire it only after a
        // restored authenticated session conclusively proves that it belongs to another owner;
        // every incomplete launch/setup/offline state remains retryable.
        if isSignedIn,
           let currentUserID = profile?.id,
           let session = await sessions.current(),
           session.accountId?.caseInsensitiveCompare(currentUserID) == .orderedSame,
           MessageNotificationContract.accountFingerprint(for: currentUserID)
            != action.accountFingerprint {
            return .invalidated
        }
        guard !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked
        else { return .retry }
        switch action.kind {
        case .open:
            return await routeMessageNotificationOpen(action) ? .completed : .retry
        case .reply(let text):
            return await queueMessageNotificationReply(text, action: action) ? .completed : .retry
        }
    }

    private func routeMessageNotificationOpen(_ action: MessageNotificationAction) async -> Bool {
        if let restoreTask { await restoreTask.value }
        guard !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted,
              let currentUserID = profile?.id,
              MessageNotificationContract.accountFingerprint(for: currentUserID)
                  == action.accountFingerprint,
              MessageNotificationContract.canonicalUUID(state.communicationOwnerUserID)
                  == MessageNotificationContract.canonicalUUID(currentUserID),
              let session = await sessions.current(),
              session.accountId?.caseInsensitiveCompare(currentUserID) == .orderedSame
        else { return false }
        let context = AuthenticatedSecurityContext(
            accountEpoch: accountEpoch,
            userID: currentUserID,
            sessionID: session.sessionId
        )
        guard await authenticatedSecurityContextIsCurrent(context) else { return false }

        var conversation = MessageNotificationConversationPolicy.conversation(
            id: action.conversationID,
            in: state.conversations
        )
        if conversation == nil {
            // A cold APNs launch can beat the first secure-message hydration. Run one normal,
            // account-fenced incremental sync, then resolve the route from the durable local
            // projection. Failure remains in the dispatcher's durable queue for connectivity or
            // foreground recovery; it is never converted into an invalid navigation state.
            guard isOnline else { return false }
            _ = await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
                await syncSecureMessagingIfPermitted(
                    presentsVisibleMessageNotifications: false,
                    reportsFailure: false,
                    expectedContext: context
                )
            }
            guard await authenticatedSecurityContextIsCurrent(context) else { return false }
            conversation = MessageNotificationConversationPolicy.conversation(
                id: action.conversationID,
                in: state.conversations
            )
        }
        guard let conversation else { return false }
        let targetMessageID = MessageNotificationTargetPolicy.messageID(
            forDigest: action.messageDigest,
            conversationID: conversation.id,
            messages: state.messages
        )
        guard requestConversationNavigation(
            conversationID: conversation.id,
            messageID: targetMessageID
        ) else { return false }
        // Clear only after the final account/deletion routing gate has succeeded. A failed cold
        // launch remains retryable and cannot consume another account's delivered notification.
        await NotificationCoordinator.shared.clearMessageNotifications(
            accountFingerprint: action.accountFingerprint,
            conversationID: action.conversationID
        )
        return true
    }

    private func handleClaimablePaymentNotificationAction(
        _ action: ClaimablePaymentNotificationAction
    ) async -> ClaimablePaymentNotificationActionHandlingResult {
        if let restoreTask { await restoreTask.value }
        let currentSession = await sessions.current()
        let currentUserID = profile?.id
        let currentFingerprint = MessageNotificationContract.accountFingerprint(
            for: currentUserID
        )
        let sessionOwnsCurrentProfile = currentUserID.map { userID in
            currentSession?.accountId?.caseInsensitiveCompare(userID) == .orderedSame
        } == true
        let communicationProjectionOwnsCurrentProfile =
            MessageNotificationContract.canonicalUUID(state.communicationOwnerUserID)
                == MessageNotificationContract.canonicalUUID(currentUserID)

        // A durable response may outlive its original session. Once a fully restored account is
        // available, a pre-existing owner mismatch is conclusive and must never be retried under
        // the replacement account.
        if isSignedIn,
           sessionOwnsCurrentProfile,
           let currentFingerprint,
           let actionFingerprint = action.accountFingerprint,
           actionFingerprint != currentFingerprint {
            return .invalidated
        }

        if action.accountFingerprint == nil {
            if isSignedIn,
               sessionOwnsCurrentProfile,
               communicationProjectionOwnsCurrentProfile,
               let currentFingerprint {
                // This is a state-machine transition, not a delayed retry: the dispatcher writes
                // the owner synchronously and invokes us again before any claim lookup begins.
                return .bindAndContinue(toAccountFingerprint: currentFingerprint)
            }
            let accountRecoveryMayResume = acceptedAccountDeletionCleanupBlocked
                || protectedLocalStateRecoveryBlocked
                || unresolvedAccountDeletionAttemptBlocked
            // After a clean signed-out restore there is no owner left to prove. Retaining an
            // unbound claim for an arbitrary future login would cross the account boundary.
            return !isSignedIn && !accountRecoveryMayResume ? .invalidated : .retry
        }

        guard !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted,
              let currentUserID,
              let currentFingerprint,
              sessionOwnsCurrentProfile,
              communicationProjectionOwnsCurrentProfile,
              let currentSession
        else { return .retry }
        guard action.accountFingerprint == currentFingerprint
        else { return .invalidated }
        let context = AuthenticatedSecurityContext(
            accountEpoch: accountEpoch,
            userID: currentUserID,
            sessionID: currentSession.sessionId
        )
        guard await authenticatedSecurityContextIsCurrent(context) else { return .retry }

        // Unlike a message notification, the server claim payload does not carry an account
        // digest. Never surface its claim ID merely because some account is signed in: first load
        // the exact claim through the fenced session and prove that user is a party. Offline and
        // transient failures stay durable for connectivity/foreground replay.
        // Missing/null flags are not a withdrawal. Only an explicit authoritative `false` retires
        // the route; a partial response remains durable until capability discovery converges.
        switch ClaimablePaymentNotificationCapabilityPolicy.readiness(
            capabilities: capabilities
        ) {
        case .enabled:
            break
        case .awaitingAuthority:
            return .retry
        case .withdrawn:
            return .invalidated
        }
        guard isOnline else { return .retry }

        if let groupPaymentID = action.groupPaymentID {
            // A share of a group payment is intentionally not readable through the standalone
            // transfer-claim endpoint. Resolve it through the caller-scoped group projection, and
            // never fall back to the wallet claim route for this branch.
            guard MessageNotificationContract.canonicalUUID(groupPaymentID) == groupPaymentID
            else { return .invalidated }
            let groupPayment: GroupPaymentDTO
            do {
                groupPayment = try await APIClientSessionBinding.$sessionID.withValue(
                    context.sessionID
                ) {
                    try await api.groupPayment(id: groupPaymentID)
                }
            } catch {
                return ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(error)
                    ? .invalidated
                    : .retry
            }
            guard await authenticatedSecurityContextIsCurrent(context) else { return .retry }
            guard ClaimablePaymentNotificationRoutingPolicy.authorizesGroupPayment(
                action: action,
                groupPayment: groupPayment,
                currentUserID: currentUserID
            ) else { return .invalidated }

            var conversation = ClaimablePaymentNotificationRoutingPolicy.conversation(
                action: action,
                groupPayment: groupPayment,
                conversations: state.conversations,
                currentUserID: currentUserID
            )
            if conversation == nil {
                _ = await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
                    await syncSecureMessagingIfPermitted(
                        presentsVisibleMessageNotifications: false,
                        reportsFailure: false,
                        expectedContext: context
                    )
                }
                guard await authenticatedSecurityContextIsCurrent(context) else { return .retry }
                conversation = ClaimablePaymentNotificationRoutingPolicy.conversation(
                    action: action,
                    groupPayment: groupPayment,
                    conversations: state.conversations,
                    currentUserID: currentUserID
                )
            }
            guard let conversation else { return .retry }
            let targetMessageID = ClaimablePaymentNotificationRoutingPolicy.targetMessageID(
                action: action,
                groupPayment: groupPayment,
                conversation: conversation,
                messages: state.messages
            )
            return requestConversationNavigation(
                conversationID: conversation.id,
                messageID: targetMessageID
            ) ? .completed : .retry
        }

        let claim: TransferAcceptanceDTO
        do {
            claim = try await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
                try await api.transferAcceptance(transferId: action.claimID)
            }
        } catch {
            return ClaimablePaymentNotificationLookupFailurePolicy.isTerminal(error)
                ? .invalidated
                : .retry
        }
        guard await authenticatedSecurityContextIsCurrent(context) else { return .retry }
        guard ClaimablePaymentNotificationRoutingPolicy.authorizesWallet(
            action: action,
            claim: claim,
            currentUserID: currentUserID
        ) else { return .invalidated }
        if let conversation = ClaimablePaymentNotificationRoutingPolicy.conversation(
            action: action,
            claim: claim,
            conversations: state.conversations,
            currentUserID: currentUserID
        ) {
            let targetMessageID = ClaimablePaymentNotificationRoutingPolicy.targetMessageID(
                action: action,
                claim: claim,
                conversation: conversation,
                messages: state.messages
            )
            if requestConversationNavigation(
                conversationID: conversation.id,
                messageID: targetMessageID
            ) {
                return .completed
            }
        }

        // No payload URL is opened. After the exact claim has authorized this account, a missing
        // or contradictory group binding safely falls back to its own server-backed wallet view.
        guard await authenticatedSecurityContextIsCurrent(context) else { return .retry }
        selectedTab = MainTabIndex.home
        walletClaimNavigationRequest = WalletClaimNavigationRequest(claimID: action.claimID)
        return .completed
    }

    private func queueMessageNotificationReply(
        _ text: String,
        action: MessageNotificationAction
    ) async -> Bool {
        let expectedAccountEpoch = accountEpoch
        guard appReviewDemoMutationsAllowed,
              !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              SecureMessagingReleaseGate.enabled,
              let clientMessageID = action.replyClientMessageID,
              let currentSession = await sessions.current()
        else { return false }
        guard SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(text) else {
            if UIApplication.shared.applicationState == .active {
                lastError = "Messages can't start with Kit Pay's reserved payment prefix."
            }
            return false
        }
        let snapshot = await store.snapshot()
        guard let currentUserID = snapshot.profile?.id,
              MessageNotificationContract.accountFingerprint(for: currentUserID)
                  == action.accountFingerprint,
              MessageNotificationContract.canonicalUUID(snapshot.communicationOwnerUserID)
                  == MessageNotificationContract.canonicalUUID(currentUserID),
              snapshot.sessionAssurance?.grantsCommunicationAccess(
                accountKYCStatus: snapshot.profile?.kycStatus
              ) == true,
              AccountSetupPolicy.restoredStep(
                  user: snapshot.profile,
                  assurance: snapshot.sessionAssurance
              ) == nil,
              snapshot.secureMessaging?.enrollment?.userID == currentUserID,
              let conversation = MessageNotificationConversationPolicy.conversation(
                  id: action.conversationID,
                  in: snapshot.conversations
              ),
              let recipientUserID = MessageNotificationConversationPolicy.recipientUserID(
                  in: conversation,
                  currentUserID: currentUserID
              ),
              CommunicationPrivacyAccessPolicy.decision(
                  ownerUserID: currentUserID,
                  recipientUserID: recipientUserID,
                  cache: snapshot.communicationPrivacy
              ) == .allowed,
              // If restore has already installed a live projection, it is newer than the snapshot
              // captured for a cold-launch reply and must also authorize the recipient.
              (!isSignedIn || communicationPrivacyAllowsOutbound(to: recipientUserID))
        else { return false }

        do {
            // Queue from the protected local projection without waiting for restore's live HTTP
            // calls. UNTextInputNotificationAction already requires device authentication; fresh
            // capabilities, roster and session checks still run before any ciphertext is sent.
            guard let commitAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
                forAccountID: currentUserID
            ), await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: currentUserID,
                sessionID: currentSession.sessionId,
                commitAdmission: commitAdmission
            ) else { return false }
            _ = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: expectedAccountEpoch,
                sessionID: currentSession.sessionId,
                commitAdmission: commitAdmission
            ) {
                try await SecureMessagingExchangeCoordinator.shared.queueDeferredText(
                    forUserID: currentUserID,
                    conversationID: conversation.id,
                    expectedRecipientUserID: recipientUserID,
                    title: conversation.title,
                    text: text,
                    clientMessageID: clientMessageID,
                    commitAdmission: commitAdmission
                )
            }
            let queuedState = await store.snapshot()
            guard ProtectedCommunicationAdmissionGate.shared.permits(commitAdmission),
                  await outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: currentUserID,
                    sessionID: currentSession.sessionId
                  )
            else { return false }
            if !isSigningOut,
               !isSubmittingAccountDeletion,
               queuedState.profile?.id.caseInsensitiveCompare(currentUserID) == .orderedSame,
               await sessions.current()?.sessionId == currentSession.sessionId {
                await publishLatestState()
                scheduleOutboxWake()
            }
            await NotificationCoordinator.shared.clearMessageNotifications(
                accountFingerprint: action.accountFingerprint,
                conversationID: conversation.id
            )
            Task { @MainActor [weak self] in
                await self?.reconcileNotificationReplyAfterRestore(
                    userID: currentUserID,
                    sessionID: currentSession.sessionId,
                    accountEpoch: expectedAccountEpoch,
                    admission: commitAdmission
                )
            }
            return true
        } catch {
            if UIApplication.shared.applicationState == .active {
                lastError = error.localizedDescription
            }
            return false
        }
    }

    private func reconcileNotificationReplyAfterRestore(
        userID: String,
        sessionID: String,
        accountEpoch expectedAccountEpoch: UUID,
        admission: ProtectedCommunicationAdmissionLease
    ) async {
        if let restoreTask { await restoreTask.value }
        guard !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              ProtectedCommunicationAdmissionGate.shared.permits(admission),
              accountEpoch == expectedAccountEpoch,
              isSignedIn,
              profile?.id.caseInsensitiveCompare(userID) == .orderedSame,
              await sessions.current()?.sessionId == sessionID
        else { return }
        let latest = await store.snapshot()
        guard latest.profile?.id.caseInsensitiveCompare(userID) == .orderedSame,
              latest.communicationOwnerUserID?.caseInsensitiveCompare(userID) == .orderedSame
        else { return }
        await publishLatestState()
        scheduleOutboxWake()
        guard ProtectedCommunicationAdmissionGate.shared.permits(admission),
              !isSubmittingAccountDeletion
        else { return }
        if isOnline { await flushOutbox() }
    }

    private func scheduleVisibleConversationCallHistoryRefresh() {
        guard callHistoryRefreshTask == nil else { return }
        callHistoryRefreshGeneration &+= 1
        let generation = callHistoryRefreshGeneration
        callHistoryRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshVisibleConversationCallHistory()
            guard self.callHistoryRefreshGeneration == generation else { return }
            self.callHistoryRefreshTask = nil
        }
    }

    private func refreshVisibleConversationCallHistory() async {
        guard isSignedIn,
              isOnline,
              callsFeatureEnabled,
              accountSetupStep == nil,
              communicationAccessGranted,
              let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return }
        let expectedAccountEpoch = accountEpoch

        do {
            let response = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.calls(cursor: nil, limit: CallHistoryPageAccumulator.pageLimit)
            }
            let callDTOs = try CallHistoryPageAccumulator.validateNewestPage(response)
            let callRecords = callDTOs.map { mapCall($0) }
            guard await callHistoryContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                sessionID: expectedSessionID,
                userID: expectedUserID
            ) else { return }
            try await commitCallHistory(
                callRecords,
                receipt: nil,
                accountEpoch: expectedAccountEpoch,
                sessionID: expectedSessionID,
                userID: expectedUserID
            )
            guard await callHistoryContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                sessionID: expectedSessionID,
                userID: expectedUserID
            ) else { return }
            await publishLatestState()
            rebuildCallContacts()
            reconcileCallWaitingAfterHistoryRefresh()
            reconcileOutgoingCallRingDeadlineAfterHistoryRefresh()
            await CallMediaCoordinator.shared.reconcileBackendCalls(state.calls)
        } catch {
            // Chat opening must remain offline-first. A cancelled, incomplete, or malformed
            // refresh leaves the last authenticated encrypted history untouched for the next pass.
        }
    }

    private func scheduleCompleteCallHistoryBackfillIfNeeded(now: Date = Date()) {
        guard callHistoryBackfillTask == nil,
              callHistoryBackfillRetryNotBefore.map({ $0 <= now }) ?? true,
              let expectedUserID = profile?.id,
              CallHistoryBackfillPolicy.isDue(
                receipt: state.callHistoryBackfillReceipt,
                userID: expectedUserID,
                now: now
              )
        else { return }

        callHistoryBackfillGeneration &+= 1
        let generation = callHistoryBackfillGeneration
        callHistoryBackfillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let completed = await self.refreshCompleteCallHistory()
            guard self.callHistoryBackfillGeneration == generation else { return }
            self.callHistoryBackfillTask = nil
            self.callHistoryBackfillRetryNotBefore = completed
                ? nil
                : Date().addingTimeInterval(CallHistoryBackfillPolicy.retryDelay)
        }
    }

    private func refreshCompleteCallHistory() async -> Bool {
        guard isSignedIn,
              isOnline,
              callsFeatureEnabled,
              accountSetupStep == nil,
              communicationAccessGranted,
              let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return false }
        let expectedAccountEpoch = accountEpoch

        do {
            let callDTOs = try await loadCompleteCallHistory(
                accountEpoch: expectedAccountEpoch,
                sessionID: expectedSessionID,
                userID: expectedUserID
            )
            let receipt = CallHistoryBackfillReceipt(
                ownerUserID: expectedUserID,
                schemaVersion: CallHistoryBackfillPolicy.schemaVersion,
                completedAt: Date()
            )
            try await commitCallHistory(
                callDTOs.map { mapCall($0) },
                receipt: receipt,
                accountEpoch: expectedAccountEpoch,
                sessionID: expectedSessionID,
                userID: expectedUserID
            )
            guard await callHistoryContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                sessionID: expectedSessionID,
                userID: expectedUserID
            ) else { return false }
            await publishLatestState()
            rebuildCallContacts()
            reconcileCallWaitingAfterHistoryRefresh()
            reconcileOutgoingCallRingDeadlineAfterHistoryRefresh()
            await CallMediaCoordinator.shared.reconcileBackendCalls(state.calls)
            return true
        } catch {
            return false
        }
    }

    private func commitCallHistory(
        _ callRecords: [CallRecord],
        receipt: CallHistoryBackfillReceipt?,
        accountEpoch expectedAccountEpoch: UUID,
        sessionID expectedSessionID: String,
        userID expectedUserID: String
    ) async throws {
        guard await callHistoryContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            sessionID: expectedSessionID,
            userID: expectedUserID
        ) else { throw CancellationError() }
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw StoreError.accountChanged }
            persisted.calls = CallLifecyclePolicy.applyingPendingTerminations(
                to: CallLifecyclePolicy.mergeHistory(
                    remote: callRecords,
                    local: persisted.calls
                ),
                outbox: persisted.outbox
            )
            if let receipt {
                persisted.callHistoryBackfillReceipt = receipt
            }
        }
    }

    /// A server call-history refresh is the remote lifecycle signal for calls that ended without a
    /// local CallKit action. Retire only the matching waiting presentation, and also dismiss the
    /// waiter when the primary media call itself became terminal.
    private func reconcileCallWaitingAfterHistoryRefresh(
        monotonicNow: TimeInterval = CallMonotonicClock.now()
    ) {
        guard let waiting = callWaitingState.waitingCall else { return }
        if waiting.ringDeadline.isExpired(at: monotonicNow) {
            _ = clearWaitingCallForLifecycle(callID: waiting.callID)
            NotificationCoordinator.shared.reportCallEnded(waiting.callUUID, reason: .unanswered)
            return
        }

        if let record = state.calls.first(where: {
            canonicalCallID($0.id) == waiting.callID
        }) {
            let reason: CXCallEndedReason?
            switch record.state {
            case .queued, .ringing:
                reason = nil
            case .active:
                reason = .answeredElsewhere
            case .missed:
                reason = .unanswered
            case .declined:
                reason = .declinedElsewhere
            case .failed:
                reason = .failed
            case .completed:
                reason = .remoteEnded
            }
            if let reason {
                _ = clearWaitingCallForLifecycle(callID: waiting.callID)
                NotificationCoordinator.shared.reportCallEnded(waiting.callUUID, reason: reason)
                return
            }
        }

        guard let activeCallID = CallMediaCoordinator.shared.activeCall?.id,
              let activeRecord = state.calls.first(where: {
                canonicalCallID($0.id) == canonicalCallID(activeCallID)
              }),
              [.completed, .missed, .declined, .failed].contains(activeRecord.state)
        else { return }
        declineWaitingCallAfterActiveCallTermination()
    }

    /// Every call this process is currently hosting: the presented media session, the provisional
    /// outgoing attempt, and the CallKit waiting record. A record named here is live by definition.
    private func hostedCallIDs() -> Set<String> {
        var identifiers: Set<String> = []
        if let activeCallID = CallMediaCoordinator.shared.activeCall?.id {
            identifiers.insert(canonicalCallID(activeCallID) ?? activeCallID.lowercased())
        }
        if let attempt = ephemeralOutgoingCallGate.attempt {
            identifiers.insert(attempt.clientCallIDString.lowercased())
        }
        if let waiting = callWaitingState.waitingCall {
            identifiers.insert(waiting.callID.lowercased())
        }
        return identifiers
    }

    /// Retires `ringing`/`active` records this process can no longer act on — the residue of a
    /// crash, or of a termination that never reached the server. Local `failed` yields to every
    /// terminal server state, so the next history refresh still restores the real outcome.
    @discardableResult
    private func reapAbandonedCallRecords(now: Date = Date()) async -> Bool {
        let hosted = hostedCallIDs()
        guard let ownerUserID = profile?.id,
              state.calls.contains(where: {
                  AbandonedCallRecordPolicy.isAbandoned($0, hostedCallIDs: hosted, now: now)
              })
        else { return false }
        do {
            try await store.update { persisted in
                guard persisted.profile?.id.caseInsensitiveCompare(ownerUserID) == .orderedSame
                else { throw StoreError.accountChanged }
                persisted.calls = AbandonedCallRecordPolicy.reaping(
                    persisted.calls,
                    hostedCallIDs: hosted,
                    now: now
                )
            }
        } catch {
            return false
        }
        await publishLatestState()
        rebuildCallContacts()
        return true
    }

    /// Commits the chosen half of the account's identity at the end of setup.
    ///
    /// `username` is optional: when the account already carries a verified legal name the server
    /// reports `username_required = false`, and passing nil leaves the provisional tag in place
    /// rather than forcing a handle on someone who did not want one. `displayName` is likewise
    /// optional — nil means "keep showing my verified legal name".
    ///
    /// The photo is deliberately attached *after* the step advances. Uploading an avatar is a
    /// three-leg prepare/upload/attach with its own durable retry lane, and a slow or failed
    /// photo must never be what stands between someone and a finished account.
    func completeProfile(
        displayName: String?,
        username: String?,
        avatarJPEG: Data? = nil,
        discovery: PendingAccountDiscoveryChoice? = nil
    ) async {
        guard !rejectAppReviewDemoMutation() else { return }
        guard let currentStep = accountSetupStep, case .profile = currentStep else { return }
        guard isOnline else {
            lastError = "Connect to the internet to finish setting up your profile."
            return
        }
        let normalizedName = displayName.map(normalizeProfileName).flatMap {
            $0.isEmpty ? nil : $0
        }
        let normalizedTag = username.map(normalizeProfileTag).flatMap { $0.isEmpty ? nil : $0 }
        let verifiedLegalName = profile?.verifiedLegalName
        if let validationError = profileIdentityValidationError(
            name: normalizedName ?? "",
            tag: normalizedTag,
            verifiedLegalName: verifiedLegalName,
            usernameRequired: profile?.usernameRequired ?? true
        ) {
            lastError = validationError
            return
        }

        isCompletingAccountSetup = true
        defer { isCompletingAccountSetup = false }
        do {
            guard let expectedSessionID = await sessions.current()?.sessionId else {
                throw APIClientError.signedOut
            }
            // Record the discoverability choices before the profile PATCH: they are held in
            // encrypted state until the session is authorized to send them, so an interrupted
            // setup still ends with the privacy the user asked for.
            if let discovery {
                await recordPendingAccountDiscoveryChoice(discovery)
            }
            let response = try await api.updateProfile(name: normalizedName, tag: normalizedTag)
            guard isSignedIn,
                  accountSetupStep == currentStep,
                  await sessions.current()?.sessionId == expectedSessionID
            else { throw APIClientError.signedOut }
            guard let currentProfile = profile,
                  let updated = UserProfileMutationMergePolicy.merge(
                    response: response,
                    current: currentProfile,
                    requestedName: normalizedName,
                    requestedTag: normalizedTag
                  )
            else {
                throw AccountSetupError.accountChanged
            }
            guard !AccountSetupPolicy.requiresProfileSetup(updated) else {
                throw AccountSetupError.profileStillRequired
            }
            try await store.update { persisted in persisted.profile = updated }
            await publishLatestState()
            accountSetupStep = AccountSetupPolicy.reconcile(
                currentStep,
                with: updated,
                assurance: sessionAssurance
            )
        } catch {
            lastError = error.localizedDescription
            return
        }

        if let avatarJPEG {
            // Reuses the hardened avatar lane rather than duplicating it. A failure here surfaces
            // its own message and leaves the durable pending attachment to retry; setup is done.
            await updateProfile(
                name: normalizedName,
                tag: normalizedTag,
                avatarJPEG: avatarJPEG
            )
        }
    }

    /// Nil `name`/`tag` mean "leave unchanged", which is how an account without a chosen username
    /// updates its photo without being forced to invent a handle first.
    @discardableResult
    func updateProfile(name: String?, tag: String?, avatarJPEG: Data? = nil) async -> Bool {
        guard !rejectAppReviewDemoMutation() else { return false }
        guard profileUpdateTask == nil else { return false }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performProfileUpdate(name: name, tag: tag, avatarJPEG: avatarJPEG)
        }
        profileUpdateTaskID = taskID
        profileUpdateTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard profileUpdateTaskID == taskID else { return false }
        profileUpdateTask = nil
        profileUpdateTaskID = nil
        return result
    }

    /// Starts (or resends) the authenticated profile-email challenge. The returned proof is
    /// process-local and bound to the exact account/session that requested it.
    func requestProfileEmailAttachment(email: String) async throws -> ProfileEmailChallenge {
        guard appReviewDemoMutationsAllowed else {
            throw AppReviewDemoMutationError.readOnly
        }
        let normalizedEmail = ProfileEmailChallengePolicy.normalizedEmail(email)
        guard EmailAccountValidation.isValidEmail(normalizedEmail) else {
            throw ProfileEmailAttachmentError.invalidEmail
        }
        let operationID = try beginProfileEmailOperation(.requestingCode)
        defer { finishProfileEmailOperation(operationID) }

        let context = try await captureProfileEmailContext()
        let result = try await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
            try await api.requestProfileEmailAttachment(email: normalizedEmail)
        }
        let receivedAt = Date()
        // Email attachment is the setup step for later email sign-in and recovery, so every
        // gate on this flow rides the email_recovery capability — never the retired
        // registration flag.
        guard emailRecoveryAvailable,
              await authenticatedSecurityContextIsCurrent(context),
              let challenge = ProfileEmailChallengePolicy.challenge(
                from: result,
                requestedEmail: normalizedEmail,
                ownerUserID: context.userID,
                sessionID: context.sessionID,
                issuedAt: receivedAt
              )
        else { throw ProfileEmailAttachmentError.invalidResponse }
        return challenge
    }

    /// Consumes a six-digit proof only in its originating session, then atomically replaces the
    /// encrypted cached profile after the server confirms the same account and email address.
    func verifyProfileEmailAttachment(
        challenge: ProfileEmailChallenge,
        code: String
    ) async throws {
        guard appReviewDemoMutationsAllowed else {
            throw AppReviewDemoMutationError.readOnly
        }
        guard let normalizedCode = ProfileEmailVerificationCodePolicy.normalizedCode(code) else {
            throw ProfileEmailAttachmentError.invalidCode
        }
        guard ProfileEmailChallengePolicy.isValid(challenge) else {
            throw ProfileEmailAttachmentError.invalidOrExpiredChallenge
        }
        let operationID = try beginProfileEmailOperation(.verifyingCode)
        defer { finishProfileEmailOperation(operationID) }

        let context = try await captureProfileEmailContext()
        guard ProfileEmailChallengePolicy.belongs(
            challenge,
            toUserID: context.userID,
            sessionID: context.sessionID
        ) else { throw ProfileEmailAttachmentError.invalidOrExpiredChallenge }

        let response = try await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
            try await api.verifyProfileEmailAttachment(
                challengeId: challenge.id,
                code: normalizedCode
            )
        }
        guard emailRecoveryAvailable,
              await authenticatedSecurityContextIsCurrent(context)
        else { throw ProfileEmailAttachmentError.unavailable }

        let updatedState = try await commitAuthenticatedMutation(
            accountEpoch: context.accountEpoch,
            userID: context.userID,
            sessionID: context.sessionID
        ) { persisted in
            guard let currentProfile = persisted.profile,
                  let verifiedProfile = ProfileEmailVerificationResponsePolicy.validatedProfile(
                    response,
                    for: challenge,
                    currentProfile: currentProfile
                  )
            else { throw ProfileEmailAttachmentError.invalidResponse }
            persisted.profile = verifiedProfile
        }
        guard await authenticatedSecurityContextIsCurrent(context) else {
            throw APIClientError.signedOut
        }
        await publishLatestState()
    }

    private func beginProfileEmailOperation(
        _ operation: ProfileEmailOperation
    ) throws -> UUID {
        guard profileEmailOperation == nil else {
            throw ProfileEmailAttachmentError.operationInProgress
        }
        let id = UUID()
        profileEmailOperationID = id
        profileEmailOperation = operation
        return id
    }

    private func finishProfileEmailOperation(_ id: UUID) {
        guard profileEmailOperationID == id else { return }
        profileEmailOperationID = nil
        profileEmailOperation = nil
    }

    private func captureProfileEmailContext() async throws -> AuthenticatedSecurityContext {
        guard isOnline else { throw ProfileEmailAttachmentError.offline }
        guard emailRecoveryAvailable,
              isSignedIn,
              !isUpdatingProfile,
              accountSetupStep == nil,
              communicationAccessGranted,
              let profile,
              profile.emailVerified != true,
              let session = await sessions.current(),
              session.accountId?.caseInsensitiveCompare(profile.id) == .orderedSame
        else { throw ProfileEmailAttachmentError.unavailable }
        let context = AuthenticatedSecurityContext(
            accountEpoch: accountEpoch,
            userID: profile.id,
            sessionID: session.sessionId
        )
        guard await authenticatedSecurityContextIsCurrent(context) else {
            throw ProfileEmailAttachmentError.unavailable
        }
        return context
    }

    private func performProfileUpdate(
        name: String?,
        tag: String?,
        avatarJPEG: Data?
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !isSigningOut, isSignedIn else { return false }
        guard profileEmailOperation == nil else {
            lastError = "Wait for email verification to finish before updating your profile."
            return false
        }
        guard isOnline else {
            lastError = "Connect to the internet to update your profile."
            return false
        }
        if avatarJPEG != nil, capabilities?.enablesProfileAvatars != true {
            lastError = "Your profile photo could not be updated right now. Try again shortly."
            return false
        }
        guard !isUpdatingProfile else { return false }
        let normalizedName = name.map(normalizeProfileName).flatMap { $0.isEmpty ? nil : $0 }
        let normalizedTag = tag.map(normalizeProfileTag).flatMap { $0.isEmpty ? nil : $0 }
        if let validationError = profileIdentityValidationError(
            name: normalizedName ?? "",
            tag: normalizedTag,
            verifiedLegalName: profile?.verifiedLegalName,
            usernameRequired: profile?.usernameRequired ?? true
        ) {
            lastError = validationError
            return false
        }
        var shouldRestartInterruptedAvatarResume = avatarJPEG == nil
        isUpdatingProfile = true
        defer {
            isUpdatingProfile = false
            if shouldRestartInterruptedAvatarResume {
                schedulePendingProfileAvatarResume()
            }
        }

        // A user-initiated replacement owns the avatar lane. Wait for any silent retry to unwind
        // so two attach operations can never race against the same encrypted pending record.
        await cancelProfileAvatarResumeAndWait()
        guard !Task.isCancelled,
              !isSigningOut,
              isSignedIn,
              let expectedSessionID = await sessions.current()?.sessionId,
              let expectedUserID = profile?.id
        else {
            lastError = APIClientError.signedOut.localizedDescription
            return false
        }
        let expectedAccountEpoch = accountEpoch
        var attemptedPendingAttachment: PendingProfileAvatarAttachment?

        if let avatarJPEG,
           let existingPendingAttachment = state.pendingProfileAvatarAttachment {
            switch ProfileAvatarPendingAttachmentPolicy.selectionDisposition(
                for: existingPendingAttachment,
                jpegData: avatarJPEG,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) {
            case .resumeExisting:
                // If the PATCH fails before polling starts, restart the exact upload interrupted
                // above. Once polling begins its own timeout/terminal policy owns the record.
                shouldRestartInterruptedAvatarResume = true
            case .discardBeforeProfileUpdate:
                // Record the replacement intent before a fallible profile PATCH. Otherwise that
                // request could fail and a later foreground retry would attach the old selection.
                guard await clearPendingProfileAvatarAttachmentIfCurrent(
                    existingPendingAttachment,
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                ) else { return false }
            }
        }

        do {
            let profileUpdate = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.updateProfile(name: normalizedName, tag: normalizedTag)
            }
            guard profileUpdate.id.caseInsensitiveCompare(expectedUserID) == .orderedSame else {
                throw AccountSetupError.accountChanged
            }
            var updatedState = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                guard let currentProfile = persisted.profile,
                      let committedProfile = UserProfileMutationMergePolicy.merge(
                        response: profileUpdate,
                        current: currentProfile,
                        requestedName: normalizedName,
                        requestedTag: normalizedTag
                      )
                else { throw AccountSetupError.accountChanged }
                persisted.profile = committedProfile
            }
            await publishLatestState()

            guard let avatarJPEG else { return true }

            let pendingAttachment: PendingProfileAvatarAttachment
            if let pending = updatedState.pendingProfileAvatarAttachment,
               ProfileAvatarPendingAttachmentPolicy.represents(
                pending,
                jpegData: avatarJPEG,
                userID: expectedUserID,
                sessionID: expectedSessionID
               ) {
                pendingAttachment = pending
            } else {
                // A different selection supersedes an older finalized upload. Clear its durable
                // retry first so a failed replacement can never attach the image the user rejected.
                if let superseded = updatedState.pendingProfileAvatarAttachment {
                    guard await clearPendingProfileAvatarAttachmentIfCurrent(
                        superseded,
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    ) else { throw CancellationError() }
                }

                try Task.checkCancellation()
                guard await outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                ) else { throw CancellationError() }
                let prepared = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.prepareProfileAvatarUpload(jpegData: avatarJPEG)
                }
                guard prepared.sourceSHA256 == ProfileAvatarUploadPolicy.sha256(of: avatarJPEG)
                else { throw ProfileAvatarUploadError.invalidServiceResponse }

                pendingAttachment = PendingProfileAvatarAttachment(
                    assetID: prepared.assetID,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID,
                    sourceSHA256: prepared.sourceSHA256,
                    finalizedAt: Date()
                )
                updatedState = try await commitAuthenticatedMutation(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                ) { persisted in
                    persisted.pendingProfileAvatarAttachment = pendingAttachment
                }
                await publishLatestState()
            }

            shouldRestartInterruptedAvatarResume = false
            attemptedPendingAttachment = pendingAttachment
            let avatarUpdate = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.resumeProfileAvatarAttachment(assetID: pendingAttachment.assetID)
            }
            guard avatarUpdate.id.caseInsensitiveCompare(expectedUserID) == .orderedSame else {
                throw AccountSetupError.accountChanged
            }
            updatedState = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                guard persisted.pendingProfileAvatarAttachment == pendingAttachment
                else { throw CancellationError() }
                guard let currentProfile = persisted.profile,
                      let committedProfile = UserProfileMutationMergePolicy.merge(
                        response: avatarUpdate,
                        current: currentProfile
                      )
                else { throw AccountSetupError.accountChanged }
                persisted.profile = committedProfile
                persisted.pendingProfileAvatarAttachment = nil
            }
            await publishLatestState()
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let attemptedPendingAttachment,
               ProfileAvatarPendingAttachmentPolicy.shouldDiscard(after: error) {
                _ = await clearPendingProfileAvatarAttachmentIfCurrent(
                    attemptedPendingAttachment,
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                )
            }
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            )
            else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    private func cancelAllProfileWorkAndWait() async {
        // Snapshot and cancel both lanes before awaiting either. A foreground update may itself
        // be waiting for the silent retry to unwind, so sequential cancellation could otherwise
        // delay sign-out behind the full scan window.
        let updateTask = profileUpdateTask
        let resumeTask = profileAvatarResumeTask
        profileUpdateTask = nil
        profileUpdateTaskID = nil
        profileAvatarResumeTask = nil
        profileAvatarResumeTaskID = nil
        updateTask?.cancel()
        resumeTask?.cancel()
        if let updateTask { _ = await updateTask.value }
        if let resumeTask { await resumeTask.value }
        isUpdatingProfile = false
    }

    /// Starts at most one silent retry for a finalized upload. The task captures the encrypted
    /// record and account epoch up front; the current session is resolved inside the task and
    /// must still exactly match before any authenticated request is sent.
    private func schedulePendingProfileAvatarResume() {
        guard appReviewDemoMutationsAllowed,
              profileAvatarResumeTask == nil,
              !isSigningOut,
              !isUpdatingProfile,
              isSignedIn,
              isOnline,
              accountSetupStep == nil,
              communicationAccessGranted,
              capabilities?.enablesProfileAvatars == true,
              let expectedUserID = profile?.id,
              let pendingAttachment = state.pendingProfileAvatarAttachment
        else { return }
        guard authenticatedRefreshCount == 0 else {
            profileAvatarResumeRequestedAfterRefresh = true
            return
        }

        let expectedAccountEpoch = accountEpoch
        let taskID = UUID()
        profileAvatarResumeTaskID = taskID
        profileAvatarResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resumePendingProfileAvatarAttachment(
                pendingAttachment,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID
            )
            guard self.profileAvatarResumeTaskID == taskID else { return }
            self.profileAvatarResumeTask = nil
            self.profileAvatarResumeTaskID = nil
        }
    }

    private func cancelProfileAvatarResumeAndWait() async {
        guard let task = profileAvatarResumeTask else {
            profileAvatarResumeTaskID = nil
            return
        }
        profileAvatarResumeTask = nil
        profileAvatarResumeTaskID = nil
        task.cancel()
        await task.value
    }

    private func resumePendingProfileAvatarAttachment(
        _ pendingAttachment: PendingProfileAvatarAttachment,
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String
    ) async {
        guard !Task.isCancelled,
              !isSigningOut,
              isSignedIn,
              isOnline,
              state.pendingProfileAvatarAttachment == pendingAttachment,
              let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else { return }

        guard ProfileAvatarPendingAttachmentPolicy.isResumable(
            pendingAttachment,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else {
            _ = await clearPendingProfileAvatarAttachmentIfCurrent(
                pendingAttachment,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            )
            return
        }

        do {
            let avatarUpdate = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.resumeProfileAvatarAttachment(
                    assetID: pendingAttachment.assetID
                )
            }
            guard avatarUpdate.id.caseInsensitiveCompare(expectedUserID) == .orderedSame else {
                throw AccountSetupError.accountChanged
            }
            let updatedState = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                guard persisted.pendingProfileAvatarAttachment == pendingAttachment
                else { throw CancellationError() }
                guard let currentProfile = persisted.profile,
                      let committedProfile = UserProfileMutationMergePolicy.merge(
                        response: avatarUpdate,
                        current: currentProfile
                      )
                else { throw AccountSetupError.accountChanged }
                persisted.profile = committedProfile
                persisted.pendingProfileAvatarAttachment = nil
            }
            await publishLatestState()
        } catch is CancellationError {
            return
        } catch {
            // Timeout, loss of connectivity, server errors, and cancellation retain the finalized
            // record. Only a terminal rejection/not-found response makes a future retry unsafe.
            guard ProfileAvatarPendingAttachmentPolicy.shouldDiscard(after: error) else { return }
            _ = await clearPendingProfileAvatarAttachmentIfCurrent(
                pendingAttachment,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            )
        }
    }

    @discardableResult
    private func clearPendingProfileAvatarAttachmentIfCurrent(
        _ pendingAttachment: PendingProfileAvatarAttachment,
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async -> Bool {
        do {
            let updatedState = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                guard persisted.pendingProfileAvatarAttachment == pendingAttachment
                else { throw CancellationError() }
                persisted.pendingProfileAvatarAttachment = nil
            }
            await publishLatestState()
            return true
        } catch {
            return false
        }
    }

    func completePaymentPinSetup(pin: String) async {
        guard !rejectAppReviewDemoMutation() else { return }
        guard accountSetupStep == .paymentPin else { return }
        guard isOnline else {
            lastError = "Connect to the internet to set your wallet PIN."
            return
        }
        guard isValidPaymentPin(pin) else {
            lastError = "Enter a four-digit wallet PIN."
            return
        }

        isCompletingAccountSetup = true
        defer { isCompletingAccountSetup = false }
        do {
            guard let expectedSessionID = await sessions.current()?.sessionId else {
                throw APIClientError.signedOut
            }
            let status = try await api.setPaymentPin(pin: pin)
            guard isSignedIn,
                  accountSetupStep == .paymentPin,
                  await sessions.current()?.sessionId == expectedSessionID
            else { throw APIClientError.signedOut }
            guard status.paymentPinSet == true else { throw AccountSetupError.pinNotEnabled }
            try await store.update { persisted in
                persisted.profile?.paymentPinSet = true
            }
            await publishLatestState()
            guard let updatedProfile = state.profile else { throw AuthUIError.missingUser }
            if let assurance = status.sessionAssurance {
                sessionAssurance = assurance
            } else {
                sessionAssurance = try await api.sessionAssurance()
            }
            accountSetupStep = AccountSetupPolicy.reconcile(
                accountSetupStep,
                with: updatedProfile,
                assurance: sessionAssurance
            )
            if accountSetupStep == nil {
                biometricAccessState = .authorized
                await resumeAuthenticatedSessionIfNeeded()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unlockSessionWithPIN(_ pin: String) async {
        guard accountSetupStep == .loginUnlock, !isCompletingAccountSetup else { return }
        guard isOnline else {
            lastError = "Connect to the internet to unlock Kit Pay."
            return
        }
        guard isValidPaymentPin(pin) else {
            lastError = "Enter your four-digit Kit Pay PIN."
            return
        }
        guard let expectedSessionID = await sessions.current()?.sessionId,
              let expectedUserID = profile?.id
        else {
            lastError = APIClientError.signedOut.localizedDescription
            return
        }
        let expectedAccountEpoch = accountEpoch

        isCompletingAccountSetup = true
        defer { isCompletingAccountSetup = false }
        do {
            let result = try await api.unlockSession(pin: pin)
            guard result.method.caseInsensitiveCompare("pin") == .orderedSame,
                  result.sessionAssurance.grantsFullAccess,
                  isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id == expectedUserID,
                  await sessions.current()?.sessionId == expectedSessionID
            else { throw AccountSetupError.sessionNotUnlocked }
            sessionAssurance = result.sessionAssurance
            guard let currentProfile = profile else { throw AuthUIError.missingUser }
            accountSetupStep = AccountSetupPolicy.reconcile(
                accountSetupStep,
                with: currentProfile,
                assurance: sessionAssurance
            )
            guard accountSetupStep == nil else { throw AccountSetupError.sessionNotUnlocked }
            biometricAccessState = .authorized
            homeBiometricState = biometricUnlockEnabled ? .authorized : .notRequired
            if !biometricUnlockEnabled,
               result.sessionAssurance.loginUnlock.supportsBiometricSignature {
                _ = try? await api.removeBiometricKey()
                if let updatedAssurance = try? await api.sessionAssurance() {
                    sessionAssurance = updatedAssurance
                }
            }
            biometricSignInPermanentlyUnavailable = false
            biometricPINRecoveryRequiresEnrollmentRemoval = false
            await resumeAuthenticatedSessionIfNeeded()
        } catch {
            guard isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  await sessions.current()?.sessionId == expectedSessionID
            else { return }
            lastError = error.localizedDescription
        }
    }

    func unlockSessionWithBiometrics() async {
        guard accountSetupStep == .loginUnlock,
              loginUnlockSupportsBiometrics,
              !isCompletingAccountSetup,
              isOnline,
              let expectedSessionID = await sessions.current()?.sessionId,
              let expectedUserID = profile?.id
        else { return }
        let expectedAccountEpoch = accountEpoch
        let expectedInstallationID = installationID()

        isCompletingAccountSetup = true
        biometricErrorMessage = nil
        defer { isCompletingAccountSetup = false }
        do {
            let challenge = try await api.createLoginBiometricChallenge()
            let signature = try await biometrics.sign(
                signingPayload: challenge.signingPayload,
                userID: expectedUserID,
                sessionID: expectedSessionID,
                installationID: expectedInstallationID,
                reason: "Use \(biometricDisplayName) to finish signing in to Kit Pay"
            )
            guard isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id == expectedUserID,
                  await sessions.current()?.sessionId == expectedSessionID
            else { throw KitBiometricError.accountChanged }
            let result = try await api.assertLoginBiometricChallenge(
                challengeId: challenge.challengeId,
                nonce: challenge.nonce,
                signature: signature
            )
            guard result.method.caseInsensitiveCompare("biometric_signature") == .orderedSame,
                  result.sessionAssurance.grantsFullAccess,
                  isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id == expectedUserID,
                  await sessions.current()?.sessionId == expectedSessionID
            else { throw AccountSetupError.sessionNotUnlocked }
            sessionAssurance = result.sessionAssurance
            guard let currentProfile = profile else { throw AuthUIError.missingUser }
            accountSetupStep = AccountSetupPolicy.reconcile(
                accountSetupStep,
                with: currentProfile,
                assurance: sessionAssurance
            )
            guard accountSetupStep == nil else { throw AccountSetupError.sessionNotUnlocked }
            biometricAccessState = .authorized
            homeBiometricState = .authorized
            biometricSignInPermanentlyUnavailable = false
            biometricPINRecoveryRequiresEnrollmentRemoval = false
            await resumeAuthenticatedSessionIfNeeded()
        } catch {
            guard isSignedIn,
                  accountEpoch == expectedAccountEpoch,
                  await sessions.current()?.sessionId == expectedSessionID
            else { return }
            biometricErrorMessage = error.localizedDescription
            if let biometricError = error as? KitBiometricError {
                if biometricError == .lockedOut {
                    biometricSignInPermanentlyUnavailable = true
                    biometricPINRecoveryRequiresEnrollmentRemoval = false
                } else if [.biometricSetChanged, .enrollmentMissing, .keyMissing, .notEnrolled,
                           .unavailable, .passcodeNotSet].contains(biometricError) {
                    await biometrics.removeAnyEnrollment()
                    biometricUnlockEnabled = false
                    biometricAccessState = .notRequired
                    homeBiometricState = .notRequired
                    biometricSignInPermanentlyUnavailable = true
                    biometricPINRecoveryRequiresEnrollmentRemoval = true
                }
            }
        }
    }

    private func reloadCapabilities() async -> Bool {
        // Keep the last confirmed value while requests are in flight. A newer authoritative
        // completion supersedes older results, while cancellation leaves older work eligible to
        // provide the last confirmed value.
        let requestGeneration = capabilitiesRequestTracker.begin()
        let expectedAccountEpoch = accountEpoch
        let expectedSession = await sessions.current()
        let expectedSessionID = expectedSession?.sessionId
        let expectedDeferredFeatureScope: MessagingDeferredFeatureScope?
        if isSignedIn,
           let expectedSession,
           let profileID = profile?.id,
           SessionAccountBindingPolicy.matches(expectedSession, profile: profile) {
            expectedDeferredFeatureScope = MessagingDeferredFeatureScope(
                accountEpoch: expectedAccountEpoch,
                userID: profileID,
                sessionID: expectedSession.sessionId
            )
        } else {
            expectedDeferredFeatureScope = nil
        }
        guard let offlineDirectCapabilityRequest = await store
            .beginMessagingOfflineDirectCreationCapabilityRequest(
                scope: expectedDeferredFeatureScope
            )
        else { return false }
        // Binding happens before the request suspends. A replacement account/session therefore
        // loses the previous decision immediately, while a retry for this same scope keeps the
        // last authenticated true *or false* result until a newer response is accepted.
        if let expectedDeferredFeatureScope {
            bindDeferredMessagingFeatures(to: expectedDeferredFeatureScope)
        } else if !isSignedIn {
            // Signed-out discovery has no account scope. While signed in, failure to prove a new
            // scope is not evidence that the current one changed, so retain its explicit denial.
            resetDeferredMessagingFeatures()
        }
        do {
            let discovered = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.capabilities()
            }
            guard await capabilitiesContextIsCurrent(
                      accountEpoch: expectedAccountEpoch,
                      sessionID: expectedSessionID
                  ),
                  capabilitiesRequestTracker.accepts(
                      requestGeneration,
                      cancelled: false
                  )
            else { return false }
            let featureDemoOwnerID = AppReviewDemoAccessPolicy.ownerID(
                    features: discovered.features,
                    authority: .authenticatedSession,
                    isSignedIn: isSignedIn,
                    profileID: profile?.id,
                    sessionID: expectedSession?.sessionId,
                    sessionAccountID: expectedSession?.accountId
                )
            let scopedDemoOwnerID = AppReviewDemoAccessPolicy.scopedOwnerID(
                communicationAccess: discovered.communicationAccess,
                financialAccess: discovered.financialAccess,
                authority: .authenticatedSession,
                isSignedIn: isSignedIn,
                profileID: profile?.id,
                sessionID: expectedSession?.sessionId,
                sessionAccountID: expectedSession?.accountId
            )
            let demoFence = AppReviewDemoCapabilityFenceDecision.resolved(
                ownerID: scopedDemoOwnerID ?? featureDemoOwnerID
            )
            // Arm the transport fence before exposing demo content. When the capability is
            // authoritatively withdrawn, keep the fence through projection replacement so stale
            // synthetic rows and already-presented sheets never gain a writable interval.
            if demoFence.keepsTransportFenceAfterProjection {
                await api.setAppReviewDemoReadOnly(true, sessionID: expectedSessionID)
                outboxWakeTask?.cancel()
                outboxWakeTask = nil
                communicationReplayTask?.cancel()
                communicationReplayTask = nil
                CommunicationBackgroundReplayScheduler.shared.cancel()
            }
            guard await capabilitiesContextIsCurrent(
                      accountEpoch: expectedAccountEpoch,
                      sessionID: expectedSessionID
                  ), capabilitiesRequestTracker.accepts(
                      requestGeneration,
                      cancelled: false
                  )
            else { return false }
            if isSignedIn, let currentAssurance = sessionAssurance {
                sessionAssurance = currentAssurance.applyingTopLevelAccess(
                    communication: discovered.communicationAccess,
                    financial: discovered.financialAccess
                )
                if let profile {
                    accountSetupStep = AccountSetupPolicy.reconcile(
                        accountSetupStep,
                        with: profile,
                        assurance: sessionAssurance
                    )
                }
            }
            authenticatedAppReviewDemoOwnerID = demoFence.projectedOwnerID
            // Publish the new in-memory decision before the protected receipt write suspends. In
            // particular, an authoritative withdrawal must close every UI/send gate immediately;
            // removing the durable receipt below preserves that result across the next launch.
            capabilities = discovered
            if let expectedDeferredFeatureScope {
                messagingDeferredFeatureSnapshot.confirm(
                    groups: messagingGroupsEnabled,
                    reactions: messagingReactionsEnabled,
                    messageEdits: messagingMessageEditsEnabled,
                    for: expectedDeferredFeatureScope
                )
            }
            if let expectedDeferredFeatureScope {
                let receipt = MessagingOfflineDirectCreationCapabilityReceipt(
                    ownerUserID: expectedDeferredFeatureScope.userID,
                    sessionID: expectedDeferredFeatureScope.sessionID,
                    authoritativeCapabilities: discovered,
                    accountMutationsAllowed: !demoFence.keepsTransportFenceAfterProjection
                )
                do {
                    let decisionCommitted = try await store
                        .commitMessagingOfflineDirectCreationCapabilityDecision(
                            receipt,
                            request: offlineDirectCapabilityRequest
                        )
                    // Another accepted response or account/session lifetime reached the protected
                    // store first. It is authoritative; this completion must not publish or undo it.
                    guard decisionCommitted else { return false }
                } catch {
                    // The live response below remains authoritative for this process. No new
                    // durable grant exists unless the protected-state write actually committed.
                }
                guard await capabilitiesContextIsCurrent(
                          accountEpoch: expectedAccountEpoch,
                          sessionID: expectedSessionID
                      ), capabilitiesRequestTracker.accepts(
                          requestGeneration,
                          cancelled: false
                      )
                else { return false }
            }
            await publishLatestState()
            if !demoFence.keepsTransportFenceAfterProjection {
                await api.setAppReviewDemoReadOnly(false, sessionID: expectedSessionID)
            }
            // A notification tap may have arrived while capability discovery was unavailable.
            // The accepted, session-bound response is the authoritative wake for that durable
            // route; replay now instead of waiting for another foreground or connectivity event.
            await ClaimablePaymentNotificationActionDispatcher.shared.replayPending()
            return true
        } catch {
            guard await capabilitiesContextIsCurrent(
                      accountEpoch: expectedAccountEpoch,
                      sessionID: expectedSessionID
                  )
            else { return false }
            let cancelled = RefreshCancellationPolicy.shouldSuppress(
                error,
                taskIsCancelled: Task.isCancelled
            )
            guard capabilitiesRequestTracker.accepts(
                requestGeneration,
                cancelled: cancelled
            ) else {
                // A view/task cancellation is not evidence that the server withdrew a
                // previously confirmed capability projection, and an older completion must not
                // overwrite a newer authoritative result.
                return false
            }
            // Failure is not evidence that the authenticated server withdrew the review-account
            // policy. Retain both the in-memory owner and the transport fence until a successful,
            // session-bound capabilities response says otherwise.
            let demoFence = AppReviewDemoCapabilityFenceDecision.failed(
                previousOwnerID: authenticatedAppReviewDemoOwnerID
            )
            authenticatedAppReviewDemoOwnerID = demoFence.projectedOwnerID
            if demoFence.keepsTransportFenceAfterProjection {
                await api.setAppReviewDemoReadOnly(true, sessionID: expectedSessionID)
            }
            // `capabilities` intentionally represents only a live response. The separate scoped
            // messaging snapshot retains the last authenticated allow/deny decisions so a failed
            // refresh cannot turn an explicit denial into the unknown (locally queueable) state.
            capabilities = nil
            await publishLatestState()
            lastError = error.localizedDescription
            return false
        }
    }

    private func capabilitiesContextIsCurrent(
        accountEpoch expectedAccountEpoch: UUID,
        sessionID expectedSessionID: String?
    ) async -> Bool {
        guard accountEpoch == expectedAccountEpoch else { return false }
        let currentSessionID = await sessions.current()?.sessionId
        switch (expectedSessionID, currentSessionID) {
        case (nil, nil):
            return true
        case let (expected?, current?):
            return SessionRefreshPolicy.matchesSessionID(expected, current: current)
        default:
            return false
        }
    }

    var communicationBlockedPeople: [CommunicationBlockedPerson] {
        CommunicationBlockedPersonResolver.resolve(
            blocks: communicationBlocks,
            contacts: contactDirectory,
            conversations: state.conversations,
            currentUserID: profile?.id
        )
    }

    var communicationBlockCandidates: [CommunicationBlockCandidate] {
        CommunicationBlockCandidateResolver.resolve(
            contacts: contactDirectory,
            blocks: communicationBlocks,
            currentUserID: profile?.id
        )
    }

    var isCommunicationPrivacyBusy: Bool {
        isLoadingCommunicationPrivacy || communicationPrivacyMutation != nil
    }

    var hasUsableCommunicationPrivacyProjection: Bool {
        communicationPreferences != nil
            && CommunicationPrivacyAccessPolicy.isCompleteProjection(
                ownerUserID: profile?.id,
                hasLoadedCompleteProjection: hasLoadedCommunicationPrivacy,
                blocks: communicationBlocks
            )
    }

    func communicationPrivacyAllowsOutbound(to rawUserID: String?) -> Bool {
        guard appReviewDemoMutationsAllowed else { return false }
        return CommunicationPrivacyAccessPolicy.decision(
            ownerUserID: profile?.id,
            recipientUserID: rawUserID,
            hasLoadedCompleteProjection: hasUsableCommunicationPrivacyProjection,
            blocks: communicationBlocks
        ) == .allowed
    }

    /// Queueing into the encrypted local store is safe while the authoritative privacy projection
    /// is still loading. Transport remains blocked in `flushOutbox` until that projection is
    /// complete and explicitly allows every recipient. A known block still prevents composition.
    func communicationPrivacyAllowsLocalQueue(to rawUserID: String?) -> Bool {
        guard isSignedIn, !appReviewDemoIsActive else { return false }
        return CommunicationPrivacyAccessPolicy.decision(
            ownerUserID: profile?.id,
            recipientUserID: rawUserID,
            hasLoadedCompleteProjection: hasUsableCommunicationPrivacyProjection,
            blocks: communicationBlocks
        ) != .blocked
    }

    func isCommunicationBlocked(userID rawUserID: String?) -> Bool {
        guard let userID = CommunicationPrivacyIdentifier.canonicalUUID(rawUserID) else {
            return false
        }
        return communicationBlocks.contains { $0.blocked && $0.userId == userID }
    }

    private func communicationPrivacyDenialMessage(
        for rawUserID: String?,
        blockedMessage: String
    ) -> String? {
        switch CommunicationPrivacyAccessPolicy.decision(
            ownerUserID: profile?.id,
            recipientUserID: rawUserID,
            hasLoadedCompleteProjection: hasUsableCommunicationPrivacyProjection,
            blocks: communicationBlocks
        ) {
        case .allowed:
            return nil
        case .blocked:
            return blockedMessage
        case .unavailable:
            return "Communication privacy is still loading. Refresh and try again."
        }
    }

    func loadCommunicationPrivacy() async {
        guard !isLoadingCommunicationPrivacy, communicationPrivacyMutation == nil else { return }
        guard isOnline else {
            communicationPrivacyErrorMessage = "Connect to the internet to refresh communication privacy."
            return
        }
        communicationPrivacyRequestGeneration &+= 1
        let generation = communicationPrivacyRequestGeneration
        isLoadingCommunicationPrivacy = true
        communicationPrivacyErrorMessage = nil
        defer {
            if communicationPrivacyRequestGeneration == generation {
                isLoadingCommunicationPrivacy = false
            }
        }
        guard let context = await communicationPrivacyContext() else {
            if communicationPrivacyRequestGeneration == generation {
                communicationPrivacyErrorMessage = "Sign in again to manage communication privacy."
            }
            return
        }

        let previousBlockedUserIDs = Set(
            communicationBlocks.lazy.filter(\.blocked).map(\.userId)
        )
        do {
            let result = try await APIClientSessionBinding.$sessionID.withValue(
                context.sessionID
            ) {
                async let preferences = api.communicationPreferences()
                async let blocks = api.communicationBlocks()
                return try await (preferences, blocks)
            }
            guard communicationPrivacyRequestGeneration == generation,
                  await communicationPrivacyContextIsCurrent(context)
            else { return }
            communicationPreferences = result.0
            communicationBlocks = result.1
            hasLoadedCommunicationPrivacy = true
            publishSharedDestinationsIfPossible()
            rebuildCallContacts()
            await persistCommunicationPrivacyCache(context: context)
            let refreshedBlockedUserIDs = Set(result.1.lazy.filter(\.blocked).map(\.userId))
            if refreshedBlockedUserIDs != previousBlockedUserIDs {
                await refreshContactsAfterCommunicationBlockChange(context: context)
            }
        } catch is CancellationError {
            return
        } catch {
            guard communicationPrivacyRequestGeneration == generation,
                  await communicationPrivacyContextIsCurrent(context)
            else { return }
            communicationPrivacyErrorMessage = CommunicationPrivacyErrorCopy.message(
                for: error,
                operation: .load
            )
        }
    }

    func setPhoneDiscoverable(_ enabled: Bool) async {
        await updateCommunicationPreference(.phoneDiscovery(enabled))
    }

    func setDirectMessageRequestsEnabled(_ enabled: Bool) async {
        await updateCommunicationPreference(.messageRequests(enabled))
    }

    func setMessagingPresenceVisible(_ visible: Bool) async {
        await updateCommunicationPreference(.presenceVisibility(visible))
        guard communicationPreferences?.messagingPresenceVisible == visible else { return }
        // Realtime capability presence is the server's effective preference/rollout projection.
        // Refresh it after PATCH so the socket reconnects against current authority.
        _ = await reloadCapabilities()
    }

    /// Whether this installation may upload its address book so Kit Pay can match contacts who
    /// already have an account. Device-local: the server carries no such preference, and
    /// `CommunicationPreferencesDTO` rejects unknown keys, so the client cannot invent a wire
    /// field without breaking already-shipped builds. Never chosen reads as enabled, which
    /// preserves the behaviour every existing installation already has.
    var contactDiscoveryEnabled: Bool {
        state.contactDiscoveryEnabled ?? true
    }

    func setContactDiscoveryEnabled(_ enabled: Bool) async {
        guard !rejectAppReviewDemoMutation() else { return }
        guard contactDiscoveryEnabled != enabled else { return }
        do {
            try await store.update { persisted in persisted.contactDiscoveryEnabled = enabled }
            await publishLatestState()
        } catch {
            // A privacy choice must take effect even if protected storage is momentarily
            // unavailable; the next successful write persists it.
            state.contactDiscoveryEnabled = enabled
        }
        if enabled {
            contactSyncState = .idle
            scheduleAutomaticContactSync()
        } else {
            invalidateContactSyncForRevocation()
            await clearLocalContacts(resultingState: .disabledByPreference)
        }
    }

    /// Records the server-backed discoverability choices made during account setup.
    ///
    /// They cannot be sent yet: `communicationPrivacyContext()` deliberately refuses to run while
    /// `accountSetupStep != nil` or before the session grants full access. Holding the intent in
    /// the encrypted, account-bound state means an interrupted setup — a KYC review that takes
    /// hours, or an app relaunch — still ends with the choices the user actually made.
    func recordPendingAccountDiscoveryChoice(_ choice: PendingAccountDiscoveryChoice) async {
        guard appReviewDemoMutationsAllowed else { return }
        do {
            try await store.update { persisted in
                persisted.pendingAccountDiscoveryChoice = choice
            }
            await publishLatestState()
        } catch {
            state.pendingAccountDiscoveryChoice = choice
        }
    }

    /// Drains the choice recorded above, the first time the session is authorized enough to
    /// commit it. Left in place on any failure so the next opportunity retries it.
    func applyPendingAccountDiscoveryChoiceIfPossible() async {
        guard appReviewDemoMutationsAllowed,
              let pending = state.pendingAccountDiscoveryChoice,
              !isApplyingAccountDiscoveryChoice,
              !isSigningOut,
              isSignedIn,
              isOnline,
              accountSetupStep == nil,
              communicationAccessGranted
        else { return }
        isApplyingAccountDiscoveryChoice = true
        defer { isApplyingAccountDiscoveryChoice = false }

        if communicationPreferences == nil {
            await loadCommunicationPrivacy()
        }
        guard let loaded = communicationPreferences else { return }
        for change in pending.outstandingChanges(given: loaded) {
            await updateCommunicationPreference(change)
            // Stop at the first write that did not land — including a conflict resolved in
            // another device's favour — rather than fighting a newer choice.
            guard let refreshed = communicationPreferences,
                  change.isSatisfied(by: refreshed)
            else { return }
        }
        do {
            try await store.update { persisted in
                persisted.pendingAccountDiscoveryChoice = nil
            }
            await publishLatestState()
        } catch {
            state.pendingAccountDiscoveryChoice = nil
        }
    }

    func setCommunicationBlocked(_ blocked: Bool, userID rawUserID: String) async -> Bool {
        guard appReviewDemoMutationsAllowed else {
            communicationPrivacyErrorMessage = AppReviewDemoMutationPolicy.readOnlyMessage
            return false
        }
        guard let userID = CommunicationPrivacyIdentifier.canonicalUUID(rawUserID),
              userID != CommunicationPrivacyIdentifier.canonicalUUID(profile?.id)
        else {
            communicationPrivacyErrorMessage = "This Kit Pay account cannot be updated."
            return false
        }
        guard !AppReviewDemoContent.isSyntheticPeerID(userID) else {
            communicationPrivacyErrorMessage = AppReviewDemoMutationPolicy.readOnlyMessage
            return false
        }
        if !hasUsableCommunicationPrivacyProjection {
            await loadCommunicationPrivacy()
            guard hasUsableCommunicationPrivacyProjection else { return false }
        }
        guard isCommunicationBlocked(userID: userID) != blocked else { return true }
        guard communicationPrivacyMutation == nil, !isLoadingCommunicationPrivacy else {
            return false
        }
        guard isOnline else {
            communicationPrivacyErrorMessage = "Connect to the internet to update blocked accounts."
            return false
        }
        communicationPrivacyRequestGeneration &+= 1
        let generation = communicationPrivacyRequestGeneration
        communicationPrivacyMutation = blocked ? .block(userID) : .unblock(userID)
        communicationPrivacyErrorMessage = nil
        defer {
            if communicationPrivacyRequestGeneration == generation {
                communicationPrivacyMutation = nil
            }
        }
        guard let context = await communicationPrivacyContext() else {
            if communicationPrivacyRequestGeneration == generation {
                communicationPrivacyErrorMessage = "Sign in again to update blocked accounts."
            }
            return false
        }

        do {
            let response = try await APIClientSessionBinding.$sessionID.withValue(
                context.sessionID
            ) {
                if blocked {
                    return try await api.blockCommunicationUser(userID: userID)
                }
                return try await api.unblockCommunicationUser(userID: userID)
            }
            guard communicationPrivacyRequestGeneration == generation,
                  await communicationPrivacyContextIsCurrent(context)
            else { return false }
            communicationBlocks.removeAll { $0.userId == userID }
            if response.blocked { communicationBlocks.insert(response, at: 0) }
            hasLoadedCommunicationPrivacy = true
            publishSharedDestinationsIfPossible()
            rebuildCallContacts()
            await persistCommunicationPrivacyCache(context: context)
            await refreshContactsAfterCommunicationBlockChange(context: context)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard communicationPrivacyRequestGeneration == generation,
                  await communicationPrivacyContextIsCurrent(context)
            else { return false }
            communicationPrivacyErrorMessage = CommunicationPrivacyErrorCopy.message(
                for: error,
                operation: blocked ? .block : .unblock
            )
            return false
        }
    }

    private func updateCommunicationPreference(_ change: CommunicationPreferenceChange) async {
        guard appReviewDemoMutationsAllowed else {
            communicationPrivacyErrorMessage = AppReviewDemoMutationPolicy.readOnlyMessage
            return
        }
        if communicationPreferences == nil {
            await loadCommunicationPrivacy()
        }
        guard let current = communicationPreferences,
              communicationPrivacyMutation == nil,
              !isLoadingCommunicationPrivacy
        else { return }
        guard isOnline else {
            communicationPrivacyErrorMessage = "Connect to the internet to update communication privacy."
            return
        }
        communicationPrivacyRequestGeneration &+= 1
        let generation = communicationPrivacyRequestGeneration
        communicationPrivacyMutation = .preference
        communicationPrivacyErrorMessage = nil
        defer {
            if communicationPrivacyRequestGeneration == generation {
                communicationPrivacyMutation = nil
            }
        }
        guard let context = await communicationPrivacyContext() else {
            if communicationPrivacyRequestGeneration == generation {
                communicationPrivacyErrorMessage = "Sign in again to update communication privacy."
            }
            return
        }

        do {
            let result = try await saveCommunicationPreference(
                change,
                current: current,
                context: context,
                generation: generation
            )
            guard communicationPrivacyRequestGeneration == generation,
                  await communicationPrivacyContextIsCurrent(context)
            else { return }
            switch result {
            case .updated(let preferences):
                communicationPreferences = preferences
            case .refreshedAfterConflict(let preferences):
                communicationPreferences = preferences
                communicationPrivacyErrorMessage =
                    "Your communication settings changed on another device. The latest choices are shown; review them and try again."
            }
            await persistCommunicationPrivacyCache(context: context)
        } catch is CancellationError {
            return
        } catch is CommunicationPreferenceConflictRefreshFailure {
            guard communicationPrivacyRequestGeneration == generation,
                  await communicationPrivacyContextIsCurrent(context)
            else { return }
            await invalidateCommunicationPrivacyProjection(context: context)
            communicationPrivacyErrorMessage =
                "Your communication settings changed on another device, but the latest choices could not be loaded. Refresh and try again."
        } catch {
            guard communicationPrivacyRequestGeneration == generation,
                  await communicationPrivacyContextIsCurrent(context)
            else { return }
            communicationPrivacyErrorMessage = CommunicationPrivacyErrorCopy.message(
                for: error,
                operation: .updatePreferences
            )
        }
    }

    private func saveCommunicationPreference(
        _ change: CommunicationPreferenceChange,
        current: CommunicationPreferencesDTO,
        context: CommunicationPrivacyAccountContext,
        generation: UInt64
    ) async throws -> CommunicationPreferenceSaveResult {
        do {
            let updated = try await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
                try await api.updateCommunicationPreferences(
                    change.request(version: current.version)
                )
            }
            guard change.isValidTransition(from: current, to: updated) else {
                throw APIClientError.invalidResponse
            }
            return .updated(updated)
        } catch let error as APIErrorPayload
            where error.code.caseInsensitiveCompare(
                "COMMUNICATION_PREFERENCES_VERSION_CONFLICT"
            ) == .orderedSame {
            let latest: CommunicationPreferencesDTO
            do {
                latest = try await APIClientSessionBinding.$sessionID.withValue(context.sessionID) {
                    try await api.communicationPreferences()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CommunicationPreferenceConflictRefreshFailure()
            }
            guard communicationPrivacyRequestGeneration == generation,
                  await communicationPrivacyContextIsCurrent(context)
            else { throw CancellationError() }
            // Do not silently replay the user's edit over a newer choice from another device.
            return .refreshedAfterConflict(latest)
        }
    }

    private func communicationPrivacyContext() async -> CommunicationPrivacyAccountContext? {
        guard !isSigningOut,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted,
              let userID = CommunicationPrivacyIdentifier.canonicalUUID(profile?.id)
        else { return nil }
        let expectedAccountEpoch = accountEpoch
        guard let sessionID = await sessions.current()?.sessionId,
              !isSigningOut,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted,
              accountEpoch == expectedAccountEpoch,
              CommunicationPrivacyIdentifier.canonicalUUID(profile?.id) == userID
        else { return nil }
        return CommunicationPrivacyAccountContext(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: sessionID
        )
    }

    private func communicationPrivacyContextIsCurrent(
        _ context: CommunicationPrivacyAccountContext
    ) async -> Bool {
        guard !Task.isCancelled,
              !isSigningOut,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted,
              accountEpoch == context.accountEpoch,
              CommunicationPrivacyIdentifier.canonicalUUID(profile?.id) == context.userID
        else { return false }
        return await sessions.current()?.sessionId == context.sessionID
    }

    private func resetCommunicationPrivacyState() {
        communicationPrivacyRequestGeneration &+= 1
        communicationPreferences = nil
        communicationBlocks = []
        isLoadingCommunicationPrivacy = false
        communicationPrivacyMutation = nil
        communicationPrivacyErrorMessage = nil
        hasLoadedCommunicationPrivacy = false
    }

    private func restoreCommunicationPrivacyCache() {
        resetCommunicationPrivacyState()
        guard let userID = CommunicationPrivacyIdentifier.canonicalUUID(profile?.id),
              CommunicationPrivacyIdentifier.canonicalUUID(state.communicationOwnerUserID)
                == userID,
              let cache = state.communicationPrivacy,
              cache.ownerUserId == userID
        else { return }
        communicationPreferences = cache.preferences
        communicationBlocks = cache.blocks
        hasLoadedCommunicationPrivacy = true
        publishSharedDestinationsIfPossible()
    }

    private func persistCommunicationPrivacyCache(
        context: CommunicationPrivacyAccountContext
    ) async {
        guard let preferences = communicationPreferences,
              let cache = CommunicationPrivacyCache(
                  ownerUserId: context.userID,
                  preferences: preferences,
                  blocks: communicationBlocks
              ),
              await communicationPrivacyContextIsCurrent(context)
        else { return }
        do {
            try await store.update { persisted in
                guard CommunicationPrivacyIdentifier.canonicalUUID(persisted.profile?.id)
                        == context.userID,
                      CommunicationPrivacyIdentifier.canonicalUUID(
                          persisted.communicationOwnerUserID
                      ) == context.userID
                else { throw StoreError.accountChanged }
                persisted.communicationPrivacy = cache
            }
        } catch {
            // Live server-confirmed state remains usable for this process. A later refresh retries
            // the encrypted cache write; never replace it with a less-authoritative projection.
        }
    }

    private func invalidateCommunicationPrivacyProjection(
        context: CommunicationPrivacyAccountContext
    ) async {
        communicationPreferences = nil
        communicationBlocks = []
        hasLoadedCommunicationPrivacy = false
        rebuildCallContacts()
        do {
            try await store.update { persisted in
                guard CommunicationPrivacyIdentifier.canonicalUUID(persisted.profile?.id)
                        == context.userID,
                      CommunicationPrivacyIdentifier.canonicalUUID(
                          persisted.communicationOwnerUserID
                      ) == context.userID
                else { throw StoreError.accountChanged }
                persisted.communicationPrivacy = nil
            }
        } catch {
            // The in-memory projection remains closed. Account binding rejects this cache if the
            // session changes, and the next successful refresh replaces it atomically.
        }
    }

    /// Contact matching is authorization-sensitive on the backend. Force the next automatic pass
    /// to fetch a fresh server projection after either side of a block transition instead of
    /// waiting for the ordinary fifteen-minute unchanged-address-book interval.
    private func refreshContactsAfterCommunicationBlockChange(
        context: CommunicationPrivacyAccountContext
    ) async {
        guard await communicationPrivacyContextIsCurrent(context) else { return }
        contactAuthorizationRevision &+= 1
        do {
            try await store.update { persisted in
                guard CommunicationPrivacyIdentifier.canonicalUUID(persisted.profile?.id)
                        == context.userID,
                      CommunicationPrivacyIdentifier.canonicalUUID(
                          persisted.communicationOwnerUserID
                      ) == context.userID
                else { throw StoreError.accountChanged }
                persisted.contactSyncLastCompletedAt = nil
            }
            let refreshedState = await store.snapshot()
            guard await communicationPrivacyContextIsCurrent(context),
                  CommunicationPrivacyIdentifier.canonicalUUID(refreshedState.profile?.id)
                    == context.userID,
                  CommunicationPrivacyIdentifier.canonicalUUID(
                      refreshedState.communicationOwnerUserID
                  ) == context.userID
            else { return }
            await publishLatestState()
        } catch {
            // The live block already filters every in-memory communication picker. Clearing this
            // process's freshness marker still makes the next pass re-check server discovery.
            guard await communicationPrivacyContextIsCurrent(context) else { return }
            state.contactSyncLastCompletedAt = nil
        }
        guard await communicationPrivacyContextIsCurrent(context) else { return }
        scheduleAutomaticContactSync()
    }

    @discardableResult
    func persistConversationDraft(
        _ body: String,
        conversationId: String,
        writeVersion: ConversationDraftWriteVersion,
        mediaAttachments: [ConversationDraftMediaAttachment]? = nil
    ) async -> Bool {
        guard !isReadOnlyAppReviewDemoConversation(conversationId) else { return false }
        let expectedAccountEpoch = accountEpoch
        guard !Task.isCancelled,
              isSignedIn,
              !isSigningOut,
              let userID = profile?.id,
              let canonicalConversationID = OutboxPolicy.canonicalConversationID(conversationId)
        else { return false }
        let boundedBody = ConversationDraftPolicy.boundedBody(body)
        if let mediaAttachments {
            guard mediaAttachments.count <= ConversationDraftPolicy.maximumMediaAttachments,
                  mediaAttachments.allSatisfy(\.isStructurallyValid),
                  Set(mediaAttachments.map(\.id)).count == mediaAttachments.count
            else { return false }
            for attachment in mediaAttachments {
                let available: Bool
                switch attachment.storageKind {
                case .protectedFile:
                    available = await SecureMediaFileCache.shared.protectedOriginalURL(
                        forStorageKey: attachment.storageKey,
                        userID: userID,
                        expectedByteCount: attachment.byteCount
                    ) != nil
                case .encryptedBlob:
                    available = await SecureMediaFileCache.shared.encryptedBlobData(
                        forStorageKey: attachment.storageKey,
                        userID: userID,
                        expectedByteCount: attachment.byteCount
                    ) != nil
                }
                guard available else { return false }
            }
        }
        // A shared first-contact composer deliberately has no durable conversation yet. Its
        // staged inbox batch and protected media files remain the draft; writing an empty thread
        // here would break the atomic conversation+message+outbox boundary. Explicit Send passes
        // the same draft facts into the queue transaction, which becomes their first state row.
        if sharedInboxProvisionalRecipient(
            conversationID: canonicalConversationID
        ) != nil {
            return true
        }
        do {
            try Task.checkCancellation()
            try await store.update { persisted in
                try Task.checkCancellation()
                guard persisted.profile?.id.caseInsensitiveCompare(userID) == .orderedSame,
                      persisted.communicationOwnerUserID?.caseInsensitiveCompare(userID)
                        == .orderedSame
                else { throw StoreError.accountChanged }
                // Check conversation existence against durable truth, not the published UI
                // state: a momentarily stale publish must never block typing (or the send that
                // follows) in a conversation that genuinely exists.
                guard persisted.conversations.contains(where: {
                    OutboxPolicy.canonicalConversationID($0.id) == canonicalConversationID
                }) else { throw CancellationError() }
                ConversationDraftPolicy.store(
                    boundedBody,
                    conversationID: canonicalConversationID,
                    ownerUserID: userID,
                    writeVersion: writeVersion,
                    mediaAttachments: mediaAttachments,
                    in: &persisted
                )
            }
            try Task.checkCancellation()
            let snapshot = await store.snapshot()
            guard !Task.isCancelled,
                  isSignedIn,
                  !isSigningOut,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id.caseInsensitiveCompare(userID) == .orderedSame,
                  snapshot.profile?.id.caseInsensitiveCompare(userID) == .orderedSame,
                  snapshot.communicationOwnerUserID?.caseInsensitiveCompare(userID)
                    == .orderedSame
            else { return false }
            let snapshotDraft = snapshot.conversationDrafts?[canonicalConversationID]
            guard snapshotDraft?.writeVersion == writeVersion,
                  snapshotDraft?.body == boundedBody,
                  mediaAttachments.map({ requested in
                      (snapshotDraft?.mediaAttachments ?? []) == requested
                  }) ?? true
            else { return false }
            let currentDraft = state.conversationDrafts?[canonicalConversationID]
            if ConversationDraftPolicy.shouldApplySnapshotDraft(
                snapshotDraft,
                over: currentDraft,
                activeWriterID: conversationDraftWriterID
            ) {
                var drafts = state.conversationDrafts ?? [:]
                if let snapshotDraft {
                    drafts[canonicalConversationID] = snapshotDraft
                } else {
                    drafts.removeValue(forKey: canonicalConversationID)
                }
                state.conversationDrafts = drafts.isEmpty ? nil : drafts
            }
            return true
        } catch is CancellationError {
            return false
        } catch StoreError.accountChanged {
            return false
        } catch {
            guard isSignedIn,
                  !isSigningOut,
                  accountEpoch == expectedAccountEpoch,
                  profile?.id.caseInsensitiveCompare(userID) == .orderedSame,
                  state.conversations.contains(where: {
                      OutboxPolicy.canonicalConversationID($0.id) == canonicalConversationID
                  })
            else { return false }
            lastError = CustomerFacingMessagingCopy.draftSaveFailure
            return false
        }
    }

    func conversationDraft(for conversationId: String) -> String {
        guard let userID = profile?.id else { return "" }
        return ConversationDraftPolicy.body(
            conversationID: conversationId,
            ownerUserID: userID,
            in: state
        )
    }

    /// Restores composer-owned media only from the exact storage representation committed in the
    /// encrypted account state. Missing/corrupt bytes are omitted rather than exposing a broken
    /// chip; the next versioned draft write repairs the manifest without touching another account.
    func restoredConversationDraftMedia(
        for conversationId: String
    ) async -> [RestoredConversationDraftMediaAttachment] {
        let expectedAccountEpoch = accountEpoch
        let snapshot = await store.snapshot()
        guard let userID = snapshot.profile?.id,
              snapshot.communicationOwnerUserID?.caseInsensitiveCompare(userID) == .orderedSame
        else { return [] }
        let manifests = ConversationDraftPolicy.mediaAttachments(
            conversationID: conversationId,
            ownerUserID: userID,
            in: snapshot
        )
        var restored: [RestoredConversationDraftMediaAttachment] = []
        restored.reserveCapacity(manifests.count)
        for manifest in manifests {
            guard !Task.isCancelled else { return [] }
            switch manifest.storageKind {
            case .protectedFile:
                guard let url = await SecureMediaFileCache.shared.protectedOriginalURL(
                    forStorageKey: manifest.storageKey,
                    userID: userID,
                    expectedByteCount: manifest.byteCount
                ) else { continue }
                restored.append(RestoredConversationDraftMediaAttachment(
                    manifest: manifest,
                    data: nil,
                    localFileURL: url
                ))
            case .encryptedBlob:
                guard let data = await SecureMediaFileCache.shared.encryptedBlobData(
                    forStorageKey: manifest.storageKey,
                    userID: userID,
                    expectedByteCount: manifest.byteCount
                ) else { continue }
                restored.append(RestoredConversationDraftMediaAttachment(
                    manifest: manifest,
                    data: data,
                    localFileURL: nil
                ))
            }
        }
        let current = await store.snapshot()
        guard !Task.isCancelled,
              expectedAccountEpoch == accountEpoch,
              current.profile?.id.caseInsensitiveCompare(userID) == .orderedSame,
              current.communicationOwnerUserID?.caseInsensitiveCompare(userID) == .orderedSame
        else { return [] }
        return restored
    }

    func nextConversationDraftWriteVersion() -> ConversationDraftWriteVersion {
        conversationDraftWriteSequence &+= 1
        if conversationDraftWriteSequence == 0 {
            conversationDraftWriterID = UUID()
            conversationDraftWriteSequence = 1
        }
        return ConversationDraftWriteVersion(
            writerID: conversationDraftWriterID,
            sequence: conversationDraftWriteSequence
        )
    }

    @discardableResult
    func queueMessage(
        conversationId: String,
        title: String,
        recipientId: String? = nil,
        body: String,
        clientMessageID: UUID? = nil,
        draftClearVersion: ConversationDraftWriteVersion? = nil,
        submittedDraftMediaAttachments: [ConversationDraftMediaAttachment]? = nil,
        deliverAt: Date? = nil,
        replyToServerMessageID: String? = nil,
        textDiagnosticsProducerScope: LocalMediaDiagnosticProducerScope? = nil
    ) async -> Bool {
        guard !isReadOnlyAppReviewDemoConversation(conversationId) else {
            lastError = "This App Review preview is read-only."
            return false
        }
        return await queueValidatedMessage(
            conversationId: conversationId,
            title: title,
            recipientId: recipientId,
            body: body,
            clientMessageID: clientMessageID,
            draftClearVersion: draftClearVersion,
            submittedDraftMediaAttachments: submittedDraftMediaAttachments,
            submissionKind: .userText,
            deliverAt: deliverAt,
            replyToServerMessageID: replyToServerMessageID,
            textDiagnosticsProducerScope: textDiagnosticsProducerScope
        )
    }

    /// Queues a canonical payment event produced by a server-confirmed payment flow. This is the
    /// only bypass for the user-text `KITPAY1:` reservation and rejects noncanonical descriptors.
    @discardableResult
    func queuePaymentEvent(
        conversationId: String,
        title: String,
        recipientId: String,
        body: String,
        clientMessageID: UUID? = nil
    ) async -> Bool {
        guard !isReadOnlyAppReviewDemoConversation(conversationId) else {
            lastError = "This App Review preview is read-only."
            return false
        }
        return await queueValidatedMessage(
            conversationId: conversationId,
            title: title,
            recipientId: recipientId,
            body: body,
            clientMessageID: clientMessageID,
            draftClearVersion: nil,
            submissionKind: .paymentEvent
        )
    }

    /// Queues a group payment announcement or an answer to one, produced by a server-confirmed
    /// group payment flow. The only bypass for the user-text `KITGRP1:` reservation, and it goes
    /// to the whole group rather than to a pinned recipient.
    @discardableResult
    func queueGroupPaymentEvent(
        conversationId: String,
        title: String,
        body: String,
        clientMessageID: UUID? = nil
    ) async -> Bool {
        guard !isReadOnlyAppReviewDemoConversation(conversationId) else {
            lastError = "This App Review preview is read-only."
            return false
        }
        return await queueValidatedMessage(
            conversationId: conversationId,
            title: title,
            recipientId: nil,
            body: body,
            clientMessageID: clientMessageID,
            draftClearVersion: nil,
            submissionKind: .groupPaymentEvent
        )
    }

    /// Queues a canonical collaborative group-request event. This is the only bypass for the
    /// `KITGREQ1:` reservation and, like ordinary group-payment events, it is group-only.
    @discardableResult
    func queueGroupPaymentRequestEvent(
        conversationId: String,
        title: String,
        descriptor: KitGroupPaymentRequestMessage,
        clientMessageID: UUID? = nil
    ) async -> Bool {
        guard !isReadOnlyAppReviewDemoConversation(conversationId) else {
            lastError = "This App Review preview is read-only."
            return false
        }
        return await queueValidatedMessage(
            conversationId: conversationId,
            title: title,
            recipientId: nil,
            body: descriptor.encoded,
            clientMessageID: clientMessageID,
            draftClearVersion: nil,
            submissionKind: .groupPaymentRequestEvent
        )
    }

    /// Queues a reaction only through the typed reaction boundary. Plain composers and
    /// notification replies reserve `KITRXN1:` so pasted text cannot impersonate a reaction.
    @discardableResult
    func queueReactionEvent(
        conversationId: String,
        title: String,
        recipientId: String?,
        reaction: KitMessageReaction
    ) async -> Bool {
        guard messagingReactionLocalQueueEnabled else {
            lastError = messagingSendFailureMessage
            return false
        }
        guard !isReadOnlyAppReviewDemoConversation(conversationId) else {
            lastError = "This App Review preview is read-only."
            return false
        }
        let canonicalConversationID = conversationId.lowercased()
        guard state.messages.contains(where: { message in
            message.conversationId.lowercased() == canonicalConversationID
                && message.serverMessageId?.lowercased() == reaction.targetServerMessageID
                && message.secureMessagingHistory?.kind.isTimelineMetadata != true
        }) else {
            lastError = "This message is no longer available to react to."
            return false
        }
        return await queueValidatedMessage(
            conversationId: conversationId,
            title: title,
            recipientId: recipientId,
            body: reaction.encoded,
            clientMessageID: nil,
            draftClearVersion: nil,
            submissionKind: .reactionEvent
        )
    }

    /// Queues a correction only through the typed edit boundary. Plain composers and notification
    /// replies reserve `KITEDIT1:` so pasted text cannot impersonate somebody's second thought.
    @discardableResult
    func queueEditEvent(
        conversationId: String,
        title: String,
        recipientId: String?,
        edit: KitMessageEdit
    ) async -> Bool {
        guard messagingMessageEditLocalQueueEnabled else {
            lastError = messagingSendFailureMessage
            return false
        }
        guard !isReadOnlyAppReviewDemoConversation(conversationId) else {
            lastError = "This App Review preview is read-only."
            return false
        }
        let canonicalConversationID = conversationId.lowercased()
        // The same test the long-press menu applied, re-run at the moment of sending: the window
        // may have closed while the correction was being typed, and only one's own settled
        // message was ever eligible.
        guard state.messages.contains(where: { message in
            message.conversationId.lowercased() == canonicalConversationID
                && message.serverMessageId?.lowercased() == edit.targetServerMessageID
                && MessageEditAggregationPolicy.canEdit(message)
        }) else {
            lastError = "This message can no longer be edited."
            return false
        }
        return await queueValidatedMessage(
            conversationId: conversationId,
            title: title,
            recipientId: recipientId,
            body: edit.encoded,
            clientMessageID: nil,
            draftClearVersion: nil,
            submissionKind: .editEvent
        )
    }

    private func queueValidatedMessage(
        conversationId: String,
        title: String,
        recipientId: String?,
        body: String,
        clientMessageID: UUID?,
        draftClearVersion: ConversationDraftWriteVersion?,
        submittedDraftMediaAttachments: [ConversationDraftMediaAttachment]? = nil,
        submissionKind: SecureMessageSubmissionKind,
        deliverAt: Date? = nil,
        replyToServerMessageID: String? = nil,
        textDiagnosticsProducerScope: LocalMediaDiagnosticProducerScope? = nil
    ) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Only something a person typed can be an answer. Payment cards and reaction descriptors
        // are events the app authors; they point at nothing.
        let replyTarget = submissionKind == .userText
            ? replyToServerMessageID.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
            : nil
        guard replyToServerMessageID == nil || replyTarget != nil else {
            lastError = "That message is no longer available to reply to."
            return false
        }
        switch submissionKind {
        case .paymentEvent:
            guard KitPaymentMessage.parse(trimmed) != nil else {
                lastError = "Kit Pay could not validate this payment event."
                return false
            }
        case .groupPaymentEvent:
            guard KitGroupPaymentMessage.parse(trimmed) != nil else {
                lastError = "Kit Pay could not validate this payment event."
                return false
            }
        case .groupPaymentRequestEvent:
            guard KitGroupPaymentRequestMessage.parse(trimmed) != nil else {
                lastError = "Kit Pay could not validate this group request event."
                return false
            }
        case .reactionEvent:
            guard KitMessageReaction.parse(trimmed) != nil else {
                lastError = "Kit Pay could not validate this reaction."
                return false
            }
        case .editEvent:
            guard KitMessageEdit.parse(trimmed) != nil else {
                lastError = "Kit Pay could not validate this edit."
                return false
            }
        case .userText:
            guard SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(trimmed) else {
                lastError = "Messages can't start with a reserved Kit Pay event prefix."
                return false
            }
        }
        guard let cleanConversationId = OutboxPolicy.canonicalConversationID(conversationId) else {
            lastError = "This conversation is no longer available. Your message was not sent."
            return false
        }
        guard secureMessagingLocalQueueAvailable else {
            lastError = messagingSendFailureMessage
            return false
        }
        if let replyTarget {
            guard state.messages.contains(where: { message in
                message.conversationId.caseInsensitiveCompare(cleanConversationId)
                    == .orderedSame
                    && message.serverMessageId?.lowercased() == replyTarget
                    && message.secureMessagingHistory?.kind.isTimelineMetadata != true
            }) else {
                lastError = "That message is no longer available to reply to."
                return false
            }
        }
        // A GROUP thread has no single pinned recipient: the coordinator re-validates local
        // membership at queue time, and the per-member privacy/attestation gates run
        // authoritatively at flush and on the server. Payment events remain strictly two-party.
        let isGroupTarget = state.conversations.first(where: {
            $0.id.caseInsensitiveCompare(cleanConversationId) == .orderedSame
        })?.isGroup == true
        guard MessagingGroupCapabilityPolicy.allowsConversationMutation(
            isGroup: isGroupTarget,
            groupCapabilityEnabled: messagingGroupLocalQueueEnabled
        ) else {
            lastError = "Group messaging is not available right now. You can still read this conversation."
            return false
        }
        if isGroupTarget, submissionKind == .paymentEvent {
            lastError = "Payment events can only be sent in one-to-one chats."
            return false
        }
        if !isGroupTarget,
           (submissionKind == .groupPaymentEvent
            || submissionKind == .groupPaymentRequestEvent) {
            // The other half of the rule above: group payment wire belongs to the group it was
            // sent into, where every member can see the same announcement and answer for
            // themselves. A one-to-one thread has no group to claim from.
            lastError = "Group payments can only be sent in a group chat."
            return false
        }
        let recipientUserID: String?
        if isGroupTarget {
            recipientUserID = nil
        } else {
            guard let recipientId,
                  let recipientUUID = UUID(
                      uuidString: recipientId.trimmingCharacters(in: .whitespacesAndNewlines)
                  )
            else {
                lastError = "Choose one valid Kit Pay recipient."
                return false
            }
            recipientUserID = recipientUUID.uuidString.lowercased()
        }
        let provisionalRecipient = sharedInboxProvisionalRecipient(
            conversationID: cleanConversationId
        )
        if let provisionalRecipient {
            guard submissionKind == .userText,
                  recipientUserID == provisionalRecipient
            else {
                lastError = messagingSendFailureMessage
                return false
            }
        }
        guard let userID = profile?.id else {
            lastError = "Choose one valid Kit Pay recipient."
            return false
        }
        // Capture every piece of account-lifetime authority before the first suspension. A
        // same-user sign-out/re-login may replace the protected store while SessionStore is being
        // consulted; acquiring a lease afterwards would accidentally bless the old composer work
        // with the replacement login's authority.
        let expectedAccountEpoch = accountEpoch
        guard let commitAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
            forAccountID: userID
        ), let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: expectedSessionID,
            commitAdmission: commitAdmission
        ) else { return false }
        if let recipientUserID,
           !communicationPrivacyAllowsLocalQueue(to: recipientUserID) {
            lastError = "Unblock this account before sending a message."
            return false
        }
        guard MessagingGroupCapabilityPolicy.allowsConversationMutation(
            isGroup: isGroupTarget,
            groupCapabilityEnabled: messagingGroupLocalQueueEnabled
        ) else {
            lastError = "Group messaging is not available right now. You can still read this conversation."
            return false
        }
        do {
            let result = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: expectedAccountEpoch,
                sessionID: expectedSessionID,
                commitAdmission: commitAdmission
            ) {
                try await SecureMessagingExchangeCoordinator.shared.queueDeferredText(
                    forUserID: userID,
                    conversationID: cleanConversationId,
                    expectedRecipientUserID: recipientUserID,
                    title: title,
                    text: trimmed,
                    clientMessageID: clientMessageID,
                    submittedDraftBody: draftClearVersion == nil ? nil : body,
                    submittedDraftMediaAttachments: submittedDraftMediaAttachments,
                    draftClearVersion: draftClearVersion,
                    deliverAt: deliverAt,
                    replyToServerMessageID: replyTarget,
                    provisionalDirectRecipientUserID: provisionalRecipient,
                    commitAdmission: commitAdmission
                )
            }
            if submissionKind == .userText {
                LocalMediaPerformanceMonitor.shared.markTextOutboxCommitted(
                    messageID: result.clientMessageID,
                    producerScope: textDiagnosticsProducerScope
                )
            }
            guard await reloadOutboxStateIfCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return false }
            // The encrypted projection and command are durable now. `scheduleOutboxWake` owns
            // online delivery so the composer can clear without waiting for roster/network I/O.
            scheduleOutboxWake()
            return true
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    /// Queues the canonical encrypted card for one server-confirmed request. Both the financial
    /// recipient and the message idempotency UUID come from that exact response.
    @discardableResult
    func queuePaymentRequest(
        _ request: PaymentRequestDTO,
        recipientId: String,
        title: String,
        conversationId: String? = nil
    ) async -> Bool {
        if let conversationId,
           isReadOnlyAppReviewDemoConversation(conversationId) {
            lastError = "This App Review preview is read-only."
            return false
        }
        guard let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return false }
        let expectedAccountEpoch = accountEpoch
        let snapshot = await store.snapshot()
        let canonicalConversationID = conversationId.flatMap {
            FinancialRecoveryValidation.canonicalUUID($0)
        }
        guard conversationId == nil || canonicalConversationID != nil else {
            lastError = "Kit Pay could not confirm who should receive this request. Nothing was sent in chat."
            return false
        }
        let recovery = (snapshot.pendingPaymentRequestChatReceipts ?? []).first(where: {
            $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                && $0.recipientUserID.caseInsensitiveCompare(recipientId) == .orderedSame
                && $0.conversationID == canonicalConversationID
                && $0.confirmation?.requestID.caseInsensitiveCompare(request.id) == .orderedSame
                && $0.phase == .confirmed
        })
        let ownsDestinationWallet = state.wallets.contains {
            $0.id.caseInsensitiveCompare(request.destinationWalletId) == .orderedSame
                && $0.currency == request.currency
        }
        let targetRecipientID: String
        let targetRecipientName: String
        let targetConversationID: String?
        let encodedDescriptor: String
        let messageID: UUID
        if let recovery,
           let confirmation = recovery.confirmation,
           confirmation.isValid(for: recovery),
           let confirmedMessageID = confirmation.clientMessageID {
            targetRecipientID = recovery.recipientUserID
            targetRecipientName = recovery.recipientName
            targetConversationID = recovery.conversationID
            encodedDescriptor = confirmation.encodedDescriptor
            messageID = confirmedMessageID
        } else if ownsDestinationWallet, let share = KitPaymentRequestChatShare(
            paymentRequest: request,
            recipientUserID: recipientId,
            recipientName: title
        ) {
            // The single-flight recovery task may have queued and acknowledged this exact card
            // while the creating view was suspended. Requeueing the same deterministic UUID is
            // an idempotent proof that the protected projection is already durable.
            targetRecipientID = share.recipientUserID
            targetRecipientName = share.recipientName
            targetConversationID = canonicalConversationID
            encodedDescriptor = share.descriptor.encoded
            messageID = share.clientMessageID
        } else {
            lastError = "Kit Pay could not confirm who should receive this request. Nothing was sent in chat."
            return false
        }
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { return false }
        let queued: Bool
        if let conversationID = targetConversationID {
            queued = await queuePaymentEvent(
                conversationId: conversationID,
                title: targetRecipientName,
                recipientId: targetRecipientID,
                body: encodedDescriptor,
                clientMessageID: messageID
            )
        } else {
            queued = await queueDirectPaymentEvent(
                recipientId: targetRecipientID,
                title: targetRecipientName,
                body: encodedDescriptor,
                clientMessageID: messageID
            )
        }
        guard queued,
              await outboxContextIsCurrent(
                  accountEpoch: expectedAccountEpoch,
                  userID: expectedUserID,
                  sessionID: expectedSessionID
              )
        else { return false }
        guard let recovery else { return true }
        do {
            try await store.update { persisted in
                guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                      persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                        == .orderedSame
                else { throw PaymentRequestSubmissionError.accountChanged }
                var records = persisted.pendingPaymentRequestChatReceipts ?? []
                guard PaymentRequestChatReceiptRecoveryPolicy.acknowledgeDurableMessage(
                    recordID: recovery.id,
                    messageID: messageID,
                    in: &records
                ) else { throw PaymentRequestSubmissionError.unconfirmedRequest }
                persisted.pendingPaymentRequestChatReceipts = records.isEmpty ? nil : records
            }
            await publishLatestState()
        } catch {
            // The deterministic card is durable. Retaining the journal can only replay the same
            // local message ID and is safer than losing acknowledgement state.
        }
        return true
    }

    // MARK: - Send Later

    /// Items in one conversation (or every conversation, when `conversationID` is nil) that are
    /// still waiting to be sent. Read straight from the durable outbox so what the timeline shows
    /// and what the queue will actually do cannot drift apart.
    func scheduledChatItems(
        conversationID: String? = nil,
        at now: Date = Date()
    ) -> [ScheduledChatItem] {
        let wanted = conversationID.map { $0.lowercased() }
        var items: [ScheduledChatItem] = []
        for command in state.outbox {
            guard let commandConversation = command.conversationId?.lowercased() else { continue }
            if let wanted, commandConversation != wanted { continue }
            guard let scheduledAt = command.scheduledAt else { continue }
            switch command.kind {
            case .secureMessage:
                guard command.isAwaitingScheduledTime(at: now),
                      let messageID = command.messageId,
                      let message = state.messages.first(where: { $0.id == messageID }),
                      KitMessageReaction.parse(message.body) == nil
                else { continue }
                items.append(
                    ScheduledChatItem(
                        id: command.id,
                        conversationID: commandConversation,
                        scheduledAt: scheduledAt,
                        content: .message(messageID),
                        preview: scheduledMessagePreview(message)
                    )
                )
            case .scheduledPaymentRequest:
                // A failed request stays in the list on purpose: it is the only place the sender
                // can find out that the request they arranged did not go out.
                guard let payload = command.scheduledPaymentRequest else { continue }
                items.append(
                    ScheduledChatItem(
                        id: command.id,
                        conversationID: commandConversation,
                        scheduledAt: scheduledAt,
                        content: .paymentRequest(commandID: command.id),
                        preview: "Request \(KitMoney.formatted(payload.amount, code: payload.currencyCode))"
                    )
                )
            case .callAttempt, .callTermination:
                continue
            }
        }
        return items.sorted {
            if $0.scheduledAt != $1.scheduledAt { return $0.scheduledAt < $1.scheduledAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Why a scheduled item is still sitting there, if it is no longer simply waiting for its
    /// minute. Returned separately from the item so the timeline can stay a plain projection.
    func scheduledItemFailureReason(_ commandID: UUID) -> String? {
        guard let command = state.outbox.first(where: { $0.id == commandID }),
              command.failureDisposition != nil
        else { return nil }
        return command.lastFailureReason ?? messagingSendFailureMessage
    }

    private func scheduledMessagePreview(_ message: LocalMessage) -> String {
        if let batch = message.pendingMediaBatch {
            // Structural gate first: a corrupt persisted batch previews as the bare
            // placeholder — its unvalidated caption and unbounded items never drive a label.
            // A caption that passes is canonical (non-nil is the whole test) and rides
            // byte-exact.
            guard batch.isStructurallyValid else {
                return KitMediaMessageFamilyPresentation.genericAttachmentLabel
            }
            let label = KitMediaMessageFamilyPresentation.summaryLabel(
                forMediaTypes: batch.items.map(\.mediaType)
            )
            if let caption = batch.caption { return "\(label) · \(caption)" }
            return label
        }
        if let pending = message.pendingAttachment {
            if let caption = pending.caption, !caption.isEmpty { return caption }
            return KitChatMediaKind(mediaType: pending.mediaType).previewLabel
        }
        if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
            if let caption = descriptor.caption, !caption.isEmpty { return caption }
            return KitChatMediaKind(mediaType: descriptor.mediaType).previewLabel
        }
        if let sealed = KitMediaMessageV2Descriptor.parse(message.body) {
            let label = KitMediaMessageFamilyPresentation.summaryLabel(for: sealed)
            if let caption = sealed.caption, !caption.isEmpty { return "\(label) · \(caption)" }
            return label
        }
        // Fail closed for anything else reserved-family shaped: a scheduled row must never
        // surface raw descriptor text, whichever build or path wrote it.
        if KitMediaMessageFamilyPolicy.isReservedFamilyText(message.body) {
            return KitMediaMessageFamilyPresentation.genericAttachmentLabel
        }
        return message.body
    }

    /// Arranges a payment request for a future minute. Nothing is created on the server now: the
    /// person being asked must not see a request before the sender meant them to, so the API call
    /// itself is what waits in the outbox. The idempotency key is minted here and reused on every
    /// attempt, so a retry after a timeout can never raise two requests.
    @discardableResult
    func schedulePaymentRequest(
        destinationWalletID: String,
        requestedFromUserID: String,
        amount: String,
        currencyCode: String,
        note: String?,
        recipientName: String,
        conversationID: String,
        deliverAt: Date
    ) async -> Bool {
        guard !isReadOnlyAppReviewDemoConversation(conversationID) else {
            lastError = "This App Review preview is read-only."
            return false
        }
        let now = Date()
        guard let scheduledAt = ScheduledSendPolicy.normalize(deliverAt, now: now) else {
            lastError = "Choose a time at least a minute from now."
            return false
        }
        guard let cleanConversationID = OutboxPolicy.canonicalConversationID(conversationID) else {
            lastError = "This conversation is no longer available. Nothing was scheduled."
            return false
        }
        guard let recipientUUID = UUID(
            uuidString: requestedFromUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        ), let expectedUserID = profile?.id,
              recipientUUID.uuidString.caseInsensitiveCompare(expectedUserID) != .orderedSame,
              state.wallets.contains(where: { $0.id == destinationWalletID }),
              state.conversations.contains(where: { conversation in
                  conversation.id.caseInsensitiveCompare(cleanConversationID) == .orderedSame
                      && !conversation.isGroup
                      && conversation.participantUserIds.contains(where: {
                          $0.caseInsensitiveCompare(expectedUserID) == .orderedSame
                      })
                      && conversation.participantUserIds.contains(where: {
                          $0.caseInsensitiveCompare(recipientUUID.uuidString) == .orderedSame
                      })
              })
        else {
            lastError = "Choose one valid Kit Pay conversation."
            return false
        }
        if let denial = communicationPrivacyDenialMessage(
            for: recipientUUID.uuidString.lowercased(),
            blockedMessage: "Unblock this account before scheduling a request."
        ) {
            lastError = denial
            return false
        }
        guard let expectedSessionID = await sessions.current()?.sessionId else { return false }
        let expectedAccountEpoch = accountEpoch
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = OfflineCommand(
            id: UUID(),
            kind: .scheduledPaymentRequest,
            createdAt: now,
            nextAttemptAt: scheduledAt,
            attemptCount: 0,
            conversationId: cleanConversationID,
            messageId: nil,
            recipientUserIds: [recipientUUID.uuidString.lowercased()],
            recipientName: recipientName,
            video: nil,
            expiresAt: nil,
            scheduledAt: scheduledAt,
            scheduledPaymentRequest: ScheduledPaymentRequestPayload(
                destinationWalletID: destinationWalletID,
                requestedFromUserID: recipientUUID.uuidString.lowercased(),
                amount: amount,
                currencyCode: currencyCode,
                note: trimmedNote?.isEmpty == true ? nil : trimmedNote,
                idempotencyKey: UUID().uuidString,
                recipientName: recipientName,
                conversationID: cleanConversationID
            )
        )
        do {
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                persisted.outbox.append(command)
            }
            scheduleOutboxWake()
            return true
        } catch {
            lastError = "Kit Pay could not save this scheduled request. Please try again."
            return false
        }
    }

    /// Releases a scheduled item now. The command keeps its id, its idempotency key and any
    /// committed ciphertext, so this is the same send happening earlier — never a second one.
    @discardableResult
    func sendScheduledItemNow(_ commandID: UUID) async -> Bool {
        await mutateScheduledItem(commandID) { persisted, now in
            OutboxPolicy.releaseScheduledCommand(commandID, in: &persisted, at: now)
        }
    }

    @discardableResult
    func rescheduleScheduledItem(_ commandID: UUID, to date: Date) async -> Bool {
        let accepted = await mutateScheduledItem(commandID) { persisted, now in
            OutboxPolicy.rescheduleCommand(commandID, to: date, in: &persisted, at: now)
        }
        if !accepted, lastError == nil {
            lastError = "Choose a time at least a minute from now."
        }
        return accepted
    }

    /// Cancels a scheduled item before it is sent. Returns the message text so the composer can
    /// offer it back instead of quietly discarding what someone wrote.
    @discardableResult
    func cancelScheduledItem(_ commandID: UUID) async -> String? {
        guard !rejectAppReviewDemoMutation() else { return nil }
        guard let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return nil }
        let expectedAccountEpoch = accountEpoch
        var removed: LocalMessage?
        var deletableMediaKeys: [String] = []
        do {
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                let now = Date()
                if let command = persisted.outbox.first(where: { $0.id == commandID }),
                   command.kind == .scheduledPaymentRequest {
                    persisted.outbox.removeAll { $0.id == commandID }
                    return
                }
                removed = OutboxPolicy.cancelScheduledCommand(
                    commandID,
                    in: &persisted,
                    at: now
                )
                // Media-cache cleanup candidates come from every generation and phase of the
                // cancelled row (v1 park, sealed v1 key, v2 batch park/checkpoint/sealed keys),
                // decided against the post-removal state: a corrupt or aliased projection can
                // carry a canonical key another live message still owns, so a blob is deleted
                // only when no surviving message anywhere still references it. Orphaning on
                // uncertainty is recoverable housekeeping; deleting a survivor's only
                // plaintext is not.
                if let cancelled = removed {
                    let survivorKeys = Set(persisted.messages.flatMap(\.localMediaStorageKeys))
                        .union(
                            persisted.conversationDrafts?.values
                                .flatMap(\.localMediaStorageKeys) ?? []
                        )
                    deletableMediaKeys = cancelled.localMediaStorageKeys
                        .filter { !survivorKeys.contains($0) }
                }
            }
        } catch {
            lastError = "Kit Pay could not update this scheduled item. Please try again."
            return nil
        }
        for storageKey in deletableMediaKeys {
            await SecureMediaFileCache.shared.remove(
                forStorageKey: storageKey,
                userID: expectedUserID
            )
        }
        scheduleOutboxWake()
        // Only ordinary authored text may return to the composer as a draft. A pending v1
        // caption, a v2 batch caption or placeholder, and any KITMEDIA-family body (the
        // tightened `allowsUserAuthoredText` refuses the whole family) all stay out: no
        // descriptor or media projection may reappear as detached editable text.
        guard let removed, removed.pendingAttachment == nil,
              removed.pendingMediaBatch == nil,
              KitMediaMessageDescriptor.parse(removed.body) == nil,
              SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(removed.body)
        else { return nil }
        return removed.body
    }

    private func mutateScheduledItem(
        _ commandID: UUID,
        _ mutation: @escaping (inout PersistedState, Date) -> Bool
    ) async -> Bool {
        guard !rejectAppReviewDemoMutation() else { return false }
        guard let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return false }
        let expectedAccountEpoch = accountEpoch
        var applied = false
        do {
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                applied = mutation(&persisted, Date())
            }
        } catch {
            lastError = "Kit Pay could not update this scheduled item. Please try again."
            return false
        }
        guard applied else { return false }
        scheduleOutboxWake()
        if isOnline { await flushOutbox() }
        return true
    }

    /// Resolves submitted financial operations only through exact read-only endpoints, then moves
    /// confirmed descriptors into the ordinary Signal-backed outbox. No automatic path invokes a
    /// money-moving mutation.
    private func recoverAndDrainFinancialChatReceipts() async {
        financialChatReceiptRecoveryNeedsAnotherPass = true
        guard !isRecoveringFinancialChatReceipts else { return }
        isRecoveringFinancialChatReceipts = true
        defer {
            isRecoveringFinancialChatReceipts = false
            financialChatReceiptRecoveryNeedsAnotherPass = false
        }

        repeat {
            financialChatReceiptRecoveryNeedsAnotherPass = false
            guard appReviewDemoMutationsAllowed,
                  isSignedIn,
                  let expectedUserID = profile?.id,
                  let expectedSessionID = await sessions.current()?.sessionId
            else { return }
            let expectedAccountEpoch = accountEpoch
            if isOnline, financialAccessGranted {
                await recoverSubmittedTransferChatReceipts(
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
                await recoverSubmittedPaymentRequestChatReceipts(
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
                await recoverSubmittedPaymentRequestResolutionChatReceipts(
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
                await recoverSubmittedGroupPaymentChatReceipts(
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
                await recoverSubmittedGroupContributionChatReceipts(
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
            }
            guard communicationAccessGranted else { return }
            await drainConfirmedFinancialChatReceipts(
                accountEpoch: expectedAccountEpoch,
                ownerUserID: expectedUserID,
                sessionID: expectedSessionID
            )
        } while financialChatReceiptRecoveryNeedsAnotherPass
    }

    private func recoverSubmittedTransferChatReceipts(
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        let now = Date()
        let recoveries = ((await store.snapshot()).pendingTransferChatReceipts ?? []).filter {
            $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                && $0.phase == .submitted
                && $0.nextRecoveryAt <= now
        }.prefix(TransferChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass)
        for recovery in recoveries {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            do {
                let transaction = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.recoverTransfer(
                        walletId: recovery.sourceWalletID,
                        destinationWalletId: recovery.destinationWalletID,
                        amount: recovery.amount,
                        note: recovery.note,
                        idempotencyKey: recovery.idempotencyKey
                    )
                }
                try await confirmTransferChatReceipt(
                    transaction,
                    recovery: recovery,
                    evidence: .exactRecovery,
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
            } catch {
                if TransferChatReceiptRecoveryPolicy.recoveryDecision(for: error)
                    == .notCommitted,
                   await outboxContextIsCurrent(
                       accountEpoch: expectedAccountEpoch,
                       userID: expectedUserID,
                       sessionID: expectedSessionID
                   ) {
                    await retireUncommittedTransferChatReceipt(
                        recovery.id,
                        ownerUserID: expectedUserID
                    )
                } else {
                    do {
                        try await store.update { persisted in
                            guard persisted.communicationOwnerUserID?
                                .caseInsensitiveCompare(expectedUserID) == .orderedSame
                            else { return }
                            var records = persisted.pendingTransferChatReceipts ?? []
                            _ = TransferChatReceiptRecoveryPolicy.recordRecoveryFailure(
                                for: recovery.id,
                                in: &records,
                                now: now
                            )
                            persisted.pendingTransferChatReceipts = records.isEmpty ? nil : records
                        }
                        await publishLatestState()
                    } catch {}
                }
            }
        }
    }

    private func recoverSubmittedPaymentRequestChatReceipts(
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        let now = Date()
        let recoveries = ((await store.snapshot()).pendingPaymentRequestChatReceipts ?? []).filter {
            $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                && $0.phase == .submitted
                && $0.nextRecoveryAt <= now
        }.prefix(PaymentRequestChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass)
        for recovery in recoveries {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            do {
                let request = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.recoverPaymentRequestCreation(
                        destinationWalletId: recovery.destinationWalletID,
                        requestedFromUserId: recovery.recipientUserID,
                        amount: recovery.amount,
                        note: recovery.note,
                        expiresAt: recovery.expiresAt,
                        idempotencyKey: recovery.idempotencyKey
                    )
                }
                try await confirmPaymentRequestChatReceipt(
                    request,
                    recovery: recovery,
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
            } catch {
                if PaymentRequestChatReceiptRecoveryPolicy.recoveryDecision(for: error)
                    == .notCommitted,
                   await outboxContextIsCurrent(
                       accountEpoch: expectedAccountEpoch,
                       userID: expectedUserID,
                       sessionID: expectedSessionID
                   ) {
                    await retireUncommittedPaymentRequestChatReceipt(
                        recovery.id,
                        ownerUserID: expectedUserID
                    )
                } else {
                    do {
                        try await store.update { persisted in
                            guard persisted.communicationOwnerUserID?
                                .caseInsensitiveCompare(expectedUserID) == .orderedSame
                            else { return }
                            var records = persisted.pendingPaymentRequestChatReceipts ?? []
                            _ = PaymentRequestChatReceiptRecoveryPolicy.recordRecoveryFailure(
                                recordID: recovery.id,
                                in: &records,
                                now: now
                            )
                            persisted.pendingPaymentRequestChatReceipts = records.isEmpty
                                ? nil
                                : records
                        }
                        await publishLatestState()
                    } catch {}
                }
            }
        }
    }

    private func recoverSubmittedPaymentRequestResolutionChatReceipts(
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        let now = Date()
        let recoveries = ((await store.snapshot())
            .pendingPaymentRequestResolutionChatReceipts ?? []).filter {
                $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                    && $0.phase == .submitted
                    && $0.nextRecoveryAt <= now
            }.prefix(
                PaymentRequestResolutionChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass
            )
        for recovery in recoveries {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            do {
                let request = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.paymentRequest(id: recovery.requestID)
                }
                guard await outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                ) else { return }
                guard recovery.matchesExactRead(request) else {
                    throw FinancialChatReceiptRecoveryError.unconfirmedResult
                }
                switch PaymentRequestResolutionChatReceiptRecoveryPolicy.exactReadDecision(
                    for: request,
                    recovery: recovery
                ) {
                case .confirm:
                    guard let confirmation = PaymentRequestResolutionChatReceiptConfirmation(
                        request: request,
                        recovery: recovery
                    ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
                    try await storePaymentRequestResolutionConfirmation(
                        confirmation,
                        recovery: recovery,
                        accountEpoch: expectedAccountEpoch,
                        ownerUserID: expectedUserID,
                        sessionID: expectedSessionID
                    )
                case .retireUncommitted:
                    await retireUncommittedPaymentRequestResolutionChatReceipt(
                        recovery.id,
                        ownerUserID: expectedUserID
                    )
                case .retain:
                    throw FinancialChatReceiptRecoveryError.unconfirmedResult
                }
            } catch {
                do {
                    try await store.update { persisted in
                        guard persisted.communicationOwnerUserID?
                            .caseInsensitiveCompare(expectedUserID) == .orderedSame
                        else { return }
                        var records = persisted.pendingPaymentRequestResolutionChatReceipts ?? []
                        _ = PaymentRequestResolutionChatReceiptRecoveryPolicy
                            .recordRecoveryFailure(
                                recordID: recovery.id,
                                in: &records,
                                now: now
                            )
                        persisted.pendingPaymentRequestResolutionChatReceipts = records.isEmpty
                            ? nil
                            : records
                    }
                    await publishLatestState()
                } catch {}
            }
        }
    }

    private func recoverSubmittedGroupPaymentChatReceipts(
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        let now = Date()
        let recoveries = ((await store.snapshot()).pendingGroupPaymentChatReceipts ?? []).filter {
            $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                && $0.phase == .submitted
                && $0.nextRecoveryAt <= now
        }.prefix(GroupPaymentChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass)
        for recovery in recoveries {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            do {
                let payment = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.recoverGroupPaymentCreation(
                        conversationId: recovery.conversationID,
                        body: recovery.body,
                        idempotencyKey: recovery.idempotencyKey
                    )
                }
                try await confirmGroupPaymentChatReceipt(
                    payment,
                    recovery: recovery,
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
            } catch {
                if GroupPaymentChatReceiptRecoveryPolicy.recoveryDecision(for: error)
                    == .notCommitted,
                   await outboxContextIsCurrent(
                       accountEpoch: expectedAccountEpoch,
                       userID: expectedUserID,
                       sessionID: expectedSessionID
                   ) {
                    await retireUncommittedGroupPaymentChatReceipt(
                        recovery.id,
                        ownerUserID: expectedUserID
                    )
                } else {
                    do {
                        try await store.update { persisted in
                            guard persisted.communicationOwnerUserID?
                                .caseInsensitiveCompare(expectedUserID) == .orderedSame
                            else { return }
                            var records = persisted.pendingGroupPaymentChatReceipts ?? []
                            _ = GroupPaymentChatReceiptRecoveryPolicy.recordRecoveryFailure(
                                recordID: recovery.id,
                                in: &records,
                                now: now
                            )
                            persisted.pendingGroupPaymentChatReceipts = records.isEmpty
                                ? nil
                                : records
                        }
                        await publishLatestState()
                    } catch {}
                }
            }
        }
    }

    private func recoverSubmittedGroupContributionChatReceipts(
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        let now = Date()
        let recoveries = ((await store.snapshot()).pendingGroupContributionChatReceipts ?? [])
            .filter {
                $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                    && $0.phase == .submitted
                    && $0.nextRecoveryAt <= now
            }.prefix(GroupContributionChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass)
        for recovery in recoveries {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            do {
                let result = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.recoverGroupPaymentRequestContribution(
                        id: recovery.requestID,
                        sourceWalletId: recovery.sourceWalletID,
                        amount: recovery.amount,
                        idempotencyKey: recovery.idempotencyKey
                    )
                }
                try await confirmGroupContributionChatReceipt(
                    result,
                    recovery: recovery,
                    accountEpoch: expectedAccountEpoch,
                    ownerUserID: expectedUserID,
                    sessionID: expectedSessionID
                )
            } catch {
                if GroupContributionChatReceiptRecoveryPolicy.recoveryDecision(for: error)
                    == .notCommitted,
                   await outboxContextIsCurrent(
                       accountEpoch: expectedAccountEpoch,
                       userID: expectedUserID,
                       sessionID: expectedSessionID
                   ) {
                    await retireUncommittedGroupContributionChatReceipt(
                        recovery.id,
                        ownerUserID: expectedUserID
                    )
                } else {
                    do {
                        try await store.update { persisted in
                            guard persisted.communicationOwnerUserID?
                                .caseInsensitiveCompare(expectedUserID) == .orderedSame
                            else { return }
                            var records = persisted.pendingGroupContributionChatReceipts ?? []
                            _ = GroupContributionChatReceiptRecoveryPolicy.recordRecoveryFailure(
                                recordID: recovery.id,
                                in: &records,
                                now: now
                            )
                            persisted.pendingGroupContributionChatReceipts = records.isEmpty
                                ? nil
                                : records
                        }
                        await publishLatestState()
                    } catch {}
                }
            }
        }
    }

    private func drainConfirmedFinancialChatReceipts(
        accountEpoch expectedAccountEpoch: UUID,
        ownerUserID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        var snapshot = await store.snapshot()
        for recovery in (snapshot.pendingTransferChatReceipts ?? []).filter({
            $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                && $0.phase == .confirmed
                && $0.confirmation?.isValid(for: $0) == true
        }).prefix(TransferChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass) {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ), let confirmation = recovery.confirmation,
               let messageID = confirmation.clientMessageID
            else { return }
            let queued: Bool
            if let conversationID = recovery.conversationID {
                queued = await queuePaymentEvent(
                    conversationId: conversationID,
                    title: recovery.recipientName,
                    recipientId: recovery.recipientUserID,
                    body: confirmation.encodedDescriptor,
                    clientMessageID: messageID
                )
            } else {
                queued = await queueDirectPaymentEvent(
                    recipientId: recovery.recipientUserID,
                    title: recovery.recipientName,
                    body: confirmation.encodedDescriptor,
                    clientMessageID: messageID
                )
            }
            guard queued else { continue }
            do {
                try await store.update { persisted in
                    guard persisted.communicationOwnerUserID?
                        .caseInsensitiveCompare(expectedUserID) == .orderedSame
                    else { throw FinancialChatReceiptRecoveryError.accountChanged }
                    var records = persisted.pendingTransferChatReceipts ?? []
                    guard TransferChatReceiptRecoveryPolicy.acknowledgeDurableMessage(
                        recordID: recovery.id,
                        messageID: messageID,
                        in: &records
                    ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
                    persisted.pendingTransferChatReceipts = records.isEmpty ? nil : records
                }
                await publishLatestState()
            } catch {}
        }

        snapshot = await store.snapshot()
        for recovery in (snapshot.pendingPaymentRequestChatReceipts ?? []).filter({
            $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                && $0.phase == .confirmed
                && $0.confirmation?.isValid(for: $0) == true
        }).prefix(PaymentRequestChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass) {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ), let confirmation = recovery.confirmation,
               let messageID = confirmation.clientMessageID
            else { return }
            let queued: Bool
            if let conversationID = recovery.conversationID {
                queued = await queuePaymentEvent(
                    conversationId: conversationID,
                    title: recovery.recipientName,
                    recipientId: recovery.recipientUserID,
                    body: confirmation.encodedDescriptor,
                    clientMessageID: messageID
                )
            } else {
                queued = await queueDirectPaymentEvent(
                    recipientId: recovery.recipientUserID,
                    title: recovery.recipientName,
                    body: confirmation.encodedDescriptor,
                    clientMessageID: messageID
                )
            }
            guard queued else { continue }
            do {
                try await store.update { persisted in
                    guard persisted.communicationOwnerUserID?
                        .caseInsensitiveCompare(expectedUserID) == .orderedSame
                    else { throw FinancialChatReceiptRecoveryError.accountChanged }
                    var records = persisted.pendingPaymentRequestChatReceipts ?? []
                    guard PaymentRequestChatReceiptRecoveryPolicy.acknowledgeDurableMessage(
                        recordID: recovery.id,
                        messageID: messageID,
                        in: &records
                    ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
                    persisted.pendingPaymentRequestChatReceipts = records.isEmpty ? nil : records
                }
                await publishLatestState()
            } catch {}
        }

        snapshot = await store.snapshot()
        for recovery in (snapshot.pendingPaymentRequestResolutionChatReceipts ?? []).filter({
            $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                && $0.phase == .confirmed
                && $0.confirmation?.isValid(for: $0) == true
        }).prefix(
            PaymentRequestResolutionChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass
        ) {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ), let confirmation = recovery.confirmation,
               let messageID = confirmation.clientMessageID
            else { return }
            let queued = await queuePaymentEvent(
                conversationId: recovery.conversationID,
                title: recovery.recipientName,
                recipientId: recovery.recipientUserID,
                body: confirmation.encodedDescriptor,
                clientMessageID: messageID
            )
            guard queued else { continue }
            do {
                try await store.update { persisted in
                    guard persisted.communicationOwnerUserID?
                        .caseInsensitiveCompare(expectedUserID) == .orderedSame
                    else { throw FinancialChatReceiptRecoveryError.accountChanged }
                    var records = persisted.pendingPaymentRequestResolutionChatReceipts ?? []
                    guard PaymentRequestResolutionChatReceiptRecoveryPolicy
                        .acknowledgeDurableMessage(
                            recordID: recovery.id,
                            messageID: messageID,
                            in: &records
                        )
                    else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
                    persisted.pendingPaymentRequestResolutionChatReceipts = records.isEmpty
                        ? nil
                        : records
                }
                await publishLatestState()
            } catch {}
        }

        snapshot = await store.snapshot()
        for recovery in (snapshot.pendingGroupPaymentChatReceipts ?? []).filter({
            $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                && $0.phase == .confirmed
                && $0.confirmation?.isValid(for: $0) == true
        }).prefix(GroupPaymentChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass) {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ), let confirmation = recovery.confirmation,
               let messageID = confirmation.clientMessageID
            else { return }
            guard let title = state.conversations.first(where: {
                $0.id.caseInsensitiveCompare(recovery.conversationID) == .orderedSame
            })?.title else { continue }
            let queued = await queueGroupPaymentEvent(
                conversationId: recovery.conversationID,
                title: title,
                body: confirmation.encodedDescriptor,
                clientMessageID: messageID
            )
            guard queued else { continue }
            do {
                try await store.update { persisted in
                    guard persisted.communicationOwnerUserID?
                        .caseInsensitiveCompare(expectedUserID) == .orderedSame
                    else { throw FinancialChatReceiptRecoveryError.accountChanged }
                    var records = persisted.pendingGroupPaymentChatReceipts ?? []
                    guard GroupPaymentChatReceiptRecoveryPolicy.acknowledgeDurableMessage(
                        recordID: recovery.id,
                        messageID: messageID,
                        in: &records
                    ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
                    persisted.pendingGroupPaymentChatReceipts = records.isEmpty ? nil : records
                }
                await publishLatestState()
            } catch {}
        }

        snapshot = await store.snapshot()
        for recovery in (snapshot.pendingGroupContributionChatReceipts ?? []).filter({
            $0.ownerUserID.caseInsensitiveCompare(expectedUserID) == .orderedSame
                && $0.phase == .confirmed
                && $0.confirmation?.isValid(for: $0) == true
        }).prefix(GroupContributionChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass) {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ), let confirmation = recovery.confirmation,
               let messageID = confirmation.clientMessageID,
               let descriptor = KitGroupPaymentRequestMessage.parse(
                   confirmation.encodedDescriptor
               )
            else { return }
            guard let title = state.conversations.first(where: {
                $0.id.caseInsensitiveCompare(recovery.conversationID) == .orderedSame
            })?.title else { continue }
            let queued = await queueGroupPaymentRequestEvent(
                conversationId: recovery.conversationID,
                title: title,
                descriptor: descriptor,
                clientMessageID: messageID
            )
            guard queued else { continue }
            do {
                try await store.update { persisted in
                    guard persisted.communicationOwnerUserID?
                        .caseInsensitiveCompare(expectedUserID) == .orderedSame
                    else { throw FinancialChatReceiptRecoveryError.accountChanged }
                    var records = persisted.pendingGroupContributionChatReceipts ?? []
                    guard GroupContributionChatReceiptRecoveryPolicy.acknowledgeDurableMessage(
                        recordID: recovery.id,
                        messageID: messageID,
                        in: &records
                    ) else { throw FinancialChatReceiptRecoveryError.unconfirmedResult }
                    persisted.pendingGroupContributionChatReceipts = records.isEmpty
                        ? nil
                        : records
                }
                await publishLatestState()
            } catch {}
        }
    }


    /// Starts protected local persistence as soon as a picker/editor accepts an attachment.
    /// The composer keeps rendering its in-memory original immediately while this work runs;
    /// Send reuses and byte-verifies the same permanent client-keyed entry before committing the
    /// durable message, so a failed or interrupted prewrite never becomes a false local record.
    func persistStagedMediaOriginal(mediaID: UUID, data: Data) async -> Bool {
        let mediaDiagnosticsScope = LocalMediaPerformanceMonitor.shared.captureProducerScope()
        guard !data.isEmpty, isSignedIn, !isSigningOut, let userID = profile?.id else { return false }
        let expectedAccountEpoch = accountEpoch
        let snapshot = await store.snapshot()
        guard expectedAccountEpoch == accountEpoch, isSignedIn, !isSigningOut,
              snapshot.profile?.id.caseInsensitiveCompare(userID) == .orderedSame,
              snapshot.communicationOwnerUserID?.caseInsensitiveCompare(userID) == .orderedSame
        else { return false }
        let key = mediaID.uuidString.lowercased()
        let insertion = await SecureMediaFileCache.shared.insertIfAbsent(
            data,
            forStorageKey: key,
            userID: userID
        )
        let persistedData = await SecureMediaFileCache.shared.data(
            forStorageKey: key,
            userID: userID
        )
        let verified = insertion != .rejected && persistedData == data
        let current = await store.snapshot()
        guard expectedAccountEpoch == accountEpoch,
              current.profile?.id == userID,
              verified
        else {
            if insertion == .stored {
                await SecureMediaFileCache.shared.remove(
                    forStorageKey: key,
                    userID: userID
                )
            }
            return false
        }
        LocalMediaPerformanceMonitor.shared.markPlayable(
            mediaID: mediaID,
            producerScope: mediaDiagnosticsScope
        )
        return true
    }

    /// File-backed variant for videos and documents. Camera/editor files are atomically adopted
    /// when possible; provider documents are copied file-to-file. Neither path constructs a
    /// whole-file `Data`, and the returned URL is the permanent protected original the sender
    /// can play/open before upload starts.
    func persistStagedMediaOriginal(
        mediaID: UUID,
        sourceURL: URL,
        mediaType: String,
        byteCount: Int,
        moveSource: Bool,
        requiresConstantTimeClone: Bool = false
    ) async -> URL? {
        let mediaDiagnosticsScope = LocalMediaPerformanceMonitor.shared.captureProducerScope()
        guard isSignedIn, !isSigningOut, let userID = profile?.id,
              KitChatMediaLimits.fitsLocalOriginal(
            byteCount: byteCount,
            mediaType: mediaType
        ) else { return nil }
        let expectedAccountEpoch = accountEpoch
        let snapshot = await store.snapshot()
        guard expectedAccountEpoch == accountEpoch, isSignedIn, !isSigningOut,
              snapshot.profile?.id.caseInsensitiveCompare(userID) == .orderedSame,
              snapshot.communicationOwnerUserID?.caseInsensitiveCompare(userID) == .orderedSame
        else { return nil }
        let key = mediaID.uuidString.lowercased()
        let destination: URL
        do {
            destination = try await SecureMediaFileCache.shared.importProtectedOriginal(
                from: sourceURL,
                forStorageKey: key,
                userID: userID,
                mediaType: mediaType,
                expectedByteCount: byteCount,
                moveSource: moveSource,
                requiresConstantTimeClone: requiresConstantTimeClone
            )
        } catch {
            return nil
        }
        let current = await store.snapshot()
        guard expectedAccountEpoch == accountEpoch, current.profile?.id == userID else {
            await SecureMediaFileCache.shared.remove(forStorageKey: key, userID: userID)
            return nil
        }
        LocalMediaPerformanceMonitor.shared.markPlayable(
            mediaID: mediaID,
            producerScope: mediaDiagnosticsScope
        )
        return destination
    }

    /// Removes a composer-only original after the user discards/replaces it. Once any durable
    /// message record owns the id, deletion is refused and ordinary message cleanup owns it.
    func discardStagedMediaOriginal(mediaID: UUID) async {
        let snapshot = await store.snapshot()
        guard let userID = snapshot.profile?.id else { return }
        let key = mediaID.uuidString.lowercased()
        guard snapshot.messages.allSatisfy({ message in
            !(message.localMediaRecords ?? []).contains(where: { $0.id == key })
                && !message.localMediaStorageKeys.contains(key)
        }), snapshot.conversationDrafts?.values.allSatisfy({ draft in
            !draft.localMediaStorageKeys.contains(key)
        }) != false else { return }
        await SecureMediaFileCache.shared.remove(forStorageKey: key, userID: userID)
    }

    /// Metadata probing is deliberately outside the capture-to-visible and download-to-visible
    /// critical paths. If it finishes after queueing/hydration, attach the duration to the exact
    /// permanent media id without touching message identity, ciphertext, or transfer state.
    func persistLocalMediaDuration(mediaID: UUID, duration: TimeInterval) async {
        guard duration.isFinite, duration > 0 else { return }
        let expectedAccountEpoch = accountEpoch
        let attachmentID = mediaID.uuidString.lowercased()
        let snapshot = await store.snapshot()
        guard expectedAccountEpoch == accountEpoch,
              let userID = snapshot.profile?.id,
              snapshot.messages.contains(where: {
                  ($0.localMediaRecords ?? []).contains(where: { $0.id == attachmentID })
              })
        else { return }
        do {
            try await store.update { persisted in
                guard persisted.profile?.id == userID
                else { throw StoreError.accountChanged }
                for index in persisted.messages.indices where
                    (persisted.messages[index].localMediaRecords ?? []).contains(
                        where: { $0.id == attachmentID }
                    ) {
                    _ = LocalMediaRecordPolicy.setDuration(
                        &persisted.messages[index],
                        attachmentID: attachmentID,
                        duration: duration
                    )
                }
            }
        } catch {
            return
        }
        guard expectedAccountEpoch == accountEpoch else { return }
        await publishLatestState()
    }

    nonisolated static func localMediaDuration(
        fileURL: URL,
        mediaType: String
    ) async -> TimeInterval? {
        let normalized = mediaType.lowercased()
        guard normalized.hasPrefix("video/") || normalized.hasPrefix("audio/") else { return nil }
        let loaded = try? await AVURLAsset(url: fileURL).load(.duration)
        guard let seconds = loaded?.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    func scheduleLocalMediaDuration(
        mediaID: UUID,
        fileURL: URL,
        mediaType: String
    ) {
        let normalized = mediaType.lowercased()
        guard normalized.hasPrefix("video/") || normalized.hasPrefix("audio/") else { return }
        let mediaDiagnosticsScope = LocalMediaPerformanceMonitor.shared.captureProducerScope()
        Task { [weak self] in
            guard let duration = await Self.localMediaDuration(
                fileURL: fileURL,
                mediaType: mediaType
            ) else { return }
            LocalMediaPerformanceMonitor.shared.updateMetadata(
                mediaID: mediaID,
                kind: KitChatMediaKind(mediaType: mediaType),
                duration: duration,
                producerScope: mediaDiagnosticsScope
            )
            await self?.persistLocalMediaDuration(mediaID: mediaID, duration: duration)
        }
    }

    private struct DirectMediaQueueTarget {
        let conversationID: String
        let provisionalRecipientUserID: String?
    }

    /// Chooses a first-contact media destination without creating an empty chat. The reviewed
    /// capability yields only an in-memory UUID; the media queue transaction is the first durable
    /// write. Older servers retain their authenticated create-before-queue behavior.
    private func directMediaQueueTarget(
        recipientId: String,
        title: String
    ) async -> DirectMediaQueueTarget? {
        let rawRecipientID = recipientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !AppReviewDemoMutationPolicy.peerIsReadOnly(
            rawRecipientID,
            isDemoActive: appReviewDemoIsActive
        ) else {
            lastError = AppReviewDemoMutationPolicy.readOnlyMessage
            return nil
        }
        guard let recipientUUID = UUID(uuidString: rawRecipientID),
              !cleanTitle.isEmpty,
              let rawUserID = profile?.id,
              let userUUID = UUID(uuidString: rawUserID),
              secureMessagingLocalQueueAvailable
        else {
            lastError = messagingSendFailureMessage
            return nil
        }
        let recipient = recipientUUID.uuidString.lowercased()
        let userID = userUUID.uuidString.lowercased()
        let route = NewMessageComposerPolicy.directRoute(
            conversations: state.conversations,
            currentUserID: userID,
            recipientUserID: recipient,
            privacyAllowsLocalQueue: communicationPrivacyAllowsLocalQueue(to: recipient)
        )
        switch route {
        case .existing(let conversation):
            return DirectMediaQueueTarget(
                conversationID: conversation.id,
                provisionalRecipientUserID: nil
            )
        case .blocked:
            lastError = "Unblock this account before starting a chat."
            return nil
        case .invalid:
            lastError = messagingSendFailureMessage
            return nil
        case .create:
            break
        }

        if messagingOfflineDirectCreationLocalQueueEnabled {
            return DirectMediaQueueTarget(
                conversationID: UUID().uuidString.lowercased(),
                provisionalRecipientUserID: recipient
            )
        }

        guard isOnline else {
            lastError = "Connect to the internet once to start this conversation."
            return nil
        }
        guard secureMessagingReleasePermitted else {
            lastError = messagingSendFailureMessage
            return nil
        }
        if let denial = communicationPrivacyDenialMessage(
            for: recipient,
            blockedMessage: "Unblock this account before starting a chat."
        ) {
            lastError = denial
            return nil
        }
        let expectedAccountEpoch = accountEpoch
        guard let commitAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
            forAccountID: userID
        ), let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
                  accountEpoch: expectedAccountEpoch,
                  userID: userID,
                  sessionID: expectedSessionID,
                  commitAdmission: commitAdmission
              )
        else { return nil }
        do {
            let created = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: expectedAccountEpoch,
                sessionID: expectedSessionID,
                commitAdmission: commitAdmission
            ) {
                try await SecureMessagingExchangeCoordinator.shared.ensureDirectConversation(
                    forUserID: userID,
                    recipientUserID: recipient,
                    title: cleanTitle,
                    commitAdmission: commitAdmission
                )
            }
            guard ProtectedCommunicationAdmissionGate.shared.permits(commitAdmission),
                  await outboxContextIsCurrent(
                      accountEpoch: expectedAccountEpoch,
                      userID: userID,
                      sessionID: expectedSessionID
                  )
            else { return nil }
            await publishLatestState()
            return DirectMediaQueueTarget(
                conversationID: created.id,
                provisionalRecipientUserID: nil
            )
        } catch is CancellationError {
            return nil
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    /// First-contact counterpart to `queueMediaMessage`. The stable client message ID and, when
    /// supported, provisional conversation UUID are minted before any suspension. No text
    /// bootstrap is created; caption and attachment remain one media message.
    @discardableResult
    func queueDirectMediaMessage(
        recipientId: String,
        title: String,
        mediaData: Data?,
        mediaType: String,
        caption: String?,
        localMediaID: UUID? = nil,
        plaintextByteSize: Int? = nil,
        localStorageKind: LocalMediaRecord.LocalStorageKind? = nil,
        duration: TimeInterval? = nil,
        preprocessingJob: LocalMediaPreprocessingJob? = nil,
        clientMessageID: UUID? = nil
    ) async -> Bool {
        let stableMessageID = clientMessageID ?? UUID()
        guard let target = await directMediaQueueTarget(
            recipientId: recipientId,
            title: title
        ) else { return false }
        return await queueMediaMessage(
            conversationId: target.conversationID,
            title: title,
            recipientId: recipientId,
            mediaData: mediaData,
            mediaType: mediaType,
            caption: caption,
            localMediaID: localMediaID,
            plaintextByteSize: plaintextByteSize,
            localStorageKind: localStorageKind,
            duration: duration,
            preprocessingJob: preprocessingJob,
            clientMessageID: stableMessageID,
            provisionalDirectRecipientUserID: target.provisionalRecipientUserID
        )
    }

    /// First-contact counterpart for one 2–8 attachment message. The batch caption, message ID,
    /// media IDs and provisional conversation ID all remain stable through outbox replay.
    @discardableResult
    func queueDirectMediaMessageBatch(
        recipientId: String,
        title: String,
        attachments: [LocalMediaQueueAttachment],
        rawCaption: String?,
        clientMessageID: UUID? = nil
    ) async -> Bool {
        let stableMessageID = clientMessageID ?? UUID()
        guard let target = await directMediaQueueTarget(
            recipientId: recipientId,
            title: title
        ) else { return false }
        return await queueMediaMessageBatch(
            conversationId: target.conversationID,
            title: title,
            recipientId: recipientId,
            attachments: attachments,
            rawCaption: rawCaption,
            clientMessageID: stableMessageID,
            provisionalDirectRecipientUserID: target.provisionalRecipientUserID
        )
    }

    /// Sends any allowed media kind (photo, voice note, video, document) end-to-end encrypted.
    /// Every plaintext original is retained in the account-scoped encrypted file cache under
    /// its permanent client media id; small v1 rows may additionally carry an inline copy.
    @discardableResult
    func queueMediaMessage(
        conversationId: String,
        title: String,
        recipientId: String?,
        mediaData: Data?,
        mediaType: String,
        caption: String?,
        localMediaID: UUID? = nil,
        plaintextByteSize: Int? = nil,
        localStorageKind: LocalMediaRecord.LocalStorageKind? = nil,
        duration: TimeInterval? = nil,
        preprocessingJob: LocalMediaPreprocessingJob? = nil,
        clientMessageID: UUID? = nil,
        submittedDraftBody: String? = nil,
        submittedDraftMediaAttachments: [ConversationDraftMediaAttachment]? = nil,
        draftClearVersion: ConversationDraftWriteVersion? = nil,
        deliverAt: Date? = nil,
        replyToServerMessageID: String? = nil,
        provisionalDirectRecipientUserID: String? = nil
    ) async -> Bool {
        guard !isReadOnlyAppReviewDemoConversation(conversationId) else {
            lastError = "This App Review preview is read-only."
            return false
        }
        guard (submittedDraftBody == nil) == (draftClearVersion == nil),
              draftClearVersion != nil || submittedDraftMediaAttachments == nil
        else {
            lastError = CustomerFacingMessagingCopy.draftSaveFailure
            return false
        }
        guard let cleanConversationId = OutboxPolicy.canonicalConversationID(conversationId) else {
            lastError = "This conversation is no longer available. Nothing was sent."
            return false
        }
        let replyTarget = replyToServerMessageID
            .flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        if replyToServerMessageID != nil {
            guard let replyTarget,
                  state.messages.contains(where: { message in
                      message.conversationId.caseInsensitiveCompare(cleanConversationId)
                          == .orderedSame
                          && message.serverMessageId?.lowercased() == replyTarget
                          && message.secureMessagingHistory?.kind.isTimelineMetadata != true
                  })
            else {
                lastError = "That message is no longer available to reply to."
                return false
            }
        }
        let isGroupTarget = state.conversations.first(where: {
            $0.id.caseInsensitiveCompare(cleanConversationId) == .orderedSame
        })?.isGroup == true
        guard MessagingGroupCapabilityPolicy.allowsConversationMutation(
            isGroup: isGroupTarget,
            groupCapabilityEnabled: messagingGroupLocalQueueEnabled
        ) else {
            lastError = "Group messaging is not available right now. You can still read this conversation."
            return false
        }
        let mediaByteCount = mediaData?.count ?? plaintextByteSize ?? 0
        let kind = KitChatMediaKind(mediaType: mediaType)
        guard KitChatMediaLimits.fits(mediaByteCount, kind: kind),
              mediaData.map({ !$0.isEmpty && $0.count == mediaByteCount }) ?? true
        else {
            lastError = "\(kind.previewLabel)s can be up to \(KitChatMediaLimits.maximumTransferLabel)."
            return false
        }
        guard secureMessagingLocalQueueAvailable else {
            lastError = messagingSendFailureMessage
            return false
        }
        // Group threads queue without a pinned single recipient; per-member privacy and group
        // attestation run authoritatively at flush and on the server (v1 policy).
        let recipientUserID: String?
        if isGroupTarget {
            recipientUserID = nil
        } else {
            guard let recipientId,
                  let recipientUUID = UUID(
                      uuidString: recipientId.trimmingCharacters(in: .whitespacesAndNewlines)
                  )
            else {
                lastError = "Choose one valid Kit Pay recipient."
                return false
            }
            recipientUserID = recipientUUID.uuidString.lowercased()
        }
        let inferredSharedRecipient = sharedInboxProvisionalRecipient(
            conversationID: cleanConversationId
        )
        let provisionalRecipient = provisionalDirectRecipientUserID
            ?? inferredSharedRecipient
        if let provisionalRecipient {
            guard messagingOfflineDirectCreationLocalQueueEnabled,
                  !isGroupTarget,
                  recipientUserID == provisionalRecipient
            else {
                lastError = "Connect to the internet once to start this conversation."
                return false
            }
        }
        guard let userID = profile?.id else {
            lastError = "Choose one valid Kit Pay recipient."
            return false
        }
        // Capture every piece of account-lifetime authority before the first suspension. A
        // same-user sign-out/re-login may replace the protected store while SessionStore is being
        // consulted; acquiring a lease afterwards would accidentally bless the old composer work
        // with the replacement login's authority.
        let expectedAccountEpoch = accountEpoch
        guard let commitAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
            forAccountID: userID
        ), let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: expectedSessionID,
            commitAdmission: commitAdmission
        ) else { return false }
        if let recipientUserID,
           !communicationPrivacyAllowsLocalQueue(to: recipientUserID) {
            lastError = "Unblock this account before sending this attachment."
            return false
        }
        // Local-first for every kind: preserve an account-scoped original under a permanent
        // client id before the durable bubble is committed. Upload/encrypt/send replay from the
        // outbox and can never be required to view bytes this device already owns.
        let stableMediaID = localMediaID ?? UUID()
        let parkedLocalKey = stableMediaID.uuidString.lowercased()
        if let mediaData {
            let insert = await SecureMediaFileCache.shared.insertIfAbsent(
                mediaData,
                forStorageKey: parkedLocalKey,
                userID: userID
            )
            guard insert != .rejected,
                  let parked = await SecureMediaFileCache.shared.data(
                      forStorageKey: parkedLocalKey,
                      userID: userID
                  ), parked == mediaData
            else {
                lastError = "This attachment could not be saved securely on this device."
                return false
            }
        } else {
            guard localMediaID != nil,
                  localStorageKind == .protectedFile,
                  await SecureMediaFileCache.shared.byteCount(
                      forStorageKey: parkedLocalKey,
                      userID: userID
                  ) == mediaByteCount,
                  await SecureMediaFileCache.shared.protectedOriginalURL(
                      forStorageKey: parkedLocalKey,
                      userID: userID,
                      expectedByteCount: mediaByteCount
                  ) != nil
            else {
                lastError = "This attachment could not be saved securely on this device."
                return false
            }
        }
        if let preprocessingJob {
            guard preprocessingJob.isStructurallyValid,
                  preprocessingJob.outputMediaType == mediaType,
                  preprocessingJob.sources.first?.storageKey == parkedLocalKey,
                  preprocessingJob.sources.first?.fileSize == mediaByteCount
            else {
                lastError = "This attachment's local processing record is invalid."
                return false
            }
            for source in preprocessingJob.sources {
                guard await SecureMediaFileCache.shared.byteCount(
                    forStorageKey: source.storageKey,
                    userID: userID
                ) == source.fileSize,
                      await SecureMediaFileCache.shared.protectedOriginalURL(
                          forStorageKey: source.storageKey,
                          userID: userID,
                          expectedByteCount: source.fileSize
                      ) != nil
                else {
                    lastError = "This attachment's local original is no longer available."
                    return false
                }
            }
        }
        guard MessagingGroupCapabilityPolicy.allowsConversationMutation(
            isGroup: isGroupTarget,
            groupCapabilityEnabled: messagingGroupLocalQueueEnabled
        ) else {
            // The key may have become draft-owned while this task crossed an actor boundary.
            // Leave an uncommitted park to bounded orphan reconciliation rather than deleting
            // bytes whose current state ownership cannot be proven atomically with file I/O.
            lastError = "Group messaging is not available right now. You can still read this conversation."
            return false
        }
        do {
            _ = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: expectedAccountEpoch,
                sessionID: expectedSessionID,
                commitAdmission: commitAdmission
            ) {
                try await SecureMessagingExchangeCoordinator.shared.queueDeferredImage(
                    forUserID: userID,
                    conversationID: cleanConversationId,
                    expectedRecipientUserID: recipientUserID,
                    title: title,
                    mediaData: mediaData,
                    mediaType: mediaType,
                    caption: caption,
                    localStorageKey: parkedLocalKey,
                    localMediaID: stableMediaID,
                    plaintextByteSize: mediaByteCount,
                    localStorageKind: localStorageKind,
                    duration: duration,
                    preprocessingJob: preprocessingJob,
                    clientMessageID: clientMessageID,
                    submittedDraftBody: submittedDraftBody,
                    submittedDraftMediaAttachments: submittedDraftMediaAttachments,
                    draftClearVersion: draftClearVersion,
                    deliverAt: deliverAt,
                    replyToServerMessageID: replyTarget,
                    provisionalDirectRecipientUserID: provisionalRecipient,
                    commitAdmission: commitAdmission
                )
            }
            let reloaded = await reloadOutboxStateIfCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            )
            guard reloaded else { return false }
            // Media bytes, pending attachment metadata and the outbox command are protected by
            // the same local commit. Upload/encryption replay continues independently from here;
            // kick it immediately so an online send starts uploading without waiting for a wake.
            scheduleOutboxWake()
            if preprocessingJob != nil { schedulePendingMediaPreprocessing() }
            if isOnline {
                Task { [weak self] in await self?.flushOutbox() }
            }
            return true
        } catch {
            // Never delete after an awaited queue attempt. A concurrent composer save can claim
            // this same permanent id; the age-gated orphan sweep safely handles true leftovers.
            return await queueMediaMessageFailureResult(
                error,
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            )
        }
    }

    /// Sends 2–8 attachments end-to-end encrypted as ONE multi-attachment (KITMEDIA2) message:
    /// one bubble, one optional caption, one wire POST, one idempotency identity. The batch is
    /// never split into per-attachment messages — every validation failure fails the whole send
    /// visibly with the composer draft and staged files preserved. `rawCaption` is the typed
    /// text before any platform trimming; the contract's exact six-codepoint strip inside
    /// `KitMediaMessageV2OutboundBatch.queued` is the only normalization ever applied to it.
    /// A shared-in handoff of any shape passes its batch UUID as `clientMessageID` — the sole
    /// message identity for that delivery — making the whole share one idempotent send and the
    /// durable footprint restart recovery pins the batch by.
    @discardableResult
    func queueMediaMessageBatch(
        conversationId: String,
        title: String,
        recipientId: String?,
        attachments: [LocalMediaQueueAttachment],
        rawCaption: String?,
        clientMessageID: UUID? = nil,
        submittedDraftBody: String? = nil,
        submittedDraftMediaAttachments: [ConversationDraftMediaAttachment]? = nil,
        draftClearVersion: ConversationDraftWriteVersion? = nil,
        deliverAt: Date? = nil,
        replyToServerMessageID: String? = nil,
        provisionalDirectRecipientUserID: String? = nil
    ) async -> Bool {
        guard !isReadOnlyAppReviewDemoConversation(conversationId) else {
            lastError = "This App Review preview is read-only."
            return false
        }
        guard (submittedDraftBody == nil) == (draftClearVersion == nil),
              draftClearVersion != nil || submittedDraftMediaAttachments == nil
        else {
            lastError = CustomerFacingMessagingCopy.draftSaveFailure
            return false
        }
        guard let cleanConversationId = OutboxPolicy.canonicalConversationID(conversationId) else {
            lastError = "This conversation is no longer available. Nothing was sent."
            return false
        }
        guard (KitMediaMessageV2Descriptor.minimumAttachmentCount
            ... KitMediaMessageV2Descriptor.maximumAttachmentCount)
            .contains(attachments.count)
        else {
            lastError = "Send between 2 and 8 attachments together."
            return false
        }
        guard Set(attachments.map(\.mediaID)).count == attachments.count
        else {
            lastError = "These attachments do not have valid local identities."
            return false
        }
        for attachment in attachments {
            let kind = KitChatMediaKind(mediaType: attachment.mediaType)
            guard KitChatMediaLimits.fits(attachment.byteCount, kind: kind),
                  attachment.mediaData.map({
                      !$0.isEmpty && $0.count == attachment.byteCount
                  }) ?? (attachment.localStorageKind == .protectedFile)
            else {
                lastError =
                    "\(kind.previewLabel)s can be up to \(KitChatMediaLimits.maximumTransferLabel)."
                return false
            }
        }
        let replyTarget = replyToServerMessageID
            .flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        if replyToServerMessageID != nil {
            guard let replyTarget,
                  state.messages.contains(where: { message in
                      message.conversationId.caseInsensitiveCompare(cleanConversationId)
                          == .orderedSame
                          && message.serverMessageId?.lowercased() == replyTarget
                          && message.secureMessagingHistory?.kind.isTimelineMetadata != true
                  })
            else {
                lastError = "That message is no longer available to reply to."
                return false
            }
        }
        let isGroupTarget = state.conversations.first(where: {
            $0.id.caseInsensitiveCompare(cleanConversationId) == .orderedSame
        })?.isGroup == true
        guard MessagingGroupCapabilityPolicy.allowsConversationMutation(
            isGroup: isGroupTarget,
            groupCapabilityEnabled: messagingGroupLocalQueueEnabled
        ) else {
            lastError = "Group messaging is not available right now. You can still read this conversation."
            return false
        }
        guard secureMessagingLocalQueueAvailable else {
            lastError = messagingSendFailureMessage
            return false
        }
        // Group threads queue without a pinned single recipient; per-member privacy and group
        // attestation run authoritatively at flush and on the server, exactly like v1.
        let recipientUserID: String?
        if isGroupTarget {
            recipientUserID = nil
        } else {
            guard let recipientId,
                  let recipientUUID = UUID(
                      uuidString: recipientId.trimmingCharacters(in: .whitespacesAndNewlines)
                  )
            else {
                lastError = "Choose one valid Kit Pay recipient."
                return false
            }
            recipientUserID = recipientUUID.uuidString.lowercased()
        }
        let inferredSharedRecipient = sharedInboxProvisionalRecipient(
            conversationID: cleanConversationId
        )
        let provisionalRecipient = provisionalDirectRecipientUserID
            ?? inferredSharedRecipient
        if let provisionalRecipient {
            guard messagingOfflineDirectCreationLocalQueueEnabled,
                  !isGroupTarget,
                  recipientUserID == provisionalRecipient
            else {
                lastError = "Connect to the internet once to start this conversation."
                return false
            }
        }
        guard let userID = profile?.id else {
            lastError = "Choose one valid Kit Pay recipient."
            return false
        }
        // Bind a batch to the account lifetime that accepted the tap, before SessionStore can
        // suspend. The lease survives local file preparation and is revalidated by the
        // coordinator at its atomic protected-store commit, so a replacement login cannot inherit
        // the durable batch.
        let expectedAccountEpoch = accountEpoch
        guard let commitAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
            forAccountID: userID
        ), let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: expectedSessionID,
            commitAdmission: commitAdmission
        ) else { return false }
        if let recipientUserID,
           !communicationPrivacyAllowsLocalQueue(to: recipientUserID) {
            lastError = "Unblock this account before sending these attachments."
            return false
        }
        // Local-first: every plaintext has a permanent client media id and is verified in the
        // protected cache before the atomic message/record/outbox commit. Picker-time prewrites
        // are reused; only entries newly created by this invocation may be rolled back.
        var createdParkedKeys: [String] = []
        var drafts: [KitMediaMessageV2OutboundBatch.DraftAttachment] = []
        var storageKinds: [LocalMediaRecord.LocalStorageKind] = []
        var preprocessingJobs: [LocalMediaPreprocessingJob?] = []
        func rollbackParks() async {
            for key in createdParkedKeys {
                await SecureMediaFileCache.shared.remove(forStorageKey: key, userID: userID)
            }
        }
        for attachment in attachments {
            let mediaID = attachment.mediaID
            let localKey = mediaID.uuidString.lowercased()
            if let job = attachment.preprocessingJob {
                guard attachment.mediaData == nil,
                      attachment.localStorageKind == .protectedFile,
                      job.isStructurallyValid,
                      job.outputMediaType == attachment.mediaType,
                      job.sources.first?.storageKey == localKey,
                      job.sources.first?.fileSize == attachment.byteCount
                else {
                    await rollbackParks()
                    lastError = "One attachment's local processing record is invalid."
                    return false
                }
                for source in job.sources {
                    guard await SecureMediaFileCache.shared.byteCount(
                        forStorageKey: source.storageKey,
                        userID: userID
                    ) == source.fileSize,
                          await SecureMediaFileCache.shared.protectedOriginalURL(
                              forStorageKey: source.storageKey,
                              userID: userID,
                              expectedByteCount: source.fileSize
                          ) != nil
                    else {
                        await rollbackParks()
                        lastError = "One attachment's local original is no longer available."
                        return false
                    }
                }
            }
            if let mediaData = attachment.mediaData {
                let insert = await SecureMediaFileCache.shared.insertIfAbsent(
                    mediaData,
                    forStorageKey: localKey,
                    userID: userID
                )
                guard insert != .rejected,
                      let parked = await SecureMediaFileCache.shared.data(
                          forStorageKey: localKey,
                          userID: userID
                      ), parked == mediaData
                else {
                    await rollbackParks()
                    lastError = "These attachments could not be saved securely on this device."
                    return false
                }
                if insert == .stored { createdParkedKeys.append(localKey) }
            } else {
                guard attachment.localStorageKind == .protectedFile,
                      await SecureMediaFileCache.shared.byteCount(
                          forStorageKey: localKey,
                          userID: userID
                      ) == attachment.byteCount,
                      await SecureMediaFileCache.shared.protectedOriginalURL(
                          forStorageKey: localKey,
                          userID: userID,
                          expectedByteCount: attachment.byteCount
                      ) != nil
                else {
                    await rollbackParks()
                    lastError = "These attachments could not be saved securely on this device."
                    return false
                }
            }
            drafts.append(KitMediaMessageV2OutboundBatch.DraftAttachment(
                attachmentID: mediaID.uuidString.lowercased(),
                mediaType: attachment.mediaType,
                plaintextByteSize: attachment.byteCount,
                localStorageKey: localKey
            ))
            storageKinds.append(attachment.localStorageKind)
            preprocessingJobs.append(attachment.preprocessingJob)
        }
        guard MessagingGroupCapabilityPolicy.allowsConversationMutation(
            isGroup: isGroupTarget,
            groupCapabilityEnabled: messagingGroupLocalQueueEnabled
        ) else {
            await rollbackParks()
            lastError = "Group messaging is not available right now. You can still read this conversation."
            return false
        }
        do {
            let batch = try KitMediaMessageV2OutboundBatch.queued(
                attachments: drafts,
                rawCaption: rawCaption,
                keyMaterialFactory: { try SecureMediaAttachmentCipher.randomKeyMaterial() }
            )
            _ = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: expectedAccountEpoch,
                sessionID: expectedSessionID,
                commitAdmission: commitAdmission
            ) {
                try await SecureMessagingExchangeCoordinator.shared.queueDeferredMediaBatch(
                    forUserID: userID,
                    conversationID: cleanConversationId,
                    expectedRecipientUserID: recipientUserID,
                    title: title,
                    batch: batch,
                    localStorageKinds: storageKinds,
                    preprocessingJobs: preprocessingJobs,
                    clientMessageID: clientMessageID,
                    submittedDraftBody: submittedDraftBody,
                    submittedDraftMediaAttachments: submittedDraftMediaAttachments,
                    draftClearVersion: draftClearVersion,
                    deliverAt: deliverAt,
                    replyToServerMessageID: replyTarget,
                    provisionalDirectRecipientUserID: provisionalRecipient,
                    commitAdmission: commitAdmission
                )
            }
            // An idempotent replay leaves redundant scratch parks for bounded cache maintenance;
            // deleting them inline could race a composer draft that just acquired the same key.
            guard await reloadOutboxStateIfCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return false }
            if preprocessingJobs.contains(where: { $0 != nil }) {
                schedulePendingMediaPreprocessing()
            }
            scheduleOutboxWake()
            if isOnline {
                Task { [weak self] in await self?.flushOutbox() }
            }
            return true
        } catch let error as KitMediaMessageV2OutboundBatch.QueueValidationError {
            await rollbackParks()
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return false }
            // Each §4 violation fails the whole send visibly under its own reason; the staged
            // attachments and typed draft stay untouched in the composer for another attempt.
            switch error {
            case .invalidItems:
                lastError =
                    "These attachments can't be sent together. Send 2 to 8 files, each up to \(KitChatMediaLimits.maximumTransferLabel)."
            case .captionOverBudget:
                lastError = "That caption is too long to send with these attachments. Shorten it and try again."
            case .reservedCaption:
                lastError = "This caption can't be sent. Edit it and try again."
            }
            return false
        } catch {
            await rollbackParks()
            return await queueMediaMessageFailureResult(
                error,
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            )
        }
    }

    private func queueMediaMessageFailureResult(
        _ error: Error,
        accountEpoch expectedAccountEpoch: UUID,
        userID: String,
        sessionID expectedSessionID: String
    ) async -> Bool {
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: expectedSessionID
        ) else { return false }
        lastError = error.localizedDescription
        return false
    }

    private struct PendingMediaPreprocessingTarget: Sendable {
        let messageID: UUID
        let conversationID: String
        let attachmentID: String
        let commandID: UUID
        let job: LocalMediaPreprocessingJob
        let lastAttemptAt: Date
    }

    private var hasPendingMediaPreprocessing: Bool {
        state.messages.contains { message in
            (message.localMediaRecords ?? []).contains { $0.preprocessingJob != nil }
        }
    }

    /// Starts one process-wide preprocessing drain. The durable message is already visible and
    /// locally playable when this runs; only the parked outbox command waits. Processing is local
    /// and therefore continues offline, while every publication is fenced to the account/session
    /// that owned the source files when the task began.
    @discardableResult
    private func schedulePendingMediaPreprocessing() -> Task<Void, Never>? {
        guard mediaPreprocessingTask == nil,
              isSignedIn,
              !isSigningOut,
              !isSubmittingAccountDeletion,
              accountSetupStep == nil,
              communicationAccessGranted
        else { return mediaPreprocessingTask }
        mediaPreprocessingGeneration &+= 1
        let generation = mediaPreprocessingGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPendingMediaPreprocessing(
                maximumItems: MediaPreprocessingPolicy.maximumItemsPerPass
            )
            guard self.mediaPreprocessingGeneration == generation else { return }
            self.mediaPreprocessingTask = nil
            self.scheduleOutboxWake()
            if self.isOnline { await self.flushOutbox() }
            if self.hasPendingMediaPreprocessing {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(MediaPreprocessingPolicy.retryDelay))
                    guard !Task.isCancelled,
                          let self,
                          self.mediaPreprocessingGeneration == generation
                    else { return }
                    self.schedulePendingMediaPreprocessing()
                }
            }
        }
        mediaPreprocessingTask = task
        return task
    }

    private func runPendingMediaPreprocessing(maximumItems: Int) async {
        guard maximumItems > 0,
              let userID = profile?.id,
              let sessionID = await sessions.current()?.sessionId
        else { return }
        let expectedAccountEpoch = accountEpoch
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == userID else { return }
        var targets: [PendingMediaPreprocessingTarget] = []
        for message in snapshot.messages {
            let commands = snapshot.outbox.filter {
                $0.kind == .secureMessage
                    && $0.messageId == message.id
                    && $0.awaitingMediaPreprocessing == true
            }
            guard commands.count == 1, let command = commands.first else { continue }
            for record in message.localMediaRecords ?? [] {
                guard let job = record.preprocessingJob,
                      job.isStructurallyValid,
                      record.isStructurallyValid
                else { continue }
                targets.append(PendingMediaPreprocessingTarget(
                    messageID: message.id,
                    conversationID: message.conversationId,
                    attachmentID: record.id,
                    commandID: command.id,
                    job: job,
                    lastAttemptAt: record.updatedAt
                ))
            }
        }

        // Starting/failing a job advances `updatedAt`, so oldest-first admission rotates a bad
        // codec input behind untouched work instead of blocking the first eight rows forever.
        let selected = Array(targets.sorted { lhs, rhs in
            if lhs.lastAttemptAt != rhs.lastAttemptAt {
                return lhs.lastAttemptAt < rhs.lastAttemptAt
            }
            if lhs.messageID != rhs.messageID {
                return lhs.messageID.uuidString < rhs.messageID.uuidString
            }
            return lhs.attachmentID < rhs.attachmentID
        }.prefix(maximumItems))
        guard !selected.isEmpty else { return }
        // Attachments sharing one outbox command are one logical message. Keep that command's
        // mutations ordered while overlapping work belonging to independent messages.
        var commandOrder: [UUID] = []
        var targetsByCommand: [UUID: [PendingMediaPreprocessingTarget]] = [:]
        for target in selected {
            if targetsByCommand[target.commandID] == nil {
                commandOrder.append(target.commandID)
            }
            targetsByCommand[target.commandID, default: []].append(target)
        }
        let groups = commandOrder.compactMap { targetsByCommand[$0] }
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            let initialCount = min(
                MediaPreprocessingPolicy.maximumConcurrentJobs,
                groups.count
            )
            while nextIndex < initialCount {
                let targets = groups[nextIndex]
                nextIndex += 1
                group.addTask { @MainActor [weak self] in
                    await self?.processPendingMediaPreprocessingTargets(
                        targets,
                        userID: userID,
                        accountEpoch: expectedAccountEpoch,
                        sessionID: sessionID
                    )
                }
            }
            while await group.next() != nil {
                guard nextIndex < groups.count, !Task.isCancelled else { continue }
                let targets = groups[nextIndex]
                nextIndex += 1
                group.addTask { @MainActor [weak self] in
                    await self?.processPendingMediaPreprocessingTargets(
                        targets,
                        userID: userID,
                        accountEpoch: expectedAccountEpoch,
                        sessionID: sessionID
                    )
                }
            }
        }
    }

    private func processPendingMediaPreprocessingTargets(
        _ targets: [PendingMediaPreprocessingTarget],
        userID: String,
        accountEpoch expectedAccountEpoch: UUID,
        sessionID: String
    ) async {
        for target in targets {
            guard !Task.isCancelled else { return }
            await processPendingMediaPreprocessingTarget(
                target,
                userID: userID,
                accountEpoch: expectedAccountEpoch,
                sessionID: sessionID
            )
        }
    }

    private func processPendingMediaPreprocessingTarget(
        _ target: PendingMediaPreprocessingTarget,
        userID: String,
        accountEpoch expectedAccountEpoch: UUID,
        sessionID: String
    ) async {
        guard !Task.isCancelled,
              await outboxContextIsCurrent(
                  accountEpoch: expectedAccountEpoch,
                  userID: userID,
                  sessionID: sessionID
              )
        else { return }
        do {
            try await store.update { persisted in
                guard persisted.profile?.id == userID,
                      let commandIndex = persisted.outbox.firstIndex(where: {
                          $0.id == target.commandID
                              && $0.messageId == target.messageID
                              && $0.awaitingMediaPreprocessing == true
                      }),
                      persisted.outbox[commandIndex].failureDisposition == nil,
                      let messageIndex = persisted.messages.firstIndex(where: {
                          $0.id == target.messageID
                              && $0.conversationId == target.conversationID
                      }),
                      LocalMediaRecordPolicy.markPreprocessingStarted(
                          &persisted.messages[messageIndex],
                          attachmentID: target.attachmentID,
                          expectedJob: target.job
                      )
                else { throw CancellationError() }
            }
            let byteCount = try await preprocessLocalMedia(
                target,
                userID: userID,
                accountEpoch: expectedAccountEpoch,
                sessionID: sessionID
            )
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: sessionID
            ), await SecureMediaFileCache.shared.protectedOriginalURL(
                forStorageKey: target.job.outputStorageKey,
                userID: userID,
                expectedByteCount: byteCount
            ) != nil
            else { throw CancellationError() }
            try await store.update { persisted in
                guard persisted.profile?.id == userID,
                      let commandIndex = persisted.outbox.firstIndex(where: {
                          $0.id == target.commandID
                              && $0.messageId == target.messageID
                              && $0.awaitingMediaPreprocessing == true
                      }),
                      let messageIndex = persisted.messages.firstIndex(where: {
                          $0.id == target.messageID
                              && $0.conversationId == target.conversationID
                      }),
                      LocalMediaRecordPolicy.completePreprocessing(
                          &persisted.messages[messageIndex],
                          attachmentID: target.attachmentID,
                          expectedJob: target.job,
                          outputByteCount: byteCount
                      )
                else { throw CancellationError() }
                let stillHasPreprocessing = (
                    persisted.messages[messageIndex].localMediaRecords ?? []
                ).contains { $0.preprocessingJob != nil }
                if !stillHasPreprocessing {
                    persisted.outbox[commandIndex].awaitingMediaPreprocessing = nil
                    if persisted.outbox[commandIndex].scheduledAt == nil {
                        persisted.outbox[commandIndex].nextAttemptAt = Date()
                    }
                }
            }
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: sessionID
            ) else { return }
            await publishLatestState()
        } catch is CancellationError {
            return
        } catch {
            try? await store.update { persisted in
                guard persisted.profile?.id == userID,
                      persisted.outbox.contains(where: {
                          $0.id == target.commandID
                              && $0.messageId == target.messageID
                              && $0.awaitingMediaPreprocessing == true
                      }),
                      let messageIndex = persisted.messages.firstIndex(where: {
                          $0.id == target.messageID
                              && $0.conversationId == target.conversationID
                      })
                else { return }
                _ = LocalMediaRecordPolicy.markPreprocessingFailed(
                    &persisted.messages[messageIndex],
                    attachmentID: target.attachmentID,
                    expectedJob: target.job
                )
            }
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: sessionID
            ) else { return }
            await publishLatestState()
        }
    }

    /// An occupied preprocessing destination that is not a valid completed output is immutable
    /// residue, not a file we may replace. Re-key the exact durable job atomically and leave the
    /// old bytes for age-gated orphan reconciliation. Throwing cancellation at the call site
    /// prevents the stale in-memory target from being marked failed over the replacement job.
    private func rekeyInvalidPreprocessingOutput(
        _ target: PendingMediaPreprocessingTarget,
        userID: String,
        accountEpoch expectedAccountEpoch: UUID,
        sessionID: String
    ) async throws {
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: sessionID
        ) else { throw CancellationError() }
        let replacementOutputKey = UUID().uuidString.lowercased()
        try await store.update { persisted in
            guard persisted.profile?.id == userID,
                  persisted.outbox.contains(where: {
                      $0.id == target.commandID
                          && $0.messageId == target.messageID
                          && $0.awaitingMediaPreprocessing == true
                          && $0.failureDisposition == nil
                  }),
                  MediaPreprocessingPolicy.canReplaceOutput(
                      storageKey: target.job.outputStorageKey,
                      ownedBy: target.messageID,
                      attachmentID: target.attachmentID,
                      expectedJob: target.job,
                      in: persisted
                  ),
                  MediaPreprocessingPolicy.isOutputStorageKeyUnowned(
                      replacementOutputKey,
                      in: persisted
                  ),
                  let messageIndex = persisted.messages.firstIndex(where: {
                      $0.id == target.messageID
                          && $0.conversationId == target.conversationID
                  }),
                  LocalMediaRecordPolicy.rekeyPreprocessingOutput(
                      &persisted.messages[messageIndex],
                      attachmentID: target.attachmentID,
                      expectedJob: target.job,
                      newOutputStorageKey: replacementOutputKey
                  )
            else { throw CancellationError() }
        }
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: sessionID
        ) else { throw CancellationError() }
        await publishLatestState()
    }

    private func preprocessLocalMedia(
        _ target: PendingMediaPreprocessingTarget,
        userID: String,
        accountEpoch expectedAccountEpoch: UUID,
        sessionID: String
    ) async throws -> Int {
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: sessionID
        ) else { throw CancellationError() }

        let ownershipSnapshot = await store.snapshot()
        guard ownershipSnapshot.profile?.id == userID,
              MediaPreprocessingPolicy.canReplaceOutput(
                  storageKey: target.job.outputStorageKey,
                  ownedBy: target.messageID,
                  attachmentID: target.attachmentID,
                  expectedJob: target.job,
                  in: ownershipSnapshot
              )
        else { throw SecureMediaAttachmentError.invalidMedia }
        // A prior process may have atomically published this job's output before it could commit
        // the state transition. Reuse it only after decoding its actual content. An occupied but
        // invalid destination is never deleted or overwritten; the durable job moves to a fresh
        // key and the bounded orphan sweep retires the old bytes after its grace window.
        let existingOutput = await SecureMediaFileCache.shared.probeProtectedOriginal(
            forStorageKey: target.job.outputStorageKey,
            userID: userID
        )
        switch existingOutput {
        case .candidate(let existingURL, let existingByteCount):
            if KitChatMediaLimits.fits(
                   existingByteCount,
                   kind: KitChatMediaKind(mediaType: target.job.outputMediaType)
               ),
               await MediaPreprocessingPolicy.isValidPublishedOutput(
                   at: existingURL,
                   for: target.job
               ) {
                return existingByteCount
            }
            try await rekeyInvalidPreprocessingOutput(
                target,
                userID: userID,
                accountEpoch: expectedAccountEpoch,
                sessionID: sessionID
            )
            throw CancellationError()
        case .occupiedInvalid:
            try await rekeyInvalidPreprocessingOutput(
                target,
                userID: userID,
                accountEpoch: expectedAccountEpoch,
                sessionID: sessionID
            )
            throw CancellationError()
        case .absent:
            break
        }

        var sourceURLs: [URL] = []
        sourceURLs.reserveCapacity(target.job.sources.count)
        for source in target.job.sources {
            guard let url = await SecureMediaFileCache.shared.protectedOriginalURL(
                forStorageKey: source.storageKey,
                userID: userID,
                expectedByteCount: source.fileSize
            ) else { throw SecureMediaAttachmentError.invalidMedia }
            sourceURLs.append(url)
        }
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: sessionID
        ) else { throw CancellationError() }
        let outputURL: URL
        switch target.job.kind {
        case .voiceAssembly:
            guard let assembled = await VoiceNoteSegmentAssembler.assembleToFile(sourceURLs)
            else { throw SecureMediaAttachmentError.invalidMedia }
            outputURL = assembled
        case .imageJPEG:
            let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(
                "kit-image-final-\(UUID().uuidString.lowercased()).jpg",
                isDirectory: false
            )
            do {
                _ = try await Task.detached(priority: .utility) {
                    try AttachmentImageDecoder.secureJPEGFile(
                        from: sourceURLs[0],
                        to: candidate,
                        maximumOutputBytes: target.job.sources[0].fileSize
                    )
                }.value
                outputURL = candidate
            } catch {
                try? FileManager.default.removeItem(at: candidate)
                throw error
            }
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let byteCount = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              KitChatMediaLimits.fits(
                  byteCount,
                  kind: KitChatMediaKind(mediaType: target.job.outputMediaType)
              ),
              await outboxContextIsCurrent(
                  accountEpoch: expectedAccountEpoch,
                  userID: userID,
                  sessionID: sessionID
              ),
              await MediaPreprocessingPolicy.isValidPublishedOutput(
                  at: outputURL,
                  for: target.job
              )
        else { throw SecureMediaAttachmentError.invalidMedia }
        let publicationSnapshot = await store.snapshot()
        guard publicationSnapshot.profile?.id == userID,
              MediaPreprocessingPolicy.canReplaceOutput(
                  storageKey: target.job.outputStorageKey,
                  ownedBy: target.messageID,
                  attachmentID: target.attachmentID,
                  expectedJob: target.job,
                  in: publicationSnapshot
              )
        else { throw CancellationError() }
        _ = try await SecureMediaFileCache.shared.importProtectedOriginal(
            from: outputURL,
            forStorageKey: target.job.outputStorageKey,
            userID: userID,
            mediaType: target.job.outputMediaType,
            expectedByteCount: byteCount,
            moveSource: true
        )
        return byteCount
    }

    /// Plaintext bytes for a single-attachment message that is still pending upload — returned
    /// together with the MIME type and caption of the very resolution that produced them —
    /// addressed by identity like every other media load. `SecureMediaLoadPolicy
    /// .resolvePendingSingle` gates the one current persisted row (coherent storage form, bound
    /// body, size bounds) before anything is served; a parked read is pinned to the declared
    /// byte count, and after the cache await the same account and identity must resolve to the
    /// identical complete shape again — a row that sealed, vanished, or was rewritten during
    /// the read serves nothing.
    func loadPendingMedia(
        messageID: UUID,
        conversationId: String
    ) async -> SecureMediaLoadPolicy.LoadedItem? {
        try? await loadSecureMediaItem(
            messageID: messageID,
            conversationId: conversationId,
            itemIndex: nil,
            allowsDownload: false
        )
    }

    /// Returns the ordered finalized segments of a voice note whose durable bubble precedes
    /// assembly. Each cache lookup and the final return are bound to the exact current record;
    /// deletion, account switch, or job completion during resolution serves nothing stale.
    func loadPendingVoicePlayback(
        messageID: UUID,
        conversationId: String
    ) async -> SecureMediaLoadPolicy.LocalVoicePlayback? {
        let snapshot = await store.snapshot()
        guard let userID = snapshot.profile?.id,
              case let .pendingSingle(pending)? = SecureMediaLoadPolicy.resolve(
                  messageID: messageID,
                  conversationId: conversationId,
                  itemIndex: nil,
                  in: snapshot.messages
              ),
              let record = LocalMediaRecordPolicy.record(
                  messageID: messageID,
                  conversationID: conversationId,
                  attachmentID: pending.attachmentID,
                  mediaType: pending.mediaType,
                  fileSize: pending.expectedByteCount ?? 0,
                  remoteStorageKey: nil,
                  in: snapshot.messages
              ),
              let job = record.preprocessingJob,
              job.kind == .voiceAssembly,
              record.originalSources == job.sources
        else { return nil }
        var urls: [URL] = []
        var durations: [TimeInterval] = []
        for source in job.sources {
            guard let duration = source.duration,
                  let url = await SecureMediaFileCache.shared.protectedOriginalURL(
                      forStorageKey: source.storageKey,
                      userID: userID,
                      expectedByteCount: source.fileSize
                  )
            else { return nil }
            urls.append(url)
            durations.append(duration)
        }
        let current = await store.snapshot()
        guard current.profile?.id == userID,
              SecureMediaLoadPolicy.resolve(
                  messageID: messageID,
                  conversationId: conversationId,
                  itemIndex: nil,
                  in: current.messages
              ) == .pendingSingle(pending),
              LocalMediaRecordPolicy.record(
                  messageID: messageID,
                  conversationID: conversationId,
                  attachmentID: pending.attachmentID,
                  mediaType: pending.mediaType,
                  fileSize: pending.expectedByteCount ?? 0,
                  remoteStorageKey: nil,
                  in: current.messages
              ) == record
        else { return nil }
        let playback = SecureMediaLoadPolicy.LocalVoicePlayback(
            fileURLs: urls,
            segmentDurations: durations,
            attachmentID: pending.attachmentID
        )
        return playback.isStructurallyValid ? playback : nil
    }

    /// Resolves a sender-owned file-backed original without reading it into memory. This uses
    /// the same identity discipline as `loadSecureMediaItem`: resolve the current persisted row,
    /// bind its LocalMediaRecord, await the cache actor, then require the whole resolution and
    /// record to be unchanged before returning the URL.
    func loadProtectedLocalMediaFile(
        messageID: UUID,
        conversationId: String,
        itemIndex: Int?
    ) async -> SecureMediaLoadPolicy.LocalFileItem? {
        let mediaDiagnosticsScope = LocalMediaPerformanceMonitor.shared.captureProducerScope()
        let snapshot = await store.snapshot()
        guard let userID = snapshot.profile?.id,
              let resolved = SecureMediaLoadPolicy.resolve(
                  messageID: messageID,
                  conversationId: conversationId,
                  itemIndex: itemIndex,
                  in: snapshot.messages
              )
        else { return nil }
        let identity: (id: String, type: String, size: Int, remote: String?, caption: String?)
        switch resolved {
        case .pendingSingle(let pending):
            identity = (
                pending.attachmentID,
                pending.mediaType,
                pending.expectedByteCount ?? pending.inlineData?.count ?? 0,
                nil,
                pending.caption
            )
        case .pendingBatchItem(let batch, _, let index):
            let item = batch.items[index]
            identity = (item.attachmentID, item.mediaType, item.plaintextByteSize, item.storageKey, nil)
        case .sealedBatchItem(let descriptor, _, let index):
            let item = descriptor.items[index]
            identity = (item.attachmentID, item.mediaType, item.plaintextByteSize, item.storageKey, nil)
        case .single(let descriptor, _, _):
            identity = (
                descriptor.attachmentID,
                descriptor.mediaType,
                descriptor.plaintextByteSize,
                descriptor.storageKey,
                descriptor.caption
            )
        }
        guard let record = LocalMediaRecordPolicy.record(
            messageID: messageID,
            conversationID: conversationId,
            attachmentID: identity.id,
            mediaType: identity.type,
            fileSize: identity.size,
            remoteStorageKey: identity.remote,
            in: snapshot.messages
        ) else { return nil }
        if record.localStorageKind == .protectedFile,
           [.localOriginal, .localCached].contains(record.availabilityState),
           let storageKey = record.localStorageKey,
           let accessLease = await SecureMediaFileCache.shared.protectedOriginalLease(
               forStorageKey: storageKey,
               userID: userID,
               expectedByteCount: identity.size
           ) {
            let current = await store.snapshot()
            guard current.profile?.id == userID,
                  SecureMediaLoadPolicy.resolve(
                      messageID: messageID,
                      conversationId: conversationId,
                      itemIndex: itemIndex,
                      in: current.messages
                  ) == resolved,
                  LocalMediaRecordPolicy.record(
                      messageID: messageID,
                      conversationID: conversationId,
                      attachmentID: identity.id,
                      mediaType: identity.type,
                      fileSize: identity.size,
                      remoteStorageKey: identity.remote,
                      in: current.messages
                  ) == record
            else { return nil }
            return SecureMediaLoadPolicy.LocalFileItem(
                url: accessLease.fileURL,
                mediaType: identity.type,
                caption: identity.caption,
                byteCount: identity.size,
                attachmentID: identity.id,
                accessLease: accessLease
            )
        }
        guard record.direction == .received,
              record.availabilityState == .remoteOnly,
              record.downloadState == .pending || record.downloadState == .failed,
              identity.remote != nil,
              isOnline,
              secureMessagingAvailable,
              let sessionID = await sessions.current()?.sessionId
        else { return nil }
        guard let capacityReservation = reserveReceivedMediaHydrationCapacity(
            plaintextByteCount: identity.size
        ) else { return nil }
        defer { receivedMediaHydrationReservations[capacityReservation] = nil }
        if let mediaID = UUID(uuidString: identity.id) {
            LocalMediaPerformanceMonitor.shared.beginRecipientHydration(
                mediaID: mediaID,
                descriptorObservedAt: record.createdAt,
                kind: KitChatMediaKind(mediaType: identity.type),
                byteCount: identity.size,
                duration: record.duration,
                producerScope: mediaDiagnosticsScope
            )
        }
        let expectedAccountEpoch = accountEpoch
        do {
            try await store.update { persisted in
                guard persisted.profile?.id == userID,
                      SecureMediaLoadPolicy.resolve(
                          messageID: messageID,
                          conversationId: conversationId,
                          itemIndex: itemIndex,
                          in: persisted.messages
                      ) == resolved
                else { throw SecureMediaAttachmentError.invalidDescriptor }
                let indices = persisted.messages.indices.filter {
                    persisted.messages[$0].id == messageID
                        && persisted.messages[$0].conversationId == conversationId
                }
                guard indices.count == 1, let index = indices.first,
                      LocalMediaRecordPolicy.markDownloading(
                          &persisted.messages[index],
                          attachmentID: identity.id
                      )
                else { throw SecureMediaAttachmentError.invalidDescriptor }
            }
            let hydrated = try await APIClientSessionBinding.$sessionID.withValue(sessionID) {
                try await SecureMessagingExchangeCoordinator.shared.hydrateMediaFile(
                    forUserID: userID,
                    conversationID: conversationId,
                    messageID: messageID,
                    itemIndex: itemIndex
                )
            }
            guard expectedAccountEpoch == accountEpoch,
                  await outboxContextIsCurrent(
                      accountEpoch: expectedAccountEpoch,
                      userID: userID,
                      sessionID: sessionID
                  ),
                  hydrated.attachmentID == identity.id,
                  hydrated.storageKey == identity.remote,
                  hydrated.mediaType == identity.type,
                  hydrated.plaintextByteSize == identity.size
            else { throw CancellationError() }
            try await store.update { persisted in
                guard persisted.profile?.id == userID,
                      SecureMediaLoadPolicy.resolve(
                          messageID: messageID,
                          conversationId: conversationId,
                          itemIndex: itemIndex,
                          in: persisted.messages
                      ) == resolved
                else { throw SecureMediaAttachmentError.invalidDescriptor }
                let indices = persisted.messages.indices.filter {
                    persisted.messages[$0].id == messageID
                        && persisted.messages[$0].conversationId == conversationId
                }
                guard indices.count == 1, let index = indices.first,
                      LocalMediaRecordPolicy.markDownloadedProtectedFile(
                          &persisted.messages[index],
                          attachmentID: identity.id,
                          remoteStorageKey: hydrated.storageKey,
                          localStorageKey: hydrated.attachmentID
                      )
                else { throw SecureMediaAttachmentError.invalidDescriptor }
            }
            await publishLatestState()
            if let mediaID = UUID(uuidString: hydrated.attachmentID) {
                LocalMediaPerformanceMonitor.shared.markRecipientHydrated(
                    mediaID: mediaID,
                    producerScope: mediaDiagnosticsScope
                )
            }
            guard let accessLease = await SecureMediaFileCache.shared.protectedOriginalLease(
                forStorageKey: hydrated.attachmentID,
                userID: userID,
                expectedByteCount: hydrated.plaintextByteSize
            ) else { throw SecureMediaAttachmentError.invalidCiphertext }
            if KitChatMediaKind(mediaType: hydrated.mediaType) != .video,
               let mediaID = UUID(uuidString: hydrated.attachmentID) {
                scheduleLocalMediaDuration(
                    mediaID: mediaID,
                    fileURL: accessLease.fileURL,
                    mediaType: hydrated.mediaType
                )
            }
            await enforceReceivedMediaCacheBudget()
            return SecureMediaLoadPolicy.LocalFileItem(
                url: accessLease.fileURL,
                mediaType: hydrated.mediaType,
                caption: identity.caption,
                byteCount: hydrated.plaintextByteSize,
                attachmentID: hydrated.attachmentID,
                accessLease: accessLease
            )
        } catch {
            if expectedAccountEpoch == accountEpoch {
                try? await store.update { persisted in
                    guard persisted.profile?.id == userID,
                          SecureMediaLoadPolicy.resolve(
                              messageID: messageID,
                              conversationId: conversationId,
                              itemIndex: itemIndex,
                              in: persisted.messages
                          ) == resolved
                    else { return }
                    let indices = persisted.messages.indices.filter {
                        persisted.messages[$0].id == messageID
                            && persisted.messages[$0].conversationId == conversationId
                    }
                    if indices.count == 1, let index = indices.first {
                        _ = LocalMediaRecordPolicy.markDownloadFailed(
                            &persisted.messages[index],
                            attachmentID: identity.id
                        )
                    }
                }
                // This method is also called directly from a visible bubble, outside the
                // background hydration pass. Publish its terminal failure so the row leaves
                // `.downloading` immediately and the customer's Retry action becomes available.
                // `publishLatestState` revision-fences older snapshots and accountEpoch prevents
                // a completed request from crossing sign-out/account replacement.
                if expectedAccountEpoch == accountEpoch {
                    await publishLatestState()
                }
            }
            return nil
        }
    }

    /// Starts one bounded receiver-cache pass. It is independent of any visible conversation:
    /// sync/relaunch/background replay all call this, and each item is re-resolved through its
    /// stable message/media identity before and after network or file work.
    @discardableResult
    private func schedulePendingMediaHydration() -> Task<Void, Never>? {
        guard mediaHydrationTask == nil,
              isOnline,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted
        else { return mediaHydrationTask }
        mediaHydrationGeneration &+= 1
        let generation = mediaHydrationGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let pendingBefore = self.pendingReceivedMediaHydrationCount
            await self.runPendingMediaHydration(maximumItems: MediaHydrationPolicy.maximumItemsPerPass)
            guard self.mediaHydrationGeneration == generation else { return }
            // Concurrent children commit independently. An early success can publish while a
            // sibling is still `.downloading`, then that sibling can fail without publishing.
            // Refresh after the whole pass so retry admission observes durable final states.
            await self.publishLatestState()
            guard self.mediaHydrationGeneration == generation else { return }
            self.mediaHydrationTask = nil
            let pendingAfter = self.pendingReceivedMediaHydrationCount
            if pendingAfter > 0, pendingAfter < pendingBefore {
                // Useful progress means there may simply have been more work than one bounded
                // pass admitted. Continue immediately; a failure-only pass uses the delayed BG
                // retry below and cannot spin or hammer the attachment service.
                _ = self.schedulePendingMediaHydration()
            } else if pendingAfter > 0 {
                CommunicationBackgroundReplayScheduler.shared.schedule(
                    earliestBeginDate: Date().addingTimeInterval(MediaHydrationPolicy.retryDelay)
                )
            }
        }
        mediaHydrationTask = task
        return task
    }

    private var hasPendingReceivedMediaHydration: Bool {
        pendingReceivedMediaHydrationCount > 0
    }

    private var pendingReceivedMediaHydrationCount: Int {
        state.messages.reduce(into: 0) { count, message in
            guard !message.isOutgoing else { return }
            count += (message.localMediaRecords ?? []).filter { record in
                record.direction == .received
                    && record.availabilityState == .remoteOnly
                    && record.cacheEvictedAt == nil
                    && [.pending, .failed].contains(record.downloadState)
            }.count
        }
    }

    private func reserveReceivedMediaHydrationCapacity(
        plaintextByteCount: Int
    ) -> UUID? {
        guard plaintextByteCount > 0 else { return nil }
        var aggregate = plaintextByteCount
        for reserved in receivedMediaHydrationReservations.values {
            let (next, overflow) = aggregate.addingReportingOverflow(reserved)
            guard !overflow else { return nil }
            aggregate = next
        }
        guard MediaHydrationPolicy.hasCapacity(
            plaintextByteCount: aggregate,
            volumeURL: FileManager.default.temporaryDirectory
        ) else { return nil }
        let token = UUID()
        receivedMediaHydrationReservations[token] = plaintextByteCount
        return token
    }

    private func runPendingMediaHydration(maximumItems: Int) async {
        guard maximumItems > 0, isOnline, let userID = profile?.id,
              let sessionID = await sessions.current()?.sessionId
        else { return }
        let expectedAccountEpoch = accountEpoch
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == userID else { return }
        var targets: [(
            messageID: UUID,
            conversationID: String,
            itemIndex: Int?,
            lastAttemptAt: Date
        )] = []
        for message in snapshot.messages where !message.isOutgoing {
            let pendingRecords = (message.localMediaRecords ?? []).filter { record in
                record.direction == .received
                    && record.availabilityState == .remoteOnly
                    && record.cacheEvictedAt == nil
                    && [.pending, .failed].contains(record.downloadState)
            }
            let pendingByID = Dictionary(grouping: pendingRecords, by: \.id)
                .compactMapValues { $0.count == 1 ? $0[0] : nil }
            guard !pendingByID.isEmpty else { continue }
            if let descriptor = KitMediaMessageDescriptor.parse(message.body),
               let record = pendingByID[descriptor.attachmentID] {
                targets.append((message.id, message.conversationId, nil, record.updatedAt))
            } else if let descriptor = KitMediaMessageV2Descriptor.parse(message.body) {
                for (index, item) in descriptor.items.enumerated()
                    where pendingByID[item.attachmentID] != nil {
                    targets.append((
                        message.id,
                        message.conversationId,
                        index,
                        pendingByID[item.attachmentID]!.updatedAt
                    ))
                }
            }
        }
        // A failed attempt updates `updatedAt`; oldest-first scheduling therefore rotates a
        // permanently failing row behind untouched work instead of starving every later album.
        let selected = Array(targets.sorted { lhs, rhs in
            if lhs.lastAttemptAt != rhs.lastAttemptAt {
                return lhs.lastAttemptAt < rhs.lastAttemptAt
            }
            if lhs.messageID != rhs.messageID {
                return lhs.messageID.uuidString < rhs.messageID.uuidString
            }
            return (lhs.itemIndex ?? -1) < (rhs.itemIndex ?? -1)
        }.prefix(maximumItems))
        guard !selected.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            let initialCount = min(MediaHydrationPolicy.maximumConcurrentDownloads, selected.count)
            while nextIndex < initialCount {
                let target = selected[nextIndex]
                nextIndex += 1
                group.addTask { @MainActor [weak self] in
                    guard let self,
                          !Task.isCancelled,
                          self.isOnline,
                          await self.outboxContextIsCurrent(
                              accountEpoch: expectedAccountEpoch,
                              userID: userID,
                              sessionID: sessionID
                          )
                    else { return }
                    _ = await self.loadProtectedLocalMediaFile(
                        messageID: target.messageID,
                        conversationId: target.conversationID,
                        itemIndex: target.itemIndex
                    )
                }
            }
            while await group.next() != nil {
                guard nextIndex < selected.count, !Task.isCancelled else { continue }
                let target = selected[nextIndex]
                nextIndex += 1
                group.addTask { @MainActor [weak self] in
                    guard let self,
                          !Task.isCancelled,
                          self.isOnline,
                          await self.outboxContextIsCurrent(
                              accountEpoch: expectedAccountEpoch,
                              userID: userID,
                              sessionID: sessionID
                          )
                    else { return }
                    _ = await self.loadProtectedLocalMediaFile(
                        messageID: target.messageID,
                        conversationId: target.conversationID,
                        itemIndex: target.itemIndex
                    )
                }
            }
        }
    }

    /// Keeps only the bounded, receiver-owned portion of the media library evictable. Selection
    /// reserves exact file fingerprints first; the protected-state CAS then makes every selected
    /// item remote-only before deletion is committed. Sender originals never enter the candidate
    /// set, and a lease acquired by an active player/document viewer excludes that file.
    private func enforceReceivedMediaCacheBudget() async {
        let snapshot = await store.snapshot()
        guard let userID = snapshot.profile?.id else { return }
        let candidates: [SecureMediaCacheEvictionCandidate] = snapshot.messages.flatMap {
            message -> [SecureMediaCacheEvictionCandidate] in
            (message.localMediaRecords ?? []).compactMap {
                record -> SecureMediaCacheEvictionCandidate? in
                guard !message.isOutgoing,
                      record.direction == .received,
                      record.availabilityState == .localCached,
                      record.downloadState == .downloaded,
                      record.remoteEncryptedObjectID != nil,
                      let storageKey = record.localStorageKey,
                      [.protectedFile, .encryptedBlob].contains(record.localStorageKind)
                else { return nil }
                return SecureMediaCacheEvictionCandidate(
                    messageID: message.id,
                    conversationID: message.conversationId,
                    attachmentID: record.id,
                    storageKey: storageKey,
                    expectedPlaintextByteCount: record.fileSize,
                    storageKind: record.localStorageKind,
                    ownership: .receivedCache,
                    lastAccessedAt: record.updatedAt
                )
            }
        }
        guard let reservation = await SecureMediaFileCache.shared.reserveReceivedCacheEviction(
            candidates: candidates,
            forUserID: userID,
            maximumBytes: MediaHydrationPolicy.maximumReceivedCacheBytes,
            targetBytes: MediaHydrationPolicy.targetReceivedCacheBytes,
            recentAccessProtection: MediaHydrationPolicy.recentAccessProtection
        ) else { return }
        do {
            try await store.update { persisted in
                guard persisted.profile?.id == userID else { throw StoreError.accountChanged }
                for candidate in reservation.candidates {
                    let indices = persisted.messages.indices.filter { index in
                        persisted.messages[index].id == candidate.messageID
                            && persisted.messages[index].conversationId == candidate.conversationID
                    }
                    guard indices.count == 1, let index = indices.first,
                          LocalMediaRecordPolicy.markReceivedCacheEvicted(
                              &persisted.messages[index],
                              attachmentID: candidate.attachmentID,
                              expectedLocalStorageKey: candidate.storageKey,
                              expectedUpdatedAt: candidate.lastAccessedAt
                          )
                    else { throw SecureMediaAttachmentError.invalidDescriptor }
                }
            }
        } catch {
            await SecureMediaFileCache.shared.cancelEviction(reservation, forUserID: userID)
            return
        }
        _ = await SecureMediaFileCache.shared.commitEviction(
            reservation,
            forUserID: userID
        )
        await publishLatestState()
    }

    /// Display-only media kind for a forward payload entry, resolved by identity from the
    /// currently published rows — payload entries carry no wire text to label themselves with.
    /// nil when the identity no longer resolves to a forwardable sealed single attachment.
    func secureMediaForwardKind(messageID: UUID, conversationId: String) -> KitChatMediaKind? {
        guard case let .single(descriptor, _, _)? = SecureMediaLoadPolicy.resolve(
            messageID: messageID,
            conversationId: conversationId,
            itemIndex: nil,
            in: state.messages
        ) else { return nil }
        return KitChatMediaKind(mediaType: descriptor.mediaType)
    }

    /// Plaintext bytes for one media attachment — together with the MIME type and caption of
    /// the row they were resolved from — addressed purely by identity: message UUID,
    /// conversation, and — for a multi-attachment (KITMEDIA2) message — the §8 display index;
    /// nil index is the single-attachment (KITMEDIA1) shape. `SecureMediaLoadPolicy` resolves
    /// that identity against the CURRENT persisted rows (`store.snapshot()`, not a published UI
    /// projection) and strictly re-parses and gates the one matching row before any cache
    /// probe, so a stale view snapshot can never serve bytes for a message that has since been
    /// deleted, replaced, or rewritten, and no caller-supplied descriptor text ever reaches the
    /// verifying open paths. Consumers that re-encode media (forward, share) must take the
    /// returned facts, never facts captured from an earlier row snapshot.
    ///
    /// Every cache probe and download suspends, so bytes are returned only after the same
    /// identity resolves again: the sealed shapes must produce the identical item, and the v1
    /// shape the identical body (its inline slot is the one field this very method legitimately
    /// fills). A row deleted or replaced during any await serves — and caches — nothing.
    ///
    /// A still-pending batch item serves only from the local encrypted cache — its plaintext was
    /// parked there at queue time and copied under the server storage key at each upload
    /// checkpoint, and no server copy is bound to the message before the seal. A sealed item
    /// tries the cache first, then downloads through the coordinator's verifying open path and
    /// caches the result under the item's storage key for offline rereads. Received videos are
    /// stricter: any legacy sealed cache hit is promoted to a leased protected file in the same
    /// call and is never returned as whole-file Data. Batch items are never stored inline on the
    /// message: `attachmentData` is the single-attachment v1 slot, and one wallet-state rewrite
    /// must not carry up to eight large blobs with it.
    ///
    /// `allowsDownload` false serves only bytes that are already local (the row's inline slot or
    /// the encrypted cache) and throws before touching the network otherwise — incidental
    /// surfaces such as video poster frames probe with it so that scrolling a conversation never
    /// silently downloads large attachments.
    func loadSecureMediaItem(
        messageID: UUID,
        conversationId: String,
        itemIndex: Int?,
        allowsDownload: Bool = true
    ) async throws -> SecureMediaLoadPolicy.LoadedItem {
        let snapshot = await store.snapshot()
        guard let userID = snapshot.profile?.id else {
            throw SecureMessagingExchangeError.invalidAccount
        }
        let matchingMessages = snapshot.messages.filter {
            $0.id == messageID && $0.conversationId == conversationId
        }
        guard matchingMessages.count == 1, let resolvedMessage = matchingMessages.first else {
            throw SecureMediaAttachmentError.invalidDescriptor
        }
        guard let resolved = SecureMediaLoadPolicy.resolve(
            messageID: messageID,
            conversationId: conversationId,
            itemIndex: itemIndex,
            in: snapshot.messages
        ) else { throw SecureMediaAttachmentError.invalidDescriptor }
        let mediaIdentity: (id: String, type: String, size: Int, remoteKey: String?)
        switch resolved {
        case .pendingSingle(let pending):
            mediaIdentity = (
                pending.attachmentID,
                pending.mediaType,
                pending.expectedByteCount ?? pending.inlineData?.count ?? 0,
                nil
            )
        case .pendingBatchItem(let batch, _, let index):
            let item = batch.items[index]
            mediaIdentity = (item.attachmentID, item.mediaType, item.plaintextByteSize, item.storageKey)
        case .sealedBatchItem(let descriptor, _, let index):
            let item = descriptor.items[index]
            mediaIdentity = (item.attachmentID, item.mediaType, item.plaintextByteSize, item.storageKey)
        case .single(let descriptor, _, _):
            mediaIdentity = (
                descriptor.attachmentID,
                descriptor.mediaType,
                descriptor.plaintextByteSize,
                descriptor.storageKey
            )
        }
        let localRecord = LocalMediaRecordPolicy.record(
            messageID: messageID,
            conversationID: conversationId,
            attachmentID: mediaIdentity.id,
            mediaType: mediaIdentity.type,
            fileSize: mediaIdentity.size,
            remoteStorageKey: mediaIdentity.remoteKey,
            in: snapshot.messages
        )
        let isReceivedVideo = !resolvedMessage.isOutgoing
            && KitChatMediaKind(mediaType: mediaIdentity.type) == .video
        func currentResolution() async -> SecureMediaLoadPolicy.Resolved? {
            // Ownership first: an account switch during an await swaps the whole persisted
            // state, and a colliding identity in the successor state must not vouch for bytes
            // read under the prior account's cache key.
            let current = await store.snapshot()
            guard current.profile?.id == userID else { return nil }
            return SecureMediaLoadPolicy.resolve(
                messageID: messageID,
                conversationId: conversationId,
                itemIndex: itemIndex,
                in: current.messages
            )
        }
        func recoverCachedReceivedVideoAsProtectedFile(
            storageKey: String,
            caption: String?
        ) async throws -> SecureMediaLoadPolicy.LoadedItem? {
            let recovered = try await ReceivedVideoCachedBlobRecovery.recover(
                store: store,
                cache: .shared,
                userID: userID,
                messageID: messageID,
                conversationID: conversationId,
                itemIndex: itemIndex,
                expectedResolution: resolved,
                expectedRecord: localRecord,
                messageIsOutgoing: resolvedMessage.isOutgoing,
                attachmentID: mediaIdentity.id,
                storageKey: storageKey,
                mediaType: mediaIdentity.type,
                byteCount: mediaIdentity.size,
                caption: caption
            )
            if recovered != nil {
                await publishLatestState()
            }
            return recovered
        }
        func localRecordStillOwns(_ storageKey: String) async -> Bool {
            let current = await store.snapshot()
            guard current.profile?.id == userID,
                  SecureMediaLoadPolicy.resolve(
                      messageID: messageID,
                      conversationId: conversationId,
                      itemIndex: itemIndex,
                      in: current.messages
                  ) == resolved,
                  let record = LocalMediaRecordPolicy.record(
                      messageID: messageID,
                      conversationID: conversationId,
                      attachmentID: mediaIdentity.id,
                      mediaType: mediaIdentity.type,
                      fileSize: mediaIdentity.size,
                      remoteStorageKey: mediaIdentity.remoteKey,
                      in: current.messages
                  )
            else { return false }
            return record.localStorageKind == .encryptedBlob
                && record.localStorageKey == storageKey
                && record.availabilityState != .remoteOnly
                && record.availabilityState != .unavailable
        }
        /// The cache and protected state are separate encrypted stores, so promotion is a
        /// verified two-phase checkpoint: first prove the exact plaintext is durably readable,
        /// then CAS the still-identical message projection and its media record in one state
        /// write. A crash between those steps can leave only a harmless cache entry; activation's
        /// age-gated orphan sweep eventually removes it and never removes a referenced key.
        func promoteVerifiedBlob(_ data: Data, storageKey: String) async throws {
            guard localRecord != nil,
                  let verified = await SecureMediaFileCache.shared.data(
                      forStorageKey: storageKey,
                      userID: userID
                  ), verified == data
            else { throw SecureMediaAttachmentError.invalidCiphertext }
            try await store.update { persisted in
                guard persisted.profile?.id == userID,
                      SecureMediaLoadPolicy.resolve(
                          messageID: messageID,
                          conversationId: conversationId,
                          itemIndex: itemIndex,
                          in: persisted.messages
                      ) == resolved
                else { throw SecureMediaAttachmentError.invalidDescriptor }
                let indices = persisted.messages.indices.filter {
                    persisted.messages[$0].id == messageID
                        && persisted.messages[$0].conversationId == conversationId
                }
                guard indices.count == 1, let index = indices.first,
                      LocalMediaRecordPolicy.markDownloaded(
                          &persisted.messages[index],
                          attachmentID: mediaIdentity.id,
                          storageKey: storageKey
                      )
                else { throw SecureMediaAttachmentError.invalidDescriptor }
            }
            await publishLatestState()
            guard await currentResolution() == resolved else {
                throw SecureMediaAttachmentError.invalidDescriptor
            }
        }
        if let localRecord,
           localRecord.localStorageKind == .protectedFile,
           let localStorageKey = localRecord.localStorageKey,
           let accessLease = await SecureMediaFileCache.shared.protectedOriginalLease(
               forStorageKey: localStorageKey,
               userID: userID,
               expectedByteCount: mediaIdentity.size
           ),
           await currentResolution() == resolved {
            if localRecord.duration == nil,
               !(localRecord.direction == .received
                   && KitChatMediaKind(mediaType: mediaIdentity.type) == .video),
               let mediaID = UUID(uuidString: mediaIdentity.id) {
                scheduleLocalMediaDuration(
                    mediaID: mediaID,
                    fileURL: accessLease.fileURL,
                    mediaType: mediaIdentity.type
                )
            }
            let localFile = SecureMediaLoadPolicy.LocalFileItem(
                url: accessLease.fileURL,
                mediaType: mediaIdentity.type,
                caption: {
                    switch resolved {
                    case .pendingSingle(let pending): return pending.caption
                    case .single(let descriptor, _, _): return descriptor.caption
                    case .pendingBatchItem, .sealedBatchItem: return nil
                    }
                }(),
                byteCount: mediaIdentity.size,
                attachmentID: mediaIdentity.id,
                accessLease: accessLease
            )
            // Images use the protected file too. ImageIO can downsample directly from the URL;
            // materializing a potentially 200 MiB compressed original into Data first provides
            // no additional integrity (the protected-cache lease already verified identity) and
            // creates avoidable memory pressure.
            return SecureMediaLoadPolicy.LoadedItem(localFile: localFile)
        }
        if let localRecord,
           localRecord.direction == .received,
           localRecord.localStorageKind == .encryptedBlob,
           localRecord.availabilityState == .localCached,
           localRecord.downloadState == .downloaded,
           KitChatMediaKind(mediaType: mediaIdentity.type) == .video,
           let localStorageKey = localRecord.localStorageKey,
           let remoteStorageKey = mediaIdentity.remoteKey {
            let sessionID = await sessions.current()?.sessionId
            let migrationSource = LegacyReceivedVideoMigrationPolicy.source(
                plaintextByteCount: mediaIdentity.size,
                allowsDownload: allowsDownload,
                isOnline: isOnline,
                secureMessagingAvailable: secureMessagingAvailable,
                hasRemoteStorageKey: true,
                hasAuthenticatedSession: sessionID != nil
            )

            if migrationSource == .streamedRemote, let sessionID {
                var streamedStateCommitted = false
                do {
                    guard let capacityReservation = reserveReceivedMediaHydrationCapacity(
                        plaintextByteCount: mediaIdentity.size
                    ) else { throw SecureMediaAttachmentError.invalidCiphertext }
                    defer { receivedMediaHydrationReservations[capacityReservation] = nil }
                    let expectedAccountEpoch = accountEpoch
                    let hydrated = try await APIClientSessionBinding.$sessionID.withValue(
                        sessionID
                    ) {
                        try await SecureMessagingExchangeCoordinator.shared.hydrateMediaFile(
                            forUserID: userID,
                            conversationID: conversationId,
                            messageID: messageID,
                            itemIndex: itemIndex
                        )
                    }
                    guard expectedAccountEpoch == accountEpoch,
                          await outboxContextIsCurrent(
                              accountEpoch: expectedAccountEpoch,
                              userID: userID,
                              sessionID: sessionID
                          ),
                          hydrated.attachmentID == mediaIdentity.id,
                          hydrated.storageKey == remoteStorageKey,
                          hydrated.mediaType == mediaIdentity.type,
                          hydrated.plaintextByteSize == mediaIdentity.size
                    else { throw CancellationError() }
                    try await store.update { persisted in
                        guard persisted.profile?.id == userID,
                              SecureMediaLoadPolicy.resolve(
                                  messageID: messageID,
                                  conversationId: conversationId,
                                  itemIndex: itemIndex,
                                  in: persisted.messages
                              ) == resolved
                        else { throw SecureMediaAttachmentError.invalidDescriptor }
                        let indices = persisted.messages.indices.filter {
                            persisted.messages[$0].id == messageID
                                && persisted.messages[$0].conversationId == conversationId
                        }
                        guard indices.count == 1, let index = indices.first,
                              LocalMediaRecordPolicy.record(
                                  messageID: messageID,
                                  conversationID: conversationId,
                                  attachmentID: mediaIdentity.id,
                                  mediaType: mediaIdentity.type,
                                  fileSize: mediaIdentity.size,
                                  remoteStorageKey: mediaIdentity.remoteKey,
                                  in: persisted.messages
                              ) == localRecord,
                              LocalMediaRecordPolicy.markDownloadedProtectedFile(
                                  &persisted.messages[index],
                                  attachmentID: mediaIdentity.id,
                                  remoteStorageKey: remoteStorageKey,
                                  localStorageKey: hydrated.attachmentID
                              )
                        else { throw SecureMediaAttachmentError.invalidDescriptor }
                    }
                    streamedStateCommitted = true
                    guard await currentResolution() == resolved,
                          let accessLease = await SecureMediaFileCache.shared
                              .protectedOriginalLease(
                                  forStorageKey: hydrated.attachmentID,
                                  userID: userID,
                                  expectedByteCount: hydrated.plaintextByteSize
                              )
                    else { throw SecureMediaAttachmentError.invalidCiphertext }
                    await SecureMediaFileCache.shared.removeEncryptedBlobRepresentation(
                        forStorageKey: localStorageKey,
                        userID: userID
                    )
                    await publishLatestState()
                    await enforceReceivedMediaCacheBudget()
                    return SecureMediaLoadPolicy.LoadedItem(localFile: .init(
                        url: accessLease.fileURL,
                        mediaType: hydrated.mediaType,
                        caption: {
                            switch resolved {
                            case .pendingSingle(let pending): return pending.caption
                            case .single(let descriptor, _, _): return descriptor.caption
                            case .pendingBatchItem, .sealedBatchItem: return nil
                            }
                        }(),
                        byteCount: hydrated.plaintextByteSize,
                        attachmentID: hydrated.attachmentID,
                        accessLease: accessLease
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A small legacy blob remains a bounded offline fallback. Large videos never
                    // fall back to whole-file ChaChaPoly decryption after a streamed attempt.
                    guard !streamedStateCommitted,
                          KitChatMediaLimits.shouldCacheInline(
                        byteCount: mediaIdentity.size
                    ) else { throw error }
                }
            }

            guard KitChatMediaLimits.shouldCacheInline(byteCount: mediaIdentity.size) else {
                if !isOnline || !allowsDownload { throw URLError(.notConnectedToInternet) }
                throw SecureMediaAttachmentError.invalidCiphertext
            }
            // The bounded fallback exists only for old offline blobs small enough for the normal
            // inline cache policy. Larger videos must use authenticated streamed rehydration.
            guard let accessLease = try await SecureMediaFileCache.shared
                .promoteEncryptedBlobToProtectedOriginal(
                    forStorageKey: localStorageKey,
                    userID: userID,
                    mediaType: mediaIdentity.type,
                    expectedByteCount: mediaIdentity.size
                )
            else { throw SecureMediaAttachmentError.invalidCiphertext }
            try await store.update { persisted in
                guard persisted.profile?.id == userID,
                      SecureMediaLoadPolicy.resolve(
                          messageID: messageID,
                          conversationId: conversationId,
                          itemIndex: itemIndex,
                          in: persisted.messages
                      ) == resolved
                else { throw SecureMediaAttachmentError.invalidDescriptor }
                let indices = persisted.messages.indices.filter {
                    persisted.messages[$0].id == messageID
                        && persisted.messages[$0].conversationId == conversationId
                }
                guard indices.count == 1, let index = indices.first,
                      LocalMediaRecordPolicy.record(
                          messageID: messageID,
                          conversationID: conversationId,
                          attachmentID: mediaIdentity.id,
                          mediaType: mediaIdentity.type,
                          fileSize: mediaIdentity.size,
                          remoteStorageKey: mediaIdentity.remoteKey,
                          in: persisted.messages
                      ) == localRecord,
                      LocalMediaRecordPolicy.markDownloadedProtectedFile(
                          &persisted.messages[index],
                          attachmentID: mediaIdentity.id,
                          remoteStorageKey: remoteStorageKey,
                          localStorageKey: localStorageKey
                      )
                else { throw SecureMediaAttachmentError.invalidDescriptor }
            }
            guard await currentResolution() == resolved else {
                throw SecureMediaAttachmentError.invalidDescriptor
            }
            await SecureMediaFileCache.shared.removeEncryptedBlobRepresentation(
                forStorageKey: localStorageKey,
                userID: userID
            )
            await publishLatestState()
            return SecureMediaLoadPolicy.LoadedItem(localFile: .init(
                url: accessLease.fileURL,
                mediaType: mediaIdentity.type,
                caption: {
                    switch resolved {
                    case .pendingSingle(let pending): return pending.caption
                    case .single(let descriptor, _, _): return descriptor.caption
                    case .pendingBatchItem, .sealedBatchItem: return nil
                    }
                }(),
                byteCount: mediaIdentity.size,
                attachmentID: mediaIdentity.id,
                accessLease: accessLease
            ))
        }
        if !isReceivedVideo,
           let localRecord,
           localRecord.localStorageKind == .encryptedBlob,
           let localStorageKey = localRecord.localStorageKey,
           let local = await SecureMediaFileCache.shared.data(
               forStorageKey: localStorageKey,
               userID: userID
           ), local.count == mediaIdentity.size,
           await localRecordStillOwns(localStorageKey) {
            return SecureMediaLoadPolicy.LoadedItem(
                data: local,
                mediaType: mediaIdentity.type,
                caption: {
                    switch resolved {
                    case .pendingSingle(let pending): return pending.caption
                    case .single(let descriptor, _, _): return descriptor.caption
                    case .pendingBatchItem, .sealedBatchItem: return nil
                    }
                }()
            )
        }
        switch resolved {
        case .pendingSingle(let pending):
            guard !isReceivedVideo else {
                throw SecureMediaAttachmentError.invalidDescriptor
            }
            if let inline = pending.inlineData {
                return SecureMediaLoadPolicy.LoadedItem(
                    data: inline,
                    mediaType: pending.mediaType,
                    caption: pending.caption
                )
            }
            guard let key = pending.localStorageKey,
                  let expected = pending.expectedByteCount,
                  let original = await SecureMediaFileCache.shared.data(
                      forStorageKey: key,
                      userID: userID
                  ), original.count == expected,
                  await currentResolution() == resolved
            else { throw SecureMediaAttachmentError.invalidCiphertext }
            return SecureMediaLoadPolicy.LoadedItem(
                data: original,
                mediaType: pending.mediaType,
                caption: pending.caption
            )

        case .pendingBatchItem(let batch, _, let itemIndex):
            guard !isReceivedVideo else {
                throw SecureMediaAttachmentError.invalidDescriptor
            }
            let item = batch.items[itemIndex]
            for key in [item.localStorageKey, item.storageKey].compactMap({ $0 }) {
                if let cached = await SecureMediaFileCache.shared.data(
                    forStorageKey: key,
                    userID: userID
                ), cached.count == item.plaintextByteSize,
                   await currentResolution() == resolved {
                    return SecureMediaLoadPolicy.LoadedItem(
                        data: cached,
                        mediaType: item.mediaType,
                        caption: nil
                    )
                }
            }
            throw SecureMediaAttachmentError.invalidCiphertext

        case .sealedBatchItem(let descriptor, _, let itemIndex):
            let item = descriptor.items[itemIndex]
            if let recovered = try await recoverCachedReceivedVideoAsProtectedFile(
                storageKey: item.storageKey,
                caption: nil
            ) {
                return recovered
            }
            if !isReceivedVideo,
               let cached = await SecureMediaFileCache.shared.data(
                forStorageKey: item.storageKey,
                userID: userID
            ), cached.count == item.plaintextByteSize,
               await currentResolution() == resolved {
                try await promoteVerifiedBlob(cached, storageKey: item.storageKey)
                return SecureMediaLoadPolicy.LoadedItem(
                    data: cached,
                    mediaType: item.mediaType,
                    caption: nil
                )
            }
            guard allowsDownload, isOnline else { throw URLError(.notConnectedToInternet) }
            guard secureMessagingAvailable else {
                throw SecureMessagingExchangeError.invalidAccount
            }
            guard let file = await loadProtectedLocalMediaFile(
                messageID: messageID,
                conversationId: conversationId,
                itemIndex: itemIndex
            ), await currentResolution() == resolved
            else { throw SecureMediaAttachmentError.invalidCiphertext }
            return SecureMediaLoadPolicy.LoadedItem(localFile: file)

        case .single(let descriptor, let descriptorText, let inlineData):
            // The policy carries inline bytes only at the exact declared size, and they live on
            // the identity-resolved row itself — nothing suspends between resolution and here.
            if let inlineData,
               KitChatMediaKind(mediaType: descriptor.mediaType) == .video,
               !resolvedMessage.isOutgoing {
                // Received video bytes must never reach AVPlayer as a retained Data value. A
                // missing/mismatched local record means launch compaction could not authenticate
                // the state transition; fail closed instead of entering the historical
                // Data + decoder + whole-state rewrite crash path.
                guard let localRecord,
                      localRecord.direction == .received,
                      localRecord.localStorageKind == .encryptedState,
                      localRecord.localStorageKey == nil,
                      localRecord.remoteEncryptedObjectID == descriptor.storageKey,
                      localRecord.availabilityState == .localCached,
                      localRecord.downloadState == .downloaded
                else { throw SecureMediaAttachmentError.invalidDescriptor }
                // Legacy receivers kept the complete decrypted video inside the encrypted state
                // row. Returning that Data makes the player retain one whole movie while
                // AVFoundation allocates its own decoder buffers, and every unrelated state
                // mutation (including wallet history) must rewrite the movie. Publish the exact
                // authenticated bytes as a protected file first, then atomically retire only the
                // still-identical inline row. The attachment id is the permanent local identity;
                // the remote storage key remains a server reference and never names this file.
                let localStorageKey = descriptor.attachmentID
                guard let accessLease = try await SecureMediaFileCache.shared
                    .promoteInlineDataToProtectedOriginal(
                        inlineData,
                        forStorageKey: localStorageKey,
                        userID: userID,
                        mediaType: descriptor.mediaType,
                        expectedByteCount: descriptor.plaintextByteSize
                    )
                else { throw SecureMediaAttachmentError.invalidCiphertext }
                try await store.update { persisted in
                    guard persisted.profile?.id == userID,
                          case .single(
                              let currentDescriptor,
                              let currentDescriptorText,
                              let currentInlineData
                          )? = SecureMediaLoadPolicy.resolve(
                              messageID: messageID,
                              conversationId: conversationId,
                              itemIndex: itemIndex,
                              in: persisted.messages
                          ),
                          currentDescriptor == descriptor,
                          currentDescriptorText == descriptorText,
                          currentInlineData == inlineData
                    else { throw SecureMediaAttachmentError.invalidDescriptor }
                    let indices = persisted.messages.indices.filter {
                        persisted.messages[$0].id == messageID
                            && persisted.messages[$0].conversationId == conversationId
                    }
                    guard indices.count == 1, let index = indices.first,
                          LocalMediaRecordPolicy.record(
                              messageID: messageID,
                              conversationID: conversationId,
                              attachmentID: descriptor.attachmentID,
                              mediaType: descriptor.mediaType,
                              fileSize: descriptor.plaintextByteSize,
                              remoteStorageKey: descriptor.storageKey,
                              in: persisted.messages
                          ) == localRecord,
                          LocalMediaRecordPolicy.promoteInlineReceivedToProtectedFile(
                              &persisted.messages[index],
                              attachmentID: descriptor.attachmentID,
                              remoteStorageKey: descriptor.storageKey,
                              localStorageKey: localStorageKey,
                              expectedInlineData: inlineData
                          )
                    else { throw SecureMediaAttachmentError.invalidDescriptor }
                }
                await publishLatestState()
                let current = await store.snapshot()
                guard current.profile?.id == userID,
                      case .single(
                          let currentDescriptor,
                          let currentDescriptorText,
                          let currentInlineData
                      )? = SecureMediaLoadPolicy.resolve(
                          messageID: messageID,
                          conversationId: conversationId,
                          itemIndex: itemIndex,
                          in: current.messages
                      ),
                      currentDescriptor == descriptor,
                      currentDescriptorText == descriptorText,
                      currentInlineData == nil,
                      let promotedRecord = LocalMediaRecordPolicy.record(
                          messageID: messageID,
                          conversationID: conversationId,
                          attachmentID: descriptor.attachmentID,
                          mediaType: descriptor.mediaType,
                          fileSize: descriptor.plaintextByteSize,
                          remoteStorageKey: descriptor.storageKey,
                          in: current.messages
                      ),
                      promotedRecord.localStorageKind == .protectedFile,
                      promotedRecord.localStorageKey == localStorageKey
                else { throw SecureMediaAttachmentError.invalidDescriptor }
                return SecureMediaLoadPolicy.LoadedItem(localFile: .init(
                    url: accessLease.fileURL,
                    mediaType: descriptor.mediaType,
                    caption: descriptor.caption,
                    byteCount: descriptor.plaintextByteSize,
                    attachmentID: descriptor.attachmentID,
                    accessLease: accessLease
                ))
            }
            if let inlineData {
                return SecureMediaLoadPolicy.LoadedItem(
                    data: inlineData,
                    mediaType: descriptor.mediaType,
                    caption: descriptor.caption
                )
            }
            // The v1 row's body is the identity that matters; its inline slot may be filled
            // concurrently (by this very method in another task), so revalidation compares the
            // current body rather than the whole resolved shape.
            func bodyIsCurrent() async -> Bool {
                if case .single(_, let currentText, _)? = await currentResolution() {
                    return currentText == descriptorText
                }
                return false
            }
            if let recovered = try await recoverCachedReceivedVideoAsProtectedFile(
                storageKey: descriptor.storageKey,
                caption: descriptor.caption
            ) {
                return recovered
            }
            if !isReceivedVideo,
               let cached = await SecureMediaFileCache.shared.data(
                forStorageKey: descriptor.storageKey,
                userID: userID
            ), cached.count == descriptor.plaintextByteSize,
               await bodyIsCurrent() {
                try await promoteVerifiedBlob(cached, storageKey: descriptor.storageKey)
                return SecureMediaLoadPolicy.LoadedItem(
                    data: cached,
                    mediaType: descriptor.mediaType,
                    caption: descriptor.caption
                )
            }
            guard allowsDownload, isOnline else { throw URLError(.notConnectedToInternet) }
            guard secureMessagingAvailable else {
                throw SecureMessagingExchangeError.invalidAccount
            }
            guard let file = await loadProtectedLocalMediaFile(
                messageID: messageID,
                conversationId: conversationId,
                itemIndex: nil
            ), await bodyIsCurrent()
            else { throw SecureMediaAttachmentError.invalidCiphertext }
            return SecureMediaLoadPolicy.LoadedItem(localFile: file)
        }
    }

    /// A new direct chat mints a durable UUIDv4 locally only under the backend's exact
    /// idempotent-create capability; otherwise it retains the legacy authenticated server-create
    /// path. Both paths commit the bubble and protected outbox before activation or roster work.
    /// Never recreate the old `direct:<user-id>` placeholder.
    @discardableResult
    func queueDirectMessage(
        recipientId: String,
        title: String,
        body: String,
        clientMessageID: UUID? = nil
    ) async -> Bool {
        let result = await queueDirectMessageResult(
            recipientId: recipientId,
            title: title,
            body: body,
            clientMessageID: clientMessageID
        )
        return result != nil
    }

    /// Returns the exact conversation whose protected outbox projection is durable locally.
    /// New-chat UI uses this result to navigate only after the idempotent queue commit succeeds.
    func queueDirectMessageResult(
        recipientId: String,
        title: String,
        body: String,
        clientMessageID: UUID? = nil,
        textDiagnosticsProducerScope: LocalMediaDiagnosticProducerScope? = nil
    ) async -> SecureMessagingQueueResult? {
        await queueValidatedDirectMessageResult(
            recipientId: recipientId,
            title: title,
            body: body,
            clientMessageID: clientMessageID,
            trustedPaymentEvent: false,
            textDiagnosticsProducerScope: textDiagnosticsProducerScope
        )
    }

    private func queueDirectPaymentEvent(
        recipientId: String,
        title: String,
        body: String,
        clientMessageID: UUID
    ) async -> Bool {
        await queueValidatedDirectMessageResult(
            recipientId: recipientId,
            title: title,
            body: body,
            clientMessageID: clientMessageID,
            trustedPaymentEvent: true
        ) != nil
    }

    private func queueValidatedDirectMessageResult(
        recipientId: String,
        title: String,
        body: String,
        clientMessageID: UUID?,
        trustedPaymentEvent: Bool,
        textDiagnosticsProducerScope: LocalMediaDiagnosticProducerScope? = nil
    ) async -> SecureMessagingQueueResult? {
        let rawRecipientID = recipientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !AppReviewDemoMutationPolicy.peerIsReadOnly(
            rawRecipientID,
            isDemoActive: appReviewDemoIsActive
        )
        else {
            lastError = AppReviewDemoMutationPolicy.readOnlyMessage
            return nil
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trustedPaymentEvent {
            guard KitPaymentMessage.parse(trimmed) != nil else {
                lastError = "Kit Pay could not validate this payment event."
                return nil
            }
        } else if !SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(trimmed) {
            lastError = "Messages can't start with Kit Pay's reserved payment prefix."
            return nil
        }
        guard let recipientUUID = UUID(uuidString: rawRecipientID),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            lastError = "Choose a valid Kit Pay contact."
            return nil
        }
        let cleanRecipientID = recipientUUID.uuidString.lowercased()
        guard secureMessagingLocalQueueAvailable,
              let rawUserID = profile?.id,
              let userUUID = UUID(uuidString: rawUserID)
        else {
            lastError = messagingSendFailureMessage
            return nil
        }
        let userID = userUUID.uuidString.lowercased()
        let expectedAccountEpoch = accountEpoch
        guard let commitAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
            forAccountID: userID
        ), let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: expectedSessionID,
            commitAdmission: commitAdmission
        ) else { return nil }
        let existingConversation: Conversation?
        switch NewMessageComposerPolicy.directRoute(
            conversations: state.conversations,
            currentUserID: userID,
            recipientUserID: cleanRecipientID,
            privacyAllowsLocalQueue: communicationPrivacyAllowsLocalQueue(
                to: cleanRecipientID
            )
        ) {
        case .create:
            existingConversation = nil
        case .existing(let conversation):
            existingConversation = conversation
        case .blocked:
            lastError = "Unblock this account before starting a chat."
            return nil
        case .invalid:
            lastError = messagingSendFailureMessage
            return nil
        }
        let allowsProvisionalConversationCreation =
            messagingOfflineDirectCreationLocalQueueEnabled
        if existingConversation == nil, !allowsProvisionalConversationCreation {
            guard isOnline else {
                lastError = "Connect to the internet once to start this conversation."
                return nil
            }
            guard secureMessagingReleasePermitted else {
                lastError = messagingSendFailureMessage
                return nil
            }
            if let denial = communicationPrivacyDenialMessage(
                for: cleanRecipientID,
                blockedMessage: "Unblock this account before starting a chat."
            ) {
                lastError = denial
                return nil
            }
        }
        do {
            let result: SecureMessagingQueueResult
            result = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                accountGeneration: expectedAccountEpoch,
                sessionID: expectedSessionID,
                commitAdmission: commitAdmission
            ) {
                if let conversation = existingConversation {
                    return try await SecureMessagingExchangeCoordinator.shared.queueDeferredText(
                        forUserID: userID,
                        conversationID: conversation.id,
                        expectedRecipientUserID: cleanRecipientID,
                        title: title,
                        text: trimmed,
                        clientMessageID: clientMessageID,
                        commitAdmission: commitAdmission
                    )
                }
                return try await SecureMessagingExchangeCoordinator.shared.queueDirectText(
                    forUserID: userID,
                    recipientUserID: cleanRecipientID,
                    title: title,
                    text: trimmed,
                    clientMessageID: clientMessageID,
                    allowsProvisionalConversationCreation:
                        allowsProvisionalConversationCreation,
                    commitAdmission: commitAdmission
                )
            }
            if !trustedPaymentEvent {
                LocalMediaPerformanceMonitor.shared.markTextOutboxCommitted(
                    messageID: result.clientMessageID,
                    producerScope: textDiagnosticsProducerScope
                )
            }
            guard await reloadOutboxStateIfCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return nil }
            scheduleOutboxWake()
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return nil }
            return result
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Creates a server-authoritative group thread and returns its conversation id, or nil with
    /// `lastError` set. Fail-closed: requires the advertised `messaging_groups` capability, an
    /// online session, and 1...31 unique Kit Pay members besides the creator.
    func createGroupConversation(name: String, memberUserIDs: [String]) async -> String? {
        guard !rejectAppReviewDemoMutation() else { return nil }
        let cleanName = MessagingGroupTitlePolicy.normalized(name)
        guard messagingGroupsEnabled, isOnline else {
            lastError = messagingSendFailureMessage
            return nil
        }
        guard MessagingGroupTitlePolicy.isValid(cleanName) else {
            lastError = "Use 1 to 64 Unicode characters and no more than 120 UTF-8 bytes for the group name."
            return nil
        }
        guard let userID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else {
            lastError = messagingSendFailureMessage
            return nil
        }
        let localID = userID.lowercased()
        var seenMembers: Set<String> = []
        var members: [String] = []
        for raw in memberUserIDs {
            guard let uuid = UUID(
                uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                lastError = "Choose valid Kit Pay contacts for this group."
                return nil
            }
            let member = uuid.uuidString.lowercased()
            guard member != localID else { continue }
            if seenMembers.insert(member).inserted {
                members.append(member)
            }
        }
        guard (1 ... SecureMessagingWire.maximumGroupMembers - 1).contains(members.count) else {
            lastError = "Groups need 1 to 31 other people."
            return nil
        }
        guard members.allSatisfy({ communicationPrivacyAllowsOutbound(to: $0) }) else {
            lastError = "Remove blocked contacts, or refresh communication privacy, before creating this group."
            return nil
        }
        let expectedAccountEpoch = accountEpoch
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: expectedSessionID
        ) else { return nil }
        guard members.allSatisfy({ communicationPrivacyAllowsOutbound(to: $0) }) else {
            lastError = "Remove blocked contacts, or refresh communication privacy, before creating this group."
            return nil
        }
        guard messagingGroupsEnabled else {
            lastError = "Group messaging is not available right now."
            return nil
        }
        do {
            let conversation = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await SecureMessagingExchangeCoordinator.shared.createGroupConversation(
                    forUserID: userID,
                    memberUserIDs: members,
                    title: cleanName
                )
            }
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return nil }
            await publishLatestState()
            return conversation.id
        } catch is CancellationError {
            return nil
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    func canRenameGroupConversation(_ conversationID: String) -> Bool {
        guard messagingGroupsEnabled,
              let conversation = currentGroupConversation(conversationID),
              let role = conversation.groupRole(for: profile?.id)
        else { return false }
        return role.canManageGroup
    }

    func canAddGroupConversationMember(_ conversationID: String) -> Bool {
        guard canRenameGroupConversation(conversationID),
              let conversation = currentGroupConversation(conversationID)
        else { return false }
        return conversation.participantUserIds.count < SecureMessagingWire.maximumGroupMembers
    }

    /// Removal remains available with `messaging_groups` dark: it is the safety path for an
    /// administrator to eject a member whose incompatible device blocks encrypted group sends.
    func canRemoveGroupConversationMember(
        _ memberUserID: String,
        from conversationID: String
    ) -> Bool {
        guard secureMessagingAvailable,
              let conversation = currentGroupConversation(conversationID),
              let localUserID = profile?.id.lowercased(),
              memberUserID.lowercased() != localUserID,
              let actorRole = conversation.groupRole(for: localUserID),
              let targetRole = conversation.groupRole(for: memberUserID)
        else { return false }
        return actorRole.canRemove(targetRole)
    }

    /// Every active member may leave even if rollout has been withdrawn or another member's
    /// device cannot attest the group protocol.
    func canLeaveGroupConversation(_ conversationID: String) -> Bool {
        guard secureMessagingAvailable,
              let conversation = currentGroupConversation(conversationID),
              let localUserID = profile?.id.lowercased()
        else { return false }
        return conversation.participantUserIds.contains(localUserID)
    }

    @discardableResult
    func renameGroupConversation(_ conversationID: String, title: String) async -> Bool {
        let cleanTitle = MessagingGroupTitlePolicy.normalized(title)
        guard canRenameGroupConversation(conversationID),
              MessagingGroupTitlePolicy.isValid(cleanTitle)
        else {
            lastError = "You cannot rename this group right now."
            return false
        }
        return await performGroupMutation(conversationID: conversationID) {
            try await SecureMessagingExchangeCoordinator.shared.renameGroupConversation(
                forUserID: $0,
                conversationID: conversationID,
                title: cleanTitle
            )
        }
    }

    /// Description and photo share the rename admission: manager role behind the groups gate.
    func canEditGroupConversationIdentity(_ conversationID: String) -> Bool {
        canRenameGroupConversation(conversationID)
    }

    @discardableResult
    func updateGroupConversationDescription(
        _ conversationID: String,
        description rawDescription: String?
    ) async -> Bool {
        let description = rawDescription
            .map(MessagingGroupDescriptionPolicy.normalized)
            .flatMap { $0.isEmpty ? nil : $0 }
        guard canEditGroupConversationIdentity(conversationID),
              description.map(MessagingGroupDescriptionPolicy.isValid) ?? true
        else {
            lastError = "You cannot change this group's description right now."
            return false
        }
        return await performGroupMutation(conversationID: conversationID) {
            try await SecureMessagingExchangeCoordinator.shared
                .updateGroupConversationDescription(
                    forUserID: $0,
                    conversationID: conversationID,
                    description: description
                )
        }
    }

    /// Runs the moderated avatar pipeline (upload, scan, sanitize) on the prepared JPEG and
    /// then asks the server to make the clean asset this group's photo.
    @discardableResult
    func updateGroupConversationPhoto(
        _ conversationID: String,
        jpegData: Data
    ) async -> Bool {
        guard canEditGroupConversationIdentity(conversationID), !jpegData.isEmpty else {
            lastError = "You cannot change this group's photo right now."
            return false
        }
        let assetID: String
        do {
            assetID = try await api.prepareGroupPhotoAsset(jpegData: jpegData)
        } catch is CancellationError {
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
        return await performGroupMutation(conversationID: conversationID) {
            try await SecureMessagingExchangeCoordinator.shared.attachGroupConversationPhoto(
                forUserID: $0,
                conversationID: conversationID,
                assetID: assetID
            )
        }
    }

    @discardableResult
    func removeGroupConversationPhoto(_ conversationID: String) async -> Bool {
        guard canEditGroupConversationIdentity(conversationID) else {
            lastError = "You cannot change this group's photo right now."
            return false
        }
        return await performGroupMutation(conversationID: conversationID) {
            try await SecureMessagingExchangeCoordinator.shared.removeGroupConversationPhoto(
                forUserID: $0,
                conversationID: conversationID
            )
        }
    }

    @discardableResult
    func addGroupConversationMember(
        _ memberUserID: String,
        to conversationID: String
    ) async -> Bool {
        guard canAddGroupConversationMember(conversationID),
              let memberUUID = UUID(
                  uuidString: memberUserID.trimmingCharacters(in: .whitespacesAndNewlines)
              )
        else {
            lastError = "You cannot add someone to this group right now."
            return false
        }
        let member = memberUUID.uuidString.lowercased()
        guard communicationPrivacyAllowsOutbound(to: member) else {
            lastError = "Unblock this account before adding them to the group."
            return false
        }
        return await performGroupMutation(conversationID: conversationID) {
            try await SecureMessagingExchangeCoordinator.shared.addGroupConversationMember(
                forUserID: $0,
                conversationID: conversationID,
                memberUserID: member
            )
        }
    }

    @discardableResult
    func removeGroupConversationMember(
        _ memberUserID: String,
        from conversationID: String
    ) async -> Bool {
        guard canRemoveGroupConversationMember(memberUserID, from: conversationID) else {
            lastError = "You cannot remove this group member."
            return false
        }
        return await performGroupMutation(conversationID: conversationID) {
            try await SecureMessagingExchangeCoordinator.shared.removeGroupConversationMember(
                forUserID: $0,
                conversationID: conversationID,
                memberUserID: memberUserID
            )
        }
    }

    @discardableResult
    func leaveGroupConversation(_ conversationID: String) async -> Bool {
        guard canLeaveGroupConversation(conversationID), let localUserID = profile?.id else {
            lastError = "You cannot leave this group right now."
            return false
        }
        return await performGroupMutation(conversationID: conversationID) { userID in
            try await SecureMessagingExchangeCoordinator.shared.removeGroupConversationMember(
                forUserID: userID,
                conversationID: conversationID,
                memberUserID: localUserID
            )
        }
    }

    private func currentGroupConversation(_ rawConversationID: String) -> Conversation? {
        guard let conversationID = OutboxPolicy.canonicalConversationID(rawConversationID),
              !isReadOnlyAppReviewDemoConversation(conversationID)
        else { return nil }
        let matches = state.conversations.filter { $0.id == conversationID && $0.isGroup }
        return matches.count == 1 ? matches[0] : nil
    }

    private func performGroupMutation(
        conversationID: String,
        operation: @escaping (String) async throws -> Conversation
    ) async -> Bool {
        guard isOnline,
              secureMessagingAvailable,
              currentGroupConversation(conversationID) != nil,
              let userID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else {
            lastError = messagingSendFailureMessage
            return false
        }
        let expectedAccountEpoch = accountEpoch
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: userID,
            sessionID: expectedSessionID
        ) else { return false }
        do {
            _ = try await APIClientSessionBinding.$sessionID.withValue(expectedSessionID) {
                try await operation(userID)
            }
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return false }
            await publishLatestState()
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    func markConversationRead(_ conversationID: String) async {
#if DEBUG && APP_STORE_SCREENSHOTS
        guard !AppStoreScreenshotFixture.isActive else { return }
#endif
        guard !isReadOnlyAppReviewDemoConversation(conversationID) else { return }
        // Only a message still in `.received` needs a receipt. Re-submitting the latest message
        // after it was already marked made the coordinator's strict single-candidate guard throw
        // "conversation no longer available" every time an up-to-date chat was reopened.
        let latestIncomingMessageID = state.messages
            .filter {
                $0.conversationId == conversationID
                    && !$0.isOutgoing
                    && $0.serverMessageId != nil
                    && $0.state == .received
            }
            .max(by: { $0.createdAt < $1.createdAt })?
            .serverMessageId
        guard secureMessagingAvailable,
              isOnline,
              let userID = profile?.id,
              let messageID = latestIncomingMessageID
        else { return }
        do {
            try await SecureMessagingExchangeCoordinator.shared.markConversationRead(
                conversationID: conversationID,
                throughServerMessageID: messageID,
                forUserID: userID
            )
            await publishLatestState()
        } catch is CancellationError {
            return
        } catch {
            // Read receipts are background bookkeeping: a failed or already-applied receipt is
            // retried on the next visit and must never interrupt the customer with an alert.
        }
    }

    /// Sent, delivered and read moments for a message this account sent.
    ///
    /// Returns the reason it could not be answered rather than an empty sheet, because "nobody has
    /// read this yet" and "we could not ask" look identical on screen and mean opposite things.
    func messageDeliveryInfo(
        conversationID: String,
        serverMessageID: String
    ) async -> Result<MessageDeliveryInfo, Error> {
        guard let userID = profile?.id else {
            return .failure(SecureMessagingExchangeError.invalidAccount)
        }
        guard secureMessagingAvailable, !isReadOnlyAppReviewDemoConversation(conversationID) else {
            return .failure(SecureMessagingExchangeError.invalidConversation)
        }
        do {
            let info = try await SecureMessagingExchangeCoordinator.shared.messageDeliveryInfo(
                conversationID: conversationID,
                serverMessageID: serverMessageID,
                forUserID: userID
            )
            return .success(info)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Conversation management (pin, mute, select, delete)

    func togglePinnedConversation(_ conversationID: String) async {
        guard !isReadOnlyAppReviewDemoConversation(conversationID) else { return }
        do {
            try await store.update { persisted in
                persisted.pinnedConversationIds = ConversationListPolicy.togglingMembership(
                    conversationID,
                    in: persisted.pinnedConversationIds
                )
            }
            await publishLatestState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleMutedConversation(_ conversationID: String) async {
        guard !isReadOnlyAppReviewDemoConversation(conversationID) else { return }
        do {
            try await store.update { persisted in
                persisted.mutedConversationIds = ConversationListPolicy.togglingMembership(
                    conversationID,
                    in: persisted.mutedConversationIds
                )
            }
            await publishLatestState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Marks chats read locally right away, then sends authenticated read receipts when online.
    func markConversationsRead(_ conversationIDs: Set<String>) async {
        let writableConversationIDs = conversationIDs.filter {
            !isReadOnlyAppReviewDemoConversation($0)
        }
        guard !writableConversationIDs.isEmpty else { return }
        do {
            try await store.update { persisted in
                for index in persisted.conversations.indices
                where writableConversationIDs.contains(persisted.conversations[index].id) {
                    persisted.conversations[index].unreadCount = 0
                }
            }
            await publishLatestState()
        } catch {
            lastError = error.localizedDescription
            return
        }
        guard isOnline, secureMessagingAvailable else { return }
        for conversationID in writableConversationIDs {
            await markConversationRead(conversationID)
        }
    }

    /// Deletes chats from this device only. Server copies stay end-to-end encrypted for the
    /// other participant; queued unsent messages for these chats are dropped from the outbox.
    func deleteConversationsLocally(_ conversationIDs: Set<String>) async {
        let writableConversationIDs = conversationIDs.filter {
            !isReadOnlyAppReviewDemoConversation($0)
        }
        guard !writableConversationIDs.isEmpty else { return }
        let userID = profile?.id
        var deletableKeys: [String] = []
        do {
            try await store.update { persisted in
                // Candidate keys span every media generation and phase of the doomed rows
                // (v1 park, sealed v1 key, v2 batch park/checkpoint keys, sealed v2 keys).
                // Which blobs may actually go is decided only after the rows are removed: a
                // corrupt or aliased projection can carry a canonical key another live message
                // still owns, so a blob is deleted solely when no surviving message — in any
                // conversation — still references it. Orphaning on uncertainty is recoverable
                // housekeeping; deleting a survivor's only plaintext is not.
                let candidateKeys = Set(
                    persisted.messages
                        .filter { writableConversationIDs.contains($0.conversationId) }
                        .flatMap(\.localMediaStorageKeys)
                ).union(
                    persisted.conversationDrafts?
                        .filter { writableConversationIDs.contains($0.key) }
                        .flatMap { $0.value.localMediaStorageKeys } ?? []
                )
                persisted.conversations.removeAll { writableConversationIDs.contains($0.id) }
                persisted.groupProjectionUpdatedAt =
                    persisted.groupProjectionUpdatedAt?.filter {
                        !writableConversationIDs.contains($0.key)
                    }
                persisted.messages.removeAll {
                    writableConversationIDs.contains($0.conversationId)
                }
                persisted.outbox.removeAll { command in
                    command.kind == .secureMessage
                        && command.conversationId.map(writableConversationIDs.contains) == true
                }
                persisted.pinnedConversationIds = persisted.pinnedConversationIds?
                    .filter { !writableConversationIDs.contains($0) }
                persisted.mutedConversationIds = persisted.mutedConversationIds?
                    .filter { !writableConversationIDs.contains($0) }
                persisted.conversationDrafts = persisted.conversationDrafts?.filter {
                    !writableConversationIDs.contains($0.key)
                }
                let survivorKeys = Set(persisted.messages.flatMap(\.localMediaStorageKeys))
                    .union(
                        persisted.conversationDrafts?.values
                            .flatMap(\.localMediaStorageKeys) ?? []
                    )
                deletableKeys = candidateKeys.subtracting(survivorKeys).sorted()
            }
            await publishLatestState()
            if let userID {
                for storageKey in deletableKeys {
                    await SecureMediaFileCache.shared.remove(
                        forStorageKey: storageKey,
                        userID: userID
                    )
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Deletes individual messages from this device only ("delete for me").
    func deleteMessagesLocally(_ messageIDs: Set<UUID>, conversationId: String) async {
        guard !messageIDs.isEmpty,
              !isReadOnlyAppReviewDemoConversation(conversationId)
        else { return }
        let userID = profile?.id
        var deletableKeys: [String] = []
        do {
            try await store.update { persisted in
                // Same candidate-then-survivor discipline as conversation deletion: collect
                // every key the doomed rows may hold media under, remove the rows, then delete
                // only blobs no surviving message anywhere still references. An aliased key in
                // a corrupt projection is orphaned, never pulled out from under its live owner.
                let candidateKeys = Set(
                    persisted.messages
                        .filter { messageIDs.contains($0.id) && $0.conversationId == conversationId }
                        .flatMap(\.localMediaStorageKeys)
                )
                persisted.messages.removeAll {
                    messageIDs.contains($0.id) && $0.conversationId == conversationId
                }
                persisted.outbox.removeAll { command in
                    command.kind == .secureMessage
                        && command.messageId.map(messageIDs.contains) == true
                }
                let survivorKeys = Set(persisted.messages.flatMap(\.localMediaStorageKeys))
                    .union(
                        persisted.conversationDrafts?.values
                            .flatMap(\.localMediaStorageKeys) ?? []
                    )
                deletableKeys = candidateKeys.subtracting(survivorKeys).sorted()
            }
            await publishLatestState()
            if let userID {
                for storageKey in deletableKeys {
                    await SecureMediaFileCache.shared.remove(
                        forStorageKey: storageKey,
                        userID: userID
                    )
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - End-to-end encrypted iCloud chat backups

    func setMessageBackupFrequency(_ frequency: MessageBackupFrequency) async {
        guard !isDeletingMessageBackup, appReviewDemoMutationsAllowed else { return }
        do {
            try await store.update { persisted in
                var preferences = persisted.messageBackupPreferences ?? .default
                preferences.frequency = frequency
                persisted.messageBackupPreferences = preferences
            }
            await publishLatestState()
            messageBackupOperationError = nil
            scheduleAutomaticMessageBackupRefresh()
            if frequency != .off {
                _ = await runAutomaticMessageBackupIfDue()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setMessageBackupIncludesMedia(_ includesMedia: Bool) async {
        guard !isDeletingMessageBackup, appReviewDemoMutationsAllowed else { return }
        do {
            try await store.update { persisted in
                var preferences = persisted.messageBackupPreferences ?? .default
                preferences.includesMedia = includesMedia
                persisted.messageBackupPreferences = preferences
            }
            await publishLatestState()
            scheduleAutomaticMessageBackupRefresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func backUpMessagesNow() async -> Bool {
        let succeeded = await performMessageBackup(
            automaticAttemptAt: nil,
            replacingUnreadable: false
        )
        scheduleAutomaticMessageBackupRefresh()
        return succeeded
    }

    /// Destructive recovery is deliberately separate from an ordinary backup. The settings UI
    /// exposes this only after upload proved an existing archive unreadable and the customer has
    /// confirmed that its ciphertext and key may be replaced.
    @discardableResult
    func replaceUnreadableMessageBackup() async -> Bool {
        guard messageBackupReplacementAvailable else { return false }
        let succeeded = await performMessageBackup(
            automaticAttemptAt: nil,
            replacingUnreadable: true
        )
        scheduleAutomaticMessageBackupRefresh()
        return succeeded
    }

    private func performMessageBackup(
        automaticAttemptAt: Date?,
        replacingUnreadable: Bool
    ) async -> Bool {
        guard !isBackingUpMessages,
              !isDeletingMessageBackup,
              !isRestoringMessages,
              appReviewDemoMutationsAllowed,
              isSignedIn,
              accountSetupStep == nil,
              let userID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return false }
        let expectedAccountEpoch = accountEpoch
        isBackingUpMessages = true
        defer { isBackingUpMessages = false }
        messageBackupOperationError = nil
        let payload = MessageBackupPayload.snapshot(
            of: state,
            userID: userID,
            deviceName: UIDevice.current.name,
            includesMedia: messageBackupPreferences.includesMedia
        )
        do {
            if let automaticAttemptAt {
                state = try await commitAuthenticatedMutation(
                    accountEpoch: expectedAccountEpoch,
                    userID: userID,
                    sessionID: expectedSessionID
                ) { persisted in
                    var preferences = persisted.messageBackupPreferences ?? .default
                    preferences.lastAutomaticBackupAttemptAt = automaticAttemptAt
                    // Pessimistic until the CloudKit save and authenticated local receipt both
                    // commit. A process kill mid-upload therefore observes a bounded retry,
                    // never an activation loop and never a false success.
                    preferences.lastAutomaticBackupSucceeded = false
                    persisted.messageBackupPreferences = preferences
                }
            }
            let summary: MessageBackupSummary
            if replacingUnreadable {
                summary = try await MessageBackupManager.shared.replaceUnreadableBackup(
                    with: payload
                )
            } else {
                summary = try await MessageBackupManager.shared.upload(payload)
            }
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) { persisted in
                var preferences = persisted.messageBackupPreferences ?? .default
                preferences.lastBackupAt = summary.createdAt
                preferences.lastBackupByteSize = summary.byteSize
                preferences.lastBackupMessageCount = summary.messageCount
                preferences.lastBackupGeneration = summary.generation
                preferences.lastBackupContentDigest = summary.contentDigest
                if let automaticAttemptAt {
                    preferences.lastAutomaticBackupAttemptAt = automaticAttemptAt
                    preferences.lastAutomaticBackupSucceeded = true
                }
                persisted.messageBackupPreferences = preferences
            }
            messageBackupReplacementAvailable = false
            messageBackupOperationError = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let automaticAttemptAt,
               await outboxContextIsCurrent(
                   accountEpoch: expectedAccountEpoch,
                   userID: userID,
                   sessionID: expectedSessionID
               ) {
                _ = try? await commitAuthenticatedMutation(
                    accountEpoch: expectedAccountEpoch,
                    userID: userID,
                    sessionID: expectedSessionID
                ) { persisted in
                    var preferences = persisted.messageBackupPreferences ?? .default
                    preferences.lastAutomaticBackupAttemptAt = automaticAttemptAt
                    preferences.lastAutomaticBackupSucceeded = false
                    persisted.messageBackupPreferences = preferences
                }
            }
            let message = error.localizedDescription
            messageBackupOperationError = message
            messageBackupReplacementAvailable =
                MessageBackupReplacementPolicy.mayOfferReplacement(after: error)
            if automaticAttemptAt == nil { lastError = message }
            return false
        }
    }

    /// Runs a due automatic backup opportunistically (app background, BG task, foreground sync).
    @discardableResult
    func runAutomaticMessageBackupIfDue() async -> MessageBackupAutomaticRunResult {
        defer { scheduleAutomaticMessageBackupRefresh() }
        guard isSignedIn,
              appReviewDemoMutationsAllowed,
              accountSetupStep == nil,
              isOnline,
              !isBackingUpMessages,
              !state.messages.isEmpty,
              MessageBackupSchedulePolicy.isBackupDue(
                  frequency: messageBackupPreferences.frequency,
                  lastBackupAt: messageBackupPreferences.lastBackupAt,
                  lastAutomaticBackupAttemptAt:
                    messageBackupPreferences.lastAutomaticBackupAttemptAt,
                  lastAutomaticBackupSucceeded:
                    messageBackupPreferences.lastAutomaticBackupSucceeded
              )
        else { return .notDue }
        let result = await performMessageBackup(
            automaticAttemptAt: Date(),
            replacingUnreadable: false
        ) ? MessageBackupAutomaticRunResult.succeeded : .failed
        return result
    }

    var nextAutomaticMessageBackupAt: Date? {
        MessageBackupSchedulePolicy.nextAttemptDate(
            frequency: messageBackupPreferences.frequency,
            lastBackupAt: messageBackupPreferences.lastBackupAt,
            lastAutomaticBackupAttemptAt: messageBackupPreferences.lastAutomaticBackupAttemptAt,
            lastAutomaticBackupSucceeded: messageBackupPreferences.lastAutomaticBackupSucceeded
        )
    }

    func scheduleAutomaticMessageBackupRefresh(now: Date = Date()) {
        guard isSignedIn,
              accountSetupStep == nil,
              !state.messages.isEmpty,
              let nextAttempt = MessageBackupSchedulePolicy.nextAttemptDate(
                  frequency: messageBackupPreferences.frequency,
                  lastBackupAt: messageBackupPreferences.lastBackupAt,
                  lastAutomaticBackupAttemptAt:
                    messageBackupPreferences.lastAutomaticBackupAttemptAt,
                  lastAutomaticBackupSucceeded:
                    messageBackupPreferences.lastAutomaticBackupSucceeded,
                  now: now
              )
        else {
            MessageBackupRefreshScheduler.shared.cancel()
            messageBackupRefreshScheduleState = .inactive
            return
        }
        // Foreground activation handles anything already due. Give a background request a small
        // runway; iOS still owns the exact execution time.
        messageBackupRefreshScheduleState = MessageBackupRefreshScheduler.shared.schedule(
            earliestBeginDate: max(nextAttempt, now.addingTimeInterval(60))
        )
    }

    /// After sign-in on a device with no local history, offer to restore the iCloud backup.
    func checkForRestorableBackup() async {
        guard isSignedIn,
              appReviewDemoMutationsAllowed,
              !isDeletingMessageBackup,
              accountSetupStep == nil,
              state.messages.isEmpty,
              availableBackupToRestore == nil,
              let userID = profile?.id
        else { return }
        guard (try? MessageBackupKeyStore.existingKey(forUserID: userID)) != nil else { return }
        guard let summary = try? await MessageBackupManager.shared.latestBackupSummary(
            forUserID: userID
        ) else { return }
        guard isSignedIn, !isDeletingMessageBackup, profile?.id == userID else { return }
        availableBackupToRestore = summary
    }

    @discardableResult
    func restoreMessagesFromBackup() async -> Bool {
        guard !isRestoringMessages,
              !isDeletingMessageBackup,
              !isBackingUpMessages,
              appReviewDemoMutationsAllowed,
              isSignedIn,
              let userID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return false }
        let expectedAccountEpoch = accountEpoch
        isRestoringMessages = true
        defer { isRestoringMessages = false }
        do {
            let payload = try await MessageBackupManager.shared.downloadPayload(forUserID: userID)
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) { persisted in
                try MessageBackupRestorePolicy.merge(
                    payload,
                    into: &persisted,
                    currentUserID: userID
                )
            }
            availableBackupToRestore = nil
            messageBackupReplacementAvailable = false
            messageBackupOperationError = nil
            scheduleAutomaticMessageBackupRefresh()
            return true
        } catch is CancellationError {
            return false
        } catch {
            // A stale restore must never place a destructive recovery action into the account
            // that replaced it. Only typed failures produced while opening the remote archive
            // are eligible for the explicit replacement path; local store/session errors remain
            // ordinary failures.
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return false }
            let archiveError = MessageBackupReplacementPolicy.remoteRestoreError(error)
            let presented: Error = archiveError ?? error
            messageBackupOperationError = presented.localizedDescription
            messageBackupReplacementAvailable = archiveError.map {
                MessageBackupReplacementPolicy.mayOfferReplacement(after: $0)
            } ?? false
            lastError = presented.localizedDescription
            return false
        }
    }

    /// Deletes both the private CloudKit ciphertext and its synchronizable decryption key.
    /// Automatic backups are disabled so the user-controlled deletion is not immediately undone.
    @discardableResult
    func deleteMessageBackup() async -> Bool {
        guard !isDeletingMessageBackup,
              !isBackingUpMessages,
              !isRestoringMessages,
              appReviewDemoMutationsAllowed,
              isSignedIn,
              isOnline,
              let userID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return false }
        let expectedAccountEpoch = accountEpoch
        isDeletingMessageBackup = true
        defer { isDeletingMessageBackup = false }
        do {
            try await MessageBackupManager.shared.deleteBackup(forUserID: userID)
            try MessageBackupKeyStore.removeKey(forUserID: userID)
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) else { return true }
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: userID,
                sessionID: expectedSessionID
            ) { persisted in
                persisted.messageBackupPreferences = .default
            }
            availableBackupToRestore = nil
            messageBackupReplacementAvailable = false
            messageBackupOperationError = nil
            MessageBackupRefreshScheduler.shared.cancel()
            messageBackupRefreshScheduleState = .inactive
            return true
        } catch is CancellationError {
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func queueCall(
        recipientId: String,
        name: String,
        video: Bool
    ) async {
        let rawRecipientId = recipientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !AppReviewDemoMutationPolicy.peerIsReadOnly(
            rawRecipientId,
            isDemoActive: appReviewDemoIsActive
        )
        else {
            lastError = AppReviewDemoMutationPolicy.readOnlyMessage
            return
        }
        guard let recipientUUID = UUID(uuidString: rawRecipientId),
              !cleanName.isEmpty
        else {
            lastError = "Choose a Kit Pay contact to call."
            return
        }
        let cleanRecipientId = recipientUUID.uuidString.lowercased()
        let callCapabilityNeedsRecovery = capabilities == nil
            || (!callsFeatureEnabled
                && capabilities?.featureIsWithdrawn("calls") != true)
        if isOnline,
           (callCapabilityNeedsRecovery || !hasUsableCommunicationPrivacyProjection) {
            await retryCommunicationReadiness()
        }
        if let denial = communicationPrivacyDenialMessage(
            for: cleanRecipientId,
            blockedMessage: "Unblock this account before starting a call."
        ) {
            lastError = denial
            return
        }
        guard mayCreateCall else {
            lastError = "Calls are not available for this account."
            return
        }
        // A crash or a lost termination can leave a `ringing`/`active` record behind with nothing
        // in this process able to end it. Retire that residue first, so the refusal below can only
        // ever describe a call the user can actually see and hang up.
        await reapAbandonedCallRecords()
        guard ephemeralOutgoingCallGate.attempt == nil,
              CallMediaCoordinator.shared.activeCall == nil,
              !AbandonedCallRecordPolicy.blocksNewCall(
                state.calls,
                hostedCallIDs: hostedCallIDs()
              )
        else {
            lastError = "Finish or cancel the current call attempt before starting another."
            return
        }
        guard UIApplication.shared.applicationState == .active,
              let lease = callMediaAccountLease,
              lease.accountEpoch == accountEpoch,
              profile?.id.caseInsensitiveCompare(lease.userID) == .orderedSame
        else {
            lastError = "Open Kit Pay to start this call."
            return
        }
        do {
            try await CallMediaCoordinator.shared.preparePermissions(video: video)
        } catch {
            lastError = error.localizedDescription
            return
        }
        guard callMediaAccountLease == lease,
              await outboxContextIsCurrent(
                accountEpoch: lease.accountEpoch,
                userID: lease.userID,
                sessionID: lease.sessionID
              )
        else { return }

        let attempt = EphemeralOutgoingCallAttempt(
            clientCallID: UUID(),
            recipientUserID: cleanRecipientId,
            recipientName: cleanName,
            video: video,
            // Android starts every call through the global callable-user contract. Keeping this
            // unbound lets an established one-to-one call become a group call; chat timelines
            // still resolve the original peer deterministically from the authenticated roster.
            conversationID: nil,
            createdAt: Date(),
            lease: lease
        )
        guard ephemeralOutgoingCallGate.begin(attempt) else {
            lastError = "Finish or cancel the current call attempt before starting another."
            return
        }
        guard let ringDeadline = outgoingCallRingDeadlineGate.begin(attempt) else {
            _ = ephemeralOutgoingCallGate.cancel(
                clientCallID: attempt.clientCallIDString
            )
            lastError = "This call is unavailable right now."
            return
        }
        scheduleOutgoingCallRingDeadline(ringDeadline)
        // Cleared before the request goes out, so only an answer to the call this attempt
        // is about to place can ever be claimed by it.
        pendingCallAnswers.removeAll()
        let presentation = ActiveCallPresentation(
            id: attempt.clientCallIDString,
            conversationId: nil,
            participantName: cleanName,
            participantAvatarURL: callParticipantAvatarURL(
                for: [cleanRecipientId]
            ),
            participantVerification: contactVerification(forUserID: cleanRecipientId),
            video: video,
            direction: "outgoing"
        )
        guard CallMediaCoordinator.shared.presentPendingOutgoing(
            presentation,
            lease: lease
        ) else {
            _ = ephemeralOutgoingCallGate.cancel(
                clientCallID: attempt.clientCallIDString
            )
            cancelOutgoingCallRingDeadline(
                clientCallID: attempt.clientCallIDString,
                lease: attempt.lease
            )
            lastError = "Finish or cancel the current call attempt before starting another."
            return
        }
        lastError = nil
        resumeEphemeralOutgoingCallIfPossible()
    }

    private var callWaitingMediaState: CallWaitingMediaState {
        switch CallMediaCoordinator.shared.state {
        case .idle: .idle
        case .preparing: .preparing
        case .connecting: .connecting
        case .reconnecting: .reconnecting
        case .connected: .connected
        case .ending: .ending
        }
    }

    private func liveCallInvitationContext(
        for activeCall: ActiveCallPresentation?
    ) -> ActiveCallInvitationContext? {
        guard appReviewDemoMutationsAllowed,
              let activeCall,
              let coordinatorCall = CallMediaCoordinator.shared.activeCall,
              coordinatorCall.conversationId == nil,
              [.connected, .reconnecting].contains(CallMediaCoordinator.shared.state),
              let context = ActiveCallInvitationPolicy.context(
                  for: activeCall,
                  calls: state.calls,
                  currentUserID: profile?.id
              ),
              UUID(uuidString: coordinatorCall.id)?.uuidString.lowercased() == context.callID
        else { return nil }
        return context
    }

    private func routeAuthenticatedIncomingCall(
        _ incoming: AuthenticatedIncomingCall
    ) {
        guard appReviewDemoMutationsAllowed else { return }
        let route = CallWaitingRoutingPolicy.route(
            incoming: incoming,
            activeCallID: CallMediaCoordinator.shared.activeCall?.id,
            mediaState: callWaitingMediaState
        )
        switch route {
        case .primary, .currentCall:
            return
        case .decline:
            NotificationCoordinator.shared.requestDeclineIncomingCall(
                callId: incoming.record.id
            )
        case .waiting(let waiting):
            switch callWaitingState.retain(waiting) {
            case .retained, .refreshed:
                CallProgressSoundPlayer.shared.beginAuthenticatedCallWaiting(
                    callID: waiting.callID
                )
            case .occupied(let unretained):
                // Match Android's single waiting banner. CallKit has room for exactly one waiting
                // record, so a third simultaneous call is declined without disturbing either the
                // connected room or the first authenticated waiting caller.
                NotificationCoordinator.shared.requestDeclineIncomingCall(
                    callId: unretained.callID
                )
            }
        }
    }

    @discardableResult
    private func clearWaitingCallForLifecycle(callID: String) -> AuthenticatedWaitingCall? {
        guard let canonicalCallID = canonicalCallID(callID),
              callWaitingState.waitingCall?.callID == canonicalCallID
        else { return nil }
        cancelWaitingCallMergeOperation(for: canonicalCallID)
        // A CallKit-originated merge marks the UUID before AppModel creates its own operation.
        // Lifecycle cleanup must release that premark too.
        NotificationCoordinator.shared.finishWaitingCallMergeAttempt(callId: canonicalCallID)
        guard let removed = callWaitingState.clearForLifecycle(callID: callID) else {
            return nil
        }
        CallProgressSoundPlayer.shared.clearAuthenticatedCallWaiting(callID: removed.callID)
        return removed
    }

    @discardableResult
    private func clearAllCallWaitingState() -> AuthenticatedWaitingCall? {
        let waitingCallID = callWaitingState.waitingCall?.callID
        cancelWaitingCallMergeOperation()
        if let waitingCallID {
            NotificationCoordinator.shared.finishWaitingCallMergeAttempt(callId: waitingCallID)
        }
        guard let removed = callWaitingState.decline() else {
            callWaitingState = CallWaitingState()
            return nil
        }
        CallProgressSoundPlayer.shared.clearAuthenticatedCallWaiting(callID: removed.callID)
        callWaitingState = CallWaitingState()
        return removed
    }

    private func declineWaitingCallAfterActiveCallTermination() {
        guard appReviewDemoMutationsAllowed else {
            _ = clearAllCallWaitingState()
            return
        }
        guard let waiting = clearAllCallWaitingState() else { return }
        NotificationCoordinator.shared.requestDeclineIncomingCall(callId: waiting.callID)
    }

    private func handleRemoteCallMediaEndedWake(_ wake: RemoteCallMediaEndedWake) {
        if let lease = callMediaAccountLease {
            cancelOutgoingCallRingDeadline(
                backendCallID: wake.callId,
                lease: lease
            )
        }
        guard let endedCallID = canonicalCallID(wake.callId),
              let waiting = callWaitingState.waitingCall,
              waiting.callID != endedCallID
        else { return }
        declineWaitingCallAfterActiveCallTermination()
    }

    private func waitingCallMergeOperationIsCurrent(
        _ operationID: UUID,
        attempt: CallWaitingMergeAttempt
    ) -> Bool {
        waitingCallMergeOperationID == operationID
            && waitingCallMergeAttempt == attempt
            && waitingCallMergeOperationGate.isCurrent(operationID)
            && callWaitingState.mergeAttempt == attempt
            && callWaitingState.waitingCall?.callID == attempt.target.waitingCallID
            && callWaitingState.waitingCall?.initiatorUserID == attempt.target.recipientUserID
    }

    private func finishWaitingCallMergeOperationIfOwned(
        _ operationID: UUID,
        attempt: CallWaitingMergeAttempt
    ) {
        guard waitingCallMergeOperationID == operationID,
              waitingCallMergeAttempt == attempt
        else { return }
        waitingCallMergeOperationGate.invalidate(operationID)
        resolveWaitingCallMergeResultSignal(false, operationID: operationID)
        waitingCallMergeTask = nil
        waitingCallMergeOperationID = nil
        waitingCallMergeAttempt = nil
        NotificationCoordinator.shared.finishWaitingCallMergeAttempt(
            callId: attempt.target.waitingCallID
        )
        if callWaitingState.mergeAttempt == attempt,
           case .retainedForRetry(let waiting) = callWaitingState.completeMerge(
               attempt,
               result: .failure
           ) {
            resumeWaitingToneIfRetained(callID: waiting.callID)
        }
    }

    /// Invalidates authority before cancelling transport. The store mutation gate observes this
    /// synchronously, so a lifecycle clear that wins the race cannot accept a late roster response.
    private func cancelWaitingCallMergeOperation(for callID: String? = nil) {
        guard let operationID = waitingCallMergeOperationID,
              let attempt = waitingCallMergeAttempt
        else { return }
        if let callID,
           canonicalCallID(callID) != attempt.target.waitingCallID {
            return
        }
        waitingCallMergeOperationGate.invalidate(operationID)
        resolveWaitingCallMergeResultSignal(false, operationID: operationID)
        waitingCallMergeTask?.cancel()
        waitingCallMergeTask = nil
        waitingCallMergeOperationID = nil
        waitingCallMergeAttempt = nil
        NotificationCoordinator.shared.finishWaitingCallMergeAttempt(
            callId: attempt.target.waitingCallID
        )
    }

    private func resolveWaitingCallMergeResultSignal(
        _ result: Bool,
        operationID: UUID
    ) {
        guard let signal = waitingCallMergeResultSignal,
              signal.operationID == operationID
        else { return }
        waitingCallMergeResultSignal = nil
        signal.continuation.yield(result)
        signal.continuation.finish()
    }

    private func resumeWaitingToneIfRetained(callID: String? = nil) {
        guard !callWaitingState.isMerging,
              let waiting = callWaitingState.waitingCall,
              !waiting.ringDeadline.isExpired(),
              callID.map({ canonicalCallID($0) == waiting.callID }) ?? true
        else { return }
        CallProgressSoundPlayer.shared.beginAuthenticatedCallWaiting(callID: waiting.callID)
    }

    /// Consumes any matching authenticated notice still queued behind a restored CallKit action.
    /// Live delivery normally places the notice first; this recovery path also makes persisted
    /// replay ordering fail closed instead of trying to merge from display-only action metadata.
    private func ingestQueuedAuthenticatedIncomingCall(callID: String) async {
        guard let canonicalCallID = canonicalCallID(callID) else { return }
        while let index = queuedCallEvents.firstIndex(where: { event in
            guard case .incoming(let notice) = event else { return false }
            return self.canonicalCallID(notice.call.record.id) == canonicalCallID
        }) {
            guard case .incoming(let notice) = queuedCallEvents.remove(at: index) else { continue }
            await recordAuthenticatedIncomingCall(notice.call)
            NotificationCoordinator.shared.acknowledgeCallEvent(notice.eventId)
        }
    }

    private func authorizedCallInvitationContext(
        for activeCall: ActiveCallPresentation?
    ) -> ActiveCallInvitationContext? {
        guard isSignedIn,
              isOnline,
              accountSetupStep == nil,
              communicationAccessGranted,
              callsFeatureEnabled,
              let lease = callMediaAccountLease,
              lease.accountEpoch == accountEpoch,
              profile?.id.caseInsensitiveCompare(lease.userID) == .orderedSame,
              let context = liveCallInvitationContext(for: activeCall)
        else { return nil }
        return context
    }

    func canInviteParticipant(to activeCall: ActiveCallPresentation?) -> Bool {
        authorizedCallInvitationContext(for: activeCall)?.canInviteAnotherParticipant == true
    }

    func participantUserIDs(for activeCall: ActiveCallPresentation?) -> Set<String> {
        ActiveCallInvitationPolicy.context(
            for: activeCall,
            calls: state.calls,
            currentUserID: profile?.id
        )?.participantUserIDs ?? []
    }

    /// Adds one callable Kit Pay user to the authenticated call already owned by this account and
    /// refreshes the encrypted local call projection from the server response.
    @discardableResult
    func inviteParticipant(
        _ recipientUserID: String,
        to activeCall: ActiveCallPresentation
    ) async -> Bool {
        guard let context = authorizedCallInvitationContext(for: activeCall) else {
            lastError = "People can no longer be added to this call."
            return false
        }
        guard context.canInviteAnotherParticipant else {
            lastError = "This call already has the maximum number of participants."
            return false
        }
        guard let recipientID = ActiveCallInvitationPolicy.canonicalRecipientID(recipientUserID)
        else {
            lastError = "Choose a valid Kit Pay contact."
            return false
        }
        if let denial = communicationPrivacyDenialMessage(
            for: recipientID,
            blockedMessage: "Unblock this account before adding this person to a call."
        ) {
            lastError = denial
            return false
        }
        guard ActiveCallInvitationPolicy.canInvite(
            recipientUserID: recipientID,
            in: context
        ) else {
            lastError = "This person is already in the call."
            return false
        }
        guard let lease = callMediaAccountLease,
              await outboxContextIsCurrent(
                  accountEpoch: lease.accountEpoch,
                  userID: lease.userID,
                  sessionID: lease.sessionID
              )
        else {
            lastError = "People can no longer be added to this call."
            return false
        }
        let callID = context.callID

        do {
            let response = try await APIClientSessionBinding.$sessionID.withValue(
                lease.sessionID
            ) {
                try await api.inviteToCall(id: callID, recipientUserIds: [recipientID])
            }
            guard ActiveCallInvitationPolicy.accepts(
                      response: response,
                      expectedContext: context,
                      invitedRecipientID: recipientID,
                      currentUserID: lease.userID
                  ),
                  callMediaAccountLease == lease,
                  let currentContext = liveCallInvitationContext(for: activeCall),
                  currentContext.callID == callID,
                  ActiveCallInvitationPolicy.accepts(
                      response: response,
                      expectedContext: currentContext,
                      invitedRecipientID: recipientID,
                      currentUserID: lease.userID
                  ),
                  await outboxContextIsCurrent(
                    accountEpoch: lease.accountEpoch,
                    userID: lease.userID,
                    sessionID: lease.sessionID
                  )
            else {
                lastError = "Kit could not verify that this person joined the active call."
                return false
            }

            let mapped = mapCall(response)
            try await store.update { persisted in
                guard persisted.profile?.id.caseInsensitiveCompare(lease.userID) == .orderedSame,
                      persisted.communicationOwnerUserID?.caseInsensitiveCompare(lease.userID)
                        == .orderedSame,
                      let persistedContext = ActiveCallInvitationPolicy.context(
                          for: activeCall,
                          calls: persisted.calls,
                          currentUserID: lease.userID
                      ),
                      persistedContext.callID == callID,
                      ActiveCallInvitationPolicy.accepts(
                          response: response,
                          expectedContext: persistedContext,
                          invitedRecipientID: recipientID,
                          currentUserID: lease.userID
                      )
                else { throw StoreError.accountChanged }
                persisted.calls = CallLifecyclePolicy.merge(
                    remote: [mapped],
                    local: persisted.calls
                )
            }
            guard await outboxContextIsCurrent(
                accountEpoch: lease.accountEpoch,
                userID: lease.userID,
                sessionID: lease.sessionID
            ) else { return false }
            await publishLatestState()
            rebuildCallContacts()
            lastError = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            lastError = callInviteFailureMessage(error)
            return false
        }
    }

    /// Merge uses a stricter invitation contract than the ordinary people picker. A lost mutation
    /// response is reconciled exactly once against the same authenticated active call; success is
    /// published only when that read-back contains the exact waiting initiator in its live roster.
    private func inviteWaitingParticipant(
        _ attempt: CallWaitingMergeAttempt,
        operationID: UUID,
        to activeCall: ActiveCallPresentation
    ) async -> Bool {
        let operationGate = waitingCallMergeOperationGate
        guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt),
              let context = authorizedCallInvitationContext(for: activeCall),
              context.callID == attempt.target.activeCallID,
              context.canInviteAnotherParticipant,
              let recipientID = ActiveCallInvitationPolicy.canonicalRecipientID(
                  attempt.target.recipientUserID
              ),
              recipientID == attempt.target.recipientUserID,
              communicationPrivacyDenialMessage(
                  for: recipientID,
                  blockedMessage: "Unblock this account before adding this person to a call."
              ) == nil,
              ActiveCallInvitationPolicy.canInvite(
                recipientUserID: recipientID,
                in: context
              ),
              let lease = callMediaAccountLease,
              await outboxContextIsCurrent(
                accountEpoch: lease.accountEpoch,
                userID: lease.userID,
                sessionID: lease.sessionID
              ),
              waitingCallMergeOperationIsCurrent(operationID, attempt: attempt)
        else {
            if waitingCallMergeOperationIsCurrent(operationID, attempt: attempt) {
                lastError = "This caller could not be added to the current call."
            }
            return false
        }
        let callID = context.callID

        do {
            let response = try await APIClientSessionBinding.$sessionID.withValue(
                lease.sessionID
            ) {
                try Task.checkCancellation()
                // This closure runs immediately at the transport boundary. The lock-protected
                // token is safe to consult off MainActor and prevents a pre-dispatch cancellation.
                guard operationGate.isCurrent(operationID) else {
                    throw CancellationError()
                }
                return try await api.inviteToCall(id: callID, recipientUserIds: [recipientID])
            }
            guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt),
                  WaitingCallMergeInvitationReconciliationPolicy.accepts(
                      response: response,
                      expectedContext: context,
                      invitedRecipientID: recipientID,
                      currentUserID: lease.userID
            )
            else {
                lastError = "This caller could not be added yet. Please try again."
                return false
            }
            return await commitWaitingMergeRoster(
                response,
                activeCall: activeCall,
                callID: callID,
                recipientID: recipientID,
                lease: lease,
                attempt: attempt,
                operationID: operationID
            )
        } catch is CancellationError {
            return false
        } catch {
            guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt)
            else { return false }
            guard WaitingCallMergeInvitationReconciliationPolicy.shouldReconcile(after: error)
            else {
                lastError = callInviteFailureMessage(error)
                return false
            }
            return await reconcileWaitingMergeInvitation(
                activeCall: activeCall,
                callID: callID,
                recipientID: recipientID,
                lease: lease,
                attempt: attempt,
                operationID: operationID
            )
        }
    }

    private func reconcileWaitingMergeInvitation(
        activeCall: ActiveCallPresentation,
        callID: String,
        recipientID: String,
        lease: CallMediaAccountLease,
        attempt: CallWaitingMergeAttempt,
        operationID: UUID
    ) async -> Bool {
        let operationGate = waitingCallMergeOperationGate
        guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt),
              callMediaAccountLease == lease,
              let currentContext = liveCallInvitationContext(for: activeCall),
              currentContext.callID == callID,
              await outboxContextIsCurrent(
                accountEpoch: lease.accountEpoch,
                userID: lease.userID,
                sessionID: lease.sessionID
              ),
              waitingCallMergeOperationIsCurrent(operationID, attempt: attempt)
        else { return false }

        do {
            let response = try await APIClientSessionBinding.$sessionID.withValue(
                lease.sessionID
            ) {
                try Task.checkCancellation()
                guard operationGate.isCurrent(operationID) else {
                    throw CancellationError()
                }
                return try await api.call(id: callID)
            }
            guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt),
                  WaitingCallMergeInvitationReconciliationPolicy.accepts(
                      response: response,
                      expectedContext: currentContext,
                      invitedRecipientID: recipientID,
                      currentUserID: lease.userID
                  )
            else {
                lastError = "This caller could not be added yet. Please try again."
                return false
            }
            return await commitWaitingMergeRoster(
                response,
                activeCall: activeCall,
                callID: callID,
                recipientID: recipientID,
                lease: lease,
                attempt: attempt,
                operationID: operationID
            )
        } catch is CancellationError {
            return false
        } catch {
            guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt),
                  callMediaAccountLease == lease,
                  await outboxContextIsCurrent(
                    accountEpoch: lease.accountEpoch,
                    userID: lease.userID,
                    sessionID: lease.sessionID
                  ),
                  waitingCallMergeOperationIsCurrent(operationID, attempt: attempt)
            else { return false }
            lastError = "This caller could not be added yet. Please try again."
            return false
        }
    }

    private func commitWaitingMergeRoster(
        _ response: CallDTO,
        activeCall: ActiveCallPresentation,
        callID: String,
        recipientID: String,
        lease: CallMediaAccountLease,
        attempt: CallWaitingMergeAttempt,
        operationID: UUID
    ) async -> Bool {
        let operationGate = waitingCallMergeOperationGate
        guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt),
              let currentContext = liveCallInvitationContext(for: activeCall),
              currentContext.callID == callID,
              WaitingCallMergeInvitationReconciliationPolicy.accepts(
                  response: response,
                  expectedContext: currentContext,
                  invitedRecipientID: recipientID,
                  currentUserID: lease.userID
              ),
              callMediaAccountLease == lease,
              await outboxContextIsCurrent(
                accountEpoch: lease.accountEpoch,
                userID: lease.userID,
                sessionID: lease.sessionID
              ),
              waitingCallMergeOperationIsCurrent(operationID, attempt: attempt)
        else { return false }

        let mapped = mapCall(response)
        do {
            try await store.update { persisted in
                let committed = try operationGate.performIfCurrent(operationID) {
                    guard persisted.profile?.id.caseInsensitiveCompare(lease.userID) == .orderedSame,
                          persisted.communicationOwnerUserID?.caseInsensitiveCompare(lease.userID)
                            == .orderedSame,
                          let persistedContext = ActiveCallInvitationPolicy.context(
                              for: activeCall,
                              calls: persisted.calls,
                              currentUserID: lease.userID
                          ),
                          persistedContext.callID == callID,
                          WaitingCallMergeInvitationReconciliationPolicy.accepts(
                              response: response,
                              expectedContext: persistedContext,
                              invitedRecipientID: recipientID,
                              currentUserID: lease.userID
                          )
                    else { throw StoreError.accountChanged }
                    persisted.calls = CallLifecyclePolicy.merge(
                        remote: [mapped],
                        local: persisted.calls
                    )
                }
                guard committed else { throw CancellationError() }
            }
            guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt),
                  callMediaAccountLease == lease,
                  await outboxContextIsCurrent(
                    accountEpoch: lease.accountEpoch,
                    userID: lease.userID,
                    sessionID: lease.sessionID
                  ),
                  waitingCallMergeOperationIsCurrent(operationID, attempt: attempt)
            else { return false }
            let snapshot = await store.snapshot()
            guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt)
            else { return false }
            await publishLatestState()
            rebuildCallContacts()
            lastError = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt),
                  callMediaAccountLease == lease,
                  await outboxContextIsCurrent(
                    accountEpoch: lease.accountEpoch,
                    userID: lease.userID,
                    sessionID: lease.sessionID
                  ),
                  waitingCallMergeOperationIsCurrent(operationID, attempt: attempt)
            else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    /// Declines only the authenticated waiting call. The connected LiveKit room and its CallKit
    /// record remain untouched while the normal CallKit action owns durable backend replay.
    func declineWaitingCall() {
        guard appReviewDemoMutationsAllowed else {
            _ = clearAllCallWaitingState()
            lastError = AppReviewDemoMutationPolicy.readOnlyMessage
            return
        }
        guard let retained = callWaitingState.waitingCall else {
            cancelWaitingCallMergeOperation()
            return
        }
        cancelWaitingCallMergeOperation(for: retained.callID)
        NotificationCoordinator.shared.finishWaitingCallMergeAttempt(callId: retained.callID)
        guard let waiting = callWaitingState.decline() else { return }
        CallProgressSoundPlayer.shared.clearAuthenticatedCallWaiting(
            callID: waiting.callID
        )
        NotificationCoordinator.shared.requestDeclineIncomingCall(callId: waiting.callID)
    }

    /// Android-parity Merge is a signalling operation, not a second media connection: invite the
    /// authenticated waiting initiator into the connected room, then retire and decline their
    /// separate incoming call. The initiator must accept the fresh invitation before media joins.
    func mergeWaitingCall() async {
        guard appReviewDemoMutationsAllowed else {
            _ = clearAllCallWaitingState()
            lastError = AppReviewDemoMutationPolicy.readOnlyMessage
            return
        }
        let activeCall = CallMediaCoordinator.shared.activeCall
        switch callWaitingState.beginMerge(
            activeCallID: activeCall?.id,
            mediaState: callWaitingMediaState,
            calls: state.calls,
            currentUserID: profile?.id
        ) {
        case .denied(let denial):
            if denial == .waitingCallExpired,
               let expired = callWaitingState.expire() {
                CallProgressSoundPlayer.shared.clearAuthenticatedCallWaiting(
                    callID: expired.callID
                )
                NotificationCoordinator.shared.requestDeclineIncomingCall(
                    callId: expired.callID
                )
            } else if denial == .callerAlreadyParticipant,
                      let alreadyMerged = callWaitingState.decline() {
                await completeWaitingCallMerge(alreadyMerged)
                return
            }
            resumeWaitingToneIfRetained()
            lastError = callWaitingMergeFailureMessage(denial)

        case .begin(let attempt):
            cancelWaitingCallMergeOperation()
            let operationID = UUID()
            waitingCallMergeOperationGate.activate(operationID)
            waitingCallMergeOperationID = operationID
            waitingCallMergeAttempt = attempt
            NotificationCoordinator.shared.beginWaitingCallMergeAttempt(
                callId: attempt.target.waitingCallID
            )
            defer {
                finishWaitingCallMergeOperationIfOwned(operationID, attempt: attempt)
            }
            CallProgressSoundPlayer.shared.clearAuthenticatedCallWaiting(
                callID: attempt.target.waitingCallID
            )
            guard let activeCall,
                  activeCall.id.caseInsensitiveCompare(attempt.target.activeCallID)
                    == .orderedSame
            else {
                _ = callWaitingState.completeMerge(attempt, result: .failure)
                resumeWaitingToneIfRetained(callID: attempt.target.waitingCallID)
                lastError = callWaitingMergeFailureMessage(.mediaUnavailable)
                return
            }
            let resultChannel = AsyncStream.makeStream(
                of: Bool.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            waitingCallMergeResultSignal = WaitingCallMergeResultSignal(
                operationID: operationID,
                continuation: resultChannel.continuation
            )
            let inviteTask = Task { @MainActor [weak self] in
                guard let self,
                      self.waitingCallMergeOperationIsCurrent(
                          operationID,
                          attempt: attempt
                      )
                else {
                    self?.resolveWaitingCallMergeResultSignal(
                        false,
                        operationID: operationID
                    )
                    return false
                }
                let result = await self.inviteWaitingParticipant(
                    attempt,
                    operationID: operationID,
                    to: activeCall
                )
                self.resolveWaitingCallMergeResultSignal(
                    result,
                    operationID: operationID
                )
                return result
            }
            waitingCallMergeTask = inviteTask
            let operationGate = waitingCallMergeOperationGate
            let invited = await withTaskCancellationHandler {
                // Do not await the transport task directly. AsyncStream cancellation resumes this
                // iterator even if an underlying URLSession/store await is temporarily uncooperative.
                var iterator = resultChannel.stream.makeAsyncIterator()
                return await iterator.next() ?? false
            } onCancel: {
                // Cancellation must revoke store-commit authority synchronously. Transport
                // cancellation alone is advisory and a late response must not publish a roster.
                operationGate.invalidate(operationID)
                resultChannel.continuation.yield(false)
                resultChannel.continuation.finish()
                inviteTask.cancel()
                Task { @MainActor [weak self] in
                    self?.finishWaitingCallMergeOperationIfOwned(
                        operationID,
                        attempt: attempt
                    )
                }
            }
            guard waitingCallMergeOperationIsCurrent(operationID, attempt: attempt)
            else { return }
            waitingCallMergeTask = nil
            switch callWaitingState.completeMerge(
                attempt,
                result: invited && !Task.isCancelled ? .success : .failure
            ) {
            case .merged(let waiting):
                await completeWaitingCallMerge(waiting)
            case .retainedForRetry(let waiting):
                resumeWaitingToneIfRetained(callID: waiting.callID)
                if lastError == nil {
                    lastError = "This caller could not be added yet. Please try again."
                }
            case .stale:
                break
            }
        }
    }

    private func completeWaitingCallMerge(_ waiting: AuthenticatedWaitingCall) async {
        CallProgressSoundPlayer.shared.clearAuthenticatedCallWaiting(callID: waiting.callID)
        NotificationCoordinator.shared.reportWaitingCallMerged(callId: waiting.callID)
        // Keep the decline durable. A lost response or brief disconnect must not resurrect the
        // separate incoming call after its initiator has been invited into the current room.
        await terminateCall(id: waiting.callID, kind: .decline, reason: nil)
    }

    private func callWaitingMergeFailureMessage(_ denial: CallWaitingMergeDenial) -> String {
        switch denial {
        case .noWaitingCall:
            "There is no waiting call to merge."
        case .mergeInProgress:
            "This caller is already being added."
        case .waitingCallExpired:
            "This waiting call has ended."
        case .participantLimitReached:
            "This call already has the maximum number of participants."
        case .conversationBound:
            "This call cannot add another person."
        case .callerAlreadyParticipant:
            "This caller is already in the call."
        case .mediaUnavailable, .invalidActiveCall, .sameCall, .activeCallNotFound,
             .ambiguousActiveCall, .activeCallNotActive, .invalidRoster:
            "This call can no longer be merged."
        }
    }

    private func callInviteFailureMessage(_ error: Error) -> String {
        guard let payload = error as? APIErrorPayload else {
            return "This person could not be added to the call. Check your connection and try again."
        }
        switch payload.code.uppercased() {
        case "CALL_PARTICIPANTS_UNCHANGED":
            return "This person is already in the call."
        case "CALL_FULL":
            return "This call already has the maximum number of participants."
        case "CALL_NOT_JOINABLE", "CALL_NOT_FOUND":
            return "People can no longer be added to this call."
        case "CALL_CONVERSATION_INVALID":
            return "This call is linked to its current chat, so another person cannot be added."
        default:
            return "This person could not be added to the call. Please try again."
        }
    }

    private func scheduleOutgoingCallRingDeadline(
        _ ticket: OutgoingCallRingDeadlineTicket
    ) {
        outgoingCallRingDeadlineTask?.cancel()
        outgoingCallRingDeadlineTask = Task { @MainActor [weak self] in
            let remaining = ticket.deadline.remaining()
            do {
                if remaining > 0 {
                    try await Task.sleep(for: .seconds(remaining))
                }
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.expireOutgoingCallRingDeadline(ticket)
        }
    }

    @discardableResult
    private func cancelOutgoingCallRingDeadline(
        clientCallID: String? = nil,
        backendCallID: String? = nil,
        lease: CallMediaAccountLease? = nil
    ) -> Bool {
        guard outgoingCallRingDeadlineGate.cancel(
            clientCallID: clientCallID,
            backendCallID: backendCallID,
            lease: lease
        ) else { return false }
        outgoingCallRingDeadlineTask?.cancel()
        outgoingCallRingDeadlineTask = nil
        return true
    }

    private func expireOutgoingCallRingDeadline(
        _ expected: OutgoingCallRingDeadlineTicket
    ) async {
        guard outgoingCallRingDeadlineGate.ticket == expected else { return }
        guard expected.deadline.isExpired() else {
            // Sleeping and the uptime clock are both monotonic, but tolerate an early wake without
            // consuming the only expiry decision or losing the timer.
            scheduleOutgoingCallRingDeadline(expected)
            return
        }

        let media = CallMediaCoordinator.shared
        let presentedCallID = media.activeCall?.id
        let matchingRecord = expected.backendCallID.flatMap { backendCallID in
            state.calls.first {
                $0.id.caseInsensitiveCompare(backendCallID) == .orderedSame
            }
        }
        let recordIsTerminal = matchingRecord.map {
            [.completed, .missed, .declined, .failed].contains($0.state)
        } ?? false
        let activeBackendCallID: String?
        if let presentedCallID,
           media.state != .idle,
           media.state != .ending,
           !recordIsTerminal,
           media.ownsAuthenticatedCall(callID: presentedCallID, lease: expected.lease) {
            activeBackendCallID = presentedCallID
        } else {
            activeBackendCallID = nil
        }
        let answerWon = media.presentedCallWasAnswered
            || media.media.hasRemoteParticipant
            || media.media.remoteParticipantConnectedAt != nil
            || matchingRecord?.state == .active
            || matchingRecord?.answeredAt != nil
        let answeredBackendCallID = answerWon ? activeBackendCallID : nil

        outgoingCallRingDeadlineTask = nil
        guard let expiration = outgoingCallRingDeadlineGate.consumeExpired(
            expected,
            activeClientCallID: ephemeralOutgoingCallGate.attempt?.clientCallIDString,
            activeBackendCallID: activeBackendCallID,
            activeLease: callMediaAccountLease,
            answeredBackendCallID: answeredBackendCallID
        ) else { return }

        switch expiration {
        case .cancelProvisional(let clientCallID, let lease):
            guard ephemeralOutgoingCallGate.attempt?.lease == lease else { return }
            cancelEphemeralOutgoingCall(
                clientCallID: clientCallID,
                dismissPresentation: true
            )
        case .endAuthenticated(let callID, let lease):
            // This exact-ID/lease operation enters the ordinary CallKit end path. Its fallback
            // publishes the same durable backend termination and tears media down directly.
            _ = media.requestEnd(callID: callID, lease: lease)
        }
    }

    private func reconcileOutgoingCallRingDeadlineAfterHistoryRefresh() {
        guard let ticket = outgoingCallRingDeadlineGate.ticket,
              let backendCallID = ticket.backendCallID,
              let record = state.calls.first(where: {
                  $0.id.caseInsensitiveCompare(backendCallID) == .orderedSame
              }),
              ![.queued, .ringing].contains(record.state)
        else { return }
        cancelOutgoingCallRingDeadline(
            backendCallID: backendCallID,
            lease: ticket.lease
        )
    }

    /// Resumes only the call that is still visible in this foreground process. Nothing from this
    /// path is written to the durable outbox, scheduled as background work, or restored at launch.
    private func resumeEphemeralOutgoingCallIfPossible() {
        guard let attempt = ephemeralOutgoingCallGate.attempt else { return }
        guard outgoingCallRingDeadlineGate.permitsSubmission(for: attempt) else {
            cancelEphemeralOutgoingCall(
                clientCallID: attempt.clientCallIDString,
                dismissPresentation: true
            )
            return
        }
        guard appReviewDemoMutationsAllowed,
              isOnline,
              !isSigningOut,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted,
              callsFeatureEnabled,
              UIApplication.shared.applicationState == .active,
              callMediaAccountLease == attempt.lease,
              accountEpoch == attempt.lease.accountEpoch,
              profile?.id.caseInsensitiveCompare(attempt.lease.userID) == .orderedSame
        else { return }
        guard ephemeralOutgoingCallTask == nil else {
            // Do not overlap two POSTs for the same idempotency key. A cancelled URLSession task
            // can still be delivering its response while connectivity/foreground state returns.
            ephemeralOutgoingCallResumePending = true
            return
        }

        ephemeralOutgoingCallResumePending = false
        let taskID = UUID()
        ephemeralOutgoingCallTaskID = taskID
        ephemeralOutgoingCallTask = Task { @MainActor [weak self] in
            await self?.runEphemeralOutgoingCall(taskID: taskID)
        }
    }

    /// Connectivity/background transitions invalidate any suspended HTTP response but retain the
    /// visible attempt in memory. Returning to the foreground starts a fresh idempotent submission
    /// with the same client call ID.
    private func suspendEphemeralOutgoingCallSubmission() {
        ephemeralOutgoingCallResumePending = false
        ephemeralOutgoingCallGate.suspendSubmission()
        ephemeralOutgoingCallTask?.cancel()
    }

    @discardableResult
    private func cancelEphemeralOutgoingCall(
        clientCallID: String? = nil,
        dismissPresentation: Bool
    ) -> EphemeralOutgoingCallAttempt? {
        guard let attempt = ephemeralOutgoingCallGate.cancel(
            clientCallID: clientCallID
        ) else { return nil }
        cancelOutgoingCallRingDeadline(
            clientCallID: attempt.clientCallIDString,
            lease: attempt.lease
        )
        ephemeralOutgoingCallResumePending = false
        ephemeralOutgoingCallTask?.cancel()
        if dismissPresentation {
            CallMediaCoordinator.shared.dismissPendingOutgoing(
                clientCallID: attempt.clientCallIDString,
                lease: attempt.lease
            )
        }
        if appReviewDemoMutationsAllowed {
            pendingEphemeralCallCancellations[attempt.clientCallIDString] = attempt
            scheduleEphemeralCallCancellationDrain()
        }
        return attempt
    }

    private func scheduleEphemeralCallCancellationDrain() {
        guard appReviewDemoMutationsAllowed,
              ephemeralCallCancellationTask == nil,
              isOnline,
              !pendingEphemeralCallCancellations.isEmpty
        else { return }
        ephemeralCallCancellationTask = Task { @MainActor [weak self] in
            await self?.drainEphemeralCallCancellations()
        }
    }

    /// Cancellation intents are process-only, just like the provisional call. The backend stores
    /// the authoritative tombstone so a racing/lost start response cannot ring after local cancel.
    private func drainEphemeralCallCancellations() async {
        defer { ephemeralCallCancellationTask = nil }
        var retryCounts: [String: Int] = [:]
        while !Task.isCancelled, appReviewDemoMutationsAllowed, isOnline,
              let attempt = pendingEphemeralCallCancellations.values.first {
            let identifier = attempt.clientCallIDString
            guard SessionRefreshPolicy.matchesSessionID(
                attempt.lease.sessionID,
                current: await sessions.current()?.sessionId ?? ""
            ) else {
                pendingEphemeralCallCancellations.removeValue(forKey: identifier)
                continue
            }
            do {
                let response = try await APIClientSessionBinding.$sessionID.withValue(
                    attempt.lease.sessionID
                ) {
                    try await api.cancelCallAttempt(clientCallId: identifier)
                }
                guard response.cancelled,
                      response.clientCallId.caseInsensitiveCompare(identifier) == .orderedSame
                else { throw APIClientError.invalidResponse }
                pendingEphemeralCallCancellations.removeValue(forKey: identifier)
                retryCounts.removeValue(forKey: identifier)
            } catch is CancellationError {
                return
            } catch {
                switch OutboxPolicy.failureDecision(for: error) {
                case .retry(let retryAfter):
                    let failureCount = (retryCounts[identifier] ?? 0) + 1
                    retryCounts[identifier] = failureCount
                    let delay = EphemeralOutgoingCallRetryPolicy.delay(
                        failureCount: failureCount,
                        retryAfter: retryAfter
                    )
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                case .unchanged:
                    return
                case .awaitSession, .awaitIdentityRefresh, .permanent:
                    pendingEphemeralCallCancellations.removeValue(forKey: identifier)
                }
            }
        }
    }

    private func cancelEphemeralCallOnServerOnce(
        _ attempt: EphemeralOutgoingCallAttempt
    ) async {
        guard appReviewDemoMutationsAllowed,
              isOnline,
              SessionRefreshPolicy.matchesSessionID(
                attempt.lease.sessionID,
                current: await sessions.current()?.sessionId ?? ""
              )
        else { return }
        let response = try? await APIClientSessionBinding.$sessionID.withValue(
            attempt.lease.sessionID
        ) {
            try await api.cancelCallAttempt(clientCallId: attempt.clientCallIDString)
        }
        if response?.cancelled == true,
           response?.clientCallId.caseInsensitiveCompare(attempt.clientCallIDString)
                == .orderedSame {
            pendingEphemeralCallCancellations.removeValue(
                forKey: attempt.clientCallIDString
            )
        }
    }

    private func runEphemeralOutgoingCall(taskID: UUID) async {
        defer {
            if ephemeralOutgoingCallTaskID == taskID {
                ephemeralOutgoingCallTaskID = nil
                ephemeralOutgoingCallTask = nil
                let shouldResume = ephemeralOutgoingCallResumePending
                ephemeralOutgoingCallResumePending = false
                if shouldResume {
                    resumeEphemeralOutgoingCallIfPossible()
                }
            }
        }

        while !Task.isCancelled {
            guard ephemeralOutgoingCallTaskID == taskID,
                  appReviewDemoMutationsAllowed,
                  let attempt = ephemeralOutgoingCallGate.attempt,
                  isOnline,
                  !isSigningOut,
                  isSignedIn,
                  accountSetupStep == nil,
                  communicationAccessGranted,
                  callsFeatureEnabled,
                  UIApplication.shared.applicationState == .active,
                  callMediaAccountLease == attempt.lease,
                  await outboxContextIsCurrent(
                    accountEpoch: attempt.lease.accountEpoch,
                    userID: attempt.lease.userID,
                    sessionID: attempt.lease.sessionID
                  )
            else {
                ephemeralOutgoingCallGate.suspendSubmission()
                return
            }
            guard outgoingCallRingDeadlineGate.permitsSubmission(for: attempt) else {
                cancelEphemeralOutgoingCall(
                    clientCallID: attempt.clientCallIDString,
                    dismissPresentation: true
                )
                return
            }
            guard let submission = ephemeralOutgoingCallGate.beginSubmission() else { return }

            do {
                let result = try await APIClientSessionBinding.$sessionID.withValue(
                    attempt.lease.sessionID
                ) {
                    try await api.startCall(
                        recipientUserIds: [attempt.recipientUserID],
                        video: attempt.video,
                        conversationId: attempt.conversationID,
                        clientCallId: attempt.clientCallIDString
                    )
                }
                await acceptEphemeralOutgoingCall(
                    result,
                    submission: submission,
                    taskID: taskID
                )
                return
            } catch is CancellationError {
                if ephemeralOutgoingCallGate.accepts(submission) {
                    ephemeralOutgoingCallGate.suspendSubmission()
                }
                return
            } catch {
                guard ephemeralOutgoingCallGate.accepts(submission) else { return }
                switch OutboxPolicy.failureDecision(for: error) {
                case .retry(let retryAfter):
                    guard let failureCount = ephemeralOutgoingCallGate
                        .finishRetryableFailure(submission)
                    else { return }
                    let delay = EphemeralOutgoingCallRetryPolicy.delay(
                        failureCount: failureCount,
                        retryAfter: retryAfter
                    )
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                case .awaitSession, .awaitIdentityRefresh, .unchanged:
                    ephemeralOutgoingCallGate.suspendSubmission()
                    return
                case .permanent:
                    cancelEphemeralOutgoingCall(
                        clientCallID: attempt.clientCallIDString,
                        dismissPresentation: true
                    )
                    lastError = ephemeralCallFailureMessage(error)
                    return
                }
            }
        }
    }

    private func acceptEphemeralOutgoingCall(
        _ result: CallSessionDTO,
        submission: EphemeralOutgoingCallAttemptGate.Submission,
        taskID: UUID
    ) async {
        let attempt = submission.attempt
        // Do not suspend before arbitrating the response against the ring deadline. Whichever
        // MainActor job runs first at the boundary must win atomically: a ringing response that is
        // already late is rejected, while an authenticated answer (or its exact buffered signal)
        // is promoted and claimed before the expiry task can tear it down. The account lease is
        // synchronously revoked before sign-out/account replacement performs any suspension.
        guard !Task.isCancelled,
              appReviewDemoMutationsAllowed,
              !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              isSignedIn,
              isOnline,
              accountSetupStep == nil,
              communicationAccessGranted,
              callsFeatureEnabled,
              UIApplication.shared.applicationState != .background,
              accountEpoch == attempt.lease.accountEpoch,
              profile?.id.caseInsensitiveCompare(attempt.lease.userID) == .orderedSame,
              callMediaAccountLease == attempt.lease,
              ephemeralOutgoingCallGate.accepts(submission)
                || ephemeralOutgoingCallGate.attempt == attempt
        else {
            cancelEphemeralOutgoingCall(
                clientCallID: attempt.clientCallIDString,
                dismissPresentation: true
            )
            await endLateAcceptedCall(result.call.id, lease: attempt.lease)
            return
        }

        let mapped = mapCall(result.call)
        let responseRecord = CallLifecyclePolicy.mergingStartResponse(
            mapped,
            with: state.calls.first {
                $0.id.caseInsensitiveCompare(mapped.id) == .orderedSame
            }
        )
        let responseDisposition = OutgoingCallStartResponsePolicy.disposition(
            for: responseRecord.state
        )
        guard responseDisposition != .terminal else {
            cancelEphemeralOutgoingCall(
                clientCallID: attempt.clientCallIDString,
                dismissPresentation: true
            )
            await endLateAcceptedCall(result.call.id, lease: attempt.lease)
            return
        }
        let handoff: CallMediaHandoff
        do {
            handoff = try CallMediaHandoff(
                session: result,
                participantAvatarURL: callParticipantAvatarURL(
                    for: responseRecord.participantUserIds,
                    identities: responseRecord.participantIdentities
                ),
                participantVerification: callParticipantVerification(
                    for: responseRecord.participantUserIds,
                    identities: responseRecord.participantIdentities
                )
            )
        } catch {
            cancelEphemeralOutgoingCall(
                clientCallID: attempt.clientCallIDString,
                dismissPresentation: true
            )
            await endLateAcceptedCall(result.call.id, lease: attempt.lease)
            lastError = "This call is unavailable right now."
            return
        }

        let request = AuthenticatedCallMediaHandoff(
            lease: attempt.lease,
            handoff: handoff
        )
        let responseAlreadyAnswered = responseDisposition == .answered
            || responseRecord.answeredAt != nil
            || pendingCallAnswers.contains {
                $0.callId.caseInsensitiveCompare(handoff.callId) == .orderedSame
            }
        guard let authenticatedRingDeadline = outgoingCallRingDeadlineGate.promote(
            clientCallID: attempt.clientCallIDString,
            lease: attempt.lease,
            backendCallID: result.call.id,
            ringExpiresAt: result.call.ringExpiresAt,
            serverTime: result.call.serverTime ?? result.serverTime,
            answerAlreadyAccepted: responseAlreadyAnswered
        ) else {
            cancelEphemeralOutgoingCall(
                clientCallID: attempt.clientCallIDString,
                dismissPresentation: true
            )
            await endLateAcceptedCall(result.call.id, lease: attempt.lease)
            return
        }
        scheduleOutgoingCallRingDeadline(authenticatedRingDeadline)
        let acceptedAttempt = ephemeralOutgoingCallGate.accepts(submission)
            ? ephemeralOutgoingCallGate.finishAccepted(submission)
            : ephemeralOutgoingCallGate.finishCurrentAttemptAccepted(attempt)
        guard acceptedAttempt != nil,
              CallMediaCoordinator.shared.promotePendingOutgoing(
                clientCallID: attempt.clientCallIDString,
                request: request
              )
        else {
            cancelOutgoingCallRingDeadline(
                clientCallID: attempt.clientCallIDString,
                backendCallID: result.call.id,
                lease: attempt.lease
            )
            CallMediaCoordinator.shared.dismissPendingOutgoing(
                clientCallID: attempt.clientCallIDString,
                lease: attempt.lease
            )
            await endLateAcceptedCall(result.call.id, lease: attempt.lease)
            return
        }
        // The response has just named the call, so an answer that overtook it on the socket
        // or the push can finally be matched and applied — before anything below spends time
        // between the pickup and this screen reflecting it.
        claimPendingCallAnswer(callId: result.call.id)
        if !CallMediaCoordinator.shared.presentedCallWasAnswered,
           responseAlreadyAnswered {
            // An idempotent retry can return a call that was answered while its first response was
            // lost. The authenticated response itself then wins the deadline race even if neither
            // the realtime frame nor its push fallback reached this process.
            handleCallAnswerSignal(
                callId: result.call.id,
                signal: CallAnswerSignalPolicy.signal(
                    callId: result.call.id,
                    answeredAt: result.call.answeredAt,
                    serverTime: result.call.serverTime ?? result.serverTime
                )
            )
        }
        if ephemeralOutgoingCallTaskID != taskID {
            // A response from the cancelled transport won the idempotent race. Fence the newer
            // request for this same client call ID; a duplicate response must not end this call.
            ephemeralOutgoingCallTask?.cancel()
            ephemeralOutgoingCallTask = nil
            ephemeralOutgoingCallTaskID = nil
        }

        // The synchronous lease/epoch fences above make response arbitration safe. Revalidate the
        // Keychain-backed session separately before this response is allowed to touch persistence.
        guard await outboxContextIsCurrent(
            accountEpoch: attempt.lease.accountEpoch,
            userID: attempt.lease.userID,
            sessionID: attempt.lease.sessionID
        ) else { return }

        do {
            try await store.update { persisted in
                guard persisted.profile?.id.caseInsensitiveCompare(attempt.lease.userID)
                        == .orderedSame,
                      persisted.communicationOwnerUserID?.caseInsensitiveCompare(
                        attempt.lease.userID
                      ) == .orderedSame
                else { throw StoreError.accountChanged }
                let existing = persisted.calls.first {
                    $0.id.caseInsensitiveCompare(mapped.id) == .orderedSame
                }
                let merged = CallLifecyclePolicy.mergingStartResponse(
                    mapped,
                    with: existing
                )
                let durable = CallLifecyclePolicy.preservingDurableContext(
                    in: merged,
                    from: existing,
                    fallbackConversationID: attempt.conversationID,
                    fallbackParticipantUserIDs: [attempt.recipientUserID],
                    fallbackName: attempt.recipientName
                )
                persisted.calls = CallLifecyclePolicy.merge(
                    remote: [durable],
                    local: persisted.calls
                )
            }
            guard await outboxContextIsCurrent(
                accountEpoch: attempt.lease.accountEpoch,
                userID: attempt.lease.userID,
                sessionID: attempt.lease.sessionID
            ) else { return }
            await publishLatestState()
            rebuildCallContacts()
        } catch {
            // The authenticated call is already live. A later authoritative history refresh repairs
            // a protected-storage failure without interrupting media or exposing an internal error.
        }
    }

    private func endLateAcceptedCall(
        _ callID: String,
        lease: CallMediaAccountLease
    ) async {
        guard appReviewDemoMutationsAllowed,
              !CallMediaCoordinator.shared.ownsAuthenticatedCall(
            callID: callID,
            lease: lease
        ) else { return }
        _ = try? await APIClientSessionBinding.$sessionID.withValue(lease.sessionID) {
            try await api.endCall(id: callID, reason: "cancelled")
        }
    }

    private func ephemeralCallFailureMessage(_ error: Error) -> String {
        if let payload = error as? APIErrorPayload {
            let message = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { return message }
        }
        return "This call is unavailable right now."
    }

    func flushOutbox(reportFailures: Bool = false) async {
        guard isOnline,
              appReviewDemoMutationsAllowed,
              !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              isSignedIn,
              capabilities != nil,
              let expectedUserID = profile?.id,
              let communicationAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
                forAccountID: expectedUserID
              )
        else { return }
        let expectedAccountEpoch = accountEpoch
        guard let activeAccountLease = callMediaAccountLease,
              activeAccountLease.accountEpoch == expectedAccountEpoch,
              activeAccountLease.userID.caseInsensitiveCompare(expectedUserID) == .orderedSame
        else { return }
        guard flushingAccountEpoch != expectedAccountEpoch else { return }
        flushingAccountEpoch = expectedAccountEpoch
        var encounteredUnavailableCommunicationPrivacy = false
        var encounteredMissingMessagingCapability = false
        defer {
            if flushingAccountEpoch == expectedAccountEpoch {
                flushingAccountEpoch = nil
                if accountEpoch == expectedAccountEpoch,
                   ProtectedCommunicationAdmissionGate.shared.permits(communicationAdmission),
                   !isSubmittingAccountDeletion {
                    if encounteredUnavailableCommunicationPrivacy
                        || encounteredMissingMessagingCapability {
                        // A missing complete block projection must never create a zero-delay replay
                        // loop. The next authenticated refresh (or bounded background replay) first
                        // reloads privacy authority, while call terminations remain independently
                        // replayable during this pass.
                        outboxWakeTask?.cancel()
                        outboxWakeTask = nil
                        CommunicationBackgroundReplayScheduler.shared.schedule(
                            earliestBeginDate: Date().addingTimeInterval(5 * 60)
                        )
                    } else {
                        scheduleOutboxWake()
                    }
                }
            }
        }
        guard let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              ),
              SessionRefreshPolicy.matchesSessionID(
                activeAccountLease.sessionID,
                current: expectedSessionID
              )
        else { return }

        if state.outbox.contains(where: { $0.kind == .callAttempt }) {
            do {
                state = try await commitAuthenticatedMutation(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                ) { persisted in
                    OutboxPolicy.removeLegacyCallAttempts(in: &persisted)
                }
            } catch {
                // A protected-store failure cannot make a legacy prototype call replayable in
                // this process. The migration is attempted again on the next restore/flush.
                OutboxPolicy.removeLegacyCallAttempts(in: &state)
            }
        }

        let commands = OutboxPolicy.readyCommands(state.outbox, at: Date())
        for command in commands {
            var activeCommand = command
            guard isOnline,
                  !isSubmittingAccountDeletion,
                  ProtectedCommunicationAdmissionGate.shared.permits(communicationAdmission),
                  await outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                  ),
                  state.outbox.contains(activeCommand)
            else { return }
            switch command.kind {
            case .secureMessage:
                if isReactionMessagingCommand(activeCommand), !messagingReactionsEnabled {
                    // Reaction commands remain durable while the global rollout is withdrawn.
                    // Never prepare or transmit their ciphertext until the server gate returns.
                    encounteredMissingMessagingCapability = true
                    continue
                }
                if isMessageEditCommand(activeCommand), !messagingMessageEditsEnabled {
                    // A correction is held for the same reason: a peer whose client predates the
                    // descriptor would render one as a bubble full of protocol text.
                    encounteredMissingMessagingCapability = true
                    continue
                }
                if isGroupMessagingCommand(activeCommand), !messagingGroupsEnabled {
                    // Capability withdrawal makes existing groups read-only. Preserve the
                    // encrypted command for a later authorized replay, but do not prepare or
                    // transmit any new group ciphertext while the server gate is absent.
                    encounteredMissingMessagingCapability = true
                    continue
                }
                if !hasUsableCommunicationPrivacyProjection {
                    await loadCommunicationPrivacy()
                }
                switch communicationPrivacyDecision(for: activeCommand) {
                case .allowed:
                    break
                case .blocked:
                    await handleOutboxFailure(
                        activeCommand,
                        error: CommunicationPrivacyMessageAdmissionFailure.blocked,
                        reportFailure: reportFailures,
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    )
                    continue
                case .unavailable:
                    if hasUsableCommunicationPrivacyProjection {
                        await handleOutboxFailure(
                            activeCommand,
                            error: CommunicationPrivacyMessageAdmissionFailure.invalidRecipient,
                            reportFailure: reportFailures,
                            accountEpoch: expectedAccountEpoch,
                            userID: expectedUserID,
                            sessionID: expectedSessionID
                        )
                    } else {
                        encounteredUnavailableCommunicationPrivacy = true
                    }
                    continue
                }
                guard secureMessagingReleasePermitted else {
                    // A capability gap here is almost always a discovery flap (nil or briefly
                    // missing "messaging" while reloading). Hard-failing every queued message
                    // turned a transient blip into red bubbles; leave them queued. The defer
                    // converts this into a bounded background retry rather than a zero-delay
                    // wake loop — the transport still fail-closes on real server denial.
                    encounteredMissingMessagingCapability = true
                    continue
                }
                do {
                    if command.secureMessageFanout == nil {
                        guard ProtectedCommunicationAdmissionGate.shared.permits(
                            communicationAdmission
                        ), !isSubmittingAccountDeletion else { return }
                        _ = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                            accountGeneration: expectedAccountEpoch,
                            sessionID: expectedSessionID,
                            commitAdmission: communicationAdmission
                        ) {
                            try await SecureMessagingExchangeCoordinator.shared.prepareDeferredMessage(
                                commandID: command.id,
                                forUserID: expectedUserID
                            )
                        }
                        guard await reloadOutboxStateIfCurrent(
                            accountEpoch: expectedAccountEpoch,
                            userID: expectedUserID,
                            sessionID: expectedSessionID
                        ) else { return }
                        guard let preparedCommand = state.outbox.first(where: {
                            $0.id == command.id && $0.kind == command.kind
                        }) else { continue }
                        activeCommand = preparedCommand
                    }
                    switch communicationPrivacyDecision(for: activeCommand) {
                    case .allowed:
                        break
                    case .blocked:
                        await handleOutboxFailure(
                            activeCommand,
                            error: CommunicationPrivacyMessageAdmissionFailure.blocked,
                            reportFailure: reportFailures,
                            accountEpoch: expectedAccountEpoch,
                            userID: expectedUserID,
                            sessionID: expectedSessionID
                        )
                        continue
                    case .unavailable:
                        if hasUsableCommunicationPrivacyProjection {
                            await handleOutboxFailure(
                                activeCommand,
                                error: CommunicationPrivacyMessageAdmissionFailure.invalidRecipient,
                                reportFailure: reportFailures,
                                accountEpoch: expectedAccountEpoch,
                                userID: expectedUserID,
                                sessionID: expectedSessionID
                            )
                        } else {
                            encounteredUnavailableCommunicationPrivacy = true
                        }
                        continue
                    }
                    if isGroupMessagingCommand(activeCommand), !messagingGroupsEnabled {
                        // Re-check after roster preparation because that awaited network work and
                        // the authoritative capability projection may have changed meanwhile.
                        encounteredMissingMessagingCapability = true
                        continue
                    }
                    if isReactionMessagingCommand(activeCommand), !messagingReactionsEnabled {
                        // Preparation awaited the live conversation/roster. Re-check the global
                        // gate before the separate send request so a withdrawn rollout cannot
                        // leak already-prepared reaction ciphertext.
                        encounteredMissingMessagingCapability = true
                        continue
                    }
                    if isMessageEditCommand(activeCommand), !messagingMessageEditsEnabled {
                        encounteredMissingMessagingCapability = true
                        continue
                    }
                    guard ProtectedCommunicationAdmissionGate.shared.permits(
                        communicationAdmission
                    ), !isSubmittingAccountDeletion else { return }
                    _ = try await SecureMessagingActivationBinding.withAuthenticatedScope(
                        accountGeneration: expectedAccountEpoch,
                        sessionID: expectedSessionID,
                        commitAdmission: communicationAdmission
                    ) {
                        try await SecureMessagingExchangeCoordinator.shared.sendQueuedMessage(
                            commandID: command.id,
                            forUserID: expectedUserID
                        )
                    }
                    guard await reloadOutboxStateIfCurrent(
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    ) else { return }
                } catch SecureMessagingExchangeError.staleOutboundFanout {
                    // Pre-encryption audience drift: the coordinator has already retired the
                    // command and failed its message visibly (post-encryption staleness resolves
                    // inside sendQueuedMessage the same way), so reload-only is complete
                    // handling — no retained ready command survives to spin this flush loop,
                    // and the audience is never silently re-derived.
                    guard await reloadOutboxStateIfCurrent(
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    ) else { return }
                    if reportFailures {
                        lastError = SecureMessagingExchangeError.staleOutboundFanout.localizedDescription
                    }
                } catch SecureMessagingExchangeError.mediaMessageBlobExpired {
                    await handleRecoverableMediaMessageFailure(
                        activeCommand,
                        error: .mediaMessageBlobExpired,
                        reportFailure: reportFailures,
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    )
                } catch SecureMessagingExchangeError.mediaMessageRosterChanged {
                    await handleRecoverableMediaMessageFailure(
                        activeCommand,
                        error: .mediaMessageRosterChanged,
                        reportFailure: reportFailures,
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard await outboxContextIsCurrent(
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    ) else { return }
                    await handleOutboxFailure(
                        activeCommand,
                        error: error,
                        reportFailure: reportFailures,
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    )
                }
            case .callAttempt:
                // Legacy rows are migration-only and are never submitted or replayed.
                continue
            case .callTermination:
                guard state.outbox.contains(where: { $0.id == command.id }) else { continue }
                guard let replay = OutboxPolicy.terminationReplay(for: command) else {
                    do {
                        state = try await commitOutboxMutation(
                            accountEpoch: expectedAccountEpoch,
                            userID: expectedUserID,
                            sessionID: expectedSessionID,
                            command: command
                        ) { persisted in
                            persisted.outbox.removeAll { $0.id == command.id }
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        if reportFailures { lastError = error.localizedDescription }
                    }
                    continue
                }
                do {
                    guard ProtectedCommunicationAdmissionGate.shared.permits(
                        communicationAdmission
                    ), !isSubmittingAccountDeletion else { return }
                    let call: CallDTO
                    switch replay.kind {
                    case .decline:
                        call = try await APIClientSessionBinding.$sessionID.withValue(
                            expectedSessionID
                        ) {
                            try await api.declineCall(id: replay.callId)
                        }
                    case .end:
                        call = try await APIClientSessionBinding.$sessionID.withValue(
                            expectedSessionID
                        ) {
                            try await api.endCall(
                                id: replay.callId,
                                reason: replay.reason ?? "cancelled"
                            )
                        }
                    }
                    guard await outboxContextIsCurrent(
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    ) else { return }
                    let mappedCall = mapCall(call)
                    state = try await commitOutboxMutation(
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID,
                        command: command
                    ) { persisted in
                            persisted.outbox.removeAll { $0.id == command.id }
                            persisted.calls = CallLifecyclePolicy.merge(
                                remote: [mappedCall],
                                local: persisted.calls
                            )
                        }
                } catch is CancellationError {
                    return
                } catch {
                    guard await outboxContextIsCurrent(
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    ) else { return }
                    if CallLifecyclePolicy.isIdempotentTerminationFailure(
                        error,
                        kind: replay.kind
                    ) {
                        await acknowledgeReplayedTermination(
                            command: command,
                            callId: replay.callId,
                            kind: replay.kind,
                            suppressingErrorMessage: error.localizedDescription,
                            accountEpoch: expectedAccountEpoch,
                            userID: expectedUserID,
                            sessionID: expectedSessionID
                        )
                    } else {
                        await handleOutboxFailure(
                            command,
                            error: error,
                            reportFailure: reportFailures,
                            accountEpoch: expectedAccountEpoch,
                            userID: expectedUserID,
                            sessionID: expectedSessionID
                        )
                    }
                }
            case .scheduledPaymentRequest:
                await replayScheduledPaymentRequest(
                    command,
                    reportFailures: reportFailures,
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                )
            }
        }
    }

    /// Raises one payment request that was arranged for this minute.
    ///
    /// Money movement needs an authorization the app may not hold right now — a locked screen, a
    /// stepped-down session, wallets not yet loaded. None of those mean the schedule was wrong, so
    /// the command waits instead of being spent: it is pushed to the next check rather than
    /// attempted and permanently failed.
    private func replayScheduledPaymentRequest(
        _ command: OfflineCommand,
        reportFailures: Bool,
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        guard var payload = command.scheduledPaymentRequest else {
            // Nothing actionable was stored. Drop the row rather than retry it forever.
            state = (try? await commitOutboxMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID,
                command: command
            ) { persisted in
                persisted.outbox.removeAll { $0.id == command.id }
            }) ?? state
            return
        }
        guard let conversationID = payload.conversationID,
              state.conversations.contains(where: { conversation in
                  conversation.id.caseInsensitiveCompare(conversationID) == .orderedSame
                      && !conversation.isGroup
                      && conversation.participantUserIds.contains(where: {
                          $0.caseInsensitiveCompare(expectedUserID) == .orderedSame
                      })
                      && conversation.participantUserIds.contains(where: {
                          $0.caseInsensitiveCompare(payload.requestedFromUserID) == .orderedSame
                      })
              })
        else {
            await handleOutboxFailure(
                command,
                error: PaymentRequestSubmissionError.invalidRecipient,
                reportFailure: reportFailures,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            )
            return
        }
        guard accountSetupStep == nil,
              !requiresBiometricSignIn,
              financialAccessGranted,
              state.wallets.contains(where: { $0.id == payload.destinationWalletID })
        else {
            state = (try? await commitOutboxMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID,
                command: command
            ) { persisted in
                OutboxPolicy.deferScheduledCommand(command.id, in: &persisted, at: Date())
            }) ?? state
            return
        }
        do {
            let confirmation: ScheduledPaymentRequestConfirmation
            if let stored = payload.confirmedRequest {
                guard stored.isValid(for: payload) else {
                    throw PaymentRequestSubmissionError.unconfirmedRequest
                }
                confirmation = stored
            } else {
                let request = try await createPaymentRequest(
                    destinationWalletID: payload.destinationWalletID,
                    requestedFromUserID: payload.requestedFromUserID,
                    amount: payload.amount,
                    note: payload.note,
                    idempotencyKey: payload.idempotencyKey
                )
                guard let confirmed = ScheduledPaymentRequestConfirmation(
                    request: request,
                    payload: payload
                ) else { throw PaymentRequestSubmissionError.unconfirmedRequest }
                confirmation = confirmed

                // Persist the exact server-confirmed descriptor before attempting chat. A crash
                // from this point onward replays the same message UUID and never creates a second
                // financial request.
                state = try await commitOutboxMutation(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID,
                    command: command
                ) { persisted in
                    guard let index = persisted.outbox.firstIndex(where: { $0.id == command.id }),
                          var storedPayload = persisted.outbox[index].scheduledPaymentRequest
                    else { throw CancellationError() }
                    storedPayload.confirmedRequest = confirmed
                    persisted.outbox[index].scheduledPaymentRequest = storedPayload
                }
                payload.confirmedRequest = confirmed
            }

            guard confirmation.isValid(for: payload),
                  let clientMessageID = confirmation.clientMessageID
            else { throw PaymentRequestSubmissionError.unconfirmedRequest }
            let queued = await queuePaymentEvent(
                conversationId: conversationID,
                title: payload.recipientName,
                recipientId: payload.requestedFromUserID,
                body: confirmation.encodedDescriptor,
                clientMessageID: clientMessageID
            )
            guard queued else {
                state = (try? await commitOutboxMutation(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID,
                    command: state.outbox.first(where: { $0.id == command.id }) ?? command
                ) { persisted in
                    OutboxPolicy.deferScheduledCommand(command.id, in: &persisted, at: Date())
                }) ?? state
                return
            }

            // Only now are both halves durable: the server object exists and the idempotent E2EE
            // card is in the ordinary outbox. Retire the scheduling instruction last.
            let latestCommand = state.outbox.first(where: { $0.id == command.id }) ?? command
            state = try await commitOutboxMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID,
                command: latestCommand
            ) { persisted in
                persisted.outbox.removeAll { $0.id == command.id }
            }
        } catch is CancellationError {
            return
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            await handleOutboxFailure(
                command,
                error: error,
                reportFailure: reportFailures,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            )
        }
    }

    private func communicationPrivacyDecision(
        for command: OfflineCommand
    ) -> CommunicationPrivacyAccessDecision {
        guard command.kind == .secureMessage,
              let recipientUserIDs = command.recipientUserIds,
              !recipientUserIDs.isEmpty
        else { return .unavailable }
        // v1 group policy: per-member privacy is enforced by the server at fanout, so a queued
        // group command is admitted whenever its thread is a locally validated group.
        if command.conversationId.map({ conversationID in
            state.conversations.first(where: { $0.id == conversationID })?.isGroup == true
        }) == true,
           recipientUserIDs.count < SecureMessagingWire.maximumGroupMembers {
            return .allowed
        }
        guard recipientUserIDs.count == 1 else { return .unavailable }
        return CommunicationPrivacyAccessPolicy.decision(
            ownerUserID: profile?.id,
            recipientUserID: recipientUserIDs[0],
            hasLoadedCompleteProjection: hasUsableCommunicationPrivacyProjection,
            blocks: communicationBlocks
        )
    }

    private func isGroupMessagingCommand(_ command: OfflineCommand) -> Bool {
        guard command.kind == .secureMessage,
              let conversationID = command.conversationId
        else { return false }
        return state.conversations.contains {
            $0.id.caseInsensitiveCompare(conversationID) == .orderedSame && $0.isGroup
        }
    }

    private func isReactionMessagingCommand(_ command: OfflineCommand) -> Bool {
        guard command.kind == .secureMessage,
              let messageID = command.messageId,
              let message = state.messages.first(where: { $0.id == messageID })
        else { return false }
        return KitMessageReaction.parse(message.body) != nil
    }

    private func isMessageEditCommand(_ command: OfflineCommand) -> Bool {
        guard command.kind == .secureMessage,
              let messageID = command.messageId,
              let message = state.messages.first(where: { $0.id == messageID })
        else { return false }
        return KitMessageEdit.parse(message.body) != nil
    }

    private func outboxContextIsCurrent(
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String,
        commitAdmission: ProtectedCommunicationAdmissionLease? = nil
    ) async -> Bool {
        await OutboxContextRevalidator.validate(
            localContextIsCurrent: { [self] in
                localOutboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    commitAdmission: commitAdmission
                )
            },
            loadCurrentSession: { [sessions] in await sessions.current() },
            sessionIsCurrent: { currentSession in
                currentSession.sessionId.caseInsensitiveCompare(expectedSessionID) == .orderedSame
                    && currentSession.accountId?.caseInsensitiveCompare(expectedUserID)
                        == .orderedSame
            }
        )
    }

    private func localOutboxContextIsCurrent(
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        commitAdmission: ProtectedCommunicationAdmissionLease?
    ) -> Bool {
        guard !Task.isCancelled,
              !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              isSignedIn,
              accountEpoch == expectedAccountEpoch,
              profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame
        else { return false }
        guard let commitAdmission else { return true }
        return ProtectedCommunicationAdmissionGate.shared.permits(commitAdmission)
    }

    /// Commits a replay mutation only into the same encrypted account that issued the network
    /// request, then returns a snapshot proven to still belong to that live session.
    private func commitOutboxMutation(
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String,
        command expectedCommand: OfflineCommand,
        _ mutation: (inout PersistedState) throws -> Void
    ) async throws -> PersistedState {
        try await commitAuthenticatedMutation(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) { persisted in
            guard persisted.outbox.contains(expectedCommand) else { throw CancellationError() }
            try mutation(&persisted)
        }
    }

    private func commitAuthenticatedMutation(
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String,
        _ mutation: (inout PersistedState) throws -> Void
    ) async throws -> PersistedState {
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { throw CancellationError() }
        try await store.update { persisted in
            guard persisted.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  persisted.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                    == .orderedSame
            else { throw CancellationError() }
            try mutation(&persisted)
        }
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
              snapshot.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                == .orderedSame,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else { throw CancellationError() }
        // Re-fetch monotonically at the moment of publishing: `snapshot` was captured before
        // the context guards suspended, so assigning it directly could roll back newer commits.
        return await publishLatestState()
    }

    @discardableResult
    private func reloadOutboxStateIfCurrent(
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async -> Bool {
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
              snapshot.communicationOwnerUserID?.caseInsensitiveCompare(expectedUserID)
                == .orderedSame,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else { return false }
        await publishLatestState()
        return true
    }

    /// Requests Contacts once, as the first scene becomes active. iOS persists
    /// the choice; later launches only inspect the stored authorization state.
    func requestContactsPermissionAtLaunch() async {
#if DEBUG && APP_STORE_SCREENSHOTS
        guard !AppStoreScreenshotFixture.isActive else { return }
#endif
        guard UIApplication.shared.applicationState == .active else { return }
        if let restoreTask { await restoreTask.value }
        guard appReviewDemoMutationsAllowed,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked
        else { return }
        guard !didRequestContactsAtLaunch else {
            applicationDidBecomeActive()
            return
        }
        didRequestContactsAtLaunch = true

        // Never raise the system Contacts prompt for someone who already switched contact
        // matching off in Kit Pay.
        guard contactDiscoveryEnabled else {
            contactSyncState = .disabledByPreference
            return
        }

        // Unit-test hosts must never display a system privacy prompt.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        switch contactSource.accessState() {
        case .notDetermined:
            contactSyncState = .requestingPermission
            do {
                guard try await contactSource.requestAccess() else {
                    contactSyncState = .denied
                    invalidateContactSyncForRevocation()
                    await clearLocalContactsAfterRevocation()
                    return
                }
            } catch {
                contactSyncState = .failed(error.localizedDescription)
                return
            }
        case .denied:
            contactSyncState = .denied
            invalidateContactSyncForRevocation()
            await clearLocalContactsAfterRevocation()
            return
        case .allowed, .limited:
            break
        }

        scheduleAutomaticContactSync()
    }

    /// Re-checks Settings whenever the app returns to the foreground, then
    /// scans for changes. An unchanged encrypted fingerprint avoids needless
    /// uploads while a periodic server refresh discovers newly joined users.
    func applicationDidBecomeActive() {
        KitPresenceCenter.shared.setForeground(true)
        wakeVisibleConversationSync()
        guard appReviewDemoMutationsAllowed else { return }
        resumeEphemeralOutgoingCallIfPossible()
        schedulePendingProfileAvatarResume()
        // Timers are suspended while the process is backgrounded. Re-arm and drain immediately
        // on every authenticated foreground so due scheduled messages/payment requests do not
        // wait for a later unrelated action. The same foreground is a reliable opportunistic
        // automatic-backup window when iOS deferred its background refresh.
        scheduleOutboxWake()
        scheduleAutomaticMessageBackupRefresh()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isOnline {
                await self.recoverAndDrainFinancialChatReceipts()
                await self.flushOutbox()
            }
            _ = await self.runAutomaticMessageBackupIfDue()
        }
        // Returning to the foreground is the first moment after a crash at which the app can see
        // that a call it thought was live has no session behind it any more.
        Task { @MainActor [weak self] in await self?.reapAbandonedCallRecords() }
        guard contactDiscoveryEnabled else {
            if contactSyncState != .disabledByPreference {
                contactSyncState = .disabledByPreference
            }
            requestCallMicrophonePermissionInForeground()
            Task { @MainActor in
                await CallMediaCoordinator.shared.resumeDeferredInitialCameraIfPossible()
            }
            return
        }
        switch contactSource.accessState() {
        case .allowed, .limited:
            scheduleAutomaticContactSync()
        case .denied:
            contactSyncState = .denied
            invalidateContactSyncForRevocation()
            Task { [weak self] in await self?.clearLocalContactsAfterRevocation() }
        case .notDetermined:
            break
        }
        requestCallMicrophonePermissionInForeground()
        Task { @MainActor in
            await CallMediaCoordinator.shared.resumeDeferredInitialCameraIfPossible()
        }
    }

    private func requestCallMicrophonePermissionInForeground() {
        guard appReviewDemoMutationsAllowed,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted,
              callsFeatureEnabled,
              UIApplication.shared.applicationState == .active,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        Task {
            try? await CallMediaCoordinator.shared.prepareMicrophonePermission()
        }
    }

    func retryAutomaticContactSync() {
        guard appReviewDemoMutationsAllowed else { return }
        // A visible retry follows a failed server pass. Reusing a recent local projection here
        // would hide the error without discovering the newly joined or relinked recipient.
        scheduleAutomaticContactSync(forceServerRefresh: true)
    }

    private func handleBackgroundContactRefresh(_ refreshTask: BGAppRefreshTask) async {
        let taskID = ObjectIdentifier(refreshTask)
        // ObjectIdentifiers can be reused after dealloc; never leave a stale expiry marker
        // behind or a future refresh task could be treated as already expired.
        defer { expiredBackgroundContactTasks.remove(taskID) }
        refreshTask.expirationHandler = { [weak self, weak refreshTask] in
            Task { @MainActor in
                guard let self, let refreshTask else { return }
                self.expiredBackgroundContactTasks.insert(taskID)
                self.contactSyncTask?.cancel()
                self.contactSyncTask = nil
                self.contactSyncCurrentTaskForcesServerRefresh = false
                self.contactSyncGeneration &+= 1
                self.contactSyncNeedsAnotherPass = false
                refreshTask.setTaskCompleted(success: false)
            }
        }
        if let restoreTask { await restoreTask.value }
        for _ in 0 ..< 30 where !hasConnectivityStatus {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard expiredBackgroundContactTasks.remove(taskID) == nil else { return }
        guard let runningTask = scheduleAutomaticContactSync() else {
            refreshTask.setTaskCompleted(success: false)
            return
        }
        let succeeded = await runningTask.value

        guard expiredBackgroundContactTasks.remove(taskID) == nil else { return }
        refreshTask.setTaskCompleted(success: succeeded)
    }

    private func handleBackgroundCommunicationReplay(
        _ processingTask: BGProcessingTask
    ) async {
        let taskID = ObjectIdentifier(processingTask)
        // BackgroundTasks treats a second completion as a programmer error. Expiration can race
        // the final outbox commit, so use the same exactly-once latch as automatic backups.
        let completion = BackgroundTaskCompletionLatch(processingTask)
        processingTask.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else {
                    completion.finish(success: false)
                    return
                }
                self.expiredBackgroundCommunicationTasks.insert(taskID)
                self.communicationReplayTask?.cancel()
                self.communicationReplayTask = nil
                // Delivery consumed the pending system request. Keep every durable outbox row
                // untouched and arm the earliest one again before returning the expired task.
                self.scheduleOutboxWake()
                completion.finish(success: false)
            }
        }
        if let restoreTask { await restoreTask.value }
        for _ in 0 ..< 30 where !hasConnectivityStatus {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard expiredBackgroundCommunicationTasks.remove(taskID) == nil else { return }

        let replay: Task<Bool, Never> = Task { @MainActor [weak self] in
            guard let self,
                  self.isOnline,
                  self.isSignedIn,
                  self.accountSetupStep == nil,
                  self.communicationAccessGranted
            else { return false }
            await self.refresh()
            // Start durable local work, but spend the background network window draining rows
            // that are already ready instead of waiting behind unrelated image/voice jobs.
            self.schedulePendingMediaPreprocessing()
            await self.drainReadyOutbox()
            if let hydration = self.schedulePendingMediaHydration() {
                await hydration.value
            }
            return !Task.isCancelled && self.isOnline && self.isSignedIn
        }
        communicationReplayTask = replay
        let succeeded = await replay.value
        communicationReplayTask = nil

        guard expiredBackgroundCommunicationTasks.remove(taskID) == nil else { return }
        scheduleOutboxWake()
        completion.finish(success: succeeded)
    }

    /// A background URLSession can finish a ciphertext chunk after this process was terminated.
    /// Restore the account-bound projection first, then let the exact durable outbox row consume
    /// that completion and advance its resumable offset. The uploader keeps iOS's event callback
    /// alive around this method (with its own bounded watchdog), so scheduling the next chunk is
    /// deterministic rather than waiting for an unrelated foreground refresh.
    private func recoverCompletedBackgroundMediaUpload() async {
        if let restoreTask { await restoreTask.value }
        for _ in 0 ..< 30 where !hasConnectivityStatus {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard isOnline,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted
        else {
            scheduleOutboxWake()
            return
        }
        schedulePendingMediaPreprocessing()
        await drainReadyOutbox(maximumPasses: 1)
        scheduleOutboxWake()
    }

    private func contactsDidChange() {
        contactChangeDebounceTask?.cancel()
        contactChangeDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.scheduleAutomaticContactSync()
        }
    }

    private func invalidateContactSyncForRevocation() {
        contactSyncTask?.cancel()
        contactSyncTask = nil
        contactSyncCurrentTaskForcesServerRefresh = false
        contactSyncGeneration &+= 1
        contactSyncNeedsAnotherPass = false
        contactDirectoryRevision &+= 1
    }

    private func clearLocalContactsAfterRevocation() async {
        await clearLocalContacts(resultingState: .denied)
    }

    /// Drops every locally projected contact. `resultingState` distinguishes iOS revoking access
    /// (which offers an Open Settings recovery) from the user switching contact matching off in
    /// Kit Pay (which needs no recovery — they can switch it back on in the same place).
    private func clearLocalContacts(resultingState: AutomaticContactSyncState) async {
        do {
            try await store.update { persisted in
                persisted.contacts = []
                persisted.contactSyncFingerprint = nil
                persisted.contactSyncSnapshotScope = nil
                persisted.contactSyncLastCompletedAt = nil
            }
            await publishLatestState()
            rebuildCallContacts()
        } catch {
            // Revocation must take effect in-memory even if protected storage
            // is temporarily unavailable; retry persistence next foreground.
            state.contacts = []
            state.contactSyncFingerprint = nil
            state.contactSyncSnapshotScope = nil
            state.contactSyncLastCompletedAt = nil
            rebuildCallContacts()
        }
        contactSyncState = resultingState
    }

    @discardableResult
    private func scheduleAutomaticContactSync(
        forceServerRefresh: Bool = false
    ) -> Task<Bool, Never>? {
        guard appReviewDemoMutationsAllowed,
              isSignedIn,
              isOnline,
              accountSetupStep == nil,
              communicationAccessGranted,
              contactDiscoveryEnabled
        else { return nil }
        guard [.allowed, .limited].contains(contactSource.accessState()) else { return nil }
        if let contactSyncTask {
            if forceServerRefresh, !contactSyncCurrentTaskForcesServerRefresh {
                // The picker must not finish behind a cache-eligible pass. Invalidate that pass
                // and return a new task which is guaranteed to consult the server. Generation and
                // session fences prevent the cancelled task from publishing stale state.
                contactSyncTask.cancel()
                self.contactSyncTask = nil
                contactSyncCurrentTaskForcesServerRefresh = false
                contactSyncGeneration &+= 1
                contactSyncNeedsAnotherPass = false
            } else {
                if !forceServerRefresh { contactSyncNeedsAnotherPass = true }
                return contactSyncTask
            }
        }

        let expectedAccountEpoch = accountEpoch
        contactSyncGeneration &+= 1
        let expectedSyncGeneration = contactSyncGeneration
        contactSyncCurrentTaskForcesServerRefresh = forceServerRefresh
        let task = Task { [weak self] in
            guard let self else { return false }
            let succeeded = await self.performAutomaticContactSync(
                expectedAccountEpoch: expectedAccountEpoch,
                expectedSyncGeneration: expectedSyncGeneration,
                forceServerRefresh: forceServerRefresh
            )
            guard self.accountEpoch == expectedAccountEpoch,
                  self.contactSyncGeneration == expectedSyncGeneration
            else { return false }
            self.contactSyncTask = nil
            self.contactSyncCurrentTaskForcesServerRefresh = false
            if self.contactSyncNeedsAnotherPass {
                self.contactSyncNeedsAnotherPass = false
                self.scheduleAutomaticContactSync()
            }
            return succeeded
        }
        contactSyncTask = task
        return task
    }

    private func performAutomaticContactSync(
        expectedAccountEpoch: UUID,
        expectedSyncGeneration: UInt64,
        forceServerRefresh: Bool
    ) async -> Bool {
        guard appReviewDemoMutationsAllowed,
              isSignedIn, isOnline,
              accountSetupStep == nil,
              communicationAccessGranted,
              accountEpoch == expectedAccountEpoch,
              contactSyncGeneration == expectedSyncGeneration,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return false }
        let expectedContactAuthorizationRevision = contactAuthorizationRevision

        let accessState = contactSource.accessState()
        guard accessState == .allowed || accessState == .limited else {
            contactSyncState = .denied
            invalidateContactSyncForRevocation()
            await clearLocalContactsAfterRevocation()
            return false
        }
        let limitedAccess = accessState == .limited

        contactDirectoryRevision &+= 1
        let expectedDirectoryRevision = contactDirectoryRevision
        contactSyncState = .syncing(
            ContactSyncProgress(phase: .preparing, completedUnitCount: 0, totalUnitCount: 0)
        )

        do {
            let rawContacts = try await contactSource.phoneNumbers()
            let identityContext = phoneIdentityContext
            let normalizationTask = Task.detached(priority: .utility) {
                let snapshot = ContactSyncNormalizer.snapshot(
                    from: rawContacts,
                    context: identityContext
                )
                return (snapshot: snapshot, fingerprint: snapshot.fingerprint)
            }
            let normalized = await withTaskCancellationHandler {
                await normalizationTask.value
            } onCancel: {
                normalizationTask.cancel()
            }
            let snapshot = normalized.snapshot
            let snapshotFingerprint = normalized.fingerprint
            try Task.checkCancellation()
            guard snapshot.omittedCount == 0 else {
                throw ContactSyncError.snapshotTooLarge(limit: ContactSyncSnapshot.serverLimit)
            }
            guard await contactSyncContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                syncGeneration: expectedSyncGeneration,
                sessionID: expectedSessionID,
                directoryRevision: expectedDirectoryRevision
            ) else { return false }

            let recentlyRefreshed = state.contactSyncLastCompletedAt.map {
                Date().timeIntervalSince($0) < 15 * 60
            } ?? false
            // Automatic snapshots are device-local, not account-global. Always
            // upsert so a second iPhone (or limited access) cannot erase rows
            // learned from another device. Full replacement requires a future
            // device-scoped server snapshot model.
            let snapshotScope: ContactSyncSnapshotScope = .partial
            let snapshotIsUnchanged = state.contactSyncFingerprint == snapshotFingerprint
                && state.contactSyncSnapshotScope == snapshotScope
            let requiresAuthorizationRefresh = refreshedContactAuthorizationRevision
                < expectedContactAuthorizationRevision
            if ContactSyncServerRefreshPolicy.canReuseLocalProjection(
                snapshotIsUnchanged: snapshotIsUnchanged,
                recentlyRefreshed: recentlyRefreshed,
                requiresAuthorizationRefresh: requiresAuthorizationRefresh,
                forceServerRefresh: forceServerRefresh
            ) {
                contactSyncState = .synced(
                    uploaded: snapshot.contacts.count,
                    matched: contactDirectory.filter { $0.isKitUser == true }.count,
                    limitedAccess: limitedAccess
                )
                return true
            }
            let response = try await contactSyncRequestWithRetry(
                accountEpoch: expectedAccountEpoch,
                syncGeneration: expectedSyncGeneration,
                sessionID: expectedSessionID,
                directoryRevision: expectedDirectoryRevision
            ) { [weak self] in
                guard let self else { throw CancellationError() }
                if snapshotIsUnchanged {
                    self.contactSyncState = .syncing(
                        ContactSyncProgress(
                            phase: .refreshing,
                            completedUnitCount: 0,
                            totalUnitCount: 0
                        )
                    )
                    return try await self.api.contacts()
                }
                return try await self.api.syncContacts(
                    snapshot.contacts,
                    scope: snapshotScope
                ) { [weak self] progress in
                    await self?.recordContactSyncProgress(
                        progress,
                        accountEpoch: expectedAccountEpoch,
                        syncGeneration: expectedSyncGeneration,
                        sessionID: expectedSessionID,
                        directoryRevision: expectedDirectoryRevision
                    )
                }
            }

            try Task.checkCancellation()
            guard await contactSyncContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                syncGeneration: expectedSyncGeneration,
                sessionID: expectedSessionID,
                directoryRevision: expectedDirectoryRevision
            ) else { return false }

            let serverContacts = response.items ?? []
            let snapshotEntries = snapshot.contacts
            let directoryTask = Task.detached(priority: .utility) {
                let visibleContacts = ContactRecipientDirectory.restrictedToSnapshot(
                    serverContacts,
                    entries: snapshotEntries,
                    context: identityContext
                )
                return ContactRecipientDirectory.ordered(
                    visibleContacts,
                    context: identityContext
                )
            }
            let directory = await withTaskCancellationHandler {
                await directoryTask.value
            } onCancel: {
                directoryTask.cancel()
            }
            try Task.checkCancellation()
            guard await contactSyncContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                syncGeneration: expectedSyncGeneration,
                sessionID: expectedSessionID,
                directoryRevision: expectedDirectoryRevision
            ) else { return false }
            let completedAt = Date()
            try await store.update { persisted in
                persisted.contacts = directory
                persisted.contactSyncFingerprint = snapshotFingerprint
                persisted.contactSyncSnapshotScope = snapshotScope
                persisted.contactSyncLastCompletedAt = completedAt
            }
            let updatedState = await store.snapshot()
            guard await contactSyncContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                syncGeneration: expectedSyncGeneration,
                sessionID: expectedSessionID,
                directoryRevision: expectedDirectoryRevision
            ) else { return false }
            await publishLatestState()
            refreshedContactAuthorizationRevision = max(
                refreshedContactAuthorizationRevision,
                expectedContactAuthorizationRevision
            )
            rebuildCallContacts()
            contactSyncState = .synced(
                uploaded: snapshot.contacts.count,
                matched: directory.filter { $0.isKitUser == true }.count,
                limitedAccess: limitedAccess
            )
            return true
        } catch is CancellationError {
            if contactSyncGeneration == expectedSyncGeneration,
               contactSyncState != .denied {
                contactSyncState = .idle
            }
            return false
        } catch {
            guard accountEpoch == expectedAccountEpoch,
                  contactSyncGeneration == expectedSyncGeneration,
                  contactDirectoryRevision == expectedDirectoryRevision
            else { return false }
            contactSyncState = .failed(contactSyncErrorMessage(error))
            return false
        }
    }

    private func recordContactSyncProgress(
        _ progress: ContactSyncProgress,
        accountEpoch expectedAccountEpoch: UUID,
        syncGeneration expectedSyncGeneration: UInt64,
        sessionID expectedSessionID: String,
        directoryRevision expectedDirectoryRevision: UInt64
    ) async {
        guard await contactSyncContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            syncGeneration: expectedSyncGeneration,
            sessionID: expectedSessionID,
            directoryRevision: expectedDirectoryRevision
        ) else { return }
        contactSyncState = .syncing(progress)
    }

    private func contactSyncRequestWithRetry<Value>(
        accountEpoch expectedAccountEpoch: UUID,
        syncGeneration expectedSyncGeneration: UInt64,
        sessionID expectedSessionID: String,
        directoryRevision expectedDirectoryRevision: UInt64,
        operation: () async throws -> Value
    ) async throws -> Value {
        var automaticRetryCount = 0
        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                switch ContactSyncRetryPolicy.decision(
                    for: error,
                    automaticRetryCount: automaticRetryCount
                ) {
                case .retry(let delay):
                    automaticRetryCount += 1
                    try await Task.sleep(for: .seconds(delay))
                case .waitForConnectivity:
                    throw CancellationError()
                case .stop:
                    throw error
                }
                try Task.checkCancellation()
                guard await contactSyncContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    syncGeneration: expectedSyncGeneration,
                    sessionID: expectedSessionID,
                    directoryRevision: expectedDirectoryRevision
                ) else { throw CancellationError() }
            }
        }
    }

    private func contactSyncContextIsCurrent(
        accountEpoch expectedAccountEpoch: UUID,
        syncGeneration expectedSyncGeneration: UInt64,
        sessionID expectedSessionID: String,
        directoryRevision expectedDirectoryRevision: UInt64
    ) async -> Bool {
        guard isSignedIn,
              accountEpoch == expectedAccountEpoch,
              contactSyncGeneration == expectedSyncGeneration,
              contactDirectoryRevision == expectedDirectoryRevision
        else { return false }
        return await sessions.current()?.sessionId == expectedSessionID
    }

    private func contactSyncErrorMessage(_ error: Error) -> String {
        if let payload = error as? APIErrorPayload { return payload.message }
        return error.localizedDescription
    }

    /// Searches the authenticated Kit Pay member directory without persisting
    /// server-wide results into the user's private address-book projection.
    func searchKitUsers(query: String) async throws -> [KitUserSearchResultDTO] {
        guard !isSigningOut,
              isSignedIn,
              isOnline,
              hasUsableCommunicationPrivacyProjection,
              let expectedUserID = profile?.id,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return [] }
        let expectedAccountEpoch = accountEpoch
        let response = try await APIClientSessionBinding.$sessionID.withValue(
            expectedSessionID
        ) {
            try await api.searchKitUsers(query: query)
        }
        try Task.checkCancellation()
        guard !isSigningOut,
              isSignedIn,
              isOnline,
              accountEpoch == expectedAccountEpoch,
              profile?.id.caseInsensitiveCompare(expectedUserID) == .orderedSame,
              await sessions.current()?.sessionId == expectedSessionID
        else { throw CancellationError() }
        return (response.items ?? []).filter {
            communicationPrivacyAllowsOutbound(to: $0.id)
        }
    }

    func loadContactDirectory(forceServerRefresh: Bool = false) async {
        rebuildCallContacts()
        if let runningTask = scheduleAutomaticContactSync(
            forceServerRefresh: forceServerRefresh
        ) {
            _ = await runningTask.value
        }
    }

    func loadCallContacts() async {
        guard callsFeatureEnabled else {
            rebuildCallContacts()
            return
        }
        await loadContactDirectory()
    }

    func callContactMatches(_ contact: CallableContact, query: String) -> Bool {
        if let source = contact.source {
            return ContactRecipientDirectory.matches(
                source,
                query: query,
                context: phoneIdentityContext
            )
        }
        return contact.name.localizedCaseInsensitiveContains(query)
            || contact.subtitle.localizedCaseInsensitiveContains(query)
    }

    private func verifyIncomingCallOwnership(
        _ request: IncomingCallVerificationRequest
    ) async {
        guard NotificationCoordinator.shared.isAwaitingIncomingCallVerification(request) else {
            return
        }
        guard appReviewDemoMutationsAllowed else {
            NotificationCoordinator.shared.rejectIncomingCallVerification(request)
            return
        }
        guard isOnline else {
            NotificationCoordinator.shared.retryIncomingCallVerificationAfterTransientFailure(
                request
            )
            return
        }
        guard callsFeatureEnabled else {
            NotificationCoordinator.shared.rejectIncomingCallVerification(request)
            return
        }
        guard !isSigningOut,
              isSignedIn,
              let expectedUserID = profile?.id,
              let expectedLease = callMediaAccountLease
        else { return }
        let expectedAccountEpoch = accountEpoch
        guard let expectedSessionID = await sessions.current()?.sessionId,
              expectedLease.accountEpoch == expectedAccountEpoch,
              expectedLease.userID.caseInsensitiveCompare(expectedUserID) == .orderedSame,
              expectedLease.sessionID.caseInsensitiveCompare(expectedSessionID) == .orderedSame,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              ),
              NotificationCoordinator.shared.isAwaitingIncomingCallVerification(request)
        else { return }

        do {
            let response = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.call(id: request.push.callId)
            }
            guard callMediaAccountLease == expectedLease,
                  await outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                  ),
                  NotificationCoordinator.shared.isAwaitingIncomingCallVerification(request)
            else { return }
            guard let incoming = IncomingCallAuthenticationPolicy.authenticatedCall(
                response: response,
                matching: request.push,
                currentUserID: expectedUserID
            ) else {
                NotificationCoordinator.shared.rejectIncomingCallVerification(request)
                return
            }
            _ = NotificationCoordinator.shared.promoteAuthenticatedIncomingCall(
                incoming,
                for: request
            )
        } catch is CancellationError {
            return
        } catch {
            guard callMediaAccountLease == expectedLease,
                  await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
                  ),
                  NotificationCoordinator.shared.isAwaitingIncomingCallVerification(request)
            else { return }
            switch IncomingCallLookupFailurePolicy.disposition(for: error) {
            case .terminal:
                NotificationCoordinator.shared.rejectIncomingCallVerification(request)
            case .transient:
                NotificationCoordinator.shared.retryIncomingCallVerificationAfterTransientFailure(
                    request,
                    retryAfter: IncomingCallLookupRetryPolicy.retryAfter(from: error)
                )
            }
        }
    }

    private func recordAuthenticatedIncomingCall(
        _ incoming: AuthenticatedIncomingCall
    ) async {
        let record = incoming.record
        guard appReviewDemoMutationsAllowed else {
            NotificationCoordinator.shared.reportCallEnded(incoming.callUUID, reason: .failed)
            return
        }
        guard !locallyTerminatedCallIds.contains(record.id.lowercased()) else {
            NotificationCoordinator.shared.reportCallEnded(incoming.callUUID, reason: .remoteEnded)
            return
        }
        guard !isSigningOut,
              isSignedIn,
              !incoming.ringDeadline.isExpired(),
              let expectedUserID = profile?.id,
              let expectedLease = callMediaAccountLease
        else { return }
        let expectedAccountEpoch = accountEpoch
        guard let expectedSessionID = await sessions.current()?.sessionId,
              expectedLease.accountEpoch == expectedAccountEpoch,
              expectedLease.userID.caseInsensitiveCompare(expectedUserID) == .orderedSame,
              expectedLease.sessionID.caseInsensitiveCompare(expectedSessionID) == .orderedSame,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else { return }
        do {
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                persisted.calls = CallLifecyclePolicy.mergingIncomingRing(
                    record,
                    into: persisted.calls
                )
            }
            rebuildCallContacts()
            routeAuthenticatedIncomingCall(incoming)
        } catch is CancellationError {
            return
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            lastError = error.localizedDescription
        }
    }

    private var connectedMediaPermitsCallWaitingMerge: Bool {
        switch CallMediaCoordinator.shared.state {
        case .connected, .reconnecting:
            true
        case .idle, .preparing, .connecting, .ending:
            false
        }
    }

    private func handleWaitingCallSystemAction(_ action: CallSystemAction) async {
        // CallKit marks the waiting UUID before publishing this action. AppModel's successful
        // merge scope also finishes it, while this outer idempotent release covers authentication,
        // replay, and eligibility failures that never create an AppModel operation token.
        defer {
            NotificationCoordinator.shared.finishWaitingCallMergeAttempt(callId: action.callId)
        }
        await ingestQueuedAuthenticatedIncomingCall(callID: action.callId)
        guard let actionCallID = canonicalCallID(action.callId),
              callWaitingState.waitingCall?.callID == actionCallID
        else {
            await rejectUnmergeableSecondaryCall(action)
            return
        }
        await mergeWaitingCall()
    }

    /// Retires only the second CallKit/backend call. It deliberately does not ask the media
    /// coordinator to disconnect, because a different call owns the current LiveKit room.
    private func rejectUnmergeableSecondaryCall(_ action: CallSystemAction) async {
        _ = clearWaitingCallForLifecycle(callID: action.callId)
        NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
        await terminateCall(id: action.callId, kind: .decline, reason: nil)
    }

    /// One validated "this call was answered", from any route — the socket frame, the
    /// `call.answered` push, or a claim from the buffer once a start response named its call.
    ///
    /// Three kinds of device receive the same signal and each must do something different:
    /// the caller advances and anchors its timers, this account's *other* ringing devices
    /// stop offering the call, and the device that actually answered takes only the
    /// timestamp. Every branch is fenced by exact call id, so a signal about any other call
    /// moves nothing here.
    func handleCallAnswerSignal(callId rawCallId: String, signal: CallAnswerSignal?) {
        guard isSignedIn,
              let callId = CallAnswerSignalPolicy.callId(rawCallId)
        else { return }

        let media = CallMediaCoordinator.shared
        if media.activeCall?.id.caseInsensitiveCompare(callId) == .orderedSame {
            if let lease = callMediaAccountLease {
                cancelOutgoingCallRingDeadline(
                    backendCallID: callId,
                    lease: lease
                )
            }
            guard media.applyCallAnswered(callId: callId, signal: signal) else { return }
            if media.activeCall?.direction == "outgoing" {
                // CallKit renders wall-clock dates, so the connect instant is derived from
                // the two server timestamps and mapped onto local time at receipt. The
                // device clock supplies only "now" — never the age — which keeps the system
                // call timer on the same authoritative origin as the in-app one.
                let age = signal.flatMap {
                    CallAnswerSignalPolicy.age(
                        answeredAt: $0.answeredAt,
                        serverTime: $0.serverTime
                    )
                } ?? 0
                NotificationCoordinator.shared.reportOutgoingCallConnected(
                    callId: callId,
                    connectedAt: Date().addingTimeInterval(-age)
                )
            }
            return
        }

        // Not the call this device is on. If it is one this device is still offering —
        // ringing full-screen or waiting behind the current call — another device on this
        // account answered it, and the offer ends as answered-elsewhere rather than ringing
        // on until the invite expires and recording a miss.
        if callWaitingState.waitingCall?.callID.caseInsensitiveCompare(callId) == .orderedSame {
            _ = clearWaitingCallForLifecycle(callID: callId)
        }
        NotificationCoordinator.shared.reportCallAnsweredElsewhere(callId: callId)

        // And if a `POST /calls` is in flight, the answer may belong to the very call its
        // response is about to name. Held for that exact claim instead of being dropped for
        // not matching a call this device could not yet name.
        if ephemeralOutgoingCallGate.attempt != nil {
            rememberPendingCallAnswer(callId: callId, signal: signal)
        }
    }

    private func rememberPendingCallAnswer(callId: String, signal: CallAnswerSignal?) {
        // Re-inserted rather than merged, so a repeat of the same answer refreshes its
        // position instead of ageing out behind newer, unrelated ones.
        pendingCallAnswers.removeAll { $0.callId == callId }
        pendingCallAnswers.append((callId: callId, signal: signal))
        let capacity = 8
        if pendingCallAnswers.count > capacity {
            pendingCallAnswers.removeFirst(pendingCallAnswers.count - capacity)
        }
    }

    /// Claims and applies the buffered answer for exactly [callId], once. A successful start
    /// response calls this the moment it can name its call, which is what closes the gap
    /// between "the callee picked up" and "this device knew which call that was about".
    private func claimPendingCallAnswer(callId rawCallId: String) {
        guard let callId = CallAnswerSignalPolicy.callId(rawCallId),
              let index = pendingCallAnswers.firstIndex(where: { $0.callId == callId })
        else { return }
        let pending = pendingCallAnswers.remove(at: index)
        handleCallAnswerSignal(callId: pending.callId, signal: pending.signal)
    }

    func handleCallSystemAction(_ action: CallSystemAction) async {
        guard appReviewDemoMutationsAllowed else {
            await CallMediaCoordinator.shared.disconnectFromCallKit(callId: action.callId)
            NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
            return
        }
        guard !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked
        else {
            await retireBlockedCallActionIfOwned(action)
            return
        }
        switch action.kind {
        case .answer:
            if callActionTargetsDifferentActiveMediaCall(action) {
                await ingestQueuedAuthenticatedIncomingCall(callID: action.callId)
                if connectedMediaPermitsCallWaitingMerge {
                    await handleWaitingCallSystemAction(action)
                } else {
                    await rejectUnmergeableSecondaryCall(action)
                }
                return
            }
            let expectedAccountEpoch = accountEpoch
            guard !isSigningOut,
                  isSignedIn,
                  let expectedUserID = profile?.id,
                  let expectedSessionID = await sessions.current()?.sessionId,
                  let mediaLease = callMediaAccountLease,
                  mediaLease.accountEpoch == expectedAccountEpoch,
                  mediaLease.userID.caseInsensitiveCompare(expectedUserID) == .orderedSame,
                  SessionRefreshPolicy.matchesSessionID(
                    mediaLease.sessionID,
                    current: expectedSessionID
                  ),
                  await outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                  )
            else {
                await CallMediaCoordinator.shared.disconnectFromCallKit(callId: action.callId)
                NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
                if !isSigningOut, isSignedIn { lastError = "Sign in to answer this call." }
                return
            }
            // Reading the session and account fence suspends. Repeat media ownership before this
            // action is allowed to alter the connecting presentation.
            if callActionTargetsDifferentActiveMediaCall(action) {
                await ingestQueuedAuthenticatedIncomingCall(callID: action.callId)
                if connectedMediaPermitsCallWaitingMerge {
                    await handleWaitingCallSystemAction(action)
                } else {
                    await rejectUnmergeableSecondaryCall(action)
                }
                return
            }
            CallMediaCoordinator.shared.presentConnecting(
                incomingPresentation(for: action),
                lease: mediaLease
            )
            do {
                let session = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.acceptCall(id: action.callId)
                }
                guard !callActionTargetsDifferentActiveMediaCall(action) else {
                    await terminateCall(id: session.call.id, kind: .end, reason: "cancelled")
                    NotificationCoordinator.shared.reportCallEnded(
                        action.callUUID,
                        reason: .failed
                    )
                    return
                }
                guard await outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                ) else {
                    _ = try? await APIClientSessionBinding.$sessionID.withValue(
                        expectedSessionID
                    ) {
                        try await api.endCall(id: session.call.id, reason: "cancelled")
                    }
                    await CallMediaCoordinator.shared.disconnectFromCallKit(callId: action.callId)
                    NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
                    return
                }
                guard !locallyTerminatedCallIds.contains(action.callId.lowercased()) else {
                    await flushOutbox()
                    await CallMediaCoordinator.shared.disconnectFromCallKit(callId: action.callId)
                    NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
                    return
                }
                let activeRecord = mapCall(session.call, stateOverride: .active)
                // Answering must not wait on protected storage. Committing the answered row
                // re-encrypts the whole local state, and doing it here would spend that time in the
                // one place the user is listening for the other person. The same reconciliation is
                // projected in memory to decide whether media may start, and the durable write
                // follows once the call is live.
                let projectedCalls = CallLifecyclePolicy.merge(
                    remote: [
                        CallLifecyclePolicy.mergingStartResponse(
                            activeRecord,
                            with: state.calls.first {
                                $0.id.caseInsensitiveCompare(activeRecord.id) == .orderedSame
                            }
                        ),
                    ],
                    local: state.calls
                )
                guard !callActionTargetsDifferentActiveMediaCall(action),
                      !locallyTerminatedCallIds.contains(action.callId.lowercased()),
                      CallLifecyclePolicy.allowsMediaStart(
                        callID: session.call.id,
                        in: projectedCalls
                      )
                else {
                    await terminateCall(id: session.call.id, kind: .end, reason: "cancelled")
                    await CallMediaCoordinator.shared.disconnectFromCallKit(callId: action.callId)
                    NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
                    return
                }
                let mediaResult = Result {
                    try CallMediaHandoff(
                        session: session,
                        participantAvatarURL: callParticipantAvatarURL(
                            for: activeRecord.participantUserIds,
                            identities: activeRecord.participantIdentities
                        ),
                        participantVerification: callParticipantVerification(
                            for: activeRecord.participantUserIds,
                            identities: activeRecord.participantIdentities
                        )
                    )
                }
                switch mediaResult {
                case .success(let handoff):
                    await CallMediaCoordinator.shared.consumeAuthenticated(
                        AuthenticatedCallMediaHandoff(lease: mediaLease, handoff: handoff)
                    )
                    await persistAnsweredCall(
                        activeRecord,
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    )
                case .failure(let error):
                    await APIClientSessionBinding.$sessionID.withValue(expectedSessionID) {
                        await terminateCall(
                            id: session.call.id,
                            kind: .end,
                            reason: "network_error"
                        )
                    }
                    await CallMediaCoordinator.shared.disconnectFromCallKit(callId: action.callId)
                    NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
                    if await outboxContextIsCurrent(
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    ) {
                        lastError = error.localizedDescription
                    }
                }
            } catch is CancellationError {
                await CallMediaCoordinator.shared.disconnectFromCallKit(callId: action.callId)
                NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
            } catch {
                guard await outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                ) else {
                    await CallMediaCoordinator.shared.disconnectFromCallKit(callId: action.callId)
                    NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
                    return
                }
                do {
                    state = try await commitAuthenticatedMutation(
                        accountEpoch: expectedAccountEpoch,
                        userID: expectedUserID,
                        sessionID: expectedSessionID
                    ) { persisted in
                        if let index = persisted.calls.firstIndex(where: {
                            $0.id.caseInsensitiveCompare(action.callId) == .orderedSame
                        }) {
                            persisted.calls[index].state = .failed
                            persisted.calls[index].endedAt = Date()
                        }
                    }
                } catch {
                    // The authenticated context is rechecked below before any visible error.
                }
                await enqueueTermination(
                    callId: action.callId,
                    kind: .decline,
                    reason: nil,
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                )
                await CallMediaCoordinator.shared.disconnectFromCallKit(callId: action.callId)
                NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
                if await outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                ) {
                    lastError = error.localizedDescription
                }
            }
        case .mergeWaiting:
            await handleWaitingCallSystemAction(action)
        case .decline:
            _ = clearWaitingCallForLifecycle(callID: action.callId)
            await terminateCall(id: action.callId, kind: .decline, reason: nil)
        case .end:
            _ = clearWaitingCallForLifecycle(callID: action.callId)
            await terminateCall(id: action.callId, kind: .end, reason: "cancelled")
        case .timedOut:
            _ = clearWaitingCallForLifecycle(callID: action.callId)
            await markCallMissed(action.callId)
        }
    }

    /// Records an answered call after its media is already live. A protected-storage failure here
    /// is repaired by the next authoritative history refresh; it must never interrupt a call the
    /// user is already speaking on.
    private func persistAnsweredCall(
        _ activeRecord: CallRecord,
        accountEpoch: UUID,
        userID: String,
        sessionID: String
    ) async {
        do {
            state = try await commitAuthenticatedMutation(
                accountEpoch: accountEpoch,
                userID: userID,
                sessionID: sessionID
            ) { persisted in
                let existing = persisted.calls.first {
                    $0.id.caseInsensitiveCompare(activeRecord.id) == .orderedSame
                }
                let reconciled = CallLifecyclePolicy.mergingStartResponse(
                    activeRecord,
                    with: existing
                )
                persisted.calls = CallLifecyclePolicy.merge(
                    remote: [reconciled],
                    local: persisted.calls
                )
            }
            rebuildCallContacts()
        } catch {
            // Intentionally silent: see the note above.
        }
    }

    private func retireBlockedCallActionIfOwned(_ action: CallSystemAction) async {
        guard let targetAccountID = privacyQuarantineTargetAccountID,
              callMediaAccountLease?.userID.caseInsensitiveCompare(targetAccountID)
                == .orderedSame
        else { return }
        await CallMediaCoordinator.shared.disconnectFromCallKit(callId: action.callId)
        NotificationCoordinator.shared.reportCallEnded(action.callUUID, reason: .failed)
    }

    func handleCallMediaFailure(_ failure: CallMediaFailure) async {
        guard appReviewDemoMutationsAllowed,
              !isSigningOut,
              callMediaAccountLease == failure.lease,
              !locallyTerminatedCallIds.contains(failure.callId.lowercased()),
              await outboxContextIsCurrent(
                accountEpoch: failure.lease.accountEpoch,
                userID: failure.lease.userID,
                sessionID: failure.lease.sessionID
              )
        else { return }
        cancelOutgoingCallRingDeadline(
            backendCallID: failure.callId,
            lease: failure.lease
        )
        lastError = "Call media failed: \(failure.message)"
        await terminateCall(id: failure.callId, kind: .end, reason: "network_error")
    }

    func registerPushToken(_ token: String, provider: String = "apns") async {
        guard appReviewDemoMutationsAllowed,
              !isSigningOut,
              isSignedIn,
              accountSetupStep == nil,
              communicationAccessGranted,
              let accountID = profile?.id
        else { return }
        let expectedAccountEpoch = accountEpoch
        guard let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: accountID,
                sessionID: expectedSessionID
              )
        else { return }
        _ = await pushRegistrations.register(
            accountID: accountID,
            provider: provider,
            token: token
        ) { [weak self, api] in
            guard let self,
                  await self.outboxContextIsCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: accountID,
                    sessionID: expectedSessionID
                  )
            else { throw CancellationError() }
            let result = try await APIClientSessionBinding.$sessionID.withValue(
                expectedSessionID
            ) {
                try await api.registerPushToken(token, provider: provider)
            }
            guard await self.outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: accountID,
                sessionID: expectedSessionID
            ) else { throw CancellationError() }
            return result.registered == true
        }
    }

    func unregisterPushToken(provider: String) async {
        guard appReviewDemoMutationsAllowed,
              let accountID = profile?.id
        else { return }
        let expectedAccountEpoch = accountEpoch
        let expectedSessionID = await sessions.current()?.sessionId
        await pushRegistrations.reset(accountID: accountID, provider: provider)
        guard let expectedSessionID,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: accountID,
                sessionID: expectedSessionID
              )
        else { return }
        // Token invalidation is a background cleanup signal. A future Apple token replay will
        // repair transient failures, so it must never replace a user's actionable foreground error.
        _ = try? await APIClientSessionBinding.$sessionID.withValue(expectedSessionID) {
            try await api.unregisterPushToken(provider: provider)
        }
    }

    func refreshKYC() async {
        guard isSignedIn, isOnline,
              let expectedSessionID = await sessions.current()?.sessionId
        else { return }
        kycRequestGeneration &+= 1
        let expectedGeneration = kycRequestGeneration
        do {
            let status = try await api.kycStatus()
            guard await kycRequestIsCurrent(
                generation: expectedGeneration,
                sessionID: expectedSessionID
            ) else { return }
            kycStatus = status
            // KYC can change financial_access without changing the legacy assurance fields.
            // Re-read the scoped decision before enabling any wallet action.
            let assurance = try await api.sessionAssurance()
            guard await kycRequestIsCurrent(
                generation: expectedGeneration,
                sessionID: expectedSessionID
            ) else { return }
            sessionAssurance = assurance
            if let currentProfile = profile {
                accountSetupStep = AccountSetupPolicy.reconcile(
                    accountSetupStep,
                    with: currentProfile,
                    assurance: assurance
                )
            }
        } catch {
            guard await kycRequestIsCurrent(
                generation: expectedGeneration,
                sessionID: expectedSessionID
            ) else { return }
            lastError = error.localizedDescription
        }
    }

    func startKYC() async -> URL? {
        guard !rejectAppReviewDemoMutation() else { return nil }
        guard isSignedIn else {
            lastError = APIClientError.signedOut.localizedDescription
            return nil
        }
        guard isOnline else {
            lastError = "Connect to the internet to start identity verification."
            return nil
        }
        guard let expectedSessionID = await sessions.current()?.sessionId else {
            lastError = APIClientError.signedOut.localizedDescription
            return nil
        }
        kycRequestGeneration &+= 1
        let expectedGeneration = kycRequestGeneration
        do {
            let status = try await api.createKYCSession(
                consent: true,
                privacyNoticeVersion: KitLegalConstants.privacyNoticeVersion
            )
            guard await kycRequestIsCurrent(
                generation: expectedGeneration,
                sessionID: expectedSessionID
            ) else { return nil }
            kycStatus = status
            guard let url = KYCVerificationURLPolicy.validatedURL(
                from: status.providerSession?.verificationURL
            ) else {
                throw KYCUIError.invalidVerificationURL
            }
            return url
        } catch {
            guard await kycRequestIsCurrent(
                generation: expectedGeneration,
                sessionID: expectedSessionID
            ) else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    private func kycRequestIsCurrent(generation: UInt64, sessionID: String) async -> Bool {
        guard isSignedIn, kycRequestGeneration == generation else { return false }
        return await sessions.current()?.sessionId == sessionID
    }

    private func terminateCall(
        id: String,
        kind: CallTerminationKind,
        reason: String?
    ) async {
        guard appReviewDemoMutationsAllowed,
              !isReadOnlyAppReviewDemoCall(id)
        else {
            lastError = AppReviewDemoMutationPolicy.readOnlyMessage
            return
        }
        if callOwnsActiveMedia(callID: id) {
            declineWaitingCallAfterActiveCallTermination()
        }
        guard !isSigningOut,
              isSignedIn,
              let expectedUserID = profile?.id
        else { return }
        let expectedAccountEpoch = accountEpoch
        guard let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else { return }
        locallyTerminatedCallIds.insert(id.lowercased())
        let endedAt = Date()
        do {
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                if let index = persisted.calls.firstIndex(where: {
                    $0.id.caseInsensitiveCompare(id) == .orderedSame
                }) {
                    persisted.calls[index].state = kind == .decline ? .declined : .completed
                    persisted.calls[index].endedAt = endedAt
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            lastError = error.localizedDescription
        }

        guard isOnline || !hasConnectivityStatus else {
            await enqueueTermination(
                callId: id,
                kind: kind,
                reason: reason,
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            )
            return
        }

        do {
            let result: CallDTO
            switch kind {
            case .decline:
                result = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.declineCall(id: id)
                }
            case .end:
                result = try await APIClientSessionBinding.$sessionID.withValue(
                    expectedSessionID
                ) {
                    try await api.endCall(id: id, reason: reason ?? "cancelled")
                }
            }
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            let mappedResult = mapCall(result)
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                persisted.outbox.removeAll {
                    $0.kind == .callTermination
                        && $0.callId?.caseInsensitiveCompare(id) == .orderedSame
                }
                persisted.calls = CallLifecyclePolicy.mergeHistory(
                    remote: [mappedResult],
                    local: persisted.calls
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            if CallLifecyclePolicy.isIdempotentTerminationFailure(error, kind: kind) {
                await acknowledgeTermination(
                    callId: id,
                    kind: kind,
                    suppressingErrorMessage: error.localizedDescription,
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                )
            } else {
                await enqueueTermination(
                    callId: id,
                    kind: kind,
                    reason: reason,
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                )
            }
        }
    }

    private func acknowledgeTermination(
        callId: String,
        kind: CallTerminationKind,
        suppressingErrorMessage terminalErrorMessage: String,
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        do {
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                OutboxPolicy.acknowledgeTermination(
                    callId: callId,
                    kind: kind,
                    in: &persisted,
                    at: Date()
                )
            }
            if lastError == terminalErrorMessage { lastError = nil }
        } catch is CancellationError {
            return
        } catch {
            // The server operation is already terminal, but a local persistence failure remains
            // actionable and must not be disguised as a successful durable reconciliation.
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            lastError = error.localizedDescription
        }
    }

    private func acknowledgeReplayedTermination(
        command: OfflineCommand,
        callId: String,
        kind: CallTerminationKind,
        suppressingErrorMessage terminalErrorMessage: String,
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        do {
            state = try await commitOutboxMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID,
                command: command
            ) { persisted in
                OutboxPolicy.acknowledgeTermination(
                    callId: callId,
                    kind: kind,
                    in: &persisted,
                    at: Date()
                )
            }
            if lastError == terminalErrorMessage { lastError = nil }
        } catch is CancellationError {
            return
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            lastError = error.localizedDescription
        }
    }

    private func enqueueTermination(
        callId: String,
        kind: CallTerminationKind,
        reason: String?,
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        guard UUID(uuidString: callId) != nil,
              await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
              )
        else { return }
        let now = Date()
        let command = OfflineCommand(
            id: UUID(),
            kind: .callTermination,
            createdAt: now,
            nextAttemptAt: now,
            attemptCount: 0,
            conversationId: nil,
            messageId: nil,
            recipientUserIds: nil,
            recipientName: nil,
            video: nil,
            expiresAt: nil,
            callId: callId.lowercased(),
            terminationKind: kind,
            terminationReason: reason
        )
        do {
            state = try await commitAuthenticatedMutation(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) { persisted in
                let alreadyQueued = persisted.outbox.contains {
                    $0.kind == .callTermination
                        && $0.callId?.caseInsensitiveCompare(callId) == .orderedSame
                }
                if !alreadyQueued { persisted.outbox.append(command) }
                if let index = persisted.calls.firstIndex(where: {
                    $0.id.caseInsensitiveCompare(callId) == .orderedSame
                }) {
                    persisted.calls[index].state = kind == .decline ? .declined : .completed
                    persisted.calls[index].endedAt = persisted.calls[index].endedAt ?? now
                }
            }
            scheduleOutboxWake()
        } catch is CancellationError {
            return
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            lastError = error.localizedDescription
        }
    }

    private func markCallFailed(_ callId: String) async {
        guard !isSigningOut, isSignedIn, let expectedUserID = profile?.id else { return }
        let expectedAccountEpoch = accountEpoch
        guard let expectedSessionID = await sessions.current()?.sessionId else { return }
        state = (try? await commitAuthenticatedMutation(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) { persisted in
            if let index = persisted.calls.firstIndex(where: {
                $0.id.caseInsensitiveCompare(callId) == .orderedSame
            }) {
                persisted.calls[index].state = .failed
                persisted.calls[index].endedAt = Date()
            }
        }) ?? state
    }

    private func markCallMissed(_ callId: String) async {
        guard !isSigningOut, isSignedIn, let expectedUserID = profile?.id else { return }
        let expectedAccountEpoch = accountEpoch
        guard let expectedSessionID = await sessions.current()?.sessionId else { return }
        state = (try? await commitAuthenticatedMutation(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) { persisted in
            if let index = persisted.calls.firstIndex(where: {
                $0.id.caseInsensitiveCompare(callId) == .orderedSame
            }) {
                persisted.calls[index].state = .missed
                persisted.calls[index].direction = "missed"
                persisted.calls[index].endedAt = Date()
            }
        }) ?? state
        rebuildCallContacts()
    }

    private func rebuildCallContacts(remote: [WalletContactDTO]? = nil) {
        // Lifecycle updates should add call-history options without discarding
        // the API directory already loaded for this session. Passing an
        // explicit empty array still clears remote contacts authoritatively.
        let remoteContacts = (remote ?? contactDirectory).filter { contact in
            if let userID = ContactRecipientDirectory.recipientUserId(for: contact) {
                return communicationPrivacyAllowsOutbound(to: userID)
            }
            return contact.isKitUser != true
        }
        callContacts = CallLifecyclePolicy.contactOptions(
            remote: remoteContacts,
            history: state.calls.filter { !isReadOnlyAppReviewDemoCall($0.id) },
            context: phoneIdentityContext,
            excludingUserId: profile?.id,
            remoteAlreadyOrdered: true
        ).filter { !$0.isKitUser || communicationPrivacyAllowsOutbound(to: $0.id) }
    }

    private func failedMessageRetryContext(
        conversationID rawConversationID: String,
        recipientUserID rawRecipientUserID: String?
    ) -> (userID: String, conversationID: String, recipientUserID: String)? {
        guard appReviewDemoMutationsAllowed,
              let rawUserID = profile?.id,
              let userUUID = UUID(
                  uuidString: rawUserID.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              let conversationID = OutboxPolicy.canonicalConversationID(rawConversationID),
              !isReadOnlyAppReviewDemoConversation(conversationID),
              let rawRecipientUserID,
              let recipientUUID = UUID(
                  uuidString: rawRecipientUserID.trimmingCharacters(in: .whitespacesAndNewlines)
              )
        else { return nil }
        let userID = userUUID.uuidString.lowercased()
        let recipientUserID = recipientUUID.uuidString.lowercased()
        guard userID != recipientUserID,
              communicationPrivacyAllowsOutbound(to: recipientUserID)
        else { return nil }
        return (userID, conversationID, recipientUserID)
    }

    /// A group conversation has no single recipient to validate, so its retry is gated by the
    /// group capability and this device's own membership instead. v1 group policy mirrors the
    /// flush gate: per-member privacy is a server concern. Only a retained command can be
    /// resumed this way — a group send that left no command behind is not re-derived locally.
    private func retainedGroupMessageRetry(
        _ messageID: UUID,
        conversationID rawConversationID: String
    ) -> (userID: String, conversationID: String, recipientUserIDs: [String])? {
        guard appReviewDemoMutationsAllowed,
              messagingGroupLocalQueueEnabled,
              let rawUserID = profile?.id,
              let userUUID = UUID(
                  uuidString: rawUserID.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              let conversationID = OutboxPolicy.canonicalConversationID(rawConversationID),
              !isReadOnlyAppReviewDemoConversation(conversationID),
              let conversation = state.conversations.first(where: {
                  $0.id.caseInsensitiveCompare(conversationID) == .orderedSame
              }),
              conversation.isGroup,
              OutboxPolicy.canRetryMessage(messageID, in: state.outbox)
        else { return nil }
        let userID = userUUID.uuidString.lowercased()
        let commands = state.outbox.filter {
            $0.kind == .secureMessage && $0.messageId == messageID
        }
        guard conversation.participantUserIds.contains(where: {
                  $0.caseInsensitiveCompare(userID) == .orderedSame
              }),
              commands.count == 1,
              commands[0].conversationId == conversationID,
              let recipientUserIDs = commands[0].recipientUserIds,
              !recipientUserIDs.isEmpty,
              recipientUserIDs.count < SecureMessagingWire.maximumGroupMembers
        else { return nil }
        return (userID, conversationID, recipientUserIDs)
    }

    private func resumeRetainedGroupMessage(
        _ messageID: UUID,
        context: (userID: String, conversationID: String, recipientUserIDs: [String])
    ) async {
        let expectedAccountEpoch = accountEpoch
        guard let commitAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
            forAccountID: context.userID
        ), let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
                  accountEpoch: expectedAccountEpoch,
                  userID: context.userID,
                  sessionID: expectedSessionID,
                  commitAdmission: commitAdmission
              )
        else { return }
        do {
            try await store.update(admission: commitAdmission) { persisted in
                let commands = persisted.outbox.filter {
                    $0.kind == .secureMessage && $0.messageId == messageID
                }
                guard persisted.profile?.id.caseInsensitiveCompare(context.userID)
                        == .orderedSame,
                      persisted.communicationOwnerUserID?.caseInsensitiveCompare(
                          context.userID
                      ) == .orderedSame,
                      commands.count == 1,
                      commands[0].conversationId == context.conversationID,
                      commands[0].recipientUserIds == context.recipientUserIDs,
                      OutboxPolicy.resumeFailedMessage(
                          messageID: messageID,
                          in: &persisted,
                          at: Date()
                      )
                else { throw CancellationError() }
            }
            guard await reloadOutboxStateIfCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: context.userID,
                sessionID: expectedSessionID
            ) else { return }
            scheduleOutboxWake()
            if isOnline { await flushOutbox(reportFailures: true) }
        } catch is CancellationError {
            return
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: context.userID,
                sessionID: expectedSessionID
            ) else { return }
            lastError = error.localizedDescription
        }
    }

    func canRetryMessage(
        _ messageID: UUID,
        conversationID: String,
        recipientUserID: String?
    ) -> Bool {
        if retainedGroupMessageRetry(messageID, conversationID: conversationID) != nil {
            return true
        }
        guard let context = failedMessageRetryContext(
            conversationID: conversationID,
            recipientUserID: recipientUserID
        ) else { return false }

        let commands = state.outbox.filter {
            $0.kind == .secureMessage && $0.messageId == messageID
        }
        if OutboxPolicy.canRetryMessage(messageID, in: state.outbox) {
            guard commands.count == 1,
                  commands[0].conversationId == context.conversationID,
                  commands[0].recipientUserIds == [context.recipientUserID]
            else { return false }
            return true
        }

        guard secureMessagingLocalQueueAvailable else { return false }
        // A failed KITMEDIA2 send — pending batch or sealed descriptor — retries only through
        // the media path, which restores the whole batch under the same client message ID.
        // The text path would send the caption alone and split the message; its own validator
        // refuses every media shape, so this dispatch is what gives v2 a working affordance.
        if let failed = state.messages.first(where: { $0.id == messageID }),
           failed.pendingMediaBatch != nil
               || KitMediaMessageV2Descriptor.parse(failed.body) != nil {
            return SecureMessagingExchangeCoordinator.canRetryFailedMediaMessage(
                in: state,
                messageID: messageID,
                userID: context.userID,
                conversationID: context.conversationID,
                expectedRecipientUserID: context.recipientUserID
            )
        }
        return SecureMessagingExchangeCoordinator.canRetryFailedTextMessage(
            in: state,
            messageID: messageID,
            userID: context.userID,
            conversationID: context.conversationID,
            recipientUserID: context.recipientUserID
        )
    }

    func retryFailedMessage(
        _ messageID: UUID,
        conversationID: String,
        recipientUserID: String?
    ) async {
        if let group = retainedGroupMessageRetry(messageID, conversationID: conversationID) {
            await resumeRetainedGroupMessage(messageID, context: group)
            return
        }
        guard let context = failedMessageRetryContext(
            conversationID: conversationID,
            recipientUserID: recipientUserID
        ), canRetryMessage(
            messageID,
            conversationID: context.conversationID,
            recipientUserID: context.recipientUserID
        ) else { return }
        let expectedAccountEpoch = accountEpoch
        guard let commitAdmission = ProtectedCommunicationAdmissionGate.shared.lease(
            forAccountID: context.userID
        ), let expectedSessionID = await sessions.current()?.sessionId,
              await outboxContextIsCurrent(
                  accountEpoch: expectedAccountEpoch,
                  userID: context.userID,
                  sessionID: expectedSessionID,
                  commitAdmission: commitAdmission
              )
        else { return }

        let resumesRetainedCommand = OutboxPolicy.canRetryMessage(
            messageID,
            in: state.outbox
        )
        do {
            if resumesRetainedCommand {
                try await store.update(admission: commitAdmission) { persisted in
                    let commands = persisted.outbox.filter {
                        $0.kind == .secureMessage && $0.messageId == messageID
                    }
                    guard persisted.profile?.id.caseInsensitiveCompare(context.userID)
                            == .orderedSame,
                          persisted.communicationOwnerUserID?.caseInsensitiveCompare(
                              context.userID
                          ) == .orderedSame,
                          commands.count == 1,
                          commands[0].conversationId == context.conversationID,
                          commands[0].recipientUserIds == [context.recipientUserID],
                          OutboxPolicy.resumeFailedMessage(
                              messageID: messageID,
                              in: &persisted,
                              at: Date()
                          )
                    else { throw CancellationError() }
                }
            } else {
                guard secureMessagingLocalQueueAvailable else { return }
                // Same dispatch as `canRetryMessage`: a v2 projection may only ride the media
                // retry, which re-queues the entire batch — never its caption as text.
                let failed = state.messages.first(where: { $0.id == messageID })
                if failed?.pendingMediaBatch != nil
                    || failed.map({ KitMediaMessageV2Descriptor.parse($0.body) != nil }) == true {
                    _ = try await SecureMessagingExchangeCoordinator.shared
                        .retryFailedMediaMessage(
                            messageID: messageID,
                            forUserID: context.userID,
                            conversationID: context.conversationID,
                            expectedRecipientUserID: context.recipientUserID,
                            commitAdmission: commitAdmission
                        )
                } else {
                    _ = try await SecureMessagingExchangeCoordinator.shared
                        .retryFailedTextMessage(
                            messageID: messageID,
                            forUserID: context.userID,
                            conversationID: context.conversationID,
                            expectedRecipientUserID: context.recipientUserID,
                            commitAdmission: commitAdmission
                        )
                }
            }
            guard await reloadOutboxStateIfCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: context.userID,
                sessionID: expectedSessionID
            ) else { return }
            scheduleOutboxWake()
            if isOnline { await flushOutbox(reportFailures: true) }
        } catch is CancellationError {
            return
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: context.userID,
                sessionID: expectedSessionID
            ) else { return }
            lastError = error.localizedDescription
        }
    }

    private func handleOutboxFailure(
        _ command: OfflineCommand,
        error: Error,
        reportFailure: Bool,
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        guard await outboxContextIsCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { return }
        let reason = error.localizedDescription
        do {
            switch OutboxPolicy.failureDecision(for: error) {
            case .retry(let retryAfter):
                state = try await commitOutboxMutation(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID,
                    command: command
                ) { persisted in
                    let now = Date()
                    OutboxPolicy.scheduleRetry(
                        for: command,
                        in: &persisted,
                        at: now,
                        retryAfter: retryAfter
                    )
                    if let messageID = command.messageId,
                       let index = persisted.messages.firstIndex(where: { $0.id == messageID }) {
                        LocalMediaRecordPolicy.markRetryPending(
                            &persisted.messages[index],
                            now: now
                        )
                    }
                }
            case .awaitSession:
                state = try await commitOutboxMutation(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID,
                    command: command
                ) { persisted in
                    let now = Date()
                    OutboxPolicy.markAwaitingSession(
                        for: command,
                        reason: reason,
                        in: &persisted
                    )
                    if let messageID = command.messageId,
                       let index = persisted.messages.firstIndex(where: { $0.id == messageID }) {
                        LocalMediaRecordPolicy.markRetryPending(
                            &persisted.messages[index],
                            now: now
                        )
                    }
                }
            case .awaitIdentityRefresh:
                state = try await commitOutboxMutation(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID,
                    command: command
                ) { persisted in
                    let now = Date()
                    OutboxPolicy.markAwaitingIdentityRefresh(
                        for: command,
                        reason: reason,
                        in: &persisted
                    )
                    if let messageID = command.messageId,
                       let index = persisted.messages.firstIndex(where: { $0.id == messageID }) {
                        LocalMediaRecordPolicy.markRetryPending(
                            &persisted.messages[index],
                            now: now
                        )
                    }
                }
            case .unchanged:
                guard await reloadOutboxStateIfCurrent(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID
                ) else { return }
            case .permanent:
                state = try await commitOutboxMutation(
                    accountEpoch: expectedAccountEpoch,
                    userID: expectedUserID,
                    sessionID: expectedSessionID,
                    command: command
                ) { persisted in
                    OutboxPolicy.markPermanentFailure(
                        for: command,
                        reason: reason,
                        in: &persisted
                    )
                    if let messageID = command.messageId,
                       let index = persisted.messages.firstIndex(where: { $0.id == messageID }) {
                        LocalMediaRecordPolicy.markUploadFailed(&persisted.messages[index])
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard await outboxContextIsCurrent(
                accountEpoch: expectedAccountEpoch,
                userID: expectedUserID,
                sessionID: expectedSessionID
            ) else { return }
            if reportFailure { lastError = error.localizedDescription }
            return
        }
        if reportFailure, !(error is CancellationError) { lastError = reason }
    }

    /// A KITMEDIA2 send that failed because the world moved — blobs expired or the recipient
    /// roster changed — was already rewritten in place by the coordinator under the same
    /// command and client message IDs: batch reopened and pending body restored for expiry,
    /// fanout cleared for a roster change. Reload that fresh persisted truth, then hand retry
    /// bookkeeping ONLY the freshly resolved command value: `commitOutboxMutation` proves
    /// whole-value outbox containment, so this pass's captured pre-mutation command — stale
    /// fanout included — would silently cancel the retry instead of scheduling it.
    private func handleRecoverableMediaMessageFailure(
        _ command: OfflineCommand,
        error: SecureMessagingExchangeError,
        reportFailure: Bool,
        accountEpoch expectedAccountEpoch: UUID,
        userID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        guard await reloadOutboxStateIfCurrent(
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        ) else { return }
        // Full stable identity, uniquely resolved: exactly one fresh command carrying the same
        // command ID, secure kind, the same non-nil message projection, and the same
        // conversation. Zero matches means retry/user/session work already replaced this send;
        // more than one means a corrupted outbox — fail closed and touch nothing rather than
        // reschedule whichever duplicate happens to come back first.
        let freshMatches = state.outbox.filter {
            $0.id == command.id
                && $0.kind == .secureMessage
                && $0.messageId != nil
                && $0.messageId == command.messageId
                && $0.conversationId == command.conversationId
        }
        guard freshMatches.count == 1, let freshCommand = freshMatches.first else { return }
        await handleOutboxFailure(
            freshCommand,
            error: error,
            reportFailure: reportFailure,
            accountEpoch: expectedAccountEpoch,
            userID: expectedUserID,
            sessionID: expectedSessionID
        )
    }

    private func drainReadyOutbox(maximumPasses: Int = 32) async {
        guard appReviewDemoMutationsAllowed else { return }
        for _ in 0 ..< maximumPasses {
            guard !Task.isCancelled else { return }
            let before = state.outbox
            guard !OutboxPolicy.readyCommands(before, at: Date()).isEmpty else { return }
            await flushOutbox()
            if state.outbox == before { return }
        }
    }

    private func scheduleOutboxWake() {
        outboxWakeTask?.cancel()
        outboxWakeTask = nil
        guard appReviewDemoMutationsAllowed else {
            CommunicationBackgroundReplayScheduler.shared.cancel()
            return
        }
        let now = Date()
        let outboxBackgroundWakeDate = CommunicationBackgroundReplayPolicy.earliestBeginDate(
            for: state.outbox,
            now: now
        )
        let hydrationBackgroundWakeDate = hasPendingReceivedMediaHydration
            ? now.addingTimeInterval(MediaHydrationPolicy.retryDelay)
            : nil
        let preprocessingBackgroundWakeDate = hasPendingMediaPreprocessing
            ? now.addingTimeInterval(30)
            : nil
        guard let backgroundWakeDate = [
            outboxBackgroundWakeDate,
            hydrationBackgroundWakeDate,
            preprocessingBackgroundWakeDate,
        ]
            .compactMap({ $0 }).min()
        else {
            CommunicationBackgroundReplayScheduler.shared.cancel()
            return
        }
        CommunicationBackgroundReplayScheduler.shared.schedule(
            earliestBeginDate: backgroundWakeDate
        )
        guard isOnline,
              isSignedIn,
              !isSigningOut,
              !isSubmittingAccountDeletion,
              !acceptedAccountDeletionCleanupBlocked,
              !protectedLocalStateRecoveryBlocked,
              !unresolvedAccountDeletionAttemptBlocked,
              let wakeDate = OutboxPolicy.nextWakeDate(state.outbox)
        else { return }

        let expectedAccountEpoch = accountEpoch
        outboxWakeTask = Task { @MainActor [weak self] in
            let delay = max(0, wakeDate.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.accountEpoch == expectedAccountEpoch,
                  self.isOnline,
                  self.isSignedIn
            else { return }
            self.outboxWakeTask = nil
            await self.flushOutbox()
        }
    }

    private func deviceRegistration() -> DeviceRegistration {
        let info = Bundle.main.infoDictionary
        return DeviceRegistration(
            installationId: installationID(),
            name: UIDevice.current.name,
            appVersion: APIClientIdentity.appVersion(
                marketingVersion: info?["CFBundleShortVersionString"] as? String,
                buildNumber: info?["CFBundleVersion"] as? String
            ),
            osVersion: UIDevice.current.systemVersion,
            model: UIDevice.current.model
        )
    }

    private func installationID() -> String {
        let installationAccount = "kit-pay-installation-id"
        if let data = try? KeychainStore.data(for: installationAccount),
           let value = String(data: data, encoding: .utf8),
           UUID(uuidString: value) != nil {
            return value.lowercased()
        }
        let value = UUID().uuidString.lowercased()
        try? KeychainStore.set(Data(value.utf8), for: installationAccount)
        return value
    }
}

@MainActor
final class CommunicationBackgroundReplayScheduler {
    static let shared = CommunicationBackgroundReplayScheduler()
    static let identifier = "africa.kit.pay.ios.communication-replay"

    private var handler: ((BGProcessingTask) -> Void)?
    private var pendingTask: BGProcessingTask?
    private var armedEarliestBeginDate: Date?

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: .main
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.armedEarliestBeginDate = nil
            if let handler = self?.handler {
                handler(processingTask)
            } else {
                self?.pendingTask = processingTask
            }
        }
    }

    func installHandler(_ handler: @escaping (BGProcessingTask) -> Void) {
        self.handler = handler
        if let pendingTask {
            self.pendingTask = nil
            handler(pendingTask)
        }
    }

    @discardableResult
    func schedule(
        earliestBeginDate: Date,
        submit: (BGProcessingTaskRequest) throws -> Void = {
            try BGTaskScheduler.shared.submit($0)
        }
    ) -> CommunicationBackgroundReplayScheduleState {
        // Keep an already-armed task when the replacement would be no earlier. Submitting first
        // also means a failed attempt to improve the window cannot erase the only durable wake
        // for a scheduled message.
        if let armedEarliestBeginDate,
           armedEarliestBeginDate <= earliestBeginDate {
            return .armed(earliestBeginDate: armedEarliestBeginDate)
        }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = earliestBeginDate
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try submit(request)
            armedEarliestBeginDate = earliestBeginDate
            return .armed(earliestBeginDate: earliestBeginDate)
        } catch {
            if let armedEarliestBeginDate {
                return .armed(earliestBeginDate: armedEarliestBeginDate)
            }
            return .submissionFailed
        }
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        armedEarliestBeginDate = nil
    }
}

enum CommunicationBackgroundReplayScheduleState: Equatable, Sendable {
    case armed(earliestBeginDate: Date)
    case submissionFailed
}

enum MessageBackupBackgroundTransitionPolicy {
    static func shouldAttempt(
        isSignedIn: Bool,
        setupComplete: Bool,
        isOnline: Bool,
        frequency: MessageBackupFrequency,
        messageCount: Int
    ) -> Bool {
        isSignedIn
            && setupComplete
            && isOnline
            && frequency != .off
            && messageCount > 0
    }
}

enum KitBiometricGateState: Equatable {
    case notRequired
    case locked
    case authorizing
    case authorized
}

private enum KitBiometricPurpose {
    case returningSignIn
    case home
    case paymentRequest

    func reason(using kind: KitBiometricKind) -> String {
        switch self {
        case .returningSignIn:
            "Use \(kind.displayName) to sign in to Kit Pay"
        case .home:
            "Use \(kind.displayName) to view your wallet and payments"
        case .paymentRequest:
            "Use \(kind.displayName) to send this payment request"
        }
    }
}

private enum MainTabIndex {
    static let home = 0
    static let messages = 1
}

/// A reviewable build-time latch in addition to server protocol discovery. Build 5 enables the
/// encrypted path for TestFlight validation; server flags still cannot enable an unreviewed wire.
enum SecureMessagingReleaseGate {
    static let enabled = true
}

/// Local queueing is deliberately independent of capability discovery. Capture/selection has
/// already produced an app-owned original, and the protected outbox is not a network boundary.
/// The dispatcher revalidates the authenticated server and device-roster contracts before any
/// ciphertext upload or fanout; an unavailable/withdrawn contract therefore leaves the exact
/// local message pending instead of making the composer wait for the network.
enum SecureMessagingLocalQueueReleasePolicy {
    static func permits(buildEnabled: Bool) -> Bool {
        buildEnabled
    }
}

struct SecureMessagingRemoteWake: Sendable {
    let notificationID: UUID

    init?(_ object: Any?) {
        guard let payload = object as? [AnyHashable: Any],
              payload["type"] as? String == "messaging.sync",
              payload["scope"] as? String == "messaging",
              let rawNotificationID = payload["notification_id"] as? String,
              let notificationID = UUID(uuidString: rawNotificationID),
              let aps = payload["aps"] as? [AnyHashable: Any],
              (aps["content-available"] as? NSNumber)?.intValue == 1,
              aps.count == 1,
              aps.keys.allSatisfy({ ($0 as? String) == "content-available" }),
              payload.count == 4,
              Set(payload.keys.compactMap { $0 as? String }) == Set([
                  "type", "scope", "notification_id", "aps",
              ])
        else { return nil }
        self.notificationID = notificationID
    }
}

private func mapCall(_ dto: CallDTO, stateOverride: CallState? = nil) -> CallRecord {
    CallRecord(
        id: dto.id,
        name: dto.name?.isEmpty == false ? dto.name! : "Kit Pay user",
        participantUserIds: dto.participantUserIds ?? [],
        direction: dto.direction,
        type: dto.type,
        video: dto.isVideoCall,
        state: stateOverride ?? CallLifecyclePolicy.mappedState(dto.state),
        // Invalid server timestamps must never make an old call appear to have happened "now".
        startedAt: CallLifecyclePolicy.serverTimestamp(dto.startedAt)
            ?? Date(timeIntervalSince1970: 0),
        endedAt: CallLifecyclePolicy.serverTimestamp(dto.endedAt),
        isDeferredAttempt: false,
        conversationId: dto.conversationId,
        answeredAt: CallLifecyclePolicy.serverTimestamp(dto.answeredAt),
        participantIdentities: CallParticipantIdentityPolicy.validated(
            dto.participants,
            matching: dto.participantUserIds
        )
    )
}

private func emailAccountValidationMessage(
    _ error: EmailAccountValidationError,
    reset: Bool = false
) -> String {
    switch error {
    case .invalidNameLength:
        "Enter a display name (2–120 characters)."
    case .placeholderName:
        "Choose the display name people should see."
    case .invalidTagLength:
        "Your username must be 3 to 32 characters."
    case .provisionalTag:
        "Choose your own username."
    case .reservedTag:
        "This username is reserved."
    case .invalidTagCharacters:
        "Use only lowercase letters, numbers, and underscores in your username."
    case .invalidEmail:
        "Enter a valid email address."
    case .weakPassword:
        "Use at least 12 characters with uppercase, lowercase, and a number."
    case .passwordMismatch:
        "The passwords do not match."
    case .invalidToken:
        reset
            ? "Paste the complete reset token from your email."
            : "Paste the complete verification token from your email."
    }
}

enum AuthUIError: LocalizedError {
    case missingChallenge, missingSession, missingUser, invalidResponse, staleResponse
    case localDiagnosticsCleanupFailed
    var errorDescription: String? {
        switch self {
        case .missingChallenge: "Kit did not return an OTP challenge."
        case .missingSession: "Sign-in completed without a usable session."
        case .missingUser: "Sign-in completed without a usable profile."
        case .invalidResponse: "Kit returned an invalid authentication response. Start again."
        case .staleResponse: "That sign-in request is no longer active. Start again."
        case .localDiagnosticsCleanupFailed:
            "Protected data from the prior session could not be cleared. Restart and try again."
        }
    }
}

enum AccountSetupError: LocalizedError {
    case accountChanged, profileStillRequired, pinNotEnabled, sessionNotUnlocked

    var errorDescription: String? {
        switch self {
        case .accountChanged: "The profile response belongs to another account. Sign in again."
        case .profileStillRequired: "Profile setup is still required after saving the profile."
        case .pinNotEnabled: "The wallet PIN was not enabled."
        case .sessionNotUnlocked: "Kit Pay could not confirm this session unlock. Try again."
        }
    }
}

enum CallQueueError: LocalizedError {
    case invalidRTC
    case unexpectedCall

    var errorDescription: String? {
        switch self {
        case .invalidRTC: "Kit returned invalid call credentials."
        case .unexpectedCall: "Kit returned a different call than the one requested."
        }
    }
}

enum KYCUIError: LocalizedError {
    case invalidVerificationURL
    var errorDescription: String? { "Kit returned an invalid identity-verification link." }
}
