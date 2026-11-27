import XCTest

/// Rendered production views with retained Server frames and explicitly
/// generated non-live content. No customer account or network is involved.
@MainActor
final class FreeRenderedUITests: XCTestCase {
    func testNormalMessageRowOffersSwipeActionFromEitherEdge() {
        // Merely revealing an action must neither answer nor open the message.
        for swipeLeft in [true, false] {
            let app = launchActionableMessage()
            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)
            let normal = element("request-row-sample-approval-0", in: app)
            reveal(normal, in: list)
            if UIDevice.current.userInterfaceIdiom == .pad {
                let start = normal.coordinate(withNormalizedOffset: CGVector(dx: swipeLeft ? 0.78 : 0.22, dy: 0.5))
                let end = normal.coordinate(withNormalizedOffset: CGVector(dx: swipeLeft ? 0.18 : 0.82, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            } else if swipeLeft {
                normal.swipeLeft()
            } else {
                normal.swipeRight()
            }
            let action = app.buttons["inbox-no-comment"]
            let eligible = action.waitForExistence(timeout: 5)
            XCTAssertTrue(eligible, app.debugDescription)
            capture("normal-message-swipe-\(swipeLeft)", app)
            app.terminate()
        }
    }

    private func launchActionableMessage() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-inbox-list-column",
                               "--harklight-test-inbox-list-state=actionableMessage",
                               "--harklight-ui-diagnostics"]
        app.launch()
        return app
    }

    func testCapturedFreeSelectionAndReadTransition() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)
            let provenance = element("free-rendered-provenance", in: app)
            XCTAssertTrue(status(provenance).contains("unread"), app.debugDescription)
            let normalMessage = element("request-row-newer", in: app)
            let normalReply = element("normal-reply-item-older", in: app)
            reveal(normalMessage, in: list)
            reveal(normalReply, in: list)
            XCTAssertTrue(status(provenance).contains("unread"), "List visibility must not mark chat Seen.")
            capture("free-\(appearance)-captured-normal", app)

            // Select the request and return to its normal row.
            reveal(normalMessage, in: list, downward: true)
            normalMessage.tap()
            let heading = app.buttons["request-heading"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(heading.label.contains("Generated newer parent"), app.debugDescription)
            capture("free-\(appearance)-selected-own-parent", app)
            returnToInbox(app)
            XCTAssertTrue(normalMessage.isHittable,
                          "Return must reveal the existing own row after selection.\n\(app.debugDescription)")
            XCTAssertTrue(status(provenance).contains("unread"), "Selecting a different parent does not read this chat.")
            capture("free-\(appearance)-own-row-after-selection", app)

            // The reply opens its own parent's chat at the retained target.
            reveal(normalReply, in: list)
            normalReply.tap()
            let replyText = app.staticTexts["Generated reply for the captured older chat"]
            XCTAssertTrue(replyText.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(replyText.isHittable, app.debugDescription)
            XCTAssertTrue(heading.label.contains("Generated older parent"), app.debugDescription)
            let read = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'read=2'"),
                                                  object: provenance)
            XCTAssertEqual(XCTWaiter.wait(for: [read], timeout: 5), .completed, app.debugDescription)
            capture("free-\(appearance)-chat-read-target", app)
            dismissChat(app)
            returnToInbox(app)
            let history = app.staticTexts["History"]
            reveal(history, in: list)
            reveal(normalReply, in: list)
            XCTAssertTrue(history.exists, app.debugDescription)
            XCTAssertGreaterThan(normalReply.frame.minY, history.frame.minY)
            XCTAssertTrue(status(provenance).contains("Captured history"), app.debugDescription)
            capture("free-\(appearance)-captured-history", app)
            app.terminate()
        }
    }

    func testGeneratedLegacySectionsAreTruthfulAndHistoryRemainsReachable() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance, legacy: true)
            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(status(element("free-rendered-provenance", in: app)).contains("Generated legacy"))
            let active = element("request-row-active-common", in: app)
            reveal(active, in: list)
            capture("free-\(appearance)-generated-legacy-active", app)
            let earlier = app.staticTexts["Earlier activity"].firstMatch
            reveal(earlier, in: list)
            XCTAssertTrue(app.staticTexts["Earlier messages"].firstMatch.exists, app.debugDescription)
            let explanation = app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS 'their combined arrival order is unavailable'" )).firstMatch
            XCTAssertTrue(explanation.exists, app.debugDescription)
            capture("free-\(appearance)-generated-earlier-messages", app)
            let unknown = element("normal-reply-item-active-unknown", in: app)
            reveal(unknown, in: list)
            XCTAssertTrue(app.staticTexts["Earlier chat replies"].firstMatch.exists, app.debugDescription)
            XCTAssertTrue(app.staticTexts["Arrival order unavailable"].firstMatch.exists, app.debugDescription)
            capture("free-\(appearance)-generated-unknown-order", app)
            let historical = element("request-row-history-common", in: app)
            reveal(historical, in: list)
            XCTAssertTrue(app.staticTexts["History"].exists, app.debugDescription)
            capture("free-\(appearance)-generated-subdued-history", app)
            // This row required an actual list scroll, unlike the small
            // captured view. Returning must preserve its stable row target.
            // Tap its upper part: the floating list toolbar can cover its centre.
            historical.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            let heading = app.buttons["request-heading"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(heading.label.contains("Common historical message"), app.debugDescription)
            capture("free-\(appearance)-scrolled-history-selected", app)
            returnToInbox(app)
            XCTAssertTrue(historical.isHittable, "Return must preserve the scrolled history row.\n\(app.debugDescription)")
            capture("free-\(appearance)-scrolled-history-return", app)
            let historicalUnknown = element("normal-reply-item-history-unknown", in: app)
            reveal(historicalUnknown, in: list)
            capture("free-\(appearance)-generated-legacy-history", app)
            app.terminate()
        }
    }

    private func launch(_ appearance: String, legacy: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--free-rendered", "--harklight-ui-diagnostics",
                               "--harklight-test-inbox-list-\(appearance)"]
        if legacy { app.launchArguments.append("--free-rendered-legacy") }
        app.launch()
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func status(_ element: XCUIElement) -> String {
        element.value as? String ?? ""
    }

    private func reveal(_ element: XCUIElement, in list: XCUIElement, downward: Bool = false) {
        for _ in 0..<12 where !element.isHittable {
            if downward { list.swipeDown() } else { list.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, "Expected visible element: \(element.debugDescription)")
    }

    private func returnToInbox(_ app: XCUIApplication) {
        if app.scrollViews["message-card-scroll"].exists {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.isHittable, app.debugDescription)
            back.tap()
        }
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func dismissChat(_ app: XCUIApplication) {
        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.exists, app.debugDescription)
        history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
            .press(forDuration: 0.1, thenDragTo: history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(history.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
