import LocalAuthentication
import XCTest
@testable import KitPay

final class BiometricAuthenticationTests: XCTestCase {
    private let validP256Point = Data([
        0x04,
        0x6B, 0x17, 0xD1, 0xF2, 0xE1, 0x2C, 0x42, 0x47,
        0xF8, 0xBC, 0xE6, 0xE5, 0x63, 0xA4, 0x40, 0xF2,
        0x77, 0x03, 0x7D, 0x81, 0x2D, 0xEB, 0x33, 0xA0,
        0xF4, 0xA1, 0x39, 0x45, 0xD8, 0x98, 0xC2, 0x96,
        0x4F, 0xE3, 0x42, 0xE2, 0xFE, 0x1A, 0x7F, 0x9B,
        0x8E, 0xE7, 0xEB, 0x4A, 0x7C, 0x0F, 0x9E, 0x16,
        0x2B, 0xCE, 0x33, 0x57, 0x6B, 0x31, 0x5E, 0xCE,
        0xCB, 0xB6, 0x40, 0x68, 0x37, 0xBF, 0x51, 0xF5,
    ])

    /// The Face ID/Touch ID sheet only shows `LAContext.localizedReason`. Reading the Secure
    /// Enclave key back does not authenticate — signing does — so a context without a reason left
    /// payment step-up and app unlock asking for biometrics with nothing said about why.
    func testAuthenticationContextCarriesTheCustomerFacingReason() {
        let reason = "Authorize this Kit Pay payment"

        let context = KitBiometricAuthenticator.makeAuthenticationContext(reason: reason)

        XCTAssertEqual(context.localizedReason, reason)
        XCTAssertEqual(context.localizedCancelTitle, "Cancel")
        XCTAssertEqual(context.localizedFallbackTitle, "")
    }

