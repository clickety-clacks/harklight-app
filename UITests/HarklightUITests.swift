import XCTest
import AttentionDomain

@MainActor
final class HarklightUITests: XCTestCase {
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
        let note = app.textFields["request-input-note"]
        revealInCard(note, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot("Sender scene note field", from: app)
        XCTAssertTrue(app.staticTexts["Select the location on the floor plan and add a note."]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["request-lifecycle-status"].exists,
                       "The card omits the extra Open status line from the design.")
        XCTAssertFalse(app.staticTexts["fixture:Facilities"].exists,
                       "Raw fixture identity stays in request details, not the task framing.")
        XCTAssertFalse(app.buttons["fixture-outcome-menu"].exists,
                        "Fixture outcomes are available only after an answer enters Pending.")

        let centerPoint = setFacilitiesPoint(in: app, x: 500, y: 500)
        openRequestDetails(in: app)
        XCTAssertTrue(app.staticTexts["Sender: fixture:Facilities"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Message: facilities-01"].exists)
        let originalContent = app.staticTexts["request-original-content-json"]
        XCTAssertTrue(originalContent.waitForExistence(timeout: 5))
        XCTAssertTrue(originalContent.label.contains("facilities-01"))
        attachScreenshot("Request history sheet", from: app)
        app.buttons["request-details-done"].tap()
        let retainedPoint = app.staticTexts["request-point-value-location"]
        revealInCard(retainedPoint, in: app)
        XCTAssertEqual(retainedPoint.label,
                       "Horizontal \(centerPoint.x), vertical \(centerPoint.y)",
                       "Inspecting request details must preserve the active point draft.")

        let submittedPoint = setFacilitiesPoint(in: app, x: 240, y: 500)
        note.tap()
        note.typeText("Near the east entrance")
        XCTAssertEqual(note.value as? String, "Near the east entrance",
                       "The editor must retain every character before the answer is submitted.")

        let finish = app.buttons["request-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(finish.isEnabled, "A valid point and note should enable the shared answer action.")
        finish.tap()
        let lifecycle = app.staticTexts["request-lifecycle-status"]
        XCTAssertTrue(lifecycle.waitForExistence(timeout: 5))
        XCTAssertEqual(lifecycle.label, "Pending",
                       "A local submission remains pending until its fixture outcome is explicitly simulated.")
        XCTAssertTrue(app.buttons["fixture-outcome-menu"].waitForExistence(timeout: 5),
                      "The local outcome simulation appears on the ordinary pending fixture card.")
        assertExactFacilitiesReceipt(in: app, point: submittedPoint)
    }

    func testAnswerRemainsAvailableWhileRefreshIsRunning() throws {
        let app = launchFreshApp(additionalArguments: ["--harklight-test-refreshing"])
        let refreshing = app.descendants(matching: .any)["inbox-refreshing-badge"]
        XCTAssertTrue(refreshing.waitForExistence(timeout: 5), app.debugDescription)
        let brand = app.descendants(matching: .any)["inbox-brand"]
        XCTAssertTrue(brand.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(refreshing.frame.midY, brand.frame.midY, accuracy: 1,
                       "The refresh badge stays in the title row.")
        XCTAssertGreaterThanOrEqual(refreshing.frame.minX, brand.frame.maxX)
        XCTAssertLessThan(refreshing.frame.minX - brand.frame.maxX, 16,
                          "The refresh badge sits immediately to the right of the title.")
        attachScreenshot("Inbox badge while refreshing", from: app)

        selectFacilitiesRequest(in: app)
        _ = setFacilitiesPoint(in: app, x: 240, y: 500)

        let note = app.textFields["request-input-note"]
        revealInCard(note, in: app)
        note.tap()
        note.typeText("Near the east entrance")

        let finish = app.buttons["request-finish"]
        XCTAssertTrue(finish.isEnabled,
                      "A refresh must not dim or disable the visible answer action.")
        attachScreenshot("Answer available while inbox is refreshing", from: app)
        finish.tap()

        let lifecycle = app.staticTexts["request-lifecycle-status"]
        XCTAssertTrue(lifecycle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(lifecycle.label, "Pending")
        attachScreenshot("Answer submitted while inbox is refreshing", from: app)
    }

    func testStaleAnswerDialogShowsChangedMessage() throws {
        let app = launchFreshApp(additionalArguments: ["--harklight-test-stale-answer"])
        let alert = app.alerts["The message changed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        let changedMessage = alert.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Updated request:")).firstMatch
        XCTAssertTrue(changedMessage.waitForExistence(timeout: 5), app.debugDescription)
        let reviewMessage = alert.buttons["Review message"]
        XCTAssertTrue(reviewMessage.isHittable,
                      "The person can open the new version and answer again.")
        attachScreenshot("Stale answer shows updated message", from: app)
        reviewMessage.tap()

        XCTAssertTrue(app.buttons["request-finish"].waitForExistence(timeout: 5),
                      "Reviewing the changed message returns to its answer control.\n\(app.debugDescription)")
    }

    func testConnectionWarningButtonShowsTheObservedError() throws {
        let app = launchFreshApp(additionalArguments: ["--harklight-test-connection-warning"])
        let warningButton = app.buttons["inbox-warning-button"]
        let message = app.staticTexts["inbox-warning-message"]
        if message.waitForExistence(timeout: 1) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.10)).tap()
            XCTAssertFalse(message.waitForExistence(timeout: 1), app.debugDescription)
        }
        XCTAssertTrue(warningButton.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(warningButton.isHittable, app.debugDescription)
        warningButton.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(message.label, "The approved server could not be reached.")
        attachScreenshot("Tapped connection warning shows its error", from: app)
    }

    func testUntouchedRequestStartsInInbox() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()

        let inboxTab = workspaceTab("Inbox", in: app)
        let repliedTab = workspaceTab("Replied", in: app)
        XCTAssertTrue(inboxTab.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(repliedTab.exists, app.debugDescription)
        XCTAssertTrue(inboxTab.isSelected)
        attachScreenshot("Inbox list", from: app)

        let facilities = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(facilities.waitForExistence(timeout: 5),
                      "An untouched request belongs in Inbox.\n\(app.debugDescription)")
        repliedTab.tap()
        attachScreenshot("Empty Replied list", from: app)
        XCTAssertFalse(facilities.waitForExistence(timeout: 2),
                       "An untouched request does not appear in Replied.")
    }
    func testAcceptedAnswerShowsKnownAnsweredSceneThroughSharedFixture() throws {
        let app = launchFreshApp()
        let submittedPoint = submitFacilitiesAnswer(in: app, x: 240, y: 610)

        applyFixtureOutcome("ownOperationAccepted", in: app)

        let inbox = workspaceTab("Inbox", in: app)
        XCTAssertTrue(app.buttons["request-finish"].waitForNonExistence(timeout: 5),
                      "A confirmed accepted answer returns the compact detail to the list.")
        XCTAssertTrue(inbox.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(inbox.isSelected,
                      "The automatic return keeps the tab the user entered from.")
        XCTAssertFalse(app.buttons["inbox-warning-button"].exists,
                       "A resolved send raises no unresolved-send warning.")
        attachScreenshot("Accepted answer returns to the list", from: app)

        workspaceTab("Replied", in: app).tap()
        let row = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()

        let answeredControl = app.buttons["request-answered"]
        XCTAssertTrue(answeredControl.waitForExistence(timeout: 5),
                      "An accepted answer shows Answered on the toolbar checkmark.")
        XCTAssertEqual(answeredControl.value as? String, "Completed",
                       "The Answered checkmark presents its completed state like Seen does.")
        XCTAssertFalse(answeredControl.isEnabled,
                       "The Answered state is a completed status, not an action.")
        XCTAssertFalse(app.staticTexts["request-lifecycle-status"].exists,
                       "The content area omits the redundant Answered status line.")
        XCTAssertFalse(app.staticTexts["request-receipt-evidence"].exists,
                       "Internal evidence wording stays out of the content area.")
        let knownPoint = app.descendants(matching: .any)["Established submitted location"].firstMatch
        XCTAssertTrue(knownPoint.waitForExistence(timeout: 5),
                      "The accepted original operation should select the known sender result scene.")
        XCTAssertEqual(knownPoint.value as? String,
                       "Horizontal \(submittedPoint.x), vertical \(submittedPoint.y)")

        assertExactFacilitiesReceipt(in: app, point: submittedPoint)
    }

    func testServerAnsweredAfterUnconfirmedSendMovesToRepliedWithoutClaimingAcceptance() throws {
        let app = launchFreshApp()
        let submittedPoint = submitFacilitiesAnswer(in: app, x: 240, y: 610)

        applyFixtureOutcome("answerOutcomeUnconfirmed", in: app)

        let answeredControl = app.buttons["request-answered"]
        XCTAssertTrue(answeredControl.waitForExistence(timeout: 5),
                      "A server-answered request shows Answered on the toolbar checkmark.")
        XCTAssertFalse(app.staticTexts["request-lifecycle-status"].exists,
                       "The content area omits the redundant Answered status line.")
        XCTAssertFalse(app.staticTexts["request-receipt-evidence"].exists,
                       "Internal evidence wording stays out of the content area.")
        XCTAssertFalse(app.descendants(matching: .any)["Established submitted location"].exists,
                       "An unconfirmed closure must keep the neutral sender scene.")

        assertExactFacilitiesReceipt(in: app, point: submittedPoint)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        let inbox = workspaceTab("Inbox", in: app)
        let row = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(inbox.isSelected,
                      "A lost or unconfirmed response leaves the user on Inbox.")
        XCTAssertFalse(row.waitForExistence(timeout: 2),
                       "A server-answered request no longer appears in Inbox.")
        XCTAssertFalse(app.staticTexts["Answer sent · result not confirmed"].exists,
                       "A server-answered request is not shown as a failed response.")
        XCTAssertFalse(app.staticTexts["Answered locally · nothing sent"].exists,
                       "The list must not claim this device's answer was accepted.")
        attachScreenshot("Server-answered response removed from Inbox", from: app)

        workspaceTab("Replied", in: app).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The server-answered request appears in Replied.")
        XCTAssertFalse(app.staticTexts["Answer sent · result not confirmed"].exists)
        XCTAssertFalse(app.staticTexts["Answered locally · nothing sent"].exists)
        attachScreenshot("Server-answered response in Replied", from: app)
    }

    func testUnresolvedSendRaisesPlainLanguageWarningPopup() throws {
        let app = launchFreshApp()
        _ = submitFacilitiesAnswer(in: app, x: 240, y: 610)

        applyFixtureOutcome("cleared", in: app)

        // A fresh warning auto-presents the warning popover, including over
        // the request detail, so its message is readable without navigating
        // back or tapping the warning button (which the open popover covers).
        let message = app.staticTexts["inbox-warning-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10),
                      "A send left without a confirmed result raises the inbox warning.")
        XCTAssertEqual(message.label,
                       "A request closed without a confirmed result for your answer. Your answer stays saved on this device.",
                       "The popup explains the unresolved send in plain language.")
        attachScreenshot("Unresolved send warning popup", from: app)
    }

    func testNativeBackKeepsInboxListPositionForUntouchedRequest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples", "--harklight-ui-diagnostics"]
        app.launch()
        let list = app.collectionViews.firstMatch
        let facilities = app.descendants(matching: .any)["request-row-facilities-01"]
        let review = app.descendants(matching: .any)["request-row-review-01"]
        let others = [app.descendants(matching: .any)["request-row-unknown-01"], review]
        XCTAssertTrue(facilities.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(others.allSatisfy { $0.waitForExistence(timeout: 5) }, app.debugDescription)
        let examples = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sample-'"))
        XCTAssertTrue(examples.firstMatch.waitForExistence(timeout: 10),
                      "Local examples make the list long enough to scroll.")
        let brand = app.descendants(matching: .any)["inbox-brand"]
        XCTAssertTrue(brand.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(others.contains { $0.frame.minY > facilities.frame.minY },
                      "The request starts above other open requests in the Inbox.")

        // Scroll part of a row so the position Back must keep is not the list's top.
        let top = ([facilities] + others).min { $0.frame.minY < $1.frame.minY }!
        let unscrolledAnchor = review.frame.minY - list.frame.minY
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -(top.frame.height * 0.5 + 20))),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        let scrolledAnchor = review.frame.minY - list.frame.minY
        XCTAssertLessThan(scrolledAnchor, unscrolledAnchor - 10,
                          "The tapped request must be scrolled within the list.")

        let headerHidden = expectation(for: NSPredicate(format: "isHittable == false"),
                                       evaluatedWith: brand)
        wait(for: [headerHidden], timeout: 5)
        XCTAssertTrue(review.isHittable, app.debugDescription)
        review.tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5),
                      "The detail card, rather than the matching list row, confirms navigation.")
        attachScreenshot("Native detail back control", from: app)

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["harklight-detail-back"].exists,
                       "Detail uses the native navigation back control.")
        back.tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(review.isHittable, "Back returns the tapped request to the visible list.")
        XCTAssertTrue(workspaceTab("Inbox", in: app).isSelected)
        XCTAssertTrue(review.exists, "The tapped untouched request remains in Inbox after native Back.")
        XCTAssertTrue(facilities.exists, "The other untouched request remains in Inbox after native Back.")
        attachScreenshot("Last viewed row in Inbox", from: app)
        let kept = NSPredicate { _, _ in
            abs((review.frame.minY - list.frame.minY) - scrolledAnchor) <= 1
        }
        let keptPosition = XCTNSPredicateExpectation(predicate: kept, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [keptPosition], timeout: 3), .completed,
                       "Back without switching messages must preserve the tapped row's position within the list: \(review.frame.minY - list.frame.minY), expected \(scrolledAnchor).\n\(app.debugDescription)")
    }

    func testSplitViewAdaptationKeepsTheSelectedMessage() {
        XCUIDevice.shared.orientation = .portrait
        let app = launchFreshApp()
        let facilities = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(facilities.waitForExistence(timeout: 10), app.debugDescription)
        facilities.tap()
        XCTAssertTrue(app.staticTexts["Facilities desk"].waitForExistence(timeout: 5))
        attachScreenshot("Selected detail in portrait before split adaptation", from: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Facilities desk"].waitForExistence(timeout: 5),
                      "Changing to the wide split view must keep the selected message.")
        attachScreenshot("Selected detail after landscape split adaptation", from: app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["Facilities desk"].waitForExistence(timeout: 5),
                      "Adapting back to compact layout must not count as leaving the message.")
        attachScreenshot("Selected detail after compact split adaptation", from: app)

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(facilities.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testNativeInteractiveBackReturnsToSearchableList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()
        let facilities = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(facilities.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(facilities.label.contains("Facilities"), facilities.label)
        XCTAssertFalse(facilities.label.contains("fixture:"), facilities.label)
        let settings = app.buttons["inbox-settings"]
        XCTAssertTrue(settings.isHittable)
        attachScreenshot("Inbox list with collapsed controls", from: app)
        facilities.tap()
        XCTAssertTrue(app.staticTexts["Facilities desk"].waitForExistence(timeout: 5))
        attachScreenshot("Request detail", from: app)

        let back = workspaceBackButton(in: app)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["harklight-detail-back"].exists,
                       "Detail uses the native navigation back control.")
        back.tap()
        XCTAssertTrue(facilities.waitForExistence(timeout: 5),
                      "Back must return to the same inbox list.")
        facilities.tap()
        XCTAssertTrue(app.staticTexts["Facilities desk"].waitForExistence(timeout: 5))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.25))
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let returnedToInbox = facilities.waitForExistence(timeout: 5)
        if !returnedToInbox { attachScreenshot("Detail after native edge swipe", from: app) }
        XCTAssertTrue(returnedToInbox, "An edge swipe from detail must return to the inbox list.\n\(app.debugDescription)")
        XCTAssertTrue(facilities.isHittable, app.debugDescription)

        let field = workspaceSearchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "The native list search should focus and show the keyboard.")
        // Native active search may collapse the title and trailing actions.
        attachScreenshot("Native list search with keyboard", from: app)

        field.typeText("preview could not\n")
        let notice = app.descendants(matching: .any)["sample-error-0"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(notice.label.contains("Collection assistant"), notice.label)
        attachScreenshot("Sample row in shared list renderer", from: app)
        notice.tap()
        let seenAction = app.buttons["request-seen-action"]
        XCTAssertTrue(seenAction.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(seenAction.isEnabled,
                      "The restored body Seen action performs the same response as the toolbar check.")
        XCTAssertEqual(app.buttons.matching(identifier: "request-seen-action").count, 1)
        XCTAssertFalse(app.buttons["Later"].exists,
                       "Request detail does not offer a Later action.")
        XCTAssertFalse(app.staticTexts["Not now"].exists)
        let finishSeen = app.buttons["request-finish-seen"]
        if !finishSeen.exists || !finishSeen.isEnabled {
            attachScreenshot("Seen toolbar before action", from: app)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Seen toolbar accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(finishSeen.exists,
                      "The top check must be present.\n\(app.debugDescription)")
        XCTAssertTrue(finishSeen.isEnabled,
                      "The top check must perform the Seen action.\n\(app.debugDescription)")
        XCTAssertEqual(app.buttons.matching(identifier: "request-finish-seen").count, 1,
                       "Notice detail keeps one toolbar Seen control.")
        XCTAssertFalse(app.staticTexts["Seen available"].exists)
        attachScreenshot("Notice detail Seen available", from: app)
        finishSeen.tap()
        XCTAssertTrue(app.staticTexts["Seen selected locally · nothing sent"].waitForExistence(timeout: 5))
        XCTAssertTrue(finishSeen.exists,
                      "The Seen button stays in place after the action.")
        XCTAssertTrue(finishSeen.label.contains("Seen"), finishSeen.label)
        XCTAssertEqual(finishSeen.value as? String, "Completed")
        XCTAssertFalse(finishSeen.isEnabled,
                       "The completed toolbar Seen button cannot be tapped again.")
        XCTAssertTrue(seenAction.exists,
                      "The body Seen action remains alongside the toolbar check.")
        XCTAssertFalse(seenAction.isEnabled,
                       "The completed body Seen action cannot be tapped again.")
        XCTAssertEqual(app.buttons.matching(identifier: "request-seen-action").count, 1,
                       "The restored body Seen control remains singular after completion.")
        XCTAssertEqual(app.buttons.matching(identifier: "request-finish-seen").count, 1,
                       "The completed toolbar Seen control stays in place by itself.")
        let compactSeenControl = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = finishSeen.frame
            return frame.width > 70 && frame.width < 160 && frame.height < 60
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [compactSeenControl], timeout: 3), .completed,
                       "The confirmed Seen label must settle into one compact toolbar button.")
        attachScreenshot("Notice detail Seen completed", from: app)
    }

    func testTextChoiceCardMatchesReferenceCapture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()
        let field = workspaceSearchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Which approach\n")
        let row = app.descendants(matching: .any)["sample-textChoice-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        let approach = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Plan the whole space")).firstMatch
        XCTAssertTrue(approach.waitForExistence(timeout: 5), app.debugDescription)
        approach.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: approach)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 5), .completed)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attachScreenshot("Text choice card with selected answer", from: app)
    }

    func testExplicitTierAndFriendlyDateReferenceCapture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-tier-reference"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Top · 8 lines"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Middle · 4 lines"].exists)
        XCTAssertTrue(app.staticTexts["Low · 2 lines"].exists)
        attachScreenshot("Explicit top middle low cell tiers", from: app)
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.staticTexts["Older date"].waitForExistence(timeout: 5))
        attachScreenshot("Friendly date cases in tier fixtures", from: app)
    }

    private func attachScreenshot(_ name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAnsweredRequestMovesToRepliedAndKeepsInboxSelected() throws {
        let app = launchFreshApp(diagnostics: true)
        let facilities = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(facilities.waitForExistence(timeout: 10), app.debugDescription)
        _ = submitFacilitiesAnswer(in: app, x: 240, y: 610)
        applyFixtureOutcome("ownOperationAccepted", in: app)
        XCTAssertTrue(app.buttons["request-finish"].waitForNonExistence(timeout: 5),
                      "A confirmed accepted answer returns the compact detail to the list.")

        let inbox = workspaceTab("Inbox", in: app)
        let replied = workspaceTab("Replied", in: app)
        XCTAssertTrue(inbox.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(inbox.isSelected,
                      "The automatic return keeps the tab the user entered from.")
        XCTAssertFalse(facilities.waitForExistence(timeout: 2),
                       "An answered request leaves the Inbox list.")
        attachScreenshot("Answered request leaves Inbox selected", from: app)

        replied.tap()
        XCTAssertTrue(replied.isSelected, app.debugDescription)
        XCTAssertTrue(facilities.waitForExistence(timeout: 5),
                      "The answered request appears in Replied after the user switches tabs.\n\(app.debugDescription)")
        attachScreenshot("Answered request in Replied", from: app)

        facilities.tap()
        let answeredControl = app.buttons["request-answered"]
        XCTAssertTrue(answeredControl.waitForExistence(timeout: 5),
                      "An accepted answer shows Answered on the toolbar checkmark.")
        attachScreenshot("Replied toolbar confirmed", from: app)
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
        openRequestDetails(in: app)
        let receipt = app.staticTexts["request-details-original-answer-json"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertEqual(receipt.label,
                       "{\"point\":{\"x\":\(point.x),\"y\":\(point.y)},\"note\":\"Near the east entrance\",\"drawingRevision\":9007199254740993}",
                       "The terminal fixture outcome must preserve the exact originally submitted answer.")
        XCTAssertTrue(app.staticTexts["request-details-receipt-evidence"].exists,
                      "The technical receipt evidence remains available in request details.")
        attachScreenshot("Exact saved answer sheet", from: app)
        app.buttons["request-details-done"].tap()
    }

    private func openRequestDetails(in app: XCUIApplication) {
        let heading = app.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let scroll = app.scrollViews["message-card-scroll"]
        let visibleTop = app.navigationBars.firstMatch.frame.maxY
        for _ in 0..<8 {
            if heading.isHittable && heading.frame.minY >= visibleTop { break }
            scroll.swipeDown()
        }
        XCTAssertTrue(heading.isHittable, "The message heading must open request history.")
        XCTAssertGreaterThanOrEqual(heading.frame.minY, visibleTop,
                                    "The heading must be below the navigation bar before tapping it.")
        heading.tap()
        attachScreenshot("Request history interaction", from: app)
        XCTAssertTrue(app.buttons["request-details-done"].waitForExistence(timeout: 5),
                      "Request history must open off the detail card face.\n\(app.debugDescription)")
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

        let backButton = app.navigationBars.buttons.firstMatch
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
        let note = app.textFields["request-input-note"]
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

    private func launchFreshApp(diagnostics: Bool = false,
                                additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        if diagnostics { app.launchArguments.append("--harklight-ui-diagnostics") }
        app.launchArguments.append(contentsOf: additionalArguments)
        app.launch()
        return app
    }

}
