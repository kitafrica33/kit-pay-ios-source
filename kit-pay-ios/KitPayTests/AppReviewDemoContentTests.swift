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
