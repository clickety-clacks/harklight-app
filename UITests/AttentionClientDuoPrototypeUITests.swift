import XCTest

@MainActor
final class AttentionClientDuoPrototypeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testUnjoinedDeviceCanPasteAnInvitationWithoutAssemblingCredentials() throws {
        let app = XCUIApplication()
        app.launch()
        let invitation = app.secureTextFields["Full invitation"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Welcome to Harklight"].exists)
        XCTAssertFalse(app.buttons["Join"].exists, "Join requires a verified destination and a deliberate confirmation")
        invitation.tap()
        invitation.typeText("harklight://join#invalid")
        app.buttons["Check invitation"].tap()
        XCTAssertTrue(app.staticTexts["Joining could not be confirmed"].waitForExistence(timeout: 5))
        let diagnosticHistory = app.buttons["enrollment-client-diagnostics-share"]
        XCTAssertTrue(diagnosticHistory.waitForExistence(timeout: 5),
                      "An invitation verification failure must expose the retained safe journal before the inbox exists")
        XCTAssertTrue(diagnosticHistory.isHittable,
                      "The journal action must be reachable on the pre-inbox failure screen")
        XCTAssertFalse(app.buttons["Join"].exists, "An invalid invitation cannot add a device")
        app.buttons["Use another invitation"].tap()
        XCTAssertTrue(app.secureTextFields["Full invitation"].waitForExistence(timeout: 5),
                      "A refused paste must let the person enter the fresh invitation without restarting")
    }

