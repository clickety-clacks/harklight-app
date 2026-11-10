import XCTest

@MainActor
final class ReleaseNotesUITests: XCTestCase {
    func testPost79UpdateLabelsUnknownBuildNumbersWithoutGuessing() {
        let app = XCUIApplication()
        let simulatedCurrentBuild = "9001" // Synthetic metadata; no archive mapping is claimed.
        app.launchArguments = ["--reset-attention-fixture"]
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST"] = "1"
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST_BUILD"] = simulatedCurrentBuild
        app.launch()

        XCTAssertTrue(app.navigationBars["What’s New"].waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Keep an unfinished Reply"].exists,
                      app.debugDescription)
        let unconfirmedUpdateHeader = app.staticTexts["Version 0.1.0 · Build UNCONFIRMED"]
        XCTAssertTrue(unconfirmedUpdateHeader.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["See why a response was not accepted"].exists,
                      app.debugDescription)
        let updateHeader = app.staticTexts["Version 0.1.0 · Build UNCONFIRMED"]
        XCTAssertTrue(updateHeader.exists, app.debugDescription)
        attachScreenshot("release-notes-post79-update", from: app)
        XCTAssertTrue(app.staticTexts["See when Chat needs attention"].exists,
                      app.debugDescription)
        let exampleMessagesNote = app.staticTexts["Example messages are gone from the app"]
        revealUpdateSheetElement(exampleMessagesNote, in: app)
        XCTAssertTrue(exampleMessagesNote.exists,
                      app.debugDescription)
        XCTAssertFalse(app.staticTexts["Version 0.1.0 · Build \(simulatedCurrentBuild)"].exists,
                       "A later installed build must not relabel this update.")

        app.buttons["Done"].tap()
        let settings = app.buttons["inbox-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()
        let historyLink = app.buttons["Release notes"]
        XCTAssertTrue(historyLink.waitForExistence(timeout: 5), app.debugDescription)
        historyLink.tap()
        XCTAssertTrue(app.navigationBars["Release notes"].waitForExistence(timeout: 5),
                      app.debugDescription)
        let historicalSection = app.cells.containing(
            .staticText, identifier: "Changes since Build 79").firstMatch
        revealHistoryElement(historicalSection, in: app)
        XCTAssertTrue(historicalSection.staticTexts[
            "Version 0.1.0 · Build UNCONFIRMED"
        ].exists, "Settings keeps unknown historical build numbers explicit.")
        attachScreenshot("release-notes-settings-post79-history", from: app)
        let earlierHighlight = app.staticTexts["More details for each message"]
        revealHistoryElement(earlierHighlight, in: app)
        XCTAssertTrue(earlierHighlight.exists,
                      "The earlier historical entry remains available in Settings.")
    }

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
        let currentUnconfirmedHeader = app.staticTexts["Version 0.1.0 · Build UNCONFIRMED"]
        XCTAssertTrue(currentUnconfirmedHeader.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Version 0.1.0 · Build \(simulatedCurrentBuild)"].exists,
                      "Settings preserves the existing entry for this numbered build.")
        XCTAssertTrue(app.staticTexts["A single rounded Reply box"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["The Reply label and full-width editor now sit together in one rounded box."].exists,
                      app.debugDescription)

        let build61Header = app.staticTexts["Version 0.1.0 · Build 61"]
        let inboxScrollingTitle = app.staticTexts["Scroll through your Inbox more smoothly"]
        let inboxScrollingDetail = app.staticTexts[
            "Scrolling the inbox list does less work, so it should feel smoother."
        ]
        XCTAssertTrue(build61Header.isHittable,
                      "The earlier numbered release is visible before history is scrolled.")
        XCTAssertTrue(inboxScrollingTitle.isHittable, app.debugDescription)
        XCTAssertTrue(inboxScrollingDetail.isHittable, app.debugDescription)
        XCTAssertTrue(app.staticTexts["See clearer release notes"].isHittable,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts[
            "Each update now has an icon, a short title and a clear description."
        ].isHittable, app.debugDescription)
        attachScreenshot("release-notes-settings-history", from: app)

        let build59Header = app.staticTexts["Version 0.1.0 · Build 59"]
        revealHistoryElement(build59Header, in: app)
        XCTAssertTrue(build59Header.isHittable,
                      "Settings history keeps earlier numbered notes after the new release.")
        let settingsTitle = app.staticTexts["Settings in the toolbar"]
        revealHistoryElement(settingsTitle, in: app)
        XCTAssertTrue(settingsTitle.isHittable,
                      "Settings history retains the confirmed Build 59 entry.")
        let datedHistorySection = app.cells.containing(
            .staticText, identifier: "Earlier on October 25, 2026").firstMatch
        revealHistoryElement(datedHistorySection, in: app)
        XCTAssertTrue(datedHistorySection.staticTexts[
            "Version 0.1.0 · Build UNCONFIRMED"
        ].exists, "Settings shows the dated entry and marks its build number unconfirmed.")
        let replyTitle = app.staticTexts["Reply right from the message"]
        revealHistoryElement(replyTitle, in: app)
        XCTAssertTrue(replyTitle.isHittable,
                      "Settings history includes the shipped inline Reply field.")
        let listeningTitle = app.staticTexts["See when your agent is listening"]
        revealHistoryElement(listeningTitle, in: app)
        XCTAssertTrue(listeningTitle.isHittable,
                      app.debugDescription)
        let keyboardTitle = app.staticTexts["Keep your keyboard while reading"]
        revealHistoryElement(keyboardTitle, in: app)
        XCTAssertTrue(keyboardTitle.isHittable,
                      app.debugDescription)
        attachScreenshot("release-notes-settings-history-lower", from: app)
    }

    private func revealHistoryElement(_ element: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews["release-notes-history"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        reveal(element, in: list)
    }

    private func revealUpdateSheetElement(_ element: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews["release-notes-update-sheet"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        reveal(element, in: list)
    }

    private func reveal(_ element: XCUIElement, in list: XCUIElement) {
        for _ in 0..<24 where !element.isHittable {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.80))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
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
