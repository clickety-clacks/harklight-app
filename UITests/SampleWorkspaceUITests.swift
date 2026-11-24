import UIKit
import XCTest

@MainActor
final class SampleWorkspaceUITests: XCTestCase {
    override func setUpWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testInboxSortSwitchesBetweenServerPriorityAndOriginalPostingTime() {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-test-inbox-sort"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        let sort = app.buttons["inbox-sort"]
        guard sort.waitForExistence(timeout: 5) else {
            XCTFail("The main Inbox toolbar needs a Priority / Posted control.")
            return
        }
        XCTAssertEqual(sort.label, "Sort: Priority")
        let higher = app.buttons["request-row-sort-higher"]
        let newer = app.buttons["request-row-sort-newer"]
        XCTAssertTrue(higher.waitForExistence(timeout: 5))
        XCTAssertTrue(newer.exists)
        XCTAssertLessThan(higher.frame.minY, newer.frame.minY)
        assertInboxDate(1_700_000_000_000, in: higher)
        assertInboxDate(1_700_172_800_000, in: newer)
        capture("Inbox Priority order", app)

        if isPad {
            higher.tap()
            XCTAssertTrue(app.buttons["request-heading"].waitForExistence(timeout: 5))
        }
        sort.tap()
        app.buttons["Posted"].tap()
        XCTAssertEqual(sort.label, "Sort: Posted")
        XCTAssertLessThan(newer.frame.minY, higher.frame.minY)
        assertInboxDate(1_700_172_800_000, in: newer)
        assertInboxDate(1_700_000_000_000, in: higher)
        if isPad {
            XCTAssertTrue(app.buttons["request-heading"].label.contains("Older priority message"))
            XCTAssertTrue(higher.isSelected)
        }
        capture("Inbox Posted order", app)
        if !isPad {
            newer.tap()
            let heading = app.buttons["request-heading"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5))
            XCTAssertTrue(heading.label.contains("Newest posted message"))
            showList(app)
            XCTAssertTrue(sort.waitForExistence(timeout: 5))
            XCTAssertEqual(sort.label, "Sort: Posted")
        }

        sort.tap()
        app.buttons["Priority"].tap()
        XCTAssertEqual(sort.label, "Sort: Priority")
        XCTAssertLessThan(higher.frame.minY, newer.frame.minY)
        sort.tap()
        app.buttons["Posted"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        XCTAssertEqual(sort.label, "Sort: Priority")
    }

    func testInboxSortUsesTheExistingReplyDateWhenTheQuoteHasNoTimestamp() {
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-test-inbox-sort-reply"]
        app.launch()
        defer { app.terminate() }

        let reply = app.buttons["normal-reply-item-reply-parent"]
        let message = app.buttons["request-row-dated-message"]
        guard reply.waitForExistence(timeout: 5), message.exists else {
            XCTFail("The cached reply and comparison message must be visible.")
            return
        }
        XCTAssertLessThan(message.frame.minY, reply.frame.minY)
        assertInboxDate(1_700_432_000_000, in: reply)
        let sort = app.buttons["inbox-sort"]
        sort.tap()
        app.buttons["Posted"].tap()
        XCTAssertLessThan(reply.frame.minY, message.frame.minY)
        assertInboxDate(1_700_432_000_000, in: reply)
    }

    func testInboxSortScrollsToASelectedThreadMemberWhenItRegroups() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("A split Inbox is needed to sort while the detail stays visible.")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-test-inbox-sort-thread"]
        app.launch()
        defer { app.terminate() }

