import Foundation

/// One biometric verification per foreground session, and what the screen looks like until it
/// happens.
///
/// Owner report, 1.0.17 build 105: biometric verification on the pay screen and the home screen
/// *"should verify once, and the background has to be blurred until verified successfully"*.
/// Build 105 did neither:
///
/// * Returning from the background verified the app (`returningSignIn`), then Home verified
///   *again* the moment the customer opened it if they had last been on another tab — the
///   returning proof only unlocked Home when Home happened to be the selected tab.
/// * Leaving the Home tab called `homeDidResignActive()`, which locked Home outright. Switching
///   to Messages and back was a second Face ID. A customer moving between chats and their wallet
///   paid for a prompt every time.
/// * Sending a payment request always prompted, however recently the same face had been checked.
/// * Home did not blur anything: it *replaced* its content with the gate, so the balances were
///   simply absent, and the swap between the two was visible.
///
/// Verification is bound to three things at once, because any one of them changing must void it:
/// the foreground session (a trip through the background ends the proof — this is the existing
/// `applicationDidEnterBackgroundSecurely` rule, not a new one), the account epoch (a sign-out,
/// a sign-in or a session change re-mints it) and the user id. A stale value can therefore never
/// authorise the next account's wallet.
///
/// Pure Foundation, no SwiftUI: exercised on Linux by
/// `.github/scripts/tests/run_foreground_verification_linux_gate.sh`.
enum ForegroundVerificationPolicy {
    /// A successful local-authentication proof, and what it was a proof *of*.
    struct Verification: Equatable {
        /// Incremented every time the app enters the background.
        let foregroundEpoch: UInt64
        /// `AppModel.accountEpoch` at the moment of the proof.
        let accountEpoch: UUID
        /// The signed-in user the proof belongs to.
        let userID: String

        init(foregroundEpoch: UInt64, accountEpoch: UUID, userID: String) {
            self.foregroundEpoch = foregroundEpoch
            self.accountEpoch = accountEpoch
            self.userID = userID
        }
    }

    /// Whether `verification` still speaks for the current foreground session and account.
    ///
    /// A nil `userID` — no profile loaded — is never verified: there is no one for the proof to
    /// be about.
    static func isVerified(
        _ verification: Verification?,
        foregroundEpoch: UInt64,
        accountEpoch: UUID,
        userID: String?
    ) -> Bool {
        guard let verification, let userID, !userID.isEmpty else { return false }
        return verification.foregroundEpoch == foregroundEpoch
            && verification.accountEpoch == accountEpoch
            && verification.userID.caseInsensitiveCompare(userID) == .orderedSame
    }

    /// Whether a surface must raise a fresh biometric prompt.
    ///
    /// With app unlock switched off there is nothing to prompt for, which is why this answers
    /// `false` rather than deferring to the (absent) verification.
    static func requiresPrompt(
        unlockEnabled: Bool,
        verification: Verification?,
        foregroundEpoch: UInt64,
        accountEpoch: UUID,
        userID: String?
    ) -> Bool {
        guard unlockEnabled else { return false }
        return !isVerified(
            verification,
            foregroundEpoch: foregroundEpoch,
            accountEpoch: accountEpoch,
            userID: userID
        )
    }

    // MARK: Presentation

    /// Enough to make a balance, a name and an amount unreadable at arm's length. Paired with a
    /// privacy redaction, not relied on alone: a blur is a reversible transform of the pixels it
    /// was given, and a screen recording of one is not a safe place to keep an account number.
    static let blurRadius: Double = 28

    static func blurRadius(isVerified: Bool) -> Double {
        isVerified ? 0 : blurRadius
    }

    /// Unverified content is inert: no taps, no scrolling, no VoiceOver. A blurred balance the
    /// customer can still tap through to is not a gate.
    static func contentIsInteractive(isVerified: Bool) -> Bool { isVerified }

    /// Sensitive text is replaced, not merely softened, while the gate is up.
    static func contentIsRedacted(isVerified: Bool) -> Bool { !isVerified }

    /// How long the blur takes to change, in seconds.
    ///
    /// This is the "no flash of unblurred content" rule, written as arithmetic so a test can hold
    /// it: **locking is instantaneous and unlocking is animated.** An animation applied to the
    /// locking direction would render intermediate frames of a clear balance on the way down —
    /// which is exactly the flash the owner must never see — while animating the way up is only a
    /// pleasant reveal after the proof has already succeeded.
    static func animationDuration(wasVerified: Bool, isVerified: Bool) -> Double {
        guard isVerified, !wasVerified else { return 0 }
        return 0.25
    }
}
