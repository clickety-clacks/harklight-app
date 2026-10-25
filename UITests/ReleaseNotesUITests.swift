import XCTest

@MainActor
final class ReleaseNotesUITests: XCTestCase {
    func testUpdateSheetAndSettingsHistoryShowReleasedNotes() {
        let app = XCUIApplication()
        let simulatedCurrentBuild = "61" // Synthetic metadata; no archive mapping is claimed.
        app.launchArguments = ["--reset-attention-fixture"]
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST"] = "1"
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST_BUILD"] = simulatedCurrentBuild
        app.launch()

        let updateTitle = app.navigationBars["What’s New"]
        XCTAssertTrue(updateTitle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Version 0.1.0 · Build \(simulatedCurrentBuild)"].exists,
                      "The update sheet identifies the released build and version.")
        XCTAssertTrue(app.staticTexts["Scroll through your Inbox more smoothly"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Keep your place while browsing messages and loading older items."].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["See clearer release notes"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Each update now has an icon, a short title and a clear description."].exists,
                      app.debugDescription)
        XCTAssertFalse(app.staticTexts["Earlier on October 25, 2026"].exists,
                       "Dated history-only notes do not appear in the update sheet.")
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
        XCTAssertTrue(app.staticTexts["Version 0.1.0 · Build \(simulatedCurrentBuild)"].exists,
                      "Settings history identifies the build attached to this release note.")
        XCTAssertTrue(app.staticTexts["Scroll through your Inbox more smoothly"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Keep your place while browsing messages and loading older items."].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["See clearer release notes"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Each update now has an icon, a short title and a clear description."].exists,
                      app.debugDescription)
        attachScreenshot("release-notes-settings-history", from: app)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Version 0.1.0 · Build 59"].exists,
                      "Settings history retains the confirmed numbered release.")
        XCTAssertTrue(app.staticTexts["Settings in the toolbar"].exists,
                      "Settings history retains the confirmed Build 59 entry.")
        XCTAssertTrue(app.staticTexts["Version 0.1.0 · Earlier on October 25, 2026"].exists,
                      "Settings history identifies the dated entry without a build number.")
        XCTAssertTrue(app.staticTexts["Reply right from the message"].exists,
                      "Settings history includes the shipped inline Reply field.")
        XCTAssertTrue(app.staticTexts["See when your agent is listening"].exists,
                      app.debugDescription)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Keep your keyboard while reading"].exists,
                      app.debugDescription)
        attachScreenshot("release-notes-settings-history-lower", from: app)
    }

    private func attachScreenshot(_ name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
