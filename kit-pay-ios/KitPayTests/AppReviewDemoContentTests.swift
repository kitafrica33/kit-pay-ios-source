import Foundation
import XCTest
@testable import KitPay

final class AppReviewDemoContentTests: XCTestCase {
    private let ownerID = "10000000-0000-4000-8000-000000000001"
    private let sessionID = "20000000-0000-4000-8000-000000000001"

    func testPublicCapabilityResponseCannotActivateReviewContent() {
        XCTAssertNil(
            AppReviewDemoAccessPolicy.ownerID(
                features: [AppReviewDemoAccessPolicy.featureKey: true],
                authority: .publicDiscovery,
                isSignedIn: true,
                profileID: ownerID,
                sessionID: sessionID,
                sessionAccountID: ownerID
            )
        )
    }

    func testMissingSessionCannotActivateReviewContent() {
        XCTAssertNil(
            AppReviewDemoAccessPolicy.ownerID(
                features: [AppReviewDemoAccessPolicy.featureKey: true],
                authority: .authenticatedSession,
                isSignedIn: true,
                profileID: ownerID,
                sessionID: nil,
                sessionAccountID: ownerID
            )
        )
    }

    func testMismatchedSessionAndProfileCannotActivateReviewContent() {
        XCTAssertNil(
            AppReviewDemoAccessPolicy.ownerID(
                features: [AppReviewDemoAccessPolicy.featureKey: true],
                authority: .authenticatedSession,
                isSignedIn: true,
                profileID: ownerID,
                sessionID: sessionID,
                sessionAccountID: "10000000-0000-4000-8000-000000000002"
            )
        )
    }

    func testMatchingAuthenticatedSessionAndFlagActivateReviewContent() {
        XCTAssertEqual(
            AppReviewDemoAccessPolicy.ownerID(
                features: [AppReviewDemoAccessPolicy.featureKey: true],
                authority: .authenticatedSession,
                isSignedIn: true,
                profileID: ownerID.uppercased(),
                sessionID: sessionID,
                sessionAccountID: ownerID
            ),
            ownerID
        )
    }

    func testProjectionChangesOnlyExplicitCommunicationPreviewFields() throws {
        let original = financialState()
        let projected = AppReviewDemoContent.projectedState(
            from: original,
            authenticatedOwnerID: ownerID,
            now: Date(timeIntervalSince1970: 1_777_176_000),
            calendar: Calendar(identifier: .gregorian)
        )

        var originalJSON = try jsonObject(original)
        var projectedJSON = try jsonObject(projected)
        let allowedProjectionFields = [
            "conversations", "messages", "calls", "pinnedConversationIds",
        ]
        for field in allowedProjectionFields {
            originalJSON.removeValue(forKey: field)
            projectedJSON.removeValue(forKey: field)
        }
        XCTAssertEqual(originalJSON as NSDictionary, projectedJSON as NSDictionary)
        XCTAssertEqual(projected.wallets, original.wallets)
        XCTAssertEqual(projected.selectedWalletId, original.selectedWalletId)
        XCTAssertEqual(projected.transactions, original.transactions)
        XCTAssertEqual(projected.profile, original.profile)
    }

    func testSyntheticIdentifiersAreRecognizedCaseInsensitively() {
        XCTAssertTrue(
            AppReviewDemoContent.isSyntheticConversationID(
                "D1000000-0000-4000-8000-000000000001"
            )
        )
        XCTAssertTrue(
            AppReviewDemoContent.isSyntheticCallID(
                "D2000000-0000-4000-8000-000000000005"
            )
        )
        XCTAssertTrue(
            AppReviewDemoContent.isSyntheticPeerID(
                "D0000000-0000-4000-8000-000000000001"
            )
        )
        XCTAssertFalse(
            AppReviewDemoContent.isSyntheticConversationID(
                "30000000-0000-4000-8000-000000000001"
            )
        )
    }

    func testOnlyProvisionedAminaPreviewCanAdvertiseAccountReporting() {
        XCTAssertTrue(
            AppReviewDemoContent.isProvisionedReportingTarget(
                conversationID: "D1000000-0000-4000-8000-000000000001",
                peerID: "D0000000-0000-4000-8000-000000000001"
            )
        )
        XCTAssertFalse(
            AppReviewDemoContent.isProvisionedReportingTarget(
                conversationID: "d1000000-0000-4000-8000-000000000002",
                peerID: "d0000000-0000-4000-8000-000000000002"
            )
        )
        XCTAssertFalse(
            AppReviewDemoContent.isProvisionedReportingTarget(
                conversationID: "d1000000-0000-4000-8000-000000000001",
                peerID: "d0000000-0000-4000-8000-000000000002"
            )
        )
        XCTAssertFalse(
            AppReviewDemoContent.isProvisionedReportingTarget(
                conversationID: "d1000000-0000-4000-8000-000000000001",
                peerID: nil
            )
        )
    }

