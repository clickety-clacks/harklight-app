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
        XCTAssertEqual(try FeedEvent(ServerSentEvent(id: nil, event: "heartbeat", data: "{}")), .heartbeat,
                       "A heartbeat has no id and is not a change.")
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
        XCTAssertTrue(errors.reports.allSatisfy { $0.correlation.requestID?.hasPrefix("req-") == true },
                      "Each report carries the feed's Request-Id.")
    }

    func testCatchUpAdvancesPerBatchSoAFailureResumesFromTheLastFullBatch() async throws {
        let server = FakeClientAPIServer()
        for _ in 0..<5 { server.commit("item", "{}") }
        let model = RecordingSyncModel(snapshotRev: { 0 })
        model.failApplyAt = 4
        let cursor = MemoryRevCursor(1)
        let sync = ChangeFeedSync(transport: server, cursor: cursor, model: model,
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        do { try await sync.catchUp(); XCTFail("The failed apply ends the catch-up.") } catch {}
        XCTAssertEqual(try cursor.load(), 3, "The first batch (2, 3) is kept; the failed change is not.")
        try await sync.catchUp()
        XCTAssertEqual(model.applied, [2, 3, 4, 5])
        XCTAssertEqual(try cursor.load(), 5)
    }

    func testASeededPersonsZeroCursorRebaselinesInsteadOfReadingFromTheStart() async throws {
        let server = FakeClientAPIServer()
        // Seeded at cut-over: position 1, log retained only from rev 2.
        server.prune(through: 1)
        server.commit("item", "{}")
        let model = RecordingSyncModel(snapshotRev: { server.head })
        let cursor = MemoryRevCursor(0)
        let sync = ChangeFeedSync(transport: server, cursor: cursor, model: model,
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        try await sync.catchUp()
        XCTAssertEqual(model.rebaselines, 1)
        XCTAssertEqual(try cursor.load(), 2)
    }

    func testARejectedDeviceCertificateStopsSync() async throws {
        let server = FakeClientAPIServer()
        server.feedFailure = URLError(.clientCertificateRejected)
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, cursor: MemoryRevCursor(0),
                                  model: RecordingSyncModel(snapshotRev: { 0 }), errors: errors,
                                  waitBeforeRetry: noWait)
        await sync.runForeground()
        let state = await sync.liveState
        XCTAssertEqual(state, .stopped, "A revoked device fails at TLS; Sync stops rather than retrying.")
        XCTAssertEqual(errors.reports.map(\.initiator), [.deviceRevoked])
    }

    func testHeartbeatsKeepTheFeedLiveWithoutMovingTheCursorAndAPauseStopsSync() async throws {
        let server = FakeClientAPIServer()
        let cursor = MemoryRevCursor(0)
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let sync = ChangeFeedSync(transport: server, cursor: cursor, model: model,
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        let run = Task { await sync.runForeground() }
        await eventually("open") { server.openFeedCount == 1 }
        server.heartbeat()
        server.commit("item", "{}")
        await eventually("applied") { model.applied == [1] }
        XCTAssertEqual(cursor.saves, [1], "Only the change moved the cursor.")
        server.closeFeeds(reason: "account_paused")
        _ = await run.value
        let state = await sync.liveState
        XCTAssertEqual(state, .accountPaused)
    }

    func testCatchUpRebaselinesOnceAndReportsASecondExpiry() async throws {
        let server = FakeClientAPIServer()
        for _ in 0..<3 { server.commit("item", "{}") }
        server.prune(through: 3)
        // A snapshot that is itself already too old to resume from.
        let model = RecordingSyncModel(snapshotRev: { 1 })
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, cursor: MemoryRevCursor(1), model: model, errors: errors,
                                  waitBeforeRetry: noWait)
        do { try await sync.catchUp(); XCTFail("A second 410 ends the catch-up.") } catch {}
        XCTAssertEqual(model.rebaselines, 1, "No rebaseline loop.")
        XCTAssertEqual(errors.reports.first?.operation, "catch_up")
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

    func testAnAutomaticRetryResendsAfterAnUnknownOutcome() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [URLError(.timedOut)]
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes,
                             wait: { _, _ in try await Task.sleep(for: .milliseconds(20)) })
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("the retry delivered it") { outcomes.accepted.count == 1 }
        XCTAssertEqual(server.received.map(\.idempotencyKey), [entry.idempotencyKey, entry.idempotencyKey],
                       "The retry is not cancelled by its own send and reuses the key.")
    }

    func testAnUnknownServerErrorWithoutAContractBodyNeverDropsTheWrite() async throws {
        let unknown = APIError(status: 502, body: Data("<html>bad gateway</html>".utf8), requestID: nil, retryAfter: nil)
        XCTAssertTrue(unknown.retryable)
        XCTAssertFalse(unknown.isPermanent)
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [unknown]
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, persistence, outcomes)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("held") { server.received.count == 1 }
        await box.flush()
        XCTAssertTrue(outcomes.rejected.isEmpty)
        XCTAssertEqual(outcomes.accepted.map(\.0), [entry.idempotencyKey])
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

    func testARevokedDeviceHoldsTheOutboxForReviewAfterReenrolment() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [URLError(.clientCertificateRejected)]
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, persistence, outcomes)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("held") { await box.unauthorized }
        XCTAssertEqual(persistence.keys, [entry.idempotencyKey], "Kept, with its key.")
        await box.resumeAfterReenrolment()
        XCTAssertEqual(outcomes.accepted.map(\.0), [entry.idempotencyKey])
    }

    func testAPausedAccountKeepsWritesUntilThePauseEnds() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [APIError(status: 403, body: Data(#"{"error":"account_paused","retryable":false,"request_id":"r"}"#.utf8),
                                             requestID: nil, retryAfter: nil)]
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, persistence, outcomes)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("held") { await box.unauthorized }
        XCTAssertTrue(outcomes.rejected.isEmpty, "A pause never refuses the person's write.")
        XCTAssertEqual(persistence.keys, [entry.idempotencyKey])
        await box.resumeAfterReenrolment()
        XCTAssertEqual(outcomes.accepted.map(\.0), [entry.idempotencyKey])
    }

    func testAForbiddenWriteIsADefinitiveRefusal() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [APIError(status: 403, body: Data(#"{"error":"forbidden","retryable":false,"request_id":"r"}"#.utf8),
                                             requestID: nil, retryAfter: nil)]
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes)
        try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("refused") { outcomes.rejected.count == 1 }
        XCTAssertEqual(outcomes.rejected.first?.1.token, .forbidden)
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
        XCTAssertEqual(errors.reports.first?.correlation.requestID, "req-x",
                       "The Request-Id is kept for correlation.")
        XCTAssertEqual(errors.reports.first?.httpStatus, 409)
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

