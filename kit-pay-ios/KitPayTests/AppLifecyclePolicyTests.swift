import Foundation
import XCTest
@testable import KitPay

/// Decisions the app makes about network path updates and reconnect work.
final class AppLifecyclePolicyTests: XCTestCase {
    func testFirstSatisfiedPathUpdateIsTreatedAsARecovery() {
        XCTAssertEqual(
            ConnectivityTransitionPolicy.transition(previousOnline: nil, isOnline: true),
            .recovered
        )
    }

    func testFirstUnsatisfiedPathUpdateReportsTheLoss() {
        XCTAssertEqual(
            ConnectivityTransitionPolicy.transition(previousOnline: nil, isOnline: false),
            .lost
        )
    }

    /// `NWPathMonitor` republishes `.satisfied` whenever the path changes at all — a second
    /// interface appearing, a VPN attaching, expensive/constrained status flipping. Each repeat
    /// used to re-run capabilities, bootstrap, wallets, transactions, call history, push-token
    /// replay and a contact sync.
    func testRepeatedSatisfiedPathUpdatesDoNotRepeatReconnectWork() {
        XCTAssertEqual(
            ConnectivityTransitionPolicy.transition(previousOnline: true, isOnline: true),
            .unchanged
        )
    }

    func testRepeatedUnsatisfiedPathUpdatesDoNotRepeatSuspension() {
        XCTAssertEqual(
            ConnectivityTransitionPolicy.transition(previousOnline: false, isOnline: false),
            .unchanged
        )
    }

    func testReconnectionAfterALossStillRunsRecoveryWork() {
        XCTAssertEqual(
            ConnectivityTransitionPolicy.transition(previousOnline: false, isOnline: true),
            .recovered
        )
    }

    func testLosingConnectivityAfterBeingOnlineSuspendsNetworkWork() {
        XCTAssertEqual(
            ConnectivityTransitionPolicy.transition(previousOnline: true, isOnline: false),
            .lost
        )
    }

    func testSingleMediaOutboxFenceRejectsSignOutDuringSessionLookup() async throws {
        let userID = "10000000-0000-4000-8000-000000000201"
        let sessionID = "20000000-0000-4000-8000-000000000201"
        let expectedEpoch = UUID(uuidString: "30000000-0000-4000-8000-000000000201")!
        let lifetime = LockedOutboxLifetime(epoch: expectedEpoch)
        let lookup = SuspendedOutboxSessionLookup(
            session: testSession(userID: userID, sessionID: sessionID)
        )

        let validation = Task { @MainActor in
            await OutboxContextRevalidator.validate(
                localContextIsCurrent: { lifetime.matches(expectedEpoch) },
                loadCurrentSession: { await lookup.load() },
                sessionIsCurrent: {
                    $0.sessionId == sessionID && $0.accountId == userID
                }
            )
        }
        try await lookup.waitUntilStarted()

        // performSignOut rotates AppModel.accountEpoch before its first awaited cleanup and only
        // quarantines the protected-store gate later. A matching old SessionStore result must not
        // revive the send during that window.
        lifetime.rotate()
        await lookup.release()

        let accepted = await validation.value
        XCTAssertFalse(accepted)
    }

    func testMediaBatchOutboxFenceRejectsSameUserReplacementLeaseDuringSessionLookup() async throws {
        let userID = "10000000-0000-4000-8000-000000000202"
        let sessionID = "20000000-0000-4000-8000-000000000202"
        let gate = ProtectedCommunicationAdmissionGate()
        gate.restore(forAccountID: userID)
        let staleLease = try XCTUnwrap(gate.lease(forAccountID: userID))
        defer { gate.quarantine() }
        let lookup = SuspendedOutboxSessionLookup(
            session: testSession(userID: userID, sessionID: sessionID)
        )

        let validation = Task { @MainActor in
            await OutboxContextRevalidator.validate(
                localContextIsCurrent: { gate.permits(staleLease) },
                loadCurrentSession: { await lookup.load() },
                sessionIsCurrent: {
                    $0.sessionId == sessionID && $0.accountId == userID
                }
            )
        }
        try await lookup.waitUntilStarted()

        gate.quarantine()
        gate.restore(forAccountID: userID)
        let replacementLease = try XCTUnwrap(gate.lease(forAccountID: userID))
        XCTAssertNotEqual(staleLease, replacementLease)
        await lookup.release()

        let accepted = await validation.value
        XCTAssertFalse(accepted)
    }

