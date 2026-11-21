import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

private func waitUntil(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                       _ condition: @escaping () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out: \(message)", file: file, line: line)
}

/// Serves `GET /v2/items/{item_id}/entries` pages by their `before` cursor.
private final class EntriesPagesTransport: ClientAPITransport, @unchecked Sendable {
    private let lock = NSLock()
    var pages: [String?: String] = [:]
    private(set) var requested: [APIRequest] = []
    func send(_ request: APIRequest) async throws -> APIResponse {
        lock.withLock { requested.append(request) }
        guard request.path == "/v2/items/a/entries", let body = pages[request.query["before"]] else {
            throw APIError(status: 404, token: .notFound, retryable: false, requestID: "r")
        }
        return APIResponse(status: 200, requestID: "r", body: Data(body.utf8))
    }
    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> { AsyncThrowingStream { $0.finish() } }
    func changeBatch(after: Rev) async throws -> FeedBatch { FeedBatch(changes: [], rev: after, more: false) }
}

private struct DelayedResourceResponses: ClientAPITransport {
    let entriesStarted: AsyncGate
    let writeStarted: AsyncGate
    let release: AsyncGate
    let entries: String
    let write: String

    func send(_ request: APIRequest) async throws -> APIResponse {
        let body: String
        switch request.path {
        case "/v2/items/a/entries":
            entriesStarted.release()
            body = entries
        case "/v2/items/a/seen":
            writeStarted.release()
            body = write
        default:
            throw APIError(status: 404, token: .notFound, retryable: false, requestID: "r")
        }
        await release.wait()
        return APIResponse(status: 200, requestID: "r", body: Data(body.utf8))
    }

    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> { AsyncThrowingStream { $0.finish() } }
    func changeBatch(after: Rev) async throws -> FeedBatch { FeedBatch(changes: [], rev: after, more: false) }
}

/// Review L-16: an opened item's entries are read page by page, and an entry
/// that cannot be read is reported with its id rather than dropped silently.
final class ServerModelV2EntriesLoadTests: XCTestCase {
    private func entry(_ id: String, _ position: Int) -> String {
        V2Fixture.entry(id, item: "a", rev: position, position: position)
    }

