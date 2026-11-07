import XCTest

@MainActor
final class ReleaseNotesUITests: XCTestCase {
    func testCurrentReleaseOpensOnFirstInstallAndShowsItsBuildInSettings() {
        let simulatedCurrentBuild = "142" // Synthetic metadata; no archive mapping is claimed.
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST"] = "1"
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST_FRESH_INSTALL"] = "1"
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST_BUILD"] = simulatedCurrentBuild
        app.launch()

        XCTAssertTrue(app.navigationBars["What’s New"].waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Version 0.1.0 · Build \(simulatedCurrentBuild)"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Read chats after a request is replaced"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts[
            "You can still open a replaced request’s chat history, but you can’t send new messages there."
        ].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Keep track of replies across conversations"].exists,
                       "A fresh install shows only the current pending entry.")

        app.buttons["Done"].tap()
        let settings = app.buttons["inbox-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()
        let historyLink = app.buttons["Release notes"]
        XCTAssertTrue(historyLink.waitForExistence(timeout: 5), app.debugDescription)
        historyLink.tap()
        XCTAssertTrue(app.navigationBars["Release notes"].waitForExistence(timeout: 5),
                      app.debugDescription)
        let buildHeader = app.staticTexts["Version 0.1.0 · Build \(simulatedCurrentBuild)"]
        revealHistoryElement(buildHeader, in: app)
        XCTAssertTrue(buildHeader.exists,
                      "Settings keeps the current release's build label.")
        let shippedBuildHeader = app.staticTexts["Version 0.1.0 · Build 139"]
        revealHistoryElement(shippedBuildHeader, in: app)
        XCTAssertTrue(shippedBuildHeader.exists,
                      "Settings preserves the stamped TestFlight build for the earlier entry.")
        let updateTitle = app.staticTexts["Know which release is installed"]
        revealHistoryElement(updateTitle, in: app)
        XCTAssertTrue(updateTitle.exists,
                      app.debugDescription)
        let repliesTitle = app.staticTexts["Keep track of replies across conversations"]
        revealHistoryElement(repliesTitle, in: app)
        XCTAssertTrue(repliesTitle.exists,
                      "Settings history keeps the cross-conversation reply note.")
        let repliesDetail = app.staticTexts[
            "Reading a reply in one conversation does not mark new replies in other conversations as read."
        ]
        revealHistoryElement(repliesDetail, in: app)
        XCTAssertTrue(repliesDetail.exists, app.debugDescription)
    }

    func testPost79UpdateShowsEarliestConfirmedContainingBuildWithoutRelabeling() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST"] = "1"
        app.launchEnvironment["HARKLIGHT_RELEASE_NOTES_UI_TEST_BUILD"] = "107"
        app.launch()

        XCTAssertTrue(app.navigationBars["What’s New"].waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Keep an unfinished Reply"].exists,
                      app.debugDescription)
        let unconfirmedUpdateHeader = app.staticTexts[
            "Version 0.1.0 · Response delivery improvements"
        ]
        XCTAssertTrue(unconfirmedUpdateHeader.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["See why a response was not accepted"].exists,
                      app.debugDescription)
        let updateHeader = app.staticTexts["Version 0.1.0 · First confirmed in Build 106"]
        XCTAssertTrue(updateHeader.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["See when Chat needs attention"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Example messages are gone from the app"].exists,
                      app.debugDescription)
        let pendingHeader = app.staticTexts["Version 0.1.0 · Build 107"]
        revealHistoryElement(pendingHeader, in: app)
        XCTAssertTrue(pendingHeader.exists,
                      "The pending release uses the installed build number.")
        XCTAssertTrue(app.staticTexts["Version 0.1.0 · First confirmed in Build 106"].exists,
                      "A later installed build must not relabel the historical update.")

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
            "Version 0.1.0 · First confirmed in Build 106"
        ].exists, "Settings keeps the historical entry's confirmed build label.")
        let earlierHighlight = app.staticTexts["More context in the Inbox"]
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
        XCTAssertTrue(app.staticTexts["Read chats after a request is replaced"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts[
            "You can still open a replaced request’s chat history, but you can’t send new messages there."
        ].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Know which release is installed"].exists,
                       "The stamped Build139 entry is future history at this synthetic build.")
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
        let currentBuildHeader = app.staticTexts["Version 0.1.0 · Build \(simulatedCurrentBuild)"]
        XCTAssertTrue(currentBuildHeader.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(currentBuildHeader.exists,
                      "Settings history identifies the build attached to this release note.")
        XCTAssertTrue(app.staticTexts["A single rounded Reply box"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["The Reply label and full-width editor now sit together in one rounded box."].exists,
                      app.debugDescription)

        let build61Header = app.staticTexts["Version 0.1.0 · Build 61"]
        let inboxScrollingTitle = app.staticTexts["Scroll through your Inbox more smoothly"]
        let inboxScrollingDetail = app.staticTexts[
            "Scrolling the inbox list does less work, so it should feel smoother."
        ]
        revealHistoryElement(build61Header, in: app)
        XCTAssertTrue(build61Header.isHittable,
                      "Settings history keeps the earlier numbered release available after scrolling.")
        revealHistoryElement(inboxScrollingTitle, in: app)
        XCTAssertTrue(inboxScrollingTitle.isHittable, app.debugDescription)
        revealHistoryElement(inboxScrollingDetail, in: app)
        XCTAssertTrue(inboxScrollingDetail.isHittable, app.debugDescription)
        let releaseNoteFormatTitle = app.staticTexts["See clearer release notes"]
        revealHistoryElement(releaseNoteFormatTitle, in: app)
        XCTAssertTrue(releaseNoteFormatTitle.isHittable, app.debugDescription)
        let releaseNoteFormatDetail = app.staticTexts[
            "Each update now has an icon, a short title and a clear description."
        ]
        revealHistoryElement(releaseNoteFormatDetail, in: app)
        XCTAssertTrue(releaseNoteFormatDetail.isHittable, app.debugDescription)
        attachScreenshot("release-notes-settings-history", from: app)

        let build59Header = app.staticTexts["Version 0.1.0 · Build 59"]
        revealHistoryElement(build59Header, in: app)
        XCTAssertTrue(build59Header.isHittable,
                      "Settings history keeps earlier numbered notes after the new release.")
        let settingsTitle = app.staticTexts["Settings in the toolbar"]
        revealHistoryElement(settingsTitle, in: app)
        XCTAssertTrue(settingsTitle.isHittable,
                      "Settings history retains the confirmed Build 59 entry.")
        let datedHistoryHeader = app.staticTexts["Version 0.1.0 · Earlier on October 25, 2026"]
        revealHistoryElement(datedHistoryHeader, in: app)
        XCTAssertTrue(datedHistoryHeader.isHittable,
                      "Settings history identifies the dated entry without a build number.")
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
        for _ in 0..<40 where !element.isHittable {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.56))
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
