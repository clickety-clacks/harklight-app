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
        XCTAssertTrue(app.staticTexts["The new collection is ready. Choose what happens to the earlier sketches."].exists)
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
        let back = app.navigationBars.buttons.firstMatch
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
        let other = app.buttons["request-row-sample-review-0"]
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        row.tap()
        XCTAssertTrue(app.staticTexts["Upload cleanup unconfirmed. Retry cleanup before reselecting files; your text draft is retained."].waitForExistence(timeout: 5))
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

    func testRetractedItemKeepsItsSelectedChoiceHistoryAndUnsentDiscussion() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Archive", in: app)
        let row = app.buttons["request-row-sample-approval-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Retracted"))
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
        let savedChoice = app.buttons.containing(.staticText, identifier: "Archive").firstMatch
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
}