    func testInitializedPointEditorsRemainAvailableForCorrectionInPlace() throws {
        let app = launchFreshApp()

        selectFacilitiesRequest(in: app)
        XCTAssertEqual(app.staticTexts["request-heading"].label, "Facilities desk")
        XCTAssertFalse(app.staticTexts["fixture:Facilities"].exists,
                       "Raw fixture identity belongs in read-only details, not the task framing.")
        XCTAssertFalse(app.buttons["Choose example outcome"].exists,
                       "Simulation controls belong on the separate Demo controls screen.")

        let instructions = app.buttons["message-instructions-disclosure"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        instructions.tap()
        XCTAssertTrue(app.staticTexts["Select the location on the floor plan and add a note."]
            .waitForExistence(timeout: 5))
        instructions.tap()

        let status = app.buttons["request-status-details"]
        XCTAssertTrue(status.exists)
        XCTAssertEqual(status.label, "Open. No answer has been submitted.")
        let availableCompactWidth = app.windows.firstMatch.frame.width - 32
        XCTAssertLessThanOrEqual(status.frame.width, min(320, availableCompactWidth) + 1,
                                 "The compact status action should stay badge-sized instead of filling the detail column.")
        status.tap()
        XCTAssertTrue(app.staticTexts["request-details-outcome"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["identity-value-account"].label, "fictional-sample-account")
        XCTAssertEqual(app.staticTexts["identity-value-sender-id"].label, "fixture:Facilities")
        XCTAssertEqual(app.staticTexts["identity-value-message-id"].label, "facilities-01")
        let senderLabel = app.staticTexts["Sender ID"]
        let senderValue = app.staticTexts["identity-value-sender-id"]
        XCTAssertTrue(senderLabel.exists)
        XCTAssertTrue(senderValue.exists)
        let inlineGap = senderValue.frame.minX - senderLabel.frame.maxX
        let isInlineGroup = abs(inlineGap) <= 12 &&
            abs(senderValue.frame.midY - senderLabel.frame.midY) <= 12
        let isStackedGroup = abs(senderValue.frame.minX - senderLabel.frame.minX) <= 12 &&
            senderValue.frame.minY >= senderLabel.frame.maxY &&
            senderValue.frame.minY - senderLabel.frame.maxY <= 16
        XCTAssertTrue(isInlineGroup || isStackedGroup,
                      "The exact sender label and value should stay in one compact group.\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["identity-value-created"].exists,
                      "The exact creation metadata should remain available in details.")
        let detailsBack = app.buttons["request-details-return"]
        XCTAssertTrue(detailsBack.waitForExistence(timeout: 5))
        detailsBack.tap()
        XCTAssertTrue(app.buttons["request-status-details"].waitForExistence(timeout: 5))

        let setPoint = app.buttons["set-point"]
        XCTAssertTrue(setPoint.waitForExistence(timeout: 5))
        setPoint.tap()

        let statusAfterDraft = app.buttons["request-status-details"]
        XCTAssertTrue(statusAfterDraft.waitForExistence(timeout: 5))
        // XCTest scrolls the identified control into view, as it does for Set point above.
        statusAfterDraft.tap()
        XCTAssertTrue(app.staticTexts["request-details-outcome"].waitForExistence(timeout: 5))
        app.buttons["request-details-return"].tap()
        XCTAssertEqual(app.textFields["coordinate-horizontal"].value as? String, "500")
        XCTAssertEqual(app.textFields["coordinate-vertical"].value as? String, "500",
                       "Inspecting outcome details must preserve the active scene draft.")

        let horizontal = app.textFields["coordinate-horizontal"]
        let vertical = app.textFields["coordinate-vertical"]
        replaceText(in: horizontal, with: "1001")

        XCTAssertTrue(app.staticTexts["coordinate-entry-error"].waitForExistence(timeout: 5))
        XCTAssertTrue(horizontal.exists, "The initialized horizontal editor must remain visible after invalid text.")
        XCTAssertTrue(vertical.exists, "The initialized vertical editor must remain visible after invalid text.")
        XCTAssertFalse(app.buttons["set-point"].exists, "Invalid text must not reset an initialized point.")
        XCTAssertFalse(app.buttons["send-answer"].isEnabled)

        replaceText(in: horizontal, with: "240")
        XCTAssertFalse(app.staticTexts["coordinate-entry-error"].exists)
        XCTAssertTrue(vertical.exists)

        let note = app.textViews["text-input-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("Near the east entrance")

        let send = app.buttons["send-answer"]
        XCTAssertTrue(send.isEnabled, "Correcting the coordinate in place should restore a valid answer.")
        send.tap()
        let pendingStatus = app.buttons["request-status-details"]
        XCTAssertTrue(pendingStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(pendingStatus.label,
                       "Pending. The answer is saved locally in this fixture; no relay is connected.")
        XCTAssertFalse(app.staticTexts["Your submitted answer · exact JSON"].exists,
                       "Receipt inspection should stay out of the principal task composition.")
        pendingStatus.tap()
        XCTAssertTrue(app.descendants(matching: .any)["request-details-receipt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your submitted answer · exact JSON"].exists)
        let expectedReceipt = "{\"point\":{\"x\":240,\"y\":500},\"note\":\"Near the east entrance\",\"drawingRevision\":9007199254740993}"
        let submittedAnswer = app.staticTexts["request-details-receipt-json"]
        XCTAssertTrue(submittedAnswer.waitForExistence(timeout: 5),
                      "Exact answer JSON should be exposed in read-only details. Hierarchy:\n\(app.debugDescription)")
        XCTAssertEqual(submittedAnswer.label, expectedReceipt,
                       "Read-only details should retain the exact submitted answer, including its large integer.")
}
    func testAcceptedAnswerShowsKnownAnsweredSceneAfterDemoReturn() throws {
        let app = launchFreshApp()

        selectFacilitiesRequest(in: app)
        let setPoint = app.buttons["set-point"]
        XCTAssertTrue(setPoint.waitForExistence(timeout: 5))
        setPoint.tap()
        replaceOutcomeCoordinate(in: app, field: app.textFields["coordinate-horizontal"], with: "240")
        replaceOutcomeCoordinate(in: app, field: app.textFields["coordinate-vertical"], with: "610")

        let note = app.textViews["text-input-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        revealOutcomeEditor(note, in: app)
        note.tap()
        note.typeText("Near the east entrance")

        let send = app.buttons["send-answer"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.buttons["request-status-details"].waitForExistence(timeout: 5))

        applyFixtureOutcome("ownOperationAccepted", in: app)

        let acceptedStatus = app.buttons["request-status-details"]
        XCTAssertTrue(acceptedStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(acceptedStatus.label,
                       "Answered. This fixture simulates acceptance for this submission; no relay or source result exists, and source use is not shown.",
                       "The spoken button name includes the simulated outcome while the visible capsule remains lifecycle-only.")
        XCTAssertLessThanOrEqual(acceptedStatus.frame.height, 48,
                                 "The lifecycle status should remain a compact badge.")
        let knownPoint = app.staticTexts["Established submitted location"].firstMatch
        XCTAssertTrue(knownPoint.waitForExistence(timeout: 5),
                      "The accepted original operation should select the known sender result scene.")
        XCTAssertEqual(knownPoint.value as? String, "Horizontal 240, vertical 610")

        acceptedStatus.tap()
        let acceptedOutcome = app.staticTexts["request-details-outcome"]
        XCTAssertTrue(acceptedOutcome.waitForExistence(timeout: 5))
        XCTAssertTrue(acceptedOutcome.label.contains("No relay or source receipt exists"))
        assertExactFacilitiesReceipt(in: app)
    }

    func testUnconfirmedAnswerOutcomeKeepsNeutralSceneAndExactReceipt() throws {
        let app = launchFreshApp()
        submitFacilitiesAnswer(in: app, horizontal: "240", vertical: "610")

        applyFixtureOutcome("answerOutcomeUnconfirmed", in: app)

        let unconfirmedStatus = app.buttons["request-status-details"]
        XCTAssertTrue(unconfirmedStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(unconfirmedStatus.label,
                       "Answered. Your submission outcome is unconfirmed; the original operation outcome remains unresolved.",
                       "The spoken button name preserves the unconfirmed original-operation outcome.")
        XCTAssertFalse(app.staticTexts["Established submitted location"].exists,
                       "An unconfirmed closure must keep the neutral sender scene.")

        unconfirmedStatus.tap()
        let outcome = app.staticTexts["request-details-outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
        XCTAssertTrue(outcome.label.contains("original operation outcome remains unconfirmed"))
        XCTAssertTrue(app.staticTexts["Your submitted answer · exact JSON"].exists,
                      "Read-only inspection retains the captured answer without calling it the winning result.")
        assertExactFacilitiesReceipt(in: app)
    }

    private func applyFixtureOutcome(_ scenario: String, in app: XCUIApplication) {
        let outcomeButton = app.buttons["fixture-outcome-button"]
        XCTAssertTrue(outcomeButton.waitForExistence(timeout: 5),
                      "The ordinary pending fixture card must expose its local outcome control.")
        XCTAssertTrue(outcomeButton.isHittable)
        outcomeButton.tap()
        let outcome = app.buttons.matching(identifier: "fixture-outcome-" + scenario).firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
        XCTAssertTrue(outcome.isEnabled && outcome.isHittable,
                      "Apply the local outcome through the ordinary card's native dialog.")
        outcome.tap()
    }

    private func assertExactFacilitiesReceipt(in app: XCUIApplication) {
        let receipt = app.staticTexts["request-details-receipt-json"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertEqual(receipt.label,
                       "{\"point\":{\"x\":240,\"y\":610},\"note\":\"Near the east entrance\",\"drawingRevision\":9007199254740993}",
                       "The terminal fixture outcome must preserve the exact originally submitted answer.")
    }

    private func selectFacilitiesRequest(in app: XCUIApplication) {
        let requestRow = app.descendants(matching: .any)["request-row-facilities-01"]
        showRequestsListIfNeeded(in: app)
        XCTAssertTrue(requestRow.waitForExistence(timeout: 5))
        requestRow.tap()
        XCTAssertTrue(app.staticTexts["Facilities desk"].waitForExistence(timeout: 5))
    }

    private func showRequestsListIfNeeded(in app: XCUIApplication) {
        let requestRow = app.descendants(matching: .any)["request-row-facilities-01"]
        guard !requestRow.isHittable else { return }

        let sidebarButton = app.buttons["Show Sidebar"]
        if sidebarButton.exists {
            sidebarButton.tap()
        } else {
            let backButton = app.buttons["BackButton"]
            XCTAssertTrue(backButton.waitForExistence(timeout: 5),
                          "The selected request must provide a way back to the Requests list.")
            backButton.tap()
        }
        XCTAssertTrue(requestRow.waitForExistence(timeout: 5),
                      "Returning from the selected request should reveal the Requests list.")
    }

    private func replaceText(in field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let existingText = field.value as? String ?? ""
        if !existingText.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingText.count))
        }
        field.typeText(value)
    }

    private func revealOutcomeEditor(_ editor: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        for _ in 0..<8 {
            let keyboard = app.keyboards.firstMatch
            let keyboardTop = keyboard.exists ? keyboard.frame.minY : app.frame.maxY
            let cancel = app.buttons["Cancel draft"]
            let bottom = min(keyboardTop, cancel.exists ? cancel.frame.minY : app.frame.maxY - 80)
            let frame = editor.frame
            if editor.isHittable && frame.minY >= 100 && frame.maxY < bottom - 44 { return }
            let direction: CGFloat = frame.minY < 100 ? 1 : -1
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0))
                .withOffset(CGVector(dx: 0, dy: bottom - 160))
            let end = start.withOffset(CGVector(dx: 0, dy: direction * 120))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("The ordinary card must reveal the editor above its bars and keyboard.\n\(app.debugDescription)")
    }

    private func replaceOutcomeCoordinate(in app: XCUIApplication, field: XCUIElement, with value: String) {
        revealOutcomeEditor(field, in: app)
        let existing = field.value as? String ?? ""
        field.tap()
        if !existing.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)) }
        field.typeText(value)
        XCTAssertEqual(field.value as? String, value)
    }

    private func submitFacilitiesAnswer(in app: XCUIApplication,
                                        horizontal: String,
                                        vertical: String) {
        selectFacilitiesRequest(in: app)
        let setPoint = app.buttons["set-point"]
        XCTAssertTrue(setPoint.waitForExistence(timeout: 5))
        setPoint.tap()
        replaceOutcomeCoordinate(in: app, field: app.textFields["coordinate-horizontal"], with: horizontal)
        replaceOutcomeCoordinate(in: app, field: app.textFields["coordinate-vertical"], with: vertical)
        let note = app.textViews["text-input-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        revealOutcomeEditor(note, in: app)
        note.tap()
        note.typeText("Near the east entrance")
        let send = app.buttons["send-answer"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.buttons["request-status-details"].waitForExistence(timeout: 5))
    }

    private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()
        return app
    }

}
