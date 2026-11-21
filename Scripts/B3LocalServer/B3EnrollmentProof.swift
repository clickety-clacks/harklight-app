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

        let invitation = signals.appendingPathComponent("invitation-control.json")
        let control = try waitForControl(invitation)
        try FileManager.default.removeItem(at: invitation)
        try openInvitation(control, in: app, signals: signals)
        if control.route != "paste" {
            try confirmForegroundHandoff(control.route, app: app, signals: signals)
        }
        tapVisible(app.buttons["Join"], in: app, timeout: 25)
        try signal("invite-confirmed", at: signals)
        let approval = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Approval code ")).firstMatch
        XCTAssertTrue(approval.waitForExistence(timeout: 20), "The join should reach owner approval.")
        let code = String(approval.label.dropFirst("Approval code ".count))
        guard code.range(of: "^[A-Za-z0-9 -]{4,64}$", options: .regularExpression) != nil else {
            return XCTFail("The approval text did not have the expected shape.")
        }
        try signal("approval", text: code, at: signals)
        try signal("request-pending", at: signals)
        let approved = signals.appendingPathComponent("approved")
        let approvalDeadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: approved.path), Date() < approvalDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: approved.path), "The fixture owner should acknowledge approval.")
        try signal("owner-approved", at: signals)
        let row = firstRequest(in: app)
        let continueAfterApproval = app.buttons["Continue"]
        let check = app.buttons["Check again"]
        let connectionDeadline = Date().addingTimeInterval(45)
        var nextStatusCheck = Date.distantPast
        while !row.exists, Date() < connectionDeadline {
            if continueAfterApproval.isHittable {
                try signal("connected", at: signals)
                continueAfterApproval.tap()
                tapVisible(app.scrollViews.buttons["Not now"], in: app)
                try signal("notification-choice", at: signals)
            } else if Date() >= nextStatusCheck, check.isHittable {
                check.tap()
                nextStatusCheck = Date().addingTimeInterval(5)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(row.exists, "The approved identity should load a seeded inbox row.")
        let rowID = row.identifier
        XCTAssertTrue(rowID.hasPrefix("request-row-"))
        try signal("seeded-inbox", at: signals)
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
        waitForRemovalRetry(retry, in: app)
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
        waitForRemovalRetry(retry, in: app)
        tapVisible(retry, in: app)
        let readOnlyText = app.buttons["View unsent text"].firstMatch
        if !readOnlyText.waitForExistence(timeout: 15) { openSettings(app) }
        tapVisible(readOnlyText, in: app, timeout: 12)
        XCTAssertTrue(app.staticTexts[queued].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[draft].waitForExistence(timeout: 8))
        try signal("confirmed-removal-kept-unsent-text", at: signals)
    }

    private struct InvitationControl: Decodable {
        let route: String
        let link: URL?
    }

    private func waitForControl(_ file: URL) throws -> InvitationControl {
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file) {
                return try JSONDecoder().decode(InvitationControl.self, from: data)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func openInvitation(_ control: InvitationControl, in app: XCUIApplication, signals: URL) throws {
        switch control.route {
        case "bridge":
            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
            guard let url = control.link else { throw CocoaError(.fileReadCorruptFile) }
            safari.open(url)
            let bridge = safari.links["Open in Harklight"].firstMatch
            XCTAssertTrue(bridge.waitForExistence(timeout: 35), "The dashboard should resolve the short invitation.")
            try signal("bridge-resolved", at: signals)
            tapVisible(bridge, in: safari)
            try signal("bridge-tapped", at: signals)
        case "paste":
            let field = app.secureTextFields["Full invitation"]
            tapVisible(field, in: app)
            field.press(forDuration: 1)
            let menuPaste = app.menuItems["Paste"]
            if menuPaste.waitForExistence(timeout: 4) {
                menuPaste.tap()
            } else {
                tapVisible(app.buttons["Paste"], in: app, timeout: 4)
            }
            let allowPaste = app.alerts.buttons["Allow Paste"].firstMatch
            if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
            tapVisible(app.buttons["Check invitation"], in: app)
        case "native":
            guard let url = control.link else { throw CocoaError(.fileReadCorruptFile) }
            app.open(url)
        default:
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func confirmForegroundHandoff(_ route: String, app: XCUIApplication, signals: URL) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let systemOpen = springboard.alerts.buttons["Open"].firstMatch
        let safariOpen = safari.alerts.buttons["Open"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while app.state != .runningForeground, Date() < deadline {
            if systemOpen.isHittable {
                systemOpen.tap()
                try signal("system-open-confirmed", at: signals)
            } else if route == "bridge", safariOpen.isHittable {
                safariOpen.tap()
                try signal("system-open-confirmed", at: signals)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertEqual(app.state, .runningForeground, "Harklight should become the foreground app after Open.")
        try signal("handoff-foreground", at: signals)
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

    private func waitForRemovalRetry(_ retry: XCUIElement, in app: XCUIApplication) {
        // The account section may be inside a lazily rendered Settings form.
        // Scroll it into view while the sign-out attempt closes and reopens the transport.
        let form = app.collectionViews.firstMatch
        for _ in 0..<3 {
            if retry.isHittable { return }
            if form.isHittable { form.swipeUp() }
            if retry.waitForExistence(timeout: 4), retry.isHittable { return }
        }
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "Unconfirmed removal should remain retryable.")
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
