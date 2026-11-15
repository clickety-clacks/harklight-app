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

    func testRemoteFlagOffRestoresOrdinaryRowsWithoutHidingProgressData() throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("flag-person"), deviceID: ExactText("flag-device")), transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let flags = RemoteFeatureFlags()
        let id = UUID()
        flags.connect(context: context, connectionID: id)
        let live = try LivePresentationStore(store: domain, context: context, featureFlags: flags)
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("progress-work"))
        let payload = try JSONValue.parse(Data(#"""
            {"title":"Work in progress","body":"Keep this message visible","message_type":"fyi",
             "progress":{"updated_at":"2026-11-09T10:00:00Z","percent":45,"stage":"coding",
                         "segments":[{"stage":"coding","width":45}]}}
            """#.utf8))
        _ = try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        try live.refreshFromDurableStore()

        let onItems = live.inboxRows.map(InboxItem.request)
        XCTAssertEqual(ProgressInboxProjection.rows(onItems, search: "").map(\.key), [key])
        XCTAssertTrue(InboxListProjection.filteredRows(onItems, in: .inbox, search: "").isEmpty)

        flags.replace(RemoteFeatureFlagSnapshot(field: .object([
            JSONMember("progress_inbox", .bool(false))
        ])), connectionID: id)
        XCTAssertFalse(live.progressInboxEnabled)
        XCTAssertNotNil(live.request(for: key)?.messageProgress, "The flag must not delete Server data")
        let ordinary = try XCTUnwrap(live.inboxRow(for: key))
        XCTAssertNil(ordinary.progress, "OFF restores ordinary row rendering and controls")
        XCTAssertEqual(ordinary.title, "Work in progress")
        XCTAssertEqual(ordinary.bodyText, "Keep this message visible")
        let offItems = live.inboxRows.map(InboxItem.request)
        XCTAssertTrue(ProgressInboxProjection.rows(offItems, search: "", enabled: false).isEmpty)
        XCTAssertEqual(InboxListProjection.filteredRows(offItems, in: .inbox, search: "").map(\.id),
                       [.request(key)])
        for serverItems in [nil, [InboxViewListItem(kind: .message, key: key)]] as [[InboxViewListItem]?] {
            let entries = InboxNormalListProjection.entries(rows: offItems,
                serverItems: serverItems, in: .inbox, search: "")
            let selections = entries.flatMap { entry -> [InboxSelection] in
                guard case let .message(message) = entry else { return [] }
                return message.members.map(\.id)
            }
            XCTAssertEqual(selections, [.request(key)], "OFF restores both old-server and server-ranked lists")
        }
        XCTAssertEqual(InboxBadge.count(requests: live.inboxRows, samples: SampleLibrary(),
                                       showsLocalExamples: false), 1)

        flags.replace(RemoteFeatureFlagSnapshot(field: .object([
            JSONMember("progress_inbox", .bool(true))
        ])), connectionID: id)
        XCTAssertEqual(ProgressInboxProjection.rows(live.inboxRows.map(InboxItem.request),
                                                   search: "").map(\.key), [key])
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
