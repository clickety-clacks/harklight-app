import XCTest

@MainActor
final class InboxStockTabsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testInboxHeaderMinimizesOnScrollAndRestoresOnScrollUp() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        let brand = app.descendants(matching: .any)["inbox-brand"]
        let settings = app.buttons["inbox-settings"]
        XCTAssertTrue(brand.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot("Inbox header at top", from: app)

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        let dragStart = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.80))
        let dragEnd = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        app.swipeUp()
        let hidden = expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: brand)
        wait(for: [hidden], timeout: 5)
        XCTAssertFalse(settings.isHittable, "The toolbar hides as the inbox scrolls down.")
        attachScreenshot("Inbox header minimized", from: app)

        app.swipeDown()
        let restored = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: brand)
        wait(for: [restored], timeout: 5)
        XCTAssertTrue(settings.isHittable, "The toolbar returns when scrolling up.")
        attachScreenshot("Inbox header restored", from: app)
    }

    func testStockTabsAndSearchKeepInboxAndRepliedResults() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        let inboxTab = workspaceTab("Inbox", in: app)
        let repliedTab = workspaceTab("Replied", in: app)
        let searchTab = workspaceTab("Search", in: app)
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(repliedTab.exists, app.debugDescription)
        XCTAssertTrue(searchTab.exists, app.debugDescription)
        XCTAssertTrue(inboxTab.isSelected, app.debugDescription)
        XCTAssertEqual(inboxTab.images.firstMatch.identifier, "envelope.badge",
                       "The Inbox tab keeps the outline envelope and solid dot in both appearance states.")
        XCTAssertFalse(app.searchFields.firstMatch.exists, app.debugDescription)
        assertListHeader(in: app)
        let inboxHeaderY = app.descendants(matching: .any)["inbox-brand"].frame.minY
        attachScreenshot("Inbox tab", from: app)

        repliedTab.tap()
        XCTAssertTrue(repliedTab.isSelected, app.debugDescription)
        XCTAssertFalse(app.searchFields.firstMatch.exists, app.debugDescription)
        assertListHeader(in: app)
        attachScreenshot("Replied tab", from: app)

        inboxTab.tap()
        searchTab.tap()
        assertListHeader(in: app)
        XCTAssertEqual(app.descendants(matching: .any)["inbox-brand"].frame.minY, inboxHeaderY,
                       accuracy: 3, "Search keeps the header at the same height as Inbox.")
        attachScreenshot("Search tab selected", from: app)
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(searchField.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(searchField.frame.maxY, keyboard.frame.minY + 1,
                                 "The Search field sits above the keyboard.")

        searchField.typeText(" \n")
        let keyboardDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 5), .completed,
                       "Submitting a whitespace-only query with the stock Search key dismisses the keyboard.")
        XCTAssertGreaterThan(searchField.frame.midY, app.frame.height * 0.65,
                             "The idle Search tab field returns to the bottom area.")
        XCTAssertEqual(app.descendants(matching: .any)["inbox-brand"].frame.minY, inboxHeaderY,
                       accuracy: 3, "Search keeps the header aligned after the field returns to the bottom.")
        attachScreenshot("Search idle", from: app)

        searchField.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThanOrEqual(searchField.frame.maxY, keyboard.frame.minY + 1,
                                 "The Search field sits above the keyboard while typing.")
        attachScreenshot("Search keyboard up", from: app)
        searchField.typeText("Archive")
        attachScreenshot("Search keyboard with Archive", from: app)
        searchField.typeText("\n")
        XCTAssertTrue(app.buttons["inbox-settings"].exists, app.debugDescription)
        attachScreenshot("Search results for Archive", from: app)
        let approval = app.descendants(matching: .any)["sample-approval-0"]
        XCTAssertTrue(approval.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot("Inbox search in use", from: app)

        approval.tap()
        let searchPosition = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '[0-9]+ of 3'")).firstMatch
        XCTAssertTrue(searchPosition.waitForExistence(timeout: 5),
                      "Search card position counts only the three matching Archive results.\n\(app.debugDescription)")
        let keepHere = app.buttons.containing(.staticText, identifier: "Keep here").firstMatch
        XCTAssertTrue(keepHere.waitForExistence(timeout: 5), app.debugDescription)
        keepHere.tap()
        let finish = app.descendants(matching: .any)["sample-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), app.debugDescription)
        finish.tap()

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "The stock Search field remains available after returning from a Search detail.")
        XCTAssertTrue(searchField.isHittable, app.debugDescription)
        XCTAssertFalse(approval.waitForExistence(timeout: 2),
                       "Search remains scoped to Inbox after the response moves out of Inbox.")
        XCTAssertEqual(app.descendants(matching: .any)["inbox-brand"].frame.minY, inboxHeaderY,
                       accuracy: 3, "Returning from a Search detail keeps the header in place.")
        XCTAssertGreaterThan(searchField.frame.midY, app.frame.height * 0.65,
                             "Returning from a Search detail leaves Search in the bottom tab area.")
        attachScreenshot("Answered request leaves Inbox search", from: app)

        selectMessageTab("Replied", in: app)
        XCTAssertTrue(repliedTab.isSelected, app.debugDescription)
        XCTAssertTrue(approval.waitForExistence(timeout: 5),
                      "The submitted local answer appears in Replied.")
        assertListHeader(in: app)
        attachScreenshot("Replied tab with answered message", from: app)

        searchTab.tap()
        let repliedSearchField = app.searchFields.firstMatch
        XCTAssertTrue(repliedSearchField.waitForExistence(timeout: 5), app.debugDescription)
        repliedSearchField.tap()
        repliedSearchField.typeText("Archive\n")
        XCTAssertTrue(app.buttons["inbox-settings"].exists, app.debugDescription)
        XCTAssertTrue(approval.waitForExistence(timeout: 5),
                      "The same query finds the answered message in Replied.")
        attachScreenshot("Replied search for Archive in use", from: app)
    }

    func testNotificationRouteLeavesSearchAndOpensTheTargetRequest() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-test-notification-navigation"]
        app.launch()

        let inboxTab = workspaceTab("Inbox", in: app)
        let searchTab = workspaceTab("Search", in: app)
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 10), app.debugDescription)
        searchTab.tap()

        let searchField = app.searchFields.firstMatch
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

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(inboxTab.isSelected,
                      "Returning from a notification opened in Search returns to its Inbox tab.")
        searchTab.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["request-row-facilities-01"]
            .waitForExistence(timeout: 5),
                      "Returning to Search shows its cleared path and query.")
        XCTAssertFalse(app.scrollViews["message-card-scroll"].exists,
                       "The previous notification detail is not left on the Search stack.")
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
        XCTAssertTrue(app.buttons["inbox-settings"].exists, app.debugDescription,
                      file: file, line: line)
    }

    private func attachScreenshot(_ name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
