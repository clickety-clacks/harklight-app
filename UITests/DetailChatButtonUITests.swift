import XCTest

@MainActor
final class DetailChatButtonUITests: XCTestCase {
    func testChatUsesTrailingBottomToolbarAndPresentsSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10),
                      app.debugDescription)
        let sample = app.descendants(matching: .any)["sample-information-2"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5), app.debugDescription)
        sample.tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5),
                      app.debugDescription)

        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(chat.frame.midY, screen.midY,
                             "Chat belongs in the message screen's bottom toolbar.")
        XCTAssertGreaterThan(chat.frame.midX, screen.midX,
                             "Chat is trailing in the bottom toolbar.")
        XCTAssertTrue(chat.isHittable, app.debugDescription)

        chat.tap()
        XCTAssertTrue(app.textViews["sample-chat-composer"].waitForExistence(timeout: 5),
                      app.debugDescription)
    }

    func testDetailChatUsesNativeToolbarInLightMode() {
        verifyToolbarChatButton(appearance: "Light")
    }

    func testDetailChatUsesNativeToolbarInDarkMode() {
        verifyToolbarChatButton(appearance: "Dark")
    }

    func testNotificationChatDismissalStaysClosedWhenDetailIsRecreated() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The regular-width detail recreation requires an iPad layout.")
        }
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-test-notification-navigation",
                               "--harklight-test-notification-chat"]
        app.launch()

        let search = workspaceSearchField(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        search.tap()
        search.typeText("no-matching-request\n")

        let openNotification = app.buttons["harklight-test-notification"]
        XCTAssertTrue(openNotification.waitForExistence(timeout: 10), app.debugDescription)
        if !openNotification.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(openNotification.isHittable, app.debugDescription)
        openNotification.tap()

        let noChat = app.staticTexts.matching(identifier: "conversation-no-chat-empty-state").firstMatch
        XCTAssertTrue(noChat.waitForExistence(timeout: 10),
                      "The synthetic notification opens the target's Chat surface. \(app.debugDescription)")
        attachScreenshot("synthetic-notification-chat-open")

        noChat.swipeDown()
        XCTAssertTrue(app.buttons["request-heading"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Chat"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(noChat.waitForNonExistence(timeout: 5),
                      "One deliberate dismissal closes the notification Chat surface.")
        attachScreenshot("synthetic-notification-chat-dismissed-once")

        let otherRequest = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(otherRequest.waitForExistence(timeout: 5), app.debugDescription)
        otherRequest.tap()
        XCTAssertTrue(app.buttons["request-heading"].label.contains("Facilities desk"),
                      app.debugDescription)
        let targetRequest = app.descendants(matching: .any)["request-row-unknown-01"]
        XCTAssertTrue(targetRequest.waitForExistence(timeout: 5), app.debugDescription)
        targetRequest.tap()
        let targetHeading = app.buttons["request-heading"]
        XCTAssertTrue(targetHeading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(targetHeading.label.contains("Unfamiliar interface"), targetHeading.debugDescription)
        let stayedClosed = noChat.waitForNonExistence(timeout: 2)
        XCTAssertTrue(stayedClosed,
                      "Recreating the detail does not reopen a dismissed notification chat. \(app.debugDescription)")
        attachScreenshot("synthetic-notification-chat-stays-closed-after-detail-recreation")
        guard stayedClosed else { return }

        app.buttons["Chat"].tap()
        XCTAssertTrue(noChat.waitForExistence(timeout: 5),
                      "The person can intentionally reopen the Chat surface. \(app.debugDescription)")
        attachScreenshot("synthetic-notification-chat-intentionally-reopened")
    }

    func testWideDetailChatButtonAlsoPresentsDismissibleSheet() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The wide detail presentation requires an iPad layout.")
        }
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()
        let sample = app.descendants(matching: .any)["sample-information-2"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5), app.debugDescription)
        sample.tap()

        let chat = app.toolbars.buttons["Chat"].exists
            ? app.toolbars.buttons["Chat"] : app.navigationBars.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(chat.isHittable, app.debugDescription)
        let inputSurfaceQuery = app.otherElements.matching(
            identifier: "sample-chat-input-surface")
        let inputSurfaceCountBeforePresentation = inputSurfaceQuery.count
        XCTAssertGreaterThan(inputSurfaceCountBeforePresentation, 0,
                             "Wide landscape keeps inline Chat in the detail while the Chat button can still open its sheet.")
        attachScreenshot("wide-detail-trailing-chat-toolbar-before-tap")
        chat.tap()

        let window = app.windows.firstMatch.frame
        let inputSurfaceAppears = expectation(
            for: NSPredicate(format: "count > %d", inputSurfaceCountBeforePresentation),
            evaluatedWith: inputSurfaceQuery)
        wait(for: [inputSurfaceAppears], timeout: 5)
        let inputSurfaces = inputSurfaceQuery.allElementsBoundByIndex
        let composerContainers = app.descendants(matching: .any)
            .containing(.textView, identifier: "sample-chat-composer")
            .allElementsBoundByIndex
        let presentations = inputSurfaces.compactMap { surface -> (XCUIElement, CGRect)? in
            let frames = centeredPresentationFrames(
                in: composerContainers,
                containing: surface.frame,
                window: window)
            guard frames.count == 1 else { return nil }
            return (surface, frames[0])
        }
        guard presentations.count == 1 else {
            XCTFail("Expected one composer surface inside one centered native Chat presentation. \(app.debugDescription)")
            return
        }
        let (chatInputSurface, presentationFrame) = presentations[0]
        let composers = chatInputSurface.textViews.matching(
            identifier: "sample-chat-composer")
        guard composers.count == 1 else {
            XCTFail("Expected one composer inside the native chat presentation's composer surface. \(app.debugDescription)")
            return
        }
        let composer = composers.element(boundBy: 0)
        guard composer.waitForExistence(timeout: 5) else {
            XCTFail("The native chat presentation's composer did not appear. \(app.debugDescription)")
            return
        }
        attachScreenshot("wide-detail-chat-presentation-open")
        dismissPresentedChat(app,
                             presentationFrame,
                             inputSurfaceQuery,
                             inputSurfaceCountBeforePresentation)
        XCTAssertTrue(chat.isHittable, app.debugDescription)
        attachScreenshot("wide-detail-chat-toolbar-after-presentation-dismissal")
    }

    func testUnreadChatIsExposedAndClearedFromToolbar() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()

        let search = workspaceSearchField(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("studio collection\n")
        let sample = app.descendants(matching: .any)["sample-warning-0"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5), app.debugDescription)
        sample.tap()

        let chat = app.buttons["bubble.left.and.bubble.right"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(chat.value as? String, "1 item",
                       "The native toolbar badge must expose the unread chat count.")
        attachScreenshot("unread-chat-toolbar-badge")
        chat.tap()
        let composer = app.textViews["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertFalse(app.buttons["Close"].exists, app.debugDescription)
        dismissChatSheet(app, composer)
        XCTAssertNotEqual(chat.value as? String, "1 item",
                          "Opening the conversation clears its unread indicator.")
        attachScreenshot("chat-toolbar-after-reading")
    }

    func testDetailVersionIndicatorOpensReadOnlyHistoricalMessageAndChatHasNoVersionPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        let search = workspaceSearchField(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        search.tap()
        search.typeText("Archive\n")
        let revised = app.descendants(matching: .any)["sample-approval-2"]
        XCTAssertTrue(revised.waitForExistence(timeout: 10), app.debugDescription)
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 where !revised.isHittable { list.swipeUp() }
        XCTAssertTrue(revised.isHittable, app.debugDescription)
        revised.tap()

        let versionIndicator = app.descendants(matching: .any)["request-update-fact"]
        XCTAssertTrue(versionIndicator.waitForExistence(timeout: 5), app.debugDescription)
        versionIndicator.tap()
        let original = app.buttons["Original version"]
        XCTAssertTrue(original.waitForExistence(timeout: 5), app.debugDescription)
        original.tap()

        let historicalContent = app.scrollViews["historical-message-version"]
        XCTAssertTrue(historicalContent.waitForExistence(timeout: 5), app.debugDescription)
        let historicalTitle = app.staticTexts["historical-version-title"]
        let historicalBody = app.staticTexts["historical-version-body"]
        XCTAssertTrue(historicalTitle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(historicalBody.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(historicalTitle.isHittable, app.debugDescription)
        XCTAssertTrue(historicalBody.isHittable, app.debugDescription)
        XCTAssertFalse(historicalContent.buttons["request-finish"].exists,
                       "A historical message version is available for reading and has no Send action.")
        attachScreenshot("detail-original-message-version-read-only")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["sample-finish"].waitForExistence(timeout: 5),
                      "The current version's local response flow remains available.")
        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        chat.tap()
        XCTAssertTrue(app.textViews["sample-chat-composer"].waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["conversation-revision-picker"].exists,
                       "Version selection belongs to message details, not Chat.")
        attachScreenshot("chat-without-version-selector")
    }

    func testHorizontalSwipeInsideChatReturnsToListAndPreservesDraft() {
        for direction in ["left", "right"] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
            app.launch()

            let row = app.descendants(matching: .any)["sample-information-2"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
            row.tap()
            let chat = app.buttons["Chat"]
            XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
            chat.tap()
            let composer = app.textViews["sample-chat-composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
            composer.tap()
            composer.typeText("Swipe draft stays saved")

            let history = app.scrollViews["conversation-history-scroll"]
            XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
            let startX: CGFloat = direction == "left" ? 0.9 : 0.1
            let endX: CGFloat = direction == "left" ? 0.1 : 0.9
            let start = history.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
            let end = history.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 0.1)

            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "A horizontal \(direction) swipe in Chat returns to the message list. \(app.debugDescription)")
            XCTAssertTrue(row.isHittable, app.debugDescription)
            XCTAssertFalse(composer.exists, app.debugDescription)
            attachScreenshot("chat-horizontal-swipe-\(direction)-returns-to-list")

            row.tap()
            let reopenedChat = app.buttons["Chat"]
            XCTAssertTrue(reopenedChat.waitForExistence(timeout: 5), app.debugDescription)
            reopenedChat.tap()
            let reopenedComposer = app.textViews["sample-chat-composer"]
            XCTAssertTrue(reopenedComposer.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(reopenedComposer.value as? String, "Swipe draft stays saved",
                           "Dismissing Chat keeps its unsent draft for an intentional reopen.")
            app.terminate()
        }
    }

    private func verifyToolbarChatButton(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "-uiUserInterfaceStyle", appearance]
        app.launch()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        let sample = app.descendants(matching: .any)["sample-information-2"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5), app.debugDescription)
        sample.tap()

        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5), app.debugDescription)
        let chat = app.toolbars.buttons["Chat"].exists
            ? app.toolbars.buttons["Chat"] : app.navigationBars.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(chat.isHittable, app.debugDescription)
        XCTAssertFalse(app.scrollViews["message-card-scroll"].buttons["Chat"].exists,
                       "Chat belongs to the navigation container, not the message card.")
        XCTAssertFalse(app.buttons["Later"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Not now"].exists, app.debugDescription)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "request-detail-chat-\(appearance.lowercased())"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "request-detail-chat-\(appearance.lowercased())-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        chat.tap()
        let composer = app.textViews["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Close"].exists, app.debugDescription)
        attachScreenshot("chat-sheet-without-header-or-close-\(appearance.lowercased())")
        if appearance == "Light" {
            composer.tap()
            composer.typeText("Draft survives dismissal")
        }
        dismissChatSheet(app, composer)
        XCTAssertFalse(composer.waitForExistence(timeout: 1.5),
                       "One deliberate dismissal leaves Chat closed until the toolbar button is tapped.")
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(chat.isHittable, app.debugDescription)
        XCTAssertFalse(composer.exists, app.debugDescription)
        attachScreenshot("chat-dismissed-once-\(appearance.lowercased())")
        chat.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5),
                      "The toolbar Chat button must keep reopening its sheet. \(app.debugDescription)")
        if appearance == "Light" {
            XCTAssertEqual(composer.value as? String, "Draft survives dismissal",
                           "Swiping the sheet away must preserve the unsent chat draft.")
        }
        attachScreenshot("chat-sheet-reopened-\(appearance.lowercased())")
    }

    private func dismissChatSheet(_ app: XCUIApplication, _ composer: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let draftBeforeKeyboardDismissal = composer.value as? String
            let history = app.scrollViews["conversation-history-scroll"]
            XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
            // Interactive dismissal begins in the history and continues through the keyboard.
            let start = history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            let end = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(forDuration: 0.1, thenDragTo: end)
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(composer.value as? String, draftBeforeKeyboardDismissal,
                           "Dismissing the keyboard keeps the unsent Chat draft.")
        }

        let window = app.windows.firstMatch.frame
        let contentFrame = composer.frame
        let containers = app.otherElements
            .containing(.textView, identifier: "sample-chat-composer")
            .allElementsBoundByIndex.map(\.frame)
        let presentation = containers
            .filter { $0.width > contentFrame.width + 4 &&
                      $0.height > contentFrame.height * 4 &&
                      $0.height < window.height - 4 }
            .max { $0.width * $0.height < $1.width * $1.height } ?? window
        let screen = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = screen.withOffset(CGVector(dx: presentation.midX,
                                               dy: presentation.minY + 16))
        let end = start.withOffset(CGVector(dx: 0, dy: min(400, window.height * 0.8)))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    private func centeredPresentationFrames(in elements: [XCUIElement],
                                            containing contentFrame: CGRect,
                                            window: CGRect) -> [CGRect] {
        var frames: [CGRect] = []
        for element in elements {
            let frame = element.frame
            guard frame.contains(contentFrame),
                  frame.width > contentFrame.width + 4,
                  frame.height > contentFrame.height * 4,
                  frame.width < window.width - 4,
                  frame.height < window.height - 4,
                  abs(frame.midX - window.midX) <= 4,
                  abs(frame.midY - window.midY) <= 4,
                  !frames.contains(frame) else {
                continue
            }
            frames.append(frame)
        }
        return frames
    }

    private func dismissPresentedChat(_ app: XCUIApplication,
                                      _ presentation: CGRect,
                                      _ inputSurfaceQuery: XCUIElementQuery,
                                      _ inputSurfaceCountBeforePresentation: Int) {
        let window = app.windows.firstMatch.frame
        let outsidePoint = CGPoint(x: max(window.minX + 8, presentation.minX - 24),
                                   y: presentation.midY)
        guard !presentation.contains(outsidePoint),
              window.contains(outsidePoint) else {
            XCTFail("Expected a visible point outside the native Chat presentation. \(app.debugDescription)")
            return
        }
        let outsideTap = app.coordinate(withNormalizedOffset: CGVector(
            dx: (outsidePoint.x - window.minX) / window.width,
            dy: (outsidePoint.y - window.minY) / window.height))
        outsideTap.tap()
        let presentationDismissed = expectation(
            for: NSPredicate(format: "count == %d", inputSurfaceCountBeforePresentation),
            evaluatedWith: inputSurfaceQuery)
        wait(for: [presentationDismissed], timeout: 5)
        XCTAssertEqual(inputSurfaceQuery.count, inputSurfaceCountBeforePresentation,
                       "The centered Chat presentation should close after an outside tap. \(app.debugDescription)")
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
