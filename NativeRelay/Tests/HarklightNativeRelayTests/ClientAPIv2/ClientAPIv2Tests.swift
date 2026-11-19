import Foundation
@testable import HarklightNativeRelay
import XCTest

/// Waits for `condition` without a fixed sleep; fails after `timeout`.
private func eventually(_ message: String, timeout: Duration = .seconds(2),
                        file: StaticString = #filePath, line: UInt = #line,
                        _ condition: @escaping () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out: \(message)", file: file, line: line)
}

private let noWait: @Sendable (Int) async throws -> Void = { _ in await Task.yield() }
private let noOutboxWait: @Sendable (Int, TimeInterval?) async throws -> Void = { _, _ in
    try await Task.sleep(for: .seconds(3600))
}

final class ServerSentEventParserTests: XCTestCase {
    private func events(_ lines: [String]) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        return lines.compactMap { parser.feed(line: $0) }
    }

    func testEventsCarryIdKindAndMultiLineDataAndHeartbeatsAreIgnored() {
        let parsed = events([": heartbeat", "", "id: 7", "event: item", "data: {\"a\":", "data: 1}", "",
                             ": heartbeat", "", "id: 8", "event: entry", "data:{}", ""])
        XCTAssertEqual(parsed, [
            ServerSentEvent(id: "7", event: "item", data: "{\"a\":\n1}"),
            ServerSentEvent(id: "8", event: "entry", data: "{}")
        ])
    }

    func testAnEventWithoutDataIsNotDispatchedAndTheLastIdCarriesOver() {
        var parser = ServerSentEventParser()
        XCTAssertNil(parser.feed(line: "id: 3"))
        XCTAssertNil(parser.feed(line: ""), "No data, no event.")
        XCTAssertNil(parser.feed(line: "data: x"))
        XCTAssertEqual(parser.feed(line: ""), ServerSentEvent(id: "3", event: "message", data: "x"))
        XCTAssertEqual(parser.lastEventID, "3", "A reconnect resumes from the last id.")
    }

    func testFeedEventsMapRevKindAndClosingReason() throws {
        XCTAssertEqual(try FeedEvent(ServerSentEvent(id: "12", event: "item", data: "{}")),
                       .change(FeedChange(rev: 12, kind: .item, data: Data("{}".utf8))))
        XCTAssertEqual(try FeedEvent(ServerSentEvent(id: nil, event: "closing", data: #"{"reason":"revoked"}"#)),
                       .closing(reason: "revoked"))
        XCTAssertThrowsError(try FeedEvent(ServerSentEvent(id: "x", event: "item", data: "{}")))
    }

    func testErrorBodiesKeepOnlyTheClosedTokenList() {
        let known = APIError(status: 409, body: Data(#"{"error":"stale_request","retryable":false,"request_id":"r1"}"#.utf8),
                             requestID: nil, retryAfter: nil)
        XCTAssertEqual(known.token, .staleRequest)
        XCTAssertEqual(known.requestID, "r1")
        XCTAssertTrue(known.isPermanent)
        let unknown = APIError(status: 503, body: Data(#"{"error":"something the server made up"}"#.utf8),
                               requestID: "r2", retryAfter: 5)
        XCTAssertEqual(unknown.token, .other, "Free-form server text never becomes a token.")
        XCTAssertTrue(unknown.retryable)
        XCTAssertFalse(unknown.isPermanent)
    }
}

final class ChangeFeedSyncTests: XCTestCase {
    func testFirstRunRebaselinesFromASnapshotThenFollowsTheFeedFromItsRev() async throws {
        let server = FakeClientAPIServer()
        server.commit("item", "{}")
        server.commit("item", "{}")
        let model = RecordingSyncModel(snapshotRev: { server.head })
        let cursor = MemoryRevCursor()
        let sync = ChangeFeedSync(transport: server, cursor: cursor, model: model,
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        let run = Task { await sync.runForeground() }
        await eventually("the feed is open") { server.openFeedCount == 1 }
        XCTAssertEqual(model.rebaselines, 1)
        XCTAssertEqual(try cursor.load(), 2, "The snapshot's rev is the starting cursor.")

        server.commit("entry", "{}")
        await eventually("the live change is applied") { model.applied == [3] }
        XCTAssertEqual(try cursor.load(), 3)
        let state = await sync.liveState
        XCTAssertEqual(state, .live)
        run.cancel()
    }

    func testTheCursorAdvancesOnlyAfterTheChangeIsPersistedAndAFailedApplyIsRedelivered() async throws {
        let server = FakeClientAPIServer()
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let cursor = MemoryRevCursor(0)
        model.onApply = { change in
            // At apply time the cursor has not yet moved past the change.
            XCTAssertLessThan((try? cursor.load()) ?? 0, change.rev)
        }
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, cursor: cursor, model: model, errors: errors,
                                  waitBeforeRetry: noWait)
        server.commit("item", "{}")
        server.commit("item", "{}")
        model.failApplyAt = 2
        let run = Task { await sync.runForeground() }
        await eventually("both changes applied after the retry") { model.applied == [1, 2] }
        XCTAssertEqual(try cursor.load(), 2)
        XCTAssertEqual(errors.reports.first?.phase, "apply", "The failed apply is in the Error Log.")
        run.cancel()
    }

    func testAnExpiredCursorRebaselinesAndResumesWithoutMissingLaterChanges() async throws {
        let server = FakeClientAPIServer()
        for _ in 0..<5 { server.commit("item", "{}") }
        server.prune(through: 4)
        let model = RecordingSyncModel(snapshotRev: { server.head })
        let cursor = MemoryRevCursor(1)
        let sync = ChangeFeedSync(transport: server, cursor: cursor, model: model,
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        let run = Task { await sync.runForeground() }
        await eventually("the feed reopens from the snapshot") { server.openFeedCount == 1 }
        XCTAssertEqual(model.rebaselines, 1)
        XCTAssertEqual(try cursor.load(), 5)
        server.commit("item", "{}")
        await eventually("the next change arrives") { model.applied == [6] }
        run.cancel()
    }

    func testAServerShutdownReconnectsFromTheCursorAndARevokeStopsSync() async throws {
        let server = FakeClientAPIServer()
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, cursor: MemoryRevCursor(0), model: model, errors: errors,
                                  waitBeforeRetry: noWait)
        let run = Task { await sync.runForeground() }
        await eventually("open") { server.openFeedCount == 1 }
        server.closeFeeds(reason: "server_shutdown")
        server.commit("item", "{}")
        await eventually("reopened and caught up") { model.applied == [1] }

        server.closeFeeds(reason: "revoked")
        _ = await run.value
        let state = await sync.liveState
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(errors.reports.map(\.initiator), [.serverClosed, .deviceRevoked],
                       "Each server-initiated end names its initiator.")
    }

    func testPushCatchUpAppliesEveryBatchFromTheCursor() async throws {
        let server = FakeClientAPIServer()
        for _ in 0..<5 { server.commit("item", "{}") }
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let cursor = MemoryRevCursor(1)
        let sync = ChangeFeedSync(transport: server, cursor: cursor, model: model,
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        try await sync.catchUp()
        XCTAssertEqual(model.applied, [2, 3, 4, 5])
        XCTAssertEqual(try cursor.load(), 5)
    }
}

final class ActionOutboxTests: XCTestCase {
    private func outbox(_ server: FakeClientAPIServer, _ persistence: MemoryOutboxPersistence,
                        _ outcomes: RecordingOutcomes, errors: RecordingErrorLogV2 = RecordingErrorLogV2(),
                        wait: @escaping @Sendable (Int, TimeInterval?) async throws -> Void = noOutboxWait)
        throws -> ActionOutbox {
        server.persistedKeys = { persistence.keys }
        return try ActionOutbox(persistence: persistence, transport: server, outcomes: outcomes, errors: errors,
                                waitBeforeRetry: wait)
    }

    private let seen = FrozenWrite(method: .post, path: "/v2/items/a/seen", body: Data("{}".utf8))

    func testTheKeyIsPersistedBeforeTheFirstSendAndTheResponseIsApplied() async throws {
        let server = FakeClientAPIServer()
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, persistence, outcomes)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("accepted") { outcomes.accepted.count == 1 }
        XCTAssertEqual(server.keysPersistedAtSend, [true])
        XCTAssertEqual(server.received.first?.idempotencyKey, entry.idempotencyKey)
        XCTAssertEqual(outcomes.accepted.first?.1.rev, 1, "The write's own rev reaches the model at once.")
        let pending = await box.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func testAnUnsavedIntentIsNeverSent() async throws {
        let server = FakeClientAPIServer()
        let persistence = MemoryOutboxPersistence()
        persistence.failNextSave = true
        let box = try outbox(server, persistence, RecordingOutcomes())
        do {
            try await box.submit(target: "a", operation: "mark_seen", write: seen)
            XCTFail("The save failure is reported to the caller.")
        } catch {}
        await box.flush()
        XCTAssertTrue(server.received.isEmpty)
    }

    func testAnUnknownOutcomeIsResentWithTheSameKeyAndTheReplayCountsAsTheOriginal() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [CommittedThenLost(error: URLError(.networkConnectionLost))]
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let errors = RecordingErrorLogV2()
        let box = try outbox(server, persistence, outcomes, errors: errors)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("first send ended unknown") { errors.reports.count == 1 }
        XCTAssertEqual(persistence.keys, [entry.idempotencyKey], "Kept, with its key, after an unknown outcome.")

        // Relaunch: a new outbox from the same durable record resends it.
        let relaunched = try outbox(server, persistence, outcomes, errors: errors)
        await relaunched.flush()
        XCTAssertEqual(server.received.map(\.idempotencyKey), [entry.idempotencyKey, entry.idempotencyKey])
        XCTAssertEqual(outcomes.accepted.count, 1)
        XCTAssertEqual(outcomes.accepted.first?.1.replayed, true)
        XCTAssertEqual(server.head, 1, "The server applied the mutation once.")
        XCTAssertTrue(persistence.keys.isEmpty)
        XCTAssertEqual(errors.resolutions, ["actions.mark_seen"])
    }

    func testOperationsOnOneItemGoInOrderWhileOtherItemsProceed() async throws {
        let server = FakeClientAPIServer()
        let held = AsyncGate()
        server.holdWrites["/v2/items/a/answer"] = held
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes)
        let answer = try await box.submit(target: "a", operation: "answer",
            write: FrozenWrite(method: .post, path: "/v2/items/a/answer", body: Data(#"{"request_revision":1}"#.utf8)))
        let reply = try await box.submit(target: "a", operation: "reply",
            write: FrozenWrite(method: .post, path: "/v2/items/a/replies", body: Data(#"{"text":"t"}"#.utf8)))
        let other = try await box.submit(target: "b", operation: "mark_seen",
            write: FrozenWrite(method: .post, path: "/v2/items/b/seen", body: Data("{}".utf8)))
        await eventually("the other item is accepted") { outcomes.accepted.map(\.0) == [other.idempotencyKey] }
        XCTAssertFalse(server.received.contains { $0.path == "/v2/items/a/replies" },
                       "The later operation on the same item waits for the earlier one.")
        held.release()
        await eventually("both in order") { outcomes.accepted.count == 3 }
        XCTAssertEqual(outcomes.accepted.map(\.0), [other.idempotencyKey, answer.idempotencyKey, reply.idempotencyKey])
    }

    func testADefinitiveRefusalLeavesTheOutboxAndIsShownWithItsToken() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [APIError(status: 409, token: .staleRequest, retryable: false, requestID: "req-x")]
        let outcomes = RecordingOutcomes()
        let errors = RecordingErrorLogV2()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes, errors: errors)
        try await box.submit(target: "a", operation: "answer",
            write: FrozenWrite(method: .post, path: "/v2/items/a/answer", body: Data("{}".utf8)))
        await eventually("refused") { outcomes.rejected.count == 1 }
        XCTAssertEqual(outcomes.rejected.first?.1.token, .staleRequest)
        XCTAssertEqual(errors.reports.first?.correlation.serverConnectionID, "req-x",
                       "The Request-Id is kept for correlation.")
        XCTAssertEqual(errors.reports.first?.retryable, false)
        let pending = await box.pending
        XCTAssertTrue(pending.isEmpty)
    }
}

/// Design section 8 on the r2 API: a failing change feed cannot stop reads
/// or actions.
final class ClientAPIIsolationTests: XCTestCase {
    private func assertReadsAndActionsSurviveAFailingFeed(_ failure: any Error) async throws {
        let server = FakeClientAPIServer()
        server.feedFailure = failure
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, cursor: MemoryRevCursor(0),
                                  model: RecordingSyncModel(snapshotRev: { 0 }), errors: errors,
                                  waitBeforeRetry: noWait)
        let run = Task { await sync.runForeground() }
        await eventually("the feed failure was reported") { errors.reports.contains { $0.concern == .sync } }

        let read = try await server.send(.get("/v2/inbox"))
        XCTAssertEqual(read.status, 200, "The inbox read succeeds while the feed is failing.")
        let outcomes = RecordingOutcomes()
        let box = try ActionOutbox(persistence: MemoryOutboxPersistence(), transport: server, outcomes: outcomes,
                                   errors: errors, waitBeforeRetry: noOutboxWait)
        try await box.submit(target: "a", operation: "mark_seen",
                             write: FrozenWrite(method: .post, path: "/v2/items/a/seen", body: Data("{}".utf8)))
        await eventually("Mark Seen is confirmed") { outcomes.accepted.count == 1 }
        XCTAssertFalse(errors.reports.contains { $0.concern != .sync },
                       "Only Sync reports the feed failure.")
        run.cancel()
    }

    func testReadsAndMarkSeenSurviveACancelledFeed() async throws {
        try await assertReadsAndActionsSurviveAFailingFeed(URLError(.cancelled))
    }

    func testReadsAndMarkSeenSurviveAnAbortedFeed() async throws {
        try await assertReadsAndActionsSurviveAFailingFeed(POSIXError(.ECONNABORTED))
    }
}
