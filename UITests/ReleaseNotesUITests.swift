import XCTest

@MainActor
final class ReleaseNotesUITests: XCTestCase {
    func testUpdateSheetAndSettingsHistoryShowReleasedNotes() {
        let app = XCUIApplication()
        let simulatedCurrentBuild = "62" // Synthetic metadata; no archive mapping is claimed.
        app.launchArguments = ["--reset-attention-fixture"]
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST"] = "1"
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST_BUILD"] = simulatedCurrentBuild
        app.launch()

        let updateTitle = app.navigationBars["What’s New"]
        XCTAssertTrue(updateTitle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Version 0.1.0 · Build \(simulatedCurrentBuild)"].exists,
                      "The update sheet identifies the released build and version.")
        XCTAssertTrue(app.staticTexts["A single rounded Reply box"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["The Reply label and full-width editor now sit together in one rounded box."].exists,
                      app.debugDescription)
        XCTAssertFalse(app.staticTexts["Scroll through your Inbox more smoothly"].exists,
                       "Earlier build notes do not appear in the current update sheet.")
        XCTAssertFalse(app.staticTexts["See clearer release notes"].exists,
                       "Earlier build notes do not appear in the current update sheet.")
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
        let historyList = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
        XCTAssertTrue(historyList.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(historyList.staticTexts["Version 0.1.0 · Build \(simulatedCurrentBuild)"].exists,
                      "Settings history identifies the build attached to this release note.")
        XCTAssertTrue(historyList.staticTexts["A single rounded Reply box"].exists,
                      app.debugDescription)
        XCTAssertTrue(historyList.staticTexts["The Reply label and full-width editor now sit together in one rounded box."].exists,
                      app.debugDescription)

        let build61Header = historyList.staticTexts["Version 0.1.0 · Build 61"]
        let inboxScrollingTitle = historyList.staticTexts["Scroll through your Inbox more smoothly"]
        let inboxScrollingDetail = historyList.staticTexts[
            "Scrolling the inbox list does less work, so it should feel smoother."
        ]
        XCTAssertTrue(build61Header.isHittable,
                      "The earlier numbered release is visible before history is scrolled.")
        XCTAssertTrue(inboxScrollingTitle.isHittable, app.debugDescription)
        XCTAssertTrue(inboxScrollingDetail.isHittable, app.debugDescription)
        XCTAssertTrue(historyList.staticTexts["See clearer release notes"].isHittable,
                      app.debugDescription)
        XCTAssertTrue(historyList.staticTexts[
            "Each update now has an icon, a short title and a clear description."
        ].isHittable, app.debugDescription)
        attachScreenshot("release-notes-settings-history", from: app)

        let build59Header = historyList.staticTexts["Version 0.1.0 · Build 59"]
        revealHistoryElement(build59Header, in: historyList)
        XCTAssertTrue(build59Header.isHittable,
                      "Settings history keeps earlier numbered notes after the new release.")
        let settingsTitle = historyList.staticTexts["Settings in the toolbar"]
        revealHistoryElement(settingsTitle, in: historyList)
        XCTAssertTrue(settingsTitle.isHittable,
                      "Settings history retains the confirmed Build 59 entry.")
        let datedHistoryHeader = historyList.staticTexts["Version 0.1.0 · Earlier on October 25, 2026"]
        revealHistoryElement(datedHistoryHeader, in: historyList)
        XCTAssertTrue(datedHistoryHeader.isHittable,
                      "Settings history identifies the dated entry without a build number.")
        let replyTitle = historyList.staticTexts["Reply right from the message"]
        revealHistoryElement(replyTitle, in: historyList)
        XCTAssertTrue(replyTitle.isHittable,
                      "Settings history includes the shipped inline Reply field.")
        let listeningTitle = historyList.staticTexts["See when your agent is listening"]
        revealHistoryElement(listeningTitle, in: historyList)
        XCTAssertTrue(listeningTitle.isHittable,
                      app.debugDescription)
        let keyboardTitle = historyList.staticTexts["Keep your keyboard while reading"]
        revealHistoryElement(keyboardTitle, in: historyList)
        XCTAssertTrue(keyboardTitle.isHittable,
                      app.debugDescription)
        attachScreenshot("release-notes-settings-history-lower", from: app)
    }

    private func revealHistoryElement(_ element: XCUIElement, in list: XCUIElement) {
        for _ in 0..<8 where !element.isHittable {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable,
                      "The requested release-note entry becomes visible with incremental history scrolling.")
    }

    private func attachScreenshot(_ name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
