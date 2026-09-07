import XCTest

#if APP_STORE_SCREENSHOTS
/// Captures real app UI with deterministic, synthetic data compiled only into this Debug job.
final class AppStoreScreenshotUITests: XCTestCase {
    private let fixtureArgument = "--kit-app-store-screenshot-fixture-v1"
    private let fixtureContactName = "Amina Demo"
    private let fixtureConversationID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

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
        // Session configuration starts asynchronously after the microphone prompt. The
        // Simulator's no-device alert can arrive after the permission UI has disappeared;
        // an immediate `exists` snapshot misses it and leaves Close camera obstructed.
        let cameraAlert = app.alerts["Camera"]
        if cameraAlert.waitForExistence(timeout: 10) {
            XCTAssertTrue(
                cameraAlert.staticTexts["The camera is not available on this device."].exists,
                "Camera startup produced an unexpected error"
            )
            tap(cameraAlert.buttons["OK"], in: app, message: "Camera availability alert could not close")
        }
        let cameraReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: closeCamera
        )
        XCTAssertEqual(XCTWaiter.wait(for: [cameraReady], timeout: 10), .completed,
                       "Close camera must be tappable after permission and startup alerts settle")
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

    func testLongHistoryVerticalBubbleDragsPreserveReadingPosition() {
        let app = XCUIApplication()
        app.launchArguments += [
            fixtureArgument,
            "--kit-chat-long-history-scroll-fixture-v1",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_UG",
            "-UIUserInterfaceStyle", "Light",
        ]
        app.launch()
        require(app.staticTexts["Wallet balance"], in: app, message: "Long-history fixture did not load")
        tap(app.buttons["Messages"], in: app, message: "Messages tab is unavailable")
        openFixtureConversation(in: app)
        let timeline = app.scrollViews["conversation-timeline"]
        require(timeline, in: app, message: "Long-history timeline did not appear")
        let newest = timeline.staticTexts["Long history 300"].firstMatch
        require(newest, in: app, message: "Long-history fixture has no newest row")
        XCTAssertTrue(newest.isHittable, "First opening must reveal row 300, not the start of history")

        var geometry = ["Synthetic workload: 100 conversations, 2,000 text messages, 300 primary rows.",
                        "Two functional drag passes and frame geometry; no timing or hitch measurements.",
                        "Simulator results do not establish physical-device latency."]
        // Build 78 retained native momentum after the requested stationary hold. Use a
        // low input velocity so the partial return leaves room for UIKit's deceleration;
        // keep the reading-position and idle-layout assertions unchanged.
        let readingDragVelocity = XCUIGestureVelocity(rawValue: 60)
        let stationaryReleaseDuration: TimeInterval = 0.5
        // Preserve first-pass and repeated-state coverage independently of XCTest's
        // metric collector, which raised an internal exception in both builds 76 and 77.
        for _ in 0..<2 {
            // Restore the starting position before the repeated drag pair.
            let jump = app.buttons["Jump to latest message"]
            if jump.exists { jump.tap() }
            XCTAssertTrue(newest.isHittable, "Each drag pair starts at the newest row")
            let viewport = timeline.frame.insetBy(dx: 2, dy: 20)
            // Short, plain-text bubbles keep these anchors visible on the screenshot iPhone.
            // Row 296 is outgoing; row 295 is incoming, so both bubble gesture owners are used.
            let outgoing = timeline.staticTexts["Long history 296"].firstMatch
            require(outgoing, in: app, message: "Outgoing scroll anchor is missing")
            XCTAssertTrue(outgoing.isHittable)
            let outgoingBefore = outgoing.frame
            let distance = min(CGFloat(180), viewport.height * 0.3)
            let olderDestination = CGPoint(x: outgoingBefore.midX, y: outgoingBefore.midY + distance)
            XCTAssertTrue(viewport.contains(olderDestination), "Older drag must stay inside the timeline")

            outgoing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: olderDestination.x, dy: olderDestination.y)),
                       withVelocity: readingDragVelocity, thenHoldForDuration: stationaryReleaseDuration)
            let outgoingAfter = outgoing.frame
            print("[KitPayLongHistoryGeometry] Outgoing before/after: \(outgoingBefore) -> \(outgoingAfter)")
            if outgoingAfter.minY - outgoingBefore.minY <= distance * 0.5 {
                retainHierarchy(app, named: "long-history-vertical-drag-failure")
                capture(app, named: "long-history-vertical-drag-failure")
            }
            XCTAssertGreaterThan(outgoingAfter.minY - outgoingBefore.minY, distance * 0.5,
                                 "Dragging down from inside a bubble must reveal older messages")
            XCTAssertFalse(newest.isHittable, "Reading older messages must leave the latest position")

            let incoming = timeline.staticTexts["Long history 295"].firstMatch
            require(incoming, in: app, message: "Incoming scroll anchor is missing")
            XCTAssertTrue(incoming.isHittable)
            let incomingBefore = incoming.frame
            // Leave well over the 56-point near-latest threshold after the partial return.
            let returnDistance = distance / 3
            let newerDestination = CGPoint(x: incomingBefore.midX, y: incomingBefore.midY - returnDistance)
            XCTAssertTrue(viewport.contains(newerDestination), "Newer drag must stay inside the timeline")
            incoming.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: newerDestination.x, dy: newerDestination.y)),
                       withVelocity: readingDragVelocity, thenHoldForDuration: stationaryReleaseDuration)
            let incomingAfter = incoming.frame
            let dragGeometry = "Outgoing before/after: \(outgoingBefore) -> \(outgoingAfter)\n"
                + "Incoming before/after: \(incomingBefore) -> \(incomingAfter)"
            print("[KitPayLongHistoryGeometry] Incoming before/after: \(incomingBefore) -> \(incomingAfter)")
            // Retain the observed frames before assertions can abort this test.
            let returnAttachment = XCTAttachment(string: dragGeometry)
            returnAttachment.name = "long-history-scroll-after-return"
            returnAttachment.lifetime = .keepAlways
            add(returnAttachment)
            XCTAssertLessThan(incomingAfter.minY - incomingBefore.minY, -returnDistance * 0.5,
                              "Dragging up from inside a bubble must move back toward newer messages")
            let distanceStillInHistory = (outgoingAfter.minY - outgoingBefore.minY)
                - (incomingBefore.minY - incomingAfter.minY)
            XCTAssertGreaterThan(distanceStillInHistory, 56,
                                 "The stopped return must remain beyond the near-latest distance")
            XCTAssertFalse(app.buttons["Cancel reply"].exists, "Vertical scrolling must not select a reply")
            XCTAssertFalse(app.buttons["Close camera"].waitForExistence(timeout: 1),
                           "Ordinary history scrolling must not open the camera")
            XCTAssertFalse(newest.isHittable, "A partial return must preserve the chosen reading position")
            XCTAssertTrue(jump.isHittable, "The user must retain an explicit way back to latest")
            XCTAssertEqual(incoming.frame.minY, incomingAfter.minY, accuracy: 4,
                           "Idle layout updates must not pull the reader away from history")
            geometry.append("Outgoing before/after: \(outgoingBefore) -> \(outgoingAfter)")
            geometry.append("Incoming before/after: \(incomingBefore) -> \(incomingAfter)")
        }
        let attachment = XCTAttachment(string: geometry.joined(separator: "\n"))
        attachment.name = "long-history-scroll-geometry"
        attachment.lifetime = .keepAlways
        add(attachment)

        tap(app.buttons["Jump to latest message"], in: app, message: "Jump to latest is unavailable")
        XCTAssertTrue(newest.isHittable, "Jump to latest must reveal row 300")
        tap(app.navigationBars.buttons.element(boundBy: 0), in: app, message: "Chat has no back button")
        require(app.navigationBars["Chats"], in: app, message: "Chats did not return")
        openFixtureConversation(in: app)
        require(newest, in: app, message: "Newest row is missing after reopening")
        XCTAssertTrue(newest.isHittable, "Reopening long history must preserve latest-message opening")
        XCTAssertFalse(app.buttons["Cancel reply"].exists)
        XCTAssertFalse(app.buttons["Close camera"].exists)

        // Exercise actual UIKit/SwiftUI gesture arbitration, including the opposite direction
        // and a stationary long press. Policy-only tests cannot prove which recognizer wins.
        for (label, horizontalDistance) in [("Long history 296", CGFloat(-120)),
                                             ("Long history 295", CGFloat(120))] {
            let bubble = timeline.staticTexts[label].firstMatch
            requireHittable(bubble, in: app, message: "Reply gesture anchor is unavailable")
            let start = bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.01,
                        thenDragTo: start.withOffset(CGVector(dx: horizontalDistance, dy: 0)),
                        withVelocity: readingDragVelocity,
                        thenHoldForDuration: stationaryReleaseDuration)
            tap(app.buttons["Cancel reply"], in: app,
                message: "A deliberate horizontal swipe must select a reply")
            XCTAssertFalse(app.buttons["Cancel reply"].exists)
            // Reopening also dismisses the reply keyboard before the next gesture.
            tap(app.navigationBars.buttons.element(boundBy: 0), in: app,
                message: "Chat has no back button after cancelling reply")
            openFixtureConversation(in: app)
            XCTAssertTrue(newest.isHittable)
        }
        let menuAnchors = timeline.staticTexts.matching(NSPredicate(format: "label == %@", "Long history 296"))
        let menuAnchor = menuAnchors.firstMatch
        requireHittable(menuAnchor, in: app, message: "Context menu anchor is unavailable")
        XCTAssertEqual(menuAnchors.count, 1, "The context menu must target one message")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Reopening must dismiss the reply keyboard")
        let anchorBeforePress = menuAnchor.frame
        let applicationFrame = app.frame
        let timelineFrame = timeline.frame.intersection(applicationFrame)
        let chatNavigationBar = app.navigationBars.containing(
            .button, identifier: "Open \(fixtureContactName)'s profile"
        ).firstMatch
        XCTAssertTrue(chatNavigationBar.exists, "The chat header must define the visible timeline")
        let visibleTop = max(timelineFrame.minY, chatNavigationBar.frame.maxY)
        let visibleTimeline = CGRect(x: timelineFrame.minX, y: visibleTop,
                                     width: timelineFrame.width, height: timelineFrame.maxY - visibleTop)
        let pressPoint = CGPoint(x: anchorBeforePress.midX, y: anchorBeforePress.midY)
        XCTAssertTrue(visibleTimeline.insetBy(dx: 2, dy: 2).contains(anchorBeforePress),
                      "The entire long-press label must be visible below the chat header")
        let settledAnchor = menuAnchor.frame
        XCTAssertEqual(settledAnchor.midX, pressPoint.x, accuracy: 1,
                       "The message must not move horizontally before the stationary press")
        XCTAssertEqual(settledAnchor.midY, pressPoint.y, accuracy: 1,
                       "The message must not move vertically before the stationary press")
        let beforePress = "Anchor: \(anchorBeforePress); settled: \(settledAnchor); "
            + "visible timeline: \(visibleTimeline); press: \(pressPoint)"
        print("[KitPayLongHistoryContextMenu] Before press: \(beforePress)")
        // Use the validated label center, not XCTest's implicit element hit-point selection.
        // Keep the same stationary one-second input; never retry a missed long press.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: pressPoint.x - applicationFrame.minX,
                                 dy: pressPoint.y - applicationFrame.minY))
            .press(forDuration: 1)
        let afterPress = "Anchor: \(menuAnchor.exists ? String(describing: menuAnchor.frame) : "not exposed"); "
            + "timeline: \(timeline.exists ? String(describing: timeline.frame) : "not exposed")"
        print("[KitPayLongHistoryContextMenu] After press: \(afterPress)")
        let menuGeometry = XCTAttachment(string: "Before press: \(beforePress)\nAfter press: \(afterPress)")
        menuGeometry.name = "long-history-context-menu-geometry"
        menuGeometry.lifetime = .keepAlways
        add(menuGeometry)
        tap(app.buttons["Reply"], in: app,
            message: "A stationary long press must retain the message context menu")
        let cancelReply = app.buttons["Cancel reply"]
        require(cancelReply, in: app, message: "The context menu must still select the quoted message")
        let quote = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Replying to You: Long history 296")
        ).firstMatch
        XCTAssertTrue(quote.exists, "Reply must quote the exact message that received the long press")
        XCTAssertTrue(cancelReply.isHittable, "The quoted message must remain cancellable")
        cancelReply.tap()
        XCTAssertFalse(app.buttons["Close camera"].exists)

        // Selection owns row taps only while enabled. Exercise that transition in the same
        // fixture, then require another real bubble drag after the selection gesture leaves.
        tap(app.navigationBars.buttons.element(boundBy: 0), in: app, message: "Chat has no back button")
        require(app.navigationBars["Chats"], in: app, message: "Chats did not return")
        openFixtureConversation(in: app)
        let selectionAnchor = timeline.staticTexts["Long history 296"].firstMatch
        requireHittable(selectionAnchor, in: app, message: "Selection anchor is unavailable")
        let selectionFrame = selectionAnchor.frame
        let selectionAppFrame = app.frame
        XCTAssertTrue(timeline.frame.intersection(selectionAppFrame).contains(selectionFrame))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: selectionFrame.midX - selectionAppFrame.minX,
                                 dy: selectionFrame.midY - selectionAppFrame.minY))
            .press(forDuration: 1)
        tap(app.buttons["Select"], in: app, message: "The message menu must allow selection")
        require(app.staticTexts["1 selected"], in: app, message: "The long-pressed row must be selected")
        let secondSelection = timeline.staticTexts["Long history 295"].firstMatch
        require(secondSelection, in: app, message: "The second selection row is unavailable")
        let secondSelectionFrame = secondSelection.frame
        let secondSelectionAppFrame = app.frame
        XCTAssertTrue(timeline.frame.intersection(secondSelectionAppFrame).contains(secondSelectionFrame))
        let secondSelectionPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: secondSelectionFrame.midX - secondSelectionAppFrame.minX,
                                 dy: secondSelectionFrame.midY - secondSelectionAppFrame.minY))
        secondSelectionPoint.tap()
        require(app.staticTexts["2 selected"], in: app, message: "Selection mode must accept a row tap")
        let selectedSecondFrame = secondSelection.frame
        XCTAssertEqual(selectedSecondFrame.midX, secondSelectionFrame.midX, accuracy: 1,
                       "Selecting a row must preserve its tap position")
        XCTAssertEqual(selectedSecondFrame.midY, secondSelectionFrame.midY, accuracy: 1,
                       "Selecting a row must preserve its reading position")
        secondSelectionPoint.tap()
        require(app.staticTexts["1 selected"], in: app, message: "A second tap must deselect the same row")
        tap(app.buttons["Done"], in: app, message: "Selection mode must close")
        requireHittable(app.buttons["Open \(fixtureContactName)'s profile"].firstMatch, in: app,
                       message: "Normal chat controls must return after selection")
        requireHittable(selectionAnchor, in: app, message: "The scroll anchor must remain visible")
        let afterSelectionBefore = selectionAnchor.frame
        let afterSelectionDistance = min(CGFloat(180), timeline.frame.height * 0.3)
        let afterSelectionEnd = CGPoint(x: afterSelectionBefore.midX,
                                       y: afterSelectionBefore.midY + afterSelectionDistance)
        let afterSelectionAppFrame = app.frame
        XCTAssertTrue(timeline.frame.intersection(afterSelectionAppFrame).contains(afterSelectionEnd))
        selectionAnchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: afterSelectionEnd.x - afterSelectionAppFrame.minX,
                                     dy: afterSelectionEnd.y - afterSelectionAppFrame.minY)),
                   withVelocity: readingDragVelocity, thenHoldForDuration: stationaryReleaseDuration)
        let afterSelectionAfter = selectionAnchor.frame
        let selectionGeometry = "After selection: \(afterSelectionBefore) -> \(afterSelectionAfter)"
        print("[KitPayLongHistorySelectionGeometry] \(selectionGeometry)")
        let selectionAttachment = XCTAttachment(string: selectionGeometry)
        selectionAttachment.name = "long-history-scroll-after-selection"
        selectionAttachment.lifetime = .keepAlways
        add(selectionAttachment)
        if afterSelectionAfter.minY - afterSelectionBefore.minY <= afterSelectionDistance * 0.5 {
            retainHierarchy(app, named: "long-history-after-selection-drag-failure")
            capture(app, named: "long-history-after-selection-drag-failure")
        }
        XCTAssertGreaterThan(afterSelectionAfter.minY - afterSelectionBefore.minY,
                             afterSelectionDistance * 0.5,
                             "Leaving selection must restore scrolling from inside a message bubble")
        XCTAssertFalse(newest.isHittable, "The post-selection drag must leave the latest position")
        XCTAssertFalse(app.buttons["Cancel reply"].exists, "A vertical drag must not select a reply")
        XCTAssertFalse(app.buttons["Close camera"].exists, "A vertical history drag must not open camera")
    }

    private func openFixtureConversation(in app: XCUIApplication) {
        require(app.navigationBars["Chats"], in: app, message: "Chats did not open")
        let lists = app.scrollViews.matching(identifier: "conversation-list")
        let list = lists.firstMatch
        require(list, in: app, message: "Conversation list is missing")
        XCTAssertEqual(lists.count, 1, "The conversation list must be unique")

        // Inactive tabs can still appear in XCTest's hierarchy. Select the navigation Button
        // by conversation identity inside the chat list, never a global display-name match.
        let rows = list.buttons.matching(identifier: "conversation-row:\(fixtureConversationID)")
        let row = rows.firstMatch
        requireHittable(row, in: app, message: "The primary fixture conversation is not tappable")
        XCTAssertEqual(rows.count, 1, "The primary fixture conversation row must be unique")
        require(row.staticTexts[fixtureContactName], in: app,
                message: "The primary fixture conversation has an unexpected title")
        row.tap()

        requireHittable(
            app.navigationBars.buttons["Open \(fixtureContactName)'s profile"].firstMatch,
            in: app,
            message: "Navigation did not open the primary fixture conversation"
        )
    }

    private func requireHittable(_ element: XCUIElement, in app: XCUIApplication, message: String) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        guard XCTWaiter.wait(for: [ready], timeout: 30) == .completed else {
            retainHierarchy(app, named: "fixture-conversation-navigation-failure")
            XCTFail(message)
            return
        }
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
