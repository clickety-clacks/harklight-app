import XCTest

@MainActor
final class ReplyTypingPerformanceUITests: XCTestCase {
    func testLongReplyTypingLatencyAndDraftSurviveAppRelaunch() async throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-search-button"].waitForExistence(timeout: 10), app.debugDescription)
        openTextChoice(in: app)

        let reply = app.buttons.containing(.staticText, identifier: "Your own answer").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        reply.tap()
        let editor = app.textViews["request-input-answer-response"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
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
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-search-button"].waitForExistence(timeout: 10), app.debugDescription)
        openTextChoice(in: app)
        let reopenedReply = app.buttons.containing(.staticText, identifier: "Your own answer").firstMatch
        XCTAssertTrue(reopenedReply.waitForExistence(timeout: 5), app.debugDescription)
        reopenedReply.tap()
        let reopenedEditor = app.textViews["request-input-answer-response"]
        XCTAssertTrue(reopenedEditor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(reopenedEditor.value as? String, longReply,
                       "A reply that paused before the app was killed must survive relaunch.")
    }

    private func openTextChoice(in app: XCUIApplication) {
        app.buttons["inbox-search-button"].tap()
        let search = app.textFields["inbox-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.typeText("Which approach\n")
        let row = app.descendants(matching: .any)["sample-textChoice-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
    }
}