    func testAuthenticationContextsAreNotSharedBetweenPrompts() {
        let first = KitBiometricAuthenticator.makeAuthenticationContext(reason: "Unlock Kit Pay")
        let second = KitBiometricAuthenticator.makeAuthenticationContext(reason: "Send money")

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.localizedReason, "Unlock Kit Pay")
        XCTAssertEqual(second.localizedReason, "Send money")
    }

    @MainActor
    func testBiometricOperationGateRejectsReentrantAdmissionAcrossSuspension() async throws {
        var gate = BiometricAuthenticationOperationGate()
        let firstOperation = try XCTUnwrap(gate.begin())

        await Task.yield()

        XCTAssertTrue(gate.isActive)
        XCTAssertTrue(gate.owns(firstOperation))
        XCTAssertNil(gate.begin())
        XCTAssertTrue(gate.finish(firstOperation))
        XCTAssertFalse(gate.isActive)
    }

    func testStaleBiometricOwnerCannotReleaseAReplacementOperation() throws {
        var gate = BiometricAuthenticationOperationGate()
        let firstOperation = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.finish(firstOperation))

        let replacementOperation = try XCTUnwrap(gate.begin())
        XCTAssertNotEqual(firstOperation, replacementOperation)
        XCTAssertFalse(gate.finish(firstOperation))
        XCTAssertTrue(gate.owns(replacementOperation))
        XCTAssertTrue(gate.finish(replacementOperation))
    }

    func testBackgroundInvalidatesCapturedReturningSignInAuthorization() {
        var fence = ReturningSignInBiometricAuthorizationFence()
        let foregroundAttempt = fence.capture()

        XCTAssertTrue(fence.authorizes(foregroundAttempt))

        fence.invalidate()

        XCTAssertFalse(fence.authorizes(foregroundAttempt))
        XCTAssertTrue(fence.authorizes(fence.capture()))
    }

    func testReturningSignInCanAuthorizeCurrentHomeVisitWithoutASecondLease() throws {
        var returningFence = ReturningSignInBiometricAuthorizationFence()
        var homeFence = HomeBiometricAuthorizationFence()
        var gate = BiometricAuthenticationOperationGate()
        let operation = try XCTUnwrap(gate.begin())
        let returningToken = returningFence.capture()
        let homeToken = homeFence.capture()

        XCTAssertTrue(returningFence.authorizes(returningToken))
        XCTAssertTrue(homeFence.authorizes(homeToken, homeIsSelected: true))
        XCTAssertNil(gate.begin())
        XCTAssertTrue(gate.finish(operation))

        returningFence.invalidate()
        homeFence.invalidate()
        XCTAssertFalse(returningFence.authorizes(returningToken))
        XCTAssertFalse(homeFence.authorizes(homeToken, homeIsSelected: true))
    }

    func testLeavingHomeInvalidatesOnlyTheCapturedHomeAuthorization() {
        var fence = HomeBiometricAuthorizationFence()
        let firstVisit = fence.capture()

        XCTAssertTrue(fence.authorizes(firstVisit, homeIsSelected: true))
        XCTAssertFalse(fence.authorizes(firstVisit, homeIsSelected: false))

        fence.invalidate()
        XCTAssertFalse(fence.authorizes(firstVisit, homeIsSelected: true))

        let nextVisit = fence.capture()
        XCTAssertTrue(fence.authorizes(nextVisit, homeIsSelected: true))
    }

    func testFinishedHomePromptDoesNotConsumeLaterPaymentApprovalLease() throws {
        var gate = BiometricAuthenticationOperationGate()
        let homeOperation = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.finish(homeOperation))

        let paymentOperation = try XCTUnwrap(gate.begin())
        XCTAssertNotEqual(homeOperation, paymentOperation)
        XCTAssertTrue(gate.owns(paymentOperation))
    }

    func testEnrollmentIsBoundToUserAndInstallationButNotSession() {
        let enrollment = KitBiometricEnrollment(
            userID: "10000000-0000-0000-0000-000000000001",
            installationID: "30000000-0000-0000-0000-000000000001",
            kind: .faceID,
            publicKeySHA256: String(repeating: "a", count: 64),
            enabledAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertTrue(
            KitBiometricEnrollmentPolicy.belongsToCurrentUser(
                enrollment,
                userID: enrollment.userID,
                sessionID: "old-session",
                installationID: enrollment.installationID
            )
        )
        XCTAssertTrue(
            KitBiometricEnrollmentPolicy.belongsToCurrentUser(
                enrollment,
                userID: enrollment.userID,
                sessionID: "rotated-session",
                installationID: enrollment.installationID
            )
        )
        XCTAssertFalse(
            KitBiometricEnrollmentPolicy.belongsToCurrentUser(
                enrollment,
                userID: "10000000-0000-0000-0000-000000000002",
                sessionID: "rotated-session",
                installationID: enrollment.installationID
            )
        )
        XCTAssertFalse(
            KitBiometricEnrollmentPolicy.belongsToCurrentUser(
                enrollment,
                userID: enrollment.userID,
                sessionID: "rotated-session",
                installationID: "30000000-0000-0000-0000-000000000002"
            )
        )
    }

    func testSPKIWrapsValidP256PointAndPEMRoundTrips() throws {
        let der = try KitBiometricP256.subjectPublicKeyInfo(
            fromX963Representation: validP256Point
        )

        XCTAssertEqual(der.count, 91)
        XCTAssertEqual(
            der.prefix(KitBiometricP256.subjectPublicKeyInfoPrefix.count),
            KitBiometricP256.subjectPublicKeyInfoPrefix
        )
        XCTAssertEqual(
            der.suffix(validP256Point.count),
            validP256Point
        )

        let pem = try KitBiometricP256.publicKeyPEM(
            fromX963Representation: validP256Point
        )
        let lines = pem.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "-----BEGIN PUBLIC KEY-----")
        XCTAssertEqual(lines.last, "-----END PUBLIC KEY-----")
        XCTAssertTrue(lines.dropFirst().dropLast().allSatisfy { $0.count <= 64 })
        XCTAssertEqual(
            Data(base64Encoded: lines.dropFirst().dropLast().joined()),
            der
        )
    }

    func testInvalidX963PointsAreRejected() {
        XCTAssertThrowsError(
            try KitBiometricP256.subjectPublicKeyInfo(
                fromX963Representation: Data(repeating: 0, count: 65)
            )
        )
        XCTAssertThrowsError(
            try KitBiometricP256.subjectPublicKeyInfo(
                fromX963Representation: Data([0x04, 0x01, 0x02])
            )
        )
        XCTAssertThrowsError(
            try KitBiometricP256.subjectPublicKeyInfo(
                fromX963Representation: Data([0x04]) + Data(repeating: 0, count: 64)
            )
        )
    }

    func testBase64URLSignatureEncodingIsUnpadded() {
        let encoded = KitBiometricP256.base64URLEncodedString(
            Data([0xFB, 0xFF])
        )

        XCTAssertEqual(encoded, "-_8")
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }

    func testSigningPayloadPreservesExactUTF8Bytes() {
        let payload = "A|é|\u{1F4B3}|\n"
        let expected = Data([
            0x41, 0x7C, 0xC3, 0xA9, 0x7C,
            0xF0, 0x9F, 0x92, 0xB3, 0x7C, 0x0A,
        ])

        XCTAssertEqual(
            KitBiometricP256.signingPayloadData(payload),
            expected
        )
    }

    func testFinancialApprovalUsesBiometricsInsteadOfPINWhenEnabled() {
        XCTAssertEqual(
            KitFinancialStepUpApprovalPolicy.method(biometricsEnabled: true),
            .biometricSignature
        )
        XCTAssertEqual(
            KitFinancialStepUpApprovalPolicy.method(biometricsEnabled: false),
            .pin
        )
    }

    func testAccountDeletionRemainsPINOnlyWhenBiometricsAreEnabled() {
        XCTAssertEqual(
            KitFinancialStepUpApprovalPolicy.method(
                purpose: "account_deletion",
                biometricsEnabled: true
            ),
            .pin
        )
        XCTAssertEqual(
            KitFinancialStepUpApprovalPolicy.method(
                purpose: "mobile_money_payout",
                biometricsEnabled: true
            ),
            .biometricSignature
        )
    }

    func testAcceptedDeletionBiometricCleanupRetainsAuthorityUntilRemovalVerifies() throws {
        let enrollment = KitBiometricEnrollment(
            userID: "10000000-0000-4000-8000-000000000001",
            installationID: "20000000-0000-4000-8000-000000000001",
            kind: .faceID,
            publicKeySHA256: String(repeating: "a", count: 64),
            enabledAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        var materialPresent = true
        var shouldFailRemoval = true

        XCTAssertThrowsError(
            try AcceptedDeletionBiometricCleanupPolicy.removeAndVerify(
                targetUserID: enrollment.userID,
                installationID: enrollment.installationID,
                loadEnrollment: { materialPresent ? enrollment : nil },
                removeMaterial: {
                    if shouldFailRemoval { throw KitBiometricError.storage }
                    materialPresent = false
                },
                materialRemains: { materialPresent }
            )
        )
        XCTAssertTrue(materialPresent)

        shouldFailRemoval = false
        let result = try AcceptedDeletionBiometricCleanupPolicy.removeAndVerify(
            targetUserID: enrollment.userID,
            installationID: enrollment.installationID,
            loadEnrollment: { materialPresent ? enrollment : nil },
            removeMaterial: { materialPresent = false },
            materialRemains: { materialPresent }
        )
        XCTAssertEqual(result, .removedTargetMaterial)
        XCTAssertFalse(materialPresent)
    }

    func testAcceptedDeletionBiometricCleanupPreservesReplacementEnrollment() throws {
        let replacement = KitBiometricEnrollment(
            userID: "10000000-0000-4000-8000-000000000002",
            installationID: "20000000-0000-4000-8000-000000000001",
            kind: .touchID,
            publicKeySHA256: String(repeating: "b", count: 64),
            enabledAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        var removalWasCalled = false

        let result = try AcceptedDeletionBiometricCleanupPolicy.removeAndVerify(
            targetUserID: "10000000-0000-4000-8000-000000000001",
            installationID: replacement.installationID,
            loadEnrollment: { replacement },
            removeMaterial: { removalWasCalled = true },
            materialRemains: { true }
        )

        XCTAssertEqual(result, .replacementEnrollmentPreserved)
        XCTAssertFalse(removalWasCalled)
    }

    func testFinancialIntentHashMatchesBackendCanonicalJSONContract() throws {
        let qrIntent: [String: String?] = [
            "action": "qr_payment",
            "qr_code_id": "qr-1",
            "qr_payload_hash": "abc123",
            "source_wallet_id": "wallet-1",
            "amount": "1250.00",
            "currency": "UGX",
        ]

        XCTAssertEqual(
            String(
                decoding: try KitFinancialStepUpBinding.canonicalPayloadData(
                    purpose: "qr_payment",
                    intent: qrIntent
                ),
                as: UTF8.self
            ),
            #"{"purpose":"qr_payment","intent":{"action":"qr_payment","amount":"1250.00","currency":"UGX","qr_code_id":"qr-1","qr_payload_hash":"abc123","source_wallet_id":"wallet-1"}}"#
        )
        XCTAssertEqual(
            try KitFinancialStepUpBinding.intentHash(
                purpose: "qr_payment",
                intent: qrIntent
            ),
            "19650abce904f429cf2c1649052f1b1a23a9231284711fe3ca1bbf41db8301da"
        )
        XCTAssertEqual(
            try KitFinancialStepUpBinding.intentHash(
                purpose: "wallet_transfer",
                intent: ["amount": "10.00", "note": nil]
            ),
            "dd9e458b4ca3171054aeca59b2df404265ea945250fbf0bff81ac17f40752338"
        )
    }

    func testFinancialIntentHashMatchesBackendPaymentRailVectors() throws {
        let collectionIntent: [String: String?] = [
            "action": "collection",
            "quote_id": "11111111-1111-1111-1111-111111111111",
            "wallet_id": "22222222-2222-2222-2222-222222222222",
            "mobile_money_account_id": "33333333-3333-3333-3333-333333333333",
            "network": "MTN",
            "fee_mode": "gross_up",
            "requested_amount": "500.00",
            "provider_amount": "517.00",
            "provider_fee": "12.93",
            "platform_fee": "3.62",
            "rounding_adjustment": "0.45",
            "total_fees": "17.00",
            "wallet_credit": "500.00",
            "currency": "UGX",
        ]
        let payoutIntent: [String: String?] = [
            "action": "payout",
            "quote_id": "11111111-1111-1111-1111-111111111111",
            "wallet_id": "22222222-2222-2222-2222-222222222222",
            "mobile_money_account_id": "33333333-3333-3333-3333-333333333333",
            "network": "MTN",
            "fee_mode": "sender_absorbs",
            "recipient_amount": "500.00",
            "processing_fee": "10.00",
            "provider_fee": "5.00",
            "kit_fee": "5.00",
            "provider_fee_cap": "5.00",
            "maximum_provider_total": "505.00",
            "customer_debit": "510.00",
            "kit_debit": "0.00",
            "schedule_version": "rukapay-test-2026-08-18",
            "currency": "UGX",
        ]
        let bankIntent: [String: String?] = [
            "action": "transfer",
            "operation_type": "bank_transfer",
            "quote_id": "66666666-6666-4666-8666-666666666666",
            "wallet_id": "33333333-3333-4333-8333-333333333333",
            "beneficiary_id": "44444444-4444-4444-8444-444444444444",
            "bank_id": "11111111-1111-4111-8111-111111111111",
            "bank_code": "040147",
            "fee_mode": "sender_absorbs",
            "recipient_amount": "50000.00",
            "processing_fee": "6000.00",
            "provider_fee": "3000.00",
            "kit_fee": "3000.00",
            "provider_fee_cap": "3000.00",
            "maximum_provider_total": "53000.00",
            "customer_debit": "56000.00",
            "kit_debit": "0.00",
            "schedule_version": "rukapay-bank-test-2026-08-18",
            "currency": "UGX",
        ]

        XCTAssertEqual(
            try KitFinancialStepUpBinding.intentHash(
                purpose: "mobile_money_collection",
                intent: collectionIntent
            ),
            "39e04b4e3b821d7a728c1589bbd0ded9b4d3cc992fe4e6848ea40907da0dd3c6"
        )
        XCTAssertEqual(
            try KitFinancialStepUpBinding.intentHash(
                purpose: "mobile_money_payout",
                intent: payoutIntent
            ),
            "e02403a1e40de669ea73c152564aa41e8338bf5a440d194aab00000df0cb6615"
        )
        XCTAssertEqual(
            try KitFinancialStepUpBinding.intentHash(
                purpose: "bank_transfer",
                intent: bankIntent
            ),
            "46221ab444e4ae53fef6a752a488f70769aeb6c7d6cff02f6a70406b88022d87"
        )
        XCTAssertEqual(
            try KitFinancialStepUpBinding.intentHash(
                purpose: "bill_payment",
                intent: [
                    "quote_id": "quote-1",
                    "wallet_id": "wallet-1",
                    "client_reference": "ios-provider-operation-1",
                ]
            ),
            "6a3c9a67cb8c839ae3731ab990e6460af282e609f4ddf6bf4c79947c99a4d345"
        )
    }

    func testBiometricChallengeMustBindTheExactIntentAndSigningPayload() throws {
        let purpose = "mobile_money_payout"
        let intent: [String: String?] = [
            "action": "payout",
            "wallet_id": "wallet-1",
            "mobile_money_account_id": "account-1",
            "network": "MTN",
            "amount": "400.00",
            "currency": "UGX",
        ]
        let hash = try KitFinancialStepUpBinding.intentHash(
            purpose: purpose,
            intent: intent
        )
        let nonce = "server-nonce"
        let challenge = StepUpChallengeDTO(
            id: "challenge-1",
            purpose: purpose,
            intentHash: hash,
            nonce: nonce,
            signingPayload: KitFinancialStepUpBinding.signingPayload(
                purpose: purpose,
                intentHash: hash,
                nonce: nonce
            ),
            methods: ["pin", "biometric_signature"],
            expiresAt: "2026-08-18T12:02:00Z"
        )

        XCTAssertNoThrow(
            try KitFinancialStepUpBinding.validate(
                challenge,
                purpose: purpose,
                intent: intent,
                method: .biometricSignature
            )
        )
        var changedIntent = intent
        changedIntent["amount"] = "401.00"
        XCTAssertThrowsError(
            try KitFinancialStepUpBinding.validate(
                challenge,
                purpose: purpose,
                intent: changedIntent,
                method: .biometricSignature
            )
        )

        let alteredPayload = StepUpChallengeDTO(
            id: challenge.id,
            purpose: challenge.purpose,
            intentHash: challenge.intentHash,
            nonce: challenge.nonce,
            signingPayload: challenge.signingPayload + "\nchanged",
            methods: challenge.methods,
            expiresAt: challenge.expiresAt
        )
        XCTAssertThrowsError(
            try KitFinancialStepUpBinding.validate(
                alteredPayload,
                purpose: purpose,
                intent: intent,
                method: .biometricSignature
            )
        )
    }

    func testEnabledBiometricsNeverDowngradeToAvailablePINMethod() throws {
        let purpose = "qr_payment"
        let intent: [String: String?] = ["amount": "10.00"]
        let hash = try KitFinancialStepUpBinding.intentHash(
            purpose: purpose,
            intent: intent
        )
        let challenge = StepUpChallengeDTO(
            id: "challenge-1",
            purpose: purpose,
            intentHash: hash,
            nonce: "nonce",
            signingPayload: KitFinancialStepUpBinding.signingPayload(
                purpose: purpose,
                intentHash: hash,
                nonce: "nonce"
            ),
            methods: ["pin"],
            expiresAt: "2026-08-18T12:02:00Z"
        )

        XCTAssertThrowsError(
            try KitFinancialStepUpBinding.validate(
                challenge,
                purpose: purpose,
                intent: intent,
                method: KitFinancialStepUpApprovalPolicy.method(
                    biometricsEnabled: true
                )
            )
        ) { error in
            XCTAssertEqual(error as? KitFinancialStepUpError, .invalidChallenge)
        }
    }

    func testResolverUsesExistingBiometricChallengeWithoutRepair() async throws {
        let purpose = "mobile_money_payout"
        let intent: [String: String?] = ["quote_id": "quote-1"]
        let initial = try stepUpChallenge(
            id: "challenge-1",
            purpose: purpose,
            intent: intent,
            methods: ["pin", "biometric_signature"]
        )
        var repairCount = 0
        var replacementCount = 0

        let resolved = try await KitFinancialStepUpChallengeResolver.resolve(
            initial: initial,
            purpose: purpose,
            intent: intent,
            method: .biometricSignature,
            repairBiometricEnrollment: { repairCount += 1 },
            createReplacementChallenge: {
                replacementCount += 1
                return initial
            }
        )

        XCTAssertEqual(resolved.id, initial.id)
        XCTAssertEqual(repairCount, 0)
        XCTAssertEqual(replacementCount, 0)
    }

    func testResolverUsesExistingPINChallengeWithoutBiometricRepair() async throws {
        let purpose = "airtime_purchase"
        let intent: [String: String?] = ["quote_id": "quote-1"]
        let initial = try stepUpChallenge(
            id: "challenge-pin",
            purpose: purpose,
            intent: intent,
            methods: ["pin"]
        )
        var repairCount = 0
        var replacementCount = 0

        let resolved = try await KitFinancialStepUpChallengeResolver.resolve(
            initial: initial,
            purpose: purpose,
            intent: intent,
            method: .pin,
            repairBiometricEnrollment: { repairCount += 1 },
            createReplacementChallenge: {
                replacementCount += 1
                return initial
            }
        )

        XCTAssertEqual(resolved.id, initial.id)
        XCTAssertEqual(repairCount, 0)
        XCTAssertEqual(replacementCount, 0)
    }

    func testResolverRepairsPINOnlyChallengeOnceAndRequiresFreshBiometricChallenge() async throws {
        let purpose = "bank_transfer"
        let intent: [String: String?] = ["quote_id": "quote-1"]
        let initial = try stepUpChallenge(
            id: "challenge-pin-only",
            purpose: purpose,
            intent: intent,
            methods: ["pin"]
        )
        let replacement = try stepUpChallenge(
            id: "challenge-biometric",
            purpose: purpose,
            intent: intent,
            methods: ["pin", "biometric_signature"]
        )
        var repairCount = 0
        var replacementCount = 0

        let resolved = try await KitFinancialStepUpChallengeResolver.resolve(
            initial: initial,
            purpose: purpose,
            intent: intent,
            method: .biometricSignature,
            repairBiometricEnrollment: { repairCount += 1 },
            createReplacementChallenge: {
                replacementCount += 1
                return replacement
            }
        )

        XCTAssertEqual(resolved.id, replacement.id)
        XCTAssertTrue(KitFinancialStepUpBinding.supports(.biometricSignature, in: resolved))
        XCTAssertEqual(repairCount, 1)
        XCTAssertEqual(replacementCount, 1)
    }

    func testResolverRejectsSecondPINOnlyChallengeWithoutDowngrading() async throws {
        let purpose = "qr_payment"
        let intent: [String: String?] = ["amount": "500.00"]
        let initial = try stepUpChallenge(
            id: "challenge-1",
            purpose: purpose,
            intent: intent,
            methods: ["pin"]
        )
        let replacement = try stepUpChallenge(
            id: "challenge-2",
            purpose: purpose,
            intent: intent,
            methods: ["pin"]
        )
        var repairCount = 0
        var replacementCount = 0

        do {
            _ = try await KitFinancialStepUpChallengeResolver.resolve(
                initial: initial,
                purpose: purpose,
                intent: intent,
                method: .biometricSignature,
                repairBiometricEnrollment: { repairCount += 1 },
                createReplacementChallenge: {
                    replacementCount += 1
                    return replacement
                }
            )
            XCTFail("A second PIN-only challenge must not downgrade biometric approval.")
        } catch {
            XCTAssertEqual(
                error as? KitFinancialStepUpError,
                .approvalMethodUnavailable
            )
        }

        XCTAssertEqual(repairCount, 1)
        XCTAssertEqual(replacementCount, 1)
    }

    func testResolverRejectsTamperedChallengeBeforeRepair() async throws {
        let purpose = "bill_payment"
        let intent: [String: String?] = ["quote_id": "quote-1"]
        let valid = try stepUpChallenge(
            id: "challenge-1",
            purpose: purpose,
            intent: intent,
            methods: ["pin"]
        )
        let tampered = StepUpChallengeDTO(
            id: valid.id,
            purpose: valid.purpose,
            intentHash: String(repeating: "0", count: 64),
            nonce: valid.nonce,
            signingPayload: valid.signingPayload,
            methods: valid.methods,
            expiresAt: valid.expiresAt
        )
        var repairCount = 0
        var replacementCount = 0

        do {
            _ = try await KitFinancialStepUpChallengeResolver.resolve(
                initial: tampered,
                purpose: purpose,
                intent: intent,
                method: .biometricSignature,
                repairBiometricEnrollment: { repairCount += 1 },
                createReplacementChallenge: {
                    replacementCount += 1
                    return valid
                }
            )
            XCTFail("A tampered binding must be rejected before enrollment repair.")
        } catch {
            XCTAssertEqual(error as? KitFinancialStepUpError, .invalidChallenge)
        }

        XCTAssertEqual(repairCount, 0)
        XCTAssertEqual(replacementCount, 0)
    }

    func testResolverDoesNotCreateReplacementWhenEnrollmentRepairFails() async throws {
        let purpose = "airtime_purchase"
        let intent: [String: String?] = ["quote_id": "quote-1"]
        let initial = try stepUpChallenge(
            id: "challenge-1",
            purpose: purpose,
            intent: intent,
            methods: ["pin"]
        )
        var replacementCount = 0

        do {
            _ = try await KitFinancialStepUpChallengeResolver.resolve(
                initial: initial,
                purpose: purpose,
                intent: intent,
                method: .biometricSignature,
                repairBiometricEnrollment: {
                    throw ResolverTestError.repairFailed
                },
                createReplacementChallenge: {
                    replacementCount += 1
                    return initial
                }
            )
            XCTFail("A failed enrollment repair must stop the approval attempt.")
        } catch {
            XCTAssertEqual(error as? ResolverTestError, .repairFailed)
        }

        XCTAssertEqual(replacementCount, 0)
    }

    func testStepUpVerificationMustConfirmRequestedMethodAndToken() {
        XCTAssertNoThrow(
            try KitFinancialStepUpBinding.validate(
                StepUpVerificationDTO(
                    stepUpToken: "one-time-token",
                    expiresAt: "2026-08-18T12:05:00Z",
                    method: "biometric_signature"
                ),
                method: .biometricSignature
            )
        )
        XCTAssertThrowsError(
            try KitFinancialStepUpBinding.validate(
                StepUpVerificationDTO(
                    stepUpToken: "one-time-token",
                    expiresAt: "2026-08-18T12:05:00Z",
                    method: "pin"
                ),
                method: .biometricSignature
            )
        )
        XCTAssertThrowsError(
            try KitFinancialStepUpBinding.validate(
                StepUpVerificationDTO(
                    stepUpToken: "",
                    expiresAt: "2026-08-18T12:05:00Z",
                    method: "biometric_signature"
                ),
                method: .biometricSignature
            )
        )
    }

    private func stepUpChallenge(
        id: String,
        purpose: String,
        intent: [String: String?],
        methods: [String]?
    ) throws -> StepUpChallengeDTO {
        let intentHash = try KitFinancialStepUpBinding.intentHash(
            purpose: purpose,
            intent: intent
        )
        let nonce = "nonce-\(id)"
        return StepUpChallengeDTO(
            id: id,
            purpose: purpose,
            intentHash: intentHash,
            nonce: nonce,
            signingPayload: KitFinancialStepUpBinding.signingPayload(
                purpose: purpose,
                intentHash: intentHash,
                nonce: nonce
            ),
            methods: methods,
            expiresAt: "2026-08-19T12:02:00Z"
        )
    }

    private enum ResolverTestError: Error, Equatable {
        case repairFailed
    }
}
