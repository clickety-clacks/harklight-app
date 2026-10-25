import XCTest

@MainActor
final class ReleaseNotesUITests: XCTestCase {
    func testUpdateSheetAndSettingsHistoryShowReleasedNotes() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST"] = "1"
        app.launch()

        let updateTitle = app.navigationBars["What’s New"]
        XCTAssertTrue(updateTitle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Version 0.1.0 · Build 1"].exists,
                      "The update sheet identifies the released build and version.")
        XCTAssertTrue(app.staticTexts["What’s New after an update"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Release notes in Settings"].exists,
                      app.debugDescription)
        attachScreenshot("release-notes-update-sheet", from: app)

        app.buttons["Done"].tap()
        let settings = app.buttons["inbox-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()

        let historyLink = app.buttons["Release notes"]
        XCTAssertTrue(historyLink.waitForExistence(timeout: 5), app.debugDescription)
        historyLink.tap()
        XCTAssertTrue(app.navigationBars["Release notes"].waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Version 0.1.0 · Build 1"].exists,
                      "Settings history identifies the released build and version.")
        XCTAssertTrue(app.staticTexts["What’s New after an update"].exists,
                      app.debugDescription)
        attachScreenshot("release-notes-settings-history", from: app)
    }

    private func attachScreenshot(_ name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
