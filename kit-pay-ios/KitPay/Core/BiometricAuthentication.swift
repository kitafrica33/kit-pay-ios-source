import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum KitBiometricKind: String, Codable, Equatable, Sendable {
    case faceID
    case touchID
    case biometrics

    var displayName: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .biometrics: "biometrics"
        }
    }

    var symbolName: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .biometrics: "person.badge.key.fill"
        }
    }
}

struct KitBiometricAvailability: Equatable, Sendable {
    let kind: KitBiometricKind
    let isAvailable: Bool
    let unavailableMessage: String?
}

struct KitBiometricEnrollment: Codable, Equatable, Sendable {
    let userID: String
    let installationID: String
    let kind: KitBiometricKind
    let publicKeySHA256: String
    let enabledAt: Date
}

enum KitBiometricEnrollmentPolicy {
    static func belongsToCurrentUser(
        _ enrollment: KitBiometricEnrollment?,
        userID: String,
        installationID: String
    ) -> Bool {
        enrollment?.userID.caseInsensitiveCompare(userID) == .orderedSame
            && enrollment?.installationID == installationID
    }

    // Session rotation must not invalidate a device-bound biometric enrollment.
    static func belongsToCurrentUser(
        _ enrollment: KitBiometricEnrollment?,
        userID: String,
        sessionID _: String,
        installationID: String
    ) -> Bool {
        belongsToCurrentUser(
            enrollment,
            userID: userID,
            installationID: installationID
        )
    }
}

enum AcceptedDeletionBiometricCleanupResult: Equatable {
    case removedTargetMaterial
    case replacementEnrollmentPreserved
}

enum AcceptedDeletionBiometricCleanupPolicy {
    static func removeAndVerify(
        targetUserID: String,
        installationID: String,
        loadEnrollment: () throws -> KitBiometricEnrollment?,
        removeMaterial: () throws -> Void,
        materialRemains: () throws -> Bool
    ) throws -> AcceptedDeletionBiometricCleanupResult {
        if let enrollment = try loadEnrollment(),
           !KitBiometricEnrollmentPolicy.belongsToCurrentUser(
               enrollment,
               userID: targetUserID,
               installationID: installationID
           ) {
            return .replacementEnrollmentPreserved
        }
        try removeMaterial()
        guard try !materialRemains() else { throw KitBiometricError.storage }
        return .removedTargetMaterial
    }
}

