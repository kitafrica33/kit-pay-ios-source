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

    func testChatAttachmentMenuOpensPhotosAndFilesAfterKeyboardDismissal() {
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
        openFixtureConversation(in: app)

        let composer = app.descendants(matching: .any)
            .matching(identifier: "conversation-message-composer").firstMatch
        let attachmentToggle = app.buttons["conversation-attachment-toggle"]
        let attachmentMenu = app.descendants(matching: .any)
            .matching(identifier: "conversation-attachment-menu").firstMatch
        let photoPicker = app.descendants(matching: .any)
            .matching(identifier: "conversation-photo-picker").firstMatch
        let originalDraft = "Attachment preview draft"

        requireHittable(composer, in: app, message: "The real message composer is unavailable")
        composer.tap()
        require(app.keyboards.firstMatch, in: app, message: "The composer keyboard did not appear")
        composer.typeText(originalDraft)
        XCTAssertEqual(composer.value as? String, originalDraft)

        // Exercise the customer's path with the keyboard still raised. These are real
        // PHPicker/Files presentations; no fixture callback pretends a picker opened.
        requireHittable(attachmentToggle, in: app, message: "Attachments cannot open above the keyboard")
        attachmentToggle.tap()
        require(attachmentMenu, in: app, message: "The attachment panel did not open")
        let library = app.buttons["conversation-attach-library"]
        requireHittable(library, in: app, message: "Photo & video library is not tappable")
        library.tap()
        require(photoPicker, in: app, message: "The real photo picker did not present")
        requireHittable(app.buttons["Cancel"].firstMatch, in: app,
                       message: "The photo picker cannot be cancelled")
        app.buttons["Cancel"].firstMatch.tap()
        requireHittable(attachmentToggle, in: app, message: "Photo cancellation did not restore attachments")
        XCTAssertFalse(photoPicker.exists, "The photo picker must dismiss before opening another picker")
        XCTAssertEqual(composer.value as? String, originalDraft, "Photo cancellation must preserve the draft")

        // Reopen immediately after cancellation; a stale presentation flag must not swallow
        // the next selection or leave the composer behind a dismissed modal.
        attachmentToggle.tap()
        require(attachmentMenu, in: app, message: "The attachment panel could not reopen after Photos")
        let document = app.buttons["conversation-attach-document"]
        requireHittable(document, in: app, message: "Document is not tappable")
        document.tap()
        let filesCancel = app.buttons["Cancel"].firstMatch
        requireHittable(filesCancel, in: app, message: "The native Files picker did not present")
        XCTAssertFalse(photoPicker.exists, "Document must open Files, not the previous photo picker")
        XCTAssertFalse(composer.isHittable, "Files must own presentation while choosing a document")
        filesCancel.tap()
        requireHittable(composer, in: app, message: "Files cancellation did not restore the composer")
        XCTAssertEqual(composer.value as? String, originalDraft, "Files cancellation must preserve the draft")

        // Verify repeated plain + taps remain reversible, then prove actual text editing
        // still works. No Send is pressed and this synthetic draft never leaves the device.
        for _ in 0..<2 {
            requireHittable(attachmentToggle, in: app, message: "Attachments became unavailable after cancellation")
            attachmentToggle.tap()
            requireHittable(library, in: app, message: "The attachment panel did not reopen")
            attachmentToggle.tap()
            let closed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: attachmentMenu
            )
            if XCTWaiter.wait(for: [closed], timeout: 10) != .completed {
                retainHierarchy(app, named: "chat-attachment-menu-dismissal-failure")
                XCTFail("The + button must close the attachment panel")
            }
        }
        requireHittable(composer, in: app, message: "The composer is obstructed after closing attachments")
        composer.tap()
        require(app.keyboards.firstMatch, in: app, message: "The composer keyboard did not return")
        XCTAssertEqual(composer.value as? String, originalDraft,
                       "Reopening the attachment panel must preserve the complete draft")
        // A tap chooses an insertion point; it does not promise to place the caret at the
        // end. Require one contiguous edit at any position with every draft character intact.
        let insertedText = "__edit__"
        composer.typeText(insertedText)
        guard let editedDraft = composer.value as? String else {
            XCTFail("The composer must expose the edited draft after picker cancellation")
            return
        }
        XCTAssertEqual(editedDraft.count, originalDraft.count + insertedText.count,
                       "The composer must insert the typed text exactly once")
        XCTAssertEqual(editedDraft.replacingOccurrences(of: insertedText, with: ""), originalDraft,
                       "Typing after picker cancellation must preserve every original draft character")
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
                        "Three functional drag passes with frame geometry and per-drag wall clock.",
                        "Simulator results do not establish physical-device latency."]
        // Build 78 retained native momentum after the requested stationary hold. Use a
        // low input velocity so the partial return leaves room for UIKit's deceleration;
        // keep the reading-position and idle-layout assertions unchanged.
        let readingDragVelocity = XCUIGestureVelocity(rawValue: 60)
        let stationaryReleaseDuration: TimeInterval = 0.5
        // Preserve first-pass and repeated-state coverage independently of XCTest's
        // metric collector, which raised an internal exception in both builds 76 and 77.
        // Three passes, not two. The pass that failed on build 104 was the one taken straight
        // after *Jump to latest message*, where the screen had just republished and the main
        // thread was still folding the whole 2 000-message thread; see
        // docs/status/ios-chat-scroll-2026-09-21.md. That pass is the
        // cheap one to repeat, and repeating it is what turns an intermittent freeze into a
        // reliable signal: a drag that finds the main thread busy moves the timeline 0.0 points.
        for pass in 0..<3 {
            // Restore the starting position before the repeated drag pair.
            let jump = app.buttons["Jump to latest message"]
            if jump.exists { jump.tap() }
            XCTAssertTrue(newest.isHittable, "Each drag pair starts at the newest row")
            let passStart = Date()
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
            // Wall clock per drag, so a run that merely got slower is distinguishable from one
            // that froze, and so the before/after numbers in the report are measured.
            let olderSeconds = Date().timeIntervalSince(passStart)
            print("[KitPayLongHistoryGeometry] Pass \(pass) older drag took \(olderSeconds)s")
            print("[KitPayLongHistoryGeometry] Outgoing before/after: \(outgoingBefore) -> \(outgoingAfter)")
            if outgoingAfter.minY - outgoingBefore.minY <= distance * 0.5 {
                retainHierarchy(app, named: "long-history-vertical-drag-failure")
                capture(app, named: "long-history-vertical-drag-failure")
            }
            XCTAssertGreaterThan(outgoingAfter.minY - outgoingBefore.minY, distance * 0.5,
                                 "Dragging down from inside a bubble must reveal older messages "
                                    + "(pass \(pass), \(olderSeconds)s)")
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
            geometry.append("Pass \(pass) older drag: \(olderSeconds)s")
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

    // MARK: - Owner report, 1.0.17 build 105: chat media

    /// Scrolling a thread of 320 mixed-media messages, timed.
    ///
    /// Owner report: *"still some lagging between chats ... scrolling through chat messages
    /// lags"*. `testLongHistoryVerticalBubbleDragsPreserveReadingPosition` above cannot see it —
    /// 2,000 plain text rows never touch the image decoder. This one opens the thread the report
    /// describes (96 photos with real JPEG bytes, 32 videos, 32 voice notes, 32 audio files, 32
    /// documents, 96 text rows) and records the wall clock of every swipe.
    ///
    /// The assertions here are functional, and the ceiling is deliberately loose: a simulator on
    /// shared CI hardware cannot establish a 60 Hz claim, and pretending otherwise would make the
    /// suite flaky *and* the report dishonest. The hitch rate and the first-move latency in
    /// `docs/status/ios-chat-media-2026-09-21.md` are measured on a device with Instruments. What
    /// this test is for is the regression: a build where a `body` decodes again does not merely
    /// get slower here, it stops moving, and the movement assertions catch that.
    func testMixedMediaThreadScrollsAndRecordsSwipeWallClock() {
        let app = XCUIApplication()
        app.launchArguments += [
            fixtureArgument,
            "--kit-chat-mixed-media-scroll-fixture-v1",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_UG",
            "-UIUserInterfaceStyle", "Light",
        ]
        app.launch()
        require(app.staticTexts["Wallet balance"], in: app, message: "Mixed-media fixture did not load")
        tap(app.buttons["Messages"], in: app, message: "Messages tab is unavailable")
        openFixtureConversation(in: app)

        let timeline = app.scrollViews["conversation-timeline"]
        require(timeline, in: app, message: "Mixed-media timeline did not appear")
        let newest = timeline.staticTexts["Noted 320"].firstMatch
        require(newest, in: app, message: "Mixed-media fixture has no newest row")
        XCTAssertTrue(newest.isHittable, "Opening must reveal the newest row, not the start of history")

        // The first photo bubble has to resolve its local original and decode off the main
        // thread before anything is on screen to scroll past.
        let anyPhoto = app.buttons["End-to-end encrypted photo queued to send"].firstMatch
        XCTAssertTrue(
            anyPhoto.waitForExistence(timeout: 20),
            "No photo bubble ever rendered; the mixed-media fixture carries 96 of them"
        )

        // Warm-up, deliberately untimed, and *downwards* — older messages are above.
        //
        // Two traps, both paid for in a real run. (1) A chat opens pinned to its newest message,
        // and a deliberate upward pull from a pinned timeline is this product's camera gesture;
        // `testChatBottomPullOpensCameraOnlyAfterADeliberateRelease` asserts exactly that. Run
        // 6ab15f28 swiped up: the camera opened over the thread at t = 24.9 s, iOS raised its
        // Camera and Microphone prompts, and every later "timed" swipe was synthesized into a
        // camera preview while the timeline sat untouched at 100 %. Reading history is
        // `swipeDown`. (2) XCUITest dismisses an interrupting alert *inside* whatever
        // interaction is running when it notices: pass 1 of run 6ab15445 measured 9.5 s, of
        // which the app's share was none — it was SpringBoard tapping "Allow" twice. Absorb any
        // prompt, and the first cold decode, before the clock starts.
        let closeCamera = app.buttons["Close camera"]
        for _ in 0 ..< 3 { timeline.swipeDown(velocity: .default) }
        XCTAssertFalse(
            XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists,
            "A system permission alert is still on screen; the timings would measure SpringBoard"
        )
        XCTAssertFalse(closeCamera.exists, "Reading history must never open the camera")

        var report = [
            "Synthetic workload: 1 conversation, \(320) messages.",
            "96 photos (real JPEG bytes), 32 videos, 32 voice notes, 32 audio files,",
            "32 documents, 96 text rows.",
            "Debug build, Simulator, shared CI hardware, after three untimed warm-up swipes.",
            "Each figure is one XCUITest swipe end to end: finding the scroll view, checking",
            "for interrupting elements, synthesizing the drag, and then waiting for the app to",
            "go idle -- which includes the scroll's own deceleration. It is an upper bound on a",
            "gesture, not a frame time, and it does not establish physical-device latency.",
            "See docs/status/ios-chat-media-2026-09-21.md.",
        ]
        var slowest: TimeInterval = 0

        for pass in 0 ..< 12 {
            let start = Date()
            timeline.swipeDown(velocity: .default)
            let seconds = Date().timeIntervalSince(start)
            slowest = max(slowest, seconds)
            report.append("Pass \(pass) into history: \(seconds)s")
            print("[KitPayMixedMediaGeometry] Pass \(pass) into history \(seconds)s")
        }
        XCTAssertFalse(newest.isHittable, "Twelve swipes through media must leave the newest row")
        XCTAssertFalse(closeCamera.exists, "Reading history must never open the camera")
        let jump = Self.jumpToLatest(in: app)
        if !Self.waitUntilHittable(jump) {
            capture(app, named: "mixed-media-no-jump-to-latest")
            print(app.debugDescription)
        }
        XCTAssertTrue(jump.isHittable, "A reader deep in media history needs the way back")

        // Back towards the newest row — ten passes against the twelve that came down, and a
        // stop the moment the newest row is on screen. Both guards exist for the same reason:
        // an upward swipe on a re-pinned timeline is the camera pull, not a scroll, and the
        // last stretch back to the bottom belongs to "Jump to latest" anyway.
        var returnPasses = 0
        for pass in 0 ..< 10 {
            if newest.isHittable { break }
            let start = Date()
            timeline.swipeUp(velocity: .default)
            let seconds = Date().timeIntervalSince(start)
            slowest = max(slowest, seconds)
            returnPasses += 1
            report.append("Pass \(pass) back towards the newest row: \(seconds)s")
            print("[KitPayMixedMediaGeometry] Pass \(pass) back \(seconds)s")
        }
        report.append("Return passes taken: \(returnPasses)")
        XCTAssertGreaterThan(
            returnPasses, 0, "Twelve swipes into history must leave somewhere to come back from"
        )
        XCTAssertFalse(closeCamera.exists, "Coming back must not open the camera")

        report.append("Slowest single swipe: \(slowest)s")
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "mixed-media-scroll-wall-clock"
        attachment.lifetime = .keepAlways
        add(attachment)

        // A loose ceiling on purpose, and a considered one. Twenty-two timed passes over this
        // thread on run 6ab1666b -- the first run that was measuring the timeline at all rather
        // than a camera preview opened by its own warm-up -- ran from 2.78 s to 4.08 s, mean
        // 3.25 s, on a Debug build on a shared CI Mac, with XCUITest's wait-for-idle and the
        // scroll's own deceleration inside every figure. Claiming 60 Hz from that would be a
        // lie in either direction. What this number is for is the regression: build 105 decoded
        // a 37.7 MB thumbnail inside `body` for every photo that came on screen, against a
        // 64 MB cache that could therefore hold one of them, and a return to that does not cost
        // a second a swipe -- it costs tens of seconds, because every pass re-decodes what the
        // pass before it evicted.
        XCTAssertLessThan(
            slowest, 8,
            "A single swipe took \(slowest)s; something is decoding on the main thread again"
        )

        if !newest.isHittable {
            XCTAssertTrue(
                Self.waitUntilHittable(jump),
                "Jump to latest vanished before the reader reached the newest row"
            )
            tap(jump, in: app, message: "Jump to latest is unavailable")
        }
        XCTAssertTrue(newest.isHittable, "The reader must end on the newest row")
        capture(app, named: "mixed-media-thread")
    }

    /// Opening media from the thread and swiping left and right through the whole conversation.
    ///
    /// Owner report: *"test swiping left and right on media in a chat"*. On build 105 this could
    /// not be tested from a queued photo or from an album cell at all, because neither opened the
    /// gallery — each opened a standalone viewer with nowhere to swipe to. The fold had always
    /// counted those items among the conversation's media; nothing routed a tap to them.
    func testMediaGallerySwipesThroughTheConversationsMediaInOrder() {
        let app = XCUIApplication()
        app.launchArguments += [
            fixtureArgument,
            "--kit-chat-mixed-media-scroll-fixture-v1",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_UG",
            "-UIUserInterfaceStyle", "Light",
        ]
        app.launch()
        require(app.staticTexts["Wallet balance"], in: app, message: "Mixed-media fixture did not load")
        tap(app.buttons["Messages"], in: app, message: "Messages tab is unavailable")
        openFixtureConversation(in: app)

        let timeline = app.scrollViews["conversation-timeline"]
        require(timeline, in: app, message: "Mixed-media timeline did not appear")
        let queued = app.buttons.matching(
            NSPredicate(format: "label == %@", "End-to-end encrypted photo queued to send")
        )
        XCTAssertTrue(queued.firstMatch.waitForExistence(timeout: 20),
                      "No photo bubble to open the gallery from")

        // Open from the middle of the thread, not from its end. A gallery opened on the last
        // item has nowhere to walk to, and stepping back from it is the one thing a reader never
        // does. Older messages are above: `swipeDown` reads history (`swipeUp` on a pinned
        // timeline is the camera gesture).
        for _ in 0 ..< 12 { timeline.swipeDown(velocity: .default) }
        XCTAssertFalse(app.buttons["Close camera"].exists,
                       "Reading history must never open the camera")
        guard let photo = Self.firstHittable(queued, scrolling: timeline) else {
            capture(app, named: "gallery-no-hittable-queued-photo")
            XCTFail("No queued photo bubble came on screen in the mixed-media thread")
            return
        }
        photo.tap()

        let counter = Self.galleryCounter(app)
        XCTAssertTrue(
            counter.waitForExistence(timeout: 10),
            "Tapping a queued photo must open the conversation gallery, not a dead-end viewer"
        )
        guard let opening = Self.galleryPosition(counter.label) else {
            XCTFail("Gallery counter is unreadable: \(counter.label)")
            return
        }
        XCTAssertGreaterThan(
            opening.total, 100,
            "The gallery must hold the conversation's media (96 photos + 32 videos), not one item"
        )

        // The walk needs headroom: ten turns forward, and a single deliberate drag is allowed
        // to cross one page boundary. Whichever queued photo came on screen first, step back
        // until there is room -- this test is about order and completeness, not about where in
        // the conversation the reader happened to start.
        var start = opening
        var headroomSteps = 0
        while start.index + 20 > start.total, headroomSteps < 40 {
            headroomSteps += 1
            guard let back = Self.turnGalleryPage(app, forward: false, from: start),
                  back.index < start.index
            else {
                capture(app, named: "gallery-headroom-failure")
                XCTFail("""
                Could not step back from item \(start.index) of \(start.total); \
                the counter now reads "\(Self.galleryCounter(app).label)"
                """)
                return
            }
            start = back
        }
        XCTAssertLessThanOrEqual(
            start.index + 20, start.total,
            "Could not find headroom for the walk; the gallery is stuck at item \(start.index)"
        )

        // What each visited item *is* comes from the gallery's own per-item label ("Photo from
        // You, 24 Aug 2026 at 09:41"), which is the page's accessibility container — not an
        // Image, which is why run 6ab1666b walked all ten pages correctly and still reported
        // that it had seen no media at all.
        let pages = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                        "Photo from", "Video from")
        )
        let pageCount = pages.count
        print("[KitPayGallery] labelled pages in the tree: \(pageCount) of \(opening.total)")
        if pageCount == 0 {
            capture(app, named: "gallery-unlabelled-pages")
            print(app.debugDescription)
        }

        var visited = [start.index]
        var kinds = Set<String>()
        kinds.formUnion(Self.mediaKinds(from: pages, pageCount: pageCount, at: start.index))

        // Forward. The gallery's own counter is the order oracle: every turn moves on, in
        // order, and never skips a page. Where a synthesised drag leaves a scroll view is not
        // part of the product's contract -- run 6ab16c17 carried two items in one gesture and
        // failed a test that had assumed exactly one -- so the walk reads the position the
        // pager settled on and holds it to what a reader would demand of it.
        var current = start
        for _ in 0 ..< 10 {
            guard let position = Self.turnGalleryPage(app, forward: true, from: current) else {
                capture(app, named: "gallery-forward-swipe-failure")
                XCTFail("""
                Swiping left did not move on from item \(current.index) of \(current.total); \
                the counter still reads "\(Self.galleryCounter(app).label)"
                """)
                return
            }
            XCTAssertGreaterThan(
                position.index, current.index,
                "Swiping left must walk forward through the conversation's media"
            )
            XCTAssertLessThanOrEqual(
                position.index - current.index, 2,
                "One swipe jumped item \(current.index) -> \(position.index): media went past unseen"
            )
            XCTAssertEqual(
                position.total, start.total,
                "The gallery lost media mid-walk: \(start.total) -> \(position.total)"
            )
            visited.append(position.index)
            current = position
            kinds.formUnion(
                Self.mediaKinds(from: pages, pageCount: pageCount, at: position.index)
            )
        }
        print("[KitPayGallery] forward walk: \(visited)")
        XCTAssertEqual(
            visited, visited.sorted(),
            "Swiping left must walk the conversation's media in order: \(visited)"
        )
        XCTAssertGreaterThanOrEqual(
            current.index - start.index, 10,
            "Ten swipes left must carry the reader ten items on: \(visited)"
        )
        XCTAssertTrue(
            kinds.contains("Photo") && kinds.contains("Video"),
            """
            Eleven pages of a mixed thread must include both photos and videos; \
            saw \(kinds) across \(pageCount) labelled pages
            """
        )
        capture(app, named: "gallery-mixed-media")

        // Rotation must not lose the reader's place.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertNotNil(
            Self.waitForGalleryPosition(app, expecting: current.index),
            "Rotating must keep the gallery on item \(current.index)"
        )
        capture(app, named: "gallery-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertNotNil(
            Self.waitForGalleryPosition(app, expecting: current.index),
            "Rotating back must keep the gallery on item \(current.index)"
        )

        // Zoom, then back out. A zoomed page must still be a page.
        //
        // The gallery zooms by pinch *and* by double tap (1x <-> 2.5x, anchored at the tap
        // point, `ZoomableImageView`). A synthesized pinch cannot zoom *in* on a page that
        // already fills the screen — its touch points have nowhere to travel to — which is
        // where run 6ab17461 stopped: "Invalid scale 2.40 greater than maximum possible scale
        // 0.84". The double tap is the product's own affordance and has no such limit. A video
        // page does not zoom and its centre is the play button, so step onto a photo first.
        if Self.currentPageLabel(app).hasPrefix("Video from"),
           let next = Self.turnGalleryPage(app, forward: true, from: current) {
            current = next
        }
        if Self.currentPageLabel(app).hasPrefix("Photo from") {
            let anchor = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
            anchor.doubleTap()
            XCTAssertNotNil(
                Self.waitForGalleryPosition(app, expecting: current.index),
                "Zooming must not move the gallery off its item"
            )
            capture(app, named: "gallery-zoomed")
            anchor.doubleTap()
            XCTAssertNotNil(
                Self.waitForGalleryPosition(app, expecting: current.index),
                "Coming back out of a zoom must not move the gallery off its item"
            )
        }

        // Back the way we came.
        var walkedBack = [current.index]
        for _ in 0 ..< 10 {
            guard let position = Self.turnGalleryPage(app, forward: false, from: current) else {
                capture(app, named: "gallery-backward-swipe-failure")
                XCTFail("""
                Swiping right did not move back from item \(current.index); \
                the counter still reads "\(Self.galleryCounter(app).label)"
                """)
                return
            }
            XCTAssertLessThan(
                position.index, current.index,
                "Swiping right must walk back through the conversation's media"
            )
            XCTAssertLessThanOrEqual(
                current.index - position.index, 2,
                "One swipe jumped item \(current.index) -> \(position.index): media went past unseen"
            )
            walkedBack.append(position.index)
            current = position
        }
        print("[KitPayGallery] walk back: \(walkedBack)")
        XCTAssertEqual(
            walkedBack, walkedBack.sorted(by: >),
            "Swiping right must walk back in order: \(walkedBack)"
        )
        XCTAssertGreaterThanOrEqual(
            (walkedBack.first ?? 0) - current.index, 10,
            "Ten swipes right must carry the reader ten items back: \(walkedBack)"
        )

        tap(app.buttons["Close media viewer"], in: app, message: "Gallery has no close button")
        require(
            app.scrollViews["conversation-timeline"],
            in: app,
            message: "Closing the gallery must return to the conversation"
        )
    }

    /// The button's accessibility label is *not* constant: `MessagesView` swaps in
    /// "N new messages, jump to latest" whenever the thread has unseen incoming rows, which the
    /// mixed-media fixture does. Matching only the quiet label made the run of 2026-09-21 fail
    /// with a control that was on screen the whole time.
    private static func jumpToLatest(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label == %@ OR label ENDSWITH %@",
                        "Jump to latest message", "jump to latest")
        ).firstMatch
    }

    /// `isHittable` read once, immediately after a swipe returns, is a race the app loses
    /// honestly: the scroll view is still decelerating, the reading position it reports hops
    /// through the main queue, and the button itself fades and scales in over 0.2 s. Poll.
    @discardableResult
    private static func waitUntilHittable(
        _ element: XCUIElement, timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isHittable { return true }
            usleep(120_000)
        }
        return element.exists && element.isHittable
    }

    /// A row that merely `exists` in a lazy timeline can sit hundreds of points outside the
    /// viewport — the failing tap of 2026-09-21 reported a frame at y = -343 — and XCUITest's
    /// own "scroll to visible" cannot reach it, because the stack only builds what it shows.
    /// Scroll the timeline until one of the matches is genuinely on screen, and tap that one.
    ///
    /// It scrolls *into history* (`swipeDown`): an upward pull on a timeline that is still
    /// pinned to its newest message is the product's camera gesture, and the camera then covers
    /// the thread for the rest of the test.
    private static func firstHittable(
        _ query: XCUIElementQuery, scrolling timeline: XCUIElement, attempts: Int = 10
    ) -> XCUIElement? {
        for _ in 0 ... attempts {
            for element in query.allElementsBoundByIndex where element.isHittable {
                return element
            }
            timeline.swipeDown(velocity: .default)
        }
        return query.allElementsBoundByIndex.first { $0.isHittable }
    }

    private static func galleryPosition(_ label: String) -> (index: Int, total: Int)? {
        // "Item 7 of 128"
        let parts = label.split(separator: " ")
        guard parts.count == 4,
              let index = Int(parts[1]),
              let total = Int(parts[3])
        else { return nil }
        return (index, total)
    }

    /// "Item 7 of 128" — the gallery's own position readout, and the order oracle for every
    /// swipe in `testMediaGallerySwipesThroughTheConversationsMediaInOrder`.
    private static func galleryCounter(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Item ")
        ).firstMatch
    }

    /// The counter lives in the gallery chrome, and a tap on a page toggles that chrome away.
    /// A swipe the pager does not consume is delivered to the page's own tap gesture instead —
    /// so a page turn that fails can also hide the only element that would have reported it,
    /// and the poll below would blame the pager for a missing label. Bring the chrome back.
    @discardableResult
    private static func restoreGalleryChrome(_ app: XCUIApplication) -> Bool {
        guard !galleryCounter(app).exists else { return true }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return galleryCounter(app).waitForExistence(timeout: 2)
    }

    /// One page turn, as a finger that puts the page where it wants it and then lets go.
    ///
    /// `XCUIElement.swipeLeft/Right` is a flick: short, fast, and easy for a page that is still
    /// settling — or for a video page's controls — to swallow. Run 6ab15f28 lost its second
    /// step-back to exactly that, with no diagnosis possible from "nothing moved". Dragging
    /// 84 % of the width turned the page, but the finger lifted with the synthesiser's release
    /// velocity still on it and run 6ab16c17 carried two pages in one gesture (item 96 -> 98).
    ///
    /// So: 70 % of the width — past the pager's commit threshold on distance alone, and short
    /// of the next boundary — dragged slowly and then *held*, which is what
    /// `thenHoldForDuration` exists for, the same release this file's reading drags use. The
    /// finger lifts with no velocity, and the pager settles on the neighbour it is showing.
    private static func pageGallery(_ app: XCUIApplication, forward: Bool) {
        let from = app.coordinate(
            withNormalizedOffset: CGVector(dx: forward ? 0.85 : 0.15, dy: 0.5)
        )
        let to = app.coordinate(
            withNormalizedOffset: CGVector(dx: forward ? 0.15 : 0.85, dy: 0.5)
        )
        from.press(forDuration: 0.05, thenDragTo: to,
                   withVelocity: XCUIGestureVelocity(rawValue: 320), thenHoldForDuration: 0.3)
    }

    /// The label of the page the reader is on — "Photo from You, 24 Aug 2026 at 09:41" — or
    /// "" when the pager is holding more than one labelled page, because then which of them the
    /// reader is looking at is not something the tree can be asked.
    private static func currentPageLabel(_ app: XCUIApplication) -> String {
        let pages = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                        "Photo from", "Video from")
        )
        guard pages.count == 1 else { return "" }
        return pages.firstMatch.label
    }

    /// Turn one page and report where the gallery settled, or `nil` if it never moved.
    ///
    /// The counter is polled until two consecutive readings agree, so a reading taken while
    /// the pager is still animating is never mistaken for the destination.
    private static func turnGalleryPage(
        _ app: XCUIApplication,
        forward: Bool,
        from current: (index: Int, total: Int),
        timeout: TimeInterval = 6
    ) -> (index: Int, total: Int)? {
        pageGallery(app, forward: forward)
        let deadline = Date().addingTimeInterval(timeout)
        var restoreAttempts = 0
        var settling: (index: Int, total: Int)?
        while Date() < deadline {
            let counter = galleryCounter(app)
            if counter.exists, let position = galleryPosition(counter.label) {
                if position.index != current.index {
                    if let previous = settling, previous.index == position.index { return position }
                    settling = position
                }
            } else if restoreAttempts == 0 {
                restoreAttempts += 1
                restoreGalleryChrome(app)
                continue
            }
            usleep(120_000)
        }
        return settling
    }

    /// The pager animates, so the counter is polled rather than read once.
    private static func waitForGalleryPosition(
        _ app: XCUIApplication,
        expecting index: Int,
        timeout: TimeInterval = 5
    ) -> (index: Int, total: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: (index: Int, total: Int)?
        var restoreAttempts = 0
        while Date() < deadline {
            let counter = galleryCounter(app)
            if counter.exists, let position = galleryPosition(counter.label) {
                last = position
                if position.index == index { return position }
            } else if restoreAttempts == 0 {
                restoreAttempts += 1
                restoreGalleryChrome(app)
                continue
            }
            usleep(120_000)
        }
        return last?.index == index ? last : nil
    }

    /// "Photo from You, 24 Aug 2026 at 09:41" -> "Photo", for the item the reader is on.
    ///
    /// How many of a pager's pages are in the accessibility tree at once is not something a
    /// test gets to assume, and the two possibilities want different queries. A
    /// `UIPageViewController` normally holds the visible page and its immediate neighbours, in
    /// which case reading every match is a handful of element resolutions; a materialised list
    /// would instead hold all of them, in item order, where the page for item N is match N - 1
    /// and reading them all would cost a tree walk per swipe. Ask the query how many there are,
    /// once, and take the cheap route either way.
    private static func mediaKinds(
        from pages: XCUIElementQuery, pageCount: Int, at index: Int
    ) -> Set<String> {
        let labels: [String] = pageCount <= 8
            ? pages.allElementsBoundByIndex.map(\.label)
            : [pages.element(boundBy: max(0, index - 1)).label]
        var kinds: Set<String> = []
        for label in labels {
            if label.hasPrefix("Photo from") { kinds.insert("Photo") }
            if label.hasPrefix("Video from") { kinds.insert("Video") }
        }
        return kinds
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
