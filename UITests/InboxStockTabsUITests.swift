import XCTest

@MainActor
final class InboxStockTabsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testStockTabsAndSearchKeepInboxAndRepliedResults() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        let inboxTab = app.buttons["Inbox"]
        let repliedTab = app.buttons["Replied"]
        let searchTab = app.buttons["Search"]
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(repliedTab.exists, app.debugDescription)
        XCTAssertTrue(searchTab.exists, app.debugDescription)
        XCTAssertTrue(inboxTab.isSelected, app.debugDescription)
        attachScreenshot("Inbox tab", from: app)

        repliedTab.tap()
        XCTAssertTrue(repliedTab.isSelected, app.debugDescription)
        attachScreenshot("Replied tab", from: app)

        inboxTab.tap()
        searchTab.tap()
        attachScreenshot("Search tab selected", from: app)
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        searchField.tap()
        searchField.typeText("Archive")
        attachScreenshot("Search results for Archive", from: app)
        let approval = app.descendants(matching: .any)["sample-approval-0"]
        XCTAssertTrue(approval.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot("Inbox search in use", from: app)

        inboxTab.tap()
        approval.tap()
        let keepHere = app.buttons.containing(.staticText, identifier: "Keep here").firstMatch
        XCTAssertTrue(keepHere.waitForExistence(timeout: 5), app.debugDescription)
        keepHere.tap()
        let finish = app.descendants(matching: .any)["sample-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), app.debugDescription)
        finish.tap()

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(repliedTab.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(repliedTab.isSelected, app.debugDescription)
        XCTAssertTrue(approval.waitForExistence(timeout: 5),
                      "The submitted local answer appears in Replied.")
        attachScreenshot("Replied tab with answered message", from: app)

        searchTab.tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        searchField.tap()
        searchField.typeText("Archive")
        XCTAssertTrue(approval.waitForExistence(timeout: 5),
                      "The same query finds the answered message in Replied.")
        attachScreenshot("Replied search in use", from: app)
    }

    private func attachScreenshot(_ name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
