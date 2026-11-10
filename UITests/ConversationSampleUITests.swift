import XCTest
import UIKit

@MainActor
final class ConversationSampleUITests: XCTestCase {
    func testPriorityRowsAndNewMessageAreaRenderIn250PointListColumn() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let states: [(name: String, rowIdentifier: String, selectedMessageID: String?,
                      selectedTitle: String?, comparisonIdentifier: String?, fullWidth: Bool)] = [
            ("selectedPlainAndUnselectedComparison", "request-row-sample-approval-0",
             "sample-approval-0", "Archive the old studio sketches?",
             "request-row-sample-textChoice-0", false),
            ("selectedHigh", "request-row-sample-approval-0", "sample-approval-0",
             "Archive the old studio sketches?", nil, false),
            ("fullWidthHigh", "request-row-sample-approval-0", nil, nil, nil, true),
            ("acceptedNewMessage", "new-message-area-request-row-sample-information-0",
             nil, nil, nil, false),
            ("replyItem", "reply-item-request-row-sample-information-0",
             nil, nil, nil, false),
            ("replyItemFullWidth", "reply-item-request-row-sample-information-0",
             nil, nil, nil, true),
        ]

        for appearance in ["light", "dark"] {
            for state in states {
                let app = XCUIApplication()
                app.launchArguments = [
                    "--harklight-test-inbox-list-column",
                    "--harklight-test-inbox-list-\(appearance)",
                    "--harklight-test-inbox-list-state=\(state.name)"
                ]
                if state.name == "replyItem" || state.name == "replyItemFullWidth" {
                    app.launchArguments.append("--harklight-test-reply-item-area")
                }
                app.launch()

                let appWindow = app.windows.firstMatch
                XCTAssertTrue(appWindow.waitForExistence(timeout: 10), app.debugDescription)
                XCTAssertGreaterThan(appWindow.frame.width, 500,
                                     "Only the NavigationSplitView sidebar may be constrained to 250 points.\n\(app.debugDescription)")

                let columnWidth = app.descendants(matching: .any)["priority-capture-list-column-width"]
                XCTAssertTrue(columnWidth.waitForExistence(timeout: 10), app.debugDescription)

                let list = app.collectionViews.firstMatch
                XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
                let expectedColumnWidth = state.fullWidth ? Int(list.frame.width.rounded()) : 250
                XCTAssertEqual(columnWidth.value as? String, String(expectedColumnWidth),
                               "The host's measured List width must match the requested state.\n\(app.debugDescription)")
                XCTAssertEqual(list.frame.width, CGFloat(expectedColumnWidth), accuracy: 5,
                               "The List itself must match its measured width.\n\(app.debugDescription)")
                if state.fullWidth {
                    XCTAssertGreaterThanOrEqual(list.frame.width, 500,
                                                "The full-width comparison must use the app window, not a narrow list column.\n\(app.debugDescription)")
                } else {
                    XCTAssertEqual(list.frame.width, 250, accuracy: 5,
                                   "The selected-row target is a 250-point list column.\n\(app.debugDescription)")
                }

                let row = app.descendants(matching: .any)[state.rowIdentifier]
                XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertTrue(row.isHittable,
                              "The capture target must be visible before it is inspected.\n\(app.debugDescription)")
                XCTAssertEqual(row.frame.width, CGFloat(expectedColumnWidth), accuracy: 5)
                XCTAssertGreaterThanOrEqual(row.frame.minY, list.frame.minY - 1)
                XCTAssertLessThanOrEqual(row.frame.maxY, list.frame.maxY + 1)
                let captureSelection = app.descendants(matching: .any)["priority-capture-selection"]
                XCTAssertTrue(captureSelection.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertEqual(captureSelection.value as? String, "none",
                               "The test host must begin with no preselected row.\n\(app.debugDescription)")
                if let selectedMessageID = state.selectedMessageID,
                   let selectedTitle = state.selectedTitle {
                    row.tap()
                    let selected = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@", selectedMessageID),
                        object: captureSelection)
                    XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                                   "A real row press must update the List selection.\n\(app.debugDescription)")
                    XCTAssertTrue(row.isSelected,
                                  "The pressed product row must expose the native selected state.\n\(app.debugDescription)")
                    let detailHeading = app.buttons["request-heading"]
                    XCTAssertTrue(detailHeading.waitForExistence(timeout: 5), app.debugDescription)
                    XCTAssertTrue(detailHeading.isHittable, app.debugDescription)
                    XCTAssertTrue(detailHeading.label.contains(selectedTitle),
                                  "The detail must show the same selected request.\n\(app.debugDescription)")
                }
                if state.fullWidth {
                    XCTAssertTrue(row.isEnabled,
                                  "The full-width comparison must keep production NavigationLinks active.\n\(app.debugDescription)")
                }

                if state.name == "selectedPlainAndUnselectedComparison" {
                    guard let comparisonIdentifier = state.comparisonIdentifier else {
                        XCTFail("The selected Plain comparison needs an unselected request row.")
                        return
                    }
                    let comparison = app.descendants(matching: .any)[comparisonIdentifier]
                    XCTAssertTrue(comparison.waitForExistence(timeout: 5), app.debugDescription)
                    XCTAssertTrue(comparison.isHittable, comparison.debugDescription)
                    XCTAssertFalse(comparison.isSelected,
                                   "The comparison row must remain unselected.\n\(comparison.debugDescription)")
                    XCTAssertTrue(comparison.label.contains("Which approach for the studio?"),
                                  comparison.debugDescription)
                }
                if state.name == "selectedHigh" || state.name == "fullWidthHigh" {
                    let marker = app.descendants(matching: .any)["inbox-priority-high"]
                    let duePhrase = app.descendants(matching: .any)["inbox-due-phrase"]
                    XCTAssertTrue(marker.waitForExistence(timeout: 5), app.debugDescription)
                    XCTAssertEqual(marker.label, "High priority", marker.debugDescription)
                    XCTAssertTrue(duePhrase.waitForExistence(timeout: 5), app.debugDescription)
                    XCTAssertEqual(duePhrase.label, "Due tomorrow at 9:00 AM", duePhrase.debugDescription)
                }
                if state.name == "acceptedNewMessage" {
                    let header = app.descendants(matching: .any)["new-message-area-header"]
                    XCTAssertTrue(header.waitForExistence(timeout: 5), app.debugDescription)
                    XCTAssertTrue(header.isHittable, app.debugDescription)
                }
                if state.name == "replyItem" || state.name == "replyItemFullWidth" {
                    let unseenCount = app.descendants(matching: .any)["reply-item-unseen-count"]
                    XCTAssertTrue(unseenCount.waitForExistence(timeout: 5), app.debugDescription)
                    XCTAssertTrue(unseenCount.label.contains("2 new"), unseenCount.debugDescription)
                    let badge = app.descendants(matching: .any)["reply-item-priority-now"]
                    XCTAssertTrue(badge.waitForExistence(timeout: 5), app.debugDescription)
                    let normalReply = app.descendants(matching: .any)[
                        "normal-reply-item-sample-information-0"
                    ]
                    XCTAssertTrue(normalReply.waitForExistence(timeout: 5), app.debugDescription)
                    let normalPriority = app.descendants(matching: .any)[
                        "normal-reply-item-priority-now"
                    ]
                    XCTAssertTrue(normalPriority.waitForExistence(timeout: 5), app.debugDescription)
                    let acceptedMessage = app.descendants(matching: .any)["new-message-area-request-row-sample-information-0"]
                    XCTAssertTrue(acceptedMessage.waitForExistence(timeout: 5), app.debugDescription)
                    XCTAssertLessThan(row.frame.minY, acceptedMessage.frame.minY,
                                      "The newer reply item must sort above the older accepted message.\n\(app.debugDescription)")
                }

                captureInboxColumnState("inbox-250-\(appearance)-\(state.name)", app)
                app.terminate()
            }
        }
    }

    func testFloatingSearchKeepsNormalReplyTextVisibleAtLargeContentSizes() {
        XCUIDevice.shared.orientation = .landscapeLeft

        for contentSize in [
            UIContentSizeCategory.large,
            UIContentSizeCategory.extraExtraLarge,
            UIContentSizeCategory.extraExtraExtraLarge
        ] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-UIPreferredContentSizeCategoryName", contentSize.rawValue,
                "--harklight-test-inbox-list-column",
                "--harklight-test-inbox-list-light",
                "--harklight-test-inbox-list-state=markdown",
                "--harklight-markdown-acceptance",
                "--harklight-test-markdown-reply-item"
            ]
            app.launch()

            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)

            let normalReplyRow = app.descendants(matching: .any)[
                "normal-reply-item-sample-markdown-acceptance"
            ]
            XCTAssertTrue(normalReplyRow.waitForExistence(timeout: 5), app.debugDescription)
            let replyText = normalReplyRow.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Open reply guide")
            ).firstMatch
            XCTAssertTrue(replyText.waitForExistence(timeout: 5), app.debugDescription)

            let searchField = app.searchFields.firstMatch
            XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(searchField.isHittable, searchField.debugDescription)
            for _ in 0..<8 where replyText.frame.maxY > searchField.frame.minY {
                list.swipeUp()
            }
            XCTAssertTrue(normalReplyRow.isHittable, normalReplyRow.debugDescription)
            XCTAssertTrue(replyText.isHittable, replyText.debugDescription)
            XCTAssertLessThanOrEqual(
                replyText.frame.maxY,
                searchField.frame.minY,
                "The floating Search field must not cover the normal reply text.\n\(app.debugDescription)"
            )

            searchField.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            searchField.typeText("Markdown\n")
            XCTAssertTrue(normalReplyRow.waitForExistence(timeout: 5),
                          "Searching still finds the visible reply.\n\(app.debugDescription)")
            app.terminate()
        }
    }

    func testMarkdownRendersInNewNormalDetailAndConversationWithoutChangingRowTaps() {
        XCUIDevice.shared.orientation = .landscapeLeft

        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "--harklight-test-inbox-list-column",
                "--harklight-test-inbox-list-\(appearance)",
                "--harklight-test-inbox-list-state=markdown",
                "--harklight-markdown-acceptance",
                "--harklight-test-markdown-reply-item"
            ]
            app.launch()

            let newRow = app.descendants(matching: .any)[
                "new-message-area-request-row-sample-markdown-acceptance"
            ]
            XCTAssertTrue(newRow.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(newRow.label.contains("A Markdown note"), newRow.debugDescription)
            XCTAssertFalse(newRow.label.contains("**"), newRow.debugDescription)
            let selection = app.descendants(matching: .any)["priority-capture-selection"]
            XCTAssertTrue(selection.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(selection.value as? String, "none", app.debugDescription)
            let firstSeenProbe = app.descendants(matching: .any)["markdown-row-first-seen"]
            XCTAssertTrue(firstSeenProbe.waitForExistence(timeout: 5), app.debugDescription)
            let firstSeenExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@ AND value != %@", "unseen", "missing"),
                object: firstSeenProbe)
            XCTAssertEqual(XCTWaiter.wait(for: [firstSeenExpectation], timeout: 5), .completed,
                           "The visible New row should retain its normal visibility-based Seen behavior.")
            let firstSeenBeforeLink = firstSeenProbe.value as? String
            let newReplyRow = app.descendants(matching: .any)[
                "reply-item-request-row-sample-markdown-acceptance"
            ]
            XCTAssertTrue(newReplyRow.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(newReplyRow.label.contains("reply guide"), newReplyRow.debugDescription)
            XCTAssertFalse(newReplyRow.label.contains("[reply guide]"), newReplyRow.debugDescription)
            let replyFirstSeenProbe = app.descendants(matching: .any)["markdown-reply-first-seen"]
            XCTAssertTrue(replyFirstSeenProbe.waitForExistence(timeout: 5), app.debugDescription)
            let replyFirstSeenExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@ AND value != %@", "unseen", "missing"),
                object: replyFirstSeenProbe)
            XCTAssertEqual(XCTWaiter.wait(for: [replyFirstSeenExpectation], timeout: 5), .completed,
                           "The visible New reply should retain its normal visibility-based Seen behavior.")
            let replyFirstSeenBeforeLink = replyFirstSeenProbe.value as? String
            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
            captureInboxColumnState("markdown-\(appearance)-new-row", app)
            captureInboxColumnState("markdown-\(appearance)-new-reply-row", app)

            let newGuide = app.links.matching(
                NSPredicate(format: "label CONTAINS %@", "Open guide")
            ).firstMatch
            XCTAssertTrue(newGuide.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(newGuide.isHittable, newGuide.debugDescription)
            newGuide.tap()
            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
            XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10), app.debugDescription)
            app.activate()
            XCTAssertEqual(selection.value as? String, "none",
                           "Opening a link in New must leave its row unselected.")
            XCTAssertEqual(firstSeenProbe.value as? String, firstSeenBeforeLink,
                           "Opening a link must not change the New row's Seen timestamp.")
            XCTAssertTrue(newRow.waitForExistence(timeout: 5),
                          "Opening a New-row link must not remove the item or mark it seen.\n\(app.debugDescription)")

            let newReplyGuide = newReplyRow.links.matching(
                NSPredicate(format: "label CONTAINS %@", "reply guide")
            ).firstMatch
            XCTAssertTrue(newReplyGuide.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(newReplyGuide.isHittable, newReplyGuide.debugDescription)
            newReplyGuide.tap()
            XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10), app.debugDescription)
            app.activate()
            XCTAssertEqual(selection.value as? String, "none",
                           "Opening a New reply link must leave its parent unselected.")
            XCTAssertEqual(replyFirstSeenProbe.value as? String, replyFirstSeenBeforeLink,
                           "Opening a New reply link must not change its Seen timestamp.")
            XCTAssertTrue(newReplyRow.exists,
                          "Opening a New reply link must not remove the item.\n\(app.debugDescription)")

            let normalReplyRow = app.descendants(matching: .any)[
                "normal-reply-item-sample-markdown-acceptance"
            ]
            for _ in 0..<8 where !normalReplyRow.isHittable { list.swipeUp() }
            XCTAssertTrue(normalReplyRow.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(normalReplyRow.isHittable,
                          "The reply must also retain its normal prioritized row.\n\(app.debugDescription)")
            XCTAssertTrue(normalReplyRow.label.contains("A Markdown note"), normalReplyRow.debugDescription)
            XCTAssertFalse(normalReplyRow.label.contains("**"), normalReplyRow.debugDescription)
            captureInboxColumnState("markdown-\(appearance)-normal-reply-row", app)

            let normalReplyGuide = normalReplyRow.links.matching(
                NSPredicate(format: "label CONTAINS %@", "reply guide")
            ).firstMatch
            XCTAssertTrue(normalReplyGuide.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(normalReplyGuide.isHittable, normalReplyGuide.debugDescription)
            let normalReplyFirstSeenBeforeLink = replyFirstSeenProbe.value as? String
            normalReplyGuide.tap()
            XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10), app.debugDescription)
            app.activate()
            XCTAssertEqual(selection.value as? String, "none",
                           "Opening a normal reply link must leave its parent unselected.")
            XCTAssertEqual(replyFirstSeenProbe.value as? String, normalReplyFirstSeenBeforeLink,
                           "Opening a normal reply link must not change its Seen timestamp.")
            XCTAssertTrue(normalReplyRow.exists,
                          "Opening a normal reply link must preserve the normal reply row.\n\(app.debugDescription)")

            let normalRow = app.descendants(matching: .any)["request-row-sample-markdown-acceptance"]
            for _ in 0..<8 where !normalRow.isHittable { list.swipeUp() }
            XCTAssertTrue(normalRow.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(normalRow.isHittable,
                          "The same request must remain in its normal prioritized position.\n\(app.debugDescription)")
            captureInboxColumnState("markdown-\(appearance)-normal-row", app)

            let normalGuide = normalRow.links.matching(
                NSPredicate(format: "label CONTAINS %@", "Open guide")
            ).firstMatch
            XCTAssertTrue(normalGuide.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(normalGuide.isHittable, normalGuide.debugDescription)
            normalGuide.tap()
            XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10), app.debugDescription)
            app.activate()
            XCTAssertEqual(selection.value as? String, "none",
                           "Opening a normal-row link must not select or mark the request seen.")
            XCTAssertTrue(normalRow.exists, app.debugDescription)

            for _ in 0..<8 where !newRow.isHittable { list.swipeDown() }
            XCTAssertTrue(newRow.isHittable, app.debugDescription)
            // Stay in the button's blank trailing area so this is a row tap,
            // not a tap on the embedded Markdown link.
            newRow.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.82)).tap()
            let selected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "sample-markdown-acceptance"),
                object: selection)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                           "A non-link tap in New keeps the existing request navigation.\n\(app.debugDescription)")
            let heading = app.buttons["request-heading"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(heading.label.contains("A Markdown note"), heading.debugDescription)
            XCTAssertFalse(heading.label.contains("**"), heading.debugDescription)
            let body = app.textViews["request-message-body"]
            XCTAssertTrue(body.waitForExistence(timeout: 5), app.debugDescription)
            let bodyText = body.value as? String ?? body.label
            XCTAssertTrue(bodyText.contains("First item"), bodyText)
            XCTAssertTrue(bodyText.contains("A quoted sentence"), bodyText)
            XCTAssertTrue(bodyText.contains("let answer = 42"), bodyText)
            XCTAssertFalse(bodyText.contains("**"), bodyText)
            XCTAssertFalse(bodyText.contains("```"), bodyText)
            let stake = app.staticTexts["request-stake"]
            XCTAssertTrue(stake.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(stake.label.contains("main risk"), stake.debugDescription)
            capture("markdown-\(appearance)-detail", app)

            app.buttons["Chat"].tap()
            let history = app.scrollViews["conversation-history-scroll"]
            XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
            let conversationText = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Could you explain")
            ).firstMatch
            XCTAssertTrue(conversationText.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(conversationText.label.contains("**"), conversationText.debugDescription)
            XCTAssertTrue(app.links.matching(
                NSPredicate(format: "label CONTAINS %@", "guide")
            ).firstMatch.exists, app.debugDescription)
            XCTAssertTrue(app.links.matching(
                NSPredicate(format: "label CONTAINS %@", "reply guide")
            ).firstMatch.exists, app.debugDescription)
            capture("markdown-\(appearance)-conversation", app)
            app.terminate()
        }
    }

    func testMarkdownUsesAccessibilityDynamicTypeInNewNormalAndDetail() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "--harklight-test-inbox-list-column",
            "--harklight-test-inbox-list-light",
            "--harklight-test-inbox-list-state=markdown",
            "--harklight-markdown-acceptance",
            "--harklight-test-markdown-reply-item",
            "-UIPreferredContentSizeCategoryName",
            UIContentSizeCategory.accessibilityLarge.rawValue
        ]
        app.launch()

        let newRow = app.descendants(matching: .any)[
            "new-message-area-request-row-sample-markdown-acceptance"
        ]
        XCTAssertTrue(newRow.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(newRow.label.contains("A Markdown note"), newRow.debugDescription)
        XCTAssertFalse(newRow.label.contains("**"), newRow.debugDescription)
        captureInboxColumnState("markdown-accessibility-new-row", app)

        let newReplyRow = app.descendants(matching: .any)[
            "reply-item-request-row-sample-markdown-acceptance"
        ]
        XCTAssertTrue(newReplyRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(newReplyRow.label.contains("reply guide"), newReplyRow.debugDescription)
        captureInboxColumnState("markdown-accessibility-new-reply-row", app)

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        let normalReplyRow = app.descendants(matching: .any)[
            "normal-reply-item-sample-markdown-acceptance"
        ]
        for _ in 0..<8 where !normalReplyRow.isHittable { list.swipeUp() }
        XCTAssertTrue(normalReplyRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(normalReplyRow.isHittable, normalReplyRow.debugDescription)
        captureInboxColumnState("markdown-accessibility-normal-reply-row", app)

        let normalRow = app.descendants(matching: .any)["request-row-sample-markdown-acceptance"]
        for _ in 0..<8 where !normalRow.isHittable { list.swipeUp() }
        XCTAssertTrue(normalRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(normalRow.isHittable, normalRow.debugDescription)
        XCTAssertTrue(normalRow.label.contains("A Markdown note"), normalRow.debugDescription)
        captureInboxColumnState("markdown-accessibility-normal-row", app)

        for _ in 0..<8 where !newRow.isHittable { list.swipeDown() }
        XCTAssertTrue(newRow.isHittable, newRow.debugDescription)
        newRow.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.82)).tap()

        let selection = app.descendants(matching: .any)["priority-capture-selection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5), app.debugDescription)
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "sample-markdown-acceptance"),
            object: selection)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                       "A non-link tap in the larger-text New row must keep existing navigation.\n\(app.debugDescription)")
        let heading = app.buttons["request-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.label.contains("A Markdown note"), heading.debugDescription)
        let body = app.textViews["request-message-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5), app.debugDescription)
        let bodyText = body.value as? String ?? body.label
        XCTAssertTrue(bodyText.contains("First item"), bodyText)
        XCTAssertTrue(bodyText.contains("let answer = 42"), bodyText)
        XCTAssertFalse(bodyText.contains("```"), bodyText)
        capture("markdown-accessibility-detail", app)
        app.terminate()
    }

    func testPlainTextRemainsReadableInNewNormalAndDetailInLightAndDark() {
        XCUIDevice.shared.orientation = .landscapeLeft

        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "--harklight-test-inbox-list-column",
                "--harklight-test-inbox-list-\(appearance)",
                "--harklight-test-inbox-list-state=acceptedNewMessage"
            ]
            app.launch()

            let selection = app.descendants(matching: .any)["priority-capture-selection"]
            XCTAssertTrue(selection.waitForExistence(timeout: 5), app.debugDescription)
            let newRow = app.descendants(matching: .any)[
                "new-message-area-request-row-sample-information-0"
            ]
            XCTAssertTrue(newRow.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(newRow.label.contains("Thursday"), newRow.debugDescription)
            XCTAssertFalse(newRow.label.contains("**"), newRow.debugDescription)
            captureInboxColumnState("plain-\(appearance)-new-row", app)

            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
            let normalRow = app.descendants(matching: .any)["request-row-sample-information-0"]
            for _ in 0..<8 where !normalRow.isHittable { list.swipeUp() }
            XCTAssertTrue(normalRow.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(normalRow.label.contains("Thursday"), normalRow.debugDescription)
            XCTAssertFalse(normalRow.label.contains("**"), normalRow.debugDescription)
            captureInboxColumnState("plain-\(appearance)-normal-row", app)

            for _ in 0..<8 where !newRow.isHittable { list.swipeDown() }
            XCTAssertTrue(newRow.isHittable, app.debugDescription)
            newRow.tap()
            let selected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "sample-information-0"),
                object: selection)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                           "Plain-text New selection should keep existing navigation.\n\(app.debugDescription)")
            XCTAssertTrue(newRow.waitForNonExistence(timeout: 5), app.debugDescription)
            let body = app.textViews["request-message-body"]
            XCTAssertTrue(body.waitForExistence(timeout: 5), app.debugDescription)
            let bodyText = body.value as? String ?? body.label
            XCTAssertTrue(bodyText.contains("The new time is 2 PM."), bodyText)
            XCTAssertFalse(bodyText.contains("**"), bodyText)
            capture("plain-\(appearance)-detail", app)
            app.terminate()
        }
    }

    func testReplyItemOpensParentChatScrolledToEarliestUnseenReply() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-samples", "--harklight-test-reply-item-area"]
        app.launch()

        let replyRow = app.descendants(matching: .any)["reply-item-request-row-sample-information-0"]
        XCTAssertTrue(replyRow.waitForExistence(timeout: 10), app.debugDescription)
        let unseenCount = app.descendants(matching: .any)["reply-item-unseen-count"]
        XCTAssertTrue(unseenCount.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(unseenCount.label.contains("2 new"), unseenCount.debugDescription)
        let inboxList = app.collectionViews.firstMatch
        XCTAssertTrue(inboxList.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(replyRow.isHittable, app.debugDescription)
        capture("reply-item-in-samples-inbox", app)

        let normalReply = app.descendants(matching: .any)[
            "normal-reply-item-sample-information-0"
        ]
        for _ in 0..<8 where !normalReply.isHittable {
            inboxList.swipeUp()
        }
        XCTAssertTrue(normalReply.isHittable,
                      "The server-ordered normal reply row must be reachable below New.\n\(app.debugDescription)")
        let normalQuote = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Newest unseen chat reply")
        ).firstMatch
        XCTAssertTrue(normalQuote.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(normalQuote.isHittable, normalQuote.debugDescription)
        let normalPriority = app.staticTexts["normal-reply-item-priority-now"]
        XCTAssertTrue(normalPriority.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(normalPriority.label.contains("Urgent"), normalPriority.debugDescription)
        capture("reply-item-normal-row-in-samples-inbox", app)

        for _ in 0..<8 where !replyRow.isHittable {
            inboxList.swipeDown()
        }
        XCTAssertTrue(replyRow.isHittable,
                      "The New reply item must remain reachable after viewing its normal row.\n\(app.debugDescription)")
        replyRow.tap()

        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription)
        let earliestReply = app.staticTexts[
            "Earliest unseen chat reply: the middle section of the draft now reads better."
        ]
        XCTAssertTrue(earliestReply.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(earliestReply.isHittable,
                      "The chat must open scrolled to the earliest unseen reply, past the long earlier history.\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts[
            "Earlier local discussion turn 1 keeps this example history long."
        ].isHittable,
                       "The top of the long history must be off screen when the chat lands on the reply.\n\(app.debugDescription)")
        capture("reply-item-tap-landed-on-earliest-unseen-reply", app)

        let requestHeading = app.buttons["request-heading"]
        XCTAssertTrue(requestHeading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(requestHeading.label.contains("Unread conversation"), requestHeading.debugDescription)

        let newestReply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Newest unseen chat reply: the revised draft")
        ).firstMatch
        XCTAssertFalse(newestReply.isHittable,
                       "The later reply must remain offscreen when the earliest unseen reply opens.")
        for _ in 0..<12 where !newestReply.isHittable {
            history.swipeUp()
        }
        XCTAssertTrue(newestReply.isHittable,
                      "Scrolling to the later reply must bring it into the chat viewport.\n\(app.debugDescription)")
        let readLabel = NSPredicate(format: "label CONTAINS %@", "Conversation read")
        expectation(for: readLabel, evaluatedWith: requestHeading)
        waitForExpectations(timeout: 5)
    }

    func testForegroundChatIndicatorOpensTheMatchingConversation() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-samples", "--harklight-test-foreground-chat-indicator"]
        app.launch()

        let indicators = app.buttons.matching(identifier: "foreground-chat-notification")
        XCTAssertTrue(indicators.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(indicators.count, 1,
                       "With no sheet open, the app root should show exactly one chat indicator.\n\(app.debugDescription)")
        let indicator = indicators.firstMatch
        XCTAssertTrue(indicator.label.contains("Agent reply"), app.debugDescription)
        capture("foreground-chat-indicator", app)
        indicator.tap()

        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts[
            "Agent example: the shorter path is faster, while the longer path is easier to revise."
        ].waitForExistence(timeout: 5), app.debugDescription)
        capture("foreground-chat-indicator-opened-matching-chat", app)
    }

    func testForegroundChatIndicatorAppearsOverOpenChatAndOpensOtherConversation() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-samples",
                               "--harklight-test-foreground-chat-indicator-over-chat"]
        app.launch()

        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts[
            "This local file demonstrates distinct transfer and use facts."
        ].waitForExistence(timeout: 5), "Chat A must be visible before chat B alerts.\n\(app.debugDescription)")

        let indicators = app.buttons.matching(identifier: "foreground-chat-notification")
        XCTAssertTrue(indicators.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let indicator = indicators.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(indicator,
                      "The chat B indicator must appear above the open chat A sheet.\n\(app.debugDescription)")
        guard let indicator else { return }
        capture("foreground-chat-indicator-over-open-chat-a", app)
        indicator.tap()

        let reply = app.staticTexts[
            "Agent example: the shorter path is faster, while the longer path is easier to revise."
        ]
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(reply.isHittable,
                      "Tapping the indicator must bring chat B above the already-open chat A.\n\(app.debugDescription)")
        capture("foreground-chat-indicator-opened-other-chat", app)
    }

    func testSentChatStatusLightShowsDeliveredAndKeepsReplyAsNextChatTurn() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-samples", "--harklight-test-chat-status-light"]
        app.launch()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()

        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Local example · status is simulated; nothing was sent."].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["Delivered"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Agent example: the shorter path is faster, while the longer path is easier to revise."].exists,
                      app.debugDescription)
        XCTAssertFalse(app.staticTexts["The agent marked this handled."].exists,
                       "Action folds into Delivered; an actual reply remains a chat turn.")
        XCTAssertFalse(app.staticTexts["Nothing's listening right now"].exists,
                       "A listening report does not add a composer warning.")
        capture("sent-chat-status-listening-light", app)
    }

    func testSentChatStatusDarkHighlightsUnreachableAndAgedWaitingWithoutClaimingFailure() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-samples", "--harklight-test-chat-status-dark"]
        app.launch()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()

        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        history.swipeUp()
        let delayed = app.staticTexts["Not delivered yet"]
        XCTAssertTrue(delayed.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Nothing's listening right now"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Local example · status is simulated; nothing was sent."].exists,
                      app.debugDescription)
        XCTAssertFalse(app.staticTexts["No one will get this"].exists,
                       "A delayed message is not presented as definitively undeliverable.")
        capture("sent-chat-status-not-listening-dark", app)
    }

    func testUnsupportedLatestReportShowsRedComposerNoticeWithoutRelabelingDeliveredMessage() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-samples", "--harklight-test-chat-status-dark",
                              "--harklight-test-chat-status-unsupported"]
        app.launch()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()

        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        history.swipeUp()
        let latestMessage = app.staticTexts["Could you check whether this message reached anyone?"]
        XCTAssertTrue(latestMessage.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(latestMessage.isHittable, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Delivered"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Not delivered yet"].exists,
                       "The latest unsupported report makes unreceived messages undeliverable.")
        let noOneWillGetThis = app.staticTexts["No one will get this"]
        XCTAssertTrue(noOneWillGetThis.exists, app.debugDescription)
        XCTAssertTrue(app.textViews["sample-chat-composer"].isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(
            NSPredicate(format: "label == %@", "No one will get this")).count, 2,
            "An unreceived message and the composer show the latest unsupported report; an earlier receipt stays Delivered.")
        capture("sent-chat-status-unsupported-composer-dark", app)
    }

    func testTwoAckStatusLightShowsSendingWaitingRerouteAndNegativeReason() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-samples", "--harklight-test-chat-status-light",
                               "--harklight-test-chat-status-two-ack"]
        app.launch()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()

        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        history.swipeUp()
        XCTAssertTrue(app.staticTexts["Local example · status is simulated; nothing was sent."].exists,
                      "These rows are synthetic display fixtures, not Server acceptance evidence.\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Sending…"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Waiting for Calendar assistant"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Delivered to Release orchestrator")).firstMatch.exists,
            app.debugDescription)
        XCTAssertTrue(app.staticTexts["Delivered"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Not delivered: The receiving system is unavailable."].exists,
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["No listener has picked this up"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Nothing's listening right now"].exists, app.debugDescription)
        capture("sent-chat-two-ack-light", app)
    }

    func testTwoAckIncapableListenerAck1IsFinalDeliveredLight() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-samples", "--harklight-test-chat-status-light",
                               "--harklight-test-chat-status-two-ack",
                               "--harklight-test-chat-status-ack1-final-only"]
        app.launch()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()

        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        let incapableListener = app.staticTexts["This listener cannot send ACK2."]
        XCTAssertTrue(incapableListener.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Delivered"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Local example · status is simulated; nothing was sent."].exists,
                      app.debugDescription)
        capture("sent-chat-two-ack-ack1-final-light", app)
    }

    func testTwoAckStatusDarkKeepsWaitingQuietAndDeliveredCaptionStable() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-samples", "--harklight-test-chat-status-dark",
                               "--harklight-test-chat-status-two-ack"]
        app.launch()

        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()

        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        history.swipeUp()
        XCTAssertTrue(app.staticTexts["Waiting for Calendar assistant"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Delivered to Release orchestrator")).firstMatch.exists,
            app.debugDescription)
        XCTAssertTrue(app.staticTexts["Nothing's listening right now"].exists, app.debugDescription)
        capture("sent-chat-two-ack-dark", app)
    }

    func testSendButtonAndReturnClearAcceptedLocalDiscussion() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()
        let composer = app.textViews["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        composer.tap()
        composer.typeText("A note submitted with Send.")
        let send = app.buttons["Send locally"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(history.staticTexts["A note submitted with Send."].waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertEqual(composer.value as? String, "Write a message…")
        XCTAssertFalse(send.isEnabled)
        composer.tap()
        composer.typeText("A note submitted with Return.")
        let keyboardSend = app.keyboards.buttons["Send"]
        XCTAssertTrue(keyboardSend.waitForExistence(timeout: 5), app.debugDescription)
        keyboardSend.tap()
        XCTAssertTrue(history.staticTexts["A note submitted with Return."].waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertEqual(composer.value as? String, "Write a message…")
        XCTAssertFalse(send.isEnabled)
    }

    func testOrdinaryConversationSharesAdaptivePanelWithoutLiveServices() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()
        let composers = app.textViews.matching(identifier: "sample-chat-composer")
        XCTAssertTrue(composers.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(composers.count, 1)
        XCTAssertTrue(app.staticTexts["Could you explain the tradeoff?"].exists,
                      "Ordinary request chat must project its domain history")
        let prompt = app.staticTexts["Could you explain the tradeoff?"]
        let reply = app.staticTexts["The first option favors speed; the second leaves more room to revise. This is an example conversation."]
        let agentReply = app.staticTexts["Agent example: the shorter path is faster, while the longer path is easier to revise."]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(agentReply.waitForExistence(timeout: 5), app.debugDescription)
        let versionOneLabel = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "version 1")).firstMatch
        XCTAssertFalse(versionOneLabel.exists,
                       "Original-revision message headers omit the version-one label.")
        XCTAssertLessThan(prompt.frame.minY, reply.frame.minY,
                          "A reply must appear below the prompt it answers even when its ID sorts first")
        XCTAssertLessThan(reply.frame.minY, agentReply.frame.minY,
                          "The later reply must remain below the earlier reply it answers")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Replying to: Could you explain the tradeoff?"
        )).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Replying to: The first option favors speed"
        )).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Local example · nothing sent"].exists,
                      "The fixture must keep its local delivery state truthful")
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

    func testNoChatStateExplainsMissingThreadAndKeepsMessageActionAvailable() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()

        let seenAction = app.buttons["request-seen-action"]
        XCTAssertTrue(seenAction.waitForExistence(timeout: 5), app.debugDescription)
        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        chat.tap()

        let noChatTitle = app.staticTexts["No chat"]
        let noChatDescription = app.staticTexts[
            "The agent that sent this didn’t open a chat for it. You can still respond to the message itself."
        ]
        XCTAssertTrue(noChatTitle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(noChatDescription.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Chat unavailable"].exists,
                       "A confirmed local no-chat example must not be presented as a server failure.")
        XCTAssertFalse(app.textViews["sample-chat-composer"].exists,
                       "A missing chat thread must not show a chat composer.")
        capture("conversation-no-chat-empty-state", app)

        let screen = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let frame = app.windows.firstMatch.frame
        let start = screen.withOffset(CGVector(dx: frame.midX, dy: frame.minY + 20))
        let end = start.withOffset(CGVector(dx: 0, dy: min(400, frame.height * 0.8)))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(noChatTitle.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(seenAction.exists, "The message's Seen response remains available outside the no-chat view.")
    }

    func testChatPanelRemovesRedundantRowsAndKeepsComposerControlsAlignedAsPromptGrows() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        chat.tap()

        let composer = app.textViews["sample-chat-composer"]
        let inputSurface = app.otherElements["sample-chat-input-surface"]
        let add = app.buttons["sample-chat-add-attachment"]
        let send = app.buttons["sample-chat-send"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(inputSurface.exists, app.debugDescription)
        XCTAssertTrue(add.exists && send.exists, app.debugDescription)
        XCTAssertTrue(inputSurface.isHittable,
                      "The Chat presentation exposes its composer surface.")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "About ")).firstMatch.exists,
                       "The conversation panel no longer shows request-context title text.")
        XCTAssertFalse(app.staticTexts["Local conversation · nothing sent"].exists,
                       "The redundant conversation footer is not shown.")
        XCTAssertFalse(app.staticTexts["conversation-availability"].exists,
                       "The standalone listening row is not shown.")
        XCTAssertFalse(app.buttons["Close"].exists,
                       "The conversation panel no longer needs a large toolbar X.")
        XCTAssertFalse(send.isEnabled,
                       "Removing the footer and listening row does not make an empty draft sendable.")

        let singleLineTextHeight = composer.frame.height
        let singleLineControlHeight = inputSurface.frame.height
        XCTAssertEqual(singleLineControlHeight, 44, accuracy: 1,
                       "The single-line text field surface uses the shared 44-point control height.")
        XCTAssertEqual(add.frame.height, singleLineControlHeight, accuracy: 1,
                       "The plus control matches the single-line prompt height.")
        XCTAssertEqual(send.frame.height, singleLineControlHeight, accuracy: 1,
                       "The send control matches the single-line prompt height.")
        capture("chat-panel-headerless-equal-composer", app)

        composer.tap()
        composer.typeText("This prompt grows onto multiple lines inside the native chat panel.")
        XCTAssertTrue(send.isEnabled,
                      "A nonempty draft remains sendable after removing the redundant rows.")
        let multilineTextHeight = composer.frame.height
        let multilineSurfaceHeight = inputSurface.frame.height
        XCTAssertGreaterThan(multilineTextHeight, singleLineTextHeight + 8,
                             "The vertical text field expands to show its wrapped text.")
        XCTAssertGreaterThan(multilineSurfaceHeight, singleLineControlHeight + 8,
                             "The glass input surface grows with the multiline prompt.")
        XCTAssertEqual(add.frame.height, singleLineControlHeight, accuracy: 1,
                       "Multiline growth does not stretch the plus button.")
        XCTAssertEqual(send.frame.height, singleLineControlHeight, accuracy: 1,
                       "Multiline growth does not stretch the send button.")
        capture("chat-panel-multiline-prompt", app)
    }

    func testChatHistoryKeepsKeyboardUntilDownwardSwipe() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10), app.debugDescription)
        enterSearch("Thursday", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-information-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        app.buttons["Chat"].tap()

        let composer = app.textViews["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        let history = app.scrollViews["conversation-history-scroll"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), app.debugDescription)
        history.swipeUp()
        let latestMessage = history.staticTexts[
            "Agent example: the shorter path is faster, while the longer path is easier to revise."
        ]
        let firstMessage = history.staticTexts["Could you explain the tradeoff?"]
        XCTAssertTrue(latestMessage.isHittable, app.debugDescription)

        let chatDraft = "Keep this unsent prompt while I read the conversation."
        composer.tap()
        composer.typeText(chatDraft)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), app.debugDescription)

        latestMessage.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2),
                      "Tapping conversation content leaves the composer keyboard open.")
        XCTAssertEqual(composer.value as? String, chatDraft,
                       "Tapping conversation content preserves the unsent prompt.")

        let addAttachment = app.buttons["sample-chat-add-attachment"]
        XCTAssertTrue(addAttachment.isHittable, app.debugDescription)
        addAttachment.tap()
        let samplePhoto = app.buttons["Sample photo"]
        XCTAssertTrue(samplePhoto.waitForExistence(timeout: 5), app.debugDescription)
        samplePhoto.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2),
                      "Returning from the attachment action leaves the composer keyboard open.")
        XCTAssertEqual(composer.value as? String, chatDraft,
                       "The attachment action preserves the unsent prompt.")

        history.swipeUp()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2),
                      "Scrolling toward older conversation content keeps the keyboard open.")
        history.swipeDown()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2),
                      "Scrolling back through the history keeps the keyboard open until the content reaches its start.")
        XCTAssertTrue(firstMessage.isHittable,
                      "The downward content swipe has returned the history to its first message.")

        // Interactive dismissal tracks a downward scroll gesture after it enters
        // the keyboard area, so begin on history and continue through the composer.
        let dismissalStart = history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        let dismissalEnd = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        dismissalStart.press(forDuration: 0.1, thenDragTo: dismissalEnd)
        XCTAssertFalse(keyboard.waitForExistence(timeout: 1.5),
                       "A downward swipe at the start of conversation history dismisses the keyboard interactively.")
        XCTAssertEqual(composer.value as? String, chatDraft,
                       "Interactive dismissal preserves the unsent chat draft.")
        composer.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5),
                      "The composer can be focused again after interactive dismissal.")
        XCTAssertEqual(composer.value as? String, chatDraft,
                       "Refocusing the composer preserves the unsent draft.")
    }

    func testAcceptedSenderUpdateIsVisibleInTheSameOrdinaryRequestAndHistory() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-test-markdown-history"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("Archive", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-approval-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Updated"))
        row.tap()
        XCTAssertTrue(app.buttons["request-update-fact"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["request-update-fact"].label, "Updated · version 2")
        capture("sender-updated-current-request", app)
        app.buttons["Chat"].tap()
        XCTAssertTrue(app.staticTexts["Updated"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["conversation-revision-picker"].exists,
                       "Chat keeps the item's conversation history without a version selector.")
        capture("sender-updated-chat-has-no-version-selector", app)
    }

    func testMixedCleanupRetainsUnidentifiedFilesWithoutInventedCommittedHistory() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("welcome", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-review-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["Chat"].tap()
        let composer = app.textViews["sample-chat-composer"]
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
        let row = app.descendants(matching: .any)["request-row-sample-review-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["Chat"].tap()
        let composer = app.textViews["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["conversation-upload-cleanup-status"].exists)
        dismissChatSheet(app)
        app.buttons["Chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["conversation-upload-cleanup-status"].exists, "Closing chat alone does not leave its message")
        dismissChatSheet(app)
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
        app.launchArguments = ["--harklight-ui-diagnostics"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        enterSearch("welcome", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-review-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["Chat"].tap()
        let composer = app.textViews["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Keep this file note.")
        XCTAssertFalse(app.otherElements["conversation-upload-cleanup-status"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["conversation-upload-cleanup-status"].exists, "Adaptive reconstruction is not message departure")
        capture("upload-before-message-departure", app)
        XCUIDevice.shared.orientation = .portrait
        // A wide landscape layout may reveal its passive inline panel and
        // dismiss the sheet during rotation. Reopen the button presentation.
        if !app.textViews["sample-chat-composer"].exists { app.buttons["Chat"].tap() }
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        dismissChatSheet(app)
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5), app.debugDescription)
        XCUIDevice.shared.orientation = .landscapeLeft
        showInbox(app)
        let other = app.descendants(matching: .any)["request-row-sample-review-0"]
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        guard reveal(other, in: listContainer(app), app: app) else { return }
        other.tap()
        // In a regular-width split view the sidebar rows expose these titles too,
        // so only the detail card can show that the selection changed.
        let detail = app.scrollViews["message-card-scroll"]
        let departed = detail.staticTexts["Review the studio welcome text"].waitForExistence(timeout: 5)
        recordDiagnostics("after-departure", app)
        XCTAssertTrue(departed, "Selecting another row must change the detail identity before cleanup is assessed")
        showInbox(app)
        guard reveal(row, in: listContainer(app), app: app) else { return }
        row.tap()
        let returned = detail.staticTexts["Review the library welcome text"].waitForExistence(timeout: 5)
        recordDiagnostics("after-return", app)
        XCTAssertTrue(returned, "Returning to the original row must restore its exact detail identity")
        app.buttons["Chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let cleanupShown = app.staticTexts["Upload cleanup unconfirmed. Retry cleanup before reselecting files; your text draft is retained."].waitForExistence(timeout: 5)
        recordDiagnostics("after-return-chat", app)
        XCTAssertTrue(cleanupShown)
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

    func testEdgePullDoesNotChangeSelectedMessageAndBackReturnsToEntryTab() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--harklight-ui-diagnostics"]
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        let entryTab = workspaceTab("Inbox", in: app)
        XCTAssertTrue(entryTab.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(entryTab.isSelected, "The sample message should be opened from the Inbox entry tab.")
        let list = listContainer(app)
        // Open the information example after placing its row in view.
        let opened = app.descendants(matching: .any)["request-row-sample-information-1"]
        XCTAssertTrue(app.descendants(matching: .any)["request-row-sample-information-2"].waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<30 where !unobscured(opened, in: list, app: app) {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -150)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(unobscured(opened, in: list, app: app), app.debugDescription)
        opened.tap()
        let card = app.scrollViews["message-card-scroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        let counter = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+ of [0-9]+'")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), app.debugDescription)
        let originalPosition = counter.label
        let lower = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        lower.press(forDuration: 0.1, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertEqual(counter.label, originalPosition,
                       "Pulling past the bottom of a message must not select another one.")
        upper.press(forDuration: 0.1, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertEqual(counter.label, originalPosition,
                       "Pulling past the top of a message must not select another one.")
        recordDiagnostics("after-edge-pull", app)
        let probe = app.descendants(matching: .any)["inbox-ui-diagnostics"].firstMatch
        XCTAssertTrue(probe.label.contains("lastViewed=request:sample-information-1 "), probe.label)
        let back = workspaceBackButton(in: app)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        let returnedToInbox = entryTab.waitForExistence(timeout: 5) && entryTab.isSelected
            && card.waitForNonExistence(timeout: 5)
        recordDiagnostics("after-back", app)
        XCTAssertTrue(returnedToInbox,
                      "Back without switching messages must return to the entry tab. \(app.debugDescription)")
    }

    func testRetractedItemKeepsItsSelectedChoiceHistoryAndUnsentDiscussion() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["inbox-settings"].waitForExistence(timeout: 10))
        workspaceTab("Inbox", in: app).tap()
        enterSearch("Archive", in: app)
        let row = app.descendants(matching: .any)["request-row-sample-approval-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Retracted"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The sender retracted this request. Saved work and its original delivery status are retained; no further answer will be sent."].exists)
        XCTAssertFalse(app.descendants(matching: .any)["request-not-accepted-status"].exists,
                        "An unsent saved draft is not presented as a refused answer.")
        capture("sender-retracted-retained-request", app)
        app.buttons["Chat"].tap()
        let composer = app.textViews["sample-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Please keep this unsent note.")
        XCTAssertFalse(composer.isEnabled)
        XCTAssertFalse(app.buttons["Send locally"].isEnabled)
        let savedDraft = app.buttons["conversation-earlier-answer"]
        XCTAssertTrue(savedDraft.waitForExistence(timeout: 5),
                      "The unrelated unsent draft remains available when no answer was refused.")
        savedDraft.tap()
        XCTAssertTrue(app.staticTexts["Saved answer · request retracted. Its original wording and choices are retained."].waitForExistence(timeout: 5))
        let savedChoice = app.buttons.matching(NSPredicate(format: "label == %@", "Archive")).firstMatch
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
            let row = app.descendants(matching: .any)["request-row-" + id]
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            row.tap()
            app.buttons["Chat"].tap()
            XCTAssertTrue(app.textViews["sample-chat-composer"].waitForExistence(timeout: 5))
        }
        open("sample-approval-2", search: "Archive")
        XCTAssertTrue(app.staticTexts["Please review the sketches before archiving. The earlier answer draft is retained."].exists)
        capture("conversation-current-revision", app)
        let chatComposer = app.textViews["sample-chat-composer"]
        XCTAssertFalse(app.buttons["conversation-revision-picker"].exists,
                       "Conversation history does not expose a version picker.")
        let draft = "Keep this chat draft while I read the earlier version."
        chatComposer.tap()
        chatComposer.typeText(draft)
        XCTAssertEqual(chatComposer.value as? String, draft)
        dismissChatSheet(app)

        let detailVersionIndicator = app.buttons["request-update-fact"]
        XCTAssertTrue(detailVersionIndicator.waitForExistence(timeout: 5), app.debugDescription)
        detailVersionIndicator.tap()
        let versionHistory = app.scrollViews["request-version-history"]
        XCTAssertTrue(versionHistory.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["request-version-card-1"].exists,
                      app.debugDescription)
        let copyEarlierVersion = app.buttons["request-version-copy-1"]
        XCTAssertTrue(copyEarlierVersion.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["conversation-earlier-answer"].exists,
                       "The version view has no answer control.")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "conversation-carried-over-retry-")).firstMatch.exists,
                       "The version view has no Retry control.")
        XCTAssertFalse(app.buttons["sample-chat-send"].exists,
                       "The version view has no chat Send control.")
        copyEarlierVersion.tap()
        app.buttons["request-version-history-done"].tap()
        app.buttons["Chat"].tap()
        XCTAssertTrue(chatComposer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(chatComposer.value as? String, draft,
                       "Opening and closing read-only version history preserves the chat draft.")
        capture("conversation-read-copy-version-preserves-draft", app)
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
        XCTAssertFalse(app.textViews["sample-chat-composer"].isEnabled)
        XCTAssertFalse(app.buttons["Send locally"].isEnabled)
        capture("conversation-explicit-closure", app)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func captureInboxColumnState(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func dismissChatSheet(_ app: XCUIApplication) {
        let composer = app.textViews["sample-chat-composer"]
        let inputSurface = app.otherElements["sample-chat-input-surface"]
        // The saved accessibility hierarchy exposes the native presentation's
        // history and composer but has no Sheet node, so anchor the swipe to the history.
        let history = app.scrollViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(inputSurface.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(history.exists, app.debugDescription)
        let start = history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        let end = history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(inputSurface.waitForNonExistence(timeout: 5), app.debugDescription)
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

    private func enterSearch(_ query: String, in app: XCUIApplication) {
        let field = workspaceSearchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        let clearText = field.buttons["Clear text"]
        if clearText.exists && clearText.isHittable { clearText.tap() }
        field.tap()
        field.typeText(query + "\n")
    }

    private func showInbox(_ app: XCUIApplication) {
        guard app.scrollViews["message-card-scroll"].exists else { return }
        let searchField = app.searchFields.firstMatch
        let back = app.navigationBars.buttons.firstMatch
        if back.exists && back.isHittable {
            back.tap()
        } else {
            let sidebar = app.buttons["Show Sidebar"]
            if sidebar.exists && sidebar.isHittable { sidebar.tap() }
        }
        XCTAssertTrue(workspaceTab("Inbox", in: app).waitForExistence(timeout: 5) ||
                      workspaceTab("Replied", in: app).waitForExistence(timeout: 5) ||
                      searchField.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func listContainer(_ app: XCUIApplication) -> XCUIElement {
        // In split view, the detail card is also a scroll view but it cannot scroll the list.
        let collectionView = app.collectionViews.firstMatch
        if collectionView.exists { return collectionView }
        let table = app.tables.firstMatch
        if table.exists { return table }
        let listScrollViews = app.scrollViews.matching(NSPredicate(format: "identifier != %@", "message-card-scroll"))
        let scrollView = listScrollViews.firstMatch
        return scrollView
    }

    /// Whether the whole row is inside the list, above its bottom tab and search controls.
    private func unobscured(_ element: XCUIElement, in scrollView: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let bottom = bottomControlsTop(app)
        let frame = element.frame
        return element.isHittable && frame.minY >= scrollView.frame.minY && frame.maxY <= bottom
    }

    /// Scrolls until the whole row is below the navigation bar and above the
    /// bottom controls. Returns false with a screenshot if it remains blocked.
    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("Row does not exist: \(app.debugDescription)")
            return false
        }
        func unobscured() -> Bool {
            let bottom = bottomControlsTop(app)
            let navigationBar = app.navigationBars.firstMatch
            let top = max(scrollView.frame.minY,
                          navigationBar.exists ? navigationBar.frame.maxY : scrollView.frame.minY)
            let frame = element.frame
            return element.isHittable && frame.minY >= top && frame.maxY <= bottom
        }
        for _ in 0..<8 {
            if unobscured() { return true }
            let direction: CGFloat = element.frame.midY < scrollView.frame.midY ? 180 : -180
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: direction)),
                        withVelocity: .slow,
                        thenHoldForDuration: 0.3)
        }
        if unobscured() { return true }
        capture("row-outside-list-after-scrolling", app)
        XCTFail("Row stayed outside the unobscured list after scrolling: frame=\(element.frame), hittable=\(element.isHittable), list=\(scrollView.frame)\n\(app.debugDescription)")
        return false
    }

    private func bottomControlsTop(_ app: XCUIApplication) -> CGFloat {
        let tabButtons = [
            workspaceTab("Inbox", in: app),
            workspaceTab("Replied", in: app),
        ].filter(\.exists)
        if let tabTop = tabButtons.map(\.frame.minY).min() { return tabTop }
        let searchField = app.searchFields.firstMatch
        return searchField.exists ? searchField.frame.minY : app.windows.firstMatch.frame.maxY
    }
}

@MainActor
private func workspaceTab(_ title: String, in app: XCUIApplication) -> XCUIElement {
    let tabBarButton = app.tabBars.buttons[title]
    if tabBarButton.exists { return tabBarButton }
    return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
}

@MainActor
private func workspaceSearchField(in app: XCUIApplication) -> XCUIElement {
    let field = app.searchFields.firstMatch
    if field.exists { return field }
    let list = app.collectionViews.firstMatch
    if list.exists {
        for _ in 0..<3 {
            list.swipeDown()
            if field.waitForExistence(timeout: 1) { break }
        }
    }
    return field
}

@MainActor
private func workspaceBackButton(in app: XCUIApplication) -> XCUIElement {
    let toolbarBack = app.toolbars.buttons["BackButton"]
    if toolbarBack.exists { return toolbarBack }

    let navigationBack = app.navigationBars.buttons.matching(
        NSPredicate(format: "identifier == 'BackButton' OR label == 'Back'")
    ).firstMatch
    if navigationBack.exists { return navigationBack }

    return app.buttons["BackButton"]
}
