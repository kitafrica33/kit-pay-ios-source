import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct MessagingBiometricBinding: Codable, Equatable, Sendable {
    let generation: UUID
    let accountID: String
    let sessionID: String

    var isStructurallyValid: Bool {
        UUID(uuidString: accountID)?.uuidString.lowercased() == accountID
            && UUID(uuidString: sessionID)?.uuidString.lowercased() == sessionID
    }
}

struct MessagingBiometricCredential: Codable, Equatable, Sendable {
    let id: UUID
    let binding: MessagingBiometricBinding
    let enrollmentKeyID: String
    let secretSHA256: Data

    var isStructurallyValid: Bool {
        binding.isStructurallyValid
            && Self.isValidEnrollmentKeyID(enrollmentKeyID)
            && secretSHA256.count == 32
    }

    static func isValidEnrollmentKeyID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}

protocol MessagingBiometricAuthenticating: Sendable {
    func createCredential(
        binding: MessagingBiometricBinding, enrollmentKeyID: String
    ) throws -> MessagingBiometricCredential
    func credentialExists(_ credential: MessagingBiometricCredential) throws -> Bool
    func authenticate(credential: MessagingBiometricCredential) async throws
    func removeCredential(_ credential: MessagingBiometricCredential) throws
}

enum MessagingBiometricCredentialError: Error, LocalizedError {
    case cancelled, lockedOut, unavailable, notEnrolled, passcodeRequired
    case interactionUnavailable, authenticationFailed
    case missingCredential, invalidatedCredential, invalidBinding, appApprovalRequired
    case keychainStorage(OSStatus)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Biometric authentication was cancelled. Try sharing again when you are ready."
        case .lockedOut:
            "Face ID or Touch ID is locked. Unlock your device, then try sharing again."
        case .unavailable:
            "Face ID or Touch ID is unavailable. Check biometric access in device settings and try again."
        case .notEnrolled:
            "Set up Face ID or Touch ID on this device before enabling biometric sharing."
        case .passcodeRequired:
            "A device passcode is required for biometric sharing."
        case .interactionUnavailable:
            "Biometric authentication cannot run right now. Unlock your device and try sharing again."
        case .authenticationFailed:
            "Face ID or Touch ID did not authorize sharing. Please try again."
        case .missingCredential:
            // Keychain does not distinguish deletion from biometric-set invalidation here.
            "The saved biometric sharing approval is missing or no longer usable. Unlock Kit Pay to renew sharing access."
        case .invalidatedCredential:
            "The saved biometric sharing approval is invalid. Unlock Kit Pay to renew sharing access."
        case .invalidBinding:
            "Kit Pay could not match biometric sharing approval to your sign-in. Unlock Kit Pay and try again."
        case .appApprovalRequired:
            "Unlock Kit Pay with Face ID or Touch ID to approve secure sharing."
        case .keychainStorage:
            "Kit Pay could not access secure sharing storage. Please try again."
        }
    }
}

/// A dedicated shared-Keychain item, never the wallet's private biometric signing key.
/// The caller binds creation to fresh main-app biometric proof and rechecks broker ownership.
struct SystemMessagingBiometricAuthenticator: MessagingBiometricAuthenticating {
    private static let service = "africa.kit.pay.messaging-shared"

    /// Cancellation may invalidate the context from another executor while LA is evaluating.
    /// No context properties or authentication operations are exposed through this holder.
    private final class ContextCancellation: @unchecked Sendable {
        private let context: LAContext

        init(context: LAContext) { self.context = context }

        func invalidate() { context.invalidate() }
    }

    func createCredential(
        binding: MessagingBiometricBinding, enrollmentKeyID: String
    ) throws -> MessagingBiometricCredential {
#if KIT_SHARE_EXTENSION
        throw MessagingBiometricCredentialError.appApprovalRequired
#else
        guard binding.isStructurallyValid,
              MessagingBiometricCredential.isValidEnrollmentKeyID(enrollmentKeyID)
        else { throw MessagingBiometricCredentialError.invalidBinding }

        let context = LAContext()
        defer { context.invalidate() }
        try Self.requireAvailableBiometrics(context)

        var secret = Data(count: 32)
        let randomStatus = secret.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let address = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, address)
        }
        guard randomStatus == errSecSuccess else {
            throw MessagingBiometricCredentialError.keychainStorage(randomStatus)
        }
        let credential = MessagingBiometricCredential(
            id: UUID(), binding: binding, enrollmentKeyID: enrollmentKeyID,
            secretSHA256: Data(SHA256.hash(data: secret))
        )
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet, &accessError
        ) else {
            if let error = accessError?.takeRetainedValue() {
                throw Self.mapError(error as Error)
            }
            throw MessagingBiometricCredentialError.keychainStorage(errSecParam)
        }
        var attributes = try Self.query(for: credential)
        attributes[kSecAttrAccessControl as String] = accessControl
        attributes[kSecValueData as String] = secret
        // Add-only: no existing guard can be overwritten or silently recreated.
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.mapStatus(status) }
        return credential
