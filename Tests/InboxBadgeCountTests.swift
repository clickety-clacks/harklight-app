import XCTest
@testable import Harklight
import AttentionDomain

/// The icon badge equals the Inbox count: rows the Inbox tab lists, judged by
/// the same membership rule the list uses, and zero when the Inbox is empty.
@MainActor
final class InboxBadgeCountTests: XCTestCase {
    private func row(_ messageID: String, status: String = "Pending",
                     hasUserAction: Bool = false, localSeenSelected: Bool = false,
                     informationalSeenStatus: InformationalSeenStatus? = nil,
                     hasFailedResponse: Bool = false) -> InboxRequestRow {
        var row = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                            messageID: ExactText(messageID)),
            title: "Message " + messageID, sender: "Planning assistant", status: status)
        row.hasUserAction = hasUserAction
        row.localSeenSelected = localSeenSelected
        row.informationalSeenStatus = informationalSeenStatus
        row.hasFailedResponse = hasFailedResponse
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

    func testBadgeMatchesTheInboxTabListOverTheSameItems() {
        let samples = SampleLibrary()
        samples.populate()
        let requests = [
            row("open"),
            row("answered", status: "Answered", hasUserAction: true),
            row("refused", hasUserAction: true, hasFailedResponse: true),
        ]
        for showsLocalExamples in [true, false] {
            let items = showsLocalExamples ? samples.inboxItems(appendingTo: requests)
                : requests.map(InboxItem.request)
            let listed = InboxListProjection.filteredRows(items, in: .inbox,
                                                          selectedTab: .inbox, search: "")
            XCTAssertEqual(InboxBadge.count(requests: requests, samples: samples,
                                            showsLocalExamples: showsLocalExamples),
                           listed.count)
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
        // so demonstrate removal on an example without one.
        let unreplied = try XCTUnwrap(samples.inboxItems(appendingTo: []).first {
            guard case let .example(_, response) = $0 else { return false }
            return !$0.belongsToReplied && response.inboxRow?.hasFailedResponse != true
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
