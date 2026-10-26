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
        XCTAssertTrue(app.textFields["sample-chat-composer"].waitForExistence(timeout: 5),
                      app.debugDescription)
    }

    func testDetailChatUsesNativeToolbarInLightMode() {
        verifyToolbarChatButton(appearance: "Light")
    }

    func testDetailChatUsesNativeToolbarInDarkMode() {
        verifyToolbarChatButton(appearance: "Dark")
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
        XCTAssertEqual(inputSurfaceCountBeforePresentation, 0,
                       "Landscape keeps the native list/detail split until Chat opens its sheet.")
        attachScreenshot("wide-detail-trailing-chat-toolbar-before-tap")
        chat.tap()

        let window = app.windows.firstMatch.frame
        let inputSurfaceAppears = expectation(
            for: NSPredicate(format: "count > %d", inputSurfaceCountBeforePresentation),
            evaluatedWith: inputSurfaceQuery)
        wait(for: [inputSurfaceAppears], timeout: 5)
        let inputSurfaces = inputSurfaceQuery.allElementsBoundByIndex
        let composerContainers = app.descendants(matching: .any)
            .containing(.textField, identifier: "sample-chat-composer")
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
        let composers = chatInputSurface.textFields.matching(
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
        let composer = app.textFields["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertFalse(app.buttons["Close"].exists, app.debugDescription)
        dismissChatSheet(app, composer)
        XCTAssertNotEqual(chat.value as? String, "1 item",
                          "Opening the conversation clears its unread indicator.")
        attachScreenshot("chat-toolbar-after-reading")
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
        let composer = app.textFields["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Close"].exists, app.debugDescription)
        attachScreenshot("chat-sheet-without-header-or-close-\(appearance.lowercased())")
        if appearance == "Light" {
            composer.tap()
            composer.typeText("Draft survives dismissal")
        }
        dismissChatSheet(app, composer)
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(chat.isHittable, app.debugDescription)
        XCTAssertFalse(composer.exists, app.debugDescription)
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
        let window = app.windows.firstMatch.frame
        let contentFrame = composer.frame
        let containers = app.otherElements
            .containing(.textField, identifier: "sample-chat-composer")
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
