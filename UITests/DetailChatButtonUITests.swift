import XCTest

@MainActor
final class DetailChatButtonUITests: XCTestCase {
    func testDetailChatButtonFloatsBottomTrailingInLightMode() {
        verifyFloatingChatButton(appearance: "Light")
    }

    func testDetailChatButtonFloatsBottomTrailingInDarkMode() {
        verifyFloatingChatButton(appearance: "Dark")
    }

    private func verifyFloatingChatButton(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples",
                               "-uiUserInterfaceStyle", appearance]
        app.launch()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        let searchTab = app.tabBars.buttons["Search"]
        if searchTab.exists && !searchTab.isSelected { searchTab.tap() }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("Thursday\n")

        let sample = app.descendants(matching: .any)["sample-information-0"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5), app.debugDescription)
        sample.tap()

        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5), app.debugDescription)
        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(chat.isHittable, app.debugDescription)
        XCTAssertGreaterThan(chat.frame.midX, app.frame.midX,
                            "Chat is placed on the trailing side of request detail.")
        XCTAssertGreaterThan(chat.frame.midY, app.frame.midY,
                            "Chat is placed near the bottom of request detail.")
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

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(chat.isHittable, app.debugDescription)
        XCTAssertFalse(app.textFields["sample-chat-composer"].exists, app.debugDescription)
    }
}
