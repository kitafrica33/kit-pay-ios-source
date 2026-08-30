import Foundation

enum AccountSetupStep: Hashable {
    case profile(needsPaymentPin: Bool)
    case deviceVerification(needsPaymentPin: Bool)
    case paymentPin
    case loginUnlock
}

enum AccountSetupPolicy {
    static func initialStep(
        afterAuthentication user: UserProfile?,
        assurance: SessionAssuranceDTO?
    ) -> AccountSetupStep? {
        requiredStep(user: user, assurance: assurance)
    }

    static func initialStep(afterAuthentication user: UserProfile?) -> AccountSetupStep? {
        initialStep(afterAuthentication: user, assurance: nil)
    }

    /// Restoration is deliberately fail closed: a missing profile, assurance projection, or
    /// nullable PIN flag must not grant access to authenticated app content.
    static func restoredStep(
        user: UserProfile?,
        assurance: SessionAssuranceDTO?
    ) -> AccountSetupStep? {
        requiredStep(user: user, assurance: assurance)
    }

    static func restoredStep(user: UserProfile?) -> AccountSetupStep? {
        restoredStep(user: user, assurance: nil)
    }

    static func reconcile(
        _ current: AccountSetupStep?,
        with user: UserProfile,
        assurance: SessionAssuranceDTO?
    ) -> AccountSetupStep? {
        requiredStep(user: user, assurance: assurance)
    }

    static func reconcile(_ current: AccountSetupStep?, with user: UserProfile) -> AccountSetupStep? {
        reconcile(current, with: user, assurance: nil)
    }

    static func nextStep(afterCompleting current: AccountSetupStep) -> AccountSetupStep? {
        switch current {
        case .profile:
            .loginUnlock
        case .deviceVerification, .paymentPin, .loginUnlock:
            nil
        }
    }

    static func requiresProfileSetup(_ user: UserProfile?) -> Bool {
        guard let user else { return true }
        return user.profileSetupRequired == true || profileIdentityValidationError(
            name: user.name ?? "",
            tag: user.tag,
            verifiedLegalName: user.verifiedLegalName,
            // Absent on servers that predate the split, where the username is still mandatory.
            usernameRequired: user.usernameRequired ?? true
        ) != nil
    }

    private static func requiredStep(
        user: UserProfile?,
        assurance: SessionAssuranceDTO?
    ) -> AccountSetupStep? {
        if requiresProfileSetup(user) {
            // Wallet-PIN and KYC setup belong to the money flow, not app admission. Carrying
            // `false` prevents legacy setup state from manufacturing a payment-PIN step.
            return .profile(needsPaymentPin: false)
        }
        guard let user, let assurance else { return .loginUnlock }
        switch assurance.communicationRequirement(accountKYCStatus: user.kycStatus) {
        case .allowed:
            return nil
        case .verifyDeviceIdentity:
            return .deviceVerification(needsPaymentPin: false)
        case .unlockSession:
            return user.paymentPinSet == true ? .loginUnlock : .paymentPin
        case .unavailable:
            return .loginUnlock
        }
    }
}

/// A profile PATCH carries only the chosen identity. The legal name is server-owned and is
/// deliberately absent from this request: nothing the client sends may overwrite it.
///
/// Both fields are omitted-if-nil rather than sent as null, so "the user did not choose a
/// username" reads as *unchanged* to the server instead of *clear it*.
struct UpdateProfileRequest: Encodable, Equatable {
    let name: String?
    let tag: String?

    init(name: String?, tag: String?) {
        self.name = name
        self.tag = tag
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(tag, forKey: .tag)
    }

    enum CodingKeys: String, CodingKey {
        case name, tag
    }
}

struct SetPaymentPinRequest: Encodable, Equatable {
    let pin: String
    let pinConfirmation: String
    let currentPin: String?

    init(pin: String, currentPin: String? = nil) {
        self.pin = pin
        pinConfirmation = pin
        self.currentPin = currentPin
    }

    enum CodingKeys: String, CodingKey {
        case pin
        case pinConfirmation = "pin_confirmation"
        case currentPin = "current_pin"
    }
}

func normalizeProfileName(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func normalizeProfileTag(_ value: String) -> String {
    let trimmed = value.drop(while: { $0.isWhitespace })
        .reversed()
        .drop(while: { $0.isWhitespace })
        .reversed()
    return String(trimmed).dropFirstIfAtSign.lowercased()
}

/// Validates the *chosen* half of an account's identity: a display name and an `@username`.
///
/// Neither is the user's legal name. When identity verification has already produced a verified
/// legal name, pass it as `verifiedLegalName` and the display name becomes optional — the app
/// shows the verified name instead of forcing the user to retype it. When the server reports that
/// the username is optional, an unset or still-provisional tag is likewise accepted. Anything the
/// user *does* type is validated either way, so an optional field can never be saved half-formed.
///
/// The defaults reproduce the original required-both behaviour, which is what deployments that
/// predate the legal-name split still expect.
func profileIdentityValidationError(
    name: String,
    tag: String?,
    verifiedLegalName: String? = nil,
    usernameRequired: Bool = true
) -> String? {
    let normalizedName = normalizeProfileName(name)
    let normalizedTag = normalizeProfileTag(tag ?? "")
    let hasVerifiedLegalName = !normalizeProfileName(verifiedLegalName ?? "").isEmpty
    let displayNameIsUnset = normalizedName.isEmpty || isPlaceholderProfileName(normalizedName)
    let usernameIsUnset = normalizedTag.isEmpty || isProvisionalProfileTag(normalizedTag)

    if !(hasVerifiedLegalName && displayNameIsUnset) {
        switch normalizedName.unicodeScalars.count {
        case 2...120: break
        default: return "Enter a display name (2–120 characters)."
        }
        if isPlaceholderProfileName(normalizedName) {
            return "Choose the display name people should see."
        }
    }

    if !(!usernameRequired && usernameIsUnset) {
        switch normalizedTag.unicodeScalars.count {
        case 3...32: break
        default: return "Your username must be 3 to 32 characters."
        }
        if isProvisionalProfileTag(normalizedTag) {
            return "Choose your own username."
        }
        if normalizedTag.hasPrefix("deleted_") || reservedProfileTags.contains(normalizedTag) {
            return "This username is reserved."
        }
        if normalizedTag.range(of: "^[a-z0-9_]{3,32}$", options: .regularExpression) == nil {
            return "Use only lowercase letters, numbers, and underscores in your username."
        }
    }
    return nil
}

func isPlaceholderProfileName(_ value: String) -> Bool {
    let normalized = normalizeProfileName(value)
    return normalized.isEmpty ||
        normalized.caseInsensitiveCompare("Kit Pay User") == .orderedSame ||
        normalized.caseInsensitiveCompare("Kit Wallet User") == .orderedSame
}

func isProvisionalProfileTag(_ value: String) -> Bool {
    normalizeProfileTag(value).range(
        of: "^kit_[a-z0-9]{10}$",
        options: .regularExpression
    ) != nil
}

func isValidPaymentPin(_ pin: String) -> Bool {
    pin.count == 4 && pin.allSatisfy { character in
        character >= "0" && character <= "9"
    }
}

private extension String {
    var dropFirstIfAtSign: String {
        first == "@" ? String(dropFirst()) : self
    }
}

private let reservedProfileTags: Set<String> = [
    "admin", "administrator", "api", "help", "kit", "kit_africa", "kit_pay",
    "kitafrica", "kitpay", "moderator", "official", "pay", "root", "security",
    "staff", "support", "system",
]
