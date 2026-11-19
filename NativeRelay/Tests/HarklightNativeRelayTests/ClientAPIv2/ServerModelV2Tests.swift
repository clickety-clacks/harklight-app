import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

/// Fixtures in the accepted contract's shapes (docs/client-api-v2.md edff7e9
/// with contract rulings round 2).
enum V2Fixture {
    static func item(_ id: String, rev: Int, rankKey: String, section: String = "priority",
                     message: String = #"{"title":"Question","body":"b"}"#, terminal: String? = nil,
                     chat: String = #"{"available":true,"started":false}"#, extra: String = "") -> String {
        var members = [
            #""item_id":"\#(id)""#, #""rev":\#(rev)"#, #""sender":"agent-app""#, #""request_revision":1"#,
            #""message":\#(message)"#, #""files":[]"#, #""seen":false"#, #""chat":\#(chat)"#,
            #""availability":{"state":"not_listening","last_detached_at_ms":5}"#,
            #""rank":{"key":"\#(rankKey)","score":0.930,"section":"\#(section)"}"#,
            #""future_member":{"ignored":true}"#
        ]
        if let terminal { members.append(#""terminal":\#(terminal)"#) }
        if !extra.isEmpty { members.append(extra) }
        return "{" + members.joined(separator: ",") + "}"
    }

    static func entry(_ id: String, item: String, rev: Int, position: Int, kind: String = "reply",
                      author: String = "origin", text: String = "hi") -> String {
        #"{"entry_id":"\#(id)","item_id":"\#(item)","rev":\#(rev),"position":\#(position),"kind":"\#(kind)","author":"\#(author)","at_ms":10,"request_revision":1,"text":"\#(text)","files":[]}"#
    }

    static func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }
}

final class ServerModelV2Tests: XCTestCase {
    func testAnItemDecodesIgnoringUnknownMembersAndKeepsTheMessageExactly() throws {
        let message = #"{"title":"Deploy","message_type":"fyi","progress":{"percent":40,"stage":""},"score":0.930}"#
        let item = try APIItem(json: V2Fixture.json(V2Fixture.item("i1", rev: 3, rankKey: "a", message: message)))
        XCTAssertEqual(item.message.jsonString, message, "Message content passes through unchanged.")
        XCTAssertEqual(item.rank.score?.lexeme, "0.930")
        XCTAssertEqual(item.rank.section, "priority")
        XCTAssertEqual(item.availability?.state, "not_listening")
    }

    func testABlankProgressStageItemIsKeptNotDropped() throws {
        let store = try ServerModelV2Store(fileURL: nil)
        for (id, progress) in [("blank", #"{"percent":40,"stage":""}"#), ("absent", #"{"percent":40}"#)] {
            let message = #"{"title":"Deploy","message_type":"fyi","progress":\#(progress)}"#
            try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item(id, rev: 2, rankKey: id, message: message)))
        }
        XCTAssertEqual(Set(store.snapshot.items.keys.map(\.rawValue)), ["blank", "absent"])
    }

