import XCTest

@MainActor
final class ProgressRenderedUITests: XCTestCase {
    func testErrorAndBlockerIconsSideBySideInBothAppearances() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--message-icon-comparison", "--harklight-test-inbox-list-\(appearance)"]
            app.launch()
            let error = app.descendants(matching: .any)["icon-comparison-error"].firstMatch
            let blocker = app.descendants(matching: .any)["icon-comparison-blocker"].firstMatch
            XCTAssertTrue(error.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(blocker.exists)
            XCTAssertTrue(error.label.contains("Error opening preview"), error.label)
            XCTAssertTrue(blocker.label.contains("Request, Blocker"), blocker.label)
            XCTAssertLessThan(error.frame.midX, blocker.frame.midX)
            capture("error-and-blocker-\(appearance)", app)
            app.terminate()
        }
    }

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
            XCTAssertTrue(detail.staticTexts["Prepare the studio handoff, FYI"].exists)
            XCTAssertTrue(app.staticTexts["Packaging"].exists || app.staticTexts["packaging"].exists)
            XCTAssertFalse(app.buttons["Seen"].exists)
            XCTAssertFalse(app.buttons["Reply"].exists)
            capture("progress-detail-\(mode)", app)
            app.terminate()
        }
    }

    func testProgressMoreExpandsWithoutANewSection() {
        let app = XCUIApplication()
        app.launchArguments = ["--progress-rendered", "--harklight-test-inbox-list-light"]
        app.launch()
        let progressHeader = app.staticTexts["progress-header"]
        XCTAssertTrue(progressHeader.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(progressHeader.label, "Progress · 5 of 7")
        let more = app.buttons["progress-more"]
        reveal(more, in: app)
        more.tap()
        for _ in 0..<12 where !progressHeader.isHittable {
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertEqual(progressHeader.label, "Progress · 7 of 7")
        XCTAssertFalse(app.staticTexts["new-message-area-header"].exists)
        app.terminate()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        towardTop: Bool = false) {
        for _ in 0..<12 where !element.isHittable {
            let list = app.collectionViews.firstMatch
            if towardTop { list.swipeDown() } else { list.swipeUp() }
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
