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
        XCTAssertFalse(workspaceTab("Search", in: app).exists,
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
        attachScreenshot("Replied results for Archive", from: app)
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
