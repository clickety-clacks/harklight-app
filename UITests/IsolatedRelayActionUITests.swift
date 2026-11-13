import UIKit
import XCTest

/// Opt-in diagnosis against an already enrolled disposable account on a real
/// isolated server. Enrollment and server cleanup belong to the fixture owner.
/// No invitations, credentials, sample launches or protocol doubles enter here.
@MainActor
final class IsolatedRelayActionUITests: XCTestCase {
    private let observationTimeout: TimeInterval = 30

    func testLeftSwipeThenBodySeen() throws {
        try exerciseSeen(edge: "LEFT", swipeLeft: true, control: "request-seen-action")
    }

    func testRightSwipeThenToolbarSeen() throws {
        try exerciseSeen(edge: "RIGHT", swipeLeft: false, control: "request-finish-seen")
    }

    func testReplyThroughVisibleSendControl() throws {
        let message = try configuredMessage("REPLY")
        let app = launchEnrolledApp()
        defer { collectJournal(app) }
        try openMessage(message, in: app)
        let choice = app.buttons.containing(.staticText, identifier: "Reply").firstMatch
        try tap(choice, stage: "reply-choice", in: app)
        let editor = app.textViews["request-compatibility-reply-response"]
        try tap(editor, stage: "reply-editor", in: app)
        let reply = "Isolated UI diagnostic reply " + UUID().uuidString.lowercased()
        editor.typeText(reply)
        attach(reply, named: "synthetic-reply-for-server-correlation")
        snapshot("reply-draft", app)
        try tap(app.buttons["request-finish"], stage: "reply-send", in: app)
        try openRepliedMessage(message, in: app)
        let confirmation = app.descendants(matching: .any)["request-answered"].firstMatch
        // The app can show pending intent before the server accepts it. Only
        // its actual confirmation card and exact answer count as UI success.
        guard confirmation.waitForExistence(timeout: observationTimeout) else {
            snapshot("reply-unconfirmed", app)
            throw Failure.missing("request-answered")
        }
        XCTAssertTrue(app.staticTexts[reply].exists,
                      "The confirmed reply must retain the exact submitted text.")
        snapshot("reply-confirmed", app)
    }