enum KitBiometricP256 {
    static let subjectPublicKeyInfoPrefix = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
        0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
        0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ])

    static func subjectPublicKeyInfo(
        fromX963Representation representation: Data
    ) throws -> Data {
        guard representation.count == 65, representation.first == 0x04 else {
            throw KitBiometricError.invalidPublicKey
        }
        do {
            _ = try P256.Signing.PublicKey(x963Representation: representation)
        } catch {
            throw KitBiometricError.invalidPublicKey
        }
        return subjectPublicKeyInfoPrefix + representation
    }

    static func publicKeyPEM(fromX963Representation representation: Data) throws -> String {
        let encoded = try subjectPublicKeyInfo(
            fromX963Representation: representation
        ).base64EncodedString()
        let lines = stride(from: 0, to: encoded.count, by: 64).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(
                start,
                offsetBy: min(64, encoded.count - offset)
            )
            return String(encoded[start..<end])
        }
        return (["-----BEGIN PUBLIC KEY-----"] + lines + ["-----END PUBLIC KEY-----"])
            .joined(separator: "\n")
    }

    static func signingPayloadData(_ signingPayload: String) -> Data {
        Data(signingPayload.utf8)
    }

    static func base64URLEncodedString(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum KitFinancialStepUpApprovalMethod: String, Equatable, Sendable {
    case pin
    case biometricSignature = "biometric_signature"
}

enum KitFinancialStepUpApprovalPolicy {
    private static let pinOnlyPurposes: Set<String> = ["account_deletion"]

    static func method(biometricsEnabled: Bool) -> KitFinancialStepUpApprovalMethod {
        biometricsEnabled ? .biometricSignature : .pin
    }

    static func method(
        purpose: String,
        biometricsEnabled: Bool
    ) -> KitFinancialStepUpApprovalMethod {
        pinOnlyPurposes.contains(purpose) ? .pin : method(
            biometricsEnabled: biometricsEnabled
        )
    }
}

typealias KitFinancialStepUpAuthorization = @MainActor (
    _ purpose: String,
    _ intent: [String: String?],
    _ pin: String,
    _ reason: String
) async throws -> StepUpVerificationDTO

enum KitFinancialStepUpBinding {
    static func canonicalPayloadData(
        purpose: String,
        intent: [String: String?]
    ) throws -> Data {
        var encodedIntent: [String: Any] = [:]
        for (key, value) in intent {
            if let value {
                encodedIntent[key] = value
            } else {
                encodedIntent[key] = NSNull()
            }
        }
        guard JSONSerialization.isValidJSONObject(encodedIntent) else {
            throw KitFinancialStepUpError.invalidIntent
        }

        do {
            let purposeJSON = try JSONSerialization.data(
                withJSONObject: purpose,
                options: [.fragmentsAllowed, .withoutEscapingSlashes]
            )
            let intentJSON = try JSONSerialization.data(
                withJSONObject: encodedIntent,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )

            // The backend's v1 contract fixes the outer order as purpose then
            // intent, and canonicalizes only the nested intent object. Sorting
            // the outer object changes the signed hash for every payment.
            var canonical = Data("{\"purpose\":".utf8)
            canonical.append(purposeJSON)
            canonical.append(Data(",\"intent\":".utf8))
            canonical.append(intentJSON)
            canonical.append(0x7D)
            return canonical
        } catch {
            throw KitFinancialStepUpError.invalidIntent
        }
    }

    static func intentHash(
        purpose: String,
        intent: [String: String?]
    ) throws -> String {
        let canonical = try canonicalPayloadData(purpose: purpose, intent: intent)
        return SHA256.hash(data: canonical).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func signingPayload(
        purpose: String,
        intentHash: String,
        nonce: String
    ) -> String {
        "kit-wallet-step-up-v1\n\(purpose)\n\(intentHash)\n\(nonce)"
    }

    static func validate(
        _ challenge: StepUpChallengeDTO,
        purpose: String,
        intent: [String: String?],
        method: KitFinancialStepUpApprovalMethod
    ) throws {
        try validateBinding(challenge, purpose: purpose, intent: intent)
        guard supports(method, in: challenge) else {
            throw KitFinancialStepUpError.invalidChallenge
        }
    }

    static func validateBinding(
        _ challenge: StepUpChallengeDTO,
        purpose: String,
        intent: [String: String?]
    ) throws {
        let expectedHash = try intentHash(purpose: purpose, intent: intent)
        guard !challenge.id.isEmpty,
              !challenge.nonce.isEmpty,
              challenge.purpose == purpose,
              challenge.intentHash == expectedHash,
              challenge.signingPayload == signingPayload(
                  purpose: purpose,
                  intentHash: expectedHash,
                  nonce: challenge.nonce
              )
        else { throw KitFinancialStepUpError.invalidChallenge }
    }

    static func supports(
        _ method: KitFinancialStepUpApprovalMethod,
        in challenge: StepUpChallengeDTO
    ) -> Bool {
        challenge.methods?.contains(where: {
            $0.caseInsensitiveCompare(method.rawValue) == .orderedSame
        }) == true
    }

    static func validate(
        _ verification: StepUpVerificationDTO,
        method: KitFinancialStepUpApprovalMethod
    ) throws {
        guard !verification.stepUpToken.isEmpty,
              verification.method.caseInsensitiveCompare(method.rawValue) == .orderedSame
        else { throw KitFinancialStepUpError.invalidVerification }
    }
}

enum KitFinancialStepUpChallengeResolver {
    static func resolve(
        initial challenge: StepUpChallengeDTO,
        purpose: String,
        intent: [String: String?],
        method: KitFinancialStepUpApprovalMethod,
        repairBiometricEnrollment: () async throws -> Void,
        createReplacementChallenge: () async throws -> StepUpChallengeDTO
    ) async throws -> StepUpChallengeDTO {
        try KitFinancialStepUpBinding.validateBinding(
            challenge,
            purpose: purpose,
            intent: intent
        )
        if KitFinancialStepUpBinding.supports(method, in: challenge) {
            return challenge
        }

        guard method == .biometricSignature,
              KitFinancialStepUpBinding.supports(.pin, in: challenge)
        else { throw KitFinancialStepUpError.invalidChallenge }

        // A PIN-only challenge means the server no longer has this device's
        // biometric public key. Repair that registration once, then require a
        // new biometric challenge. Never downgrade this approval to PIN.
        try await repairBiometricEnrollment()
        let replacement = try await createReplacementChallenge()
        try KitFinancialStepUpBinding.validateBinding(
            replacement,
            purpose: purpose,
            intent: intent
        )
        guard KitFinancialStepUpBinding.supports(method, in: replacement) else {
            throw KitFinancialStepUpError.approvalMethodUnavailable
        }
        return replacement
    }
}

enum KitFinancialStepUpError: LocalizedError, Equatable {
    case invalidIntent
    case invalidChallenge
    case invalidVerification
    case approvalMethodUnavailable
    case invalidPIN
    case authorizationInProgress
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .invalidIntent:
            "Kit could not safely bind approval to this payment. Nothing was submitted."
        case .invalidChallenge:
            "Kit could not verify the exact payment approval request. Nothing was submitted."
        case .invalidVerification:
            "Kit did not confirm this payment approval. Nothing was submitted."
        case .approvalMethodUnavailable:
            "Biometric payment approval could not be refreshed on this iPhone. Nothing was submitted."
        case .invalidPIN:
            "Enter your four-digit wallet PIN."
        case .authorizationInProgress:
            "Finish the current biometric approval before trying again."
        case .accountChanged:
            "Your Kit Pay session changed before approval completed. Nothing was submitted."
        }
    }
}

