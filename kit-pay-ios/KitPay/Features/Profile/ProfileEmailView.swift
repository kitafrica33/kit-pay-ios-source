import Foundation
import SwiftUI

struct ProfileEmailPresentation: Equatable {
    let title: String
    let subtitle: String
    let canAttach: Bool
}

enum ProfileEmailPresentationPolicy {
    static func presentation(
        profile: UserProfile?,
        attachmentAvailable: Bool
    ) -> ProfileEmailPresentation {
        let email = profile?.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if profile?.emailVerified == true, let email, !email.isEmpty {
            return ProfileEmailPresentation(
                title: "Email address",
                subtitle: "\(email) · Verified · Email changes are not yet supported",
                canAttach: false
            )
        }
        if !attachmentAvailable {
            return ProfileEmailPresentation(
                title: email?.isEmpty == false ? "Verify email address" : "Add email address",
                subtitle: "Email verification is temporarily unavailable",
                canAttach: false
            )
        }
        guard let email, !email.isEmpty else {
            return ProfileEmailPresentation(
                title: "Add email address",
                subtitle: "Add a verified contact and recovery address",
                canAttach: true
            )
        }
        return ProfileEmailPresentation(
            title: "Verify email address",
            subtitle: "\(email) · Not verified",
            canAttach: true
        )
    }
}

