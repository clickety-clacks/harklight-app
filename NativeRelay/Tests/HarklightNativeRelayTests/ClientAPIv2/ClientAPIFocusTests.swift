import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

private func waitFor(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                     _ condition: @escaping () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out: \(message)", file: file, line: line)
}

/// Records focus writes and answers each with a queued body.
private final class FocusTransport: ClientAPITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    private(set) var sent: [APIRequest] = []
    var failNext: APIError?
    /// Holds the first write until released.
    var holdFirst: AsyncGate?
    func respond(_ body: String) { lock.withLock { bodies.append(body) } }
    var sentBodies: [String] { lock.withLock { sent.map { String(decoding: $0.body ?? Data(), as: UTF8.self) } } }
    func send(_ request: APIRequest) async throws -> APIResponse {
        let gate = lock.withLock { () -> AsyncGate? in defer { holdFirst = nil }; return holdFirst }
        if let gate {
            lock.withLock { sent.append(request) }
            await gate.wait()
            return APIResponse(status: 200, requestID: "r", body: Data(#"{"rev":1}"#.utf8))
        }
        let (failure, body) = lock.withLock { () -> (APIError?, String) in
            sent.append(request)
            defer { failNext = nil }
            return (failNext, bodies.isEmpty ? #"{"rev":1}"# : bodies.removeFirst())
        }
        if let failure { throw failure }
        return APIResponse(status: 200, requestID: "r", body: Data(body.utf8))
    }
    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> { AsyncThrowingStream { $0.finish() } }
    func changeBatch(after: Rev) async throws -> FeedBatch { FeedBatch(changes: [], rev: after, more: false) }
}

/// Lets a test release each renewal sleep by hand. Like `Task.sleep`, a
/// cancelled sleep ends at once with `CancellationError`.
private final class ManualTicks: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    var sleepers: Int { lock.withLock { waiting.count } }
    func sleep(_: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { waiting.append((id, continuation)) }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            cancel(id)
        }
    }
    private func cancel(_ id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
            return waiting.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
    func tick() { lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst().continuation }?.resume() }
}

private final class ShowLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var shows: [(ClientAPIShow, Date)] = []
    func add(_ show: ClientAPIShow, _ at: Date) { lock.withLock { shows.append((show, at)) } }
    var ids: [String] { lock.withLock { shows.map(\.0.showID) } }
}

/// Contract round 11 r4: focus and held shows, transport only.
final class ClientAPIFocusTests: XCTestCase {
    private let showJSON = #"{"show_id":"s1","device_id":"d1","item_id":"i1","target":"chat","held_ms":1500}"#

    private func channel(_ transport: FocusTransport, ticks: ManualTicks = ManualTicks(),
                         errors: RecordingErrorLogV2 = RecordingErrorLogV2(), log: ShowLog = ShowLog())
        -> ClientAPIFocusChannel {
        ClientAPIFocusChannel(transport: transport, errors: errors, sleep: { try await ticks.sleep($0) },
                              now: { Date(timeIntervalSince1970: 100) },
                              onShow: { log.add($0, $1) })
    }

