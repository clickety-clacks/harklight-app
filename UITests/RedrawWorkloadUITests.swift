import XCTest

/// The same product journey is run on diagnostic baseline and candidate builds.
/// Each capture resets app-owned counters and writes the ordered results to the
/// app's Documents/redraw-measurements.json file.
@MainActor
final class RedrawWorkloadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testListDetailAndReplyChanges() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-redraw-probe"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        capture("startup", in: app)

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        scrollBothWays(list)
        capture("list scroll", in: app)

        openExample("Archive the old studio sketches?", rowID: "sample-approval-0", in: app)
        capture("long body setup", in: app)
        let card = app.scrollViews["message-card-scroll"]
        scrollBothWays(card)
        capture("long body scroll", in: app)

        showList(in: app)
        openExample("Which cover for the studio journal?", rowID: "sample-pictureChoice-0", in: app)
        capture("picture setup", in: app)
        scrollBothWays(card)
        capture("picture scroll", in: app)

        showList(in: app)
        openExample("Which approach", rowID: "sample-textChoice-0", in: app)
        let reply = app.buttons.containing(.staticText, identifier: "Your own answer").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 where !reply.isHittable { card.swipeUp() }
        XCTAssertTrue(reply.isHittable, app.debugDescription)
        reply.tap()
        let editor = app.textViews["request-input-answer-response"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture("reply setup", in: app)

        for character in ["q", "z", "v", "k"] {
            editor.typeText(character)
        }
        capture("four individual Reply changes", in: app)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let longReply = (1...16).map { "Reply line \($0) keeps growing across the field." }
            .joined(separator: " ")
        editor.typeText(longReply)
        capture("long reply typing", in: app)
        XCTAssertTrue((editor.value as? String ?? "").contains("Reply line 16"),
                      "The unsent Reply draft retains the typed content.")

        card.swipeDown()
        XCTAssertFalse(app.keyboards.firstMatch.exists, app.debugDescription)
        capture("keyboard dismissal", in: app)
        scrollBothWays(card)
        capture("long reply scroll", in: app)

        for _ in 0..<3 {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(card.waitForExistence(timeout: 5))
        }
        capture("rotation", in: app)
        XCTAssertTrue((editor.value as? String ?? "").contains("Reply line 16"),
                      "Scrolling and rotation preserve the unsent Reply draft.")
    }

    private func capture(_ phase: String, in app: XCUIApplication) {
        let button = app.buttons["redraw-capture"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.tap()
        print("REDRAW_CAPTURE \(phase)")
    }

    private func openExample(_ query: String, rowID: String, in app: XCUIApplication) {
        let search = workspaceSearchField(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        let clear = search.buttons["Clear text"]
        if clear.exists && clear.isHittable { clear.tap() }
        search.tap()
        search.typeText(query + "\n")
        let row = app.descendants(matching: .any)[rowID]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5),
                      app.debugDescription)
    }

    private func showList(in app: XCUIApplication) {
        let back = workspaceBackButton(in: app)
        if back.exists && back.isHittable {
            back.tap()
        } else {
            let sidebar = app.buttons["Show Sidebar"]
            XCTAssertTrue(sidebar.exists && sidebar.isHittable, app.debugDescription)
            sidebar.tap()
        }
        XCTAssertTrue(workspaceSearchField(in: app).waitForExistence(timeout: 5),
                      app.debugDescription)
    }

    private func scrollBothWays(_ scroll: XCUIElement) {
        for _ in 0..<6 {
            scroll.swipeUp()
            scroll.swipeDown()
        }
    }
}
