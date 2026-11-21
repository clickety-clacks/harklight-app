import XCTest

@MainActor
final class B4InstallOverUIProof: XCTestCase {
    func testEnrollBeforeUpdate() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let signals = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        app.launch()
        try signal("ready", at: signals)
        let instruction = signals.appendingPathComponent("invitation-control.json")
        let bound = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: instruction.path), Date() < bound {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        struct Invitation: Decodable { let link: URL }
        let invitation = try JSONDecoder().decode(Invitation.self, from: Data(contentsOf: instruction))
        try FileManager.default.removeItem(at: instruction)
        app.open(invitation.link)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemOpen = springboard.alerts.buttons["Open"].firstMatch
        let handoffBound = Date().addingTimeInterval(20)
        while app.state != .runningForeground, Date() < handoffBound {
            if systemOpen.isHittable { systemOpen.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let join = app.buttons["Join"]
        XCTAssertTrue(join.waitForExistence(timeout: 25))
        join.tap()

        let approval = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Approval code ")).firstMatch
        XCTAssertTrue(approval.waitForExistence(timeout: 20))
        let code = String(approval.label.dropFirst("Approval code ".count))
        guard code.range(of: "^[A-Za-z0-9 -]{4,64}$", options: .regularExpression) != nil else {
            return XCTFail("The approval code did not have the expected shape.")
        }
        try signal("approval", text: code, at: signals)
        let approved = signals.appendingPathComponent("approved")
        let approvalBound = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: approved.path), Date() < approvalBound {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: approved.path))

        let finishing = app.staticTexts["Approved, finishing up"]
        let check = app.buttons["Check again"]
        let durableBound = Date().addingTimeInterval(45)
        var nextCheck = Date.distantPast
        while !finishing.exists, Date() < durableBound {
            if Date() >= nextCheck, check.isHittable {
                check.tap()
                nextCheck = Date().addingTimeInterval(5)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(finishing.exists, "0.1 must save owner approval before the legacy connection finishes.")
        try signal("durable-approval", at: signals)
    }

    func testRestoredSeededInboxAfterUpdateAndColdRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let rowID = try restoredInboxRow(in: app)
        app.terminate()
        app.launch()
        XCTAssertEqual(try restoredInboxRow(in: app), rowID)
        print("B4-UPGRADE seeded_inbox_cold_relaunch=pass")
    }

    private func restoredInboxRow(in app: XCUIApplication) throws -> String {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "request-row-")).firstMatch
        let proceed = app.buttons["Continue"]
        let deadline = Date().addingTimeInterval(50)
        while !row.exists, Date() < deadline {
            if proceed.isHittable {
                proceed.tap()
                let notNow = app.scrollViews.buttons["Not now"]
                if notNow.waitForExistence(timeout: 8) { notNow.tap() }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(row.exists, "The updated app should load the account's seeded inbox without a new invitation.")
        XCTAssertTrue(row.label.contains("B3 fixture request") || app.staticTexts["B3 fixture request"].exists)
        return row.identifier
    }

    private func signal(_ name: String, text: String = "yes", at directory: URL) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
