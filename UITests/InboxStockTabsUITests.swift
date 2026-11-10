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

    func testNativeListSearchKeepsInboxAndRepliedResults() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        let inboxTab = workspaceTab("Inbox", in: app)
        let repliedTab = workspaceTab("Replied", in: app)
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(repliedTab.exists, app.debugDescription)
        XCTAssertTrue(inboxTab.isSelected, app.debugDescription)
        XCTAssertFalse(app.tabBars.buttons["Search"].exists,
                       "Search belongs to the message list, not a separate tab.")
        assertListHeader(in: app)
        attachScreenshot("Inbox with native list search", from: app)

        let searchField = workspaceSearchField(in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        searchField.tap()
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
        repliedTab.tap()
        XCTAssertTrue(repliedTab.isSelected, app.debugDescription)
        XCTAssertTrue(approval.waitForExistence(timeout: 5),
                      "The same query finds the answered request in Replied.")
        XCTAssertTrue(approval.isHittable, app.debugDescription)
        approval.tap()
        let localReply = app.staticTexts["Answered locally · nothing sent"]
        XCTAssertTrue(localReply.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(localReply.isHittable, app.debugDescription)
        attachScreenshot("Replied results for Archive", from: app)
    }

    func testFilteredRowsAndMessageTextStayReachableAtStandardAndLargeType() {
        for usesLargeType in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                                   "--harklight-ui-diagnostics"]
            if usesLargeType {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                       "UICTContentSizeCategoryAccessibilityXXXL"]
            } else {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM"]
            }
            app.launch()

            let expectedSizeClass = UIDevice.current.userInterfaceIdiom == .pad
                ? "regular" : "compact"
            let diagnostics = app.descendants(matching: .any)["inbox-ui-diagnostics"]
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(diagnostics.label.contains("sizeClass=\(expectedSizeClass)"),
                          "The test must exercise the expected layout. \(diagnostics.label)")

            let search = workspaceSearchField(in: app)
            XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
            search.tap()
            search.typeText("Archive")
            workspaceTab("Replied", in: app).tap()
            let result = app.descendants(matching: .any)["sample-approval-2"]
            XCTAssertTrue(result.waitForExistence(timeout: 5), app.debugDescription)

            let list = app.collectionViews.firstMatch
            for _ in 0..<8 where !result.isHittable { list.swipeUp() }
            XCTAssertTrue(result.isHittable,
                          "A filtered result must remain reachable with the search field active. \(app.debugDescription)")

            // The Replied tab keeps the filtered result and native bottom controls visible.
            let bottomBar = app.tabBars.firstMatch
            XCTAssertTrue(bottomBar.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(result.waitForExistence(timeout: 5), app.debugDescription)
            for _ in 0..<8 where !result.isHittable { list.swipeUp() }
            XCTAssertTrue(result.isHittable, app.debugDescription)
            XCTAssertLessThanOrEqual(result.frame.maxY, bottomBar.frame.minY + 2,
                                     "The bottom controls must not cover a filtered row. \(app.debugDescription)")
            attachScreenshot("filtered-result-\(expectedSizeClass)-\(usesLargeType ? "large" : "standard")", from: app)

            result.tap()
            let messageText = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Choose what happens to the earlier sketches")
            ).firstMatch
            XCTAssertTrue(messageText.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(messageText.isHittable,
                          "The selected message text remains visible and reachable. \(app.debugDescription)")
            attachScreenshot("filtered-message-text-\(expectedSizeClass)-\(usesLargeType ? "large" : "standard")", from: app)
            app.terminate()
        }
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
                let clearSearch = workspaceSearchField(in: app).buttons["Clear text"]
                if clearSearch.exists && clearSearch.isHittable { clearSearch.tap() }
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

    func testColdSyntheticNotificationShowsLoadingThenExactMessageDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-test-notification-navigation",
                               "--harklight-test-notification-pending",
                               "--harklight-test-notification-auto"]
        app.launch()

        let loading = app.descendants(matching: .any)["notification-message-loading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 10), app.debugDescription)
        attachScreenshot("synthetic-notification-cold-loading", from: app)
        app.buttons["notification-test-resolve"].tap()

        let heading = app.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.label.contains("Unfamiliar interface"),
                      "The completed synthetic route opens its exact fixture target. \(heading.label)")
        attachScreenshot("synthetic-notification-cold-target", from: app)
    }

    func testWarmSyntheticNotificationShowsLoadingThenExactMessageChat() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-test-notification-navigation",
                               "--harklight-test-notification-pending",
                               "--harklight-test-notification-chat"]
        app.launch()

        let openNotification = app.buttons["harklight-test-notification"]
        XCTAssertTrue(openNotification.waitForExistence(timeout: 10), app.debugDescription)
        openNotification.tap()
        let loading = app.descendants(matching: .any)["notification-message-loading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot("synthetic-notification-warm-loading", from: app)
        app.buttons["notification-test-resolve"].tap()

        let chatSurface = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(chatSurface.waitForExistence(timeout: 5), app.debugDescription)
        let targetHeading = app.buttons["request-heading"]
        XCTAssertTrue(targetHeading.exists,
                      "The completed synthetic chat route remains on its exact fixture detail. \(app.debugDescription)")
        XCTAssertTrue(targetHeading.label.contains("Unfamiliar interface"), targetHeading.label)
        attachScreenshot("synthetic-notification-warm-target-chat", from: app)
    }

    func testSyntheticNotificationFailureOffersReturnToInbox() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-test-notification-navigation",
                               "--harklight-test-notification-pending"]
        app.launch()

        let openNotification = app.buttons["harklight-test-notification"]
        XCTAssertTrue(openNotification.waitForExistence(timeout: 10), app.debugDescription)
        openNotification.tap()
        XCTAssertTrue(app.descendants(matching: .any)["notification-message-loading"]
            .waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["notification-test-unavailable"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["notification-message-unavailable"]
            .waitForExistence(timeout: 5), app.debugDescription)
        let returnButton = app.buttons["notification-return-to-inbox"]
        XCTAssertTrue(returnButton.isHittable, app.debugDescription)
        attachScreenshot("synthetic-notification-unavailable", from: app)
        returnButton.tap()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["request-row-facilities-01"]
            .waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["notification-message-loading"].exists,
                       "Returning dismisses the unavailable route without reopening it.")
        attachScreenshot("synthetic-notification-returned-to-inbox", from: app)
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
