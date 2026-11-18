import XCTest

@MainActor
final class RetractionExpiryRelaunchUITests: XCTestCase {
    func testServerRetractionExpiresInForegroundAndAfterProcessRelaunch() async throws {
        // Evidence run only: Scripts/test-server-retraction-expiry.sh installs the
        // Server-produced fixture this test needs and sets this variable.
        guard ProcessInfo.processInfo.environment["HARKLIGHT_SERVER_RETRACTION_EVIDENCE"] == "1" else {
            throw XCTSkip("Requires the Server-produced retraction fixture from Scripts/test-server-retraction-expiry.sh.")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--attention-fixture",
            "--reset-attention-fixture",
            "--harklight-test-server-retraction"
        ]
        app.launch()

        let readback = app.staticTexts["server-retraction-persistence-readback"]
        XCTAssertTrue(readback.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(readback.label, "Server retraction persisted: first_process")
        let retracted = app.descendants(matching: .any)["inbox-retracted-pill"]
        XCTAssertTrue(retracted.waitForExistence(timeout: 10), app.debugDescription)

        let advanceClock = app.buttons["advance-server-retraction-expiry"]
        XCTAssertTrue(advanceClock.waitForExistence(timeout: 5), app.debugDescription)
        advanceClock.tap()
        let rowExpired = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: retracted)
        XCTAssertEqual(XCTWaiter.wait(for: [rowExpired], timeout: 10), .completed,
                       "The foreground expiry task should remove the retracted row at the server timestamp plus 24 hours.")

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10),
                      "The first app process must terminate before relaunching from the persisted store.")
        app.launchArguments = [
            "--attention-fixture",
            "--harklight-test-retraction-expiry-after-deadline"
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), app.debugDescription)

        XCTAssertTrue(readback.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(readback.label, "Server retraction persisted: after_process_relaunch")
        XCTAssertFalse(retracted.exists,
                       "The row must remain absent after a real process relaunch past the persisted server retraction deadline.")

        let searchField = workspaceSearchField(in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        searchField.tap()
        searchField.typeText("Please review the attached file\n")
        let historyRow = app.descendants(matching: .any)["expired-retraction-history-native-interop"]
        XCTAssertTrue(historyRow.waitForExistence(timeout: 10), app.debugDescription)
        historyRow.tap()

        let chatButton = app.buttons["Chat"]
        XCTAssertTrue(chatButton.waitForExistence(timeout: 5), app.debugDescription)
        chatButton.tap()
        let conversation = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(conversation.staticTexts["Retracted"].waitForExistence(timeout: 5),
                      "The retained conversation exposes the retraction after expiry and process relaunch.")
    }
}
