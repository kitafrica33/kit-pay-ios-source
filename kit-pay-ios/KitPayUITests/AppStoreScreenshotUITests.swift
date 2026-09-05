import XCTest

#if APP_STORE_SCREENSHOTS
/// Captures real app UI with deterministic, synthetic data compiled only into this Debug job.
final class AppStoreScreenshotUITests: XCTestCase {
    private let fixtureArgument = "--kit-app-store-screenshot-fixture-v1"
    private let fixtureContactName = "Amina Demo"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testCaptureAppStoreScreenshots() {
        let app = XCUIApplication()
        app.launchArguments += [
            fixtureArgument,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_UG",
            "-UIUserInterfaceStyle", "Light",
        ]
        app.launch()

        require(app.staticTexts["Wallet balance"], in: app, message: "Fixture Home did not load")
        capture(app, named: "01-home")

        tap(app.buttons["Messages"], in: app, message: "Messages tab is unavailable")
        require(app.navigationBars["Chats"], in: app, message: "Chats did not open")
        require(
            app.staticTexts[fixtureContactName].firstMatch,
            in: app,
            message: "Primary fixture conversation is missing"
        )
        capture(app, named: "02-chats")

        app.staticTexts[fixtureContactName].firstMatch.tap()
        require(
            app.buttons["Open \(fixtureContactName)'s profile"].firstMatch,
            in: app,
            message: "Fixture conversation did not open"
        )
        require(
            app.staticTexts["Payment accepted"].firstMatch,
            in: app,
            message: "Fixture payment event is missing"
        )
        let newest = app.staticTexts["Yes — 6:00 PM works for me."].firstMatch
        require(newest, in: app, message: "The actual newest fixture message is missing")
        XCTAssertTrue(newest.isHittable, "First opening must reveal the actual newest message")
        capture(app, named: "03-conversation")

        let back = app.navigationBars.buttons.element(boundBy: 0)
        require(back, in: app, message: "Conversation has no back button")
        back.tap()
        require(app.navigationBars["Chats"], in: app, message: "Chats did not return")

        tap(app.buttons["Home"], in: app, message: "Home tab is unavailable")
        require(app.staticTexts["Wallet balance"], in: app, message: "Home did not return")

        tap(app.buttons["Mobile"], in: app, message: "Mobile money shortcut is unavailable")
        require(app.navigationBars["Mobile money"], in: app, message: "Mobile money did not open")
        require(app.staticTexts["MTN & Airtel"], in: app, message: "Mobile money fixture did not load")
        require(app.staticTexts["Demo MTN"], in: app, message: "Saved mobile money data is missing")
        capture(app, named: "04-mobile-money")
        tap(app.buttons["Close"], in: app, message: "Mobile money has no Close button")
        require(app.staticTexts["Wallet balance"], in: app, message: "Home did not return")

        tap(app.buttons["Bank"], in: app, message: "Bank transfer shortcut is unavailable")
        require(app.navigationBars["Bank"], in: app, message: "Bank did not open")
        require(
            app.staticTexts["Send to bank"],
            in: app,
            message: "Bank fixture did not load"
        )
        require(
            app.staticTexts[fixtureContactName].firstMatch,
            in: app,
            message: "Saved bank beneficiary data is missing"
        )
        capture(app, named: "05-bank-transfer")
        tap(app.buttons["Close"], in: app, message: "Bank transfer has no Close button")
        require(app.staticTexts["Wallet balance"], in: app, message: "Home did not return")

        tap(app.buttons["Calls"], in: app, message: "Calls tab is unavailable")
        require(app.navigationBars["Calls"], in: app, message: "Calls did not open")
        require(
            app.staticTexts[fixtureContactName].firstMatch,
            in: app,
            message: "Fixture call history is missing"
        )
        capture(app, named: "06-calls")

        tap(app.buttons["Profile"], in: app, message: "Profile tab is unavailable")
        require(app.navigationBars["Profile"], in: app, message: "Profile did not open")
        require(app.staticTexts["Kit Pay Demo"], in: app, message: "Fixture profile is missing")
        capture(app, named: "07-profile")
    }

