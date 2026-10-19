import XCTest

@MainActor
final class ConversationSampleUITests: XCTestCase {
    func testOrdinaryConversationSharesAdaptivePanelWithoutLiveServices() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.buttons["request-row-sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()
        let composers = app.textFields.matching(identifier: "sample-chat-composer")
        XCTAssertTrue(composers.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(composers.count, 1)
        XCTAssertTrue(app.staticTexts["Could you explain the tradeoff?"].exists,
                      "Ordinary request chat must project its domain history")
        XCTAssertTrue(app.staticTexts["Agent"].waitForExistence(timeout: 5),
                      "An agent-authored answer must keep its distinct author in the ordinary conversation view")
        XCTAssertTrue(app.staticTexts["Agent example: the shorter path is faster, while the longer path is easier to revise."].exists)
        XCTAssertTrue(app.buttons["Add sample attachment"].isHittable)
        capture("ordinary-conversation-agent-answer", app)
        capture("ordinary-conversation-portrait", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let singleComposer = expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: composers)
        wait(for: [singleComposer], timeout: 5)
        XCTAssertTrue(app.buttons["Add sample attachment"].isHittable)
        capture("ordinary-conversation-landscape", app)
        XCUIDevice.shared.orientation = .portrait
    }

    func testAcceptedSenderUpdateIsVisibleInTheSameOrdinaryRequestAndHistory() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Archive", in: app)
        let row = app.buttons["request-row-sample-approval-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Updated"))
        row.tap()
        XCTAssertTrue(app.staticTexts["request-update-fact"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["request-update-fact"].label, "Updated · version 2")
        capture("sender-updated-current-request", app)
        app.buttons["Chat"].tap()
        XCTAssertTrue(app.staticTexts["Updated"].waitForExistence(timeout: 5))
        app.buttons["conversation-revision-picker"].tap()
        app.buttons["Version 1 · draft"].tap()
        app.buttons["conversation-earlier-answer"].tap()
        XCTAssertTrue(app.staticTexts["Not delivered · this selection belongs to the earlier question"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "The new collection is ready. Choose what happens to the earlier sketches."
        )).firstMatch.waitForExistence(timeout: 5))
        capture("sender-updated-earlier-question-and-draft", app)
    }

    func testMixedCleanupRetainsUnidentifiedFilesWithoutInventedCommittedHistory() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("welcome", in: app)
        let row = app.buttons["request-row-sample-review-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["Chat"].tap()
        let composer = app.textFields["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Keep the original mixed-result note.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@",
            "Some upload references are committed. Individual file status awaits synchronized history; retained draft references are not ready to resend.")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Unidentified example.txt"].exists)
        XCTAssertTrue(app.staticTexts["Not ready · reselect after cleanup"].exists)
        XCTAssertFalse(app.buttons["Send locally"].isEnabled)
        XCTAssertFalse(app.staticTexts["Committed file references remain available in history. This result does not identify individual files."].exists)
        capture("mixed-cleanup-retained-unidentified-reference", app)
    }

    func testCompactBackLeavesMessageButClosingChatDoesNotAbandonItsUpload() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("welcome", in: app)
        let row = app.buttons["request-row-sample-review-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["Chat"].tap()
        let composer = app.textFields["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["conversation-upload-cleanup-status"].exists)
        app.buttons["Close"].tap()
        app.buttons["Chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["conversation-upload-cleanup-status"].exists, "Closing chat alone does not leave its message")
        app.buttons["Close"].tap()
        let back = app.buttons["harklight-detail-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["Chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Keep this file note.")
        XCTAssertTrue(app.staticTexts["Upload cleanup unconfirmed. Retry cleanup before reselecting files; your text draft is retained."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send locally"].isEnabled)
        capture("compact-back-upload-cleanup-retained-draft", app)
    }

    func testNavigationKeepsUnsubmittedUploadCleanupTruthfulAcrossAdaptiveRebuild() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-ui-diagnostics"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("welcome", in: app)
        let row = app.buttons["request-row-sample-review-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["Chat"].tap()
        let composer = app.textFields["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Keep this file note.")
        XCTAssertFalse(app.otherElements["conversation-upload-cleanup-status"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["conversation-upload-cleanup-status"].exists, "Adaptive reconstruction is not message departure")
        capture("upload-before-message-departure", app)
        app.buttons["Close"].tap()
        showInbox(app)
        let other = app.buttons["request-row-sample-review-0"]
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        guard reveal(other, in: app.scrollViews.firstMatch, app: app) else { return }
        other.tap()
        // In a regular-width split view the sidebar rows expose these titles too,
        // so only the detail card can show that the selection changed.
        let detail = app.scrollViews["message-card-scroll"]
        let departed = detail.staticTexts["Review the studio welcome text"].waitForExistence(timeout: 5)
        recordDiagnostics("after-departure", app)
        XCTAssertTrue(departed, "Selecting another row must change the detail identity before cleanup is assessed")
        showInbox(app)
        guard reveal(row, in: app.scrollViews.firstMatch, app: app) else { return }
        row.tap()
        let returned = detail.staticTexts["Review the library welcome text"].waitForExistence(timeout: 5)
        recordDiagnostics("after-return", app)
        XCTAssertTrue(returned, "Returning to the original row must restore its exact detail identity")
        app.buttons["Chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let cleanupShown = app.staticTexts["Upload cleanup unconfirmed. Retry cleanup before reselecting files; your text draft is retained."].waitForExistence(timeout: 5)
        recordDiagnostics("after-return-chat", app)
        XCTAssertTrue(cleanupShown)
        XCTAssertEqual(composer.value as? String, "Keep this file note.")
        XCTAssertFalse(app.buttons["Send locally"].isEnabled)
        XCTAssertTrue(app.staticTexts["Not ready · reselect after cleanup"].exists)
        XCTAssertTrue(app.staticTexts["Local example · cleanup is unconfirmed; no service is contacted."].exists)
        capture("upload-return-unconfirmed-no-resend", app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Keep this file note.")
        XCTAssertFalse(app.buttons["Send locally"].isEnabled)
        capture("upload-cleanup-portrait-retained-draft", app)
    }

    func testBackAfterSwitchingMessagesShowsTheLastViewedMessage() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-ui-diagnostics"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        let list = app.scrollViews.firstMatch
        // The information, warning, error and note examples are short cards, so a pull past
        // their end moves between them. Open the first one while the last one is out of view.
        let opened = app.buttons["request-row-sample-information-1"]
        let lastViewed = app.buttons["request-row-sample-note-1"]
        XCTAssertTrue(app.buttons["request-row-sample-information-2"].waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<30 where !unobscured(opened, in: list, app: app) {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -150)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(unobscured(opened, in: list, app: app), app.debugDescription)
        XCTAssertFalse(unobscured(lastViewed, in: list, app: app),
                       "The last-viewed message must start outside the visible list so Back has to bring it into view.")
        opened.tap()
        let card = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        let counter = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+ of [0-9]+'")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<3 {
            guard showNextMessage(card: card, counter: counter, app: app) else { return }
        }
        recordDiagnostics("after-switching", app)
        let probe = app.descendants(matching: .any)["inbox-ui-diagnostics"].firstMatch
        XCTAssertTrue(probe.label.contains("lastViewed=request:sample-note-1 "), probe.label)
        let back = app.buttons["harklight-detail-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        let shown = NSPredicate { _, _ in lastViewed.exists && self.unobscured(lastViewed, in: list, app: app) }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 5)
        recordDiagnostics("after-back", app)
        XCTAssertEqual(result, .completed, "Back after switching messages must show the last-viewed message: \(app.debugDescription)")
    }

    func testRetractedItemKeepsItsSelectedChoiceHistoryAndUnsentDiscussion() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Archive", in: app)
        let row = app.buttons["request-row-sample-approval-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Retracted"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The sender retracted this request. Saved work and its original delivery status are retained; no further answer will be sent."].exists)
        capture("sender-retracted-retained-request", app)
        app.buttons["Chat"].tap()
        let composer = app.textFields["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Please keep this unsent note.")
        XCTAssertFalse(composer.isEnabled)
        XCTAssertFalse(app.buttons["Send locally"].isEnabled)
        app.buttons["conversation-earlier-answer"].tap()
        XCTAssertTrue(app.staticTexts["Saved answer · request retracted. Its original wording and choices are retained."].waitForExistence(timeout: 5))
        let savedChoice = app.buttons.matching(NSPredicate(format: "label == %@", "Archive")).firstMatch
        XCTAssertTrue(savedChoice.exists)
        XCTAssertEqual(savedChoice.value as? String, "Selected")
        capture("sender-retracted-history-and-unsent-note", app)
    }

    func testConversationRevisionFileFactsAndClosureUseTheOrdinaryApp() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        func open(_ id: String, search: String) {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
            enterSearch(search, in: app)
            let row = app.buttons["request-row-" + id]
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            row.tap()
            app.buttons["Chat"].tap()
            XCTAssertTrue(app.textFields["sample-chat-composer"].waitForExistence(timeout: 5))
        }
        open("sample-approval-2", search: "Archive")
        XCTAssertTrue(app.staticTexts["Please review the sketches before archiving. The earlier answer draft is retained."].exists)
        capture("conversation-current-revision", app)
        let picker = app.buttons["conversation-revision-picker"]
        XCTAssertTrue(picker.exists, app.debugDescription)
        picker.tap()
        app.buttons["Version 1 · draft"].tap()
        app.buttons["conversation-earlier-answer"].tap()
        XCTAssertTrue(app.staticTexts["Not delivered · this selection belongs to the earlier question"].waitForExistence(timeout: 5))
        capture("conversation-archived-answer", app)
        open("sample-information-2", search: "Thursday")
        XCTAssertTrue(app.staticTexts["Example · Exact bytes transferred"].exists)
        XCTAssertTrue(app.staticTexts["Example · Agent reported unusable: Fictional unsupported format"].exists)
        capture("conversation-distinct-file-facts", app)
        app.buttons["example.txt"].tap()
        XCTAssertTrue(app.staticTexts["Original bytes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Open file"].exists, "Local examples cannot fetch from a real service")
        capture("conversation-file-metadata", app)
        open("sample-completed-2", search: "journal is ready")
        XCTAssertTrue(app.staticTexts["Request cleared"].exists)
        XCTAssertFalse(app.textFields["sample-chat-composer"].isEnabled)
        XCTAssertFalse(app.buttons["Send locally"].isEnabled)
        capture("conversation-explicit-closure", app)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Reads the app's diagnostics probes (enabled by `--harklight-ui-diagnostics`)
    /// and keeps them with the result, so a failure carries its view and store state.
    private func recordDiagnostics(_ step: String, _ app: XCUIApplication) {
        let probes = ["inbox-ui-diagnostics", "inbox-list-diagnostics", "conversation-ui-diagnostics"]
        let text = probes.compactMap { id -> String? in
            let probe = app.descendants(matching: .any)[id].firstMatch
            return probe.exists ? "\(id): \(probe.label)" : nil
        }.joined(separator: "\n")
        print("E2_DIAG \(step)\n\(text.isEmpty ? "no probes" : text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "diagnostics-\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func enterSearch(_ query: String, in app: XCUIApplication) {
        let dismiss = app.buttons["inbox-search-dismiss"]
        if dismiss.exists && dismiss.isHittable { dismiss.tap() }
        let field = app.textFields["inbox-search-field"]
        if !field.exists {
            let button = app.buttons["inbox-search-button"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
            button.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText(query + "\n")
    }

    private func showInbox(_ app: XCUIApplication) {
        let searchButton = app.buttons["inbox-search-button"]
        let searchField = app.textFields["inbox-search-field"]
        guard !searchButton.exists && !searchField.exists else { return }
        let back = app.buttons["harklight-detail-back"]
        if back.exists && back.isHittable {
            back.tap()
        } else {
            let sidebar = app.buttons["Show Sidebar"]
            if sidebar.exists && sidebar.isHittable { sidebar.tap() }
        }
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5) || searchField.waitForExistence(timeout: 5),
                      app.debugDescription)
    }

    /// Pulls past the end of the open message until the next one opens.
    private func showNextMessage(card: XCUIElement, counter: XCUIElement, app: XCUIApplication) -> Bool {
        let before = counter.label
        let lower = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        for _ in 0..<8 {
            lower.press(forDuration: 0.1, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0.5)
            let moved = NSPredicate { _, _ in counter.exists && counter.label != before }
            if XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 2) == .completed {
                return true
            }
        }
        XCTFail("Pulling past the end of message \(before) did not open the next message: \(app.debugDescription)")
        return false
    }

    /// Whether the whole row is inside the list, above its bottom tab and search controls.
    private func unobscured(_ element: XCUIElement, in scrollView: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let controls = [app.textFields["inbox-search-field"], app.otherElements["inbox-message-tabs"],
                        app.buttons["inbox-search-button"]].filter(\.exists).map(\.frame.minY)
        let bottom = controls.min() ?? app.windows.firstMatch.frame.maxY
        let frame = element.frame
        return element.isHittable && frame.minY >= scrollView.frame.minY && frame.maxY <= bottom
    }

    /// Scrolls until the whole row is inside the visible list. Returns false after
    /// a recorded failure so the caller does not tap a row the controls cover.
    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("Row does not exist: \(app.debugDescription)")
            return false
        }
        // A row partly under the bottom search controls can be hittable while its
        // tap point lands on them, so require the whole row inside the visible list.
        func unobscured() -> Bool {
            let search = app.textFields["inbox-search-field"]
            let bottom = search.exists ? search.frame.minY : app.windows.firstMatch.frame.maxY
            let frame = element.frame
            return element.isHittable && frame.minY >= scrollView.frame.minY && frame.maxY <= bottom
        }
        for _ in 0..<8 {
            if unobscured() { return true }
            if element.frame.midY < scrollView.frame.midY { scrollView.swipeDown() } else { scrollView.swipeUp() }
        }
        if unobscured() { return true }
        XCTFail("Row stayed outside the unobscured list after scrolling: \(app.debugDescription)")
        return false
    }
}
