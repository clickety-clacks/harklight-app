import XCTest

@MainActor
final class ReplyDraftPersistenceUITests: XCTestCase {
    func testLongReplyDraftSurvivesAppRelaunch() async throws {
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

        let longReply = String(repeating: "a", count: 256)
        editor.typeText(longReply)
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
        XCTAssertEqual(reopenedEditor.value as? String, longReply,
                       "A reply that paused before the app was killed must survive relaunch.")
    }

    private func reveal(_ editor: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["message-card-scroll"]
        for _ in 0..<8 where !editor.isHittable { scroll.swipeUp() }
        XCTAssertTrue(editor.isHittable, app.debugDescription)
    }
}
