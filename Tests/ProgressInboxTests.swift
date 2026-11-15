import AttentionDomain
import XCTest
@testable import Harklight

@MainActor
final class ProgressInboxTests: XCTestCase {
    private func row(_ id: String, time: String = "2026-11-09T10:00:00Z",
                     percent: Int = 45, marked: Bool = true) throws -> InboxRequestRow {
        var row = InboxRequestRow(key: RequestKey(accountScope: ExactText("account"),
            senderID: ExactText("sender"), messageID: ExactText(id)),
            title: id, sender: "Studio", status: "Pending")
        if marked {
            let raw = """
            {"message_type":"fyi","progress":{"updated_at":"\(time)",
             "percent":\(percent),"stage":"coding","segments":[{"stage":"coding","width":\(percent)}]}}
            """
            row.progress = MessageProgress.read(from: try JSONValue.parse(Data(raw.utf8)))
        }
        return row
    }

    func testRemoteFlagHidesProgressAndRestoresItWithoutChangingOrdinaryRows() throws {
        let progress = try row("work")
        let ordinary = try row("ordinary", marked: false)
        let items = [progress, ordinary].map(InboxItem.request)
        XCTAssertTrue(ProgressInboxProjection.rows(items, search: "", enabled: false).isEmpty)
        XCTAssertEqual(ProgressInboxProjection.rows(items, search: "", enabled: true).map(\.key),
                       [progress.key])
        XCTAssertEqual(InboxListProjection.filteredRows(items, in: .inbox, search: "").count, 1)
    }

    func testProgressSortsByAgentTimeThenIdentityWithUnavailableLast() throws {
        let a = try row("a")
        let b = try row("b")
        let latest = try row("latest", time: "2026-11-09T11:00:00Z")
        let bad = try row("unavailable", time: "bad")
        let rows = ProgressInboxProjection.rows([bad, b, latest, a].map(InboxItem.request), search: "")
        XCTAssertEqual(rows.map(\.title), ["latest", "a", "b", "unavailable"])
        XCTAssertEqual(rows.last?.progress, .unavailable)
    }

    func testCompleteStaysButTerminalAndRetractedProgressLeave() throws {
        let complete = try row("complete", percent: 100)
        var closed = try row("closed")
        closed.isResolved = true
        var retracted = try row("retracted")
        retracted.isRetracted = true
        let rows = ProgressInboxProjection.rows([complete, closed, retracted].map(InboxItem.request), search: "")
        XCTAssertEqual(rows.map(\.key), [complete.key])
    }

    func testProgressNeverCountsOrLeaksIntoOrdinaryListsIncludingServerOrder() throws {
        let ordinary = try row("ordinary", marked: false)
        let complete = try row("complete", percent: 100)
        let malformed = try row("malformed", time: "bad")
        let requests = [ordinary, complete, malformed]
        let items = requests.map(InboxItem.request)
        XCTAssertEqual(InboxBadge.count(requests: requests, samples: SampleLibrary(),
                                       showsLocalExamples: false), 1)
        for tab in [InboxWorkspaceTab.inbox, .replied] {
            let filtered = InboxListProjection.filteredRows(items, in: tab, search: "")
            XCTAssertFalse(filtered.contains(where: \.isProgress))
            let server = requests.map { InboxViewListItem(kind: .message, key: $0.key) }
            let entries = InboxNormalListProjection.entries(rows: items, serverItems: server, in: tab, search: "")
            let keys = entries.flatMap { entry -> [InboxSelection] in
                guard case let .message(message) = entry else { return [] }
                return message.members.map(\.id)
            }
            XCTAssertFalse(keys.contains(.request(complete.key)))
            XCTAssertFalse(keys.contains(.request(malformed.key)))
        }
    }

    func testFiveAndMoreDoesNotDependOnOrdinaryInboxAndSearchKeepsProgress() throws {
        let requests = try (0..<7).map { try row("work-\($0)") }
        let items = requests.map(InboxItem.request)
        let rows = ProgressInboxProjection.rows(items, search: "")
        XCTAssertEqual(ProgressInboxProjection.shown(rows, expanded: false).count, 5)
        XCTAssertEqual(ProgressInboxProjection.shown(rows, expanded: true).count, 7)
        XCTAssertEqual(ProgressInboxProjection.rows(items, search: "work-6").map(\.title), ["work-6"])
        XCTAssertTrue(InboxListProjection.filteredRows(items, in: .inbox, search: "").isEmpty)
        XCTAssertTrue(ProgressInboxProjection.rows([], search: "").isEmpty)
    }
}