        // The disclosure can give its identifier to nested rows. Find the row by its own label.
        let listButtons = app.buttons.matching(NSPredicate(format: "identifier != %@", "request-heading"))
        let selected = listButtons.matching(NSPredicate(format: "label CONTAINS %@", "Selected thread message"))
            .firstMatch
        let previousMember = listButtons.matching(NSPredicate(format: "label CONTAINS %@", "Thread message 12"))
            .firstMatch
        let sort = app.buttons["inbox-sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        XCTAssertFalse(selected.isHittable, "The Priority group starts collapsed below the visible rows.")
        sort.tap()
        app.buttons["Posted"].tap()
        XCTAssertEqual(sort.label, "Sort: Posted")
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !selected.isHittable {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.84))
                .press(forDuration: 0.05, thenDragTo:
                    list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36)))
        }
        XCTAssertTrue(selected.isHittable, "The thread member can be selected in Posted.")
        selected.tap()
        let heading = app.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.label.contains("Selected thread message"))

        if !sort.isHittable { list.swipeDown() } // Reveal the sidebar toolbar after scrolling.
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        sort.tap()
        app.buttons["Priority"].tap()
        XCTAssertEqual(sort.label, "Sort: Priority")
        assertInboxRowInView(selected, "Priority should reopen and scroll to the member's group.")
        XCTAssertTrue(previousMember.isHittable)
        XCTAssertLessThan(previousMember.frame.minY, selected.frame.minY)
        XCTAssertTrue(heading.label.contains("Selected thread message"))
        capture("Inbox Priority regrouped selected thread member", app)

        if !sort.isHittable { list.swipeDown() }
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        sort.tap()
        app.buttons["Posted"].tap()
        XCTAssertEqual(sort.label, "Sort: Posted")
        assertInboxRowInView(selected, "Posted should scroll back to the selected row.")
        XCTAssertTrue(previousMember.isHittable)
        XCTAssertLessThan(selected.frame.minY, previousMember.frame.minY)
        XCTAssertTrue(heading.label.contains("Selected thread message"))
        capture("Inbox Posted selected thread member", app)
    }

    private func assertInboxRowInView(_ row: XCUIElement, _ reason: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            row.exists && row.isHittable && row.isSelected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, reason, file: file, line: line)
    }

    private func assertInboxDate(_ milliseconds: Double, in row: XCUIElement,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let date = formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
        XCTAssertTrue(row.label.contains(date) || row.staticTexts[date].exists,
                      "Expected row date \(date), got \(row.label).", file: file, line: line)
    }

    func testInboxSortKeepsSearchAndRepliedBehavior() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-test-inbox-sort"]
        app.launch()
        defer { app.terminate() }

        let sort = app.buttons["inbox-sort"]
        guard sort.waitForExistence(timeout: 5) else {
            XCTFail("The Inbox sort control is missing.")
            return
        }
        sort.tap()
        app.buttons["Posted"].tap()

        enterSearch("Older priority message", in: app)
        XCTAssertTrue(app.buttons["request-row-sort-higher"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["request-row-sort-newer"].exists)
        XCTAssertFalse(sort.exists)
        clearSearch(in: app)
        let inbox = workspaceTab("Inbox", in: app)
        if inbox.exists && !inbox.isSelected { inbox.tap() }

        let replied = workspaceTab("Replied", in: app)
        XCTAssertTrue(replied.waitForExistence(timeout: 5))
        replied.tap()
        XCTAssertFalse(sort.exists)
        XCTAssertTrue(app.buttons["request-row-sort-answered"].waitForExistence(timeout: 5))
        inbox.tap()
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        XCTAssertEqual(sort.label, "Sort: Posted")
    }

    func testFYIDigestOpensListInNavigationAndSortChangesOrder() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-ui-diagnostics"]
        app.launch()
        defer { app.terminate() }

        openFYIListIfNeeded(app)
        let sort = app.buttons["fyi-sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Done"].exists)
        let list = app.collectionViews["fyi-list"]
        let garden = list.staticTexts["Community garden"]
        let museum = list.staticTexts["Museum hours"]
        XCTAssertTrue(garden.exists)
        XCTAssertTrue(museum.exists)
        XCTAssertLessThan(garden.frame.minY, museum.frame.minY)
        capture("FYI list in its navigation pane", app)
        sort.tap()
        app.buttons["Posted"].tap()
        XCTAssertLessThan(museum.frame.minY, garden.frame.minY)
        XCTAssertTrue(sort.label.contains("Posted"))

        garden.tap()
        XCTAssertTrue(app.buttons["request-heading"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["1 of 2"].exists,
                       "FYI detail should not expose ordinary Inbox paging.")
        capture("FYI normal detail in its navigation pane", app)
        let back = app.navigationBars.buttons["FYIs"].firstMatch
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        XCTAssertTrue(sort.label.contains("Posted"))

        let firstBody = list.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "The museum is open")).firstMatch
        XCTAssertTrue(firstBody.waitForExistence(timeout: 5))
        firstBody.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["request-heading"].waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        XCTAssertTrue(sort.label.contains("Posted"))

        let blank = list.cells.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.36))
        blank.tap()
        XCTAssertTrue(app.buttons["request-heading"].waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(sort.waitForExistence(timeout: 5))

        capture("FYI list with posted order", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(sort.waitForExistence(timeout: 10), "The FYI list should reopen for the same account.")
    }

    func testFYISeenCanBeRevealedFromEitherEdgeOnTheBodyWithoutFullSwipe() {
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list"]
        app.launch()
        defer { app.terminate() }
        openFYIListIfNeeded(app)
        let list = app.collectionViews["fyi-list"]
        let seen = app.buttons["Seen"].firstMatch
        for text in ["The community garden reopened", "The museum is open"] {
            let body = list.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
            XCTAssertTrue(body.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons["Mark All Seen"].isEnabled)
            body.swipeRight()
            XCTAssertTrue(seen.waitForExistence(timeout: 3), "Leading swipe on \(text)")
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.77)).tap()
            body.swipeLeft()
            XCTAssertTrue(seen.waitForExistence(timeout: 3), "Trailing swipe on \(text)")
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.77)).tap()
            XCTAssertTrue(app.buttons["Mark All Seen"].isEnabled, "A swipe alone cannot mark a FYI Seen.")
        }
    }


    func testFinishedProgressSeenButtonShowsPendingWithoutOfferingAnotherSwipe() {
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-test-fyi-finished-progress",
                               "--harklight-test-fyi-plain-seen"]
        app.launch()
        defer { app.terminate() }
        openFYIListIfNeeded(app)

        let list = app.collectionViews["fyi-list"]
        let row = list.staticTexts["Progress with a Seen response"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let seen = app.buttons["request-seen-action"]
        XCTAssertTrue(seen.waitForExistence(timeout: 5))
        seen.tap()
        XCTAssertTrue(app.staticTexts["Seen pending confirmation"].waitForExistence(timeout: 5))
        XCTAssertFalse(seen.exists)
        app.navigationBars.buttons["FYIs"].tap()
        let pending = list.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Seen pending confirmation")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Waiting for confirmation"].exists)
        XCTAssertFalse(app.buttons["Mark All Seen"].isEnabled)
        capture("Progress FYI Seen pending in list", app)
        row.swipeLeft()
        XCTAssertFalse(app.buttons["Seen"].exists)
    }

    func testConfirmedFYILeavesTheRestoredListAndLastSeenLeavesAnEmptyState() {
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list"]
        app.launch()
        defer { app.terminate() }

        openFYIListIfNeeded(app)
        let list = app.collectionViews["fyi-list"]
        XCTAssertTrue(list.staticTexts["Community garden"].waitForExistence(timeout: 5))
        capture("FYIs before confirmed Seen", app)

        app.terminate()
        app.launchArguments.append("--harklight-test-fyi-garden-seen")
        app.launch()
        XCTAssertTrue(app.buttons["fyi-sort"].waitForExistence(timeout: 5))
        XCTAssertFalse(list.staticTexts["Community garden"].exists)
        XCTAssertTrue(list.staticTexts["Museum hours"].exists)
        capture("FYIs after one confirmed Seen", app)

        app.terminate()
        app.launchArguments.append("--harklight-test-fyi-plain-seen")
        app.launch()
        XCTAssertTrue(app.staticTexts["All FYIs are seen"].waitForExistence(timeout: 5))
        XCTAssertFalse(list.staticTexts["Museum hours"].exists)
        XCTAssertFalse(app.buttons["Mark All Seen"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["inbox-fyi"].firstMatch.exists)
        capture("Empty FYIs and disabled Mark All Seen", app)
    }

    func testEndedFYIProgressOpensOrdinaryDetailFromInboxSearch() {
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-test-fyi-ended-progress",
                               "--harklight-test-fyi-plain-seen"]
        app.launch()
        defer { app.terminate() }

        XCTAssertFalse(app.descendants(matching: .any)["inbox-fyi"].firstMatch.exists)
        let field = workspaceSearchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Progress with a Seen response")
        let result = app.staticTexts["Progress with a Seen response"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let heading = app.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.label.contains("Progress with a Seen response"))
        XCTAssertFalse(app.staticTexts["Progress unavailable"].exists)
    }

    func testRepliedFYIsHaveTheirOwnListAndControls() {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-test-fyi-garden-seen",
                               "--harklight-test-fyi-tab-switch"]
        app.launch()
        defer { app.terminate() }

        if isPad {
            openFYIListIfNeeded(app)
            XCTAssertTrue(app.collectionViews["fyi-list"].staticTexts["Museum hours"].exists)
        }
        workspaceTab("Replied", in: app).tap()
        let card = app.buttons["replied-fyi"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("Seen FYIs"))
        XCTAssertFalse(card.label.contains("unseen"))
        XCTAssertFalse(app.descendants(matching: .any)["request-row-legacy/fyi-garden"].firstMatch.exists)
        if !isPad { card.tap() }
        let list = app.collectionViews["fyi-list"]
        XCTAssertTrue(list.staticTexts["Community garden"].waitForExistence(timeout: 5))
        XCTAssertFalse(list.staticTexts["Museum hours"].exists)
        XCTAssertFalse(app.buttons["Mark All Seen"].exists)
        capture("Replied FYIs", app)
        if isPad {
            list.staticTexts["Community garden"].tap()
            XCTAssertTrue(app.buttons["request-heading"].waitForExistence(timeout: 5))
            workspaceTab("Inbox", in: app).tap()
            XCTAssertTrue(list.staticTexts["Museum hours"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["request-heading"].exists)
            workspaceTab("Replied", in: app).tap()
            XCTAssertTrue(list.staticTexts["Community garden"].waitForExistence(timeout: 5))
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(list.staticTexts["Community garden"].waitForExistence(timeout: 5))
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(list.staticTexts["Community garden"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Mark All Seen"].exists)
        if isPad {
            workspaceTab("Inbox", in: app).tap()
            XCTAssertTrue(list.staticTexts["Museum hours"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Mark All Seen"].exists)
            XCTAssertFalse(list.staticTexts["Community garden"].exists)
            capture("Inbox FYIs after switching back", app)
        }
    }

    func testSeenFYICanBeFoundInRepliedSearch() {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-test-fyi-plain-seen"]
        app.launch()
        defer { app.terminate() }

        if !isPad, app.buttons["fyi-sort"].exists {
            workspaceBackButton(in: app).tap()
        }
        workspaceTab("Replied", in: app).tap()
        let field = workspaceSearchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Community garden")
        let result = app.descendants(matching: .any)["request-row-legacy/fyi-garden"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let heading = app.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.label.contains("Community garden"))
    }

    func testLargeRepliedFYIListOpensAndScrolls() {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-test-fyi-bulk-replied"]
        app.launch()
        defer { app.terminate() }

        let replied = workspaceTab("Replied", in: app)
        XCTAssertTrue(replied.waitForExistence(timeout: 10))
        replied.tap()
        let card = app.buttons["replied-fyi"]
        guard card.waitForExistence(timeout: 10) else {
            XCTFail("The bulk Replied card is missing.")
            return
        }
        let start = ProcessInfo.processInfo.systemUptime
        card.tap()
        let list = app.collectionViews["fyi-list"]
        let first = list.staticTexts["Bulletin 1034"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let opened = ProcessInfo.processInfo.systemUptime
        list.swipeUp()
        XCTAssertFalse(first.isHittable)
        let scrolled = ProcessInfo.processInfo.systemUptime
        if isPad {
            for _ in 0..<2 {
                workspaceTab("Inbox", in: app).tap()
                XCTAssertTrue(list.staticTexts["Community garden"].waitForExistence(timeout: 5))
                replied.tap()
                XCTAssertTrue(list.waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["Mark All Seen"].exists)
            }
        }
        let switched = ProcessInfo.processInfo.systemUptime
        print("900 Seen FYIs: open \((opened - start) * 1000) ms, swipe and inspect \((scrolled - opened) * 1000) ms, switch round trips \((switched - scrolled) * 1000) ms")
    }

    func testIPadTabSwitchClearsOtherSideDetailAndRemembersOrdinarySelection() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Regular iPad split view") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()
        defer { app.terminate() }

        let facilities = app.descendants(matching: .any)["request-row-facilities-01"]
        XCTAssertTrue(facilities.waitForExistence(timeout: 5))
        facilities.tap()
        let heading = app.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.label.contains("Facilities desk"))
        workspaceTab("Replied", in: app).tap()
        XCTAssertFalse(heading.exists)
        workspaceTab("Inbox", in: app).tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.label.contains("Facilities desk"))
    }

    func testLargeFYIListOpensAndScrolls() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list", "--harklight-test-fyi-bulk"]
        app.launch()
        defer { app.terminate() }

        let digest = app.descendants(matching: .any)["inbox-fyi"].firstMatch
        guard digest.waitForExistence(timeout: 10) else {
            XCTFail("The bulk fixture should start in Inbox. " + app.debugDescription)
            return
        }
        XCTAssertTrue(digest.label.contains("137 unseen") || app.staticTexts["137 unseen"].exists)
        let start = ProcessInfo.processInfo.systemUptime
        openFYIListIfNeeded(app)
        let list = app.collectionViews["fyi-list"]
        let garden = list.staticTexts["Community garden"]
        XCTAssertTrue(garden.isHittable)
        let opened = ProcessInfo.processInfo.systemUptime
        list.swipeUp()
        XCTAssertFalse(garden.isHittable)
        let scrolled = ProcessInfo.processInfo.systemUptime
        print("FYI 842-item fixture: open \((opened - start) * 1000) ms, swipe and inspect \((scrolled - opened) * 1000) ms")
    }

    func testFYIBodyDoubleTapSelectsWord() {
        assertFYINativeSelection("FYI word selected") { _, point in point.doubleTap() }
    }

    func testFYIBodyTripleTapKeepsTheListOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list"]
        app.launch()
        defer { app.terminate() }
        openFYIListIfNeeded(app)

        let body = fyiGardenBody(in: app)
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertTrue(app.buttons["fyi-sort"].exists)
        XCTAssertFalse(app.buttons["request-heading"].exists)
    }

    func testFYIBodyLongPressShowsCopy() {
        assertFYINativeSelection("FYI long press Copy", copy: true) { _, point in
            point.press(forDuration: 1)
        }
    }

    private func assertFYINativeSelection(_ captureName: String, copy: Bool = false,
                                          gesture: (XCUIElement, XCUICoordinate) -> Void) {
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-fyi-list"]
        app.launch()
        defer { app.terminate() }
        openFYIListIfNeeded(app)

        let body = fyiGardenBody(in: app)
        guard body.waitForExistence(timeout: 5) else {
            XCTFail("The garden FYI body is missing.")
            return
        }
        gesture(body, body.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4)))
        let copyAction = app.menuItems["Copy"]
        XCTAssertTrue(copyAction.waitForExistence(timeout: 5), app.debugDescription)
        capture(captureName, app)
        if copy, copyAction.exists { copyAction.tap() }
        XCTAssertTrue(app.buttons["fyi-sort"].exists)
        XCTAssertFalse(app.buttons["request-heading"].exists)
    }

    private func fyiGardenBody(in app: XCUIApplication) -> XCUIElement {
        app.collectionViews["fyi-list"].textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@", "The community garden reopened")).firstMatch
    }

    private func openFYIListIfNeeded(_ app: XCUIApplication) {
        let sort = app.buttons["fyi-sort"]
        if sort.exists { return }
        let digest = app.descendants(matching: .any)["inbox-fyi"].firstMatch
        if digest.waitForExistence(timeout: 5) {
            digest.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        }
        XCTAssertTrue(sort.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testSuccessMessageKindAppearsInInboxAndDetail() {
        for (motionLabel, motionArgument) in [
            ("off", "--harklight-test-reduce-motion-off"),
            ("on", "--harklight-test-reduce-motion-on")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                                  "--harklight-message-kind-acceptance", motionArgument]
            app.launch()
            XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)

            enterSearch("Release package", in: app)
            let row = app.descendants(matching: .any)["sample-message-kind-success"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(row.label.contains("FYI"), row.label)
            XCTAssertTrue(row.label.contains("Success"), row.label)
            capture("Success kind inbox · Reduce Motion \(motionLabel)", app)

            row.tap()
            XCTAssertTrue(app.buttons["request-heading"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.descendants(matching: .any)["message-type-fyi"].exists,
                          app.debugDescription)
            XCTAssertTrue(app.descendants(matching: .any)["message-kind-success"].exists,
                          app.debugDescription)
            XCTAssertTrue(app.buttons["request-seen-action"].exists,
                          "The typed FYI message keeps the existing Seen action available.")
            XCTAssertFalse(app.descendants(matching: .any)["request-seen-form-label"].exists,
                           "Revision 7 draws no FYI label above the Seen button.")
            capture("Success kind detail · Reduce Motion \(motionLabel)", app)

            showList(app)
            enterSearch("A note for the studio journal", in: app)
            let requestRow = app.descendants(matching: .any)["sample-note-0"]
            XCTAssertTrue(requestRow.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(requestRow.label.contains("Request"), requestRow.label)
            XCTAssertTrue(requestRow.label.contains("Blocker"), requestRow.label)
            requestRow.tap()
            XCTAssertTrue(app.descendants(matching: .any)["message-type-request"].waitForExistence(timeout: 5),
                          app.debugDescription)
            XCTAssertTrue(app.descendants(matching: .any)["message-kind-blocker"].exists,
                          app.debugDescription)
            XCTAssertTrue(app.buttons["Reply"].exists,
                          "The existing Reply action remains available for a typed request.")

            showList(app)
            enterSearch("review moved to Thursday", in: app)
            let legacySeen = app.descendants(matching: .any)["sample-information-0"]
            XCTAssertTrue(legacySeen.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(legacySeen.label.contains("FYI"),
                           "The Seen descriptor does not create a stored type label.")
            legacySeen.tap()
            XCTAssertTrue(app.buttons["request-seen-action"].waitForExistence(timeout: 5),
                          app.debugDescription)
            XCTAssertFalse(app.descendants(matching: .any)["message-type-fyi"].exists,
                           "An untyped legacy Seen message remains untyped.")
            XCTAssertTrue(app.buttons["request-seen-action"].exists,
                          "The original Seen button remains available.")
            app.terminate()
        }
    }

    func testMessageDetailDetectedURLAndSystemActionsInLightMode() {
        exerciseMessageDetectors(style: "Light")
    }

    func testMessageDetailDetectorsInDarkMode() {
        exerciseMessageDetectors(style: "Dark")
    }

    func testMessageDetailCopiesSelectedWord() {
        exerciseMessageCopy(selectWholeMessage: false)
    }

    func testMessageDetailCopiesWholeBody() {
        exerciseMessageCopy(selectWholeMessage: true)
    }

    private func exerciseMessageCopy(selectWholeMessage: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-data-detector-acceptance"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Detector acceptance", in: app)
        let row = app.descendants(matching: .any)["sample-data-detector-acceptance"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.staticTexts["Detector acceptance"].tap()
        let body = app.textViews["request-message-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        let baseline = selectWholeMessage ? "whole-message-baseline" : "selected-word-baseline"
        UIPasteboard.general.string = baseline
        XCTAssertEqual(UIPasteboard.general.string, baseline)
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.025)).press(forDuration: 1)
        if selectWholeMessage {
            let selectAll = app.menuItems["Select All"]
            for _ in 0..<3 where !selectAll.exists {
                let next = app.buttons["Next Page"]
                guard next.exists else { break }
                next.tap()
            }
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
            selectAll.tap()
        }
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.tap()

        // Paste is a user action inside the source app, so iOS pasteboard
        // privacy does not require the background UI runner to read app data.
        app.buttons["Chat"].tap()
        let composer = app.textViews["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        composer.tap()
        composer.press(forDuration: 1)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        let expected = selectWholeMessage ? detectorVisibleBody : "Select"
        let pasted = expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: composer)
        wait(for: [pasted], timeout: 5)
        XCTAssertEqual(composer.value as? String, expected)
        capture(selectWholeMessage ? "whole-message-copied-and-pasted" : "selected-word-copied-and-pasted", app)
        // Keep this a local unsent draft; never activate Send.
    }

    private var detectorVisibleBody: String {
        "Select this sentence to verify that copying remains available.\nhttps://example.invalid/detector-acceptance\n+1 (415) 555-0136\n1 Infinite Loop, Cupertino, CA 95014\nNovember 4, 2027 at 2:00 PM."
    }

    private func exerciseMessageDetectors(style: String) {
        let originalAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = originalAppearance }
        XCUIDevice.shared.appearance = style == "Dark" ? .dark : .light
        XCTAssertEqual(XCUIDevice.shared.appearance, style == "Dark" ? .dark : .light)
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-data-detector-acceptance", "--harklight-ui-diagnostics"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Detector acceptance", in: app)
        let row = app.descendants(matching: .any)["sample-data-detector-acceptance"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.staticTexts["Detector acceptance"].tap()
        let body = app.textViews["request-message-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5), app.debugDescription)
        // Copy preserves the visible Markdown-rendered paragraphs, whose spacing is
        // supplied by paragraph style rather than extra newline characters.
        let expected = detectorVisibleBody
        XCTAssertEqual(body.value as? String, expected)
        capture("message-detectors-\(style)", app)

        let url = app.links.matching(NSPredicate(format: "label CONTAINS %@",
            "example.invalid/detector-acceptance")).firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 5), app.debugDescription)
        url.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10))
        app.activate()

        // Open the stock menus without placing a call, opening Maps, or saving
        // an event. Each must offer the platform action for the detected value
        // (data detectors work item: a date offers the system calendar actions).
        for (value, actionPattern) in [
            ("November 4", "(Create Event|Add to Calendar|Show in Calendar|Open in Calendar).*"),
            ("415", "Call.*"),
            ("Infinite Loop", ".*(Maps|Directions).*")
        ] {
            let link = app.links.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
            // Returning from Safari or Home, the app may still be activating; a
            // long press then is lost and no preview appears.
            let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"),
                                                     object: link)
            XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 5), .completed, app.debugDescription)
            // Match only actionable system controls. The sender label contains
            // "Calendar", so a broad descendant-label match would prove nothing.
            let predicate = NSPredicate(format: "label MATCHES[c] %@", actionPattern)
            let menuAction = app.menuItems.matching(predicate).firstMatch
            let buttonAction = app.buttons.matching(predicate).firstMatch
            func actionOffered() -> Bool {
                let shown = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in menuAction.exists || buttonAction.exists }, object: nil)
                return XCTWaiter().wait(for: [shown], timeout: 10) == .completed
            }
            link.press(forDuration: 1)
            var offered = actionOffered()
            if !offered {
                // A press lost to an activation transition shows nothing at all;
                // press once more. The action must still be offered.
                link.press(forDuration: 1)
                offered = actionOffered()
            }
            XCTAssertTrue(offered, app.debugDescription)
            capture("message-detector-\(value)-\(style)", app)
            // A tap outside a tall detector preview can hit its map instead
            // of dismissing it. Leaving the app closes the system preview
            // without invoking an action; return to the same message next.
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(body.waitForExistence(timeout: 5), app.debugDescription)
        }
        app.terminate()
    }

    func testOrdinaryInboxHasNoExampleMessagesOrAddControl() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["request-row-review-01"].waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["sample-approval-0"].exists)
        app.buttons["inbox-settings"].tap()
        XCTAssertFalse(app.buttons["Add example messages"].exists)
        XCTAssertFalse(app.staticTexts["Local examples"].exists)
    }

    func testOrdinaryInboxKeepsRequestsAlongsideTestFixtures() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture"]
        app.launch()
        let realRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'request-row-'"))
        XCTAssertTrue(realRows.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let original = app.descendants(matching: .any)["request-row-review-01"]
        XCTAssertTrue(original.waitForExistence(timeout: 5), app.debugDescription)
        let originalID = original.identifier
        capture("ordinary-inbox-before-examples", app)
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
        let listVisibleAlongsideDetail = app.searchFields.firstMatch.isHittable
        let detail = app.scrollViews["message-card-scroll"]
        finish.tap()
        if listVisibleAlongsideDetail {
            XCTAssertTrue(detail.waitForExistence(timeout: 5),
                          "Submitting in two-pane presentation keeps the detail visible.")
        } else {
            XCTAssertTrue(detail.waitForNonExistence(timeout: 5),
                          "Submitting returns the single-pane detail to the list before confirmation.")
            XCTAssertTrue(inboxTab.isSelected, app.debugDescription)
        }
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
        XCTAssertTrue(original.label.contains("Waiting for a reply"),
                      "The submitted answer shows it is still sending until its outcome is confirmed. Row label: \(original.label)")
        capture("choice-response-in-replied", app)
        // The removed Settings action used to add examples only after the ordinary
        // request flow. Reopen the persisted fixture with test-only examples now.
        app.terminate()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(workspaceTab("Inbox", in: app).waitForExistence(timeout: 10),
                      app.debugDescription)
        let row = app.descendants(matching: .any)["sample-approval-0"]
        // Test fixtures remain in Inbox, so leave the submitted request's Replied tab first.
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
        XCTAssertTrue(original.label.contains("Waiting for a reply"),
                      "The submitted ordinary answer is still sending after relaunch and local example actions. Row label: \(original.label)")
        original.tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5))
        // The persisted submission still shows its send state in place: the
        // check spins and the answers step back, with no Pending card.
        let sending = app.buttons["request-finish"]
        XCTAssertTrue(sending.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(sending.label, "Sending",
                       "The persisted ordinary submission keeps sending after local example actions.")
        XCTAssertFalse(app.descendants(matching: .any)["request-pending-answer-status"].exists)
        // The sent choice carries the sending spinner, so its label ends with the choice.
        for answer in ["Cover A", "Cover B", "Send a note"] {
            let button = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", answer)).firstMatch
            guard button.exists else { continue }
            XCTAssertFalse(button.isEnabled,
                           "While sending, the answers step back.")
        }
        capture("ordinary-request-after-example", app)
    }

    func testSubmittedRequestHistoryRemainsWhileLocalExamplesAreUsed() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
        app.launch()

        let original = app.descendants(matching: .any)["request-row-review-01"]
        XCTAssertTrue(original.waitForExistence(timeout: 10), app.debugDescription)
        original.tap()
        let choice = app.buttons["Cover A"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        XCTAssertTrue(choice.isSelected)
        let finish = app.buttons["request-finish"]
        XCTAssertTrue(finish.isEnabled, app.debugDescription)
        finish.tap()

        showList(app)
        selectMessageTab("Replied", in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 5),
                      "The submitted ordinary request appears in Replied.")
        XCTAssertTrue(original.label.contains("Waiting for a reply"),
                      "Its answer shows it is still sending until an outcome arrives. Row label: \(original.label)")

        selectMessageTab("Inbox", in: app)
        enterSearch("Archive", in: app)
        let example = app.descendants(matching: .any)["sample-approval-0"]
        XCTAssertTrue(example.waitForExistence(timeout: 5), app.debugDescription)
        example.tap()
        let keep = app.buttons.containing(.staticText, identifier: "Keep here").firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), app.debugDescription)
        keep.tap()
        app.descendants(matching: .any)["sample-finish"].tap()
        XCTAssertTrue(app.staticTexts["Answered locally · nothing sent"].waitForExistence(timeout: 5),
                      app.debugDescription)

        showList(app)
        clearSearch(in: app)
        selectMessageTab("Replied", in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 5),
                      "Using a local example does not remove the ordinary answer history.")
        original.tap()
        XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5),
                      app.debugDescription)
        // The sent choice carries the sending spinner, so its label ends with the choice.
        let submitted = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Cover A")).firstMatch
        XCTAssertTrue(submitted.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(submitted.isSelected,
                      "The submitted ordinary answer remains visible after the local example.")
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
        let listVisibleAlongsideDetail = app.searchFields.firstMatch.isHittable
        let detail = app.scrollViews["message-card-scroll"]
        submit.tap()
        if listVisibleAlongsideDetail {
            XCTAssertTrue(detail.waitForExistence(timeout: 5),
                          "Submitting No comment in two-pane presentation keeps the detail visible.")
        } else {
            XCTAssertTrue(detail.waitForNonExistence(timeout: 5),
                          "Submitting No comment returns a single-pane detail to the list immediately.")
        }
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
        let field = workspaceSearchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      app.debugDescription, file: file, line: line)
    }

    private func showList(_ app: XCUIApplication) {
        let card = app.scrollViews["message-card-scroll"]
        guard card.exists else { return }
        let back = workspaceBackButton(in: app)
        if back.exists && back.isHittable {
            back.tap()
        } else {
            let sidebar = app.buttons["Show Sidebar"]
            if sidebar.exists && sidebar.isHittable { sidebar.tap() }
        }
        // Back returns to the list; search is a separate tab now.
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5),
                      app.debugDescription)
    }

    private func enterSearch(_ query: String, in app: XCUIApplication) {
        let field = workspaceSearchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        let clearText = field.buttons["Clear text"]
        if clearText.exists && clearText.isHittable { clearText.tap() }
        field.tap()
        field.typeText(query + "\n")
    }

    private func clearSearch(in app: XCUIApplication) {
        let clearText = workspaceSearchField(in: app).buttons["Clear text"]
        if clearText.exists && clearText.isHittable { clearText.tap() }
        // Search is its own tab; leaving it returns to the list it searched.
        leaveWorkspaceSearch(in: app)
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
        let messageCardScroll = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(messageCardScroll.exists, app.debugDescription)
        messageCardScroll.swipeUp()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Scrolling to No comment keeps the Reply keyboard open.")
        XCTAssertTrue(noComment.isHittable,
                      "No comment remains reachable after scrolling its message card.")
        capture("reply-only-no-comment-available", app)

        noComment.tap()
        XCTAssertTrue(noComment.isSelected, "No comment is selected as an answer.")
        XCTAssertEqual(noComment.value as? String, "Selected")
        XCTAssertFalse(app.descendants(matching: .any)["request-local-no-comment-status"].exists,
                       "Selecting No comment does not submit it.")
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
        let replySummary = app.buttons["request-compatibility-reply-reply"]
        XCTAssertTrue(replySummary.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(replySummary.label.contains("Draft stays saved."),
                      "The same unsent Reply draft remains saved after reopening the detail.")
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

    func testRecoveryWarningStaysAvailableWithoutCoveringToolbarActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-attention-fixture", "--harklight-samples",
                               "--harklight-test-recovery-status"]
        app.launch()
        let inbox = workspaceTab("Inbox", in: app)
        let replied = workspaceTab("Replied", in: app)
        let settings = app.buttons["inbox-settings"].firstMatch
        let message = app.staticTexts.containing(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                        "inbox-warning-message", "Could not verify notification")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["inbox-warning-button"].exists)
        XCTAssertTrue(inbox.isSelected)
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        selectMessageTab("Replied", in: app)
        XCTAssertTrue(replied.isSelected)
        selectMessageTab("Inbox", in: app)
        XCTAssertTrue(inbox.isSelected)
        XCTAssertTrue(message.isHittable)
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
        XCTAssertTrue(noComment.isHittable, app.debugDescription)
        XCTAssertTrue(noComment.isEnabled,
                      "An explicit No comment failure must leave the same choice available for retry.")
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
        let listVisibleAlongsideDetail = app.searchFields.firstMatch.isHittable
        let detail = app.scrollViews["message-card-scroll"]
        bodySeen.tap()
        if listVisibleAlongsideDetail {
            XCTAssertTrue(detail.waitForExistence(timeout: 5),
                          "When the list and detail are both visible, confirmed Seen keeps the detail selected.")
            XCTAssertTrue(app.descendants(matching: .any)["request-seen-confirmation"]
                .waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.buttons["request-seen-action"].exists)
            XCTAssertFalse(app.buttons["request-finish-seen"].isEnabled,
                           "The confirmed toolbar Seen action stays visible but unavailable.")
        } else {
            XCTAssertTrue(detail.waitForNonExistence(timeout: 5),
                          "In a single-pane presentation, confirmed Seen returns to the list.")
        }
        capture("seen-response-after-confirmation", app)

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

    func testReplyChoiceKeepsDraftAcrossChatNavigationAndSend() {
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
        let editor = app.textViews.matching(identifier: "request-input-answer-response").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        let editorCard = app.descendants(matching: .any)["request-input-answer-response-card"].firstMatch
        XCTAssertTrue(editorCard.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThanOrEqual(editor.frame.minX, editorCard.frame.minX)
        XCTAssertGreaterThanOrEqual(editor.frame.minY, editorCard.frame.minY)
        XCTAssertLessThanOrEqual(editor.frame.maxX, editorCard.frame.maxX)
        XCTAssertLessThanOrEqual(editor.frame.maxY, editorCard.frame.maxY,
                                 "The reply field is inside its selected choice border.")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Selecting Reply focuses its editor.")
        capture("reply-editor-inline", app)
        capture("reply-choice-note-empty", app)
        editor.typeText("Keep the smaller first step.")
        capture("reply-choice-note-typed", app)
        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.exists,
                      "Replying does not remove Chat from the message screen.")
        capture("reply-draft-before-chat-navigation", app)

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
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(editor.value as? String, "Keep the smaller first step.")
        let reopenedEditorCard = app.descendants(matching: .any)[
            "request-input-answer-response-card"].firstMatch
        XCTAssertTrue(reopenedEditorCard.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThanOrEqual(editor.frame.minX, reopenedEditorCard.frame.minX)
        XCTAssertGreaterThanOrEqual(editor.frame.minY, reopenedEditorCard.frame.minY)
        XCTAssertLessThanOrEqual(editor.frame.maxX, reopenedEditorCard.frame.maxX)
        XCTAssertLessThanOrEqual(editor.frame.maxY, reopenedEditorCard.frame.maxY,
                                 "Returning to the request keeps the reply field in its selected choice.")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "The inline reply field can be focused again after navigation.")
        XCTAssertGreaterThan(editor.frame.height, 0)
        capture("reply-editor-reopened", app)
        let card = app.scrollViews["message-card-scroll"]
        card.swipeDown()
        XCTAssertFalse(keyboard.waitForExistence(timeout: 1.5),
                       "A downward swipe on the message content dismisses the reply keyboard.")
        XCTAssertTrue(editor.exists, "Interactive dismissal keeps the reply editor open.")
        XCTAssertEqual(editor.value as? String, "Keep the smaller first step.",
                       "Interactive dismissal preserves the unsent reply draft.")
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(chat.isHittable, "Chat is reachable after dismissing the keyboard.")
        chat.tap()
        let chatComposer = app.textViews["sample-chat-composer"]
        XCTAssertTrue(chatComposer.waitForExistence(timeout: 5), app.debugDescription)
        capture("reply-draft-chat-open", app)
        dismissReplyChatPresentation(app, chatComposer)
        XCTAssertTrue(chatComposer.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(editor.value as? String, "Keep the smaller first step.",
                       "Opening and dismissing Chat preserves the unsent reply draft.")
        capture("reply-draft-after-chat-dismissal", app)
        editor.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5),
                      "The reply editor can be focused again after interactive dismissal.")
        app.descendants(matching: .any)["sample-finish"].tap()
        card.swipeDown()
        XCTAssertFalse(keyboard.waitForExistence(timeout: 1.5),
                       "Dismiss the reply keyboard before using the stock Chat control.")
        XCTAssertTrue(chat.isHittable,
                      "Chat remains available after the reply is accepted and the keyboard is dismissed.")
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

    func testInlineReplyEditorKeepsLongDraftInsideSelectedChoice() {
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
        let editor = app.textViews["request-input-answer-response"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let editorCard = app.descendants(matching: .any)["request-input-answer-response-card"].firstMatch
        XCTAssertTrue(editorCard.waitForExistence(timeout: 5), app.debugDescription)

        let longDraft = (1...48).map { "Reply line \($0) keeps growing across the field." }
            .joined(separator: " ")
        editor.typeText(longDraft)
        capture("reply-editor-inline-long-draft", app)

        let retainedText = editor.value as? String ?? ""
        XCTAssertTrue(retainedText.contains("Reply line 48"),
                      "The full reply remains available in the inline field.")
        XCTAssertGreaterThanOrEqual(editor.frame.minX, editorCard.frame.minX)
        XCTAssertGreaterThanOrEqual(editor.frame.minY, editorCard.frame.minY)
        XCTAssertLessThanOrEqual(editor.frame.maxX, editorCard.frame.maxX)
        XCTAssertLessThanOrEqual(editor.frame.maxY, editorCard.frame.maxY,
                                 "The expanded reply field stays inside its selected choice.")
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
            case "instructions": "Prepare the studio display"
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
                selectMessageTab("Inbox", in: app)
                XCTAssertTrue(inboxTab.isSelected)
                selectMessageTab("Replied", in: app)
                XCTAssertTrue(repliedTab.isSelected,
                              "The unsent reply is checked in the Replied tab.")
                enterSearch(query, in: app)
                XCTAssertFalse(row.waitForExistence(timeout: 1),
                               "A prefilled but unsent reply stays in Inbox.")
                clearSearch(in: app)
                selectMessageTab("Inbox", in: app)
                XCTAssertTrue(inboxTab.isSelected)
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
                let answer = app.textViews["request-input-answer-response"]
                XCTAssertTrue(answer.waitForExistence(timeout: 5))
                answer.tap()
                answer.typeText("Leave room for a quiet corner.")
                capture("component-own-answer-editing", app)
                app.descendants(matching: .any)["sample-finish"].tap()
                capture("component-own-answer-submitted", app)
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
        let composer = app.textViews["sample-chat-composer"]
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

    private func dismissReplyChatPresentation(_ app: XCUIApplication, _ composer: XCUIElement) {
        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        // Chat presents a native sheet on compact layouts. Anchor the dismissal
        // gesture to its history instead of tapping an outside area that may
        // not exist at small window sizes.
        let start = history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        let end = history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5), app.debugDescription)
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
        let composer = app.textViews["sample-chat-composer"]
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
            enterSearch("Archive the old studio sketches", in: app)
            XCTAssertTrue(app.descendants(matching: .any)["sample-approval-0"].waitForExistence(timeout: 5))
            capture("corrected-duo-" + name + "-list", app)
            app.descendants(matching: .any)["sample-approval-0"].tap()
            XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5))
            capture("corrected-duo-" + name + "-card", app)
            app.buttons["Chat"].tap()
            let composer = app.textViews["sample-chat-composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap(); composer.typeText("Local orientation " + name)
            let send = app.buttons["Send locally"]
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

    func testPreviewPageCapturesInboxAndDetail() {
        let orientations: [(String, Bool)] = [
            ("portrait", false),
            ("landscape", true),
        ]
        defer { XCUIDevice.shared.orientation = .portrait }

        for (name, expectsLandscape) in orientations {
            XCUIDevice.shared.orientation = .portrait
            let app = XCUIApplication()
            app.launchArguments = ["--reset-attention-fixture", "--harklight-samples"]
            app.launch()
            XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
            enterSearch("Archive", in: app)
            let row = app.descendants(matching: .any)["sample-approval-2"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)

            if expectsLandscape {
                XCUIDevice.shared.orientation = .landscapeLeft
                let wideFrame = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in app.frame.width > app.frame.height },
                    object: app
                )
                XCTAssertEqual(XCTWaiter().wait(for: [wideFrame], timeout: 5),
                               .completed, app.debugDescription)
            }
            XCTAssertEqual(app.frame.width > app.frame.height, expectsLandscape, app.debugDescription)
            capture("preview-\(name)-inbox", app)
            row.tap()
            XCTAssertTrue(app.scrollViews["message-card-scroll"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(app.frame.width > app.frame.height, expectsLandscape, app.debugDescription)
            capture("preview-\(name)-detail", app)
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

    func testAdaptiveChatRemainsUsableInPortraitAndLandscape() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--attention-fixture", "--harklight-samples"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Thursday", in: app)
        app.descendants(matching: .any)["sample-information-2"].tap()
        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(chat.frame.midY, screen.midY,
                             "Chat is an action in the message screen's bottom toolbar.")
        XCTAssertGreaterThan(chat.frame.midX, screen.midX,
                             "Chat is trailing in the bottom toolbar.")
        XCTAssertTrue(chat.isHittable, app.debugDescription)
        chat.tap()
        XCTAssertTrue(app.textViews["sample-chat-composer"].waitForExistence(timeout: 5))
        capture("adaptive-portrait-chat", app)
        let composer = app.textViews["sample-chat-composer"]
        composer.tap(); composer.typeText("Local keyboard check")
        XCTAssertTrue(app.buttons["Send locally"].isHittable, "Keyboard must leave the send control usable")
        capture("adaptive-portrait-keyboard", app)
        app.buttons["Send locally"].tap()
        XCTAssertTrue(app.staticTexts["Local keyboard check"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        app.activate()
        let composers = app.textViews.matching(identifier: "sample-chat-composer")
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
