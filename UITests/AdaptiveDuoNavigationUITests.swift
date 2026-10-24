import XCTest

@MainActor
final class AdaptiveDuoNavigationUITests: XCTestCase {
    func testPortraitSelectionShowsDetailAndDismissesMasterOverlay() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-ui-diagnostics"]
        app.launch()

        let row = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        attachScreenshot("portrait-master-before-selection")
        row.tap()

        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Facilities desk"].exists, app.debugDescription)
        let diagnostic = app.descendants(matching: .any)["inbox-ui-diagnostics"].firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5), app.debugDescription)
        let visibility = diagnostic.label.components(separatedBy: " | ")
            .first(where: { $0.hasPrefix("visibility=") })
        XCTAssertTrue(visibility?.contains("detailOnly") == true,
                      "Selecting one row should close the portrait master overlay. \(diagnostic.label)")

        attachScreenshot("portrait-detail-after-selection")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "portrait-selection-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let back = app.toolbars.buttons["BackButton"].exists
            ? app.toolbars.buttons["BackButton"] : app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The system Back control must reopen the message list.")
        attachScreenshot("portrait-master-after-native-back")
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
