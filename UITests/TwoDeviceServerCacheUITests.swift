import UIKit
import XCTest

/// Uses the normal app on the second approved disposable device. The two
/// requests are reserved by the isolated server custodian; no fixtures are
/// injected and the first device's queued answer is never submitted here.
@MainActor
final class TwoDeviceServerCacheUITests: XCTestCase {
    private let observationTimeout: TimeInterval = 30

    func testMessageOpensDuringPostAckCatchUp() throws {
        try requireCatchUpRun()
        let message = try configuredMessage("SEEN")
        let app = launchEnrolledApp()
        let row = try findMessage(message, in: app)
        try requireActiveCatchUp(app, stage: "before-opening-message")
        snapshot("open-message-during-catch-up-before", app)
        guard row.exists, row.isEnabled, row.isHittable else {
            throw Failure.missing("hittable message row during catch-up")
        }
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let started = ProcessInfo.processInfo.systemUptime
        row.tap()
        let tapReturned = ProcessInfo.processInfo.systemUptime
        let detailAppeared = app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5)
        let observed = ProcessInfo.processInfo.systemUptime
        attach("started_at=\(startedAt) tap_return_seconds=\(tapReturned - started) " +
               "detail_observation_seconds=\(observed - tapReturned) detail_exists=\(detailAppeared)",
               named: "message-opening-timing")
        guard detailAppeared else {
            snapshot("detail-missing-during-catch-up", app)
            throw Failure.missing("message detail during catch-up")
        }
        try requireActiveCatchUp(app, stage: "after-opening-message")
        snapshot("detail-open-during-catch-up", app)
    }

    /// The isolated relay must keep real post-ACK conversation replay open.
    /// This driver never toggles a fake refreshing flag or enrolls a device.
    func testSearchBothSwipesAndChatDuringPostAckCatchUp() throws {
        try requireCatchUpRun()
        let message = try configuredMessage("SEEN")
        let app = launchEnrolledApp()
        let row = try findMessage(message, in: app)
        try requireActiveCatchUp(app, stage: "after-search")
        for left in [true, false] {
            let edge = left ? "left" : "right"
            try requireActiveCatchUp(app, stage: "before-" + edge)
            if left { row.swipeLeft() } else { row.swipeRight() }
            snapshot("catch-up-" + edge + "-menu", app)
            let action = app.buttons["inbox-mark-seen"]
            guard action.waitForExistence(timeout: 5), action.isEnabled, action.isHittable else {
                throw Failure.missing(edge + " Seen menu during catch-up")
            }
            try requireActiveCatchUp(app, stage: "after-" + edge)
            try tap(row, stage: edge + "-dismiss-menu", in: app)
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: action)
            guard XCTWaiter.wait(for: [closed], timeout: 5) == .completed else {
                throw Failure.missing(edge + " menu dismissal")
            }
        }
        try openMessage(message, in: app)
        try requireActiveCatchUp(app, stage: "before-chat")
        try tap(app.buttons["Chat"], stage: "open-chat-during-catch-up", in: app)
        guard app.textViews["sample-chat-composer"].waitForExistence(timeout: 5) else {
            throw Failure.missing("chat composer during catch-up")
        }
        snapshot("chat-open-during-catch-up", app)
    }

    func testSeenShowsPendingDuringPostAckCatchUp() throws {
        try requireCatchUpRun()
        let message = try configuredMessage("SEEN")
        let app = launchEnrolledApp()
        try openMessage(message, in: app)
        try requireActiveCatchUp(app, stage: "before-Seen")
        try tap(app.buttons["request-seen-action"], stage: "Seen-once-during-catch-up", in: app)
        try openRepliedMessage(message, in: app)
        try requireActiveCatchUp(app, stage: "after-Seen")
        let seen = app.buttons["request-finish-seen"]
        guard seen.waitForExistence(timeout: 5), (seen.value as? String) == "Pending" else {
            snapshot("missing-Seen-pending", app)
            throw Failure.missing("Seen pending confirmation during catch-up")
        }
        snapshot("Seen-pending-during-catch-up", app)
    }

    func testReplyShowsPendingTextDuringPostAckCatchUp() throws {
        try requireCatchUpRun()
        let message = try configuredMessage("REPLY")
        guard let reply = ProcessInfo.processInfo.environment["HARKLIGHT_DIAGNOSTIC_REPLY_TEXT"], !reply.isEmpty else {
            throw Failure.missing("synthetic reply configuration")
        }
        let app = launchEnrolledApp()
        try openMessage(message, in: app)
        try tap(app.buttons["Reply"], stage: "reply-choice", in: app)
        let editor = app.textViews["request-compatibility-reply-response"]
        try tap(editor, stage: "reply-editor", in: app)
        editor.typeText(reply)
        try requireActiveCatchUp(app, stage: "before-Reply")
        try tap(app.buttons["request-finish"], stage: "Reply-once-during-catch-up", in: app)
        try openRepliedMessage(message, in: app)
        try requireActiveCatchUp(app, stage: "after-Reply")
        guard app.descendants(matching: .any)["request-pending-answer-status"].firstMatch
                .waitForExistence(timeout: 5), app.staticTexts[reply].exists else {
            snapshot("missing-Reply-pending", app)
            throw Failure.missing("pending exact reply during catch-up")
        }
        snapshot("Reply-pending-during-catch-up", app)
    }

    /// One disposable chat send; the holder supplies the expected reply. Keep
    /// this same panel open through pending display and both Server turns.
    func testChatUpdatesWithoutReopeningDuringCatchUp() throws {
        try requireCatchUpRun()
        let message = try configuredMessage("CHAT")
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["HARKLIGHT_DIAGNOSTIC_CHAT_TEXT"], !text.isEmpty,
              let reply = environment["HARKLIGHT_DIAGNOSTIC_CHAT_EXPECTED_REPLY"], !reply.isEmpty else {
            throw Failure.missing("reserved synthetic chat text and expected agent reply")
        }
        let app = launchEnrolledApp()
        defer { collectJournal(app) }
        try openMessage(message, in: app)
        try tap(app.buttons["Chat"], stage: "open-chat-once", in: app)
        let editor = app.descendants(matching: .any)["sample-chat-input-surface"].firstMatch.textViews.firstMatch
        try tap(editor, stage: "chat-editor", in: app)
        editor.typeText(text)
        try requireActiveCatchUp(app, stage: "before-chat-send")
        attach("submit_time=" + ISO8601DateFormatter().string(from: Date()), named: "chat-send-time")
        try tap(app.buttons["sample-chat-send"], stage: "chat-send-once", in: app)
        let history = app.scrollViews["conversation-history-scroll"]
        guard history.staticTexts[text].firstMatch.waitForExistence(timeout: 5) else {
            snapshot("chat-own-text-missing", app)
            throw Failure.missing("own submitted text in the open transcript")
        }
        snapshot("chat-own-text-visible", app)
        guard history.staticTexts[reply].firstMatch.waitForExistence(timeout: observationTimeout) else {
            snapshot("chat-agent-reply-missing", app)
            throw Failure.missing("live agent reply without reopening chat")
        }
        let serverTurns = history.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "conversation-turn-"))
        guard serverTurns.containing(.staticText, identifier: text).firstMatch.exists else {
            snapshot("chat-own-server-turn-missing", app)
            throw Failure.missing("own Server-backed turn without reopening chat")
        }
        snapshot("chat-own-and-agent-turns-live", app)
    }

    private func requireCatchUpRun() throws {
        guard ProcessInfo.processInfo.environment["HARKLIGHT_ACTIVE_CATCHUP_UI"] == "1" else {
            throw XCTSkip("Requires observed active catch-up on the isolated Server and dedicated action rows.")
        }
    }

    private func requireActiveCatchUp(_ app: XCUIApplication, stage: String) throws {
        let probe = app.descendants(matching: .any)["inbox-catch-up-diagnostics"].firstMatch
        guard probe.waitForExistence(timeout: observationTimeout),
              probe.label.contains("source=live"), probe.label.contains("post_ack_drain=running") else {
            snapshot("catch-up-not-active-" + stage, app)
            throw Failure.missing("actual post-ACK catch-up at " + stage)
        }
        attach(probe.label, named: "active-catch-up-" + stage)
    }

    func testBothRowSwipesThenSeen() throws {
        let message = try configuredMessage("SEEN")
        let app = launchEnrolledApp()
        defer { collectJournal(app) }
        let row = try findMessage(message, in: app)
        for left in [true, false] {
            let edge = left ? "left" : "right"
            snapshot("before-" + edge + "-swipe", app)
            if left { row.swipeLeft() } else { row.swipeRight() }
            snapshot("after-" + edge + "-swipe", app)
            let action = app.buttons["inbox-mark-seen"]
            guard action.waitForExistence(timeout: 5), action.isEnabled, action.isHittable else {
                throw Failure.missing(edge + " Seen menu")
            }
            // Closing the revealed menu consumes a row tap. Navigation is a
            // separate tap after the menu actually disappears.
            try tap(row, stage: edge + "-dismiss-menu", in: app)
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: action)
            guard XCTWaiter.wait(for: [closed], timeout: 5) == .completed else {
                throw Failure.missing(edge + " menu dismissal")
            }
        }
        try openMessage(message, in: app)
        try tap(app.buttons["request-seen-action"], stage: "seen-submit", in: app)
        try openRepliedMessage(message, in: app)
        guard app.descendants(matching: .any)["request-seen-confirmation"].firstMatch
                .waitForExistence(timeout: observationTimeout) else {
            snapshot("seen-unconfirmed", app)
            throw Failure.missing("server-confirmed Seen")
        }
        snapshot("seen-confirmed", app)
    }

    func testReplyThroughVisibleSend() throws {
        let message = try configuredMessage("REPLY")
        guard let reply = ProcessInfo.processInfo.environment["HARKLIGHT_DIAGNOSTIC_REPLY_TEXT"], !reply.isEmpty else {
            throw Failure.missing("synthetic reply configuration")
        }
        let app = launchEnrolledApp()
        defer { collectJournal(app) }
        try openMessage(message, in: app)
        try tap(app.buttons["Reply"], stage: "reply-choice", in: app)
        let editor = app.textViews["request-compatibility-reply-response"]
        try tap(editor, stage: "reply-editor", in: app)
        editor.typeText(reply)
        attach(reply, named: "synthetic-reply-for-server-correlation")
        try tap(app.buttons["request-finish"], stage: "reply-send", in: app)
        try openRepliedMessage(message, in: app)
        guard app.descendants(matching: .any)["request-answered"].firstMatch
                .waitForExistence(timeout: observationTimeout), app.staticTexts[reply].exists else {
            snapshot("reply-unconfirmed", app)
            throw Failure.missing("server-confirmed exact reply")
        }
        snapshot("reply-confirmed", app)
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
        continueAfterFailure = false
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
                           "inbox-list-diagnostics", "request-delivery-warning",
                           "request-action-error", "request-action-unavailable",
                           "conversation-ui-diagnostics", "conversation-history-diagnostics"] {
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
            print("DIAGNOSTIC_OBSERVATION_LIMIT settings_unreachable")
            return
        }
        settings.tap()
        let share = app.buttons["client-diagnostics-share"]
        guard share.waitForExistence(timeout: 5), share.isHittable else {
            snapshot("journal-unavailable", app)
            print("DIAGNOSTIC_OBSERVATION_LIMIT journal_unavailable")
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
            print("DIAGNOSTIC_OBSERVATION_LIMIT complete_journal_copy_unavailable")
            return
        }
        let previousChange = UIPasteboard.general.changeCount
        copy.tap()
        guard UIPasteboard.general.changeCount != previousChange,
              let journal = UIPasteboard.general.string,
              journal.hasPrefix("Harklight client diagnostics"), journal.contains("format_version=1") else {
            print("DIAGNOSTIC_OBSERVATION_LIMIT copied_journal_inaccessible")
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