    func testDemoAccountPolicyBlocksEveryAccountMutation() {
        XCTAssertFalse(
            AppReviewDemoMutationPolicy.allowsAccountMutation(
                isSignedIn: true,
                hasAuthenticatedCapabilities: true,
                isDemoActive: true
            )
        )
        XCTAssertTrue(
            AppReviewDemoMutationPolicy.allowsAccountMutation(
                isSignedIn: true,
                hasAuthenticatedCapabilities: true,
                isDemoActive: false
            )
        )
        XCTAssertFalse(
            AppReviewDemoMutationPolicy.allowsAccountMutation(
                isSignedIn: true,
                hasAuthenticatedCapabilities: false,
                isDemoActive: false
            )
        )
        XCTAssertFalse(
            AppReviewDemoMutationPolicy.allowsAccountMutation(
                isSignedIn: false,
                hasAuthenticatedCapabilities: true,
                isDemoActive: false
            )
        )
    }

    func testSyntheticRowsRemainReadOnlyAfterCapabilityWithdrawalUntilProjectionIsGone() {
        XCTAssertTrue(
            AppReviewDemoMutationPolicy.conversationIsReadOnly(
                "d1000000-0000-4000-8000-000000000001",
                isDemoActive: false
            )
        )
        XCTAssertTrue(
            AppReviewDemoMutationPolicy.callIsReadOnly(
                "d2000000-0000-4000-8000-000000000001",
                isDemoActive: false
            )
        )
        XCTAssertTrue(
            AppReviewDemoMutationPolicy.peerIsReadOnly(
                "d0000000-0000-4000-8000-000000000001",
                isDemoActive: false
            )
        )
    }

