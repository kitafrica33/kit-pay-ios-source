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
        for path in [
            "auth/session-unlock/pin",
            "auth/session-unlock/biometric/challenge",
            "auth/session-unlock/biometric/assert",
        ] {
            XCTAssertTrue(AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                method: "POST", path: path, isDemoSession: true
            ), "The server must be able to verify the reviewer's login proof at \(path)")
        }
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
            ("POST", "auth/step-up/challenges"),
            ("POST", "auth/step-up/challenges/one/verify"),
            ("PUT", "auth/payment-pin"),
            ("PUT", "devices/current/biometric-key"),
            ("DELETE", "devices/current/biometric-key"),
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

    func testAuthenticatedDemoTransportUnlockExceptionsRequireExactRoutesAndMethods() {
        let unlockPaths = [
            "auth/session-unlock/pin",
            "auth/session-unlock/biometric/challenge",
            "auth/session-unlock/biometric/assert",
        ]
        for path in unlockPaths {
            for method in ["PUT", "PATCH", "DELETE"] {
                XCTAssertFalse(AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                    method: method, path: path, isDemoSession: true
                ), "Unlock exception must not allow \(method) \(path)")
            }
            for modifiedPath in [path + "/extra", path + "-admin", "prefix/" + path] {
                XCTAssertFalse(AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                    method: "POST", path: modifiedPath, isDemoSession: true
                ), "Unlock exception must not allow \(modifiedPath)")
            }
        }
        for path in ["auth/session-unlock", "auth/session-unlock/biometric/enroll"] {
            XCTAssertFalse(AppReviewDemoMutationPolicy.allowsAuthenticatedRequest(
                method: "POST", path: path, isDemoSession: true
            ))
        }
    }

    func testReviewPINUnlockReachesServerAndAdmitsReadOnlyApp() async throws {
        try await withReviewTransport(responses: [
            "auth/session-unlock/pin": .init(body: unlockResponse(method: "pin")),
        ]) { api, _, tokens, transport in
            let profile = try XCTUnwrap(financialState().profile)
            XCTAssertEqual(AccountSetupPolicy.initialStep(
                afterAuthentication: profile, assurance: nil
            ), .loginUnlock)

            let result = try await APIClientSessionBinding.$sessionID.withValue(tokens.sessionId) {
                try await api.unlockSession(pin: "2468")
            }

            let request = try XCTUnwrap(transport.requests.first)
            XCTAssertEqual(transport.requests.count, 1)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/kit-wallet/v1/auth/session-unlock/pin")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer review-test-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Kit-Wallet-Session-ID"), tokens.sessionId)
            XCTAssertEqual(try JSONSerialization.jsonObject(
                with: XCTUnwrap(transport.requestBodies.first)
            ) as? [String: String], ["pin": "2468"])
            XCTAssertEqual(result.method, "pin")
            XCTAssertTrue(result.sessionAssurance.grantsFullAccess)
            XCTAssertNil(AccountSetupPolicy.reconcile(
                .loginUnlock, with: profile, assurance: result.sessionAssurance
            ))
            // The same server-confirmed projection must also restore without manufacturing a
            // new PIN requirement merely because this account's wallet is read-only.
            XCTAssertNil(AccountSetupPolicy.restoredStep(
                user: profile, assurance: result.sessionAssurance
            ))
            XCTAssertEqual(result.sessionAssurance.financialAccess?.readOnly, true)
            XCTAssertEqual(MoneyActionAccessPolicy.requirement(
                identityVerified: true,
                sessionGrantsFullAccess: result.sessionAssurance.grantsFullAccess,
                scopedCommunication: result.sessionAssurance.communicationAccess,
                scopedFinancial: result.sessionAssurance.financialAccess
            ), .readOnly)
            try await assertReviewWritesStayBlocked(api, sessionID: tokens.sessionId)
            XCTAssertEqual(transport.requests.count, 1, "No feature write may reach the server")
        }
    }

    func testReviewPINRejectionPreservesLoginGateAndReadOnlyFence() async throws {
        let rejection = Data(#"{"ok":false,"error":{"code":"INVALID_LOGIN_PIN","message":"The PIN is incorrect."}}"#.utf8)
        try await withReviewTransport(responses: [
            "auth/session-unlock/pin": .init(status: 401, body: rejection),
        ]) { api, store, tokens, transport in
            do {
                _ = try await APIClientSessionBinding.$sessionID.withValue(tokens.sessionId) {
                    try await api.unlockSession(pin: "0000")
                }
                XCTFail("An invalid PIN must not unlock the session")
            } catch let error as APIErrorPayload {
                XCTAssertEqual(error.code, "INVALID_LOGIN_PIN")
                XCTAssertEqual(error.httpStatus, 401)
            }
            XCTAssertEqual(transport.requests.map(\.url?.lastPathComponent), ["pin"],
                           "One incorrect PIN must consume only one server verification attempt")
            let current = await store.current()
            XCTAssertEqual(current, tokens, "An incorrect PIN must not rotate or discard the session")
            XCTAssertEqual(AccountSetupPolicy.restoredStep(
                user: financialState().profile, assurance: nil
            ), .loginUnlock)
            try await assertReviewWritesStayBlocked(api, sessionID: tokens.sessionId)
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testReviewPINUnlockRefreshesExpiredCredentialsWithoutLosingFence() async throws {
        let expired = Data(#"{"ok":false,"error":{"code":"ACCESS_TOKEN_EXPIRED","message":"The access token expired."}}"#.utf8)
        try await withReviewTransport(responses: [
            "auth/session-unlock/pin": .init(status: 401, body: expired),
        ], includingRefresh: true, refreshedResponses: [
            "auth/session-unlock/pin": .init(body: unlockResponse(method: "pin")),
        ]) { api, store, tokens, transport in
            let result = try await APIClientSessionBinding.$sessionID.withValue(tokens.sessionId) {
                try await api.unlockSession(pin: "2468")
            }
            XCTAssertEqual(transport.requests.map(\.url?.lastPathComponent), ["pin", "refresh", "pin"])
            XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"),
                           "Bearer review-test-access")
            XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"),
                           "Bearer review-test-access-rotated")
            let refreshed = await store.current()
            XCTAssertEqual(refreshed?.sessionId, tokens.sessionId)
            XCTAssertEqual(refreshed?.accountId, tokens.accountId)
            XCTAssertEqual(refreshed?.accessToken, "review-test-access-rotated")
            XCTAssertTrue(result.sessionAssurance.grantsFullAccess)
            let profile = try XCTUnwrap(financialState().profile)
            XCTAssertNil(AccountSetupPolicy.reconcile(
                .loginUnlock, with: profile, assurance: result.sessionAssurance
            ))
            XCTAssertEqual(result.sessionAssurance.financialAccess?.readOnly, true)
            try await assertReviewWritesStayBlocked(api, sessionID: tokens.sessionId)
            XCTAssertEqual(transport.requests.count, 3)
        }
    }

    func testReviewBiometricUnlockReachesServerWithoutGrantingMutations() async throws {
        try await withReviewTransport(responses: [
            "auth/session-unlock/biometric/challenge": .init(status: 201, body: biometricChallengeResponse),
            "auth/session-unlock/biometric/assert": .init(body: unlockResponse(method: "biometric_signature")),
        ]) { api, _, tokens, transport in
            let challenge = try await APIClientSessionBinding.$sessionID.withValue(tokens.sessionId) {
                try await api.createLoginBiometricChallenge()
            }
            let result = try await APIClientSessionBinding.$sessionID.withValue(tokens.sessionId) {
                try await api.assertLoginBiometricChallenge(
                    challengeId: challenge.challengeId, nonce: challenge.nonce,
                    signature: "test-signature"
                )
            }
            XCTAssertEqual(transport.requests.map(\.url?.lastPathComponent), ["challenge", "assert"])
            XCTAssertTrue(transport.requests.allSatisfy {
                $0.httpMethod == "POST"
                    && $0.value(forHTTPHeaderField: "X-Kit-Wallet-Session-ID") == tokens.sessionId
            })
            XCTAssertEqual(try JSONSerialization.jsonObject(
                with: XCTUnwrap(transport.requestBodies.last)
            ) as? [String: String], [
                "challenge_id": "40000000-0000-4000-8000-000000000001", "nonce": "nonce-one",
                "signature": "test-signature",
            ])
            XCTAssertEqual(result.method, "biometric_signature")
            let profile = try XCTUnwrap(financialState().profile)
            XCTAssertNil(AccountSetupPolicy.reconcile(
                .loginUnlock, with: profile,
                assurance: result.sessionAssurance
            ))
            try await assertReviewWritesStayBlocked(api, sessionID: tokens.sessionId)
            XCTAssertEqual(transport.requests.count, 2)
        }
    }

    func testReviewBiometricRejectionPreservesSessionWithoutReplayingProof() async throws {
        let rejection = Data(#"{"ok":false,"error":{"code":"BIOMETRIC_ASSERTION_INVALID","message":"The biometric signature is invalid."}}"#.utf8)
        try await withReviewTransport(responses: [
            "auth/session-unlock/biometric/challenge": .init(status: 201, body: biometricChallengeResponse),
            "auth/session-unlock/biometric/assert": .init(status: 401, body: rejection),
        ]) { api, store, tokens, transport in
            let challenge = try await APIClientSessionBinding.$sessionID.withValue(tokens.sessionId) {
                try await api.createLoginBiometricChallenge()
            }
            do {
                _ = try await APIClientSessionBinding.$sessionID.withValue(tokens.sessionId) {
                    try await api.assertLoginBiometricChallenge(
                        challengeId: challenge.challengeId, nonce: challenge.nonce,
                        signature: "test-invalid-signature"
                    )
                }
                XCTFail("A rejected biometric proof must not unlock the session")
            } catch let error as APIErrorPayload {
                XCTAssertEqual(error.code, "BIOMETRIC_ASSERTION_INVALID")
                XCTAssertEqual(error.httpStatus, 401)
            }
            XCTAssertEqual(transport.requests.map(\.url?.lastPathComponent), ["challenge", "assert"],
                           "A rejected proof must consume only one verification attempt")
            let current = await store.current()
            XCTAssertEqual(current, tokens)
            XCTAssertEqual(AccountSetupPolicy.restoredStep(
                user: financialState().profile, assurance: nil
            ), .loginUnlock)
            try await assertReviewWritesStayBlocked(api, sessionID: tokens.sessionId)
            XCTAssertEqual(transport.requests.count, 2)
        }
    }

    func testReviewUnlockRejectsReplacedSessionBeforeSending() async throws {
        try await withReviewTransport(responses: [:]) { api, store, tokens, transport in
            let replacement = SessionTokens(
                accessToken: "replacement-access", refreshToken: "replacement-refresh",
                tokenType: "Bearer", accessExpiresAt: nil, refreshExpiresAt: nil,
                sessionId: UUID().uuidString.lowercased(),
                accountId: "10000000-0000-4000-8000-000000000002"
            )
            try await store.save(replacement)
            do {
                _ = try await APIClientSessionBinding.$sessionID.withValue(tokens.sessionId) {
                    try await api.unlockSession(pin: "2468")
                }
                XCTFail("An old PIN attempt must not borrow a replacement account's session")
            } catch let error as APIClientError {
                guard case .signedOut = error else {
                    return XCTFail("Expected session binding rejection, got \(error)")
                }
            }
            XCTAssertTrue(transport.requests.isEmpty)
            let current = await store.current()
            XCTAssertEqual(current, replacement)
            let remainsFenced = await api.appReviewDemoReadOnlyApplies(to: tokens.sessionId)
            XCTAssertTrue(remainsFenced)
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

    private func withReviewTransport(
        responses: [String: AppReviewUnlockTransportState.Response],
        includingRefresh: Bool = false,
        refreshedResponses: [String: AppReviewUnlockTransportState.Response] = [:],
        operation: (APIClient, SessionStore, SessionTokens, AppReviewUnlockTransportState) async throws -> Void
    ) async throws {
        let namespace = "review-unlock-test-\(UUID().uuidString)"
        let store = SessionStore(account: namespace, refreshAttemptAccount: namespace + "-refresh")
        let tokens = SessionTokens(
            accessToken: "review-test-access", refreshToken: "review-test-refresh",
            tokenType: "Bearer", accessExpiresAt: nil, refreshExpiresAt: nil,
            sessionId: UUID().uuidString.lowercased(), accountId: ownerID
        )
        var responses = responses
        if includingRefresh {
            let refreshed = SessionTokens(
                accessToken: "review-test-access-rotated", refreshToken: "review-test-refresh-rotated",
                tokenType: "Bearer", accessExpiresAt: nil, refreshExpiresAt: nil,
                sessionId: tokens.sessionId, accountId: tokens.accountId
            )
            let sessionObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(refreshed))
            responses["auth/refresh"] = .init(body: try JSONSerialization.data(withJSONObject: [
                "ok": true, "data": ["state": "authenticated", "session": sessionObject],
            ]))
        }
        let transport = AppReviewUnlockTransportState(
            responses: responses, refreshedResponses: refreshedResponses
        )
        AppReviewUnlockURLProtocol.register(transport, sessionID: tokens.sessionId)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppReviewUnlockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            AppReviewUnlockURLProtocol.unregister(sessionID: tokens.sessionId)
            try? KeychainStore.remove(namespace)
            try? KeychainStore.remove(namespace + "-refresh")
        }
        try await store.save(tokens)
        let api = APIClient(sessionStore: store, session: session)
        // This is the same API fence AppModel arms before publishing a signed-in session and
        // keeps after the authenticated capabilities identify a read-only review account.
        await api.setAppReviewDemoReadOnly(true, sessionID: tokens.sessionId)
        try await operation(api, store, tokens, transport)
    }

    private func assertReviewWritesStayBlocked(_ api: APIClient, sessionID: String) async throws {
        let remainsFenced = await api.appReviewDemoReadOnlyApplies(to: sessionID)
        XCTAssertTrue(remainsFenced, "Successful authentication must not lift the review fence")
        for (method, path) in [
            ("POST", "wallets/one/transfers"),
            ("POST", "auth/step-up/challenges"),
            ("PUT", "auth/payment-pin"),
            ("PATCH", "profile"),
            ("POST", "messaging/messages"),
        ] {
            do {
                let _: SessionUnlockResultDTO = try await api.send(
                    path: path, method: method, body: [String: String](), boundSessionID: sessionID
                )
                XCTFail("Unexpectedly admitted \(method) \(path)")
            } catch let error as AppReviewDemoMutationError {
                XCTAssertEqual(error, .readOnly)
            }
        }
    }

    private func unlockResponse(method: String) -> Data {
        Data("""
        {"ok":true,"data":{"method":"\(method)","session_assurance":{
          "device_identity":{"status":"verified","required":false,"epoch":1},
          "login_unlock":{"status":"unlocked","required":false,"method":"\(method)","methods":["pin","biometric_signature"]},
          "access":"full",
          "communication_access":{"allowed":true,"basis":"app_review","required_action":null},
          "financial_access":{"allowed":true,"basis":"app_review","required_action":null,"read_only":true}
        }}}
        """.utf8)
    }

    private var biometricChallengeResponse: Data {
        Data(#"{"ok":true,"data":{"challenge_id":"40000000-0000-4000-8000-000000000001","nonce":"nonce-one","signing_payload":"server-proof","expires_at":"2026-09-09T13:00:00Z"}}"#.utf8)
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
                totals: CustomerTransactionTotals(added: "50.00", deducted: "0"),
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

/// Routes each test by its unique session ID. Requests never reach a live service, and parallel
/// tests cannot borrow another test's response or credentials.
private final class AppReviewUnlockURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var states: [String: AppReviewUnlockTransportState] = [:]
    }
    private static let registry = Registry()

    static func register(_ state: AppReviewUnlockTransportState, sessionID: String) {
        registry.lock.withLock { registry.states[sessionID] = state }
    }

    static func unregister(sessionID: String) {
        _ = registry.lock.withLock { registry.states.removeValue(forKey: sessionID) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let sessionID = request.value(forHTTPHeaderField: "X-Kit-Wallet-Session-ID"),
              let state = Self.registry.lock.withLock({ Self.registry.states[sessionID] }),
              let url = request.url
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        state.record(request)
        guard let stub = state.response(for: request),
              let response = HTTPURLResponse(
                url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AppReviewUnlockTransportState: @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        let body: Data
    }
    let responses: [String: Response]
    let refreshedResponses: [String: Response]
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var bodies: [Data] = []

    init(responses: [String: Response], refreshedResponses: [String: Response]) {
        self.responses = responses
        self.refreshedResponses = refreshedResponses
    }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var requestBodies: [Data] { lock.withLock { bodies } }

    func response(for request: URLRequest) -> Response? {
        guard let path = request.url?.path.replacingOccurrences(of: "/api/kit-wallet/v1/", with: "")
        else { return nil }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer review-test-access-rotated",
           let response = refreshedResponses[path] {
            return response
        }
        return responses[path]
    }

    func record(_ request: URLRequest) {
        // URLSession may expose POST bytes as a stream to URLProtocol even though APIClient
        // supplied httpBody. Read that stream while the request is active.
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while body.count <= 16 * 1_024 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        lock.withLock {
            recorded.append(request)
            bodies.append(body)
        }
    }
}