    func testTheFocusBodyCarriesTodaysFieldsUnderV2Names() {
        func body(_ report: FocusReport) -> String {
            String(decoding: ClientAPIFocusWire.request(for: report, ttlSeconds: 120).body ?? Data(), as: UTF8.self)
        }
        let request = ClientAPIFocusWire.request(for: .inbox, ttlSeconds: 120)
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.path, "/v2/devices/me/focus")
        XCTAssertEqual(body(.inbox), #"{"screen":"inbox","ttl_s":120}"#)
        XCTAssertEqual(body(.notInFront), #"{"screen":"not_in_front","ttl_s":120}"#)
        XCTAssertEqual(body(.signedOut), #"{"screen":"signed_out","ttl_s":120}"#)
        XCTAssertEqual(body(.message(senderID: "agent", messageID: "i1")),
                       #"{"screen":"message","item_id":"i1","ttl_s":120}"#, "The sender is not sent.")
        XCTAssertEqual(body(.chat(senderID: "agent", messageID: "i1", visibility: .eventID("e9"))),
                       #"{"screen":"chat","item_id":"i1","visible_entry_id":"e9","ttl_s":120}"#)
        XCTAssertEqual(body(.chat(senderID: "agent", messageID: "i1", visibility: .noTurns)),
                       #"{"screen":"chat","item_id":"i1","ttl_s":120}"#)
    }

    func testAScreenChangeWritesFocusAndTheInFrontReportIsRenewedUnchanged() async throws {
        let transport = FocusTransport()
        let ticks = ManualTicks()
        let focus = channel(transport, ticks: ticks)
        let reply = await focus.report(.inbox)
        XCTAssertEqual(reply, .accepted)
        XCTAssertEqual(transport.sentBodies, [#"{"screen":"inbox","ttl_s":120}"#])

        await waitFor("renewal waits") { ticks.sleepers == 1 }
        ticks.tick()
        await waitFor("renewed") { transport.sent.count == 2 }
        XCTAssertEqual(transport.sentBodies.last, #"{"screen":"inbox","ttl_s":120}"#, "A renewal changes nothing.")

        // A new screen replaces the renewal; the old report is never resent.
        await waitFor("the next renewal waits") { ticks.sleepers == 1 }
        await focus.report(.message(senderID: "agent", messageID: "i1"))
        XCTAssertEqual(transport.sent.count, 3)
        await waitFor("only the new screen's renewal waits") { ticks.sleepers == 1 }
        ticks.tick()
        await waitFor("renewed the new screen") { transport.sent.count == 4 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.sent.count, 4, "The old screen's renewal was cancelled.")
        XCTAssertEqual(Set(transport.sentBodies.dropFirst(2)), [#"{"screen":"message","item_id":"i1","ttl_s":120}"#])
    }

    func testBackgroundingSendsNotInFrontAndStopsRenewing() async throws {
        let transport = FocusTransport()
        let ticks = ManualTicks()
        let focus = channel(transport, ticks: ticks)
        await focus.report(.inbox)
        await waitFor("renewal waits") { ticks.sleepers == 1 }
        await focus.report(.notInFront)
        ticks.tick()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.sentBodies, [#"{"screen":"inbox","ttl_s":120}"#, #"{"screen":"not_in_front","ttl_s":120}"#],
                       "Nothing is renewed out of front.")
        XCTAssertEqual(ticks.sleepers, 0)
    }

    func testAFailedWriteIsReportedAndTheRenewalRetriesIt() async throws {
        let transport = FocusTransport()
        transport.failNext = APIError(status: 503, token: .storageUnavailable, retryable: true, requestID: "req-f")
        let ticks = ManualTicks()
        let errors = RecordingErrorLogV2()
        let focus = channel(transport, ticks: ticks, errors: errors)
        let reply = await focus.report(.inbox)
        XCTAssertEqual(reply, .rejected)
        XCTAssertEqual(errors.reports.first?.operation, "focus")
        XCTAssertEqual(errors.reports.first?.correlation.requestID, "req-f")
        await waitFor("renewal waits") { ticks.sleepers == 1 }
        ticks.tick()
        await waitFor("retried by the renewal") { transport.sent.count == 2 }
        await waitFor("resolved") { errors.resolutions.contains("actions.focus") }
    }

    func testAShowFromTheFocusResponseOrTheFeedIsAppliedOnceByItsID() async throws {
        let transport = FocusTransport()
        transport.respond(#"{"rev":3,"show":\#(showJSON)}"#)
        let log = ShowLog()
        let focus = channel(transport, log: log)
        await focus.report(.inbox)
        XCTAssertEqual(log.ids, ["s1"])
        let first = try XCTUnwrap(log.shows.first)
        XCTAssertEqual(first.0, ClientAPIShow(showID: "s1", deviceID: "d1", itemID: "i1", target: .chat,
                                              heldMilliseconds: 1500))
        XCTAssertEqual(first.0.acceptedAt(receivedAt: first.1), Date(timeIntervalSince1970: 98.5),
                       "Its time on this clock is receipt minus its age.")

        await focus.received(feedShow: Data(showJSON.utf8))
        XCTAssertEqual(log.ids, ["s1"], "The same show from the feed is not applied again.")
        await focus.received(feedShow: Data(showJSON.replacingOccurrences(of: "s1", with: "s2").utf8))
        XCTAssertEqual(log.ids, ["s1", "s2"])
    }

    func testAMalformedOrUnknownShowIsNotApplied() async throws {
        let transport = FocusTransport()
        let log = ShowLog()
        let errors = RecordingErrorLogV2()
        let focus = channel(transport, errors: errors, log: log)
        await focus.received(feedShow: Data(#"{"show_id":"s1"}"#.utf8))
        await focus.received(feedShow: Data(showJSON.replacingOccurrences(of: "\"chat\"", with: "\"map\"").utf8))
        XCTAssertTrue(log.ids.isEmpty)
        XCTAssertEqual(errors.reports.map(\.operation), ["show", "show"])
        XCTAssertNil(ClientAPIFocusWire.show(inResponse: Data(#"{"rev":1}"#.utf8)))
    }

    func testAV2ShowReachesTheExistingPushedViewShape() throws {
        let show = try XCTUnwrap(ClientAPIShow(data: Data(showJSON.utf8)))
        let frame = ViewShowFrame.clientAPI(show, senderID: "agent")
        XCTAssertEqual(frame.senderID, "agent")
        XCTAssertEqual(frame.messageID, "i1")
        XCTAssertEqual(frame.target, .chat)
        XCTAssertEqual(frame.heldMilliseconds, 1500)
    }

    func testAShowEventOnTheFeedHasNoIdAndNeverMovesTheCursor() async throws {
        XCTAssertEqual(try FeedEvent(ServerSentEvent(id: nil, event: "show", data: showJSON)),
                       .show(Data(showJSON.utf8)), "An id-less show is not a malformed change.")

        let server = FakeClientAPIServer()
        let model = RecordingSyncModel(snapshotRev: { server.head })
        let cursor = MemoryRevCursor()
        let received = ShowLog()
        let sync = ChangeFeedSync(transport: server, model: model.using(cursor), errors: RecordingErrorLogV2(),
                                  waitBeforeRetry: { _ in await Task.yield() },
                                  onShow: { data in
                                      if let show = ClientAPIShow(data: data) { received.add(show, Date()) }
                                  })
        let run = Task { await sync.runForeground() }
        await waitFor("the feed is open") { server.openFeedCount == 1 }
        let before = try cursor.load()
        server.show(showJSON)
        await waitFor("the show reached focus") { received.ids == ["s1"] }
        XCTAssertEqual(try cursor.load(), before, "A show is not a log change.")
        server.commit("item", "{}")
        await waitFor("the feed still applies changes") { model.applied.count == 1 }
        run.cancel()
    }

    /// Focus addendum: `ttl_s` is an integer from 1 to 3600.
    func testTheTTLStaysWithinItsBounds() async throws {
        func ttl(_ seconds: Int) -> String {
            String(decoding: ClientAPIFocusWire.request(for: .inbox, ttlSeconds: seconds).body ?? Data(), as: UTF8.self)
        }
        XCTAssertEqual(ttl(0), #"{"screen":"inbox","ttl_s":1}"#)
        XCTAssertEqual(ttl(120), #"{"screen":"inbox","ttl_s":120}"#)
        XCTAssertEqual(ttl(5000), #"{"screen":"inbox","ttl_s":3600}"#)
        let transport = FocusTransport()
        let focus = ClientAPIFocusChannel(transport: transport, errors: RecordingErrorLogV2(), ttlSeconds: 0,
                                          sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, onShow: { _, _ in })
        await focus.report(.inbox)
        XCTAssertEqual(transport.sentBodies, [#"{"screen":"inbox","ttl_s":1}"#])
    }

    func testQueuedScreensAreReplacedByBackgroundWhileTheFirstPUTIsHeld() async {
        let transport = FocusTransport()
        let held = AsyncGate()
        transport.holdFirst = held
        let focus = channel(transport)
        await focus.enqueue(.inbox)
        await waitFor("inbox PUT starts") { transport.sentBodies.count == 1 }

        await focus.enqueue(.message(senderID: "agent", messageID: "item"))
        await focus.enqueue(.settings)
        await focus.enqueue(.notInFront)
        XCTAssertEqual(transport.sentBodies.count, 1)

        held.release()
        await waitFor("background PUT follows inbox") { transport.sentBodies.count == 2 }
        XCTAssertEqual(transport.sentBodies, [#"{"screen":"inbox","ttl_s":120}"#,
                                              #"{"screen":"not_in_front","ttl_s":120}"#])
        await focus.stop()
    }

    func testResolvingAnUnheldShowItemFetchesItWithoutAdvancingSync() async throws {
        let transport = FocusTransport()
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
                                                    directory: nil, errors: RecordingErrorLogV2())
        try connection.model.rebaseline(items: [], counts: APICounts(unresolved: 0), position: 1)
        let item = V2Fixture.item("not-yet-held", rev: 2, rankKey: "a")
        transport.respond(#"{"rev":2,"item":\#(item)}"#)

        let resolved = try await connection.resolveShowItem(itemID: ExactText("not-yet-held"))
        XCTAssertEqual(resolved?.sender, ExactText("agent-app"))
        XCTAssertEqual(transport.sent.first?.path, "/v2/items/not-yet-held")
        XCTAssertEqual(transport.sent.first?.method, .get)
        XCTAssertEqual(connection.model.heldCursor, 1)
        XCTAssertEqual(connection.model.snapshot.items[ExactText("not-yet-held")]?.seen, false)
    }

    /// Focus addendum: one focus write in flight; the latest report replaces
    /// any waiting one, so an older write never lands after a newer one.
    func testRapidScreenChangesSendOneAtATimeAndTheLatestWins() async throws {
        let transport = FocusTransport()
        let gate = AsyncGate()
        transport.holdFirst = gate
        let focus = channel(transport)
        let first = Task { await focus.report(.inbox) }
        await waitFor("the first write is in flight") { transport.sent.count == 1 }

        let older = FocusReport.message(senderID: "agent", messageID: "i1")
        let newer = FocusReport.message(senderID: "agent", messageID: "i2")
        let replaced = Task { await focus.report(older) }
        await waitFor("the next one waits") { await focus.waitingReport == older }
        let latest = Task { await focus.report(newer) }
        await waitFor("the latest replaces it") { await focus.waitingReport == newer }
        XCTAssertEqual(transport.sent.count, 1, "Nothing else is sent while a write is in flight.")

        gate.release()
        let replies = [await first.value, await replaced.value, await latest.value]
        XCTAssertEqual(replies, [.accepted, .accepted, .accepted])
        XCTAssertEqual(transport.sentBodies, [#"{"screen":"inbox","ttl_s":120}"#,
                                              #"{"screen":"message","item_id":"i2","ttl_s":120}"#],
                       "The replaced report is never sent.")
    }
}
