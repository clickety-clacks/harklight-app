import XCTest

@MainActor
final class AdaptiveDuoNavigationUITests: XCTestCase {
    func testFreshLaunchWithoutSelectionShowsInboxAndOpensSelectedMessage() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-ui-diagnostics"]
        app.launch()

        let diagnostic = app.descendants(matching: .any)["inbox-ui-diagnostics"].firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(diagnostic.label.contains("selection=nil"), diagnostic.label)
        let row = app.descendants(matching: .any)["request-row-facilities-01"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.isHittable,
                      "A fresh launch must expose Inbox without first pressing Back or Show Sidebar.")
        attachScreenshot("fresh-launch-without-selection")
        attachHierarchy("fresh-launch-without-selection-hierarchy", app: app)
        row.tap()

        let card = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(card.staticTexts["Facilities desk"].waitForExistence(timeout: 5),
                      "Selecting the inbox row must open that message.")
        attachScreenshot("fresh-launch-selected-detail")
        attachHierarchy("fresh-launch-selected-detail-hierarchy", app: app)
    }

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

    func testSelectingAnotherMessageFromPortraitOverlayUpdatesDetailAndDismissesIt() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-ui-diagnostics"]
        app.launch()

        let facilities = app.descendants(matching: .any)["request-row-facilities-01"]
        let review = app.descendants(matching: .any)["request-row-review-01"]
        XCTAssertTrue(facilities.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        facilities.tap()

        let card = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(card.staticTexts["Facilities desk"].waitForExistence(timeout: 5),
                      app.debugDescription)
        let back = workspaceBackButton(in: app)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(review.isHittable, app.debugDescription)
        attachScreenshot("portrait-overlay-before-second-selection")

        review.tap()

        XCTAssertTrue(card.staticTexts["Studio review"].waitForExistence(timeout: 5),
                      "The second row must replace the selected detail. \(app.debugDescription)")
        XCTAssertFalse(review.isHittable,
                       "Selecting from the reopened portrait list must dismiss it. \(app.debugDescription)")
        attachScreenshot("portrait-detail-after-second-selection")
        attachHierarchy("portrait-second-selection-hierarchy", app: app)
    }

    func testLandscapeSelectionKeepsListAndDetailVisibleAcrossMessages() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-ui-diagnostics"]
        app.launch()

        let diagnostic = app.descendants(matching: .any)["inbox-ui-diagnostics"].firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 10),
                      "The side-by-side test requires UI layout diagnostics. \(app.debugDescription)")
        XCTAssertTrue(diagnostic.label.contains("sizeClass=regular"),
                      "The test requires a regular-width side-by-side layout before selecting. \(diagnostic.label)")
        XCTAssertTrue(diagnostic.label.contains("landscape=true"),
                      "The test requires landscape before selecting. \(diagnostic.label)")

        let facilities = app.descendants(matching: .any)["request-row-facilities-01"]
        let review = app.descendants(matching: .any)["request-row-review-01"]
        XCTAssertTrue(facilities.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot("landscape-list-and-empty-detail-before-selection")
        facilities.tap()

        let card = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        let heading = card.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.label.contains("Facilities desk"), heading.debugDescription)
        XCTAssertTrue(app.searchFields.firstMatch.isHittable,
                      "The inbox list must remain beside the selected Facilities detail. \(app.debugDescription)")
        XCTAssertTrue(facilities.isHittable,
                      "The Facilities row must remain visible beside its detail. \(app.debugDescription)")
        assertSideBySide(listRow: facilities, detailHeading: heading, in: app)
        attachScreenshot("landscape-facilities-detail-with-list")

        review.tap()

        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.label.contains("Studio review"),
                      "Selecting the second row must replace the detail with Studio review. \(heading.debugDescription)")
        XCTAssertTrue(app.searchFields.firstMatch.isHittable,
                      "The inbox list must remain beside the second selected detail. \(app.debugDescription)")
        XCTAssertTrue(review.isHittable,
                      "The Studio review row must remain visible beside its detail. \(app.debugDescription)")
        assertSideBySide(listRow: review, detailHeading: heading, in: app)
        attachScreenshot("landscape-studio-review-detail-with-list")
        attachHierarchy("landscape-second-selection-hierarchy", app: app)
    }

    func testPortraitSelectionKeepsListAndDetailVisible() {
        // On a large iPad, NavigationSplitView keeps both columns visible in
        // portrait. Compare the actual row and detail heading; the hosting
        // scroll and collection views report pane-local accessibility frames.
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-ui-diagnostics"]
        app.launch()
        let facilities = app.descendants(matching: .any)["request-row-facilities-01"].firstMatch
        XCTAssertTrue(facilities.waitForExistence(timeout: 10), app.debugDescription)
        facilities.tap()
        let card = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        let heading = card.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.label.contains("Facilities desk"), heading.debugDescription)

        XCUIDevice.shared.orientation = .portrait
        let diagnostic = app.descendants(matching: .any)["inbox-ui-diagnostics"].firstMatch
        let portrait = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'landscape=false'"), object: diagnostic)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed, app.debugDescription)

        let review = app.descendants(matching: .any)["request-row-review-01"].firstMatch
        if !review.isHittable {
            let sidebar = app.buttons["Show Sidebar"]
            let back = workspaceBackButton(in: app)
            if sidebar.exists && sidebar.isHittable {
                sidebar.tap()
            } else if back.exists && back.isHittable {
                back.tap()
            }
        }

        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(review.isHittable,
                      "The Inbox row remains available beside the detail. \(app.debugDescription)")
        XCTAssertTrue(heading.label.contains("Facilities desk"), heading.debugDescription)
        assertSideBySide(listRow: facilities, detailHeading: heading, in: app)
        attachScreenshot("portrait-list-and-detail-before-selection")

        review.tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.label.contains("Studio review"),
                      "Selecting the second row updates the detail. \(heading.debugDescription)")
        XCTAssertTrue(review.isSelected, "The selected Inbox row remains visible in the sidebar.")
        XCTAssertTrue(review.isHittable, "The selected row remains available beside the detail.")
        assertSideBySide(listRow: review, detailHeading: heading, in: app)
        attachScreenshot("portrait-list-and-detail-after-selection")
        attachHierarchy("portrait-selection-hierarchy", app: app)
    }

    private func assertSideBySide(listRow: XCUIElement, detailHeading: XCUIElement,
                                 in app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let listFrame = listRow.frame.intersection(app.frame)
        let detailFrame = detailHeading.frame.intersection(app.frame)
        XCTAssertGreaterThan(listFrame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(detailFrame.width, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(listFrame.maxX, detailFrame.minX + 1,
                                "The visible Inbox row and selected detail heading must not overlap. \(app.debugDescription)",
                                file: file, line: line)
    }

    func testSeenReturnsToListOnlyWhenNoListPaneIsVisible() {
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
        let listVisibleAlongsideDetail = app.searchFields.firstMatch.isHittable
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
        if listVisibleAlongsideDetail {
            XCTAssertTrue(card.waitForExistence(timeout: 5),
                          "When the list and detail are both visible, confirmed Seen keeps the detail selected.")
            let confirmation = app.descendants(matching: .any)["request-seen-confirmation"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(confirmation.value as? String, "Completed")
            XCTAssertFalse(check.exists, "The toolbar action disappears after Seen is confirmed.")
            XCTAssertEqual(counter.label, initialPosition,
                           "Moving a Seen message to Replied must not reset its card position.")
            attachScreenshot("native-toolbar-check-after-seen")

            let lower = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let upper = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            lower.press(forDuration: 0.1, thenDragTo: upper, withVelocity: .slow,
                        thenHoldForDuration: 4)
            let nextPosition = "\(index + 1) of \(total)"
            XCTAssertTrue(app.staticTexts[nextPosition].waitForExistence(timeout: 5),
                          "Next remains available after the current message moves to Replied. \(app.debugDescription)")
            attachScreenshot("native-toolbar-next-after-seen")
        } else {
            XCTAssertTrue(card.waitForNonExistence(timeout: 5),
                          "A single-pane view returns to Inbox after Seen is confirmed.")
            let inbox = workspaceTab("Inbox", in: app)
            XCTAssertTrue(inbox.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(inbox.isSelected, "Returning keeps the Inbox tab selected.")
            XCTAssertFalse(row.waitForExistence(timeout: 2),
                           "The Seen row leaves Inbox as it returns to the list.")
            workspaceTab("Replied", in: app).tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "The confirmed Seen row appears in Replied.")
        }
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func attachHierarchy(_ name: String, app: XCUIApplication) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
