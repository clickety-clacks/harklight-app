import XCTest
@testable import Harklight
import AttentionDomain

/// The icon badge counts the Inbox rows that still need attention: the rows
/// the Inbox tab lists, judged by the same membership rule the list uses,
/// except retracted messages, which stay listed but no longer count. Zero
/// when nothing needs attention.
@MainActor
final class InboxBadgeCountTests: XCTestCase {
    private func row(_ messageID: String, status: String = "Pending",
                     hasUserAction: Bool = false, localSeenSelected: Bool = false,
                     informationalSeenStatus: InformationalSeenStatus? = nil,
                     hasFailedResponse: Bool = false,
                     isRetracted: Bool = false) -> InboxRequestRow {
        var row = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                            messageID: ExactText(messageID)),
            title: "Message " + messageID, sender: "Planning assistant", status: status)
        row.hasUserAction = hasUserAction
        row.localSeenSelected = localSeenSelected
        row.informationalSeenStatus = informationalSeenStatus
        row.hasFailedResponse = hasFailedResponse
        row.isRetracted = isRetracted
        return row
    }

    func testEmptyInboxCountsZeroSoTheBadgeClears() {
        XCTAssertEqual(InboxBadge.count(requests: [], samples: SampleLibrary(),
                                        showsLocalExamples: true), 0)
        XCTAssertEqual(InboxBadge.count(requests: [], samples: SampleLibrary(),
                                        showsLocalExamples: false), 0)
    }

    func testOnlyRowsWithoutAnExplicitActionCount() {
        let requests = [
            row("open"),
            row("answered", status: "Answered", hasUserAction: true),
            row("seen-locally", localSeenSelected: true),
            row("seen-pending", informationalSeenStatus: .pending),
            row("seen-confirmed", informationalSeenStatus: .confirmed),
            row("seen-available", informationalSeenStatus: .available),
        ]
        // Only "open" and "seen-available" lack an action; Seen counts as a reply
        // once chosen, even while its delivery is still pending.
        XCTAssertEqual(InboxBadge.count(requests: requests, samples: SampleLibrary(),
                                        showsLocalExamples: true), 2)
    }

    func testFailedDeliveryReturnsAnActedRowToTheCount() {
        let failed = row("refused", status: "Answer not delivered",
                         hasUserAction: true, hasFailedResponse: true)
        XCTAssertEqual(InboxBadge.count(requests: [failed], samples: SampleLibrary(),
                                        showsLocalExamples: true), 1)
    }

    func testRetractedRowsStayListedButStopCounting() {
        let requests = [
            row("open"),
            row("retracted", status: "Retracted", isRetracted: true),
        ]
        let listed = InboxListProjection.filteredRows(requests.map(InboxItem.request),
                                                      in: .inbox, search: "")
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(InboxBadge.count(requests: requests, samples: SampleLibrary(),
                                        showsLocalExamples: true), 1)
    }

    func testAnAnswerRefusedByRetractionDoesNotReturnToTheCount() {
        // A failed delivery normally returns an acted row to the count, but a
        // retraction refusal means nothing is awaited from the person anymore.
        let refused = row("refused-by-retraction", status: "Retracted",
                          hasUserAction: true, hasFailedResponse: true, isRetracted: true)
        XCTAssertEqual(InboxBadge.count(requests: [refused], samples: SampleLibrary(),
                                        showsLocalExamples: true), 0)
    }

    func testBadgeMatchesTheInboxTabListMinusRetractedRows() {
        let samples = SampleLibrary()
        samples.populate()
        let requests = [
            row("open"),
            row("answered", status: "Answered", hasUserAction: true),
            row("refused", hasUserAction: true, hasFailedResponse: true),
            row("retracted", status: "Retracted", isRetracted: true),
        ]
        for showsLocalExamples in [true, false] {
            let items = showsLocalExamples ? samples.inboxItems(appendingTo: requests)
                : requests.map(InboxItem.request)
            let listed = InboxListProjection.filteredRows(items, in: .inbox,
                                                          search: "")
            XCTAssertTrue(listed.contains { $0.isRetracted },
                          "A retracted row must stay visible in the Inbox list")
            XCTAssertEqual(InboxBadge.count(requests: requests, samples: samples,
                                            showsLocalExamples: showsLocalExamples),
                           listed.filter { !$0.isRetracted }.count)
        }
    }

    func testLocalExamplesCountWhileShownAndLeaveWhenTheyMoveToReplied() throws {
        let samples = SampleLibrary()
        samples.populate()
        let shown = InboxBadge.count(requests: [], samples: samples, showsLocalExamples: true)
        XCTAssertGreaterThan(shown, 0)
        XCTAssertEqual(InboxBadge.count(requests: [], samples: samples,
                                        showsLocalExamples: false), 0)

        // A failed delivery keeps a row in the Inbox regardless of local actions,
        // and a retracted example never counts, so demonstrate removal on an
        // example with neither.
        let unreplied = try XCTUnwrap(samples.inboxItems(appendingTo: []).first {
            guard case let .example(_, response) = $0 else { return false }
            return !$0.belongsToReplied && !$0.isRetracted &&
                response.inboxRow?.hasFailedResponse != true
        })
        guard case let .example(_, response) = unreplied else {
            return XCTFail("Expected a local example row")
        }
        response.finished = true
        let afterAction = InboxBadge.count(requests: [], samples: samples,
                                           showsLocalExamples: true)
        XCTAssertEqual(afterAction, shown - 1)
    }
}
