import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

private func waitUntilTrue(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out: \(message)", file: file, line: line)
}

/// Serves scripted catch-up batches, then a live feed that stays open.
private final class ScriptedBatches: ClientAPITransport, @unchecked Sendable {
    private let lock = NSLock()
    var batches: [Rev: FeedBatch] = [:]
    private(set) var feedOpenedAfter: Rev?
    func send(_ request: APIRequest) async throws -> APIResponse {
        throw APIError(status: 404, token: .notFound, retryable: false, requestID: "r")
    }
    func changeBatch(after: Rev) async throws -> FeedBatch {
        lock.withLock { batches[after] } ?? FeedBatch(changes: [], rev: after, more: false)
    }
    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        lock.withLock { feedOpenedAfter = after }
        return AsyncThrowingStream { $0.yield(.opened(requestID: "feed")) }
    }
}

/// Contract rounds 12, 13 and 15 as the client sees them.
final class ContractRounds12To15Tests: XCTestCase {
    private let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                           personID: ExactText("person-A"), deviceID: ExactText("installation-A"))

    private func projected(_ items: [String]) throws -> CachedAttentionServerState {
        let store = ServerModelV2Store(fileURL: nil)
        for (index, item) in items.enumerated() {
            try store.apply(kind: "item", rev: UInt64(index + 1), data: V2Fixture.json(item))
        }
        return ServerModelV2Projection.cachedState(store.snapshot, identity: identity)
    }

    private func key(_ id: String) -> RequestKey {
        RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"), messageID: ExactText(id))
    }

    /// Round 12: a batch is complete through its `rev`, which can pass its
    /// last change when trailing rows have no client form.
    func testABatchOfFormlessRowsAdvancesTheCursorAndNeverLoops() async throws {
        let transport = ScriptedBatches()
        let change = FeedChange(rev: 6, kind: .item, data: Data("{}".utf8))
        transport.batches = [0: FeedBatch(changes: [], rev: 5, more: true),
                             5: FeedBatch(changes: [change], rev: 8, more: false)]
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let cursor = MemoryRevCursor(0)
        let sync = ChangeFeedSync(transport: transport, model: model.using(cursor), errors: RecordingErrorLogV2(),
                                  waitBeforeRetry: { _ in await Task.yield() })
        let run = Task { await sync.runForeground() }
        await waitUntilTrue("the live feed opens") { transport.feedOpenedAfter != nil }
        XCTAssertEqual(transport.feedOpenedAfter, 8, "The feed follows from the position the batches were complete through.")
        XCTAssertEqual(model.applied, [6])
        XCTAssertEqual(try cursor.load(), 8)
        run.cancel()
    }

    /// Round 13: an item sent without a session has no conversation, so no
    /// composer, while other items keep chat open after every outcome.
    func testAnItemWithoutAConversationOffersNoComposer() throws {
        let cached = try projected([
            V2Fixture.item("none", rev: 1, rankKey: "a", chat: #"{"available":false,"started":false}"#),
            V2Fixture.item("done", rev: 2, rankKey: "b",
                           terminal: #"{"state":"answered","at_ms":9,"answer":{"kind":"reply","text":"ok"}}"#)
        ])
        let none = try XCTUnwrap(cached.conversations[key("none")])
        XCTAssertFalse(none.isComposerOpen)
        XCTAssertFalse(none.allowsDiscussion)
        let done = try XCTUnwrap(cached.conversations[key("done")])
        XCTAssertTrue(done.isComposerOpen, "APP-06 is unchanged for items with a conversation.")
    }

    /// Round 15: the urgency marks come from `Rank.level`.
    func testTheInboxPriorityComesFromRankLevel() throws {
        let cached = try projected([
            V2Fixture.item("n", rev: 1, rankKey: "a").replacingOccurrences(of: #""section":"current"}"#,
                                                                       with: #""section":"current","level":"now"}"#),
            V2Fixture.item("h", rev: 2, rankKey: "b").replacingOccurrences(of: #""section":"current"}"#,
                                                                       with: #""section":"current","level":"high"}"#),
            V2Fixture.item("x", rev: 3, rankKey: "c")
        ])
        let priorities = Dictionary(uniqueKeysWithValues: (cached.inboxView?.entries ?? []).map {
            ($0.key.messageID.rawValue, $0.priority)
        })
        XCTAssertEqual(priorities["n"], .some(.now))
        XCTAssertEqual(priorities["h"], .some(.high))
        XCTAssertEqual(priorities["x"], .some(nil), "Without a level, no mark.")
    }

    /// Round 15: a value action's answer shows which option was chosen.
    func testAChoiceAnswerCarriesTheChosenOptionsLabel() throws {
        let cached = try projected([
            V2Fixture.item("c", rev: 1, rankKey: "a",
                terminal: #"{"state":"answered","at_ms":9,"answer":{"kind":"choice","id":"approve","label":"Approve"}}"#),
            V2Fixture.item("bare", rev: 2, rankKey: "b",
                terminal: #"{"state":"answered","at_ms":9,"answer":{"kind":"choice"}}"#)
        ])
        XCTAssertEqual(cached.remoteStates[key("c")]?.accountAnswerOutcome,
                       .choice(id: ExactText("approve"), label: ExactText("Approve")))
        XCTAssertNil(cached.remoteStates[key("bare")]?.accountAnswerOutcome,
                     "A choice without its option shows no outcome, as an unmatched answer does today.")
    }
}