    func testAuthenticatedDemoTransportAllowsReadsAndRequiredCleanupOnly() {
        XCTAssertTrue(
            AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                method: "GET",
                path: "wallets",
                isDemoSession: true
            )
        )
        XCTAssertTrue(
            AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                method: "POST",
                path: "auth/refresh",
                isDemoSession: true
            )
        )
        XCTAssertTrue(
            AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                method: "POST",
                path: "auth/logout",
                isDemoSession: true
            )
        )
        XCTAssertTrue(
            AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                method: "DELETE",
                path: "devices/current/push-token?provider=apns",
                isDemoSession: true
            )
        )
    }

    func testAuthenticatedDemoTransportBlocksAllFeatureWrites() {
        let writes = [
            ("POST", "messaging/messages"),
            ("POST", "messaging/realtime/auth"),
            ("POST", "messaging/conversations/one/typing"),
            ("POST", "calls"),
            ("POST", "wallets/one/transfers"),
            ("POST", "mobile-money/payouts"),
            ("POST", "banking/transfers"),
            ("PATCH", "communication/preferences"),
            ("POST", "contacts/sync"),
            ("PATCH", "profile"),
            ("POST", "media/upload-intents"),
        ]
        for (method, path) in writes {
            XCTAssertFalse(
                AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                    method: method,
                    path: path,
                    isDemoSession: true
                ),
                "Unexpectedly allowed \(method) \(path)"
            )
            XCTAssertTrue(
                AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                    method: method,
                    path: path,
                    isDemoSession: false
                ),
                "Normal accounts must retain \(method) \(path)"
            )
        }
    }

    func testAuthenticatedDemoTransportCleanupExceptionsRequireExactMethods() {
        let mismatches = [
            ("DELETE", AbuseReportAPIEndpoint.path),
            ("PATCH", "auth/logout"),
            ("DELETE", "auth/refresh"),
            ("POST", "devices/current/push-token"),
        ]
        for (method, path) in mismatches {
            XCTAssertFalse(
                AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                    method: method,
                    path: path,
                    isDemoSession: true
                ),
                "Unexpectedly allowed \(method) \(path)"
            )
        }
    }

    func testDemoAbuseReportExceptionIsExactProvisionedPairOnly() {
        XCTAssertTrue(
            AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                method: "POST",
                path: AbuseReportAPIEndpoint.path,
                isDemoSession: true
            )
        )
        XCTAssertTrue(
            AppReviewDemoMutationPolicy.allowsAbuseReport(
                conversationID: "d1000000-0000-4000-8000-000000000001",
                reportedUserID: "d0000000-0000-4000-8000-000000000001",
                isDemoSession: true
            )
        )
        XCTAssertFalse(
            AppReviewDemoMutationPolicy.allowsAbuseReport(
                conversationID: "d1000000-0000-4000-8000-000000000002",
                reportedUserID: "d0000000-0000-4000-8000-000000000002",
                isDemoSession: true
            )
        )
    }

    func testCapabilityFailureRetainsOwnerAndTransportFence() {
        let decision = AppReviewDemoCapabilityFenceDecision.failed(
            previousOwnerID: ownerID
        )
        XCTAssertEqual(decision.projectedOwnerID, ownerID)
        XCTAssertTrue(decision.keepsTransportFenceAfterProjection)

        let unresolved = AppReviewDemoCapabilityFenceDecision.failed(previousOwnerID: nil)
        XCTAssertNil(unresolved.projectedOwnerID)
        XCTAssertTrue(unresolved.keepsTransportFenceAfterProjection)
    }

    func testSuccessfulFlagWithdrawalUnarmsOnlyAfterNilProjectionDecision() {
        let enabled = AppReviewDemoCapabilityFenceDecision.resolved(ownerID: ownerID)
        XCTAssertEqual(enabled.projectedOwnerID, ownerID)
        XCTAssertTrue(enabled.keepsTransportFenceAfterProjection)

        let withdrawn = AppReviewDemoCapabilityFenceDecision.resolved(ownerID: nil)
        XCTAssertNil(withdrawn.projectedOwnerID)
        XCTAssertFalse(withdrawn.keepsTransportFenceAfterProjection)
    }

    func testScopedReadOnlyAccessAlsoAuthenticatesTheReviewFence() {
        let communication = SessionCommunicationAccessDTO(
            allowed: true,
            basis: "app_review",
            requiredAction: nil
        )
        let financial = SessionFinancialAccessDTO(
            allowed: true,
            basis: "app_review",
            requiredAction: nil,
            readOnly: true
        )

        XCTAssertEqual(
            AppReviewDemoAccessPolicy.scopedOwnerID(
                communicationAccess: communication,
                financialAccess: financial,
                authority: .authenticatedSession,
                isSignedIn: true,
                profileID: ownerID,
                sessionID: sessionID,
                sessionAccountID: ownerID
            ),
            ownerID
        )
        XCTAssertNil(AppReviewDemoAccessPolicy.scopedOwnerID(
            communicationAccess: communication,
            financialAccess: SessionFinancialAccessDTO(
                allowed: true,
                basis: "app_review",
                requiredAction: nil,
                readOnly: false
            ),
            authority: .authenticatedSession,
            isSignedIn: true,
            profileID: ownerID,
            sessionID: sessionID,
            sessionAccountID: ownerID
        ))
    }

    func testTransportFenceRemainsBoundAcrossRefreshForSameSessionID() async {
        let api = APIClient(sessionStore: SessionStore())
        await api.setAppReviewDemoReadOnly(true, sessionID: sessionID.uppercased())
        let sameSessionStillProtected = await api.appReviewDemoReadOnlyApplies(
            to: sessionID
        )
        let replacementSessionProtected = await api.appReviewDemoReadOnlyApplies(
            to: "20000000-0000-4000-8000-000000000002"
        )
        XCTAssertTrue(sameSessionStillProtected)
        XCTAssertFalse(replacementSessionProtected)
    }

    func testStaleCapabilityCompletionCannotReplaceOrClearReplacementSessionFence() async {
        let api = APIClient(sessionStore: SessionStore())
        let replacementSessionID = "20000000-0000-4000-8000-000000000002"
        await api.setAppReviewDemoReadOnly(true, sessionID: replacementSessionID)
        await api.setAppReviewDemoReadOnly(true, sessionID: sessionID)
        let replacementFenceSurvivedStaleArm = await api.appReviewDemoReadOnlyApplies(
            to: replacementSessionID
        )
        XCTAssertTrue(replacementFenceSurvivedStaleArm)

        await api.setAppReviewDemoReadOnly(false, sessionID: sessionID)
        let replacementFenceSurvived = await api.appReviewDemoReadOnlyApplies(
            to: replacementSessionID
        )
        XCTAssertTrue(replacementFenceSurvived)

        await api.setAppReviewDemoReadOnly(false, sessionID: replacementSessionID.uppercased())
        let replacementFenceCleared = await api.appReviewDemoReadOnlyApplies(
            to: replacementSessionID
        )
        XCTAssertFalse(replacementFenceCleared)
    }

    private func financialState() -> PersistedState {
        var state = PersistedState.empty
        state.profile = UserProfile(
            id: ownerID,
            name: "App Reviewer",
            email: nil,
            phone: "+256700000099",
            tag: "app_review",
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: false,
            profileSetupRequired: false
        )
        state.communicationOwnerUserID = ownerID
        state.wallets = [
            Wallet(
                id: "30000000-0000-4000-8000-000000000001",
                name: "Primary wallet",
                accountNumber: "0000000000",
                accountType: "personal",
                currency: CurrencyDTO(code: "UGX", scale: "2"),
                balances: WalletBalances(available: "1234.00", ledger: "1234.00"),
                status: "active",
                isPrimary: true
            ),
        ]
        state.selectedWalletId = state.wallets[0].id
        state.transactions = [
            WalletTransaction(
                id: "40000000-0000-4000-8000-000000000001",
                walletId: state.wallets[0].id,
                reference: "APP-REVIEW-PRESERVED",
                amount: "50.00",
                currency: CurrencyDTO(code: "UGX", scale: "2"),
                type: "internal_transfer",
                direction: "credit",
                status: "completed",
                counterparty: nil,
                note: "Must remain unchanged",
                occurredAt: "2026-08-24T10:00:00Z"
            ),
        ]
        return state
    }

    private func jsonObject(_ state: PersistedState) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                as? [String: Any]
        )
    }
}
