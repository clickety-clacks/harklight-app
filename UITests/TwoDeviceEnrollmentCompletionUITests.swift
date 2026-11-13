import XCTest

@MainActor
final class TwoDeviceEnrollmentCompletionUITests: XCTestCase {
    func testFinishAlreadyApprovedSecondDevice() throws {
        guard ProcessInfo.processInfo.environment["HARKLIGHT_ISOLATED_UI_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Requires the owner-approved isolated second device.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let check = app.buttons["Check again"]
        if check.waitForExistence(timeout: 5), check.isHittable { check.tap() }
        guard app.staticTexts["Connected"].waitForExistence(timeout: 35) else {
            throw SetupFailure.connectionNotConfirmed
        }
        app.buttons["Continue"].tap()
        guard app.staticTexts["Hear about requests when Harklight is closed"].waitForExistence(timeout: 5) else {
            throw SetupFailure.notificationChoiceMissing
        }
        let decline = app.scrollViews.buttons["Not now"]
        guard decline.waitForExistence(timeout: 5), decline.isHittable else {
            throw SetupFailure.notificationChoiceMissing
        }
        decline.tap()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 30))
    }
    private enum SetupFailure: Error { case connectionNotConfirmed, notificationChoiceMissing }
}
