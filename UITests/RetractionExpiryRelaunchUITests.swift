import XCTest

@MainActor
final class RetractionExpiryRelaunchUITests: XCTestCase {
    func testPersistedRetractionExpiresAfterAppProcessRelaunch() async throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-attention-fixture",
            "--harklight-test-retraction-expiry-relaunch"
        ]
        app.launch()

        let row = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        let retracted = app.descendants(matching: .any)["inbox-retracted-pill"]
        XCTAssertTrue(retracted.waitForExistence(timeout: 5), app.debugDescription)

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "The app process must terminate before the deadline wait.")
        try await Task.sleep(for: .seconds(195))

        app.launchArguments = ["--attention-fixture"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), app.debugDescription)
        let unaffectedRow = app.descendants(matching: .any)["request-row-review-01"]
        XCTAssertTrue(unaffectedRow.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(row.waitForExistence(timeout: 3),
                       "The retracted row must be absent after a process relaunch past its persisted 24-hour deadline.")
        XCTAssertFalse(retracted.waitForExistence(timeout: 3), app.debugDescription)
    }


    func testServerRetractionExpiresInForegroundAndAfterProcessRelaunch() async throws {
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
    }
}