    func testOutboxFenceAcceptsOnlyAnUnchangedLifetimeAndMatchingSession() async {
        let userID = "10000000-0000-4000-8000-000000000203"
        let sessionID = "20000000-0000-4000-8000-000000000203"
        let session = testSession(userID: userID, sessionID: sessionID)

        let accepted = await Task { @MainActor in
            await OutboxContextRevalidator.validate(
                localContextIsCurrent: { true },
                loadCurrentSession: { session },
                sessionIsCurrent: {
                    $0.sessionId == sessionID && $0.accountId == userID
                }
            )
        }.value
        XCTAssertTrue(accepted)

        let mismatchedSessionRejected = await Task { @MainActor in
            await OutboxContextRevalidator.validate(
                localContextIsCurrent: { true },
                loadCurrentSession: { session },
                sessionIsCurrent: { $0.sessionId == "replacement-session" }
            )
        }.value
        XCTAssertFalse(mismatchedSessionRejected)
    }

    // MARK: - Foreground authoritative refresh

    func testOnlyARealBackgroundVisitRequestsForegroundRefresh() {
        var gate = ForegroundAuthoritativeRefreshGate()

        // `.inactive` -> `.active` never calls didEnterBackground().
        XCTAssertEqual(
            gate.admission(
                at: Date(timeIntervalSinceReferenceDate: 100),
                appIsActive: true,
                isOnline: true,
                sessionIsEligible: true
            ),
            .none
        )

        gate.didEnterBackground()
        XCTAssertEqual(
            gate.admission(
                at: Date(timeIntervalSinceReferenceDate: 100),
                appIsActive: true,
                isOnline: true,
                sessionIsEligible: true
            ),
            .start(generation: 1)
        )
    }

    func testConcurrentForegroundCallbacksCoalesceOntoOneGeneration() {
        var gate = ForegroundAuthoritativeRefreshGate()
        let now = Date(timeIntervalSinceReferenceDate: 100)
        gate.didEnterBackground()

        XCTAssertEqual(
            gate.admission(
                at: now,
                appIsActive: true,
                isOnline: true,
                sessionIsEligible: true
            ),
            .start(generation: 1)
        )
        XCTAssertEqual(
            gate.admission(
                at: now,
                appIsActive: true,
                isOnline: true,
                sessionIsEligible: true
            ),
            .none
        )
        gate.authoritativeRefreshDidCommit(upTo: 1)
        gate.finishAttempt(generation: 1)
        XCTAssertFalse(gate.hasPendingRefresh)
    }

    func testOfflineForegroundLeavesRefreshPendingAndRapidChurnIsThrottled() {
        var gate = ForegroundAuthoritativeRefreshGate()
        let firstStart = Date(timeIntervalSinceReferenceDate: 100)
        gate.didEnterBackground()

        XCTAssertEqual(
            gate.admission(
                at: firstStart,
                appIsActive: true,
                isOnline: false,
                sessionIsEligible: true
            ),
            .none
        )
        XCTAssertTrue(gate.hasPendingRefresh)
        XCTAssertEqual(
            gate.admission(
                at: firstStart,
                appIsActive: true,
                isOnline: true,
                sessionIsEligible: true
            ),
            .start(generation: 1)
        )
        gate.authoritativeRefreshDidCommit(upTo: 1)
        gate.finishAttempt(generation: 1)

        gate.didEnterBackground()
        XCTAssertEqual(
            gate.admission(
                at: firstStart.addingTimeInterval(2),
                appIsActive: true,
                isOnline: true,
                sessionIsEligible: true
            ),
            .wait(8)
        )
        XCTAssertTrue(gate.hasPendingRefresh)
    }

    func testTransientForegroundRefreshFailureKeepsGenerationPendingForRetry() {
        var gate = ForegroundAuthoritativeRefreshGate()
        let firstStart = Date(timeIntervalSinceReferenceDate: 100)
        gate.didEnterBackground()
        XCTAssertEqual(
            gate.admission(
                at: firstStart,
                appIsActive: true,
                isOnline: true,
                sessionIsEligible: true
            ),
            .start(generation: 1)
        )

        // No authoritativeRefreshDidCommit call: bootstrap failed transiently.
        gate.finishAttempt(generation: 1)
        XCTAssertTrue(gate.hasPendingRefresh)
        XCTAssertEqual(
            gate.admission(
                at: firstStart.addingTimeInterval(11),
                appIsActive: true,
                isOnline: true,
                sessionIsEligible: true
            ),
            .start(generation: 1)
        )
    }

    func testForegroundBootstrapReplacesAStaleCachedBalance() {
        let currency = CurrencyDTO(code: "UGX", scale: "2")
        let cachedWallet = Wallet(
            id: "wallet-1",
            name: "Kit Pay",
            accountNumber: nil,
            accountType: nil,
            currency: currency,
            balances: WalletBalances(available: "3000", ledger: "3000"),
            status: "active",
            isPrimary: true
        )
        let authoritativeWallet = Wallet(
            id: cachedWallet.id,
            name: cachedWallet.name,
            accountNumber: nil,
            accountType: nil,
            currency: currency,
            balances: WalletBalances(available: "150000", ledger: "150000"),
            status: "active",
            isPrimary: true
        )
        var state = PersistedState.empty
        state.wallets = [cachedWallet]
        state.selectedWalletId = cachedWallet.id

        state.replaceAuthoritativeWalletProjection(
            [authoritativeWallet],
            selectedWalletID: authoritativeWallet.id
        )

        XCTAssertEqual(state.wallets, [authoritativeWallet])
        XCTAssertEqual(state.wallets.first?.balances.available, "150000")
    }

