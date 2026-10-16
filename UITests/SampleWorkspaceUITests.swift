import XCTest

@MainActor
final class SampleWorkspaceUITests: XCTestCase {
    func testOrdinaryInboxKeepsRequestsWhenExamplesAreAdded() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture"]
        app.launch()
        let realRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'request-row-'"))
        XCTAssertTrue(realRows.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let original = realRows.firstMatch.identifier
        capture("ordinary-inbox-before-shake", app)
        realRows.firstMatch.tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5))
        let originalChoice = app.buttons["Cover A"]
        XCTAssertTrue(originalChoice.waitForExistence(timeout: 5), app.debugDescription)
        originalChoice.tap()
        XCTAssertTrue(originalChoice.isSelected)
        capture("ordinary-request-card", app)
        showList(app)
        app.buttons["inbox-settings"].tap()
        app.buttons["Add example messages"].tap()
        let row = app.buttons["sample-approval-0"]
        // Both sources remain in this same searchable list.
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Archive\n")
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
        if app.buttons["Clear text"].exists { app.buttons["Clear text"].tap() }
        XCTAssertTrue(app.buttons[original].exists, app.debugDescription)
        app.buttons[original].tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cover A"].isSelected, "An ordinary draft survives local example actions")
        capture("ordinary-request-after-example", app)
    }

    private func showList(_ app: XCUIApplication) {
        if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        else if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
    }

    func testDesignedControlsAndComponentScreenshots() {
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        let kinds = ["textChoice", "pictureChoice", "instructions", "review", "multipleChoice", "value", "point", "colorChoice", "soundChoice", "error", "warning", "information", "completed"]
        for kind in kinds {
            if !app.searchFields.firstMatch.isHittable {
                let sidebar = app.buttons["Show Sidebar"]
                if sidebar.exists { sidebar.tap() }
                else { app.buttons["BackButton"].tap() }
            }
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
            if app.buttons["Clear text"].exists { app.buttons["Clear text"].tap() }
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
            search.tap(); search.typeText(query + "\n")
            let row = app.buttons["sample-\(kind)-0"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            row.tap()
            XCTAssertTrue(app.buttons["sample-finish"].waitForExistence(timeout: 5))
            capture("component-\(kind)", app)
            if ["textChoice", "review", "multipleChoice", "colorChoice", "soundChoice"].contains(kind) {
                app.buttons.containing(.staticText, identifier: "Your own answer").firstMatch.tap()
                let answer = app.textFields["Your answer"]
                XCTAssertTrue(answer.waitForExistence(timeout: 5))
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

    func testComposerControlsFitSingleLineInput() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Thursday\n")
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

    func testOrdinaryConversationSharesAdaptivePanelWithoutLiveServices() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--conversation-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Thursday\n")
        let row = app.buttons["request-row-sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()
        let composers = app.textFields.matching(identifier: "sample-chat-composer")
        XCTAssertTrue(composers.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(composers.count, 1)
        XCTAssertTrue(app.staticTexts["Could you explain the tradeoff?"].exists,
                      "Ordinary request chat must project its domain history")
        XCTAssertTrue(app.buttons["Add sample attachment"].isHittable)
        capture("ordinary-conversation-portrait", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let singleComposer = expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: composers)
        wait(for: [singleComposer], timeout: 5)
        XCTAssertTrue(app.buttons["Add sample attachment"].isHittable)
        capture("ordinary-conversation-landscape", app)
        XCUIDevice.shared.orientation = .portrait
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
            let search = app.searchFields.firstMatch
            search.tap(); search.typeText("Archive\n")
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
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Thursday\n")
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
