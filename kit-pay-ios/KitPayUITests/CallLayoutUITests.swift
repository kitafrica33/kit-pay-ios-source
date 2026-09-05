import XCTest

#if APP_STORE_SCREENSHOTS
final class CallLayoutUITests: XCTestCase {
    func testMinimizedCallClearsStatusAreaAndKeepsControlsCloseToBannerBottom() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += [
            "--kit-app-store-screenshot-fixture-v1",
            "--kit-call-layout-fixture-v1",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_UG",
        ]
        app.launch()

        let minimize = app.buttons["Minimize call"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 20))
        minimize.tap()
        let row = app.otherElements["call.banner.row"]
        let end = app.buttons["call.banner.end"]
        let mute = app.buttons["call.banner.mute"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertTrue(mute.exists)

        let messages = app.buttons["Messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 10))
        messages.tap()
        let navigation = app.navigationBars["Chats"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 10))
        let settled = NSPredicate { _, _ in
            row.frame.height > 0 && navigation.frame.minY >= row.frame.maxY - 1
        }
        expectation(for: settled, evaluatedWith: app)
        waitForExpectations(timeout: 5)

        let reopen = app.buttons["Return to call with Amina Demo"]
        XCTAssertTrue(reopen.exists)
        XCTAssertEqual(reopen.frame.height, 56, accuracy: 1,
                       "The actual return-to-call surface must fill the entire banner row")
        XCTAssertEqual(row.frame.height, 56, accuracy: 1)
        XCTAssertEqual(row.frame.minY, reopen.frame.minY, accuracy: 1)
        XCTAssertEqual(row.frame.maxY, reopen.frame.maxY, accuracy: 1)
        XCTAssertEqual(end.frame.height, 44, accuracy: 1)
        XCTAssertEqual(mute.frame.height, 44, accuracy: 1)
        XCTAssertEqual(end.frame.midY, row.frame.midY, accuracy: 1)
        XCTAssertEqual(mute.frame.midY, row.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(row.frame.maxY - end.frame.maxY, 8,
                                 "The banner must not leave a notch-sized gap below its controls")
        let statusBar = app.statusBars.firstMatch
        if statusBar.exists {
            XCTAssertGreaterThanOrEqual(row.frame.minY, statusBar.frame.maxY - 1,
                                        "Controls must sit below the system status area")
        }
        XCTAssertGreaterThanOrEqual(navigation.frame.minY, row.frame.maxY - 1)
        XCTAssertLessThanOrEqual(navigation.frame.minY - row.frame.maxY, 16,
                                 "The app must reserve the banner once, with only a small content gap")
        XCTAssertTrue(end.isHittable)
        XCTAssertTrue(mute.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "active-call-banner-safe-area"
        attachment.lifetime = .keepAlways
        add(attachment)

        reopen.tap()
        XCTAssertTrue(minimize.waitForExistence(timeout: 10))
        XCTAssertFalse(end.exists)
    }
}
#endif