    private func setUp(_ pages: [String?: String]) throws -> (ServerModelV2Store, EntriesPagesTransport,
                                                               RecordingErrorLogV2, ServerModelSyncWriter) {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 1, data: V2Fixture.json(V2Fixture.item("a", rev: 1, rankKey: "a")))
        let transport = EntriesPagesTransport()
        transport.pages = pages
        let errors = RecordingErrorLogV2()
        return (store, transport, errors, ServerModelSyncWriter(store: store, transport: transport, errors: errors))
    }

    func testResetDiscardsDelayedEntriesAndAcceptedWriteResources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("model.json")
        let store = ServerModelV2Store(fileURL: file)
        let before = try APIItem(json: V2Fixture.json(V2Fixture.item("a", rev: 10, rankKey: "a")))
        try store.rebaseline(items: [before], counts: APICounts(unresolved: 1), position: 10)
        let old = V2Fixture.item("a", rev: 11, rankKey: "a")
            .replacingOccurrences(of: #""seen":false"#, with: #""seen":true"#)
        let transport = DelayedResourceResponses(entriesStarted: AsyncGate(), writeStarted: AsyncGate(),
            release: AsyncGate(), entries: #"{"rev":11,"entries":[\#(entry("old", 11))],"older":false}"#,
            write: #"{"rev":11,"item":\#(old)}"#)
        let errors = RecordingErrorLogV2()
        let writer = ServerModelSyncWriter(store: store, transport: transport, errors: errors)
        let outcomes = ServerModelOutboxOutcomes(store: store, onRejected: { _, _ in
            XCTFail("The completed operation was accepted.")
        }, onUnreadableResponse: { _, _ in
            XCTFail("An obsolete response is not a failed projection.")
        })
        let outbox = try ActionOutbox(persistence: MemoryOutboxPersistence(), transport: transport,
                                      outcomes: outcomes, errors: errors)
        let reading = Task { try await writer.loadEntries(of: ExactText("a")) }
        defer { transport.release.release() }
        try await outbox.submit(target: "a", operation: "mark_seen",
                                write: FrozenWrite(method: .post, path: "/v2/items/a/seen", body: Data("{}".utf8)))
        await transport.entriesStarted.wait()
        await transport.writeStarted.wait()

        let after = try APIItem(json: V2Fixture.json(V2Fixture.item("a", rev: 1, rankKey: "a")))
        try store.rebaseline(items: [after], counts: APICounts(unresolved: 1), position: 1)
        transport.release.release()
        do {
            try await reading.value
            XCTFail("The delayed entry page belongs to the previous generation.")
        } catch is ServerModelV2Store.SupersededGeneration {}
        await waitUntil("the accepted write leaves the queue") { await outbox.pending.isEmpty }

        let saved = ServerModelV2Store(fileURL: file)
        XCTAssertEqual(saved.heldCursor, 1)
        XCTAssertEqual(saved.snapshot.items[ExactText("a")]?.rev, 1)
        XCTAssertEqual(saved.snapshot.items[ExactText("a")]?.seen, false)
        XCTAssertTrue(saved.snapshot.orderedEntries(of: ExactText("a")).isEmpty)
        XCTAssertFalse(saved.snapshot.loadedEntryItems.contains(ExactText("a")))
    }

    func testEveryPageIsReadNewestFirstAndTheItemIsThenLoaded() async throws {
        let (store, transport, errors, writer) = try setUp([
            nil: #"{"rev":10,"entries":[\#(entry("e3", 3)),\#(entry("e4", 4))],"older":true}"#,
            "e3": #"{"rev":10,"entries":[\#(entry("e1", 1)),\#(entry("e2", 2))],"older":false}"#
        ])
        try await writer.loadEntries(of: ExactText("a"))
        XCTAssertEqual(store.snapshot.orderedEntries(of: ExactText("a")).map(\.entryID.rawValue), ["e1", "e2", "e3", "e4"])
        XCTAssertTrue(store.snapshot.loadedEntryItems.contains(ExactText("a")))
        XCTAssertEqual(transport.requested.map { $0.query["before"] }, [nil, "e3"])
        XCTAssertTrue(errors.reports.isEmpty)
    }

    func testAnUnreadableEntryIsReportedWithItsIdAndTheItemIsReadAgainNextTime() async throws {
        let (store, _, errors, writer) = try setUp([
            nil: #"{"rev":12,"entries":[\#(entry("e3", 3)),{"entry_id":"bad","item_id":"a"}],"older":true}"#,
            "e3": #"{"rev":12,"entries":[\#(entry("e1", 1))],"older":false}"#
        ])
        try await writer.loadEntries(of: ExactText("a"))
        XCTAssertEqual(errors.reports.count, 1)
        XCTAssertEqual(errors.reports.first?.operation, "load_entries")
        XCTAssertEqual(errors.reports.first?.phase, "entry")
        XCTAssertEqual(errors.reports.first?.correlation.resourceID, "bad")
        XCTAssertEqual(errors.reports.first?.correlation.rev, 12)
        XCTAssertEqual(store.snapshot.orderedEntries(of: ExactText("a")).map(\.entryID.rawValue), ["e1", "e3"],
                       "Readable entries are kept.")
        XCTAssertFalse(store.snapshot.loadedEntryItems.contains(ExactText("a")),
                       "A later clean page does not mark the item loaded.")
    }

    func testAPageWithNothingReadableStopsWithoutMarkingTheItemLoaded() async throws {
        let (store, transport, errors, writer) = try setUp([
            nil: #"{"rev":5,"entries":[{"entry_id":"bad","item_id":"a"}],"older":true}"#
        ])
        try await writer.loadEntries(of: ExactText("a"))
        XCTAssertEqual(transport.requested.count, 1)
        XCTAssertEqual(errors.reports.count, 1)
        XCTAssertFalse(store.snapshot.loadedEntryItems.contains(ExactText("a")))
    }

    func testARepeatedCursorIsRefusedInsteadOfLoopingForever() async throws {
        let (_, _, _, writer) = try setUp([
            nil: #"{"rev":5,"entries":[\#(entry("e3", 3))],"older":true}"#,
            "e3": #"{"rev":5,"entries":[\#(entry("e3", 3))],"older":true}"#
        ])
        do { try await writer.loadEntries(of: ExactText("a")); XCTFail("A repeated cursor must stop.") } catch {}
    }
}

