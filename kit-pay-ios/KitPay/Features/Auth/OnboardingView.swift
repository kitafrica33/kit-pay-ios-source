import SwiftUI

/// The signed-out surface: one full-bleed screen in the app's unauthenticated design language
/// (the same light canvas, brand badge, and open layout the PIN and biometric screens use —
/// no floating card over a decorative backdrop).
///
/// A phone number is the only way in for someone new: the customer enters their number and the
/// backend decides whether that is a first-time registration or a returning login. Email and
/// password exist solely as a restrained secondary sign-in for accounts that already attached
/// an email, and email recovery lives inside that email path — never on the front screen.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var signInMethod: SignInMethod = .phone
    @State private var accountScreen: EmailAccountScreen = .signIn
    @State private var phone = ""
    @State private var authenticationCode = ""
    @FocusState private var authenticationCodeFieldIsFocused: Bool

    @State private var email = ""
    // Passwords and account tokens intentionally live only in process-local SwiftUI state.
    @State private var password = ""
    @State private var verificationToken = ""
    @State private var recoveryEmail = ""
    @State private var resetToken = ""
    @State private var resetPassword = ""
    @State private var resetPasswordConfirmation = ""
    @State private var feedbackMessage: String?

    /// Whether the authentication surface is covered because the app is not frontmost.
    ///
    /// Derived from the live scene phase, never latched. This used to be `@State` written in
    /// `onAppear` and refreshed only in `onChange(of: scenePhase)`: if the phase read as
    /// anything but active at the moment onboarding first appeared — a slow cold launch, where
    /// this screen is not built until protected-state restore and the capabilities request have
    /// both finished — the cover went up, and with no *further* phase change to react to it
    /// never came down. The customer got a screen reading "Authentication details hidden" over
    /// their own sign-in form, with no way back except backgrounding the app or force-quitting.
    private var concealSensitiveContent: Bool {
        AuthenticationSecretLifecyclePolicy.shouldConceal(sceneIsActive: scenePhase == .active)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                KitAuthBackground()

                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 24)
                        header
                        VStack(alignment: .leading, spacing: 18) {
                            accessContent
                            if model.isLoading {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Please wait…")
                                        .font(.footnote.weight(.medium))
                                }
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(KitColor.secondaryText)
                            }
                            if let feedbackMessage {
                                Label(feedbackMessage, systemImage: "checkmark.circle.fill")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(KitColor.green)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 12)
                        Label("End-to-end encrypted", systemImage: "lock.shield.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KitColor.secondaryText)
                        Spacer(minLength: 18)
                    }
                    .padding(.horizontal, 26)
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityHidden(concealSensitiveContent)
            }
        }
        .onAppear {
            reconcileCapabilities()
        }
        .onChange(of: capabilitySignature) { _, _ in
            reconcileCapabilities()
        }
        .onChange(of: signInMethod) { previous, current in
            if previous == .email, current != .email { password = "" }
            feedbackMessage = nil
        }
        .onChange(of: model.pendingChallenge?.id) { previous, current in
            if previous != current {
                authenticationCode = ""
                // A replacement challenge (phone code accepted, two-factor step issued) swaps
                // the input field; put the keyboard straight back on it.
                if current != nil { authenticationCodeFieldIsFocused = true }
            }
        }
        .onChange(of: model.pendingDeepLink) { _, link in
            applyDeepLink(link)
        }
        .onAppear { applyDeepLink(model.pendingDeepLink) }
        .onDisappear {
            clearAccountSecrets()
        }
        .overlay {
            if concealSensitiveContent {
                KitColor.deepNavy
                    .overlay {
                        Label("Authentication details hidden", systemImage: "eye.slash.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .ignoresSafeArea()
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isModal)
            }
        }
    }

    /// The canonical Kit lockup — the master-SVG-derived brand asset used app-wide — on the
    /// shared auth canvas.
    private var header: some View {
        VStack(spacing: 12) {
            KitLogoView(tint: KitColor.navy)
                .frame(height: 56)
            Text("Money, messages and calls—together.")
                .font(.title3.weight(.medium))
                .foregroundStyle(KitColor.secondaryText)
                .multilineTextAlignment(.center)
                // Launch UI tests anchor on this identifier now that the wordmark
                // is a Shape-based logo rather than a static text.
                .accessibilityIdentifier("onboarding-wordmark")
        }
    }

    private var accessPolicy: PhoneFirstAuthAccessPolicy {
        PhoneFirstAuthAccessPolicy(capabilities: model.capabilities)
    }

    @ViewBuilder
    private var accessContent: some View {
        if model.pendingChallenge != nil {
            authenticationChallengeForm
        } else {
            switch accountScreen {
            case .signIn:
                signInForm
            case .verification:
                verificationForm
            case .forgotPassword:
                forgotPasswordForm
            case .resetPassword:
                resetPasswordForm
            }
        }
    }

    @ViewBuilder
    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Kit Pay")
                .font(.title2.bold())
                .foregroundStyle(KitColor.primaryText)

            switch accessPolicy.primaryRoute {
            case .phone:
                if signInMethod == .email, accessPolicy.offersEmailSecondary {
                    emailSignInFields
                } else {
                    phoneSignInFields
                }
            case .email:
                emailSignInFields
            case .unavailable:
                Label(
                    "Sign-in methods are temporarily unavailable. Reconnect and try again.",
                    systemImage: "wifi.exclamationmark"
                )
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var phoneSignInFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter your phone number to continue.")
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("🇺🇬 +256")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(KitColor.secondaryText)
                TextField("7XX XXX XXX", text: Binding(
                    get: { UgandaMobileMoneyPhone.spacedNationalDigits(from: phone) },
                    set: { phone = UgandaMobileMoneyPhone.nationalDigits(from: $0) }
                ))
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .font(.title3.weight(.semibold).monospacedDigit())
                .disabled(model.isLoading)
            }
            .authField()

            Button {
                feedbackMessage = nil
                Task { await model.requestOTP(phone: phone) }
            } label: {
                Label("Continue", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .tint(KitColor.green)
            .disabled(UgandaMobileMoneyPhone.apiValue(from: phone) == nil || model.isLoading)

            Text("Kit sends one SMS to verify this number. Carrier rates may apply.")
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)

            if accessPolicy.offersEmailSecondary {
                Button("Sign in with email instead") {
                    feedbackMessage = nil
                    signInMethod = .email
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(KitColor.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                .disabled(model.isLoading)
            }
        }
    }

    private var emailSignInFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use the email and password for your existing account.")
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Email address", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .disabled(model.isLoading)
                .authField()
            SecureField("Password", text: $password)
                .textContentType(.password)
                .disabled(model.isLoading)
                .authField()

            Button {
                let submittedEmail = email
                let submittedPassword = password
                feedbackMessage = nil
                Task {
                    let succeeded = await model.loginWithEmail(
                        email: submittedEmail,
                        password: submittedPassword
                    )
                    if AuthenticationSecretLifecyclePolicy.shouldClear(
                        afterSuccessfulRequest: succeeded
                    ) {
                        password = ""
                    }
                }
            } label: {
                Label("Sign in", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .tint(KitColor.green)
            .disabled(!EmailAccountValidation.isValidEmail(email) || password.isEmpty || model.isLoading)

            // Recovery belongs to the email path alone. Verification and reset complete
            // already-issued tokens, so those routes intentionally remain reachable when
            // issuance flags are later disabled.
            if model.emailRecoveryAvailable {
                Button("Forgot password?") { openForgotPassword() }
                    .frame(maxWidth: .infinity)
                    .disabled(model.isLoading)
            }
            HStack {
                Button("Verify email") { openVerification() }
                    .disabled(model.isLoading)
                Spacer()
                Button("Use reset token") { openResetPassword() }
                    .disabled(model.isLoading)
            }
            .font(.subheadline.weight(.medium))

            if accessPolicy.offersEmailSecondary {
                Button("Use phone number instead") {
                    feedbackMessage = nil
                    password = ""
                    signInMethod = .phone
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(KitColor.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                .disabled(model.isLoading)
            }
        }
    }

    /// The one-time-code step, on the same full-bleed surface as the rest of sign-in.
    ///
    /// Everything scales instead of assuming a tall portrait phone: the code entry sizes with
    /// Dynamic Type and shrinks before it clips, and the whole step lives in the shared
    /// ScrollView, so a small iPhone with the keyboard up — or landscape — scrolls rather
    /// than truncating the actions.
    @ViewBuilder
    private var authenticationChallengeForm: some View {
        if let challenge = model.pendingChallenge {
            VStack(alignment: .leading, spacing: 16) {
                Text(challenge.kind == .phoneOTP ? "Check your messages" : "Two-factor verification")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)
                Text(challengeInstructions(challenge))
                    .foregroundStyle(KitColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                authenticationCodeEntry(for: challenge)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let expired = model.pendingAuthenticationChallengeIsExpired(at: context.date)
                    let resendDelay = model.pendingAuthenticationResendDelay(at: context.date)
                    VStack(spacing: 12) {
                        Button {
                            let submittedCode = authenticationCode
                            authenticationCode = ""
                            feedbackMessage = nil
                            Task {
                                _ = await model.verifyAuthenticationCode(submittedCode)
                            }
                        } label: {
                            Text("Verify and sign in")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 18))
                        .tint(KitColor.green)
                        .disabled(
                            expired || !challengeCodeIsValid(challenge) || model.isLoading
                        )

                        if expired {
                            Label(
                                "This sign-in code has expired. Start again to request a new one.",
                                systemImage: "clock.badge.exclamationmark"
                            )
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(KitColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        } else if challenge.kind == .phoneOTP {
                            if let resendDelay {
                                Button(
                                    resendDelay > 0
                                        ? "Resend in \(resendDelay)s"
                                        : "Resend code"
                                ) {
                                    authenticationCode = ""
                                    feedbackMessage = nil
                                    Task {
                                        if await model.resendPhoneAuthenticationCode() {
                                            feedbackMessage =
                                                "The same code was sent again. Earlier messages for this sign-in still work."
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .disabled(resendDelay > 0 || model.isLoading)
                            } else {
                                Label(
                                    "Start over to request another sign-in code.",
                                    systemImage: "arrow.counterclockwise"
                                )
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(KitColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Button("Start over") {
                            authenticationCode = ""
                            model.resetPendingAuthentication()
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(model.isLoading)
                    }
                }
            }
        }
    }

    private var verificationForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountBackButton("Back to sign in")
            Text("Verify your email")
                .font(.title2.bold())
                .foregroundStyle(KitColor.primaryText)
            Text("Paste the secure verification token from your Kit Pay email.")
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Verification token", text: $verificationToken)
                .keyboardType(.asciiCapable)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(model.isLoading)
                .authField()
                .onChange(of: verificationToken) { _, value in
                    verificationToken = opaqueTokenInput(value)
                }

            Button {
                let submittedToken = verificationToken
                feedbackMessage = nil
                Task {
                    if let verifiedEmail = await model.verifyEmail(token: submittedToken) {
                        verificationToken = ""
                        email = verifiedEmail
                        returnToSignIn(message: "Email verified. Sign in to continue.")
                    }
                }
            } label: {
                Text("Verify email")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .tint(KitColor.green)
            .disabled(
                !EmailAccountValidation.isValidOpaqueToken(verificationToken)
                    || model.isLoading
            )
        }
    }

    private var forgotPasswordForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountBackButton("Back to sign in")
            Text("Reset your password")
                .font(.title2.bold())
                .foregroundStyle(KitColor.primaryText)
            Text("We will email reset instructions if the address belongs to an eligible account.")
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Email address", text: $recoveryEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .disabled(model.isLoading)
                .authField()

            Button {
                let submittedEmail = recoveryEmail
                feedbackMessage = nil
                Task {
                    if let message = await model.requestPasswordReset(email: submittedEmail) {
                        feedbackMessage = message
                        accountScreen = .resetPassword
                    }
                }
            } label: {
                Text("Send reset instructions")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .tint(KitColor.green)
            .disabled(!EmailAccountValidation.isValidEmail(recoveryEmail) || model.isLoading)
        }
    }

    private var resetPasswordForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountBackButton("Back to sign in")
            Text("Choose a new password")
                .font(.title2.bold())
                .foregroundStyle(KitColor.primaryText)
            Text("Paste the single-use token from your password reset email.")
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Reset token", text: $resetToken)
                .keyboardType(.asciiCapable)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(model.isLoading)
                .authField()
                .onChange(of: resetToken) { _, value in
                    resetToken = opaqueTokenInput(value)
                }
            SecureField("New password", text: $resetPassword)
                .textContentType(.newPassword)
                .disabled(model.isLoading)
                .authField()
            SecureField("Confirm new password", text: $resetPasswordConfirmation)
                .textContentType(.newPassword)
                .disabled(model.isLoading)
                .authField()
            Text("Use at least 12 characters with uppercase, lowercase, and a number.")
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)

            Button {
                submitPasswordReset()
            } label: {
                Text("Update password")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .tint(KitColor.green)
            .disabled(
                !EmailAccountValidation.isValidOpaqueToken(resetToken)
                    || resetPassword.isEmpty
                    || resetPasswordConfirmation.isEmpty
                    || model.isLoading
            )
        }
    }

    private func accountBackButton(_ title: String) -> some View {
        Button {
            returnToSignIn()
        } label: {
            Label(title, systemImage: "chevron.left")
                .font(.subheadline.weight(.semibold))
        }
        .disabled(model.isLoading)
    }

    private var capabilitySignature: String {
        [
            model.phoneOTPAvailable,
            model.emailPasswordAvailable,
            model.emailRecoveryAvailable,
        ].map { String($0) }.joined(separator: ":")
    }

    /// Puts the customer on the screen a verification or recovery link completes, with the token
    /// already filled in.
    ///
    /// The token is placed in the field and nothing else happens: the customer still taps the
    /// button. An inbound URL can be sent by any app on the device, so it is allowed to choose a
    /// screen and never to spend a token.
    private func applyDeepLink(_ link: KitDeepLink?) {
        guard let link, model.pendingChallenge == nil else { return }
        // Both screens are unconditional completion routes, so they open whatever the capability
        // rollout currently says about email sign-in. The email path behind them only renders
        // when email sign-in is actually offered, so backing out never lands on a disabled method.
        if model.emailPasswordAvailable { signInMethod = .email }
        accountScreen = link.screen
        switch link {
        case let .verifyEmail(token):
            verificationToken = token
        case let .resetPassword(token):
            resetToken = token
            resetPassword = ""
            resetPasswordConfirmation = ""
        }
        feedbackMessage = nil
        model.consumeDeepLink(link)
    }

    private var emailNavigationPolicy: EmailAccountNavigationPolicy {
        EmailAccountNavigationPolicy(capabilities: model.capabilities)
    }

    private func reconcileCapabilities() {
        if model.pendingChallenge == nil {
            if !emailNavigationPolicy.allows(accountScreen) {
                clearAccountSecrets()
                accountScreen = .signIn
                feedbackMessage = nil
            }
            if signInMethod == .phone, !model.phoneOTPAvailable, model.emailPasswordAvailable {
                signInMethod = .email
            } else if signInMethod == .email,
                      !model.emailPasswordAvailable,
                      model.phoneOTPAvailable {
                password = ""
                signInMethod = .phone
            }
        }
    }

    private func openVerification() {
        guard emailNavigationPolicy.allows(.verification), !model.isLoading else { return }
        model.resetPendingAuthentication()
        verificationToken = ""
        password = ""
        accountScreen = .verification
        feedbackMessage = nil
    }

    private func openForgotPassword() {
        guard emailNavigationPolicy.allows(.forgotPassword), !model.isLoading else { return }
        model.resetPendingAuthentication()
        recoveryEmail = EmailAccountValidation.normalizeEmail(email)
        password = ""
        accountScreen = .forgotPassword
        feedbackMessage = nil
    }

    private func openResetPassword() {
        guard emailNavigationPolicy.allows(.resetPassword), !model.isLoading else { return }
        model.resetPendingAuthentication()
        clearAccountSecrets()
        accountScreen = .resetPassword
        feedbackMessage = nil
    }

    private func submitPasswordReset() {
        let submittedToken = resetToken
        let submittedPassword = resetPassword
        let submittedConfirmation = resetPasswordConfirmation
        feedbackMessage = nil

        Task {
            let outcome = await model.resetPassword(
                token: submittedToken,
                password: submittedPassword,
                passwordConfirmation: submittedConfirmation
            )
            switch outcome {
            case .completed:
                resetToken = ""
                resetPassword = ""
                resetPasswordConfirmation = ""
                returnToSignIn(message: "Password updated. Sign in with your new password.")
            case .completionUncertain:
                // A single-use token may have been consumed even when the response was lost.
                // Never retain the token/passwords or invite an unsafe replay across that boundary.
                resetToken = ""
                resetPassword = ""
                resetPasswordConfirmation = ""
                returnToSignIn(
                    message: "Your password may have been updated. Try signing in with the new password; request a fresh reset email if it was not."
                )
            case .failed:
                break
            }
        }
    }

    private func returnToSignIn(message: String? = nil) {
        guard !model.isLoading else { return }
        model.resetPendingAuthentication()
        clearAccountSecrets()
        accountScreen = .signIn
        feedbackMessage = message
    }

    private func clearAccountSecrets() {
        password = ""
        verificationToken = ""
        resetToken = ""
        resetPassword = ""
        resetPasswordConfirmation = ""
        authenticationCode = ""
    }

    private func challengeInstructions(_ challenge: AuthChallenge) -> String {
        let destination = challenge.destination ?? model.pendingPhone ?? "your enrolled method"
        if challenge.kind == .phoneOTP {
            let phoneDestination = model.pendingPhone ?? destination
            return "Enter the six-digit code sent to \(UgandaMobileMoneyPhone.internationalDisplayValue(from: phoneDestination))."
        }
        if isAuthenticatorChallenge(challenge) {
            return "Enter the six-digit code from your authenticator app, or use a recovery code."
        }
        return "Enter the verification code sent to \(destination)."
    }

    /// One-time-code entry that keeps system autofill (`.oneTimeCode` on a real text field) and
    /// fits everywhere: the type scales with Dynamic Type and shrinks before clipping instead
    /// of assuming a fixed 32-point layout. The field focuses itself when the challenge appears,
    /// and VoiceOver announces what it is — the "000000" placeholder is a visual hint only.
    private func authenticationCodeEntry(for challenge: AuthChallenge) -> some View {
        Group {
            if isAuthenticatorChallenge(challenge) {
                SecureField("Authenticator or recovery code", text: $authenticationCode)
                    .font(.title3.weight(.semibold).monospaced())
                    .accessibilityLabel("Authenticator or recovery code")
                    .accessibilityHint(
                        "Enter the six-digit code from your authenticator app, or a saved recovery code."
                    )
            } else {
                TextField("000000", text: $authenticationCode)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .accessibilityLabel("Verification code")
                    .accessibilityHint("Enter the six-digit code Kit sent you.")
            }
        }
        .keyboardType(isAuthenticatorChallenge(challenge) ? .asciiCapable : .numberPad)
        .textContentType(.oneTimeCode)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.5)
        .lineLimit(1)
        .privacySensitive()
        .disabled(model.isLoading)
        .focused($authenticationCodeFieldIsFocused)
        .accessibilityIdentifier("authentication-code-field")
        .authField()
        .onChange(of: authenticationCode) { _, value in
            if !isAuthenticatorChallenge(challenge) {
                // Canonicalize, don't just filter: localized keyboards and pasted text produce
                // numerals the strict ASCII submission policy rejects, which used to leave a
                // visually full field with a verify button that never enabled.
                authenticationCode = AuthenticationCodePolicy.sanitizedSixDigitEntry(value)
            } else {
                authenticationCode = String(value.filter { !$0.isNewline }.prefix(64))
            }
        }
        .onAppear { authenticationCodeFieldIsFocused = true }
    }

    private func challengeCodeIsValid(_ challenge: AuthChallenge) -> Bool {
        AuthenticationCodePolicy.normalizedCode(authenticationCode, for: challenge) != nil
    }

    private func isAuthenticatorChallenge(_ challenge: AuthChallenge) -> Bool {
        challenge.kind == .twoFactor
            && challenge.method?.caseInsensitiveCompare("totp") == .orderedSame
    }

    private func opaqueTokenInput(_ value: String) -> String {
        String(value.filter { !$0.isWhitespace }.prefix(256))
    }
}

private enum SignInMethod: Equatable {
    case phone
    case email
}

private extension View {
    func authField() -> some View {
        padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.72), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
    }
}
