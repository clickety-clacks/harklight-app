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

    func testPortraitSelectionAdaptsListVisibilityToAvailableWidth() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-ui-diagnostics"]
        app.launch()

        let row = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        let presentation = splitPresentation(in: app)
        XCTAssertTrue(presentation.waitForExistence(timeout: 5), app.debugDescription)
        let before = presentation.value as? String ?? ""
        XCTAssertTrue(["presentation=compact", "presentation=overlay", "presentation=sideBySide"].contains(before),
                      "Establish the actual list presentation before selection: \(before)")
        attachScreenshot("portrait-master-before-selection")
        row.tap()

        let card = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        let heading = card.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.label.contains("Facilities desk"), heading.debugDescription)
        let diagnostic = app.descendants(matching: .any)["inbox-ui-diagnostics"].firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5), app.debugDescription)
        if before == "presentation=sideBySide" {
            XCTAssertTrue(row.isHittable,
                          "A side-by-side split view keeps the Inbox row beside its detail. \(diagnostic.label)")
            assertSideBySide(listRow: row, detailHeading: heading, in: app)
            attachScreenshot("portrait-side-by-side-detail-after-selection")
        } else {
            XCTAssertFalse(row.isHittable,
                           "Selection dismisses an overlaid or compact list. \(diagnostic.label)")
            attachScreenshot("portrait-detail-after-selection")
            let back = workspaceBackButton(in: app)
            XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
            back.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "The system Back control must reopen the message list.")
            attachScreenshot("portrait-master-after-native-back")
        }
        attachHierarchy("portrait-selection-hierarchy", app: app)
    }

    func testSelectingAnotherMessageFromPortraitOverlayUpdatesDetailAndDismissesIt() throws {
        try assertReopenedListDismissesAfterSelection(presentation: "overlay")
    }

    func testSelectingAnotherMessageFromCompactListUpdatesDetailAndDismissesIt() throws {
        try assertReopenedListDismissesAfterSelection(presentation: "compact")
    }

    private func assertReopenedListDismissesAfterSelection(presentation expected: String) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-ui-diagnostics"]
        if expected == "overlay" { app.launchArguments.append("--harklight-test-overlay") }
        app.launch()
        let initialSidebar = app.buttons["Show Sidebar"]
        if initialSidebar.waitForExistence(timeout: 3) && initialSidebar.isHittable {
            initialSidebar.tap()
        }

        let facilities = app.descendants(matching: .any)["request-row-facilities-01"]
        let review = app.descendants(matching: .any)["request-row-review-01"]
        XCTAssertTrue(facilities.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        let probe = splitPresentation(in: app)
        XCTAssertTrue(probe.waitForExistence(timeout: 5), app.debugDescription)
        let initial = probe.value as? String ?? ""
        if expected == "overlay", initial == "presentation=compact" {
            throw XCTSkip("A collapsed phone cannot present a regular-width overlay; the compact test covers it.")
        }
        if expected == "compact", initial != "presentation=compact" {
            throw XCTSkip("This case requires a collapsed phone; the iPad cases cover expanded presentations.")
        }
        XCTAssertEqual(initial, "presentation=\(expected)",
                       "Establish the native presentation before the first selection too.")
        facilities.tap()

        let card = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(card.staticTexts["Facilities desk"].waitForExistence(timeout: 5),
                      app.debugDescription)
        let sidebar = app.buttons["Show Sidebar"]
        let back = workspaceBackButton(in: app)
        if !review.isHittable {
            if sidebar.exists && sidebar.isHittable {
                sidebar.tap()
            } else {
                XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
                back.tap()
            }
        }
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(review.isHittable, app.debugDescription)
        let presentation = splitPresentation(in: app)
        XCTAssertTrue(presentation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(presentation.value as? String, "presentation=\(expected)",
                       "This case must exercise the real \(expected) presentation before selection.")
        attachScreenshot("\(expected)-before-second-selection")
        attachHierarchy("\(expected)-before-second-selection-hierarchy", app: app)

        review.tap()

        XCTAssertTrue(card.staticTexts["Studio review"].waitForExistence(timeout: 5),
                      "The second row must replace the selected detail. \(app.debugDescription)")
        XCTAssertFalse(review.isHittable,
                       "Selecting from the reopened portrait list must dismiss it. \(app.debugDescription)")
        attachScreenshot("portrait-detail-after-second-selection")
        attachHierarchy("portrait-second-selection-hierarchy", app: app)
    }

    func testLandscapeSelectionKeepsListAndDetailVisibleAcrossMessages() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("An iPhone stays compact in landscape; the iPad layout job runs this case.")
        }
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
        let presentation = splitPresentation(in: app)
        XCTAssertTrue(presentation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(presentation.value as? String, "presentation=sideBySide",
                       "Establish adjacent columns before selection, not just regular width.")
        attachScreenshot("landscape-list-and-empty-detail-before-selection")
        facilities.tap()

        let card = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        let heading = card.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.label.contains("Facilities desk"), heading.debugDescription)
        XCTAssertTrue(facilities.isHittable,
                      "The Facilities row must remain visible beside its detail. \(app.debugDescription)")
        assertSideBySide(listRow: facilities, detailHeading: heading, in: app)
        attachScreenshot("landscape-facilities-detail-with-list")

        review.tap()

        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.label.contains("Studio review"),
                      "Selecting the second row must replace the detail with Studio review. \(heading.debugDescription)")
        XCTAssertTrue(review.isHittable,
                      "The Studio review row must remain visible beside its detail. \(app.debugDescription)")
        assertSideBySide(listRow: review, detailHeading: heading, in: app)
        attachScreenshot("landscape-studio-review-detail-with-list")
        attachHierarchy("landscape-second-selection-hierarchy", app: app)
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
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples", "--harklight-ui-diagnostics"]
        app.launch()

        let row = app.descendants(matching: .any)["sample-information-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()

        let check = app.buttons["request-finish-seen"]
        XCTAssertTrue(check.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(check.isEnabled, app.debugDescription)
        let card = app.scrollViews["message-card-scroll"]
        let listVisibleAlongsideDetail = listVisibleBesideDetail(in: app)
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
        let navigation = app.descendants(matching: .any)["message-card-navigation"].firstMatch
        XCTAssertTrue(navigation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(navigation.label, "previous=true next=true")
        attachScreenshot("native-toolbar-check-before-seen")
        check.tap()
        if listVisibleAlongsideDetail {
            XCTAssertTrue(card.waitForExistence(timeout: 5),
                          "When the list and detail are both visible, confirmed Seen keeps the detail selected.")
            let confirmation = app.descendants(matching: .any)["request-seen-confirmation"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(confirmation.value as? String, "Completed")
            XCTAssertTrue(check.exists, "The toolbar keeps the completed Seen status visible.")
            XCTAssertEqual(check.label, "Seen")
            XCTAssertFalse(check.isEnabled, "Confirmed Seen cannot be submitted again.")
            XCTAssertEqual(counter.label, initialPosition,
                           "Moving a Seen message to Replied must not reset its card position.")
            attachScreenshot("native-toolbar-check-after-seen")

            XCTAssertEqual(navigation.label, "previous=true next=true",
                           "Both accessibility navigation actions remain available after the message moves to Replied.")
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

    func testFirstHopAfterSeenResumesCurrentInboxOrder() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This test needs Inbox and detail to remain visible after Seen.")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-ui-diagnostics", "--harklight-test-card-navigation"]
        app.launch()

        let row = app.descendants(matching: .any)["sample-information-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let diagnostic = app.descendants(matching: .any)["inbox-ui-diagnostics"].firstMatch
        let counter = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '[0-9]+ of [0-9]+'")
        ).firstMatch
        let previous = app.buttons["Previous message"]
        let next = app.buttons["Next message"]
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5))
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertTrue(previous.isHittable && next.isHittable, app.debugDescription)

        func selectedCard() throws -> Substring {
            try XCTUnwrap(diagnostic.label.split(separator: " ").first)
        }

        let middle = try selectedCard()
        let initial = counter.label
        let parts = initial.components(separatedBy: " of ").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 2, initial)
        let position = try XCTUnwrap(parts.first)
        let total = try XCTUnwrap(parts.last)
        XCTAssertGreaterThan(position, 1)
        XCTAssertLessThan(position, total)

        previous.tap()
        let leading = try selectedCard()
        XCTAssertNotEqual(leading, middle)
        next.tap()
        XCTAssertEqual(try selectedCard(), middle)
        next.tap()
        let trailing = try selectedCard()
        XCTAssertNotEqual(trailing, middle)
        previous.tap()
        XCTAssertEqual(try selectedCard(), middle)

        let seen = app.buttons["request-finish-seen"]
        XCTAssertTrue(seen.waitForExistence(timeout: 5))
        seen.tap()
        let confirmation = app.descendants(matching: .any)["request-seen-confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertEqual(try selectedCard(), middle)
        XCTAssertEqual(counter.label, initial)

        next.tap()
        XCTAssertEqual(try selectedCard(), trailing, "Next from the completed card opens its former successor.")
        XCTAssertEqual(counter.label, "\(position) of \(total - 1)",
                       "The successor uses the updated Inbox count and position.")
        previous.tap()
        XCTAssertEqual(try selectedCard(), leading, "Previous skips the completed card.")
        XCTAssertEqual(counter.label, "\(position - 1) of \(total - 1)")
    }

    private func splitPresentation(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["inbox-split-presentation"].firstMatch
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
