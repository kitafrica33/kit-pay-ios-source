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
        let next = requiredStep(user: user, assurance: assurance)

        // Profile PATCH responses from older servers can omit payment_pin_set. Do not lose a
        // PIN-setup requirement already carried by this authenticated flow.
        let carriedPaymentPin = switch current {
        case .profile(let pending), .deviceVerification(let pending): pending
        case .paymentPin: true
        case .loginUnlock, nil: false
        }
        guard carriedPaymentPin, user.paymentPinSet != true else { return next }
        switch next {
        case .profile:
            return .profile(needsPaymentPin: true)
        case .deviceVerification:
            return .deviceVerification(needsPaymentPin: true)
        case .loginUnlock, nil:
            return .paymentPin
        case .paymentPin:
            return .paymentPin
        }
    }

    static func reconcile(_ current: AccountSetupStep?, with user: UserProfile) -> AccountSetupStep? {
        reconcile(current, with: user, assurance: nil)
    }

    static func nextStep(afterCompleting current: AccountSetupStep) -> AccountSetupStep? {
        switch current {
        case .profile(let needsPaymentPin):
            .deviceVerification(needsPaymentPin: needsPaymentPin)
        case .deviceVerification(needsPaymentPin: true):
            .paymentPin
        case .deviceVerification(needsPaymentPin: false):
            .loginUnlock
        case .paymentPin, .loginUnlock:
            nil
        }
    }

    static func requiresProfileSetup(_ user: UserProfile?) -> Bool {
        guard let user else { return true }
        return user.profileSetupRequired == true || profileIdentityValidationError(
            name: user.name ?? "",
            tag: user.tag
        ) != nil
    }

    private static func requiredStep(
        user: UserProfile?,
        assurance: SessionAssuranceDTO?
    ) -> AccountSetupStep? {
        let needsPaymentPin = user?.paymentPinSet != true
        if requiresProfileSetup(user) {
            return .profile(needsPaymentPin: needsPaymentPin)
        }
        guard assurance?.deviceIdentity.isVerified == true else {
            return .deviceVerification(needsPaymentPin: needsPaymentPin)
        }
        if needsPaymentPin {
            return .paymentPin
        }
        guard assurance?.loginUnlock.isUnlocked == true,
              assurance?.grantsFullAccess == true
        else {
            return .loginUnlock
        }
        return nil
    }
}

struct UpdateProfileRequest: Encodable, Equatable {
    let name: String
    let tag: String
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

func profileIdentityValidationError(name: String, tag: String?) -> String? {
    let normalizedName = normalizeProfileName(name)
    let normalizedTag = normalizeProfileTag(tag ?? "")
    switch normalizedName.unicodeScalars.count {
    case 2...120: break
    default: return "Enter a username / display name (2–120 characters)."
    }
    if isPlaceholderProfileName(normalizedName) {
        return "Choose the username / display name people should see."
    }
    switch normalizedTag.unicodeScalars.count {
    case 3...32: break
    default: return "Your Kit Pay tag must be 3 to 32 characters."
    }
    if isProvisionalProfileTag(normalizedTag) {
        return "Choose your own Kit Pay tag."
    }
    if normalizedTag.hasPrefix("deleted_") || reservedProfileTags.contains(normalizedTag) {
        return "This Kit Pay tag is reserved."
    }
    if normalizedTag.range(of: "^[a-z0-9_]{3,32}$", options: .regularExpression) == nil {
        return "Use only lowercase letters, numbers, and underscores in your Kit Pay tag."
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