/// Review L-18: arrival numbers are kept only for held items, and still never reused.
final class ServerModelV2ArrivalPruneTests: XCTestCase {
    func testARemovedItemsNumberIsDroppedAndANewOneIsNeverAReusedNumber() throws {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 1, data: V2Fixture.json(V2Fixture.item("a", rev: 1, rankKey: "a")))
        try store.apply(kind: "item", rev: 2, data: V2Fixture.json(V2Fixture.item("b", rev: 2, rankKey: "b")))
        try store.apply(kind: "item_removed", rev: 3, data: V2Fixture.json(#"{"item_id":"a"}"#))
        XCTAssertNil(store.snapshot.arrivalOrder[ExactText("a")])
        try store.apply(kind: "item", rev: 4, data: V2Fixture.json(V2Fixture.item("c", rev: 4, rankKey: "c")))
        XCTAssertEqual(store.snapshot.arrivalOrder[ExactText("c")], 3)

        try store.rebaseline(items: [APIItem(json: V2Fixture.json(V2Fixture.item("c", rev: 4, rankKey: "c")))],
                             counts: APICounts(unresolved: 1), position: 5)
        XCTAssertEqual(store.snapshot.arrivalOrder, [ExactText("c"): 3], "A rebaseline keeps only held items' numbers.")
        try store.apply(kind: "item", rev: 6, data: V2Fixture.json(V2Fixture.item("b", rev: 6, rankKey: "b")))
        XCTAssertEqual(store.snapshot.arrivalOrder[ExactText("b")], 4, "A returning item gets a fresh number.")
    }
}

/// Review L-17: a refused write stays visible in the Error Log, tied to its
/// item, until the app discards it.
final class OutboxFailedWriteVisibilityTests: XCTestCase {
    private func write(_ item: String) -> FrozenWrite {
        FrozenWrite(method: .post, path: "/v2/items/\(item)/answer", body: Data("{}".utf8))
    }

    func testARefusalStaysUnresolvedUntilItsFailedWriteIsDiscarded() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [APIError(status: 409, token: .staleRequest, retryable: false, requestID: "req-x")]
        let persistence = MemoryOutboxPersistence()
        server.persistedKeys = { persistence.keys }
        let outcomes = RecordingOutcomes()
        let errors = RecordingErrorLogV2()
        let box = try ActionOutbox(persistence: persistence, transport: server, outcomes: outcomes, errors: errors,
                                   waitBeforeRetry: { _, _ in try await Task.sleep(for: .seconds(3600)) })

        let refused = try await box.submit(target: "item:a", operation: "answer", write: write("a"))
        await waitUntil("refused") { outcomes.rejected.count == 1 }
        XCTAssertEqual(errors.reports.first?.correlation.resourceID, "a", "The refusal names its item.")
        XCTAssertEqual(errors.reports.first?.correlation.clientOperationID, refused.idempotencyKey)

        try await box.submit(target: "item:b", operation: "answer", write: write("b"))
        await waitUntil("accepted") { outcomes.accepted.count == 1 }
        // Accepted, then removed from the outbox and (if allowed) resolved, in
        // one step: once it has left, any resolution has happened.
        await waitUntil("removed") { await box.pending.isEmpty }
        XCTAssertTrue(errors.resolutions.isEmpty,
                      "Another answer succeeding does not resolve a refusal whose write is still held.")

        await box.discardFailed(refused.idempotencyKey)
        XCTAssertEqual(errors.resolutions, ["actions.answer"])
    }
}
