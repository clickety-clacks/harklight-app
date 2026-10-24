import XCTest

@MainActor
final class DetailChatButtonUITests: XCTestCase {
    func testDetailChatUsesNativeToolbarInLightMode() {
        verifyToolbarChatButton(appearance: "Light")
    }

    func testDetailChatUsesNativeToolbarInDarkMode() {
        verifyToolbarChatButton(appearance: "Dark")
    }

    func testUnreadChatIsExposedAndClearedFromToolbar() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()

        let searchTab = workspaceTab("Search", in: app)
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10), app.debugDescription)
        searchTab.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("studio collection\n")
        let sample = app.descendants(matching: .any)["sample-warning-0"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5), app.debugDescription)
        sample.tap()

        let chat = app.toolbars.buttons["Chat"].exists
            ? app.toolbars.buttons["Chat"] : app.navigationBars.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(chat.value as? String, "1 item",
                       "The native toolbar badge must expose the unread chat count.")
        attachScreenshot("unread-chat-toolbar-badge")
        chat.tap()
        XCTAssertTrue(app.textFields["sample-chat-composer"].waitForExistence(timeout: 5),
                      app.debugDescription)
        app.buttons["Close"].tap()
        XCTAssertNotEqual(chat.value as? String, "1 item",
                          "Opening the conversation clears its unread indicator.")
        attachScreenshot("chat-toolbar-after-reading")
    }

    private func verifyToolbarChatButton(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples",
                               "-uiUserInterfaceStyle", appearance]
        app.launch()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        let searchTab = workspaceTab("Search", in: app)
        if searchTab.exists && !searchTab.isSelected { searchTab.tap() }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("Thursday\n")

        let sample = app.descendants(matching: .any)["sample-information-0"]
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
        XCTAssertTrue(app.textFields["sample-chat-composer"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.sheets.firstMatch.exists,
                       "The chat panel should be a button-anchored popover, not a sheet. \(app.debugDescription)")

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(chat.isHittable, app.debugDescription)
        XCTAssertFalse(app.textFields["sample-chat-composer"].exists, app.debugDescription)
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
