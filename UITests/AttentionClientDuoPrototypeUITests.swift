import XCTest
import AttentionDomain

@MainActor
final class AttentionClientDuoPrototypeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
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

        let centerPoint = setFacilitiesPoint(in: app, x: 500, y: 500)
        let details = app.buttons["request-details-disclosure"]
        revealInCard(details, in: app)
        details.tap()
        XCTAssertTrue(app.staticTexts["Sender: fixture:Facilities"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Message: facilities-01"].exists)
        let originalContent = app.staticTexts["request-original-content-json"]
        XCTAssertTrue(originalContent.waitForExistence(timeout: 5))
        XCTAssertTrue(originalContent.label.contains("facilities-01"))
        details.tap()
        XCTAssertEqual(app.staticTexts["request-point-value-location"].label,
                       "Horizontal \(centerPoint.x), vertical \(centerPoint.y)",
                       "Inspecting request details must preserve the active point draft.")

        let submittedPoint = setFacilitiesPoint(in: app, x: 240, y: 500)
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
        assertExactFacilitiesReceipt(in: app, point: submittedPoint)
    }
    func testAcceptedAnswerShowsKnownAnsweredSceneThroughSharedFixture() throws {
        let app = launchFreshApp()
        let submittedPoint = submitFacilitiesAnswer(in: app, x: 240, y: 610)

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
        XCTAssertEqual(knownPoint.value as? String,
                       "Horizontal \(submittedPoint.x), vertical \(submittedPoint.y)")

        assertExactFacilitiesReceipt(in: app, point: submittedPoint)
    }

    func testUnconfirmedAnswerOutcomeKeepsNeutralSceneAndExactReceipt() throws {
        let app = launchFreshApp()
        let submittedPoint = submitFacilitiesAnswer(in: app, x: 240, y: 610)

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

        assertExactFacilitiesReceipt(in: app, point: submittedPoint)
    }

    func testBackWithoutSwitchingKeepsListPositionWhenAnsweredRequestMovesDown() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()
        let list = app.scrollViews.firstMatch
        let facilities = app.buttons["request-row-facilities-01"]
        let others = [app.buttons["request-row-unknown-01"], app.buttons["request-row-review-01"]]
        XCTAssertTrue(facilities.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(others.allSatisfy { $0.waitForExistence(timeout: 5) }, app.debugDescription)
        let examples = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sample-'"))
        XCTAssertTrue(examples.firstMatch.waitForExistence(timeout: 10),
                      "Local examples make the list long enough to scroll.")
        XCTAssertTrue(others.contains { $0.frame.minY > facilities.frame.minY },
                      "The open request starts above another open request, so finishing it moves it down.")

        // Scroll part of a row so the position Back must keep is not the list's top.
        let top = ([facilities] + others).min { $0.frame.minY < $1.frame.minY }!
        let unscrolledTop = top.frame.minY
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -(top.frame.height * 0.5 + 20))),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        let scrolledTop = top.frame.minY
        XCTAssertLessThan(scrolledTop, unscrolledTop - 10, "The list must be scrolled away from its top.")

        XCTAssertTrue(facilities.isHittable, app.debugDescription)
        facilities.tap()
        XCTAssertTrue(app.staticTexts["Facilities desk"].waitForExistence(timeout: 5))
        _ = answerSelectedFacilitiesRequest(in: app, x: 240, y: 610)
        applyFixtureOutcome("ownOperationAccepted", in: app)
        let status = app.staticTexts["request-lifecycle-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Answered")

        let back = app.buttons["harklight-detail-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(top.waitForExistence(timeout: 5), app.debugDescription)
        let movedDown = NSPredicate { _, _ in others.allSatisfy { $0.frame.minY < facilities.frame.minY } }
        wait(for: [XCTNSPredicateExpectation(predicate: movedDown, object: nil)], timeout: 5)
        let kept = NSPredicate { _, _ in abs(top.frame.minY - scrolledTop) <= 1 }
        let keptPosition = XCTNSPredicateExpectation(predicate: kept, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [keptPosition], timeout: 3), .completed,
                       "Back without switching messages must return to the exact list position: top row at \(top.frame.minY), expected \(scrolledTop).\n\(app.debugDescription)")
    }

    func testAnsweredRequestStaysAtTheBottomOfUnseenAndNeverMovesToSeen() throws {
        let app = launchFreshApp()
        let facilities = app.buttons["request-row-facilities-01"]
        XCTAssertTrue(facilities.waitForExistence(timeout: 10), app.debugDescription)
        _ = submitFacilitiesAnswer(in: app, x: 240, y: 610)
        applyFixtureOutcome("ownOperationAccepted", in: app)
        let status = app.staticTexts["request-lifecycle-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Answered")
        showRequestsListIfNeeded(in: app)

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'request-row-'"))
        let atBottom = NSPredicate { _, _ in
            let others = rows.allElementsBoundByIndex.filter { $0.identifier != facilities.identifier }
            return !others.isEmpty && others.allSatisfy { $0.frame.minY < facilities.frame.minY }
        }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: atBottom, object: nil)],
                                        timeout: 5), .completed,
                       "An answered request sits below every other request in Unseen.\n\(app.debugDescription)")

        // An answered request is not offered the Seen swipe.
        facilities.swipeLeft()
        let seenSwipeAction = app.buttons.allElementsBoundByIndex
            .first { $0.label == "Seen, Seen" }
        XCTAssertNil(seenSwipeAction, app.debugDescription)

        let tabs = app.segmentedControls["inbox-message-tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5), app.debugDescription)
        tabs.buttons["Seen"].tap()
        XCTAssertTrue(tabs.buttons["Seen"].isSelected, app.debugDescription)
        XCTAssertFalse(facilities.waitForExistence(timeout: 2), "An answered request does not move to Seen")
        tabs.buttons["Unseen"].tap()
        XCTAssertTrue(facilities.waitForExistence(timeout: 5), "The answered request stays in Unseen")
    }

    private func applyFixtureOutcome(_ scenario: String, in app: XCUIApplication) {
        let outcomeButton = app.buttons["fixture-outcome-menu"]
        XCTAssertTrue(outcomeButton.waitForExistence(timeout: 5),
                      "The ordinary pending fixture card must expose its local outcome control.")
        revealInCard(outcomeButton, in: app)
        outcomeButton.tap()
        // The confirmation-dialog snapshot exposes this native action as both a
        // parent and its nested button node; interact with the first visible match.
        let outcome = app.buttons.matching(identifier: "fixture-outcome-" + scenario).firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
        XCTAssertTrue(outcome.isEnabled && outcome.isHittable,
                      "Apply the local outcome through the ordinary card's native dialog.")
        outcome.tap()
    }

    private func assertExactFacilitiesReceipt(in app: XCUIApplication, point: PointValue) {
        let details = app.buttons["request-details-disclosure"]
        revealInCard(details, in: app)
        details.tap()
        let receipt = app.staticTexts["request-details-original-answer-json"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertEqual(receipt.label,
                       "{\"point\":{\"x\":\(point.x),\"y\":\(point.y)},\"note\":\"Near the east entrance\",\"drawingRevision\":9007199254740993}",
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

        let backButton = app.buttons["harklight-detail-back"]
        if backButton.exists && backButton.isHittable {
            backButton.tap()
        } else {
            let sidebarButton = app.buttons["Show Sidebar"]
            XCTAssertTrue(sidebarButton.waitForExistence(timeout: 5),
                          "The selected request must provide a way back to the Requests list.")
            sidebarButton.tap()
        }
        XCTAssertTrue(requestRow.waitForExistence(timeout: 5),
                      "Returning from the selected request should reveal the Requests list.")
    }

    private func revealInCard(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let scroll = app.scrollViews["message-card-scroll"]
        for _ in 0..<8 {
            if element.isHittable { return }
            // A central pan scrolls the card without hitting either system edge or indicator.
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast,
                        thenHoldForDuration: 0)
        }
        XCTAssertTrue(element.isHittable,
                      "The shared message card should make its existing control reachable.\n\(app.debugDescription)")
    }

    private func setFacilitiesPoint(in app: XCUIApplication, x: Int, y: Int) -> PointValue {
        let pointSurface = app.descendants(matching: .any)["request-point-location"]
        revealInCard(pointSurface, in: app)
        pointSurface.coordinate(withNormalizedOffset: CGVector(dx: CGFloat(x) / 1000,
                                                                dy: CGFloat(y) / 1000)).tap()
        let pointValue = app.staticTexts["request-point-value-location"]
        XCTAssertTrue(pointValue.waitForExistence(timeout: 5))
        let components = pointValue.label
            .replacingOccurrences(of: "Horizontal ", with: "")
            .replacingOccurrences(of: "vertical ", with: "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count == 2 else {
            XCTFail("The point control must expose its saved integer coordinates.")
            return PointValue(x: x, y: y)
        }
        let selected = PointValue(x: components[0], y: components[1])
        XCTAssertLessThanOrEqual(abs(selected.x - x), 1,
                                 "The selected point should remain within one normalized unit of the tap.")
        XCTAssertLessThanOrEqual(abs(selected.y - y), 1,
                                 "The selected point should remain within one normalized unit of the tap.")
        return selected
    }

    private func submitFacilitiesAnswer(in app: XCUIApplication, x: Int, y: Int) -> PointValue {
        selectFacilitiesRequest(in: app)
        return answerSelectedFacilitiesRequest(in: app, x: x, y: y)
    }

    private func answerSelectedFacilitiesRequest(in app: XCUIApplication, x: Int, y: Int) -> PointValue {
        let selectedPoint = setFacilitiesPoint(in: app, x: x, y: y)
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
        return selectedPoint
    }

    private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()
        return app
    }

}
