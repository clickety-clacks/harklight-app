import XCTest

@MainActor
final class InboxStockTabsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testNativeHeaderIsReachableAtTheListScrollEdge() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        let brand = app.descendants(matching: .any)["inbox-brand"]
        let settings = app.buttons["inbox-settings"]
        XCTAssertTrue(brand.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(settings.isHittable, app.debugDescription)
        XCTAssertLessThan(abs(brand.frame.midY - settings.frame.midY), 30,
                          "The title and Settings belong on the same native header line.")
        attachScreenshot("Native header at list top", from: app)

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        let dragStart = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.80))
        let dragEnd = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        XCTAssertTrue(list.exists, app.debugDescription)
        attachScreenshot("List after scroll", from: app)

        list.swipeDown()
        XCTAssertTrue(brand.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(settings.isHittable, app.debugDescription)
        attachScreenshot("Native header restored at list top", from: app)
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
        XCTAssertFalse(workspaceTab("Search", in: app).exists,
                       "Search belongs to the message list, not a separate tab.")
        assertListHeader(in: app)
        attachScreenshot("Inbox with native list search", from: app)

        let searchField = app.searchFields.firstMatch
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

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertFalse(approval.waitForExistence(timeout: 2),
                       "An answered request leaves the Inbox search results.")
        repliedTab.tap()
        XCTAssertTrue(repliedTab.isSelected, app.debugDescription)
        XCTAssertTrue(approval.waitForExistence(timeout: 5),
                      "The same query finds the answered request in Replied.")
        attachScreenshot("Replied results for Archive", from: app)
    }

    func testNotificationRouteClearsListSearchAndOpensTheTargetRequest() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-test-notification-navigation"]
        app.launch()

        let inboxTab = workspaceTab("Inbox", in: app)
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 10), app.debugDescription)

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
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
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
