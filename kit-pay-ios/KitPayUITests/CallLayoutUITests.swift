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
        let row = app.otherElements.matching(identifier: "call.banner.row").firstMatch
        let end = app.buttons.matching(identifier: "call.banner.end").firstMatch
        let mute = app.buttons.matching(identifier: "call.banner.mute").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertTrue(mute.exists)

        let messages = app.buttons["Messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 10))
        messages.tap()
        let navigation = app.navigationBars.matching(identifier: "Chats").firstMatch
        XCTAssertTrue(navigation.waitForExistence(timeout: 10))
        var settlingRowFrame = CGRect.zero
        var settlingNavigationFrame = CGRect.zero
        let settled = NSPredicate { _, _ in
            // Each frame read performs a remote AX query. Reuse this measurement so
            // a second lookup cannot consume the wait after correct geometry was read.
            let rowFrame = row.frame
            settlingRowFrame = rowFrame
            let navigationFrame = navigation.frame
            settlingNavigationFrame = navigationFrame
            return rowFrame.height > 0 && navigationFrame.minY >= rowFrame.maxY - 1
        }
        let settledExpectation = XCTNSPredicateExpectation(predicate: settled, object: app)
        let settledResult = XCTWaiter.wait(for: [settledExpectation], timeout: 20)
        retainGeometry("""
        settleResult=\(settledResult)
        lastRow=\(settlingRowFrame)
        lastNavigation=\(settlingNavigationFrame)
        """, named: "active-call-banner-settle")
        XCTAssertEqual(settledResult, .completed,
                       "Navigation must settle below the actual banner row")

        let reopen = app.buttons.matching(identifier: "Return to call with Amina Demo").firstMatch
        XCTAssertTrue(reopen.exists)
        // Keep one fresh measured frame per element for consistent diagnostics and
        // assertions without repeatedly querying the same live accessibility tree.
        let rowFrame = row.frame
        let returnFrame = reopen.frame
        let endFrame = end.frame
        let muteFrame = mute.frame
        let navigationFrame = navigation.frame
        let geometryDescription = """
        row=\(rowFrame)
        return=\(returnFrame)
        end=\(endFrame)
        mute=\(muteFrame)
        navigation=\(navigationFrame)
        """
        retainGeometry(geometryDescription, named: "active-call-banner-geometry")
        XCTAssertEqual(returnFrame.height, 56, accuracy: 1,
                       "The actual return-to-call surface must fill the entire banner row")
        XCTAssertEqual(rowFrame.height, 56, accuracy: 1)
        XCTAssertEqual(rowFrame.minY, returnFrame.minY, accuracy: 1)
        XCTAssertEqual(rowFrame.maxY, returnFrame.maxY, accuracy: 1)
        XCTAssertEqual(endFrame.height, 44, accuracy: 1)
        XCTAssertEqual(muteFrame.height, 44, accuracy: 1)
        XCTAssertEqual(endFrame.midY, rowFrame.midY, accuracy: 1)
        XCTAssertEqual(muteFrame.midY, rowFrame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(rowFrame.maxY - endFrame.maxY, 8,
                                 "The banner must not leave a notch-sized gap below its controls")
        let statusBar = app.statusBars.firstMatch
        if statusBar.exists {
            XCTAssertGreaterThanOrEqual(rowFrame.minY, statusBar.frame.maxY - 1,
                                        "Controls must sit below the system status area")
        }
        XCTAssertGreaterThanOrEqual(navigationFrame.minY, rowFrame.maxY - 1)
        XCTAssertLessThanOrEqual(navigationFrame.minY - rowFrame.maxY, 16,
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

    private func retainGeometry(_ description: String, named name: String) {
        print("[KitPayCallBannerGeometry] \(description)")
        let attachment = XCTAttachment(string: description)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
