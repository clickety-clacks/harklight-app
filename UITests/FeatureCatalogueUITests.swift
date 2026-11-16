import XCTest

@MainActor
final class FeatureCatalogueUITests: XCTestCase {
    func testWelcomeCatalogueShowsEveryFeatureWithoutEnrollment() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let entry = app.buttons["welcome-features"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
        entry.tap()
        assertCatalogue(app)
        XCTAssertFalse(app.buttons["Join"].exists)
    }

    func testSettingsCatalogueExplainsDefaultsForLocalExamples() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture"]
        app.launch()
        let settings = app.buttons["inbox-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()
        let entry = app.buttons["settings-features"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
        assertCatalogue(app)
    }

    private func assertCatalogue(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Features"].waitForExistence(timeout: 5), app.debugDescription)
        for name in ["progressMessages", "accountAwareNotifications", "priorityLevels"] {
            let title = app.staticTexts["feature-\(name)-title"].firstMatch
            for _ in 0..<12 where !title.isHittable { app.swipeUp() }
            XCTAssertTrue(title.exists, app.debugDescription)
            let description = app.staticTexts["feature-\(name)-description"].firstMatch
            XCTAssertTrue(description.exists)
            XCTAssertFalse(app.buttons["feature-\(name)-open"].exists)
        }
    }
}