enum KitBiometricError: LocalizedError, Equatable {
    case unavailable
    case notEnrolled
    case passcodeNotSet
    case lockedOut
    case cancelled
    case biometricSetChanged
    case enrollmentMissing
    case accountChanged
    case keyMissing
    case invalidPublicKey
    case storage
    case authenticationFailed
    case signingFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Biometric authentication is unavailable on this device."
        case .notEnrolled:
            "Set up Face ID or Touch ID in iPhone Settings first."
        case .passcodeNotSet:
            "Set an iPhone passcode before enabling Face ID or Touch ID for Kit Pay."
        case .lockedOut:
            "Biometrics are locked. Unlock your iPhone with its passcode, then try again."
        case .cancelled:
            "Biometric authentication was cancelled."
        case .biometricSetChanged:
            "The biometrics enrolled on this iPhone changed. Sign in with your phone number, then enable biometrics again."
        case .enrollmentMissing:
            "Biometric sign-in is not enabled for this Kit Pay account."
        case .accountChanged:
            "The signed-in Kit Pay account changed during biometric authentication."
        case .keyMissing:
            "The biometric key is no longer available. Use your PIN, then enable biometrics again."
        case .invalidPublicKey:
            "Kit Pay could not read this device's biometric public key."
        case .storage:
            "Kit Pay could not securely save the biometric setting."
        case .authenticationFailed:
            "Face ID or Touch ID could not verify you. Please try again."
        case .signingFailed:
            "Kit Pay could not approve this request with biometrics. Use your PIN instead."
        }
    }
}

