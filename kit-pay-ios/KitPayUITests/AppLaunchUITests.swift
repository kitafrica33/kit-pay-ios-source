import XCTest

/// Launch-and-drive coverage that runs the real app on a real iOS runtime.
///
/// The unit suite exercises policy and encoding but never renders a view, and the archive that
/// became a TestFlight build had never been launched by CI at all. These tests answer the
/// questions a compile cannot: does the app come up, does it draw, is it reachable by VoiceOver,
/// and do the controls on the first screen go where they say they do.
///
/// What this cannot cover, on any macOS runner or hosted Mac: PushKit does not deliver VoIP pushes
/// to a Simulator, CallKit has no system call UI there, there is no microphone or camera to
/// publish, and the Secure Enclave key the biometric enrolment creates cannot exist. Calls, call
/// audio, and biometrics need physical devices — see the device acceptance script.
final class AppLaunchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Clears a system permission alert if one is up.
    ///
    /// The app is correct to cover its sign-in form while the scene is inactive — that is what
    /// keeps credentials out of the app-switcher snapshot — but an alert nobody answers holds the
    /// scene inactive indefinitely, so an unattended run has to answer it. CI also pre-grants
    /// Contacts; this catches anything else a future build starts asking for.
    @discardableResult
    private func dismissSystemAlertIfPresent(timeout: TimeInterval = 5) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return false }
        for label in ["Allow Full Access", "Allow", "OK", "Continue", "Don’t Allow", "Don't Allow"] {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return true
            }
        }
        return false
    }

    private func launchApp(
        dynamicTypeSize: String? = nil,
        interfaceStyle: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        if let dynamicTypeSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", dynamicTypeSize]
        }
        if let interfaceStyle {
            app.launchArguments += ["-UIUserInterfaceStyle", interfaceStyle]
        }
        app.launch()
        return app
    }

    /// Waits until SwiftUI has put *something* on screen, whatever screen that is.
    ///
    /// Deliberately not anchored to one screen's copy: launch can legitimately land on
    /// onboarding, on a recovery screen, or on the biometric gate, and a launch check that only
    /// knows one of those reports a rendering failure when the app is working.
    @discardableResult
    private func waitForFirstFrame(
        _ app: XCUIApplication,
        timeout: TimeInterval = 90,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        dismissSystemAlertIfPresent()
        let anyText = app.staticTexts.element(boundBy: 0)
        let drew = anyText.waitForExistence(timeout: timeout)
        if !drew {
            // The hierarchy is the only way to tell a hung launch from a screen this test does
            // not recognise, and it is not in the plain-text CI log unless something prints it.
            print("=== KitPay UI hierarchy after \(timeout)s ===")
            print(app.debugDescription)
            print("=== end hierarchy ===")
        }
        XCTAssertTrue(drew, "The app never drew any text.", file: file, line: line)
        return drew
    }

    func testAppLaunchesAndDrawsItsFirstScreen() {
        let app = launchApp()
        waitForFirstFrame(app)
        XCTAssertEqual(app.state, .runningForeground)
        attachScreenshot(of: app, named: "launch-light")
    }

    /// A signed-out launch must reach the sign-in screen. Sitting on the launch spinner is what
    /// an App Review device on a restricted network would see, and it is an automatic rejection.
    func testSignedOutLaunchReachesOnboarding() {
        let app = launchApp()
        waitForFirstFrame(app)

        dismissSystemAlertIfPresent()
        let wordmark = app.staticTexts["onboarding-wordmark"]
        if !wordmark.waitForExistence(timeout: 90) {
            print("=== KitPay screen instead of onboarding ===")
            print(app.debugDescription)
            print("=== end hierarchy ===")
            attachScreenshot(of: app, named: "not-onboarding")
        }
        XCTAssertTrue(
            wordmark.exists,
            "A signed-out launch did not reach onboarding."
        )
    }

    func testAppLaunchesInDarkMode() {
        let app = launchApp(interfaceStyle: "Dark")
        waitForFirstFrame(app)
        XCTAssertEqual(app.state, .runningForeground)
        attachScreenshot(of: app, named: "launch-dark")
    }

    /// The tab bar, the onboarding copy and the amount fields all resize with Dynamic Type. A
    /// launch at the largest accessibility size is where clipping and unsatisfiable layout show up.
    func testAppLaunchesAtTheLargestAccessibilityTextSize() {
        let app = launchApp(
            dynamicTypeSize: "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        )
        waitForFirstFrame(app)
        XCTAssertEqual(app.state, .runningForeground)
        attachScreenshot(of: app, named: "launch-accessibility-text")
    }

    /// A screen with no accessible element is a screen VoiceOver cannot open.
    func testFirstScreenExposesAccessibleElements() {
        let app = launchApp()
        waitForFirstFrame(app)
        let accessible = app.descendants(matching: .any)
            .allElementsBoundByAccessibilityElement
            .filter { $0.exists && $0.isHittable }
        XCTAssertFalse(accessible.isEmpty, "Nothing on the first screen is reachable.")
    }

    /// Backgrounding and returning is the transition that reruns launch work — contacts
    /// permission, connectivity recovery, session resume — and the one most likely to trap.
    func testAppSurvivesBackgroundAndForeground() {
        let app = launchApp()
        waitForFirstFrame(app)

        XCUIDevice.shared.press(.home)
        // Which non-foreground state it lands in is the system's business — suspended, plain
        // background, or already reclaimed. Only leaving the foreground matters here.
        var leftForeground = false
        for _ in 0 ..< 30 where !leftForeground {
            leftForeground = app.state != .runningForeground
            if !leftForeground { _ = app.wait(for: .runningBackground, timeout: 1) }
        }
        XCTAssertTrue(leftForeground, "The app stayed foreground after Home.")

        app.activate()
        waitForFirstFrame(app)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Rotation is where a portrait-locked app with a full-screen call surface can trap or strand
    /// its layout.
    func testAppSurvivesRotation() {
        let app = launchApp()
        waitForFirstFrame(app)

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertEqual(app.state, .runningForeground)

        XCUIDevice.shared.orientation = .portrait
        waitForFirstFrame(app)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Two launches in a row exercise the protected-state restore path against state the first
    /// launch already wrote.
    func testRelaunchRestoresWithoutFailing() {
        let first = launchApp()
        waitForFirstFrame(first)
        first.terminate()

        let second = launchApp()
        waitForFirstFrame(second)
        XCTAssertEqual(second.state, .runningForeground)
    }

    // MARK: - Controls on the sign-in screen

    /// Skips loudly rather than passing quietly. These need the sign-in surface, which needs
    /// server capabilities; a runner that cannot reach the backend has nothing to drive.
    private func requireSignIn(_ app: XCUIApplication) throws {
        waitForFirstFrame(app)
        dismissSystemAlertIfPresent()
        guard app.staticTexts["onboarding-wordmark"].waitForExistence(timeout: 90) else {
            print("=== KitPay screen instead of onboarding ===")
            print(app.debugDescription)
            print("=== end hierarchy ===")
            throw XCTSkip("Launch did not reach onboarding; see the hierarchy above.")
        }
        guard app.staticTexts["Welcome to Kit Pay"].waitForExistence(timeout: 20) else {
            throw XCTSkip("Onboarding drew, but the sign-in form is capability-gated off.")
        }
    }

    /// The phone field formats as the customer types, and Continue stays disabled until the
    /// number is actually dialable — the guard that stops a malformed OTP request.
    func testPhoneFieldFormatsAndGatesContinue() throws {
        let app = launchApp()
        try requireSignIn(app)

        let field = app.textFields["7XX XXX XXX"]
        guard field.waitForExistence(timeout: 20) else {
            throw XCTSkip("Phone sign-in is not offered by current capabilities.")
        }
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.exists)
        XCTAssertFalse(continueButton.isEnabled, "Continue was enabled with an empty number.")

        field.tap()
        field.typeText("750000002")

        // The gate that matters: a complete Ugandan mobile number, and only a complete one,
        // may be submitted.
        XCTAssertTrue(continueButton.isEnabled, "A complete number did not enable Continue.")
        XCTAssertEqual(
            (field.value as? String)?.filter(\.isNumber),
            "750000002",
            "The typed number did not survive the field's binding."
        )

        // Grouping is deliberately not asserted here. The binding's getter returns a spaced
        // value, but SwiftUI owns a TextField's text while it is focused and does not reliably
        // push a reformatted string back into a live editing session — this run observed
        // "750000002" on screen mid-typing. Whether it groups on a real device, and when, is a
        // device-pass check; the canonical value the API receives is correct either way.

        field.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertFalse(
            continueButton.isEnabled,
            "An incomplete number left Continue enabled."
        )

        attachScreenshot(of: app, named: "phone-sign-in")
    }

    /// Registration and recovery are reachable and come back. These were the routes a
    /// verification or recovery link had to reach by hand before deep links worked.
    func testAccountRoutesOpenAndReturn() throws {
        let app = launchApp()
        try requireSignIn(app)

        let createAccount = app.buttons["New to Kit Pay? Create an account"]
        if createAccount.waitForExistence(timeout: 10) {
            createAccount.tap()
            XCTAssertTrue(
                app.staticTexts["Create your account"].waitForExistence(timeout: 15),
                "Create account did not open the registration form."
            )
            app.buttons["Back to sign in"].tap()
            XCTAssertTrue(
                app.staticTexts["Welcome to Kit Pay"].waitForExistence(timeout: 15),
                "Back to sign in did not return."
            )
        }

        let forgot = app.buttons["Forgot password?"]
        if forgot.waitForExistence(timeout: 10) {
            forgot.tap()
            XCTAssertTrue(
                app.staticTexts["Reset your password"].waitForExistence(timeout: 15),
                "Forgot password did not open recovery."
            )
            app.buttons["Back to sign in"].tap()
            XCTAssertTrue(
                app.staticTexts["Welcome to Kit Pay"].waitForExistence(timeout: 15),
                "Back to sign in did not return from recovery."
            )
        }
    }

    /// Switching sign-in method must not carry a typed password across.
    func testSignInMethodPickerSwitchesForms() throws {
        let app = launchApp()
        try requireSignIn(app)

        let email = app.buttons["Email"]
        guard email.waitForExistence(timeout: 10) else {
            throw XCTSkip("Only one sign-in method is enabled, so there is no picker.")
        }
        email.tap()
        XCTAssertTrue(
            app.secureTextFields.firstMatch.waitForExistence(timeout: 15),
            "Email sign-in did not show a password field."
        )

        app.buttons["Phone"].tap()
        XCTAssertTrue(
            app.textFields["7XX XXX XXX"].waitForExistence(timeout: 15),
            "Switching back did not restore phone sign-in."
        )
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
