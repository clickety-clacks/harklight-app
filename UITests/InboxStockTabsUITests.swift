import XCTest

@MainActor
final class InboxStockTabsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testNativeHeaderMinimizesOnDownScrollAndRestoresOnUpScroll() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        let brand = app.descendants(matching: .any)["inbox-brand"]
        let settings = app.buttons["inbox-settings"]
        let firstRow = app.descendants(matching: .any)["request-row-unknown-01"]
        XCTAssertTrue(brand.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(brand.isHittable, "The native title is visible at the list top.")
        attachScreenshot("Native header at top", from: app)

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        list.swipeUp()
        let hidden = expectation(for: NSPredicate(format: "isHittable == false"),
                                 evaluatedWith: brand)
        wait(for: [hidden], timeout: 5)
        XCTAssertFalse(settings.isHittable, "Settings minimizes with the native header.")
        attachScreenshot("Native header scrolled", from: app)

        let upwardStart = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        upwardStart.press(forDuration: 0.05,
                          thenDragTo: upwardStart.withOffset(CGVector(dx: 0, dy: 90)),
                          withVelocity: .slow, thenHoldForDuration: 0.25)
        let restoredOnUpScroll = expectation(for: NSPredicate(format: "isHittable == true"),
                                            evaluatedWith: brand)
        wait(for: [restoredOnUpScroll], timeout: 5)
        XCTAssertTrue(settings.isHittable, "The native header restores when scrolling up.")
        XCTAssertFalse(firstRow.isHittable,
                       "The header restores while the list remains below its top edge.")
        attachScreenshot("Native header restored while scrolling up", from: app)

        for _ in 0..<12 {
            if firstRow.isHittable && firstRow.frame.minY >= settings.frame.maxY { break }
            list.swipeDown()
        }
        XCTAssertGreaterThanOrEqual(firstRow.frame.minY, settings.frame.maxY,
                                    "The list returns to its top row.")
        let restored = expectation(for: NSPredicate(format: "isHittable == true"),
                                   evaluatedWith: brand)
        wait(for: [restored], timeout: 5)
        XCTAssertTrue(settings.isHittable, "Settings returns with the native title.")
        attachScreenshot("Native header restored at top", from: app)
    }

    /// Something the person just sent shows in the New area at the top of
    /// Inbox with a spinner, and its row in the normal list shows the spinner
    /// too. A definitive failure shows as not sent instead.
    func testSentItemsShowASpinnerInTheNewAreaAndTheNormalList() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-test-submission-progress"]
        app.launch()

        let awaitingArea = app.descendants(matching: .any)["awaiting-reply-area-request-row-sample-approval-0"]
        XCTAssertTrue(awaitingArea.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(awaitingArea.label.contains("Waiting for a reply"), awaitingArea.label)

        let notSentArea = app.descendants(matching: .any)["awaiting-reply-area-request-row-sample-textChoice-0"]
        XCTAssertTrue(notSentArea.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(notSentArea.label.contains("Not sent"), notSentArea.label)
        XCTAssertLessThan(awaitingArea.frame.minY, notSentArea.frame.minY,
                          "The more recently sent item is first in the New area.")

        let normalRow = app.descendants(matching: .any)["request-row-sample-approval-0"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<10 where !(normalRow.exists && normalRow.isHittable) { list.swipeUp() }
        XCTAssertTrue(normalRow.exists && normalRow.isHittable, app.debugDescription)
        XCTAssertTrue(normalRow.label.contains("Waiting for a reply"),
                      "The same message keeps its normal-list row, with the spinner. \(normalRow.label)")
    }

    func testSearchTabSearchesTheListItWasOpenedFrom() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        let inboxTab = workspaceTab("Inbox", in: app)
        let repliedTab = workspaceTab("Replied", in: app)
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(repliedTab.exists, app.debugDescription)
        XCTAssertTrue(inboxTab.isSelected, app.debugDescription)
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        // Revision 7: search is its own tab, and no field floats above the tab bar.
        XCTAssertTrue(app.tabBars.buttons["Search"].exists, app.debugDescription)
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "No search field shows until the search tab is tapped.")
        assertListHeader(in: app)
        attachScreenshot("Inbox with the search tab", from: app)

        // One tap on the search tab focuses the field above the keyboard.
        app.tabBars.buttons["Search"].tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        searchField.typeText("Archive\n")
        let approval = app.descendants(matching: .any)["sample-approval-0"]
        XCTAssertTrue(approval.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot("Inbox results for Archive", from: app)

        approval.tap()
        let searchPosition = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '[0-9]+ of 3'")).firstMatch
        XCTAssertTrue(searchPosition.waitForExistence(timeout: 5), app.debugDescription)
        let keepHere = app.buttons.containing(.staticText, identifier: "Keep here").firstMatch
        XCTAssertTrue(keepHere.waitForExistence(timeout: 5), app.debugDescription)
        keepHere.tap()
        let finish = app.descendants(matching: .any)["sample-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), app.debugDescription)
        finish.tap()

        let back = workspaceBackButton(in: app)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertFalse(approval.waitForExistence(timeout: 2),
                       "An answered request leaves the Inbox search results.")

        // Leaving search returns to the tab it was opened from.
        leaveWorkspaceSearch(in: app)
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(inboxTab.isSelected, app.debugDescription)

        repliedTab.tap()
        XCTAssertTrue(repliedTab.isSelected, app.debugDescription)
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        searchField.typeText("Archive\n")
        XCTAssertTrue(approval.waitForExistence(timeout: 5),
                      "Searching from Replied finds the answered request there.")
        attachScreenshot("Replied results for Archive", from: app)
        leaveWorkspaceSearch(in: app)
        XCTAssertTrue(repliedTab.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(repliedTab.isSelected, app.debugDescription)
    }

    func testInboxAndRepliedPullToRefreshRunAndKeepFailureVisible() {
        for title in ["Inbox", "Replied"] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-attention-fixture", "--harklight-test-list-refresh"]
            if title == "Replied" { app.launchArguments.append("--harklight-samples") }
            app.launch()

            if title == "Replied" {
                let search = workspaceSearchField(in: app)
                XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
                search.tap()
                search.typeText("Archive\n")
                let sample = app.descendants(matching: .any)["sample-approval-0"]
                XCTAssertTrue(sample.waitForExistence(timeout: 5), app.debugDescription)
                sample.tap()
                let keepHere = app.buttons.containing(.staticText, identifier: "Keep here").firstMatch
                XCTAssertTrue(keepHere.waitForExistence(timeout: 5), app.debugDescription)
                keepHere.tap()
                let finish = app.descendants(matching: .any)["sample-finish"]
                XCTAssertTrue(finish.waitForExistence(timeout: 5), app.debugDescription)
                finish.tap()
                XCTAssertTrue(app.staticTexts["Answered locally · nothing sent"].waitForExistence(timeout: 5),
                              app.debugDescription)
                let back = workspaceBackButton(in: app)
                XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
                back.tap()
                leaveWorkspaceSearch(in: app)
            }

            let tab = workspaceTab(title, in: app)
            XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
            if title == "Replied" { tab.tap() }

            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
            let rowID = title == "Inbox" ? "request-row-unknown-01" : "sample-approval-0"
            let firstRow = app.descendants(matching: .any)[rowID]
            XCTAssertTrue(firstRow.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(firstRow.isHittable, app.debugDescription)
            let refreshStart = firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            refreshStart.press(forDuration: 0.05,
                               thenDragTo: refreshStart.withOffset(CGVector(dx: 0, dy: 310)),
                               withVelocity: .slow, thenHoldForDuration: 0.3)

            let warningButton = app.buttons["inbox-warning-button"]
            XCTAssertTrue(warningButton.waitForExistence(timeout: 8), app.debugDescription)
            warningButton.tap()
            let warning = app.staticTexts["inbox-warning-message"]
            XCTAssertTrue(warning.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(warning.label, "The approved server could not be reached.")
            app.terminate()
        }
    }

    func testNativeSearchFieldStaysInMasterBesideDetail() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()
        guard app.windows.firstMatch.frame.width >= 700 else {
            throw XCTSkip("A regular-width layout is required to show list and detail together.")
        }

        let row = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.buttons["request-heading"].waitForExistence(timeout: 5),
                      "The detail is visible beside the master list.")

        let list = app.collectionViews.firstMatch
        let field = app.searchFields.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(list.isHittable, "The master list remains usable beside the detail.")
        XCTAssertGreaterThan(field.frame.width, 180,
                             "Search is a full native field while the master list is visible.")
        XCTAssertGreaterThanOrEqual(field.frame.minX, list.frame.minX - 8)
        XCTAssertLessThanOrEqual(field.frame.maxX, list.frame.maxX + 8)
        attachScreenshot("Native Search in master beside detail", from: app)
    }

    func testNotificationRouteClearsListSearchAndOpensTheTargetRequest() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-test-notification-navigation"]
        app.launch()

        let inboxTab = workspaceTab("Inbox", in: app)
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 10), app.debugDescription)

        let searchField = workspaceSearchField(in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        searchField.tap()
        searchField.typeText("no-matching-request\n")
        let routeNotification = app.buttons["harklight-test-notification"]
        XCTAssertTrue(routeNotification.waitForExistence(timeout: 5), app.debugDescription)
        routeNotification.tap()

        let targetHeading = app.buttons["request-heading"]
        XCTAssertTrue(targetHeading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(targetHeading.isHittable, app.debugDescription)
        XCTAssertTrue(targetHeading.label.contains("Unfamiliar interface"),
                      "The notification target is presented in the visible detail: \(targetHeading.label)")

        let back = workspaceBackButton(in: app)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(inboxTab.isSelected,
                      "Returning from a notification opened in Search returns to its Inbox tab.")
        XCTAssertTrue(workspaceSearchField(in: app).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["request-row-facilities-01"]
            .waitForExistence(timeout: 5),
                      "Returning to Inbox shows its cleared list query.")
        XCTAssertFalse(app.scrollViews["message-card-scroll"].exists,
                       "The previous notification detail is not left selected.")
    }

    private func selectMessageTab(_ title: String, in app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let closeSearch = app.buttons["Close"]
        if closeSearch.exists { closeSearch.tap() }

        let destination = workspaceTab(title, in: app)
        XCTAssertTrue(destination.waitForExistence(timeout: 5), app.debugDescription,
                      file: file, line: line)
        if !destination.isSelected { destination.tap() }
    }

    private func assertListHeader(in app: XCUIApplication, file: StaticString = #filePath,
                                  line: UInt = #line) {
        let brand = app.descendants(matching: .any)["inbox-brand"]
        XCTAssertTrue(brand.waitForExistence(timeout: 5), app.debugDescription,
                      file: file, line: line)
        let settings = app.buttons["inbox-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription,
                      file: file, line: line)
        XCTAssertTrue(brand.isHittable,
                      "The native title is reachable when Search is inactive.",
                      file: file, line: line)
        XCTAssertTrue(settings.isHittable,
                      "Settings is reachable when Search is inactive.",
                      file: file, line: line)
        XCTAssertEqual(brand.frame.midY, settings.frame.midY, accuracy: 5,
                       "Brand and Settings share the native header line when Search is inactive.",
                       file: file, line: line)
    }

    private func attachScreenshot(_ name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
