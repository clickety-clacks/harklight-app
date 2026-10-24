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
        row.tap()

        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Facilities desk"].exists, app.debugDescription)
        let diagnostic = app.descendants(matching: .any)["inbox-ui-diagnostics"].firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(diagnostic.label.contains("visibility=detailOnly"),
                      "Selecting one row should close the portrait master overlay. \(diagnostic.label)")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "portrait-selection-detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
