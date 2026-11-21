import XCTest

/// A private fixture-only UI case. No fixture secrets are test arguments or attachments.
@MainActor
final class B3EnrollmentProof: XCTestCase {
    private let queued = "B3 unsent fixture reply"
    private let draft = "B3 retained fixture draft"

    func testInviteRelaunchAndSignOutOnOneDevice() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let signals = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        app.launch()
        try signal("ready", at: signals)

        // The controller uses simctl openurl while this app is frontmost.
        // XCTest accepts the system confirmation without requiring Device Hub.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.alerts.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 12) { open.tap() }
        let join = app.buttons["Join"]
        let useAnotherInvitation = app.buttons["Use another invitation"]
        if useAnotherInvitation.waitForExistence(timeout: 8) {
            useAnotherInvitation.tap()
            let field = app.secureTextFields["Full invitation"]
            tapVisible(field, in: app)
            field.press(forDuration: 1)
            let paste = app.menuItems["Paste"]
            if paste.waitForExistence(timeout: 4) {
                paste.tap()
            } else {
                tapVisible(app.buttons["Paste"], in: app, timeout: 4)
            }
            let allowPaste = app.alerts.buttons["Allow Paste"].firstMatch
            if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
            tapVisible(app.buttons["Check invitation"], in: app)
            try signal("pasted-invite", at: signals)
        }
        tapVisible(join, in: app, timeout: 20)
        if !FileManager.default.fileExists(atPath: signals.appendingPathComponent("pasted-invite").path) {
            try signal("native-link-confirmed", at: signals)
        }
        let approval = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Approval code ")).firstMatch
        XCTAssertTrue(approval.waitForExistence(timeout: 20), "The join should reach owner approval.")
        let code = String(approval.label.dropFirst("Approval code ".count))
        guard code.range(of: "^[A-Za-z0-9 -]{4,64}$", options: .regularExpression) != nil else {
            return XCTFail("The approval text did not have the expected shape.")
        }
        try signal("approval", text: code, at: signals)
        let approved = signals.appendingPathComponent("approved")
        let approvalDeadline = Date().addingTimeInterval(25)
        while !FileManager.default.fileExists(atPath: approved.path), Date() < approvalDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: approved.path), "The fixture owner should acknowledge approval.")
        let check = app.buttons["Check again"]
        if check.isHittable { check.tap() }
        let row = firstRequest(in: app)
        let continueAfterApproval = app.buttons["Continue"]
        if continueAfterApproval.waitForExistence(timeout: 25), continueAfterApproval.isHittable {
            continueAfterApproval.tap()
            tapVisible(app.buttons["Not now"], in: app)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The approved identity should load a seeded inbox row.")
        let rowID = row.identifier
        XCTAssertTrue(rowID.hasPrefix("request-row-"))
        openSettings(app)
        XCTAssertTrue(app.staticTexts["This phone is registered to this account."].exists)
        try signal("enrolled", at: signals)

        // Only replies and enrollment removal get the synthetic offline fault.
        // Real /me, inbox, catch-up and approval traffic continue to use the fixture.
        app.terminate()
        app.launchEnvironment["HARKLIGHT_B3_OFFLINE_REPLY"] = "1"
        app.launchEnvironment["HARKLIGHT_B3_OFFLINE_REMOVAL"] = "1"
        app.launch()
        openChat(app, rowID: rowID)
        let composer = app.textViews["sample-chat-composer"]
        composer.tap()
        composer.typeText(queued)
        app.buttons["sample-chat-send"].tap()
        XCTAssertTrue(app.staticTexts[queued].waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText(draft)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))

        app.terminate()
        app.launch()
        openChat(app, rowID: rowID)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(app.staticTexts[queued].exists)
        try signal("cold-restored", at: signals)

        app.terminate()
        app.launch()
        openSettings(app)
        tapVisible(app.buttons["Disconnect this phone…"], in: app)
        let confirmation = app.buttons["Disconnect this phone"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 6))
        confirmation.tap()
        let retry = app.buttons["Retry removal"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 16), "Unconfirmed removal should remain retryable.")
        XCTAssertTrue(app.staticTexts["This phone is registered to this account."].exists)
        try signal("offline-removal-kept-account", at: signals)

        // Give removal a real network path while keeping the queued reply
        // offline, so success must preserve both kinds of unsent text.
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "HARKLIGHT_B3_OFFLINE_REMOVAL")
        app.launch()
        openChat(app, rowID: rowID)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(app.staticTexts[queued].exists)
        app.terminate()
        app.launch()
        openSettings(app)
        tapVisible(retry, in: app)
        let readOnlyText = app.buttons["View unsent text"].firstMatch
        if !readOnlyText.waitForExistence(timeout: 15) { openSettings(app) }
        tapVisible(readOnlyText, in: app, timeout: 12)
        XCTAssertTrue(app.staticTexts[queued].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[draft].waitForExistence(timeout: 8))
        try signal("confirmed-removal-kept-unsent-text", at: signals)
    }

    private func firstRequest(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "request-row-")).firstMatch
    }

    private func openChat(_ app: XCUIApplication, rowID: String) {
        let row = app.descendants(matching: .any)[rowID].firstMatch
        tapVisible(row, in: app, timeout: 20)
        let chat = app.buttons["Chat"]
        tapVisible(chat, in: app)
        XCTAssertTrue(app.textViews["sample-chat-composer"].waitForExistence(timeout: 8))
    }

    private func openSettings(_ app: XCUIApplication) {
        let features = app.buttons["settings-features"]
        if features.isHittable { return }
        let settings = app.buttons["inbox-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        XCTAssertTrue(features.waitForExistence(timeout: 8))
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 8) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        for _ in 0..<3 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    private func signal(_ name: String, text: String = "yes", at directory: URL) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