#endif
    }

    /// Presence only, not proof that the protected secret remains usable. Never prompts.
    /// Inconclusive interaction/authentication/storage errors must not trigger replacement.
    func credentialExists(_ credential: MessagingBiometricCredential) throws -> Bool {
        var query = try Self.query(for: credential)
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Self.mapStatus(status) }
        guard result is [String: Any] else {
            throw MessagingBiometricCredentialError.keychainStorage(errSecDecode)
        }
        return true
    }

    /// All blocking Security calls and LAContext work happen outside the caller's actor.
    /// The broker must capture its challenge before awaiting, then revalidate after this returns.
    func authenticate(credential: MessagingBiometricCredential) async throws {
        let authentication = Task.detached(priority: .userInitiated) {
            try await Self.authenticateCredential(credential)
        }
        try await withTaskCancellationHandler {
            try await authentication.value
        } onCancel: {
            authentication.cancel()
        }
    }

    func removeCredential(_ credential: MessagingBiometricCredential) throws {
        var query = try Self.query(for: credential)
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.mapStatus(status)
        }
    }

    private static func authenticateCredential(
        _ credential: MessagingBiometricCredential
    ) async throws {
        var query = try query(for: credential)
        guard !Task.isCancelled else { throw MessagingBiometricCredentialError.cancelled }
        let context = LAContext()
        context.localizedReason = "Send this share securely with Kit Pay."
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        let cancellation = ContextCancellation(context: context)
        try await withTaskCancellationHandler {
            do {
                guard !Task.isCancelled else { throw MessagingBiometricCredentialError.cancelled }
                try requireAvailableBiometrics(context)
                guard try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: context.localizedReason
                ) else { throw MessagingBiometricCredentialError.authenticationFailed }
                guard !Task.isCancelled else { throw MessagingBiometricCredentialError.cancelled }
                // Satisfying LA alone is insufficient: read the original current-set ACL item
                // using the same context. Refuse another prompt if it cannot authorize the read.
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status == errSecSuccess else { throw mapStatus(status) }
                guard let secret = result as? Data, secret.count == 32,
                      Data(SHA256.hash(data: secret)) == credential.secretSHA256
                else { throw MessagingBiometricCredentialError.invalidatedCredential }
                guard !Task.isCancelled else { throw MessagingBiometricCredentialError.cancelled }
            } catch {
                if Task.isCancelled { throw MessagingBiometricCredentialError.cancelled }
                throw mapError(error)
            }
        } onCancel: {
            cancellation.invalidate()
        }
    }

    private static func query(
        for credential: MessagingBiometricCredential
    ) throws -> [String: Any] {
        guard credential.isStructurallyValid else {
            throw MessagingBiometricCredentialError.invalidBinding
        }
        guard let group = Bundle.main.object(
            forInfoDictionaryKey: "KitMessagingKeychainGroup"
        ) as? String, !group.isEmpty, !group.contains("$(") else {
            throw MessagingBiometricCredentialError.keychainStorage(errSecMissingEntitlement)
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "biometric-credential-v1-" + credential.id.uuidString.lowercased(),
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func requireAvailableBiometrics(_ context: LAContext) throws {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error.map { mapError($0) } ?? MessagingBiometricCredentialError.unavailable
        }
    }

    private static func mapError(_ error: Error) -> MessagingBiometricCredentialError {
        if let error = error as? MessagingBiometricCredentialError { return error }
        if error is CancellationError { return .cancelled }
        let error = error as NSError
        if error.domain == LAError.errorDomain, let code = LAError.Code(rawValue: error.code) {
            switch code {
            case .userCancel, .userFallback, .systemCancel, .appCancel: return .cancelled
            case .biometryLockout: return .lockedOut
            case .biometryNotAvailable: return .unavailable
            case .biometryNotEnrolled: return .notEnrolled
            case .passcodeNotSet: return .passcodeRequired
            case .notInteractive, .invalidContext: return .interactionUnavailable
            default: return .authenticationFailed
            }
        }
        if error.domain == NSOSStatusErrorDomain {
            return mapStatus(OSStatus(error.code))
        }
        return .authenticationFailed
    }

    private static func mapStatus(_ status: OSStatus) -> MessagingBiometricCredentialError {
        switch status {
        case errSecUserCanceled: return .cancelled
        case errSecInteractionNotAllowed: return .interactionUnavailable
        case errSecAuthFailed: return .authenticationFailed
        case errSecItemNotFound: return .missingCredential
        default: return .keychainStorage(status)
        }
    }
}
