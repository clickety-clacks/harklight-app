import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

private func soon(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                  _ condition: @escaping () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out: \(message)", file: file, line: line)
}

/// Serves `GET /v2/me` and passes everything else to the fake server.
private final class WithMe: ClientAPITransport, @unchecked Sendable {
    let server: FakeClientAPIServer
    var me: String?
    /// Fails this many `/v2/me` reads first.
    var failMe = 0
    private(set) var meReads = 0
    init(_ server: FakeClientAPIServer, me: String?) {
        self.server = server
        self.me = me
    }
    func send(_ request: APIRequest) async throws -> APIResponse {
        guard request.path == "/v2/me" else { return try await server.send(request) }
        meReads += 1
        if failMe > 0 { failMe -= 1; throw URLError(.networkConnectionLost) }
        guard let me else { throw URLError(.notConnectedToInternet) }
        return APIResponse(status: 200, requestID: "req-me", body: Data(me.utf8))
    }
    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> { server.changeFeed(after: after) }
    func changeBatch(after: Rev) async throws -> FeedBatch { try await server.changeBatch(after: after) }
}

/// Refuses every request, as with no connection.
private struct Offline: ClientAPITransport {
    func send(_ request: APIRequest) async throws -> APIResponse { throw URLError(.notConnectedToInternet) }
    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
    }
    func changeBatch(after: Rev) async throws -> FeedBatch { throw URLError(.notConnectedToInternet) }
}

