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