    private func exerciseSeen(edge: String, swipeLeft: Bool, control: String) throws {
        let message = try configuredMessage(edge)
        let app = launchEnrolledApp()
        defer { collectJournal(app) }
        let row = try findMessage(message, in: app)
        snapshot("before-\(edge)-swipe", app)
        if swipeLeft { row.swipeLeft() } else { row.swipeRight() }
        snapshot("after-\(edge)-swipe", app)
        let action = app.buttons["inbox-mark-seen"]
        let revealed = action.waitForExistence(timeout: 5)
        // Continue to the independent detail tap if the menu failed: otherwise
        // a swipe failure would prevent observing the reported Seen no-op.
        XCTAssertTrue(revealed, "The \(edge) row swipe must reveal Seen.")
        XCTAssertTrue(row.exists, "Revealing a menu must not submit Seen.")
        if revealed {
            let header = app.descendants(matching: .any)["inbox-brand"].firstMatch
            try tap(header, stage: "dismiss-swipe-menu", in: app)
        }
        try openMessage(message, in: app)
        try tap(app.buttons[control], stage: "\(edge)-seen-tap", in: app)
        try openRepliedMessage(message, in: app)
        let confirmation = app.descendants(matching: .any)["request-seen-confirmation"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: observationTimeout),
                      "Pending or locally selected Seen is not a confirmed response.")
        snapshot("\(edge)-seen-result", app)
    }

    private struct Message {
        let id: String
        let title: String
    }

    private enum Failure: Error { case missing(String) }

    private func configuredMessage(_ name: String) throws -> Message {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HARKLIGHT_ISOLATED_UI_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Requires explicit isolated-server/account/device custody; no default account is used.")
        }
        func required(_ suffix: String) throws -> String {
            guard let value = environment["HARKLIGHT_DIAGNOSTIC_\(name)_\(suffix)"],
                  !value.isEmpty else { throw Failure.missing("\(name)_\(suffix) configuration") }
            return value
        }
        continueAfterFailure = true
        return try Message(id: required("ID"), title: required("TITLE"))
    }

    private func launchEnrolledApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // This flag exposes existing navigation/refresh observations only. It
        // neither replaces enrollment nor supplies sample/server responses.
        app.launchArguments = ["--harklight-ui-diagnostics"]
        app.launch()
        return app
    }

    private func findMessage(_ message: Message, in app: XCUIApplication) throws -> XCUIElement {
        guard app.buttons["inbox-settings"].waitForExistence(timeout: observationTimeout) else {
            // Do not capture an enrollment screen: invitation custody is
            // separate, and the diagnostic never enrolls or resets an account.
            throw Failure.missing("accepted signed-in inbox")
        }
        let back = workspaceBackButton(in: app)
        if back.exists && back.isHittable { back.tap() }
        let search = workspaceSearchField(in: app)
        try tap(search, stage: "search", in: app)
        let clear = search.buttons["Clear text"]
        if clear.exists { clear.tap() }
        search.typeText(message.title + "\n")
        let row = app.descendants(matching: .any)["request-row-" + message.id].firstMatch
        guard row.waitForExistence(timeout: observationTimeout), row.isHittable else {
            snapshot("message-unavailable", app)
            throw Failure.missing("configured ordinary row")
        }
        return row
    }

    private func openMessage(_ message: Message, in app: XCUIApplication) throws {
        let row = try findMessage(message, in: app)
        // The disposable messages have plain bodies without links; the row's
        // combined accessibility element is the actual navigation target.
        try tap(row, stage: "open-message", in: app)
        guard app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5) else {
            snapshot("detail-unavailable", app)
            throw Failure.missing("message-card-scroll")
        }
        snapshot("detail-open", app)
    }

    private func openRepliedMessage(_ message: Message, in app: XCUIApplication) throws {
        let back = workspaceBackButton(in: app)
        if back.exists && back.isHittable { back.tap() }
        try tap(workspaceTab("Replied", in: app), stage: "replied-tab", in: app)
        try openMessage(message, in: app)
    }

    private func tap(_ element: XCUIElement, stage: String, in app: XCUIApplication) throws {
        snapshot(stage + "-before", app)
        guard element.waitForExistence(timeout: 5), element.isEnabled, element.isHittable else {
            snapshot(stage + "-unavailable", app)
            throw Failure.missing(stage)
        }
        element.tap()
        snapshot(stage + "-after", app)
    }

    private func snapshot(_ stage: String, _ app: XCUIApplication) {
        // Capture before navigating to diagnostics: that navigation can change
        // focus, layout and refresh timing. Only disposable content is allowed.
        var lines = ["time=\(ISO8601DateFormatter().string(from: Date())) stage=\(stage)"]
        for identifier in ["inbox-refreshing-badge", "inbox-status-unrefreshed",
                           "inbox-warning-button", "request-seen-action", "request-finish-seen",
                           "request-finish", "inbox-mark-seen", "inbox-no-comment",
                           "inbox-list-diagnostics", "request-delivery-warning"] {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            lines.append("\(identifier): exists=\(element.exists)" + (element.exists
                ? " enabled=\(element.isEnabled) hittable=\(element.isHittable) label=\(element.label)" : ""))
        }
        attach(lines.joined(separator: "\n") + "\n" + app.debugDescription, named: stage)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = stage
        image.lifetime = .keepAlways
        add(image)
    }

    private func collectJournal(_ app: XCUIApplication) {
        guard app.buttons["inbox-settings"].exists else { return }
        snapshot("before-diagnostics-navigation", app)
        if app.alerts["Connection needs attention"].exists {
            app.alerts["Connection needs attention"].buttons["Dismiss"].tap()
        }
        let back = workspaceBackButton(in: app)
        if back.exists && back.isHittable { back.tap() }
        if app.buttons["inbox-warning-button"].isHittable {
            app.buttons["inbox-warning-button"].tap()
            snapshot("warning-text", app)
            app.descendants(matching: .any)["inbox-brand"].firstMatch.tap()
        }
        let settings = app.buttons["inbox-settings"]
        guard settings.isHittable else {
            XCTFail("Diagnostics settings unreachable; preserve the pre-navigation evidence.")
            return
        }
        settings.tap()
        let share = app.buttons["client-diagnostics-share"]
        guard share.waitForExistence(timeout: 5), share.isHittable else {
            snapshot("journal-unavailable", app)
            XCTFail("Retained client journal unavailable; replay boundary remains unproved.")
            return
        }
        share.tap()
        let preview = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Harklight client diagnostics")).firstMatch
        if preview.waitForExistence(timeout: 5) {
            attach(preview.label, named: "journal-share-preview-may-be-truncated")
        }
        let copy = app.cells["Copy"]
        guard copy.waitForExistence(timeout: 5), copy.isHittable else {
            XCTFail("Cannot copy complete safe diagnostic journal; preview is not complete evidence.")
            return
        }
        let previousChange = UIPasteboard.general.changeCount
        copy.tap()
        guard UIPasteboard.general.changeCount != previousChange,
              let journal = UIPasteboard.general.string,
              journal.hasPrefix("Harklight client diagnostics"), journal.contains("format_version=1") else {
            XCTFail("Copied diagnostic journal inaccessible; do not read or attach unrelated clipboard data.")
            return
        }
        attach(journal, named: "client-journal-replay-ack-operation-boundaries")
    }

    private func attach(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
