import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var signInMethod: SignInMethod = .phone
    @State private var accountScreen: EmailAccountScreen = .signIn
    @State private var phone = ""
    @State private var authenticationCode = ""

    @State private var email = ""
    // Passwords and account tokens intentionally live only in process-local SwiftUI state.
    @State private var password = ""
    @State private var registrationName = ""
    @State private var registrationTag = ""
    @State private var registrationEmail = ""
    @State private var registrationPassword = ""
    @State private var registrationPasswordConfirmation = ""
    @State private var verificationEmail = ""
    @State private var verificationDestination: String?
    @State private var verificationExpiresAt: Date?
    @State private var verificationResendAvailableAt: Date?
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
        ZStack {
            LinearGradient(
                colors: [KitColor.deepNavy, KitColor.navy, KitColor.green.opacity(0.84)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(.white.opacity(0.13))
                .frame(width: 330, height: 330)
                .blur(radius: 4)
                .offset(x: 150, y: -320)
            Circle()
                .fill(KitColor.green.opacity(0.30))
                .frame(width: 280, height: 280)
                .blur(radius: 18)
                .offset(x: -170, y: 360)

            ScrollView {
                VStack(spacing: 26) {
                    Spacer(minLength: 42)
                    VStack(spacing: 14) {
                        KitLogoView(tint: .white)
                            .frame(height: 58)
                        Text("Money, messages and calls—together.")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                            // Launch UI tests anchor on this identifier now that the wordmark
                            // is a Shape-based logo rather than a static text.
                            .accessibilityIdentifier("onboarding-wordmark")
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        accessContent
                        if model.isLoading {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Please wait…")
                                    .font(.footnote.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.secondary)
                        }
                        if let feedbackMessage {
                            Label(feedbackMessage, systemImage: "checkmark.circle.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(KitColor.green)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(24)
                    .kitGlass(cornerRadius: 32)
                    .foregroundStyle(KitColor.primaryText)

                    HStack(spacing: 14) {
                        Label("End-to-end encrypted", systemImage: "lock.shield.fill")
                        Label("Offline ready", systemImage: "icloud.and.arrow.up")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 22)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityHidden(concealSensitiveContent)
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
            if previous != current { authenticationCode = "" }
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

    @ViewBuilder
    private var accessContent: some View {
        if model.pendingChallenge != nil {
            authenticationChallengeForm
        } else {
            switch accountScreen {
            case .signIn:
                signInForm
            case .registration:
                registrationForm
            case .verification:
                verificationForm
            case .forgotPassword:
                forgotPasswordForm
            case .resetPassword:
                resetPasswordForm
            }
        }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Kit Pay")
                .font(.title2.bold())

            if model.phoneOTPAvailable || model.emailPasswordAvailable {
                if model.phoneOTPAvailable, model.emailPasswordAvailable {
                    Picker("Sign-in method", selection: $signInMethod) {
                        ForEach(SignInMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isLoading)
                }

                if signInMethod == .phone, model.phoneOTPAvailable {
                    phoneSignInFields
                } else if model.emailPasswordAvailable {
                    emailSignInFields
                }

            } else {
                Label(
                    "Sign-in methods are temporarily unavailable. Reconnect and try again.",
                    systemImage: "wifi.exclamationmark"
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Verification and reset complete already-issued tokens, so these routes intentionally
            // remain reachable when issuance flags are later disabled.
            HStack {
                Button("Verify email") { openVerification() }
                    .disabled(model.isLoading)
                Spacer()
                Button("Use reset token") { openResetPassword() }
                    .disabled(model.isLoading)
            }
            .font(.subheadline.weight(.medium))

            if model.emailRecoveryAvailable {
                Button("Forgot password?") { openForgotPassword() }
                    .frame(maxWidth: .infinity)
                    .disabled(model.isLoading)
            }

            if model.emailRegistrationAvailable {
                Button("New to Kit Pay? Create an account") {
                    openRegistration()
                }
                .frame(maxWidth: .infinity)
                .disabled(model.isLoading)
            }
        }
    }

    private var phoneSignInFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter your phone number to receive a secure one-time code.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("🇺🇬 +256")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
        }
    }

    private var emailSignInFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use the email and password for your existing account.")
                .foregroundStyle(.secondary)
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
        }
    }

    @ViewBuilder
    private var authenticationChallengeForm: some View {
        if let challenge = model.pendingChallenge {
            VStack(alignment: .leading, spacing: 16) {
                Text(challenge.kind == .phoneOTP ? "Check your messages" : "Two-factor verification")
                    .font(.title2.bold())
                Text(challengeInstructions(challenge))
                    .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
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

    private var registrationForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountBackButton("Back to sign in")
            Text("Create your account")
                .font(.title2.bold())
            Text("Choose the name people will see and a unique Kit Pay @tag.")
                .foregroundStyle(.secondary)

            TextField("Username / display name", text: $registrationName)
                .textContentType(.name)
                .disabled(model.isLoading)
                .authField()
            HStack(spacing: 4) {
                Text("@")
                    .foregroundStyle(.secondary)
                TextField("unique_tag", text: Binding(
                    get: { registrationTag },
                    set: { registrationTag = EmailAccountValidation.normalizeTag($0) }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .disabled(model.isLoading)
            .authField()
            TextField("Email address", text: $registrationEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .disabled(model.isLoading)
                .authField()
            SecureField("Password", text: $registrationPassword)
                .textContentType(.newPassword)
                .disabled(model.isLoading)
                .authField()
            SecureField("Confirm password", text: $registrationPasswordConfirmation)
                .textContentType(.newPassword)
                .disabled(model.isLoading)
                .authField()
            Text("Use at least 12 characters with uppercase, lowercase, and a number.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                submitRegistration()
            } label: {
                Text("Create account")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .tint(KitColor.green)
            .disabled(
                registrationName.isEmpty
                    || registrationTag.isEmpty
                    || registrationEmail.isEmpty
                    || registrationPassword.isEmpty
                    || registrationPasswordConfirmation.isEmpty
                    || model.isLoading
            )
        }
    }

    private var verificationForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountBackButton("Back to sign in")
            Text("Verify your email")
                .font(.title2.bold())
            Text(verificationInstructions)
                .foregroundStyle(.secondary)
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

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = verificationExpiresAt.map { context.date >= $0 } ?? false
                let resendDelay = EmailVerificationChallengeTimingPolicy.secondsUntilResend(
                    availableAt: verificationResendAvailableAt,
                    now: context.date
                )
                VStack(alignment: .leading, spacing: 14) {
                    if let verificationExpiresAt, !expired {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                            Text("Current token expires in")
                            Text(verificationExpiresAt, style: .timer)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if expired {
                        Label(
                            "This token has expired. Send a new verification email.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                        expired
                            || !EmailAccountValidation.isValidOpaqueToken(verificationToken)
                            || model.isLoading
                    )

                    if model.emailRegistrationAvailable {
                        Divider().padding(.vertical, 4)
                        TextField("Email address for resend", text: $verificationEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .disabled(model.isLoading)
                            .authField()
                        Button(
                            resendDelay > 0
                                ? "Send again in \(resendDelay)s"
                                : "Send a new verification email"
                        ) {
                            let submittedEmail = verificationEmail
                            // A transport failure can occur after the server queues delivery, so
                            // begin the anti-throttle window at submission rather than response.
                            verificationResendAvailableAt =
                                EmailVerificationChallengeTimingPolicy.resendAvailableAt(from: Date())
                            feedbackMessage = nil
                            Task {
                                if let message = await model.resendEmailVerification(
                                    email: submittedEmail
                                ) {
                                    // The enumeration-safe resend response deliberately omits the
                                    // new token expiry. The backend also retires the prior token.
                                    verificationToken = ""
                                    verificationExpiresAt = nil
                                    feedbackMessage = message
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(
                            resendDelay > 0
                                || !EmailAccountValidation.isValidEmail(verificationEmail)
                                || model.isLoading
                        )
                    }
                }
            }
        }
    }

    private var forgotPasswordForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountBackButton("Back to sign in")
            Text("Reset your password")
                .font(.title2.bold())
            Text("We will email reset instructions if the address belongs to an eligible account.")
                .foregroundStyle(.secondary)

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
            Text("Paste the single-use token from your password reset email.")
                .foregroundStyle(.secondary)

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
                .foregroundStyle(.secondary)

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

    private var verificationInstructions: String {
        if let verificationDestination, !verificationDestination.isEmpty {
            return "Paste the secure verification token sent to \(verificationDestination)."
        }
        return "Paste the secure verification token from your Kit Pay email."
    }

    private var capabilitySignature: String {
        [
            model.phoneOTPAvailable,
            model.emailPasswordAvailable,
            model.emailRegistrationAvailable,
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
        // rollout currently says about email sign-in. The picker behind them only moves when
        // email sign-in is actually offered, so backing out never lands on a disabled method.
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

    private func openRegistration() {
        guard emailNavigationPolicy.allows(.registration), !model.isLoading else { return }
        model.resetPendingAuthentication()
        clearAccountSecrets()
        registrationEmail = email
        accountScreen = .registration
        feedbackMessage = nil
    }

    private func openVerification() {
        guard emailNavigationPolicy.allows(.verification), !model.isLoading else { return }
        model.resetPendingAuthentication()
        verificationEmail = EmailAccountValidation.normalizeEmail(email)
        verificationDestination = nil
        verificationExpiresAt = nil
        verificationResendAvailableAt = nil
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

    private func submitRegistration() {
        let name = registrationName
        let tag = registrationTag
        let submittedEmail = registrationEmail
        let submittedPassword = registrationPassword
        let submittedConfirmation = registrationPasswordConfirmation
        feedbackMessage = nil

        Task {
            guard let result = await model.registerWithEmail(
                name: name,
                tag: tag,
                email: submittedEmail,
                password: submittedPassword,
                passwordConfirmation: submittedConfirmation
            ) else { return }
            registrationPassword = ""
            registrationPasswordConfirmation = ""
            verificationEmail = result.user.email ?? EmailAccountValidation.normalizeEmail(submittedEmail)
            verificationDestination = result.challenge.destination
            verificationExpiresAt = EmailVerificationChallengeTimingPolicy.expirationDate(
                for: result.challenge
            )
            verificationResendAvailableAt =
                EmailVerificationChallengeTimingPolicy.resendAvailableAt(from: Date())
            registrationName = ""
            registrationTag = ""
            registrationEmail = ""
            verificationToken = ""
            accountScreen = .verification
            feedbackMessage = "We sent a verification token to \(result.challenge.destination)."
        }
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
        verificationExpiresAt = nil
        verificationResendAvailableAt = nil
        accountScreen = .signIn
        feedbackMessage = message
    }

    private func clearAccountSecrets() {
        password = ""
        registrationPassword = ""
        registrationPasswordConfirmation = ""
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

    private func authenticationCodeEntry(for challenge: AuthChallenge) -> some View {
        Group {
            if isAuthenticatorChallenge(challenge) {
                SecureField("Authenticator or recovery code", text: $authenticationCode)
            } else {
                TextField("000000", text: $authenticationCode)
            }
        }
        .keyboardType(isAuthenticatorChallenge(challenge) ? .asciiCapable : .numberPad)
        .textContentType(.oneTimeCode)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .multilineTextAlignment(.center)
        .font(.system(
            size: isAuthenticatorChallenge(challenge) ? 22 : 32,
            weight: .bold,
            design: .monospaced
        ))
        .privacySensitive()
        .disabled(model.isLoading)
        .authField()
        .onChange(of: authenticationCode) { _, value in
            if !isAuthenticatorChallenge(challenge) {
                authenticationCode = String(value.filter(\.isNumber).prefix(6))
            } else {
                authenticationCode = String(value.filter { !$0.isNewline }.prefix(64))
            }
        }
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

private enum SignInMethod: String, CaseIterable, Identifiable {
    case phone
    case email

    var id: String { rawValue }
    var title: String {
        switch self {
        case .phone: "Phone"
        case .email: "Email"
        }
    }
}

private extension View {
    func authField() -> some View {
        padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
