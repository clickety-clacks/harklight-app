import XCTest

@MainActor
final class ReplyDraftPersistenceUITests: XCTestCase {
    func testUnsentChoiceSurvivesLeavingAndReopeningRequest() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()

        let row = app.descendants(matching: .any)["request-row-review-01"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        let choice = app.buttons["Cover A"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        XCTAssertTrue(choice.isSelected)

        let back = workspaceBackButton(in: app)
        if back.exists && back.isHittable {
            back.tap()
            XCTAssertTrue(workspaceSearchField(in: app).waitForExistence(timeout: 5),
                          app.debugDescription)
        } else {
            let other = app.descendants(matching: .any)["request-row-facilities-01"]
            XCTAssertTrue(other.waitForExistence(timeout: 5), app.debugDescription)
            other.tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()

        XCTAssertTrue(app.buttons["Cover A"].isSelected,
                      "An unsent choice survives leaving and reopening the request.")
        XCTAssertTrue(app.buttons["request-finish"].isEnabled,
                      "The retained choice remains ready for deliberate submission.")
    }

    func testReplyContentsAreNotSavedAcrossAppRelaunch() async throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()
        XCTAssertTrue(workspaceTab("Inbox", in: app).waitForExistence(timeout: 10), app.debugDescription)
        let row = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        let editor = app.textFields["request-input-note"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        reveal(editor, in: app)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture("reply-free-text-empty", app)

        let longReply = String(repeating: "a", count: 256)
        editor.typeText(longReply)
        capture("reply-free-text-typed", app)
        XCTAssertEqual(editor.value as? String, longReply)

        try await Task.sleep(for: .milliseconds(700))
        app.terminate()
        app.launchArguments = ["--attention-fixture"]
        app.launch()
        XCTAssertTrue(workspaceTab("Inbox", in: app).waitForExistence(timeout: 10), app.debugDescription)
        let repliedTab = workspaceTab("Replied", in: app)
        if repliedTab.exists { repliedTab.tap() }
        let reopenedRow = app.descendants(matching: .any)["request-row-facilities-01"]
        let inboxTab = workspaceTab("Inbox", in: app)
        if !reopenedRow.waitForExistence(timeout: 3), inboxTab.exists {
            inboxTab.tap()
        }
        XCTAssertTrue(reopenedRow.waitForExistence(timeout: 5), app.debugDescription)
        reopenedRow.tap()
        let reopenedEditor = app.textFields["request-input-note"]
        XCTAssertTrue(reopenedEditor.waitForExistence(timeout: 5), app.debugDescription)
        reveal(reopenedEditor, in: app)
        XCTAssertNotEqual(reopenedEditor.value as? String, longReply,
                          "Reply contents are not saved when the app closes before the checkmark is tapped.")
    }

    private func reveal(_ editor: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["message-card-scroll"]
        for _ in 0..<8 where !editor.isHittable { scroll.swipeUp() }
        XCTAssertTrue(editor.isHittable, app.debugDescription)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
