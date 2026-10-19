import XCTest

@MainActor
final class ReplyTypingPerformanceUITests: XCTestCase {
    func testLongReplyTypingLatencyAndDraftSurviveAppRelaunch() async throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-search-button"].waitForExistence(timeout: 10), app.debugDescription)
        let row = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        let editor = app.textViews["request-input-note"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        reveal(editor, in: app)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        let longReply = String(repeating: "Please keep the east entrance clear while the repair team moves equipment through the hall. ", count: 8)
        let started = ProcessInfo.processInfo.systemUptime
        editor.typeText(longReply)
        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        XCTAssertEqual(editor.value as? String, longReply)

        let measurement = """
        scenario=reply text editor
        characters=\(longReply.count)
        elapsed_ms=\(String(format: "%.1f", elapsedMilliseconds))
        average_ms_per_character=\(String(format: "%.2f", elapsedMilliseconds / Double(longReply.count)))
        """
        let attachment = XCTAttachment(data: Data(measurement.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "reply-typing-latency"
        attachment.lifetime = .keepAlways
        add(attachment)

        try await Task.sleep(for: .milliseconds(700))
        app.terminate()
        app.launchArguments = ["--attention-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-search-button"].waitForExistence(timeout: 10), app.debugDescription)
        let repliedTab = app.buttons["inbox-tab-replied"]
        if repliedTab.exists { repliedTab.tap() }
        let reopenedRow = app.descendants(matching: .any)["request-row-facilities-01"]
        if !reopenedRow.waitForExistence(timeout: 3), app.buttons["inbox-tab-inbox"].exists {
            app.buttons["inbox-tab-inbox"].tap()
        }
        XCTAssertTrue(reopenedRow.waitForExistence(timeout: 5), app.debugDescription)
        reopenedRow.tap()
        let reopenedEditor = app.textViews["request-input-note"]
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
