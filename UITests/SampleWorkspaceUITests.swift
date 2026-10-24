import XCTest

@MainActor
final class SampleWorkspaceUITests: XCTestCase {
    override func setUpWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testOrdinaryInboxKeepsRequestsWhenExamplesAreAdded() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()
        let realRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'request-row-'"))
        XCTAssertTrue(realRows.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let original = app.descendants(matching: .any)["request-row-review-01"]
        XCTAssertTrue(original.waitForExistence(timeout: 5), app.debugDescription)
        let originalID = original.identifier
        capture("ordinary-inbox-before-shake", app)
        original.tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5))
        let originalChoice = app.buttons["Cover A"]
        XCTAssertTrue(originalChoice.waitForExistence(timeout: 5), app.debugDescription)
        originalChoice.tap()
        XCTAssertTrue(originalChoice.isSelected)
        capture("ordinary-request-card", app)
        showList(app)
        let inboxTab = workspaceTab("Inbox", in: app)
        let repliedTab = workspaceTab("Replied", in: app)
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(original.exists,
                      "An unsent choice remains in Inbox.")
        repliedTab.tap()
        XCTAssertFalse(original.waitForExistence(timeout: 1),
                       "An unsent choice does not appear in Replied.")
        inboxTab.tap()
        original.tap()
        XCTAssertTrue(app.buttons["Cover A"].isSelected,
                      "The unsent choice survives leaving the detail.")
        let finish = app.buttons["request-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(finish.isEnabled, app.debugDescription)
        finish.tap()
        XCTAssertTrue(app.staticTexts["request-lifecycle-status"].waitForExistence(timeout: 5),
                      "A saved answer moves only after it is submitted.")
        showList(app)
        XCTAssertTrue(inboxTab.isSelected,
                      "Submitting an Inbox response keeps the Inbox tab selected.")
        XCTAssertFalse(original.waitForExistence(timeout: 2),
                       "A submitted response leaves the Inbox list.")
        capture("choice-response-leaves-inbox-selected", app)
        repliedTab.tap()
        XCTAssertTrue(repliedTab.isSelected, app.debugDescription)
        XCTAssertTrue(original.waitForExistence(timeout: 5),
                      "A submitted answer appears in Replied after the user switches tabs.")
        capture("choice-response-in-replied", app)
        app.buttons["inbox-settings"].tap()
        app.buttons["Add example messages"].tap()
        let row = app.descendants(matching: .any)["sample-approval-0"]
        // Examples remain in Inbox, so leave the submitted request's Replied tab first.
        workspaceTab("Inbox", in: app).tap()
        enterSearch("Archive", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture("ordinary-inbox-with-examples", app)
        row.tap()
        let keep = app.buttons.containing(.staticText, identifier: "Keep here").firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        app.descendants(matching: .any)["sample-finish"].tap()
        XCTAssertTrue(app.staticTexts["Answered locally · nothing sent"].waitForExistence(timeout: 5))
        capture("ordinary-example-card", app)
        showList(app)
        clearSearch(in: app)
        selectMessageTab("Replied", in: app)
        XCTAssertTrue(original.exists, app.debugDescription)
        original.tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cover A"].isSelected, "An ordinary draft survives local example actions")
        capture("ordinary-request-after-example", app)
    }

    func testNoCommentIsAnUnsentLastChoiceOnMultipleChoiceRequest() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))

        let row = app.descendants(matching: .any)["request-row-review-01"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        let answerScroll = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(answerScroll.waitForExistence(timeout: 5), app.debugDescription)
        let noComment = app.buttons["request-no-comment"]
        XCTAssertTrue(noComment.waitForExistence(timeout: 5), app.debugDescription)
        answerScroll.swipeUp()
        let lastOrdinaryChoice = app.buttons["Send a note"]
        XCTAssertTrue(lastOrdinaryChoice.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThan(noComment.frame.minY, lastOrdinaryChoice.frame.maxY,
                             "No comment follows every ordinary multiple-choice answer.")
        capture("multiple-choice-no-comment-last", app)

        noComment.tap()
        XCTAssertTrue(noComment.isSelected, "No comment is selected as an ordinary answer.")
        XCTAssertFalse(app.staticTexts["request-receipt-evidence"].exists,
                       "Selecting No comment does not send it.")
        capture("multiple-choice-no-comment-selected-unsent", app)
        showList(app)
        XCTAssertTrue(workspaceTab("Inbox", in: app).isSelected)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The unsent No comment selection remains in Inbox.")
        let repliedTab = workspaceTab("Replied", in: app)
        repliedTab.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 1),
                       "The unsent No comment selection does not appear in Replied.")
        workspaceTab("Inbox", in: app).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.buttons["request-no-comment"].isSelected,
                      "The No comment selection survives leaving the detail.")
        let submit = app.buttons["request-finish"]
        XCTAssertTrue(submit.isEnabled, app.debugDescription)
        submit.tap()
        showList(app)
        XCTAssertTrue(workspaceTab("Inbox", in: app).isSelected,
                      "Submitting No comment keeps the Inbox tab selected.")
        XCTAssertFalse(row.waitForExistence(timeout: 2),
                       "The submitted No comment leaves the Inbox list.")
        capture("no-comment-response-leaves-inbox-selected", app)
        XCTAssertTrue(repliedTab.waitForExistence(timeout: 5), app.debugDescription)
        selectMessageTab("Replied", in: app)
        XCTAssertTrue(repliedTab.isSelected,
                      "Only the user's tab change moves from Inbox to Replied.")
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The submitted No comment appears in Replied.")
        capture("no-comment-response-in-replied", app)
        row.swipeLeft()
        XCTAssertFalse(app.buttons["inbox-no-comment"].exists,
                       "Replied rows have no swipe action.")
    }

    private func selectMessageTab(_ title: String, in app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let closeSearch = app.buttons["Close"]
        if closeSearch.exists { closeSearch.tap() }

        let destination = workspaceTab(title, in: app)
        XCTAssertTrue(destination.waitForExistence(timeout: 5), app.debugDescription,
                      file: file, line: line)
        if !destination.isSelected { destination.tap() }
    }

    private func assertListSearchAvailable(_ app: XCUIApplication, file: StaticString = #filePath,
                                        line: UInt = #line) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      app.debugDescription, file: file, line: line)
    }

    private func showList(_ app: XCUIApplication) {
        let card = app.scrollViews["message-card-scroll"]
        guard card.exists else { return }
        let searchField = app.searchFields.firstMatch
        let back = app.navigationBars.buttons.firstMatch
        if back.exists && back.isHittable {
            back.tap()
        } else {
            let sidebar = app.buttons["Show Sidebar"]
            if sidebar.exists && sidebar.isHittable { sidebar.tap() }
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      app.debugDescription)
    }

    private func enterSearch(_ query: String, in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        let clearText = field.buttons["Clear text"]
        if clearText.exists && clearText.isHittable { clearText.tap() }
        field.tap()
        field.typeText(query + "\n")
    }

    private func clearSearch(in app: XCUIApplication) {
        let clearText = app.searchFields.firstMatch.buttons["Clear text"]
        if clearText.exists && clearText.isHittable { clearText.tap() }
    }

    private func seenSwipeAction(in app: XCUIApplication) -> XCUIElement? {
        let action = app.buttons["inbox-mark-seen"]
        return action.exists ? action : nil
    }

    func testAnswerRequestSwipeOffersNoComment() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))

        enterSearch("Archive", in: app)
        let ordinary = app.descendants(matching: .any)["sample-approval-0"]
        XCTAssertTrue(ordinary.waitForExistence(timeout: 5), app.debugDescription)
        ordinary.swipeLeft()
        let noComment = app.buttons["inbox-no-comment"]
        XCTAssertTrue(noComment.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(noComment.label, "No comment")
        capture("inbox-swipe-no-comment-revealed", app)
        noComment.tap()
        XCTAssertFalse(ordinary.waitForExistence(timeout: 5),
                       "The row action sends No comment and removes the request from Inbox.")

        clearSearch(in: app)
        enterSearch("Which approach", in: app)
        let replyOnly = app.descendants(matching: .any)["sample-textChoice-0"]
        XCTAssertTrue(replyOnly.waitForExistence(timeout: 5), app.debugDescription)
        replyOnly.swipeRight()
        XCTAssertTrue(noComment.waitForExistence(timeout: 5),
                      "The same No comment action is available from the opposite swipe edge.")
        XCTAssertEqual(noComment.label, "No comment")
        capture("inbox-swipe-no-comment-opposite-edge", app)
    }

    func testNoCommentIsAvailableForReplyOnlyRequests() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))

        enterSearch("A note for", in: app)
        let row = app.descendants(matching: .any)["sample-note-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        let noComment = app.buttons["request-no-comment"]
        XCTAssertTrue(noComment.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(noComment.isEnabled, app.debugDescription)
        XCTAssertFalse(noComment.isSelected, app.debugDescription)
        let replyChoice = app.buttons["Reply"]
        XCTAssertTrue(replyChoice.exists, "A text-only request offers its Reply choice.")
        XCTAssertGreaterThan(noComment.frame.minY, replyChoice.frame.maxY,
                             "No comment is listed after the Reply choice.")
        replyChoice.tap()
        let replyEditor = app.descendants(matching: .any)["request-compatibility-reply-response"]
        XCTAssertTrue(replyEditor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Selecting a text-only Reply focuses its embedded editor.")
        replyEditor.typeText("Draft stays saved.")
        XCTAssertEqual(replyEditor.value as? String, "Draft stays saved.")
        XCTAssertGreaterThan(noComment.frame.minY, replyEditor.frame.maxY,
                             "No comment stays after the expanded Reply editor.")
        XCTAssertTrue(noComment.isHittable,
                      "The keyboard does not obscure the No comment action.")
        capture("reply-only-no-comment-available", app)

        noComment.tap()
        XCTAssertTrue(noComment.isSelected, "No comment is selected as an answer.")
        XCTAssertEqual(noComment.value as? String, "Selected")
        XCTAssertFalse(app.descendants(matching: .any)["request-local-no-comment-status"].exists,
                       "Selecting No comment does not submit it.")
        XCTAssertEqual(replyEditor.value as? String, "Draft stays saved.",
                       "The typed draft remains saved and unsent.")
        capture("reply-only-no-comment-selected", app)

        showList(app)
        clearSearch(in: app)
        let inboxTab = workspaceTab("Inbox", in: app)
        let repliedTab = workspaceTab("Replied", in: app)
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 5), app.debugDescription)
        assertListSearchAvailable(app)
        enterSearch("A note for", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        clearSearch(in: app)
        selectMessageTab("Replied", in: app)
        enterSearch("A note for", in: app)
        XCTAssertFalse(row.waitForExistence(timeout: 1),
                       "An unsent No comment selection does not appear in Replied.")
        clearSearch(in: app)
        selectMessageTab("Inbox", in: app)
        enterSearch("A note for", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.buttons["request-no-comment"].isSelected,
                      "The selected No comment answer survives leaving the detail.")
        app.buttons["sample-finish"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["request-local-no-comment-status"]
            .waitForExistence(timeout: 5), app.debugDescription)
        showList(app)
        clearSearch(in: app)
        assertListSearchAvailable(app)
        enterSearch("A note for", in: app)
        XCTAssertFalse(row.waitForExistence(timeout: 1),
                       "A submitted No comment leaves the Inbox.")
        clearSearch(in: app)
        selectMessageTab("Replied", in: app)
        enterSearch("A note for", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The submitted No comment appears in Replied.\n\(app.debugDescription)")
        row.swipeLeft()
        XCTAssertFalse(app.buttons["inbox-no-comment"].exists,
                       "Replied rows have no swipe action.")
    }

    func testRecoveryWarningUsesTitleRowPopoverAndPresentsOnce() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-test-recovery-status"]
        app.launch()
        let inbox = workspaceTab("Inbox", in: app)
        let replied = workspaceTab("Replied", in: app)
        let brand = app.descendants(matching: .any)["inbox-brand"]
        let warningButton = app.buttons["inbox-warning-button"]
        let settings = app.buttons["inbox-settings"]

        let message = app.staticTexts["inbox-warning-message"]
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sample-'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(message.label.contains("Could not verify notification"), message.label)
        XCTAssertTrue(inbox.isSelected, "Automatic warning presentation does not change the selected tab.")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Existing Inbox content remains visible.")
        capture("inbox-recovery-warning-popover", app)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.10)).tap()
        XCTAssertFalse(message.waitForExistence(timeout: 1),
                       "Tapping outside the stock popover dismisses it.")
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(warningButton.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(brand.exists, app.debugDescription)
        XCTAssertGreaterThanOrEqual(warningButton.frame.minX, brand.frame.maxX - 2,
                                    "The warning icon sits beside the Harklight title.")
        XCTAssertLessThan(warningButton.frame.midX, settings.frame.midX,
                          "The warning icon sits before Settings in the shared title row.")
        capture("inbox-recovery-warning-dismissed", app)
        selectMessageTab("Replied", in: app)
        XCTAssertTrue(replied.isSelected, app.debugDescription)
        XCTAssertFalse(message.waitForExistence(timeout: 1),
                       "The same warning does not reopen when switching lists.")
        selectMessageTab("Inbox", in: app)
        XCTAssertTrue(inbox.isSelected, app.debugDescription)
        XCTAssertFalse(message.waitForExistence(timeout: 1),
                       "Returning to Inbox does not auto-present the same warning again.")
        warningButton.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5),
                      "The warning icon still opens a persistent warning manually.")
    }

    func testUnsupportedNoCommentControlStaysVisibleAndCanBeRetried() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--test-no-comment-unsupported"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))

        enterSearch("A note for", in: app)
        let row = app.descendants(matching: .any)["sample-note-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()

        let noComment = app.buttons["request-no-comment"]
        XCTAssertTrue(noComment.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(noComment.isEnabled,
                      "An explicit No comment failure must leave the same choice available for retry.")
        let explanation = app.descendants(matching: .any)["request-no-comment-unavailable"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(explanation.label.contains("retry"), explanation.label)
        capture("reply-only-no-comment-retry", app)
    }

    func testSeenActionFromEitherSwipeEdgeMovesTheMessageToReplied() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))

        enterSearch("Thursday", in: app)
        let informational = app.descendants(matching: .any)["sample-information-0"]
        XCTAssertTrue(informational.waitForExistence(timeout: 5), app.debugDescription)
        informational.swipeLeft()
        let seenActionAppeared = NSPredicate { _, _ in
            self.seenSwipeAction(in: app) != nil
        }
        let actionExpectation = XCTNSPredicateExpectation(predicate: seenActionAppeared, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [actionExpectation], timeout: 5), .completed, app.debugDescription)
        guard let markSeen = seenSwipeAction(in: app) else {
            XCTFail(app.debugDescription)
            return
        }
        XCTAssertEqual(markSeen.label, "Seen")
        capture("inbox-swipe-seen-revealed", app)
        // Revealing the action does not mark the message.
        XCTAssertTrue(informational.exists, "Swiping alone leaves the message in Inbox")
        markSeen.tap()
        let leftInbox = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: informational)
        wait(for: [leftInbox], timeout: 5)
        clearSearch(in: app)

        let repliedTab = workspaceTab("Replied", in: app)
        selectMessageTab("Replied", in: app)
        XCTAssertTrue(informational.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(informational.label.contains("Seen selected locally"), informational.label)
        informational.swipeLeft()
        XCTAssertFalse(app.buttons["inbox-mark-seen"].exists,
                       "Replied rows have no Seen swipe action.")
        XCTAssertFalse(app.descendants(matching: .any)["sample-approval-0"].exists, "An untouched request remains in Inbox")
        capture("seen-message-in-replied-tab", app)

        workspaceTab("Inbox", in: app).tap()
        enterSearch("nearly full", in: app)
        let warning = app.descendants(matching: .any)["sample-warning-0"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5), app.debugDescription)
        warning.swipeRight()
        let rightEdgeSeen = NSPredicate { _, _ in self.seenSwipeAction(in: app) != nil }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: rightEdgeSeen, object: nil)],
                                        timeout: 5), .completed, app.debugDescription)
        XCTAssertEqual(seenSwipeAction(in: app)?.label, "Seen")
        seenSwipeAction(in: app)?.tap()
        XCTAssertFalse(warning.waitForExistence(timeout: 5),
                       "The same Seen action on the opposite edge moves the message out of Inbox.")
    }

    func testBodySeenActionKeepsSearchSelectedAndToolbarSeenAvailable() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()

        let bodySeen = app.buttons["request-seen-action"]
        let toolbarSeen = app.buttons["request-finish-seen"]
        XCTAssertTrue(bodySeen.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(toolbarSeen.exists, app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "request-seen-action").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "request-finish-seen").count, 1)
        capture("seen-detail-with-body-and-toolbar-actions", app)
        bodySeen.tap()
        capture("seen-response-detail", app)

        showList(app)
        assertListSearchAvailable(app)
        XCTAssertFalse(row.waitForExistence(timeout: 2),
                       "The Seen response leaves the current Inbox Search results.")
        capture("seen-response-leaves-search-results", app)
        selectMessageTab("Replied", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The Seen response appears in Replied after the user switches tabs.")
        capture("seen-response-in-replied", app)
    }

    func testReplyChoiceUsesFloatingComposerAndReopensAfterSending() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Which approach", in: app)
        let row = app.descendants(matching: .any)["sample-textChoice-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()

        let replyChoice = app.buttons.containing(.staticText, identifier: "Your own answer").firstMatch
        XCTAssertTrue(replyChoice.waitForExistence(timeout: 5), app.debugDescription)
        replyChoice.tap()
        let editor = app.textFields.matching(identifier: "request-input-answer-response").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Selecting Reply focuses its editor.")
        XCTAssertLessThanOrEqual(editor.frame.maxY, keyboard.frame.minY + 2,
                                 "The floating reply field sits above the keyboard.")
        editor.typeText("Keep the smaller first step.")
        let sendReply = app.buttons["request-reply-send"]
        XCTAssertTrue(sendReply.waitForExistence(timeout: 5), app.debugDescription)
        sendReply.tap()
        let collapsedReply = app.buttons["request-input-answer-reply-own"]
        XCTAssertTrue(collapsedReply.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(collapsedReply.label.contains("Keep the smaller first step."))
        capture("reply-choice-after-composer-send", app)

        showList(app)
        clearSearch(in: app)
        let inboxTab = workspaceTab("Inbox", in: app)
        let repliedTab = workspaceTab("Replied", in: app)
        assertListSearchAvailable(app)
        enterSearch("Which approach", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "A typed but unsent reply stays in Inbox.")
        clearSearch(in: app)
        selectMessageTab("Replied", in: app)
        enterSearch("Which approach", in: app)
        XCTAssertFalse(row.waitForExistence(timeout: 1),
                       "A typed but unsent reply does not appear in Replied.")
        clearSearch(in: app)
        selectMessageTab("Inbox", in: app)
        enterSearch("Which approach", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        let retainedSummary = app.buttons["request-input-answer-reply-own"]
        XCTAssertTrue(retainedSummary.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(editor.exists, "Returning to the request keeps the reply collapsed.")
        XCTAssertTrue(retainedSummary.label.contains("Keep the smaller first step."))

        retainedSummary.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(editor.value as? String, "Keep the smaller first step.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Tapping the selected choice reopens the editor.")
        XCTAssertLessThan(editor.frame.height, app.windows.firstMatch.frame.height * 0.15,
                          "A short reply stays compact before the field needs to grow.")
        capture("reply-editor-reopened", app)
        app.buttons["request-reply-send"].tap()
        XCTAssertTrue(retainedSummary.waitForExistence(timeout: 5))

        let otherChoice = app.buttons.containing(.staticText, identifier: "Start small").firstMatch
        XCTAssertTrue(otherChoice.waitForExistence(timeout: 5), app.debugDescription)
        otherChoice.tap()
        let ghostedReply = app.buttons["request-input-answer-reply-own"]
        XCTAssertTrue(ghostedReply.waitForExistence(timeout: 5), app.debugDescription)
        capture("reply-editor-deselected-with-draft", app)

        ghostedReply.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(editor.isEnabled, "Tapping the Reply card reselects it.")
        XCTAssertEqual(editor.value as? String, "Keep the smaller first step.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Reselecting Reply focuses its editor.")
        capture("reply-editor-reselected", app)
        app.buttons["request-reply-send"].tap()
        app.descendants(matching: .any)["sample-finish"].tap()
        capture("text-response-submitted", app)
        showList(app)
        assertListSearchAvailable(app)
        XCTAssertFalse(row.waitForExistence(timeout: 2),
                       "A submitted text reply leaves the current Inbox Search results.")
        capture("text-response-leaves-search-results", app)
        selectMessageTab("Replied", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The text response appears in Replied after the user switches tabs.")
        capture("text-response-in-replied", app)
    }

    func testReplyComposerGrowsAndScrollsWithinThirtyPercentOfScreenHeight() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Which approach", in: app)
        let row = app.descendants(matching: .any)["sample-textChoice-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()

        let replyChoice = app.buttons.containing(.staticText, identifier: "Your own answer").firstMatch
        XCTAssertTrue(replyChoice.waitForExistence(timeout: 5), app.debugDescription)
        replyChoice.tap()
        let editor = app.textFields["request-input-answer-response"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        let longDraft = (1...48).map { "Reply line \($0) keeps growing across the field." }
            .joined(separator: " ")
        editor.typeText(longDraft)
        capture("reply-composer-at-height-cap", app)

        let screenHeight = app.windows.firstMatch.frame.height
        let retainedText = editor.value as? String ?? ""
        XCTAssertTrue(retainedText.contains("Reply line 48"),
                      "The full reply remains available after the field reaches its cap.")
        XCTAssertGreaterThan(editor.frame.height, screenHeight * 0.2,
                             "The field expands as the reply grows.")
        XCTAssertLessThanOrEqual(editor.frame.height, screenHeight * 0.3 + 2,
                                 "The field stops at 30% of the screen and scrolls internally.")
    }

    func testDesignedControlsAndComponentScreenshots() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples", "--harklight-ui-diagnostics"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        let kinds = ["textChoice", "pictureChoice", "instructions", "review", "multipleChoice", "value", "point", "colorChoice", "soundChoice", "error", "warning", "information", "completed"]
        for kind in kinds {
            showList(app)
            clearSearch(in: app)
            let closeSearch = app.buttons["Close"]
            if closeSearch.exists && closeSearch.isHittable { closeSearch.tap() }
            let inboxTab = workspaceTab("Inbox", in: app)
            let repliedTab = workspaceTab("Replied", in: app)
            XCTAssertTrue(inboxTab.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(repliedTab.exists, app.debugDescription)
            if !inboxTab.isSelected { inboxTab.tap() }
            // Search the fictional sender/title so the selected type is reachable
            // through normal navigation without a test-only destination.
            let query: String = switch kind {
            case "textChoice": "Which approach"
            case "pictureChoice": "Which cover"
            case "instructions": "Prepare"
            case "review": "welcome"
            case "multipleChoice": "update go"
            case "value": "how long"
            case "point": "title go"
            case "colorChoice": "Accent"
            case "soundChoice": "sound"
            case "error": "could not"
            case "warning": "nearly full"
            case "information": "Thursday"
            default: "journal is ready"
            }
            enterSearch(query, in: app)
            let row = app.descendants(matching: .any)["sample-\(kind)-0"]
            let found = row.waitForExistence(timeout: 5)
            if kind == "review" || !found { recordDiagnostics("search-\(kind)", app) }
            XCTAssertTrue(found, app.debugDescription)
            if kind == "value" {
                clearSearch(in: app)
                inboxTab.tap()
                XCTAssertTrue(inboxTab.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertTrue(inboxTab.isSelected)
                repliedTab.tap()
                enterSearch(query, in: app)
                XCTAssertFalse(row.waitForExistence(timeout: 1),
                               "A prefilled but unsent reply stays in Inbox.")
                clearSearch(in: app)
                let closeSearchAfterReplied = app.buttons["Close"]
                if closeSearchAfterReplied.exists && closeSearchAfterReplied.isHittable {
                    closeSearchAfterReplied.tap()
                }
                inboxTab.tap()
                enterSearch(query, in: app)
                XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            }
            let listContainer = app.scrollViews.firstMatch.exists
                ? app.scrollViews.firstMatch : app.collectionViews.firstMatch
            XCTAssertTrue(listContainer.exists, app.debugDescription)
            reveal(row, in: listContainer, app: app)
            row.tap()
            if ["error", "warning", "information", "completed"].contains(kind) {
                XCTAssertTrue(app.buttons["request-seen-action"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["request-finish-seen"].exists)
                XCTAssertEqual(app.buttons.matching(identifier: "request-seen-action").count, 1)
                XCTAssertEqual(app.buttons.matching(identifier: "request-finish-seen").count, 1)
            } else {
                XCTAssertTrue(app.descendants(matching: .any)["sample-finish"].waitForExistence(timeout: 5))
            }
            capture("component-\(kind)", app)
            if ["textChoice", "review", "multipleChoice", "colorChoice", "soundChoice"].contains(kind) {
                let ownAnswer = app.buttons.containing(.staticText, identifier: "Your own answer").firstMatch
                reveal(ownAnswer, in: app.scrollViews["message-card-scroll"], app: app)
                ownAnswer.tap()
                let answer = app.textFields["request-input-answer-response"]
                XCTAssertTrue(answer.waitForExistence(timeout: 5))
                answer.tap()
                answer.typeText("Leave room for a quiet corner.")
                capture("component-own-answer-editing", app)
                app.buttons["request-reply-send"].tap()
                capture("component-own-answer-collapsed", app)
                app.descendants(matching: .any)["sample-finish"].tap()
            }
            if kind == "pictureChoice" {
                let card = app.scrollViews["message-card-scroll"]
                let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7))
                let end = card.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
                XCTAssertTrue(app.descendants(matching: .any)["sample-finish"].exists, "Ordinary scrolling retains this card")
                let picture = app.buttons.containing(.staticText, identifier: "Night sky").firstMatch
                picture.tap(); picture.tap()
                XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
                capture("component-picture-enlarged", app)
                app.buttons["Done"].tap()
            }
            if kind == "point" {
                let canvas = app.otherElements["sample-annotation-canvas"]
                XCTAssertTrue(canvas.waitForExistence(timeout: 5))
                canvas.tap()
                let note = app.textFields["Note for this spot"]
                XCTAssertTrue(note.waitForExistence(timeout: 5))
                note.tap(); note.typeText("Keep the title clear of the horizon.")
                capture("component-annotation", app)
            }
        }
        app.buttons["Chat"].tap()
        let composer = app.textFields["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Add sample attachment"].tap()
        let photo = app.buttons["Sample photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.isHittable, "The attachment choice must be usable above the keyboard")
        photo.tap()
        composer.tap(); composer.typeText("A local note with an example image.")
        capture("component-chat-composer", app)
        app.buttons["Send locally"].tap()
        XCTAssertTrue(app.staticTexts["A local note with an example image."].waitForExistence(timeout: 5))
        capture("component-chat-thread", app)
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

    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 {
            let chat = app.buttons["Chat"]
            let controlTop = chat.exists ? chat.frame.minY : scrollView.frame.maxY - 72
            if element.isHittable && element.frame.maxY < controlTop - 8 { return }
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
            let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast,
                        thenHoldForDuration: 0)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    func testComposerControlsFitSingleLineInput() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Thursday", in: app)
        app.descendants(matching: .any)["sample-information-0"].tap()
        app.buttons["Chat"].tap()
        let composer = app.textFields["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let surface = app.otherElements["sample-chat-input-surface"]
        XCTAssertTrue(surface.exists, app.debugDescription)
        let add = app.buttons["Add sample attachment"]
        let send = app.buttons["Send locally"]
        for button in [add, send] {
            XCTAssertLessThanOrEqual(button.frame.height, surface.frame.height + 1,
                                     "The complete circular control must fit the one-line input height")
        }
        print("COMPOSER_FRAMES input=\(surface.frame) add=\(add.frame) send=\(send.frame)")
        capture("composer-glass-single-line", app)
        add.tap()
        let photo = app.buttons["Sample photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.isHittable)
        photo.tap()
        composer.tap(); composer.typeText("A local note with a sample photo.")
        XCTAssertTrue(send.isHittable, "The keyboard must leave the send control usable")
        capture("composer-glass-attachment-keyboard", app)
        send.tap()
        XCTAssertTrue(app.staticTexts["A local note with a sample photo."].waitForExistence(timeout: 5))
        capture("composer-glass-local-result", app)
    }

    func testCorrectedInboxDuoOrientations() {
        let orientations: [(String, UIDeviceOrientation)] = [
            ("portrait", .portrait), ("landscape-left", .landscapeLeft),
            ("portrait-upside-down", .portraitUpsideDown), ("landscape-right", .landscapeRight)
        ]
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        defer { XCUIDevice.shared.orientation = .portrait }
        for (name, orientation) in orientations {
            XCUIDevice.shared.orientation = orientation
            app.launch()
            XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
            let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
            XCTAssertEqual(app.frame.width > app.frame.height, landscape, app.debugDescription)
            enterSearch("Archive", in: app)
            XCTAssertTrue(app.descendants(matching: .any)["sample-approval-0"].waitForExistence(timeout: 5))
            capture("corrected-duo-" + name + "-list", app)
            app.descendants(matching: .any)["sample-approval-0"].tap()
            XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5))
            capture("corrected-duo-" + name + "-card", app)
            app.buttons["Chat"].tap()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
            let composer = sheet.textFields["sample-chat-composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap(); composer.typeText("Local orientation " + name)
            let send = sheet.buttons["Send locally"]
            XCTAssertTrue(send.isHittable)
            send.tap()
            XCTAssertTrue(app.staticTexts["Local orientation " + name].waitForExistence(timeout: 5))
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "corrected-duo-" + name + "-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            print("DUO_DISPLAY_CAPTURE " + name)
            Thread.sleep(forTimeInterval: 4)
            app.terminate()
        }
    }

    func testNativeInboxHeaderMinimizesAndRestoresOnIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The native sidebar-column capture matrix is specific to iPad.")
        }
        defer { XCUIDevice.shared.orientation = .portrait }

        let orientations: [(String, UIDeviceOrientation)] = [
            ("portrait", .portrait),
            ("landscape", .landscapeLeft)
        ]
        for (name, orientation) in orientations {
            XCUIDevice.shared.orientation = orientation
            let app = XCUIApplication()
            app.launchArguments = ["--attention-fixture", "--harklight-samples"]
            app.launch()

            let brand = app.descendants(matching: .any)["inbox-brand"]
            let settings = app.buttons["inbox-settings"]
            let sidebarToggle = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "sidebar")).firstMatch
            let list = app.scrollViews.firstMatch.exists
                ? app.scrollViews.firstMatch : app.collectionViews.firstMatch
            let firstRow = app.descendants(matching: .any)["request-row-unknown-01"]

            XCTAssertTrue(brand.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(list.exists, app.debugDescription)
            XCTAssertTrue(firstRow.waitForExistence(timeout: 5), app.debugDescription)
            for _ in 0..<8 {
                if brand.isHittable && firstRow.frame.minY >= settings.frame.maxY { break }
                list.swipeDown()
            }
            XCTAssertTrue(brand.isHittable, "The toolbar is visible at the list top.")
            XCTAssertGreaterThanOrEqual(firstRow.frame.minY, settings.frame.maxY,
                                        "The first row clears the restored toolbar at the top.")
            XCTAssertEqual(app.frame.width > app.frame.height, orientation == .landscapeLeft,
                           app.debugDescription)
            XCTAssertEqual(brand.frame.midY, settings.frame.midY, accuracy: 5,
                           "Brand and Settings share the navigation row.")
            XCTAssertEqual(settings.frame.midY, sidebarToggle.frame.midY, accuracy: 5,
                           "Settings and the sidebar toggle share the navigation row.")
            print("NATIVE_HEADER_\(name) brand=\(brand.frame) settings=\(settings.frame) toggle=\(sidebarToggle.frame) list=\(list.frame)")
            capture("native-header-\(name)-top", app)

            list.swipeUp()
            let hidden = expectation(for: NSPredicate(format: "isHittable == false"),
                                     evaluatedWith: brand)
            wait(for: [hidden], timeout: 5)
            capture("native-header-\(name)-scrolled", app)

            list.swipeDown()
            let restored = expectation(for: NSPredicate(format: "isHittable == true"),
                                       evaluatedWith: brand)
            wait(for: [restored], timeout: 5)
            for _ in 0..<8 {
                if firstRow.isHittable && brand.isHittable &&
                    settings.isHittable && sidebarToggle.isHittable &&
                    firstRow.frame.minY >= settings.frame.maxY { break }
                list.swipeDown()
            }
            XCTAssertTrue(firstRow.isHittable, "The list returns to its top row.")
            XCTAssertTrue(brand.isHittable, "The header is restored at the top.")
            XCTAssertTrue(settings.isHittable, "Settings returns with the header.")
            XCTAssertTrue(sidebarToggle.isHittable, "The sidebar toggle returns with the header.")
            XCTAssertGreaterThan(brand.frame.height, 20, "The restored brand has a visible frame.")
            XCTAssertGreaterThan(settings.frame.height, 20, "The restored Settings control has a visible frame.")
            XCTAssertEqual(brand.frame.midY, settings.frame.midY, accuracy: 5,
                           "The restored brand and Settings share the navigation row.")
            XCTAssertGreaterThanOrEqual(firstRow.frame.minY, settings.frame.maxY,
                                        "The restored first row clears the toolbar.")
            print("NATIVE_HEADER_\(name)_restored brand=\(brand.frame) settings=\(settings.frame) toggle=\(sidebarToggle.frame) row=\(firstRow.frame)")
            capture("native-header-\(name)-restored", app)
            app.terminate()
        }
    }

    func testNativeInboxHeaderUsesCompactNavigationBarOnIPhone() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("The compact navigation header layout is specific to iPhone.")
        }
        defer { XCUIDevice.shared.orientation = .portrait }

        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()

        let brand = app.descendants(matching: .any)["inbox-brand"]
        let settings = app.buttons["inbox-settings"]
        let list = app.scrollViews.firstMatch.exists
            ? app.scrollViews.firstMatch : app.collectionViews.firstMatch
        let firstRow = app.descendants(matching: .any)["request-row-unknown-01"]

        XCTAssertTrue(brand.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(list.exists, app.debugDescription)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 {
            if brand.isHittable && firstRow.frame.minY >= settings.frame.maxY { break }
            list.swipeDown()
        }
        XCTAssertTrue(brand.isHittable, "The native title is visible at the list top.")
        XCTAssertEqual(brand.frame.midY, settings.frame.midY, accuracy: 5,
                       "Brand and Settings share the compact navigation row.")
        XCTAssertGreaterThanOrEqual(firstRow.frame.minY, settings.frame.maxY,
                                    "The first row clears the restored toolbar at the top.")
        capture("native-header-iphone-top", app)

        list.swipeUp()
        let hidden = expectation(for: NSPredicate(format: "isHittable == false"),
                                 evaluatedWith: brand)
        wait(for: [hidden], timeout: 5)
        capture("native-header-iphone-scrolled", app)

        list.swipeDown()
        let restored = expectation(for: NSPredicate(format: "isHittable == true"),
                                   evaluatedWith: brand)
        wait(for: [restored], timeout: 5)
        for _ in 0..<8 {
            if firstRow.isHittable && brand.isHittable && settings.isHittable &&
                firstRow.frame.minY >= settings.frame.maxY { break }
            list.swipeDown()
        }
        XCTAssertTrue(firstRow.isHittable, "The list returns to its top row.")
        XCTAssertTrue(settings.isHittable, "Settings returns with the native title.")
        XCTAssertGreaterThanOrEqual(firstRow.frame.minY, settings.frame.maxY,
                                    "The restored first row clears the native toolbar.")
        capture("native-header-iphone-restored", app)
    }

    func testBoundaryPullAndAdaptiveChat() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples",
                               "--harklight-ui-diagnostics"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Thursday", in: app)
        app.descendants(matching: .any)["sample-information-2"].tap()
        let card = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let lower = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let counter = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+ of [0-9]+'")).firstMatch
        let before = counter.label
        let parts = before.components(separatedBy: " of ")
        let next = "\((Int(parts.first ?? "") ?? 0) + 1) of \(parts.last ?? "")"
        print("BOUNDARY_PEEK_CAPTURE_START")
        lower.press(forDuration: 0.1, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 4)
        let reachedNext = app.staticTexts[next].waitForExistence(timeout: 5)
        if !reachedNext { recordDiagnostics("search-next", app) }
        XCTAssertTrue(reachedNext, app.debugDescription)
        XCTAssertTrue(app.buttons["request-heading"].label.contains("The garden review moved to Thursday"),
                      "Next changes the visible card in the Search stack.")
        upper.press(forDuration: 0.1, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.5)
        let returnedToFirst = app.staticTexts[before].waitForExistence(timeout: 5)
        if !returnedToFirst { recordDiagnostics("search-previous", app) }
        XCTAssertTrue(returnedToFirst, app.debugDescription)
        XCTAssertTrue(app.buttons["request-heading"].label.contains("The library review moved to Thursday"),
                      "Previous returns to the first visible Search result.")
        app.buttons["Chat"].tap()
        XCTAssertTrue(app.textFields["sample-chat-composer"].waitForExistence(timeout: 5))
        capture("adaptive-portrait-chat", app)
        let composer = app.textFields["sample-chat-composer"]
        composer.tap(); composer.typeText("Local keyboard check")
        XCTAssertTrue(app.buttons["Send locally"].isHittable, "Keyboard must leave the send control usable")
        capture("adaptive-portrait-keyboard", app)
        app.buttons["Send locally"].tap()
        XCTAssertTrue(app.staticTexts["Local keyboard check"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        app.activate()
        let composers = app.textFields.matching(identifier: "sample-chat-composer")
        let singleComposer = expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: composers)
        wait(for: [singleComposer], timeout: 5)
        composers.firstMatch.tap(); composers.firstMatch.typeText("Local landscape check")
        XCTAssertTrue(app.buttons["Send locally"].isHittable, "Landscape keyboard must leave the composer usable")
        app.buttons["Send locally"].tap()
        XCTAssertTrue(app.staticTexts["Local landscape check"].waitForExistence(timeout: 5))
        capture("adaptive-landscape-chat", app)
        XCUIDevice.shared.orientation = .portrait
    }
}
