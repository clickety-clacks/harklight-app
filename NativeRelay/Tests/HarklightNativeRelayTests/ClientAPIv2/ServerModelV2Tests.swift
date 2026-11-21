import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

/// Fixtures in the accepted contract's shapes (docs/client-api-v2.md edff7e9
/// with contract rulings round 2).
enum V2Fixture {
    static func item(_ id: String, rev: Int, rankKey: String, section: String = "current",
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

extension ServerModelV2Store {
    /// Applies one feed change as Sync would, moving the cursor with it.
    func apply(kind: String, rev: UInt64, data: JSONValue) throws {
        try apply([Change(rev: rev, kind: kind, data: Data(data.jsonString.utf8))], cursor: rev)
    }

    /// The person opened the item: its entries were read, so feed entries are kept.
    func open(_ itemID: String) throws {
        try apply(APIEntriesPage(json: JSONValue.parse(Data(#"{"rev":0,"entries":[],"older":false}"#.utf8))),
                  of: ExactText(itemID))
    }
}

final class ServerModelV2Tests: XCTestCase {
    func testAnItemDecodesIgnoringUnknownMembersAndKeepsTheMessageExactly() throws {
        let message = #"{"title":"Deploy","message_type":"fyi","progress":{"percent":40,"stage":""},"score":0.930}"#
        let item = try APIItem(json: V2Fixture.json(V2Fixture.item("i1", rev: 3, rankKey: "a", message: message)))
        XCTAssertEqual(item.message.jsonString, message, "Message content passes through unchanged.")
        XCTAssertEqual(item.rank.score?.lexeme, "0.930")
        XCTAssertEqual(item.rank.section, "current")
        XCTAssertEqual(item.availability?.state, "not_listening")
    }

    func testABlankProgressStageItemIsKeptNotDropped() throws {
        let store = ServerModelV2Store(fileURL: nil)
        for (id, progress) in [("blank", #"{"percent":40,"stage":""}"#), ("absent", #"{"percent":40}"#)] {
            let message = #"{"title":"Deploy","message_type":"fyi","progress":\#(progress)}"#
            try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item(id, rev: 2, rankKey: id, message: message)))
        }
        XCTAssertEqual(Set(store.snapshot.items.keys.map(\.rawValue)), ["blank", "absent"])
    }

    func testTheInboxIsInRankKeyOrderByteWiseWithSectionsKept() throws {
        let store = ServerModelV2Store(fileURL: nil)
        for (id, key, section) in [("c", "b0", "resolved"), ("a", "a1", "current"), ("b", "B9", "current")] {
            try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item(id, rev: 2, rankKey: key, section: section)))
        }
        let ordered = store.snapshot.orderedItems
        XCTAssertEqual(ordered.map(\.itemID.rawValue), ["b", "a", "c"], "Byte-wise: uppercase sorts first.")
        XCTAssertEqual(ordered.map(\.rank.section), ["current", "current", "resolved"])
    }

    func testEntriesSortByPositionAndOnlyANewerRevChangesOne() throws {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a")))
        try store.open("i")
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
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a")))
        try store.open("i")
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

        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a",
            chat: #"{"available":true,"started":true,"read_position":"e1","last_origin_reply":"e2"}"#)))
        try store.open("i")
        try store.apply(kind: "entry", rev: 3, data: V2Fixture.json(V2Fixture.entry("e1", item: "i", rev: 3, position: 1)))
        try store.apply(kind: "entry", rev: 4, data: V2Fixture.json(V2Fixture.entry("e2", item: "i", rev: 4, position: 2)))
        let item = try XCTUnwrap(store.snapshot.items[ExactText("i")])
        XCTAssertTrue(store.snapshot.hasUnreadReplies(item))
    }

    func testAnAnswerGivenOnAnotherDeviceIsHeldOnTheItem() throws {
        let terminal = #"{"state":"answered","at_ms":9,"by_this_person":true,"answer":{"kind":"default","text":"Yes","value":true}}"#
        let item = try APIItem(json: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a", terminal: terminal,
                                                                    extra: #""created_at_ms":1793300000000"#)))
        XCTAssertEqual(item.terminal?.state, "answered")
        XCTAssertEqual(item.terminal?.answer?.kind, "default")
        XCTAssertEqual(item.terminal?.answer?.text?.rawValue, "Yes")
        XCTAssertEqual(item.terminal?.answer?.value, .bool(true))
        XCTAssertEqual(item.createdAtMs, 1_793_300_000_000)
        let noComment = try APIItem(json: V2Fixture.json(V2Fixture.item("n", rev: 2, rankKey: "a",
            terminal: #"{"state":"answered","at_ms":9,"by_this_person":false,"answer":{"kind":"no_comment"}}"#)))
        XCTAssertTrue(noComment.terminal?.isNoComment == true)
    }

    func testAnEntryFromBeforeTheCutOverHasNoTimeAndStillOrders() throws {
        let old = #"{"entry_id":"e","item_id":"i","rev":1,"position":1,"kind":"reply","author":"origin","request_revision":1,"files":[],"delivery":{"delivered":true}}"#
        let entry = try APIEntry(json: V2Fixture.json(old))
        XCTAssertNil(entry.atMs)
        XCTAssertEqual(entry.delivery?.delivered, true, "Receipts arrive as delivery, not as entries.")
    }

    func testAnEarlierRevisionAndMeDecode() throws {
        let revision = try APIRevision(json: V2Fixture.json(#"{"rev":12,"revision":{"request_revision":1,"message":{"title":"First","n":1.50},"files":[]}}"#))
        XCTAssertEqual(revision.requestRevision, 1)
        XCTAssertEqual(revision.message.jsonString, #"{"title":"First","n":1.50}"#)
        let me = try APIMe(json: V2Fixture.json(#"{"account":{"state":"paused"},"features":{"progress_inbox":true,"x":"no"},"limits":{}}"#))
        XCTAssertEqual(me.accountState, "paused")
        XCTAssertEqual(me.features, ["progress_inbox": true], "Only boolean features are read.")
    }

    func testTheModelIsDurableAndAFailedSaveChangesNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("model.json")
        let store = ServerModelV2Store(fileURL: url)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a")))
        XCTAssertEqual(ServerModelV2Store(fileURL: url).snapshot, store.snapshot, "A relaunch reads what was saved.")
        XCTAssertEqual(ServerModelV2Store(fileURL: url).heldCursor, 2, "The cursor is saved with the model.")

        // A directory appearing where the file must go makes the save fail.
        let blocked = directory.appendingPathComponent("blocked")
        let failing = ServerModelV2Store(fileURL: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertThrowsError(try failing.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a"))))
        XCTAssertTrue(failing.snapshot.items.isEmpty, "Nothing is applied unless it was saved.")
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Serves `GET /v2/inbox` pages and records writes; enough for rebaseline.
private final class InboxPagesTransport: ClientAPITransport, @unchecked Sendable {
    var pages: [String?: String] = [:]
    var beforeReturningPage: @Sendable () async -> Void = {}
    var maximumBatchPosition: Rev?
    func send(_ request: APIRequest) async throws -> APIResponse {
        guard request.path == "/v2/inbox", let body = pages[request.query["page"]] else {
            throw APIError(status: 404, token: .notFound, retryable: false, requestID: "r")
        }
        await beforeReturningPage()
        return APIResponse(status: 200, requestID: "r", body: Data(body.utf8))
    }
    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> { AsyncThrowingStream { $0.finish() } }
    func changeBatch(after: Rev) async throws -> FeedBatch {
        if let maximumBatchPosition, after > maximumBatchPosition {
            throw APIError(status: 410, token: .cursorExpired, retryable: false, requestID: "r")
        }
        return FeedBatch(changes: [], rev: after, more: false)
    }
}

final class ServerModelAdapterTests: XCTestCase {
    func testADelayedSnapshotCannotReplaceDurableLiveProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("model.json")
        let store = ServerModelV2Store(fileURL: url)
        let transport = InboxPagesTransport()
        let requested = AsyncGate()
        let blocked = AsyncGate()
        transport.pages[nil] = #"{"rev":1,"items":[],"counts":{"unresolved":0}}"#
        transport.beforeReturningPage = {
            requested.release()
            await blocked.wait()
        }
        let writer = ServerModelSyncWriter(store: store, transport: transport, errors: RecordingErrorLogV2())
        let rebaseline = Task { try await writer.rebaseline() }
        defer { blocked.release() }
        await requested.wait()

        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("live", rev: 2, rankKey: "a")))
        blocked.release()
        do {
            _ = try await rebaseline.value
            XCTFail("A fenced snapshot was not installed.")
        } catch let error as SyncSnapshotSuperseded {
            XCTAssertEqual(error.position, 2)
        }
        let reopened = ServerModelV2Store(fileURL: url)
        XCTAssertEqual(reopened.heldCursor, 2)
        XCTAssertNotNil(reopened.snapshot.items[ExactText("live")])

        let reset = try await writer.rebaseline()
        XCTAssertEqual(reset, 1, "A fresh rebaseline can still follow a server reset.")
        XCTAssertEqual(ServerModelV2Store(fileURL: url).heldCursor, 1)
    }

    func testContestedCursorExpiredRecoveryStillInstallsTheReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("model.json")
        let store = ServerModelV2Store(fileURL: url)
        try store.rebaseline(items: [], counts: APICounts(unresolved: 0), position: 10)
        let transport = InboxPagesTransport()
        let requested = AsyncGate()
        let blocked = AsyncGate()
        transport.maximumBatchPosition = 1
        let reset = V2Fixture.item("reset", rev: 1, rankKey: "a")
        transport.pages[nil] = #"{"rev":1,"items":[\#(reset)],"counts":{"unresolved":1}}"#
        transport.beforeReturningPage = {
            requested.release()
            await blocked.wait()
        }
        let errors = RecordingErrorLogV2()
        let writer = ServerModelSyncWriter(store: store, transport: transport, errors: errors)
        let sync = ChangeFeedSync(transport: transport, model: writer, errors: errors)
        let catchUp = Task { try await sync.catchUp() }
        defer { blocked.release() }
        await requested.wait()

        // An already-buffered change from the old feed advances the disk
        // cursor while the first reset snapshot is still loading.
        try store.apply(kind: "item", rev: 11,
                        data: V2Fixture.json(V2Fixture.item("old", rev: 11, rankKey: "b")))
        blocked.release()
        try await catchUp.value

        let reopened = ServerModelV2Store(fileURL: url)
        XCTAssertEqual(reopened.heldCursor, 1)
        XCTAssertEqual(Set(reopened.snapshot.items.keys.map(\.rawValue)), ["reset"])
    }

    func testRebaselineReadsEveryPageKeepsTheFirstPositionAndDropsWhatIsGone() async throws {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("gone", rev: 2, rankKey: "z")))
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("a", rev: 2, rankKey: "a")))
        try store.open("a")
        try store.apply(kind: "entry", rev: 3, data: V2Fixture.json(V2Fixture.entry("e", item: "a", rev: 3, position: 1)))
        let transport = InboxPagesTransport()
        transport.pages[nil] = #"{"rev":40,"items":[\#(V2Fixture.item("a", rev: 2, rankKey: "a"))],"counts":{"unresolved":2},"next_page":"p2"}"#
        transport.pages["p2"] = #"{"rev":41,"items":[\#(V2Fixture.item("b", rev: 39, rankKey: "b"))],"counts":{"unresolved":2}}"#
        let writer = ServerModelSyncWriter(store: store, transport: transport, errors: RecordingErrorLogV2())

        let position = try await writer.rebaseline()

        XCTAssertEqual(position, 40, "The cursor is the first page's position.")
        XCTAssertEqual(store.heldCursor, 40)
        XCTAssertEqual(Set(store.snapshot.items.keys.map(\.rawValue)), ["a", "b"], "Items no page lists are dropped.")
        XCTAssertTrue(store.snapshot.entries.isEmpty, "Cached entries are dropped and fetched on open.")
        XCTAssertEqual(store.snapshot.counts?.unresolved, 2)
    }

    func testSyncAppliesRealResourcesFromTheFeedIntoTheModel() async throws {
        let server = FakeClientAPIServer()
        let store = ServerModelV2Store(fileURL: nil)
        try store.rebaseline(items: [], counts: APICounts(unresolved: 0), position: 0)
        try store.open("i")
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server,
                                  model: ServerModelSyncWriter(store: store, transport: server, errors: errors),
                                  errors: errors, waitBeforeRetry: { _ in await Task.yield() })
        let run = Task { await sync.runForeground() }
        server.commit("item", V2Fixture.item("i", rev: 1, rankKey: "a"))
        server.commit("entry", V2Fixture.entry("e", item: "i", rev: 2, position: 1))
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, store.heldCursor != 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.heldCursor, 2)
        XCTAssertEqual(store.snapshot.orderedEntries(of: ExactText("i")).map(\.entryID.rawValue), ["e"])
        run.cancel()
    }

    func testAWriteResponseIsAppliedAtOnce() async throws {
        let store = ServerModelV2Store(fileURL: nil)
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

final class ServerModelV2RobustnessTests: XCTestCase {
    private func syncOverStore(_ server: FakeClientAPIServer, _ store: ServerModelV2Store,
                               _ errors: RecordingErrorLogV2) -> ChangeFeedSync {
        ChangeFeedSync(transport: server,
                       model: ServerModelSyncWriter(store: store, transport: server, errors: errors),
                       errors: errors, waitBeforeRetry: { _ in await Task.yield() })
    }

    func testAnUnreadableKnownChangeRebaselinesOnceThenIsSkippedIfItRecurs() async throws {
        let server = FakeClientAPIServer()
        let store = ServerModelV2Store(fileURL: nil)
        try store.rebaseline(items: [], counts: APICounts(unresolved: 0), position: 0)
        let errors = RecordingErrorLogV2()
        let sync = syncOverStore(server, store, errors)
        server.commit("item", #"{"item_id":"broken","rev":1}"#)
        server.commit("item", V2Fixture.item("good", rev: 2, rankKey: "a"))
        server.inboxItems = [V2Fixture.item("good", rev: 2, rankKey: "a")]
        try await sync.catchUp()
        XCTAssertEqual(store.heldCursor, 2, "The full snapshot replaced the batch with the unreadable change.")
        XCTAssertEqual(store.snapshot.items.keys.map(\.rawValue), ["good"], "Nothing the snapshot holds is lost.")
        XCTAssertEqual(errors.reports.map(\.reason), [.app("decode_failed_rebaselining")])

        server.commit("item", #"{"item_id":"broken-again","rev":3}"#)
        try await sync.catchUp()
        XCTAssertEqual(store.heldCursor, 3, "A recurrence is skipped, so Sync never wedges.")
        XCTAssertEqual(errors.reports.last?.reason, .app("decode_failed"))
        XCTAssertEqual(errors.reports.last?.retryable, false, "Kept in the Error Log as an unresolved failure.")
    }

    func testAnUnknownFutureKindIsReportedAndSkipped() async throws {
        let server = FakeClientAPIServer()
        let store = ServerModelV2Store(fileURL: nil)
        try store.rebaseline(items: [], counts: APICounts(unresolved: 0), position: 0)
        let errors = RecordingErrorLogV2()
        server.commit("sticker", #"{"anything":1}"#)
        try await syncOverStore(server, store, errors).catchUp()
        XCTAssertEqual(store.heldCursor, 1)
        XCTAssertEqual(errors.reports.map(\.reason), [.app("unknown_kind")])
    }

    func testARebaselineStopsOnARepeatedPageCursor() async throws {
        let store = ServerModelV2Store(fileURL: nil)
        let transport = InboxPagesTransport()
        transport.pages[nil] = #"{"rev":4,"items":[],"counts":{"unresolved":0},"next_page":"p"}"#
        transport.pages["p"] = #"{"rev":4,"items":[],"counts":{"unresolved":0},"next_page":"p"}"#
        do {
            _ = try await ServerModelSyncWriter(store: store, transport: transport, errors: RecordingErrorLogV2()).rebaseline()
            XCTFail("A repeating page cursor ends the rebaseline.")
        } catch {}
    }

    func testRoundFiveAndSixSectionAndReplyRowFieldsDecode() throws {
        let item = try APIItem(json: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a",
            chat: #"{"available":true,"started":true,"unread_replies":2,"reply_group":"earlier_chat_replies","reply_rank_key":"a5"}"#)
            .replacingOccurrences(of: #""section":"current"}"#, with: #""section":"current","group":"earlier_messages"}"#)))
        XCTAssertEqual(item.rank.group, "earlier_messages")
        XCTAssertEqual(item.chat.replyGroup, "earlier_chat_replies")
        XCTAssertEqual(item.chat.replyRankKey?.rawValue, "a5")
    }

    func testABatchIsOneSaveWithItsCursor() throws {
        let store = ServerModelV2Store(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("model.json"))
        let changes = (1...50).map { n in
            ServerModelV2Store.Change(rev: UInt64(n), kind: "item",
                                      data: Data(V2Fixture.item("i\(n)", rev: n, rankKey: "k\(n)").utf8))
        }
        try store.apply(changes, cursor: 50)
        XCTAssertEqual(store.saveCount, 1, "One durable write per batch, not per change.")
        XCTAssertEqual(store.heldCursor, 50)
    }

    func testAModelOfAnotherVersionIsDiscardedWithItsCursor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("model.json")
        let store = ServerModelV2Store(fileURL: url)
        try store.apply(kind: "item", rev: 3, data: V2Fixture.json(V2Fixture.item("i", rev: 3, rankKey: "a")))
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        stored["version"] = ServerModelV2Store.formatVersion + 1
        try JSONSerialization.data(withJSONObject: stored).write(to: url)
        let reopened = ServerModelV2Store(fileURL: url)
        XCTAssertNil(reopened.heldCursor, "No cursor without its model, so Sync takes a fresh snapshot.")
        XCTAssertTrue(reopened.snapshot.items.isEmpty)
    }

    func testFeedEntriesAreKeptOnlyForItemsWhoseEntriesWereRead() throws {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a")))
        try store.apply(kind: "entry", rev: 3, data: V2Fixture.json(V2Fixture.entry("e1", item: "i", rev: 3, position: 1)))
        XCTAssertTrue(store.snapshot.orderedEntries(of: ExactText("i")).isEmpty, "Not opened: not kept.")
        try store.open("i")
        try store.apply(kind: "entry", rev: 4, data: V2Fixture.json(V2Fixture.entry("e2", item: "i", rev: 4, position: 2)))
        XCTAssertEqual(store.snapshot.orderedEntries(of: ExactText("i")).map(\.entryID.rawValue), ["e2"])
    }
}

/// Review items N-1 and N-2 of #371: unreadable resources never stop a page or
/// a rebaseline, and a skipped change never leaves something looking complete.
final class ServerModelV2UnreadableResourceTests: XCTestCase {
    func testAnUnreadableItemInAnInboxPageIsSkippedAndTheRebaselineStillCompletes() async throws {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("odd", rev: 2, rankKey: "z")))
        let transport = InboxPagesTransport()
        let broken = #"{"item_id":"odd","rev":9,"sender":7}"#
        transport.pages[nil] = #"{"rev":12,"items":[\#(V2Fixture.item("a", rev: 3, rankKey: "a")),\#(broken)],"counts":{"unresolved":1}}"#
        let errors = RecordingErrorLogV2()

        let position = try await ServerModelSyncWriter(store: store, transport: transport, errors: errors).rebaseline()

        XCTAssertEqual(position, 12, "One bad item does not stop the rebaseline, so Sync can start.")
        XCTAssertEqual(Set(store.snapshot.items.keys.map(\.rawValue)), ["a", "odd"],
                       "The unreadable item keeps its last-known copy rather than vanishing.")
        XCTAssertEqual(errors.reports.map(\.operation), ["rebaseline"])
    }

    func testAnEntriesPageWithAnUnreadableEntryLeavesTheItemToBeReadAgain() throws {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a")))
        let page = try APIEntriesPage(json: V2Fixture.json(#"{"rev":5,"older":false,"entries":[\#(V2Fixture.entry("e1", item: "i", rev: 3, position: 1)),{"entry_id":"e2","item_id":"i","rev":4}]}"#))
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.unreadable.map(\.id), [ExactText("e2")])
        try store.apply(page, of: ExactText("i"))
        XCTAssertEqual(store.snapshot.orderedEntries(of: ExactText("i")).map(\.entryID.rawValue), ["e1"])
        XCTAssertFalse(store.snapshot.loadedEntryItems.contains(ExactText("i")),
                       "Not marked complete, so opening the item reads its entries again.")
    }

    func testASkippedFeedEntryMarksItsItemToBeReadAgain() throws {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("i", rev: 2, rankKey: "a")))
        try store.open("i")
        try store.apply([ServerModelV2Store.Change(rev: 3, kind: "entry", data: Data(#"{"entry_id":"e1","item_id":"i","rev":3}"#.utf8))],
                        cursor: 3)
        XCTAssertFalse(store.snapshot.loadedEntryItems.contains(ExactText("i")),
                       "A gap after a skipped entry is never kept as if complete.")
        try store.apply(kind: "entry", rev: 4, data: V2Fixture.json(V2Fixture.entry("e2", item: "i", rev: 4, position: 2)))
        XCTAssertTrue(store.snapshot.orderedEntries(of: ExactText("i")).isEmpty,
                      "Later feed entries wait for the full read on open.")
    }

}

final class UnreadableRebaselineOnceTests: XCTestCase {
    /// L-13: the one rebaseline an unreadable change earns is spent only
    /// once that rebaseline succeeds.
    func testAFailedRebaselineLeavesTheNextUnreadableChangeToAskAgain() async throws {
        let store = ServerModelV2Store(fileURL: nil)
        let transport = InboxPagesTransport()
        let writer = ServerModelSyncWriter(store: store, transport: transport, errors: RecordingErrorLogV2())
        let broken = FeedChange(rev: 1, kind: .item, data: Data(#"{"item_id":"x","rev":1}"#.utf8))
        do { try await writer.apply([broken], cursor: 1); XCTFail("Asks for a rebaseline.") }
        catch { XCTAssertTrue(error is SyncNeedsRebaseline) }
        do { _ = try await writer.rebaseline(); XCTFail("No inbox is served yet.") } catch {}
        do { try await writer.apply([broken], cursor: 1); XCTFail("Still asks, as the rebaseline failed.") }
        catch { XCTAssertTrue(error is SyncNeedsRebaseline) }
        transport.pages[nil] = #"{"rev":1,"items":[],"counts":{"unresolved":0}}"#
        _ = try await writer.rebaseline()
        try await writer.apply([broken], cursor: 1)
        XCTAssertEqual(store.heldCursor, 1, "After a successful rebaseline a recurrence is skipped.")
    }
}

/// #377 review B-3/B-4 and round 7, at the model level.
final class ServerModelV2ArrivalAndReplyTests: XCTestCase {
    func testArrivalNumbersAreNeverReusedAfterARemoval() throws {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 1, data: V2Fixture.json(V2Fixture.item("a", rev: 1, rankKey: "a")))
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("b", rev: 2, rankKey: "b")))
        try store.apply(kind: "item_removed", rev: 3, data: V2Fixture.json(#"{"item_id":"a"}"#))
        try store.apply(kind: "item", rev: 4, data: V2Fixture.json(V2Fixture.item("c", rev: 4, rankKey: "c")))
        XCTAssertEqual(store.snapshot.arrivalOrder[ExactText("b")], 2)
        XCTAssertEqual(store.snapshot.arrivalOrder[ExactText("c")], 3, "A new message gets a number never used before.")
    }

    func testItemsWithAgentRepliesKeepFeedEntriesWithoutBeingMarkedLoaded() throws {
        let store = ServerModelV2Store(fileURL: nil)
        let chat = #"{"started":true,"last_origin_reply":"r1","unread_replies":1,"reply_group":"earlier_chat_replies","reply_rank_key":"a5"}"#
        try store.apply(kind: "item", rev: 1, data: V2Fixture.json(V2Fixture.item("i", rev: 1, rankKey: "a", chat: chat)))
        XCTAssertEqual(store.snapshot.itemsNeedingEntries, [ExactText("i")], "The reply row needs the reply.")
        try store.apply(kind: "entry", rev: 2, data: V2Fixture.json(V2Fixture.entry("r1", item: "i", rev: 2, position: 4)))
        XCTAssertEqual(store.snapshot.orderedEntries(of: ExactText("i")).map(\.entryID.rawValue), ["r1"])
        XCTAssertFalse(store.snapshot.loadedEntryItems.contains(ExactText("i")),
                       "Not complete: opening the item still reads its whole chat.")
        XCTAssertTrue(store.snapshot.itemsNeedingEntries.isEmpty)
    }

    func testChatWithoutAvailableAndAResultEntryDecode() throws {
        let item = try APIItem(json: V2Fixture.json(V2Fixture.item("i", rev: 1, rankKey: "a", chat: #"{"started":false}"#)))
        XCTAssertNil(item.chat.available, "available is optional in the contract.")
        let entry = try APIEntry(json: V2Fixture.json(#"{"entry_id":"r","item_id":"i","rev":2,"position":3,"kind":"result","author":"origin","request_revision":1,"result":{"status":"done","revision":1}}"#))
        XCTAssertEqual(entry.result?.status.rawValue, "done")
    }
}
