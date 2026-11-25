import XCTest

@MainActor
final class InboxStockTabsUITests: XCTestCase {
    func testAlertsSettingsOnlyShowsWhenTheServerAdvertisesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-relay-failed-choice"]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["inbox-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["settings-alerts"].exists)
        openAlertsFeature(in: app)
        XCTAssertFalse(app.staticTexts["feature-notifications-quiet-alerts"].exists)
    }

    func testAlertsSettingsOffersBothChoicesInLightAndDark() {
        let originalAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = originalAppearance }
        for appearance in ["light", "dark"] {
            XCUIDevice.shared.appearance = appearance == "dark" ? .dark : .light
            let app = XCUIApplication()
            app.launchArguments = ["--harklight-test-relay-failed-choice", "--harklight-test-alerts-settings"]
            app.launch()
            let settings = app.buttons["inbox-settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.tap()
            let row = app.descendants(matching: .any)["settings-alerts"].firstMatch
            if row.waitForExistence(timeout: 5) {
                XCTAssertTrue(app.staticTexts["Other messages arrive quietly. They still appear in your Inbox and on the badge."].exists)
                let capture = XCTAttachment(screenshot: app.screenshot())
                capture.name = "Alerts settings \(appearance)"
                capture.lifetime = .keepAlways
                add(capture)
                row.tap()
                XCTAssertTrue(app.buttons["Questions and urgent"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Everything"].exists)
                app.buttons["Questions and urgent"].tap()
                openAlertsFeature(in: app)
                let wording = app.staticTexts["feature-notifications-quiet-alerts"]
                for _ in 0..<6 where !wording.isHittable { app.swipeUp() }
                XCTAssertTrue(wording.isHittable)
            } else {
                XCTFail("Supported Settings must expose the Alerts picker.")
            }
            app.terminate()
        }
    }

    private func openAlertsFeature(in app: XCUIApplication) {
        app.buttons["settings-features"].tap()
        let feature = app.staticTexts["feature-accountAwareNotifications-title"]
        for _ in 0..<6 where !feature.isHittable { app.swipeUp() }
        XCTAssertTrue(feature.isHittable)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testOrdinaryLaunchAndRelaunchShowInboxWithoutOpeningTheLastMessage() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()
        let inbox = workspaceTab("Inbox", in: app)
        let row = app.descendants(matching: .any)["request-row-facilities-01"]
        let detail = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(inbox.isSelected)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.isHittable, "Compact launch must show the list column.")
        XCTAssertFalse(detail.exists, "No message was tapped on this launch.")
        row.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot("Explicitly opened detail before ordinary relaunch", from: app)

        app.terminate()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(inbox.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(inbox.isSelected)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.isHittable, app.debugDescription)
        XCTAssertFalse(detail.exists, "Ordinary relaunch must not restore the last detail.")
        attachScreenshot("Ordinary relaunch remains in the Inbox list", from: app)
    }

    func testSearchStartsUnselectedAndExplicitOpenAndBackChooseTheCorrectColumn() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(workspaceTab("Inbox", in: app).waitForExistence(timeout: 10), app.debugDescription)
        let field = workspaceSearchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText("Archive\n")
        let row = app.descendants(matching: .any)["sample-approval-0"]
        let detail = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.isHittable)
        XCTAssertFalse(detail.exists, "Search must not pick its first matching message.")
        row.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5), app.debugDescription)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad keeps the searched list beside the opened message.
            XCTAssertTrue(row.isHittable, "The searched list stays beside the opened message.")
            attachScreenshot("Search list beside explicitly opened detail", from: app)
            return
        }
        let back = workspaceBackButton(in: app)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.isHittable, "Back must restore the searchable list column.")
        XCTAssertFalse(detail.exists)
        attachScreenshot("Search list after leaving explicitly opened detail", from: app)
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

    func testSentItemsStayInTheNormalListWithoutANewSection() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-test-submission-progress"]
        app.launch()
        defer { app.terminate() }

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["new-message-area-header"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["new-message-area-more"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "normal-inbox-without-new-section"
        capture.lifetime = .keepAlways
        add(capture)
        for (id, status) in [("sample-approval-0", "Waiting for a reply"),
                             ("sample-textChoice-0", "Did not send")] {
            let row = app.descendants(matching: .any)[id].firstMatch
            for _ in 0..<12 where !(row.exists && row.isHittable) { list.swipeUp() }
            XCTAssertTrue(row.exists && row.isHittable, app.debugDescription)
            XCTAssertTrue(row.label.contains(status), row.label)
            XCTAssertFalse(app.descendants(matching: .any)["awaiting-reply-area-\(id)"].exists)
        }
    }

    func testSearchTabSearchesTheListItWasOpenedFrom() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("The Search tab is iPhone only; iPad searches from a field in the list.")
        }
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
                if UIDevice.current.userInterfaceIdiom == .phone {
                    // Close the system Search tab before selecting Replied.
                    let closeSearch = app.buttons["Close"]
                    closeSearch.tap()
                } else {
                    leaveWorkspaceSearch(in: app)
                }
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
            let warning = app.staticTexts["inbox-warning-message"].firstMatch
            XCTAssertFalse(warning.exists,
                           "\(title) must start without a warning so an existing status cannot satisfy the refresh check.\n\(app.debugDescription)")
            let refreshStart = firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            refreshStart.press(forDuration: 0.05,
                               thenDragTo: refreshStart.withOffset(CGVector(dx: 0, dy: 310)),
                               withVelocity: .slow, thenHoldForDuration: 0.3)

            XCTAssertTrue(warning.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertEqual(warning.label, "Waiting for the server. Your pending actions are saved.")
            app.terminate()
        }
    }

    /// On iPad search is a field at the top of the list rather than a tab, so
    /// it stays beside an open message and filters the list in place.
    func testIPadListSearchFieldFiltersBesideDetail() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The list search field is the iPad search; iPhone uses the Search tab.")
        }
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
        let fullTotal = positionTotal(in: app)
        XCTAssertNotNil(fullTotal, app.debugDescription)

        XCTAssertFalse(app.tabBars.buttons["Search"].exists,
                       "iPad has no Search tab.\n\(app.debugDescription)")
        let list = app.collectionViews.firstMatch
        let field = app.searchFields.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "The list has its own search field.\n\(app.debugDescription)")
        XCTAssertTrue(list.isHittable, "The master list remains usable beside the detail.")
        XCTAssertGreaterThanOrEqual(field.frame.minX, list.frame.minX - 8)
        XCTAssertLessThanOrEqual(field.frame.maxX, list.frame.maxX + 8)
        field.tap()
        field.typeText("Archive\n")
        let match = app.descendants(matching: .any)["sample-approval-0"]
        XCTAssertTrue(match.waitForExistence(timeout: 5),
                      "Typing filters the list in place.\n\(app.debugDescription)")
        match.tap()
        XCTAssertTrue(app.buttons["request-heading"].waitForExistence(timeout: 5), app.debugDescription)
        let filteredTotal = positionTotal(in: app)
        XCTAssertNotNil(filteredTotal, app.debugDescription)
        if let fullTotal, let filteredTotal {
            XCTAssertLessThan(filteredTotal, fullTotal,
                              "Detail position counts the search results, not the whole Inbox.")
        }
        attachScreenshot("iPad list search beside detail", from: app)
    }

    /// The total in the detail's "N of M" position pill.
    private func positionTotal(in app: XCUIApplication) -> Int? {
        let pill = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ of [0-9]+$")).firstMatch
        guard pill.waitForExistence(timeout: 5) else { return nil }
        return pill.label.split(separator: " ").last.flatMap { Int($0) }
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

        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad shows the list beside the routed message, with its query cleared.
            XCTAssertTrue(inboxTab.isSelected, app.debugDescription)
            XCTAssertTrue(app.descendants(matching: .any)["request-row-facilities-01"]
                .waitForExistence(timeout: 5), "The routed notification clears the list query.")
            return
        }
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
