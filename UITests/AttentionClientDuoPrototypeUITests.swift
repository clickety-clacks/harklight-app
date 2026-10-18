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

    func testSharedPointDraftAndExactReceiptRemainAvailable() throws {
        let app = launchFreshApp()

        selectFacilitiesRequest(in: app)
        XCTAssertTrue(app.staticTexts["Select the location on the floor plan and add a note."]
            .waitForExistence(timeout: 5))
        let lifecycle = app.staticTexts["request-lifecycle-status"]
        XCTAssertTrue(lifecycle.waitForExistence(timeout: 5))
        XCTAssertEqual(lifecycle.label, "Open",
                       "A fresh fixture request starts open, before a local answer is submitted.")
        XCTAssertFalse(app.staticTexts["fixture:Facilities"].exists,
                       "Raw fixture identity stays in request details, not the task framing.")
        XCTAssertFalse(app.buttons["fixture-outcome-menu"].exists,
                        "Fixture outcomes are available only after an answer enters Pending.")

        setFacilitiesPoint(in: app, x: 500, y: 500)
        let details = app.descendants(matching: .any)["request-details-disclosure"]
        revealInCard(details, in: app)
        details.tap()
        XCTAssertTrue(app.staticTexts["Sender: fixture:Facilities"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Message: facilities-01"].exists)
        let originalContent = app.staticTexts["request-original-content-json"]
        XCTAssertTrue(originalContent.waitForExistence(timeout: 5))
        XCTAssertTrue(originalContent.label.contains("facilities-01"))
        details.tap()
        XCTAssertEqual(app.staticTexts["request-point-value-location"].label,
                       "Horizontal 500, vertical 500",
                       "Inspecting request details must preserve the active point draft.")

        setFacilitiesPoint(in: app, x: 240, y: 500)
        let note = app.textViews["request-input-note"]
        revealInCard(note, in: app)
        note.tap()
        note.typeText("Near the east entrance")

        let finish = app.buttons["request-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(finish.isEnabled, "A valid point and note should enable the shared answer action.")
        finish.tap()
        XCTAssertTrue(lifecycle.waitForExistence(timeout: 5))
        XCTAssertEqual(lifecycle.label, "Pending",
                       "A local submission remains pending until its fixture outcome is explicitly simulated.")
        XCTAssertTrue(app.buttons["fixture-outcome-menu"].waitForExistence(timeout: 5),
                      "The local outcome simulation appears on the ordinary pending fixture card.")
        assertExactFacilitiesReceipt(in: app, y: 500)
    }
    func testAcceptedAnswerShowsKnownAnsweredSceneThroughSharedFixture() throws {
        let app = launchFreshApp()
        submitFacilitiesAnswer(in: app, x: 240, y: 610)

        applyFixtureOutcome("ownOperationAccepted", in: app)

        let acceptedStatus = app.staticTexts["request-lifecycle-status"]
        XCTAssertTrue(acceptedStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(acceptedStatus.label, "Answered")
        let acceptedEvidence = app.staticTexts["request-receipt-evidence"]
        XCTAssertTrue(acceptedEvidence.waitForExistence(timeout: 5))
        XCTAssertEqual(acceptedEvidence.label,
                       "simulated success for this original operation",
                       "The fixture must identify acceptance for this exact submission.")
        let knownPoint = app.descendants(matching: .any)["Established submitted location"].firstMatch
        XCTAssertTrue(knownPoint.waitForExistence(timeout: 5),
                      "The accepted original operation should select the known sender result scene.")
        XCTAssertEqual(knownPoint.value as? String, "Horizontal 240, vertical 610")

        assertExactFacilitiesReceipt(in: app, y: 610)
    }

    func testUnconfirmedAnswerOutcomeKeepsNeutralSceneAndExactReceipt() throws {
        let app = launchFreshApp()
        submitFacilitiesAnswer(in: app, x: 240, y: 610)

        applyFixtureOutcome("answerOutcomeUnconfirmed", in: app)

        let unconfirmedStatus = app.staticTexts["request-lifecycle-status"]
        XCTAssertTrue(unconfirmedStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(unconfirmedStatus.label, "Answered")
        let unconfirmedEvidence = app.staticTexts["request-receipt-evidence"]
        XCTAssertTrue(unconfirmedEvidence.waitForExistence(timeout: 5))
        XCTAssertEqual(unconfirmedEvidence.label,
                       "simulated closure without this operation's result",
                       "The fixture must retain the unconfirmed original-operation distinction.")
        XCTAssertFalse(app.descendants(matching: .any)["Established submitted location"].exists,
                       "An unconfirmed closure must keep the neutral sender scene.")

        assertExactFacilitiesReceipt(in: app, y: 610)
    }

    private func applyFixtureOutcome(_ scenario: String, in app: XCUIApplication) {
        let outcomeButton = app.buttons["fixture-outcome-menu"]
        XCTAssertTrue(outcomeButton.waitForExistence(timeout: 5),
                      "The ordinary pending fixture card must expose its local outcome control.")
        revealInCard(outcomeButton, in: app)
        outcomeButton.tap()
        let outcome = app.buttons["fixture-outcome-" + scenario]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
        XCTAssertTrue(outcome.isEnabled && outcome.isHittable,
                      "Apply the local outcome through the ordinary card's native dialog.")
        outcome.tap()
    }

    private func assertExactFacilitiesReceipt(in app: XCUIApplication, y: Int) {
        let details = app.descendants(matching: .any)["request-details-disclosure"]
        revealInCard(details, in: app)
        details.tap()
        let receipt = app.staticTexts["request-details-original-answer-json"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertEqual(receipt.label,
                       "{\"point\":{\"x\":240,\"y\":\(y)},\"note\":\"Near the east entrance\",\"drawingRevision\":9007199254740993}",
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

    private func revealInCard(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let scroll = app.scrollViews["message-card-scroll"]
        for _ in 0..<8 {
            if element.isHittable { return }
            scroll.swipeUp()
        }
        XCTAssertTrue(element.isHittable,
                      "The shared message card should make its existing control reachable.\n\(app.debugDescription)")
    }

    private func setFacilitiesPoint(in app: XCUIApplication, x: Int, y: Int) {
        let pointSurface = app.descendants(matching: .any)["request-point-location"]
        revealInCard(pointSurface, in: app)
        pointSurface.coordinate(withNormalizedOffset: CGVector(dx: CGFloat(x) / 1000,
                                                                dy: CGFloat(y) / 1000)).tap()
        let pointValue = app.staticTexts["request-point-value-location"]
        XCTAssertTrue(pointValue.waitForExistence(timeout: 5))
        XCTAssertEqual(pointValue.label, "Horizontal \(x), vertical \(y)")
    }

    private func submitFacilitiesAnswer(in app: XCUIApplication, x: Int, y: Int) {
        selectFacilitiesRequest(in: app)
        setFacilitiesPoint(in: app, x: x, y: y)
        let note = app.textViews["request-input-note"]
        revealInCard(note, in: app)
        note.tap()
        note.typeText("Near the east entrance")
        let finish = app.buttons["request-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(finish.isEnabled)
        finish.tap()
        let status = app.staticTexts["request-lifecycle-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Pending",
                       "The local answer stays pending until its fixture outcome is explicitly simulated.")
    }

    private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()
        return app
    }

}
