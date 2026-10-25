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
        attachScreenshot("wide-detail-trailing-chat-toolbar-before-tap")
        chat.tap()

        let chatSheets = app.sheets.containing(.other,
                                               identifier: "sample-chat-input-surface")
        let sheetAppears = expectation(for: NSPredicate(format: "count == 1"),
                                       evaluatedWith: chatSheets)
        wait(for: [sheetAppears], timeout: 5)
        guard chatSheets.count == 1 else {
            XCTFail("Expected one presented chat sheet containing the composer surface. \(app.debugDescription)")
            return
        }
        let chatSheet = chatSheets.element(boundBy: 0)
        let inputSurfaces = chatSheet.otherElements.matching(
            identifier: "sample-chat-input-surface")
        guard inputSurfaces.count == 1 else {
            XCTFail("Expected one composer surface inside the chat sheet. \(app.debugDescription)")
            return
        }
        let composers = inputSurfaces.textFields.matching(
            identifier: "sample-chat-composer")
        guard composers.count == 1 else {
            XCTFail("Expected one composer inside the chat sheet's composer surface. \(app.debugDescription)")
            return
        }
        let composer = composers.element(boundBy: 0)
        guard composer.waitForExistence(timeout: 5) else {
            XCTFail("The chat sheet's composer did not appear. \(app.debugDescription)")
            return
        }
        dismissNativeChatSheet(app, chatSheet, composer)
        XCTAssertTrue(chat.isHittable, app.debugDescription)
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

    private func dismissNativeChatSheet(_ app: XCUIApplication,
                                        _ sheet: XCUIElement,
                                        _ composer: XCUIElement) {
        let windowHeight = app.windows.firstMatch.frame.height
        let sheetFrame = sheet.frame
        XCTAssertGreaterThan(sheetFrame.height, composer.frame.height * 4,
                             app.debugDescription)
        let start = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        let end = start.withOffset(CGVector(dx: 0, dy: min(400, windowHeight * 0.8)))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
