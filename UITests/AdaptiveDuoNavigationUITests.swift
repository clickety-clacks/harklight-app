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
        XCTAssertFalse(row.isHittable,
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

    func testSeenKeepsCardNavigationAfterMovingOutOfInbox() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        let row = app.descendants(matching: .any)["sample-information-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()

        let check = app.buttons["request-finish-seen"]
        XCTAssertTrue(check.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(check.isEnabled, app.debugDescription)
        let card = app.scrollViews["message-card-scroll"]
        let counter = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '[0-9]+ of [0-9]+'")
        ).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), app.debugDescription)
        let initialPosition = counter.label
        let parts = initialPosition.components(separatedBy: " of ")
        let index = Int(parts.first ?? "") ?? 0
        let total = Int(parts.last ?? "") ?? 0
        XCTAssertGreaterThan(index, 0, initialPosition)
        XCTAssertLessThan(index, total, "The fixture needs a following message.")
        attachScreenshot("native-toolbar-check-before-seen")
        check.tap()
        XCTAssertTrue(app.staticTexts["Seen selected locally · nothing sent"]
            .waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(check.isEnabled, "The Seen action must not repeat after completion.")
        XCTAssertEqual(counter.label, initialPosition,
                       "Moving a Seen message to Replied must not reset its card position.")
        attachScreenshot("native-toolbar-check-after-seen")

        let lower = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        lower.press(forDuration: 0.1, thenDragTo: upper, withVelocity: .slow,
                    thenHoldForDuration: 4)
        let nextPosition = "\(index + 1) of \(total)"
        XCTAssertTrue(app.staticTexts[nextPosition].waitForExistence(timeout: 5),
                      "Next must remain available after the current message moves to Replied. \(app.debugDescription)")
        attachScreenshot("native-toolbar-next-after-seen")
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
