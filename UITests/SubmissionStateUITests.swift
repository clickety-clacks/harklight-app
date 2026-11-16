import XCTest

/// Each answer, No comment and Seen state shows in the control that sent it.
/// Sending, confirmed and closed come from real fixture sends; failed and
/// changed come from the debug phase hook after a relaunch. Screenshots are
/// written when `HL_CAPTURE_DIR` is set.
@MainActor
final class SubmissionStateUITests: XCTestCase {
    private let message = "review-01"
    private let hook = "--harklight-test-submission-phase="

    override func setUp() {
        continueAfterFailure = false
    }

    func testPickedChoiceSpinsWhileSendingThenShowsTheAnswer() {
        let app = launch(reset: true)
        openMessage(app)
        app.buttons["Cover A"].tap()
        send(app)
        capture("01-row-sending", app)
        openSentMessage(app)
        XCTAssertTrue(app.buttons["request-finish"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["request-finish"].label, "Sending")
        XCTAssertFalse(app.buttons["Cover B"].isEnabled, "Other choices step back while sending.")
        capture("02-choice-sending", app)

        simulate("ownOperationAccepted", app)
        XCTAssertTrue(element("request-answered", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Answered"].exists, "The answered card carries no Answered label.")
        app.scrollViews["message-card-scroll"].swipeDown()
        capture("03-choice-confirmed", app)
    }

    func testFailedChoiceShowsRetryInThePickedChoice() {
        // A real definitively failed answer (Cover A), seeded through the store.
        let app = launchSeeded("--harklight-test-relay-failed-choice")
        openSentMessage(app)
        XCTAssertTrue(element("request-choice-retry", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cover B"].isEnabled, "Other choices can be picked again.")
        XCTAssertNoStatusText(app)
        // The failure shows once: one circled mark and one Retry, in the picked choice.
        let message = app.scrollViews["message-card-scroll"]
        XCTAssertEqual(count("request-choice-retry", in: app), 1, "Exactly one Retry.")
        XCTAssertEqual(failureMarks(in: message), 1, "Exactly one circled mark.")
        capture("04-choice-failed", app)
    }

    func testFailedReplyIsLockedWithEditAndRetry() {
        let app = launch(reset: true)
        openMessage(app)
        let note = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send a note")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        Thread.sleep(forTimeInterval: 1)
        app.typeText("Book the Avenida, and ask for a quiet room")
        send(app)
        capture("05-reply-row-sending", app)
        openSentMessage(app)
        XCTAssertEqual(app.buttons["request-finish"].label, "Sending")
        capture("06-reply-sending", app)

        // A real definitively failed written reply, seeded through the store.
        app.terminate()
        let failed = launchSeeded("--harklight-test-relay-failed-reply")
        openSentMessage(failed)
        XCTAssertTrue(failed.buttons["request-reply-retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(failed.buttons["request-reply-edit"].exists)
        XCTAssertTrue(failed.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Avenida")).firstMatch
            .exists, "The failed text shows locked until Edit.")
        XCTAssertFalse(failed.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Avenida")).firstMatch
            .exists, "The failed text is not in an editable field.")
        XCTAssertNoStatusText(failed)
        // Bring the failed reply card into view before capturing it.
        let replyCard = element("request-input-review-response-card", in: failed)
        XCTAssertTrue(replyCard.waitForExistence(timeout: 5), failed.debugDescription)
        let scroll = failed.scrollViews["message-card-scroll"]
        for _ in 0..<8 where !(replyCard.isHittable && failed.buttons["request-reply-retry"].isHittable) {
            scroll.swipeUp()
        }
        XCTAssertTrue(replyCard.isHittable, "The failed reply card is on screen.")
        XCTAssertTrue(failed.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Avenida")).firstMatch
            .isHittable, "The locked sent text is visible.")
        XCTAssertTrue(failed.buttons["request-reply-retry"].isHittable, "Retry is visible.")
        XCTAssertTrue(failed.buttons["request-reply-edit"].isHittable, "Edit is visible.")
        // The failure shows once, in the card's row with Edit: one circled mark and
        // one Retry, and no second Retry in the card's title row.
        XCTAssertEqual(count("request-reply-retry", in: failed), 1, "Exactly one Retry control.")
        XCTAssertEqual(count("request-choice-retry", in: failed), 0, "No Retry in the card's title row.")
        XCTAssertEqual(failureMarks(in: replyCard), 1, "Exactly one circled mark on the card.")
        capture("07-reply-failed", failed)
    }

    func testNoCommentSpinsWhileSendingAndOffersRetryWhenItFails() {
        let app = launch(reset: true)
        openMessage(app)
        let noComment = app.buttons["request-no-comment"]
        let card = app.scrollViews["message-card-scroll"]
        for _ in 0..<4 where !noComment.isHittable { card.swipeUp() }
        noComment.tap()
        send(app)
        openSentMessage(app)
        for _ in 0..<4 where !noComment.isHittable { card.swipeUp() }
        capture("08-no-comment-sending", app)

        relaunch(app, phase: "noComment:failed")
        openSentMessage(app)
        for _ in 0..<4 where !noComment.isHittable { card.swipeUp() }
        XCTAssertTrue(element("request-choice-retry", in: app).waitForExistence(timeout: 5))
        capture("09-no-comment-failed", app)
    }

    func testClosedMessageReturnsTheControlsWithoutRetry() {
        let app = launch(reset: true)
        openMessage(app)
        app.buttons["Cover A"].tap()
        send(app)
        openSentMessage(app)
        simulate("cleared", app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(element("request-choice-retry", in: app).exists)
        XCTAssertFalse(app.buttons["Retry"].exists)
        app.scrollViews["message-card-scroll"].swipeDown()
        capture("10-closed", app)
    }

    func testChangedMessageShowsOneLine() {
        let app = launch(reset: true, phase: "answer:refusedChanged")
        openMessage(app)
        XCTAssertTrue(app.staticTexts["This message changed. Answer again."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Retry"].exists)
        capture("11-changed", app)
    }

    func testSeenSpinsWhileSendingAndBecomesRetrySeenWhenItFails() {
        let information = (0..<3).map { "sample-information-\($0)" }
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"] +
            information.map { hook + $0 + ":seen:sending" }
        app.launch()
        openInformation(app)
        capture("12-seen-sending", app)

        app.terminate()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"] +
            information.map { hook + $0 + ":seen:failed" }
        app.launch()
        openInformation(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Retry Seen")).firstMatch
            .waitForExistence(timeout: 5))
        capture("13-seen-failed", app)
    }

    // MARK: - Steps

    private func launch(reset: Bool, phase: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = [reset ? "--reset-attention-fixture" : "--attention-fixture"] +
            (phase.map { [hook + message + ":" + $0] } ?? [])
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    /// Launches with a debug seed that records a real failed answer for this
    /// message in an in-memory store; nothing connects anywhere.
    private func launchSeeded(_ argument: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = [argument]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    private func count(_ identifier: String, in app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(identifier: identifier).count
    }

    /// Circled failure marks ("Did not send") inside one part of the screen.
    private func failureMarks(in scope: XCUIElement) -> Int {
        scope.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Did not send")).count
    }

    /// A failed send shows only its mark and Retry, with no status words.
    private func XCTAssertNoStatusText(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for word in ["Not sent", "Pending", "Answered", "Answer not delivered"] {
            XCTAssertFalse(app.staticTexts[word].exists, "No \(word) label.", file: file, line: line)
        }
    }

    private func relaunch(_ app: XCUIApplication, phase: String) {
        app.terminate()
        app.launchArguments = ["--attention-fixture", hook + message + ":" + phase]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 20), app.debugDescription)
    }

    private func openMessage(_ app: XCUIApplication) {
        let row = element("request-row-" + message, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 10))
    }

    /// A sent message may have moved to Replied; on iPhone sending returns
    /// to the list.
    private func openSentMessage(_ app: XCUIApplication) {
        if app.scrollViews["message-card-scroll"].exists && app.buttons["request-finish"].exists { return }
        var row = element("request-row-" + message, in: app)
        if !row.waitForExistence(timeout: 2) {
            workspaceTab("Replied", in: app).tap()
            row = element("request-row-" + message, in: app)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 10))
    }

    private func openInformation(_ app: XCUIApplication) {
        let information = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "review moved to Thursday")).firstMatch
        XCTAssertTrue(information.waitForExistence(timeout: 20), app.debugDescription)
        information.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    private func send(_ app: XCUIApplication) {
        let finish = app.buttons["request-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(finish.isEnabled, app.debugDescription)
        finish.tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func simulate(_ scenario: String, _ app: XCUIApplication) {
        let outcome = app.buttons["fixture-outcome-menu"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5), app.debugDescription)
        let card = app.scrollViews["message-card-scroll"]
        for _ in 0..<4 where !outcome.isHittable { card.swipeUp() }
        outcome.tap()
        let choice = app.buttons.matching(identifier: "fixture-outcome-" + scenario).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func capture(_ name: String, _ app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 1.2)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["HL_CAPTURE_DIR"] else { return }
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url.appendingPathComponent(name + ".png"))
    }
}