    // MARK: - Inbound links

    /// A token of the shortest length the opaque-token validator accepts.
    private var validToken: String {
        String(repeating: "a", count: EmailAccountValidation.opaqueTokenLengthRange.lowerBound)
    }

    private func link(_ string: String) -> KitDeepLink? {
        guard let url = URL(string: string) else { return nil }
        return KitDeepLink.parse(url)
    }

    private func testSession(userID: String, sessionID: String) -> SessionTokens {
        SessionTokens(
            accessToken: "access",
            refreshToken: "refresh",
            tokenType: "Bearer",
            accessExpiresAt: nil,
            refreshExpiresAt: nil,
            sessionId: sessionID,
            accountId: userID
        )
    }

    func testVerificationLinkOpensTheVerificationScreenWithItsToken() {
        XCTAssertEqual(
            link("kitwallet://verify-email?token=\(validToken)"),
            .verifyEmail(token: validToken)
        )
        XCTAssertEqual(
            link("kitwallet://verify?token=\(validToken)"),
            .verifyEmail(token: validToken)
        )
        XCTAssertEqual(KitDeepLink.verifyEmail(token: validToken).screen, .verification)
    }

    func testRecoveryLinkOpensThePasswordResetScreenWithItsToken() {
        XCTAssertEqual(
            link("kitwallet://reset-password?token=\(validToken)"),
            .resetPassword(token: validToken)
        )
        XCTAssertEqual(
            link("KITWALLET://Reset?token=\(validToken)"),
            .resetPassword(token: validToken)
        )
        XCTAssertEqual(KitDeepLink.resetPassword(token: validToken).screen, .resetPassword)
    }

    func testOnlyTheKitWalletSchemeIsAccepted() {
        XCTAssertNil(link("https://pay.kit.africa/verify-email?token=\(validToken)"))
        XCTAssertNil(link("kitwallet-evil://verify-email?token=\(validToken)"))
        XCTAssertNil(link("kitpay://verify-email?token=\(validToken)"))
    }

    func testUnknownRoutesAreIgnoredRatherThanGuessedAt() {
        XCTAssertNil(link("kitwallet://send-money?token=\(validToken)"))
        XCTAssertNil(link("kitwallet://?token=\(validToken)"))
    }

    func testALinkWithoutExactlyOneUsableTokenIsRefused() {
        XCTAssertNil(link("kitwallet://verify-email"))
        XCTAssertNil(link("kitwallet://verify-email?token="))
        XCTAssertNil(link("kitwallet://verify-email?token=short"))
        // Two tokens leave it ambiguous which one the customer is about to spend.
        XCTAssertNil(
            link("kitwallet://verify-email?token=\(validToken)&token=\(validToken)")
        )
        XCTAssertNil(
            link("kitwallet://verify-email?token=\(String(repeating: "a", count: 257))")
        )
    }

    func testEmbeddedCredentialsAreRefused() {
        XCTAssertNil(link("kitwallet://user:secret@verify-email?token=\(validToken)"))
    }

    /// Anything that could render as one thing and submit as another stays out of the field.
    func testTokensOutsidePrintableASCIIAreRefused() {
        let padding = String(repeating: "a", count: 63)
        for suspect in ["\u{202E}", "\u{0430}", "\u{00A0}"] {
            let url = URL(
                string: "kitwallet://verify-email?token=\(padding + suspect)"
                    .addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
            )
            XCTAssertNil(url.flatMap(KitDeepLink.parse), "accepted \(suspect.debugDescription)")
        }
    }
}

private final class LockedOutboxLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UUID

    init(epoch: UUID) {
        self.epoch = epoch
    }

    func matches(_ expectedEpoch: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return epoch == expectedEpoch
    }

    func rotate() {
        lock.lock()
        epoch = UUID()
        lock.unlock()
    }
}

private actor SuspendedOutboxSessionLookup {
    enum Failure: Error {
        case lookupDidNotStart
    }

    private let session: SessionTokens
    private var started = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(session: SessionTokens) {
        self.session = session
    }

    func load() async -> SessionTokens? {
        started = true
        guard !released else { return session }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return session
    }

    func waitUntilStarted() async throws {
        for _ in 0..<500 {
            if started { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.lookupDidNotStart
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