struct ProfileEmailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: Field?

    @State private var email = ""
    @State private var challenge: ProfileEmailChallenge?
    @State private var code = ""
    @State private var resendAvailableAt: Date?
    @State private var errorMessage: String?
    @State private var initialized = false

    private enum Field {
        case email
        case code
    }

    var body: some View {
        NavigationStack {
            ZStack {
                liquidBackground
                ScrollView {
                    VStack(spacing: 18) {
                        hero
                        if let challenge {
                            verificationCard(challenge)
                        } else {
                            addressCard
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .kitGlass(cornerRadius: 18, tint: .red, shadow: false)
                        }
                        primaryAction
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(challenge == nil ? "Add email address" : "Verify your email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isManagingProfileEmail)
                }
            }
        }
        .onAppear(perform: initialize)
        .onDisappear(perform: discardProof)
        .interactiveDismissDisabled(model.isManagingProfileEmail)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityHidden(concealsSensitiveContent)
        .overlay {
            if concealsSensitiveContent {
                KitColor.canvas
                    .overlay {
                        Label("Email verification hidden", systemImage: "eye.slash.fill")
                            .font(.headline)
                            .foregroundStyle(KitColor.primaryText)
                    }
                    .ignoresSafeArea()
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isModal)
            }
        }
    }

    private var liquidBackground: some View {
        ZStack {
            KitColor.canvas
            Circle()
                .fill(KitColor.green.opacity(0.16))
                .frame(width: 290, height: 290)
                .blur(radius: 70)
                .offset(x: 130, y: -250)
            Circle()
                .fill(KitColor.navy.opacity(0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 82)
                .offset(x: -150, y: 300)
        }
        .ignoresSafeArea()
    }

    private var hero: some View {
        VStack(spacing: 11) {
            Image(systemName: challenge == nil ? "at" : "envelope.badge.shield.half.filled")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(KitColor.green)
                .frame(width: 70, height: 70)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.85), .white.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: KitColor.navy.opacity(0.12), radius: 18, y: 9)
            Text(challenge == nil ? "Keep your account reachable" : "Check your inbox")
                .font(.title3.bold())
                .foregroundStyle(KitColor.primaryText)
            Text(
                challenge == nil
                    ? "We will send a short-lived code before attaching this address."
                    : "Enter the six-digit code to finish adding your email address."
            )
            .font(.subheadline)
            .foregroundStyle(KitColor.secondaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Email address", systemImage: "envelope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KitColor.secondaryText)
            TextField("name@example.com", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($focusedField, equals: .email)
                .disabled(model.isManagingProfileEmail)
                .onSubmit { Task { await requestCode() } }
                .onChange(of: email) { _, value in
                    let limited = String(value.prefix(254))
                    if limited != value { email = limited }
                    errorMessage = nil
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.52), lineWidth: 0.8)
                }
        }
        .padding(16)
        .kitGlass(cornerRadius: 24)
    }

    private func verificationCard(_ challenge: ProfileEmailChallenge) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Code sent to \(challenge.destination)")
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .focused($focusedField, equals: .code)
                .privacySensitive()
                .disabled(model.isManagingProfileEmail)
                .onChange(of: code) { _, value in
                    let filtered = asciiDigits(value, maximumCount: 6)
                    if filtered != value { code = filtered }
                    errorMessage = nil
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.52), lineWidth: 0.8)
                }
                .accessibilityLabel("Six-digit verification code")

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = ProfileEmailChallengePolicy.secondsUntilResend(
                    availableAt: resendAvailableAt,
                    now: context.date
                )
                Button {
                    Task { await requestCode(resending: true) }
                } label: {
                    Text(
                        remaining > 0
                            ? "Send another code in \(countdown(remaining))"
                            : "Send another code"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 15))
                .disabled(remaining > 0 || model.isManagingProfileEmail)
            }
        }
        .padding(16)
        .kitGlass(cornerRadius: 24)
    }

    private var primaryAction: some View {
        Button {
            Task {
                if challenge == nil {
                    await requestCode()
                } else {
                    await verifyCode()
                }
            }
        } label: {
            Group {
                if model.isManagingProfileEmail {
                    HStack(spacing: 9) {
                        ProgressView().tint(.white)
                        Text(model.profileEmailOperation == .requestingCode ? "Sending…" : "Verifying…")
                    }
                } else {
                    Text(challenge == nil ? "Send code" : "Verify email")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .tint(KitColor.green)
        .disabled(
            !model.appReviewDemoMutationsAllowed
                || !canSubmit
                || model.isManagingProfileEmail
        )
    }

    private var canSubmit: Bool {
        if challenge == nil {
            return EmailAccountValidation.isValidEmail(
                ProfileEmailChallengePolicy.normalizedEmail(email)
            )
        }
        return ProfileEmailVerificationCodePolicy.normalizedCode(code) != nil
    }

    private var concealsSensitiveContent: Bool {
        challenge != nil
            && AuthenticationSecretLifecyclePolicy.shouldConceal(
                sceneIsActive: scenePhase == .active
            )
    }

    private func initialize() {
        guard !initialized else { return }
        email = model.profile?.email ?? ""
        initialized = true
        DispatchQueue.main.async {
            focusedField = .email
        }
    }

    @MainActor
    private func requestCode(resending: Bool = false) async {
        guard model.appReviewDemoMutationsAllowed,
              !model.isManagingProfileEmail
        else { return }
        let submittedEmail = ProfileEmailChallengePolicy.normalizedEmail(
            resending ? (challenge?.requestedEmail ?? email) : email
        )
        guard EmailAccountValidation.isValidEmail(submittedEmail) else {
            errorMessage = ProfileEmailAttachmentError.invalidEmail.localizedDescription
            return
        }

        let previousChallenge = challenge.flatMap {
            ProfileEmailChallengePolicy.isValid($0) ? $0 : nil
        }
        if resending,
           ProfileEmailChallengePolicy.secondsUntilResend(
            availableAt: resendAvailableAt
           ) > 0 {
            errorMessage = "Wait for the resend countdown before requesting another code."
            return
        }
        errorMessage = nil
        do {
            let issued = try await model.requestProfileEmailAttachment(email: submittedEmail)
            challenge = issued
            email = issued.requestedEmail
            code = ""
            resendAvailableAt = ProfileEmailChallengePolicy.resendAvailableAt(for: issued)
            focusedField = .code
        } catch {
            // Delivery may have been queued even if the response was lost. Preserve the prior
            // usable proof, but apply its local cooldown before another network attempt.
            if let previousChallenge {
                challenge = previousChallenge
                resendAvailableAt = ProfileEmailChallengePolicy.resendAvailableAt(
                    for: previousChallenge
                )
            }
            errorMessage = profileEmailFailureMessage(error)
        }
    }

    @MainActor
    private func verifyCode() async {
        guard !model.isManagingProfileEmail,
              let challenge,
              let normalizedCode = ProfileEmailVerificationCodePolicy.normalizedCode(code)
        else {
            errorMessage = ProfileEmailAttachmentError.invalidCode.localizedDescription
            return
        }
        guard ProfileEmailChallengePolicy.isValid(challenge) else {
            self.challenge = nil
            code = ""
            resendAvailableAt = nil
            errorMessage = ProfileEmailAttachmentError.invalidOrExpiredChallenge.localizedDescription
            focusedField = .email
            return
        }
        errorMessage = nil
        do {
            try await model.verifyProfileEmailAttachment(
                challenge: challenge,
                code: normalizedCode
            )
            discardProof()
            dismiss()
        } catch {
            errorMessage = profileEmailFailureMessage(error)
            if let payload = error as? APIErrorPayload,
               ["CHALLENGE_ALREADY_USED", "CHALLENGE_EXPIRED", "CHALLENGE_INVALID"]
                .contains(payload.code) {
                self.challenge = nil
                code = ""
                resendAvailableAt = nil
                focusedField = .email
            }
        }
    }

    private func discardProof() {
        code = ""
        challenge = nil
        resendAvailableAt = nil
    }

    private func asciiDigits(_ value: String, maximumCount: Int) -> String {
        var result = ""
        for scalar in value.unicodeScalars where (0x30 ... 0x39).contains(scalar.value) {
            guard result.unicodeScalars.count < maximumCount else { break }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private func countdown(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    private func profileEmailFailureMessage(_ error: Error) -> String {
        if let attachmentError = error as? ProfileEmailAttachmentError {
            return attachmentError.localizedDescription
        }
        if let payload = error as? APIErrorPayload {
            switch payload.code {
            case "EMAIL_ALREADY_IN_USE":
                return "That email address is already linked to another account."
            case "EMAIL_ALREADY_SET":
                return "This account already has an email address."
            case "EMAIL_ALREADY_VERIFIED":
                return "This email address is already verified."
            case "CHALLENGE_CODE_INVALID":
                return "That code was not correct. Check it and try again."
            case "CHALLENGE_ALREADY_USED":
                return "That code has already been used. Send a new code and try again."
            case "CHALLENGE_EXPIRED", "CHALLENGE_INVALID":
                return ProfileEmailAttachmentError.invalidOrExpiredChallenge.localizedDescription
            case "RATE_LIMIT_EXCEEDED":
                return "Too many codes were requested. Please wait and try again."
            case "FEATURE_UNAVAILABLE":
                return ProfileEmailAttachmentError.unavailable.localizedDescription
            default:
                return "Email verification could not be completed. Please try again."
            }
        }
        if error is URLError {
            return "Check your internet connection and try again."
        }
        if let apiError = error as? APIClientError, case .signedOut = apiError {
            return "Your session ended. Sign in again to verify your email address."
        }
        return "Email verification could not be completed. Please try again."
    }
}