    func testTheInboxIsInRankKeyOrderByteWiseWithSectionsKept() throws {
        let store = try ServerModelV2Store(fileURL: nil)
        for (id, key, section) in [("c", "b0", "history"), ("a", "a1", "priority"), ("b", "B9", "priority")] {
            try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item(id, rev: 2, rankKey: key, section: section)))
        }
        let ordered = store.snapshot.orderedItems
        XCTAssertEqual(ordered.map(\.itemID.rawValue), ["b", "a", "c"], "Byte-wise: uppercase sorts first.")
        XCTAssertEqual(ordered.map(\.rank.section), ["priority", "priority", "history"])
    }

    func testEntriesSortByPositionAndOnlyANewerRevChangesOne() throws {
        let store = try ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a")))
        try store.apply(kind: "entry", rev: 4, data: V2Fixture.json(V2Fixture.entry("e2", item: "i", rev: 4, position: 2)))
        try store.apply(kind: "entry", rev: 3, data: V2Fixture.json(V2Fixture.entry("e1", item: "i", rev: 3, position: 1)))
        XCTAssertEqual(store.snapshot.orderedEntries(of: ExactText("i")).map(\.entryID.rawValue), ["e1", "e2"])
        try store.apply(kind: "entry", rev: 5, data: V2Fixture.json(V2Fixture.entry("e1", item: "i", rev: 5, position: 1, text: "edited")))
        try store.apply(kind: "entry", rev: 4, data: V2Fixture.json(V2Fixture.entry("e1", item: "i", rev: 4, position: 1, text: "stale")))
        let e1 = try XCTUnwrap(store.snapshot.orderedEntries(of: ExactText("i")).first)
        XCTAssertEqual(e1.text?.rawValue, "edited", "An older rev is a no-op.")
        XCTAssertEqual(e1.position, 1, "An upsert never moves an entry.")
    }

    func testARemovedItemIsATombstoneAnOlderSnapshotCannotUndo() throws {
        let store = try ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a")))
        try store.apply(kind: "entry", rev: 3, data: V2Fixture.json(V2Fixture.entry("e", item: "i", rev: 3, position: 1)))
        try store.apply(kind: "item_removed", rev: 6, data: V2Fixture.json(#"{"item_id":"i"}"#))
        let older = try APIInboxPage(json: V2Fixture.json(#"{"rev":4,"items":[\#(V2Fixture.item("i", rev: 2, rankKey: "a"))],"counts":{"unresolved":1}}"#))
        try store.apply(older)
        XCTAssertNil(store.snapshot.items[ExactText("i")])
        XCTAssertTrue(store.snapshot.orderedEntries(of: ExactText("i")).isEmpty)
    }

    func testUnreadRepliesUseTheServerCountThenEntryPositions() throws {
        let counted = try APIItem(json: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a",
            chat: #"{"available":true,"started":true,"read_position":"e1","last_origin_reply":"e2","unread_replies":0}"#)))
        XCTAssertFalse(ServerModelV2().hasUnreadReplies(counted), "The server's count decides.")

        let store = try ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a",
            chat: #"{"available":true,"started":true,"read_position":"e1","last_origin_reply":"e2"}"#)))
        try store.apply(kind: "entry", rev: 3, data: V2Fixture.json(V2Fixture.entry("e1", item: "i", rev: 3, position: 1)))
        try store.apply(kind: "entry", rev: 4, data: V2Fixture.json(V2Fixture.entry("e2", item: "i", rev: 4, position: 2)))
        let item = try XCTUnwrap(store.snapshot.items[ExactText("i")])
        XCTAssertTrue(store.snapshot.hasUnreadReplies(item))
    }

    func testAnAnswerGivenOnAnotherDeviceIsHeldOnTheItem() throws {
        let terminal = #"{"state":"answered","at_ms":9,"by_this_person":true,"answer":{"choice":"yes","value":true}}"#
        let item = try APIItem(json: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a", terminal: terminal)))
        XCTAssertEqual(item.terminal?.state, "answered")
        XCTAssertEqual(item.terminal?.answer?.choice?.rawValue, "yes")
        XCTAssertEqual(item.terminal?.answer?.value, .bool(true))
    }

    func testTheModelIsDurableAndAFailedSaveChangesNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("model.json")
        let store = try ServerModelV2Store(fileURL: url)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a")))
        XCTAssertEqual(try ServerModelV2Store(fileURL: url).snapshot, store.snapshot, "A relaunch reads what was saved.")

        // A directory appearing where the file must go makes the save fail.
        let blocked = directory.appendingPathComponent("blocked")
        let failing = try ServerModelV2Store(fileURL: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertThrowsError(try failing.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a"))))
        XCTAssertTrue(failing.snapshot.items.isEmpty, "Nothing is applied unless it was saved.")
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Serves `GET /v2/inbox` pages and records writes; enough for rebaseline.
private final class InboxPagesTransport: ClientAPITransport, @unchecked Sendable {
    var pages: [String?: String] = [:]
    func send(_ request: APIRequest) async throws -> APIResponse {
        guard request.path == "/v2/inbox", let body = pages[request.query["page"]] else {
            throw APIError(status: 404, token: .notFound, retryable: false, requestID: "r")
        }
        return APIResponse(status: 200, requestID: "r", body: Data(body.utf8))
    }
    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> { AsyncThrowingStream { $0.finish() } }
    func changeBatch(after: Rev) async throws -> FeedBatch { FeedBatch(changes: [], rev: after, more: false) }
}

final class ServerModelAdapterTests: XCTestCase {
    func testRebaselineReadsEveryPageKeepsTheFirstPositionAndDropsWhatIsGone() async throws {
        let store = try ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("gone", rev: 2, rankKey: "z")))
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("a", rev: 2, rankKey: "a")))
        try store.apply(kind: "entry", rev: 3, data: V2Fixture.json(V2Fixture.entry("e", item: "a", rev: 3, position: 1)))
        let transport = InboxPagesTransport()
        transport.pages[nil] = #"{"rev":40,"items":[\#(V2Fixture.item("a", rev: 2, rankKey: "a"))],"counts":{"unresolved":2},"next_page":"p2"}"#
        transport.pages["p2"] = #"{"rev":41,"items":[\#(V2Fixture.item("b", rev: 39, rankKey: "b"))],"counts":{"unresolved":2}}"#
        let writer = ServerModelSyncWriter(store: store, transport: transport)

        let position = try await writer.rebaseline()

        XCTAssertEqual(position, 40, "The cursor is the first page's position.")
        XCTAssertEqual(Set(store.snapshot.items.keys.map(\.rawValue)), ["a", "b"], "Items no page lists are dropped.")
        XCTAssertTrue(store.snapshot.entries.isEmpty, "Cached entries are dropped and fetched on open.")
        XCTAssertEqual(store.snapshot.counts?.unresolved, 2)
    }

    func testSyncAppliesRealResourcesFromTheFeedIntoTheModel() async throws {
        let server = FakeClientAPIServer()
        let store = try ServerModelV2Store(fileURL: nil)
        let cursor = MemoryRevCursor(0)
        let sync = ChangeFeedSync(transport: server, cursor: cursor,
                                  model: ServerModelSyncWriter(store: store, transport: server),
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: { _ in await Task.yield() })
        let run = Task { await sync.runForeground() }
        server.commit("item", V2Fixture.item("i", rev: 1, rankKey: "a"))
        server.commit("entry", V2Fixture.entry("e", item: "i", rev: 2, position: 1))
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, (try? cursor.load()) != 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(try cursor.load(), 2)
        XCTAssertEqual(store.snapshot.orderedEntries(of: ExactText("i")).map(\.entryID.rawValue), ["e"])
        run.cancel()
    }

    func testAWriteResponseIsAppliedAtOnce() async throws {
        let store = try ServerModelV2Store(fileURL: nil)
        let outcomes = ServerModelOutboxOutcomes(store: store, onRejected: { _, _ in })
        let entry = OutboxEntry(idempotencyKey: UUID(), target: "i", operation: "mark_seen",
                                write: FrozenWrite(method: .post, path: "/v2/items/i/seen", body: Data("{}".utf8)),
                                createdAt: Date(), outcomeUnknown: false, attempts: 1)
        let seen = V2Fixture.item("i", rev: 7, rankKey: "a").replacingOccurrences(of: #""seen":false"#, with: #""seen":true"#)
        await outcomes.accepted(entry, response: APIResponse(status: 200, requestID: "r",
                                                             body: Data(#"{"rev":7,"item":\#(seen)}"#.utf8)))
        XCTAssertEqual(store.snapshot.items[ExactText("i")]?.seen, true)
    }
}