actor KitBiometricAuthenticator {
    static let shared = KitBiometricAuthenticator()

    private let enrollmentAccount = "kit-pay-biometric-enrollment-v2"
    private let legacyEnrollmentAccount = "kit-pay-biometric-enrollment-v1"
    private let legacyProtectedGrantAccount = "kit-pay-biometric-grant-v1"
    private let privateKeyTag = Data("africa.kit.pay.biometric-signing-key.v1".utf8)

    func availability() -> KitBiometricAvailability {
        let context = LAContext()
        var policyError: NSError?
        let available = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &policyError
        )
        let kind = Self.kind(for: context.biometryType)
        return KitBiometricAvailability(
            kind: kind,
            isAvailable: available,
            unavailableMessage: available ? nil : Self.map(policyError).localizedDescription
        )
    }

    func isEnabled(
        forUserID userID: String,
        installationID: String
    ) -> Bool {
        guard let enrollment = try? storedEnrollment(),
              KitBiometricEnrollmentPolicy.belongsToCurrentUser(
                enrollment,
                userID: userID,
                installationID: installationID
              ),
              let privateKey = try? KeychainStore.secureEnclavePrivateKey(
                applicationTag: privateKeyTag
              ),
              let fingerprint = try? Self.publicKeyFingerprint(privateKey),
              fingerprint == enrollment.publicKeySHA256
        else { return false }
        return true
    }

    // Kept for current callers; session IDs intentionally do not participate in binding.
    func isEnabled(
        forUserID userID: String,
        sessionID _: String,
        installationID: String
    ) -> Bool {
        isEnabled(forUserID: userID, installationID: installationID)
    }

    @discardableResult
    func enable(
        forUserID userID: String,
        installationID: String
    ) async throws -> KitBiometricKind {
        let kind = try await evaluate(
            reason: "Enable biometric sign-in and protect Kit Pay payments"
        )

        do {
            try removeStoredMaterial()
            let privateKey = try KeychainStore.createSecureEnclaveP256PrivateKey(
                applicationTag: privateKeyTag
            )
            let enrollment = KitBiometricEnrollment(
                userID: userID,
                installationID: installationID,
                kind: kind,
                publicKeySHA256: try Self.publicKeyFingerprint(privateKey),
                enabledAt: Date()
            )
            try KeychainStore.set(
                JSONEncoder().encode(enrollment),
                for: enrollmentAccount
            )
            return kind
        } catch let error as KitBiometricError {
            removeStoredMaterialIgnoringErrors()
            throw error
        } catch {
            removeStoredMaterialIgnoringErrors()
            throw KitBiometricError.storage
        }
    }

    // Kept for current callers; session IDs intentionally do not participate in binding.
    @discardableResult
    func enable(
        forUserID userID: String,
        sessionID _: String,
        installationID: String
    ) async throws -> KitBiometricKind {
        try await enable(forUserID: userID, installationID: installationID)
    }

    @discardableResult
    func authenticate(
        userID: String,
        installationID: String,
        reason: String
    ) throws -> KitBiometricKind {
        let enrollment = try requireEnrollment(
            userID: userID,
            installationID: installationID
        )
        let context = try Self.authenticationContext(reason: reason)
        let privateKey = try requirePrivateKey(context: context)
        guard try Self.publicKeyFingerprint(privateKey) == enrollment.publicKeySHA256 else {
            throw KitBiometricError.keyMissing
        }

        let localChallenge = Data(
            "kit-pay-biometric-authentication:\(UUID().uuidString)".utf8
        )
        _ = try Self.signature(
            for: localChallenge,
            privateKey: privateKey
        )
        return Self.kind(for: context.biometryType)
    }

    // Kept for current callers; session IDs intentionally do not participate in binding.
    @discardableResult
    func authenticate(
        userID: String,
        sessionID _: String,
        installationID: String,
        reason: String
    ) throws -> KitBiometricKind {
        try authenticate(
            userID: userID,
            installationID: installationID,
            reason: reason
        )
    }

    func publicKeyPEM(
        forUserID userID: String,
        installationID: String
    ) throws -> String {
        let enrollment = try requireEnrollment(
            userID: userID,
            installationID: installationID
        )
        guard let privateKey = try KeychainStore.secureEnclavePrivateKey(
            applicationTag: privateKeyTag
        ) else { throw KitBiometricError.keyMissing }
        let material = try Self.publicKeyMaterial(privateKey)
        guard material.fingerprint == enrollment.publicKeySHA256 else {
            throw KitBiometricError.keyMissing
        }
        return material.pem
    }

    func publicKeyPEM(
        forUserID userID: String,
        sessionID _: String,
        installationID: String
    ) throws -> String {
        try publicKeyPEM(forUserID: userID, installationID: installationID)
    }

    func sign(
        signingPayload: String,
        userID: String,
        installationID: String,
        reason: String
    ) throws -> String {
        let enrollment = try requireEnrollment(
            userID: userID,
            installationID: installationID
        )
        let context = try Self.authenticationContext(reason: reason)
        let privateKey = try requirePrivateKey(context: context)
        guard try Self.publicKeyFingerprint(privateKey) == enrollment.publicKeySHA256 else {
            throw KitBiometricError.keyMissing
        }
        let signature = try Self.signature(
            for: KitBiometricP256.signingPayloadData(signingPayload),
            privateKey: privateKey
        )
        return KitBiometricP256.base64URLEncodedString(signature)
    }

    func sign(
        signingPayload: String,
        userID: String,
        sessionID _: String,
        installationID: String,
        reason: String
    ) throws -> String {
        try sign(
            signingPayload: signingPayload,
            userID: userID,
            installationID: installationID,
            reason: reason
        )
    }

    func disable(
        forUserID userID: String,
        installationID: String
    ) throws {
        let enrollment: KitBiometricEnrollment?
        do {
            enrollment = try storedEnrollment()
        } catch {
            throw KitBiometricError.storage
        }
        if let enrollment,
           !KitBiometricEnrollmentPolicy.belongsToCurrentUser(
               enrollment,
               userID: userID,
               installationID: installationID
           ) {
            throw KitBiometricError.accountChanged
        }
        do {
            try removeStoredMaterial()
        } catch {
            throw KitBiometricError.storage
        }
    }

    // Kept for current callers; session IDs intentionally do not participate in binding.
    func disable(
        forUserID userID: String,
        sessionID _: String,
        installationID: String
    ) throws {
        try disable(forUserID: userID, installationID: installationID)
    }

    func removeAnyEnrollment() {
        removeStoredMaterialIgnoringErrors()
    }

    /// Account-deletion cleanup is marker-gated and therefore must be durable. A replacement
    /// account's enrollment is preserved; exact-target or orphaned material is removed and then
    /// read back before the caller may retire its cleanup marker.
    func removeEnrollmentForAcceptedAccountDeletion(
        userID: String,
        installationID: String
    ) throws -> AcceptedDeletionBiometricCleanupResult {
        do {
            return try AcceptedDeletionBiometricCleanupPolicy.removeAndVerify(
                targetUserID: userID,
                installationID: installationID,
                loadEnrollment: { try storedEnrollment() },
                removeMaterial: { try removeStoredMaterial() },
                materialRemains: { try storedMaterialExists() }
            )
        } catch let error as KitBiometricError {
            throw error
        } catch {
            throw KitBiometricError.storage
        }
    }

    private func requireEnrollment(
        userID: String,
        installationID: String
    ) throws -> KitBiometricEnrollment {
        let enrollment: KitBiometricEnrollment
        do {
            guard let stored = try storedEnrollment() else {
                throw KitBiometricError.enrollmentMissing
            }
            enrollment = stored
        } catch let error as KitBiometricError {
            throw error
        } catch {
            throw KitBiometricError.storage
        }
        guard KitBiometricEnrollmentPolicy.belongsToCurrentUser(
            enrollment,
            userID: userID,
            installationID: installationID
        ) else { throw KitBiometricError.enrollmentMissing }
        return enrollment
    }

    private func requirePrivateKey(context: LAContext) throws -> SecKey {
        do {
            guard let privateKey = try KeychainStore.secureEnclavePrivateKey(
                applicationTag: privateKeyTag,
                context: context
            ) else { throw KitBiometricError.biometricSetChanged }
            return privateKey
        } catch let error as KitBiometricError {
            throw error
        } catch let error as KeychainError {
            throw Self.mapKeychain(error)
        } catch {
            throw KitBiometricError.authenticationFailed
        }
    }

    private func storedEnrollment() throws -> KitBiometricEnrollment? {
        guard let data = try KeychainStore.data(for: enrollmentAccount) else { return nil }
        return try JSONDecoder().decode(KitBiometricEnrollment.self, from: data)
    }

    private func removeStoredMaterial() throws {
        try KeychainStore.removeSecureEnclaveKey(applicationTag: privateKeyTag)
        try KeychainStore.remove(enrollmentAccount)
        try KeychainStore.remove(legacyEnrollmentAccount)
        try KeychainStore.remove(legacyProtectedGrantAccount)
    }

    private func storedMaterialExists() throws -> Bool {
        if try KeychainStore.secureEnclavePrivateKey(applicationTag: privateKeyTag) != nil {
            return true
        }
        if try KeychainStore.data(for: enrollmentAccount) != nil { return true }
        if try KeychainStore.data(for: legacyEnrollmentAccount) != nil { return true }
        return try KeychainStore.data(for: legacyProtectedGrantAccount) != nil
    }

    private func removeStoredMaterialIgnoringErrors() {
        try? KeychainStore.removeSecureEnclaveKey(applicationTag: privateKeyTag)
        try? KeychainStore.remove(enrollmentAccount)
        try? KeychainStore.remove(legacyEnrollmentAccount)
        try? KeychainStore.remove(legacyProtectedGrantAccount)
    }

    private func evaluate(
        reason: String
    ) async throws -> KitBiometricKind {
        let context = Self.makeAuthenticationContext(reason: reason)
        var policyError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &policyError
        ) else { throw Self.map(policyError) }

        do {
            guard try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            ) else { throw KitBiometricError.authenticationFailed }
        } catch {
            throw Self.map(error as NSError)
        }
        return Self.kind(for: context.biometryType)
    }

    /// Builds the context that carries the customer-facing explanation into the Secure Enclave
    /// signing prompt.
    ///
    /// The reason has to live on the context. Reading the key back with `SecItemCopyMatching`
    /// does not itself authenticate — the biometric sheet is presented when the key is *used* to
    /// sign — so the only string iOS 14 and later will show is `LAContext.localizedReason`.
    /// Passing the reason as `kSecUseOperationPrompt` instead, as this did, is ignored whenever a
    /// context is supplied, which left every payment step-up and app unlock asking for Face ID
    /// with no statement of what was being authorized.
    static func makeAuthenticationContext(reason: String) -> LAContext {
        let context = LAContext()
        context.localizedReason = reason
        context.localizedFallbackTitle = ""
        context.localizedCancelTitle = "Cancel"
        return context
    }

    private static func authenticationContext(reason: String) throws -> LAContext {
        let context = makeAuthenticationContext(reason: reason)
        var policyError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &policyError
        ) else { throw map(policyError) }
        return context
    }

    private static func publicKeyMaterial(
        _ privateKey: SecKey
    ) throws -> (pem: String, fingerprint: String) {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw KitBiometricError.invalidPublicKey
        }
        var representationError: Unmanaged<CFError>?
        guard let externalRepresentation = SecKeyCopyExternalRepresentation(
            publicKey,
            &representationError
        ) as Data? else {
            _ = representationError?.takeRetainedValue()
            throw KitBiometricError.invalidPublicKey
        }
        let subjectPublicKeyInfo = try KitBiometricP256.subjectPublicKeyInfo(
            fromX963Representation: externalRepresentation
        )
        return (
            try KitBiometricP256.publicKeyPEM(
                fromX963Representation: externalRepresentation
            ),
            SHA256.hash(data: subjectPublicKeyInfo)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private static func publicKeyFingerprint(_ privateKey: SecKey) throws -> String {
        try publicKeyMaterial(privateKey).fingerprint
    }

    private static func signature(for payload: Data, privateKey: SecKey) throws -> Data {
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            payload as CFData,
            &signingError
        ) as Data? else {
            if let error = signingError?.takeRetainedValue() {
                throw mapSigning(error as Error)
            }
            throw KitBiometricError.signingFailed
        }
        return signature
    }

    private static func kind(for type: LABiometryType) -> KitBiometricKind {
        switch type {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .biometrics
        case .none: return .biometrics
        @unknown default: return .biometrics
        }
    }

    private static func map(_ error: NSError?) -> KitBiometricError {
        guard let error, error.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: error.code)
        else { return .authenticationFailed }
        switch code {
        case .biometryNotAvailable: return .unavailable
        case .biometryNotEnrolled: return .notEnrolled
        case .passcodeNotSet: return .passcodeNotSet
        case .biometryLockout: return .lockedOut
        case .userCancel, .userFallback, .systemCancel, .appCancel: return .cancelled
        default: return .authenticationFailed
        }
    }

    private static func mapKeychain(_ error: KeychainError) -> KitBiometricError {
        switch error.status {
        case errSecUserCanceled: .cancelled
        case errSecAuthFailed: .authenticationFailed
        case errSecInteractionNotAllowed: .lockedOut
        case errSecItemNotFound: .biometricSetChanged
        default: .authenticationFailed
        }
    }

    private static func mapSigning(_ error: Error) -> KitBiometricError {
        let error = error as NSError
        if error.domain == LAError.errorDomain {
            return map(error)
        }
        guard error.domain == NSOSStatusErrorDomain else { return .signingFailed }
        switch OSStatus(error.code) {
        case errSecUserCanceled: return .cancelled
        case errSecInteractionNotAllowed: return .lockedOut
        case errSecItemNotFound: return .biometricSetChanged
        case errSecAuthFailed: return .authenticationFailed
        default: return .signingFailed
        }
    }
}