final class RevGateTests: XCTestCase {
    func testOnlyNewerRevsApplyAndARemovalCannotBeUndoneByAnOlderSnapshot() {
        var gate = RevGate()
        XCTAssertTrue(gate.admit("item-a", rev: 5))
        XCTAssertFalse(gate.admit("item-a", rev: 5), "A duplicate is a no-op.")
        XCTAssertFalse(gate.admit("item-a", rev: 4), "An older change is a no-op.")
        let removedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(gate.admitRemoval("item-a", rev: 7, at: removedAt))
        XCTAssertFalse(gate.admit("item-a", rev: 6), "An older snapshot cannot bring the item back.")
        XCTAssertTrue(gate.isRemoved("item-a"))
        XCTAssertTrue(gate.admit("item-a", rev: 8), "A newer write does.")
        XCTAssertFalse(gate.isRemoved("item-a"))
    }

    func testTombstonesAreKeptForTheRetentionWindowOnly() {
        var gate = RevGate()
        let removedAt = Date(timeIntervalSince1970: 1_000)
        _ = gate.admitRemoval("item-a", rev: 3, at: removedAt)
        gate.pruneTombstones(now: removedAt.addingTimeInterval(RevGate.tombstoneRetention - 1))
        XCTAssertTrue(gate.isRemoved("item-a"))
        gate.pruneTombstones(now: removedAt.addingTimeInterval(RevGate.tombstoneRetention + 1))
        XCTAssertFalse(gate.isRemoved("item-a"))
    }
}
