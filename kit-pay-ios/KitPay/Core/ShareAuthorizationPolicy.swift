import Foundation

/// Owner directive, 2026-09-21: **biometric verification exists for payments, not for chats.**
/// Sending a photo or a link from the system share sheet is a chat action, so it must work
/// whenever the account is signed in — with the app locked, backgrounded, or not launched at
/// all since the last reboot. An extension cannot open its containing app, cannot foreground
/// it, and must never be made to wait on a Face ID prompt the customer did not ask for.
///
/// Build 1.0.17 (105) refused every share on a signed-in handset with one sentence,
/// "Sharing is locked or your account changed. Unlock Kit Pay and share again." That string
/// was `MessagingProcessBroker.Failure.accountChanged`, and **six different conditions** all
/// produced it: no authority, no session, a durable denial, sharing not enabled, a missing
/// recipient directory, and a session the sheet had already captured being replaced. Two of
/// those six were consequences of the app's own UI lock. This policy is the replacement: the
/// decision has no biometric, no app-lock, no app-foreground and no device-unlock input, and
/// each refusal carries its own sentence so the next report names a condition.
///
/// Foundation only, no Keychain, no UIKit: it compiles and runs under a stock Linux toolchain
/// (`.github/scripts/tests/run_share_authorization_linux_gate.sh`) as well as inside
/// `KitPayTests`, so the regression is provable without a Mac.
enum ShareAuthorizationPolicy {

    /// Why the share sheet may not continue. Each case is one customer sentence.
    enum Refusal: String, Equatable, Sendable, CaseIterable, Codable {
        /// No stored authority, or one with no usable account/session: nobody is signed in.
        case signedOut
        /// A durable refusal written by sign-out, privacy withdrawal or account deletion.
        /// The same write removes the recipient directory, so this is never merely a UI lock.
        case revoked
        /// Signed in, not denied, but the app has not yet published this session's recipients.
        case notPrepared
        /// The sheet captured one account/session and a different one now owns the container.
        case sessionReplaced
    }

    /// Everything the extension is allowed to consider.
    ///
    /// There is deliberately no `isAppUnlocked`, `requiresBiometricUnlock`, `isAppForegrounded`
    /// or `hasBiometricCredential` member. Re-introducing one would re-create the defect the
    /// owner reported; `ShareAuthorizationPolicyTests` asserts the shape of this type.
    struct Input: Hashable, Sendable {
        /// An authority record was decoded from the shared Keychain for this app group.
        var hasAuthority: Bool
        /// That authority carries a canonical account id and session id.
        var hasSession: Bool
        /// A `sharing.denied` marker written by a real revocation is present.
        var isHardDenied: Bool
        /// `destinations.secure` exists and its generation, account and session equal the
        /// authority's. Only the main app writes it, and a revocation deletes it, so its
        /// presence *is* the app's standing permission — no separate unlock bit is consulted.
        var hasMatchingDirectory: Bool
        /// False only when this sheet already captured a different owner on an earlier pass.
        var capturedOwnerMatches: Bool

        init(
            hasAuthority: Bool,
            hasSession: Bool,
            isHardDenied: Bool,
            hasMatchingDirectory: Bool,
            capturedOwnerMatches: Bool = true
        ) {
            self.hasAuthority = hasAuthority
            self.hasSession = hasSession
            self.isHardDenied = isHardDenied
            self.hasMatchingDirectory = hasMatchingDirectory
            self.capturedOwnerMatches = capturedOwnerMatches
        }
    }

    /// `nil` means the share may proceed.
    ///
    /// Order matters, and it is the order of how much the customer can do about it: signed out
    /// first, then a revocation, then a directory the app has not written yet, and only then a
    /// genuine account switch — which is the one and only surviving "account changed" meaning.
    static func decide(_ input: Input) -> Refusal? {
        guard input.hasAuthority, input.hasSession else { return .signedOut }
        if input.isHardDenied { return .revoked }
        guard input.hasMatchingDirectory else { return .notPrepared }
        guard input.capturedOwnerMatches else { return .sessionReplaced }
        return nil
    }

    /// The sentence the share sheet shows. None of them says "unlock": nothing on this path
    /// can be fixed by unlocking, and telling somebody to unlock an app that is already
    /// unlocked is what made build 105's report unactionable.
    static func message(for refusal: Refusal) -> String {
        switch refusal {
        case .signedOut:
            return "You are signed out of Kit Pay. Open Kit Pay, sign in, then share again."
        case .revoked:
            return "Sharing from other apps is turned off for this account. Open Kit Pay, then share again."
        case .notPrepared:
            return "Open Kit Pay once so it can list your chats here, then share again."
        case .sessionReplaced:
            return "This share belongs to a different Kit Pay account. Close this and share again."
        }
    }

    /// A refusal the customer clears by opening or re-opening Kit Pay is worth a Retry button:
    /// the container is re-read on the spot, so a share survives a mid-sheet app launch.
    static func allowsRetry(_ refusal: Refusal) -> Bool {
        switch refusal {
        case .signedOut, .revoked, .notPrepared: return true
        case .sessionReplaced: return false
        }
    }
}
