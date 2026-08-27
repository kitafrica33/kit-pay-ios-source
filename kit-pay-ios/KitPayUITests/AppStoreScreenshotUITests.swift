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
        require(app.navigationBars["Bank transfer"], in: app, message: "Bank transfer did not open")
        require(
            app.staticTexts["Saved beneficiaries"],
            in: app,
            message: "Bank transfer fixture did not load"
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
}
#endif