    func testChatBottomPullOpensCameraOnlyAfterADeliberateRelease() {
        let app = XCUIApplication()
        app.launchArguments += [
            fixtureArgument,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_UG",
            "-UIUserInterfaceStyle", "Light",
        ]
        app.launch()
        require(app.staticTexts["Wallet balance"], in: app, message: "Fixture Home did not load")
        tap(app.buttons["Messages"], in: app, message: "Messages tab is unavailable")
        require(app.navigationBars["Chats"], in: app, message: "Chats did not open")
        let conversation = app.staticTexts[fixtureContactName].firstMatch
        require(conversation, in: app, message: "Primary fixture conversation is missing")
        // The row owns the tap action; its StaticText child can report isHittable=false.
        // Use XCTest's native row tap, as the marketing capture does, and verify navigation.
        conversation.tap()
        require(app.buttons["Open \(fixtureContactName)'s profile"].firstMatch, in: app,
                message: "Fixture conversation did not open")

        let timeline = app.scrollViews["conversation-timeline"]
        require(timeline, in: app, message: "Conversation timeline did not appear")
        let newest = app.staticTexts["Yes — 6:00 PM works for me."].firstMatch
        require(newest, in: app, message: "The actual newest fixture message did not appear")
        XCTAssertTrue(newest.isHittable, "Opening a chat must reveal the newest message")
        let closeCamera = app.buttons["Close camera"]
        XCTAssertFalse(closeCamera.waitForExistence(timeout: 1),
                       "Opening/layout anchoring must never open the camera")
        retainHierarchy(app, named: "camera-pull-before-short-drag")

        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: timeline.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.78)
        ))
        XCTAssertFalse(closeCamera.waitForExistence(timeout: 1),
                       "A short bottom pull must remain in the chat")
        retainHierarchy(app, named: "camera-pull-before-deliberate-drag")

        start.press(forDuration: 0.05, thenDragTo: timeline.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.25)
        ))
        // The real camera surface can request camera/microphone permission even though the
        // Simulator has no capture device. Resolve only those system prompts before closing it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0 ..< 2 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { break }
            for label in ["Allow", "OK", "Don’t Allow", "Don't Allow"] {
                if alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    break
                }
            }
        }
        if app.alerts["Camera"].exists { app.alerts["Camera"].buttons["OK"].tap() }
        retainHierarchy(app, named: "camera-pull-after-deliberate-release")
        tap(closeCamera, in: app, message: "A deliberate bottom pull did not open the real camera")
        require(timeline, in: app, message: "Closing camera did not restore the chat")
        XCTAssertFalse(closeCamera.waitForExistence(timeout: 1),
                       "The consumed release must not reopen camera after dismissal")

        tap(app.buttons["Open \(fixtureContactName)'s profile"].firstMatch, in: app,
            message: "Conversation profile is unavailable")
        tap(app.buttons["Search"], in: app, message: "Chat search is unavailable")
        require(app.textFields["Search messages & documents"], in: app,
                message: "Chat search field did not appear")
        require(app.keyboards.firstMatch, in: app, message: "Search keyboard did not appear")
        XCTAssertFalse(closeCamera.waitForExistence(timeout: 1),
                       "Keyboard resizing must not launch the camera")
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.85))
            .press(forDuration: 0.05, thenDragTo: timeline.coordinate(
                withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2)
            ))
        XCTAssertFalse(closeCamera.waitForExistence(timeout: 1),
                       "Pulling in search must never open the camera")
        tap(app.buttons["Done"], in: app, message: "Chat search could not close")
        XCTAssertFalse(closeCamera.waitForExistence(timeout: 1),
                       "Keyboard dismissal must not launch the camera")
    }

    private func tap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        require(element, in: app, message: message, file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(message): element is not hittable", file: file, line: line)
        element.tap()
    }

    private func require(
        _ element: XCUIElement,
        in app: XCUIApplication,
        message: String,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard element.waitForExistence(timeout: timeout) else {
            print("=== Kit Pay screenshot UI hierarchy ===")
            print(app.debugDescription)
            print("=== end hierarchy ===")
            XCTFail(message, file: file, line: line)
            return
        }
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        // Navigation and sheet titles can exist before their presentation animations finish.
        // A short fixed settle keeps the retained artwork free of half-transition frames.
        Thread.sleep(forTimeInterval: 0.35)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func retainHierarchy(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
