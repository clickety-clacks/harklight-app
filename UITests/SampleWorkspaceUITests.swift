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
        app.launchArguments = ["--attention-fixture"]
        app.launch()
        let realRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'request-row-'"))
        XCTAssertTrue(realRows.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let original = app.buttons["request-row-review-01"]
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
        let inboxTab = app.buttons["inbox-tab-inbox"]
        let repliedTab = app.buttons["inbox-tab-replied"]
        XCTAssertTrue(repliedTab.waitForExistence(timeout: 5), app.debugDescription)
        repliedTab.tap()
        XCTAssertTrue(app.buttons[originalID].waitForExistence(timeout: 5),
                      "Choosing a reply moves the request to Replied.")
        inboxTab.tap()
        XCTAssertFalse(app.buttons[originalID].exists,
                       "A request with a selected answer no longer appears in Inbox.")
        app.buttons["inbox-settings"].tap()
        app.buttons["Add example messages"].tap()
        let row = app.buttons["sample-approval-0"]
        // Both sources remain in this same searchable list.
        enterSearch("Archive", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture("ordinary-inbox-with-examples", app)
        row.tap()
        let keep = app.buttons.containing(.staticText, identifier: "Keep here").firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        app.buttons["sample-finish"].tap()
        XCTAssertTrue(app.staticTexts["Answered locally · nothing sent"].waitForExistence(timeout: 5))
        capture("ordinary-example-card", app)
        showList(app)
        clearSearch(in: app)
        repliedTab.tap()
        XCTAssertTrue(app.buttons[originalID].exists, app.debugDescription)
        app.buttons[originalID].tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cover A"].isSelected, "An ordinary draft survives local example actions")
        capture("ordinary-request-after-example", app)
    }

    private func showList(_ app: XCUIApplication) {
        let card = app.scrollViews["message-card-scroll"]
        guard card.exists else { return }
        let searchButton = app.buttons["inbox-search-button"]
        let searchField = app.textFields["inbox-search-field"]
        let back = app.navigationBars.buttons.firstMatch
        if back.exists && back.isHittable {
            back.tap()
        } else {
            let sidebar = app.buttons["Show Sidebar"]
            if sidebar.exists && sidebar.isHittable { sidebar.tap() }
        }
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5) || searchField.waitForExistence(timeout: 5),
                      app.debugDescription)
    }

    private func enterSearch(_ query: String, in app: XCUIApplication) {
        clearSearch(in: app)
        let searchButton = app.buttons["inbox-search-button"]
        let field = app.textFields["inbox-search-field"]
        if !field.exists {
            XCTAssertTrue(searchButton.waitForExistence(timeout: 5), app.debugDescription)
            searchButton.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText(query + "\n")
    }

    private func clearSearch(in app: XCUIApplication) {
        let dismiss = app.buttons["inbox-search-dismiss"]
        if dismiss.exists && dismiss.isHittable { dismiss.tap() }
    }

    private func seenSwipeAction(in app: XCUIApplication) -> XCUIElement? {
        app.buttons.allElementsBoundByIndex
            .first { $0.label == "Seen, Seen" }
    }

    func testSeenActionFromEitherSwipeEdgeMovesTheMessageToReplied() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))

        // An answer request uses No comment rather than the Seen action.
        enterSearch("Archive", in: app)
        let ordinary = app.buttons["sample-approval-0"]
        XCTAssertTrue(ordinary.waitForExistence(timeout: 5), app.debugDescription)
        ordinary.swipeLeft()
        XCTAssertNotNil(app.buttons.allElementsBoundByIndex.first { $0.label.contains("No comment") },
                        app.debugDescription)
        clearSearch(in: app)

        enterSearch("Thursday", in: app)
        let informational = app.buttons["sample-information-0"]
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
        XCTAssertEqual(markSeen.label, "Seen, Seen")
        capture("inbox-swipe-seen-revealed", app)
        // Revealing the action does not mark the message.
        XCTAssertTrue(informational.exists, "Swiping alone leaves the message in Inbox")
        markSeen.tap()
        let leftInbox = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: informational)
        wait(for: [leftInbox], timeout: 5)
        clearSearch(in: app)

        let repliedTab = app.buttons["inbox-tab-replied"]
        XCTAssertTrue(repliedTab.waitForExistence(timeout: 5), app.debugDescription)
        repliedTab.tap()
        XCTAssertTrue(informational.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(informational.label.contains("Seen selected locally"), informational.label)
        XCTAssertFalse(app.buttons["sample-approval-0"].exists, "An untouched request remains in Inbox")
        capture("seen-message-in-replied-tab", app)

        app.buttons["inbox-tab-inbox"].tap()
        let warning = app.buttons["sample-warning-0"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5), app.debugDescription)
        warning.swipeRight()
        let rightEdgeSeen = NSPredicate { _, _ in self.seenSwipeAction(in: app) != nil }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: rightEdgeSeen, object: nil)],
                                        timeout: 5), .completed, app.debugDescription)
        XCTAssertEqual(seenSwipeAction(in: app)?.label, "Seen, Seen")
        seenSwipeAction(in: app)?.tap()
        XCTAssertFalse(warning.waitForExistence(timeout: 5),
                       "The same Seen action on the opposite edge moves the message out of Inbox.")
    }

    func testReplyChoiceKeepsItsEditorWhenDeselectedAndReopensOnTap() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Which approach", in: app)
        let row = app.buttons["sample-textChoice-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()

        let replyChoice = app.buttons.containing(.staticText, identifier: "Your own answer").firstMatch
        XCTAssertTrue(replyChoice.waitForExistence(timeout: 5), app.debugDescription)
        replyChoice.tap()
        let editor = app.textViews.matching(identifier: "request-input-answer-response").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        editor.tap()
        editor.typeText("Keep the smaller first step.")

        let otherChoice = app.buttons.containing(.staticText, identifier: "Start small").firstMatch
        XCTAssertTrue(otherChoice.waitForExistence(timeout: 5), app.debugDescription)
        otherChoice.tap()
        XCTAssertTrue(editor.exists, "Typed Reply stays visible after another choice is selected.")
        XCTAssertFalse(editor.isEnabled, "A deselected Reply editor is ghosted and cannot be edited.")
        XCTAssertEqual(editor.value as? String, "Keep the smaller first step.")
        capture("reply-editor-deselected-with-draft", app)

        replyChoice.tap()
        XCTAssertTrue(editor.isEnabled, "Tapping the Reply card reselects it.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Reselecting Reply focuses its editor.")
        capture("reply-editor-reselected", app)
    }

    func testDesignedControlsAndComponentScreenshots() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples", "--harklight-ui-diagnostics"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        let kinds = ["textChoice", "pictureChoice", "instructions", "review", "multipleChoice", "value", "point", "colorChoice", "soundChoice", "error", "warning", "information", "completed"]
        for kind in kinds {
            showList(app)
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
            let row = app.buttons["sample-\(kind)-0"]
            let found = row.waitForExistence(timeout: 5)
            if kind == "review" || !found { recordDiagnostics("search-\(kind)", app) }
            XCTAssertTrue(found, app.debugDescription)
            reveal(row, in: app.scrollViews.firstMatch, app: app)
            row.tap()
            if ["error", "warning", "information", "completed"].contains(kind) {
                XCTAssertTrue(app.buttons["request-finish-seen"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["request-seen-action"].exists)
            } else {
                XCTAssertTrue(app.buttons["sample-finish"].waitForExistence(timeout: 5))
            }
            capture("component-\(kind)", app)
            if ["textChoice", "review", "multipleChoice", "colorChoice", "soundChoice"].contains(kind) {
                let ownAnswer = app.buttons.containing(.staticText, identifier: "Your own answer").firstMatch
                reveal(ownAnswer, in: app.scrollViews["message-card-scroll"], app: app)
                ownAnswer.tap()
                let answer = app.textViews["request-input-answer-response"]
                XCTAssertTrue(answer.waitForExistence(timeout: 5))
                reveal(answer, in: app.scrollViews["message-card-scroll"], app: app)
                answer.tap(); answer.typeText("Leave room for a quiet corner.")
                capture("component-own-answer", app)
                app.buttons["sample-finish"].tap()
            }
            if kind == "pictureChoice" {
                let card = app.scrollViews["message-card-scroll"]
                let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7))
                let end = card.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
                XCTAssertTrue(app.buttons["sample-finish"].exists, "Ordinary scrolling retains this card")
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
            let later = app.buttons["Later"]
            let toolbarTop = chat.exists ? chat.frame.minY
                : later.exists ? later.frame.minY : scrollView.frame.maxY - 72
            if element.isHittable && element.frame.maxY < toolbarTop - 8 { return }
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
        app.buttons["sample-information-0"].tap()
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
            XCTAssertTrue(app.buttons["sample-approval-0"].waitForExistence(timeout: 5))
            capture("corrected-duo-" + name + "-list", app)
            app.buttons["sample-approval-0"].tap()
            XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5))
            capture("corrected-duo-" + name + "-card", app)
            app.buttons["Chat"].tap()
            let composer = app.textFields["sample-chat-composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap(); composer.typeText("Local orientation " + name)
            XCTAssertTrue(app.buttons["Send locally"].isHittable)
            app.buttons["Send locally"].tap()
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

    func testBoundaryPullAndAdaptiveChat() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Thursday", in: app)
        app.buttons["sample-information-0"].tap()
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
        XCTAssertTrue(app.staticTexts[next].waitForExistence(timeout: 5), app.debugDescription)
        upper.press(forDuration: 0.1, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.staticTexts[before].waitForExistence(timeout: 5), app.debugDescription)
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