/// The v2 lifecycle's composition root (B3): Sync, the outbox, `/v2/me`
/// and publishing the model into the app's repository.
final class ClientAPIv2ConnectionTests: XCTestCase {
    private let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                           personID: ExactText("person-A"), deviceID: ExactText("installation-A"))
    private var savedRules = AnswerScreenRules.today
    private let me = #"{"account":{"state":"active"},"features":{},"limits":{"upload_cap_bytes_per_file":1,"inline_decoded_bytes_per_entry":1,"retention_days":30,"answer_ui_limits":{"document_bytes":262144,"requires":16,"illustrations":128,"primitives_per_illustration":2048,"primitives_total":4096,"inputs":64,"actions":256,"scene_nodes":1024,"scene_depth":32,"result_nodes":1024,"result_depth":32,"result_point_path":32,"array_items":1024,"object_members":512,"identifier_bytes":256}}}"#

    override func setUp() {
        savedRules = AnswerScreenRules.current
        AnswerScreenRules.current = .today
    }

    override func tearDown() { AnswerScreenRules.current = savedRules }

    private lazy var context = ProfileContext(identity: identity, transportMode: .relay)

    private func connection(_ transport: any ClientAPITransport, _ repository: ClientRepository,
                            directory: URL? = nil,
                            errors: RecordingErrorLogV2 = RecordingErrorLogV2()) throws -> ClientAPIv2Connection {
        try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
                                  directory: directory, errors: errors,
                                  waitBeforeRetry: { _ in try await Task.sleep(for: .milliseconds(20)) },
                                  outboxWaitBeforeRetry: { _, _ in try await Task.sleep(for: .seconds(3600)) },
                                  meWaitBeforeRetry: { _ in try await Task.sleep(for: .milliseconds(10)) })
    }

    private func itemIDs(_ repository: ClientRepository) throws -> Set<String> {
        Set(try repository.snapshot(context: context).requests.keys.map(\.messageID.rawValue))
    }

    func testTheEndpointIsTheRelaysHostAndPortOverHTTPS() throws {
        XCTAssertEqual(ClientAPIv2Endpoint.baseURL(fromRelayURL: try XCTUnwrap(URL(string: "wss://server.example:8443/relay"))),
                       URL(string: "https://server.example:8443"))
        XCTAssertEqual(ClientAPIv2Endpoint.baseURL(fromRelayURL: try XCTUnwrap(URL(string: "https://server.example/x?y=1"))),
                       URL(string: "https://server.example"))
        XCTAssertNil(ClientAPIv2Endpoint.baseURL(fromRelayURL: try XCTUnwrap(URL(string: "ws://server.example:80/relay"))),
                     "Never in the clear.")
    }

    func testForegroundReadsTheRulesThenPublishesTheBaselineAndEveryChange() async throws {
        let server = FakeClientAPIServer()
        server.inboxItems = [V2Fixture.item("a", rev: 1, rankKey: "a")]
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let v2 = try connection(WithMe(server, me: me), repository)
        let run = Task { await v2.runForeground() }
        await soon("the baseline is published") { (try? self.itemIDs(repository)) == ["a"] }
        XCTAssertEqual(AnswerScreenRules.current.limits.documentBytes, 262_144, "The published limits are in force.")
        XCTAssertTrue(AnswerScreenRules.current.degradesUnshowableScreens)

        await soon("the feed is open") { server.openFeedCount == 1 }
        _ = server.commit("item", V2Fixture.item("b", rev: Int(server.head) + 1, rankKey: "b"))
        await soon("the change is published") { (try? self.itemIDs(repository)) == ["a", "b"] }
        run.cancel()
    }

    func testNothingIsPublishedUntilTheRulesAreRead() async throws {
        let server = FakeClientAPIServer()
        server.inboxItems = [V2Fixture.item("a", rev: 1, rankKey: "a")]
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = WithMe(server, me: nil)
        let v2 = try connection(transport, repository)
        let run = Task { await v2.runForeground() }
        await soon("the baseline is held") { v2.model.heldCursor != nil }
        XCTAssertTrue(try itemIDs(repository).isEmpty, "Without /v2/me no screen is judged by the wrong rules.")
        transport.me = me
        try await v2.refreshMe()
        XCTAssertEqual(try itemIDs(repository), ["a"])
        run.cancel()
    }

    func testARelaunchShowsTheSavedModelUnderTheSavedRulesBeforeAnyRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeClientAPIServer()
        server.inboxItems = [V2Fixture.item("a", rev: 1, rankKey: "a")]
        let first = try connection(WithMe(server, me: me), try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence()), directory: directory)
        let run = Task { await first.runForeground() }
        await soon("saved") { first.model.heldCursor != nil && first.presentation.hasRules }
        run.cancel()

        AnswerScreenRules.current = .today
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let relaunched = try connection(Offline(), repository, directory: directory)
        let offline = Task { await relaunched.runForeground() }
        await soon("the saved model is shown") { (try? self.itemIDs(repository)) == ["a"] }
        XCTAssertEqual(AnswerScreenRules.current.limits.documentBytes, 262_144, "Under the saved rules.")
        offline.cancel()
    }

    /// #393 review M1: one failed `/v2/me` read does not leave the session
    /// unpublished; it is read again until it succeeds, and its record resolves.
    func testAFailedRulesReadIsRetriedUntilTheModelCanBePublished() async throws {
        let server = FakeClientAPIServer()
        server.inboxItems = [V2Fixture.item("a", rev: 1, rankKey: "a")]
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = WithMe(server, me: me)
        transport.failMe = 2
        let errors = RecordingErrorLogV2()
        let v2 = try connection(transport, repository, errors: errors)
        let run = Task { await v2.runForeground() }
        await soon("published after the retries") { (try? self.itemIDs(repository)) == ["a"] }
        XCTAssertEqual(transport.meReads, 3)
        XCTAssertEqual(errors.reports.filter { $0.operation == "me" }.count, 2)
        XCTAssertTrue(errors.resolutions.contains("snapshot.me"), "The record resolves once it is read.")
        run.cancel()
    }

    /// #393 review M2 (L-29): writes saved before a relaunch are sent once,
    /// under their saved keys, when the connection starts; refused ones stay
    /// failed until the person retries.
    func testSavedWritesAreSentOnceAfterARelaunchAndRefusedOnesStayFailed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let offline = try connection(Offline(), try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence()), directory: directory)
        let seen = FrozenWrite(method: .post, path: "/v2/items/a/seen", body: Data("{}".utf8))
        let pending = try await offline.outbox.submit(target: "item:a", operation: "mark_seen", write: seen)
        await soon("its first send ended") { await offline.outbox.pending.first?.attempts == 1 }

        let refusing = FakeClientAPIServer()
        refusing.nextWriteFailures = [APIError(status: 409, token: .alreadyAnswered, retryable: false, requestID: "r")]
        let refusedBox = try ClientAPIv2Connection(transport: refusing, repository: try ClientRepository(
            context: context, persistence: MemoryPendingActionPersistence()), context: context,
            directory: directory.appendingPathComponent("other"), errors: RecordingErrorLogV2(),
            outboxWaitBeforeRetry: { _, _ in try await Task.sleep(for: .seconds(3600)) })
        let refused = try await refusedBox.outbox.submit(target: "item:b", operation: "answer",
            write: FrozenWrite(method: .post, path: "/v2/items/b/answer", body: Data("{}".utf8)))
        await soon("refused") { await refusedBox.outbox.failedWrites.count == 1 }

        let server = FakeClientAPIServer()
        let relaunched = try connection(WithMe(server, me: me), try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence()), directory: directory)
        let run = Task { await relaunched.runForeground() }
        await soon("the saved write is sent") { server.received.contains { $0.path == "/v2/items/a/seen" } }
        await soon("and leaves the outbox") { await relaunched.outbox.pending.isEmpty }
        XCTAssertEqual(server.received.filter { $0.method != .get }.map(\.idempotencyKey), [pending.idempotencyKey],
                       "Sent once, under its saved key.")

        let refusedAgain = try connection(WithMe(server, me: me), try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence()), directory: directory.appendingPathComponent("other"))
        let second = Task { await refusedAgain.runForeground() }
        await soon("the feed is open") { server.openFeedCount >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(server.received.contains { $0.path == "/v2/items/b/answer" }, "A refused write is not resent.")
        let failed = await refusedAgain.outbox.failedWrites
        XCTAssertEqual(failed.map(\.idempotencyKey), [refused.idempotencyKey], "It stays failed, with Retry.")
        run.cancel()
        second.cancel()
    }

    func testAFailedPublishRecordsItsCauseByName() {
        XCTAssertEqual(ClientAPIv2Connection.restoreFailure(AttentionStoreError.wrongAccount),
                       .app("restore_wrong_account"))
        XCTAssertEqual(ClientAPIv2Connection.restoreFailure(AttentionStoreError.persistence("private words")),
                       .app("restore_persistence"), "Only the case name, never its text.")
    }
}
