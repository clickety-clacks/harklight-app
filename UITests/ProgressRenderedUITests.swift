import XCTest

@MainActor
final class ProgressRenderedUITests: XCTestCase {
    func testProgressSectionAndDetailInBothAppearances() {
        XCUIDevice.shared.orientation = .portrait
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--progress-rendered", "--harklight-test-inbox-list-\(mode)"]
            app.launch()
            let row = app.descendants(matching: .any)["progress-row-progress-0"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
            capture("progress-section-\(mode)", app)
            row.tap()
            let detail = app.scrollViews["progress.detail"]
            XCTAssertTrue(detail.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Prepare the studio handoff"].exists)
            XCTAssertTrue(app.staticTexts["Packaging"].exists || app.staticTexts["packaging"].exists)
            XCTAssertFalse(app.buttons["Seen"].exists)
            XCTAssertFalse(app.buttons["Reply"].exists)
            capture("progress-detail-\(mode)", app)
            app.terminate()
        }
    }

    func testProgressAndNewMoreExpandIndependently() {
        let app = XCUIApplication()
        app.launchArguments = ["--progress-rendered", "--harklight-test-inbox-list-light"]
        app.launch()
        let progressHeader = app.staticTexts["progress-header"]
        XCTAssertTrue(progressHeader.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(progressHeader.label, "Progress · 5 of 7")
        let more = app.buttons["progress-more"]
        reveal(more, in: app)
        more.tap()
        let newHeader = app.staticTexts["new-message-area-header"]
        reveal(newHeader, in: app)
        XCTAssertEqual(newHeader.label, "New · 5 of 7")
        let newMore = app.buttons["new-message-area-more"]
        reveal(newMore, in: app)
        newMore.tap()
        reveal(newHeader, in: app)
        XCTAssertEqual(newHeader.label, "New · 7 of 7")
        for _ in 0..<12 where !progressHeader.isHittable {
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertEqual(progressHeader.label, "Progress · 7 of 7")
        app.terminate()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.exists, app.debugDescription)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
