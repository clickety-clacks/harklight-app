import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

final class ServerModelV2ProjectionTests: XCTestCase {
    private let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                           personID: ExactText("person-A"), deviceID: ExactText("installation-A"))

    private func store(_ items: [String], entries: [(open: String, json: String)] = []) throws -> ServerModelV2Store {
        let store = ServerModelV2Store(fileURL: nil)
        for (index, item) in items.enumerated() {
            try store.apply(kind: "item", rev: UInt64(index + 1), data: V2Fixture.json(item))
        }
        for (open, json) in entries {
            try store.open(open)
            let entry = try APIEntry(json: V2Fixture.json(json))
            try store.apply(kind: "entry", rev: entry.rev, data: V2Fixture.json(json))
        }
        return store
    }

    private func key(_ id: String) -> RequestKey {
        RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"), messageID: ExactText(id))
    }

    func testItemsAreKeyedByItemIdAndOrderedByArrivalAndRank() throws {
        let store = ServerModelV2Store(fileURL: nil)
        try store.rebaseline(items: [
            APIItem(json: V2Fixture.json(V2Fixture.item("late", rev: 1, rankKey: "a", extra: #""created_at_ms":200"#))),
            APIItem(json: V2Fixture.json(V2Fixture.item("early", rev: 2, rankKey: "b", extra: #""created_at_ms":100"#)))
        ], counts: APICounts(unresolved: 2), position: 2)
        let cached = ServerModelV2Projection.cachedState(store.snapshot, identity: identity)
        XCTAssertEqual(cached.requests[key("early")]?.acceptanceOrder, 1,
                       "Items first held together are numbered by created_at_ms.")
        XCTAssertEqual(cached.requests[key("late")]?.acceptanceOrder, 2)
        XCTAssertEqual(cached.inboxView?.entries.map(\.key.messageID.rawValue), ["late", "early"],
                       "The inbox order follows rank.key.")
        XCTAssertEqual(cached.requests[key("late")]?.originalPayload.jsonString, #"{"title":"Question","body":"b"}"#,
                       "The message content is carried unchanged.")
    }

    func testTerminalStatesAndTheAnswerGivenElsewhereAreCarried() throws {
        let store = try store([
            V2Fixture.item("answered", rev: 1, rankKey: "a",
                terminal: #"{"state":"answered","at_ms":9,"by_this_person":true,"answer":{"kind":"reply","text":"Ship it"}}"#),
            V2Fixture.item("nocomment", rev: 2, rankKey: "b",
                terminal: #"{"state":"answered","at_ms":9,"answer":{"kind":"no_comment"}}"#),
            V2Fixture.item("retracted", rev: 3, rankKey: "c", terminal: #"{"state":"retracted","at_ms":12}"#)
        ])
        let cached = ServerModelV2Projection.cachedState(store.snapshot, identity: identity)
        XCTAssertEqual(cached.remoteStates[key("answered")]?.state, .answered)
        XCTAssertEqual(cached.remoteStates[key("answered")]?.accountAnswerOutcome, .reply(ExactText("Ship it")))
        XCTAssertEqual(cached.remoteStates[key("nocomment")]?.state, .noComment)
        XCTAssertTrue(cached.conversations[key("retracted")]?.isRetracted == true)
    }

    func testEntriesBecomeTurnsInPositionOrderWithReadPositionAndAvailability() throws {
        let store = try store(
            [V2Fixture.item("i", rev: 1, rankKey: "a",
                chat: #"{"available":true,"started":true,"read_position":"e1","last_origin_reply":"e2"}"#)],
            entries: [
                ("i", V2Fixture.entry("e2", item: "i", rev: 3, position: 2)),
                ("i", V2Fixture.entry("e1", item: "i", rev: 2, position: 1, author: "person"))
            ])
        let cached = ServerModelV2Projection.cachedState(store.snapshot, identity: identity)
        let thread = try XCTUnwrap(cached.conversations[key("i")])
        XCTAssertEqual(thread.turns.map(\.id.rawValue), ["e1", "e2"])
        XCTAssertEqual(thread.turns.map(\.kind), [.discussion, .reply], "The person's replies are discussions.")
        XCTAssertEqual(thread.accountReadThroughConversationSequence, 1)
        XCTAssertTrue(thread.hasUnreadAgentReply)
        XCTAssertEqual(thread.availability, .notListening(lastDetachedAt: ExactText("5")),
                       "Not listening is carried as information.")
        XCTAssertEqual(cached.chatReadPositions?[key("i")], 1)
    }

    func testSectionsAndUnreadReplyRowsFollowTheServer() throws {
        let store = try store([
            V2Fixture.item("current", rev: 1, rankKey: "a1",
                chat: #"{"available":true,"started":true,"read_position":"r1","last_origin_reply":"r3","unread_replies":2,"reply_group":"earlier_chat_replies","reply_rank_key":"a5"}"#)
                .replacingOccurrences(of: #""section":"current"}"#, with: #""section":"current","group":"common"}"#),
            V2Fixture.item("older", rev: 2, rankKey: "a3")
                .replacingOccurrences(of: #""section":"current"}"#, with: #""section":"current","group":"earlier_messages"}"#),
            V2Fixture.item("done", rev: 3, rankKey: "b0", section: "resolved")
        ])
        // Items with agent replies keep their feed entries, unopened.
        for (id, rev, position) in [("r1", 4, 1), ("r2", 5, 2), ("r3", 6, 3)] {
            try store.apply(kind: "entry", rev: UInt64(rev),
                            data: V2Fixture.json(V2Fixture.entry(id, item: "current", rev: rev, position: position)))
        }
        let view = try XCTUnwrap(ServerModelV2Projection.cachedState(store.snapshot, identity: identity).inboxView)
        let rows = try XCTUnwrap(view.listItems)
        XCTAssertEqual(rows.map { "\($0.kind.rawValue):\($0.key.messageID.rawValue)" },
                       ["message:current", "message:older", "reply:current", "message:done"],
                       "The reply row sorts by reply_rank_key among item rows.")
        XCTAssertEqual(rows.map(\.freeSection?.group), [.common, .earlierMessages, .earlierChatReplies, .common])
        XCTAssertEqual(rows.last?.freeSection?.state, .history, "Resolved items are drawn under History.")
        XCTAssertEqual(rows[2].unseenCount, 2)
        XCTAssertEqual(rows[2].conversationSequence, 3, "The row quotes the newest reply.")
        XCTAssertEqual(rows[2].openAtConversationSequence, 2, "It opens at the first unread reply.")
        XCTAssertEqual(view.freeOrderVersion, 1)
    }

    func testAReplyRowWaitsForItsReplyInsteadOfShowingNothing() throws {
        let store = try store([V2Fixture.item("i", rev: 1, rankKey: "a",
            chat: #"{"started":true,"last_origin_reply":"r9","unread_replies":1,"reply_group":"earlier_chat_replies","reply_rank_key":"a5"}"#)])
        let rows = try XCTUnwrap(ServerModelV2Projection.cachedState(store.snapshot, identity: identity).inboxView?.listItems)
        XCTAssertEqual(rows.map(\.kind), [.message], "No reply row until its reply is held.")
        XCTAssertEqual(store.snapshot.itemsNeedingEntries, [ExactText("i")])
    }

    func testAMessageArrivingAfterARemovalStillCountsAsNew() throws {
        let store = try store([V2Fixture.item("a", rev: 1, rankKey: "a"), V2Fixture.item("b", rev: 2, rankKey: "b")])
        let before = ServerModelV2Projection.cachedState(store.snapshot, identity: identity)
        let highWater = before.requests.values.compactMap(\.acceptanceOrder).max() ?? 0
        try store.apply(kind: "item_removed", rev: 3, data: V2Fixture.json(#"{"item_id":"b"}"#))
        try store.apply(kind: "item", rev: 4, data: V2Fixture.json(V2Fixture.item("c", rev: 4, rankKey: "c")))
        let after = ServerModelV2Projection.cachedState(store.snapshot, identity: identity)
        XCTAssertGreaterThan(after.requests[key("c")]?.acceptanceOrder ?? 0, highWater,
                             "Above the remembered high-water mark, so New messages admits it.")
    }

    func testTheServerArrivalOrdersNewMessagesAboveItemsFromBeforeFreeOrder() throws {
        let store = try store([
            V2Fixture.item("new-2", rev: 1, rankKey: "a", extra: #""arrival":7"#),
            V2Fixture.item("old", rev: 2, rankKey: "b"),
            V2Fixture.item("new-1", rev: 3, rankKey: "c", extra: #""arrival":5"#)
        ])
        let cached = ServerModelV2Projection.cachedState(store.snapshot, identity: identity)
        let order = { (id: String) in cached.requests[self.key(id)]?.acceptanceOrder ?? 0 }
        XCTAssertLessThan(order("new-1"), order("new-2"), "Ordered by the server's arrival, not by when it was held.")
        XCTAssertLessThan(order("old"), order("new-1"), "An item from before free order never counts as new.")
    }

    /// #378 review M-7: a discarded model restarts its local numbers, but the
    /// new-messages order comes from the server's arrival, so a message that
    /// arrives after the discard is still above the remembered high-water mark.
    func testANewMessageAfterTheModelIsDiscardedStillCountsAsNew() throws {
        let before = try store([V2Fixture.item("a", rev: 1, rankKey: "a", extra: #""arrival":4"#),
                                V2Fixture.item("b", rev: 2, rankKey: "b", extra: #""arrival":5"#)])
        let highWater = ServerModelV2Projection.cachedState(before.snapshot, identity: identity)
            .requests.values.compactMap(\.acceptanceOrder).max() ?? 0

        let discarded = ServerModelV2Store(fileURL: nil)
        try discarded.rebaseline(items: [
            APIItem(json: V2Fixture.json(V2Fixture.item("a", rev: 1, rankKey: "a", extra: #""arrival":4"#))),
            APIItem(json: V2Fixture.json(V2Fixture.item("b", rev: 2, rankKey: "b", extra: #""arrival":5"#)))
        ], counts: APICounts(unresolved: 2), position: 2)
        try discarded.apply(kind: "item", rev: 3, data: V2Fixture.json(V2Fixture.item("c", rev: 3, rankKey: "c", extra: #""arrival":6"#)))
        let after = ServerModelV2Projection.cachedState(discarded.snapshot, identity: identity)
        XCTAssertEqual(after.requests[key("b")]?.acceptanceOrder, highWater, "Existing items keep their order.")
        XCTAssertGreaterThan(after.requests[key("c")]?.acceptanceOrder ?? 0, highWater)
    }

    func testReplyPrioritiesReachTheInboxViewForReplyRowsAndNew() throws {
        let chat = #"{"started":true,"read_position":"r1","last_origin_reply":"r2","unread_replies":1,"reply_group":"earlier_chat_replies","reply_rank_key":"a5","reply_priority":{"level":"high","score":0.8}}"#
        let store = try store([V2Fixture.item("i", rev: 1, rankKey: "a", chat: chat)])
        for (id, rev, position, level) in [("r1", 2, 1, "low"), ("r2", 3, 2, "high")] {
            let entry = V2Fixture.entry(id, item: "i", rev: rev, position: position)
                .replacingOccurrences(of: #""files":[]}"#, with: #""files":[],"priority":{"level":"\#(level)","score":0.5}}"#)
            try store.apply(kind: "entry", rev: UInt64(rev), data: V2Fixture.json(entry))
        }
        let view = try XCTUnwrap(ServerModelV2Projection.cachedState(store.snapshot, identity: identity).inboxView)
        XCTAssertEqual(view.replies?.map(\.conversationSequence), [1, 2])
        XCTAssertEqual(view.replies?.map(\.priority), [.low, .high])
        let row = try XCTUnwrap(view.listItems?.first { $0.kind == .reply })
        XCTAssertEqual(row.score, 0.8)
        XCTAssertEqual(row.scoreKind, .current)
    }

    func testResultEntriesBecomeResultStatusTurns() throws {
        let store = try store([V2Fixture.item("i", rev: 1, rankKey: "a")])
        try store.open("i")
        try store.apply(kind: "entry", rev: 2, data: V2Fixture.json(#"{"entry_id":"res","item_id":"i","rev":2,"position":1,"kind":"result","author":"origin","request_revision":1,"result":{"status":"done","revision":1}}"#))
        let thread = try XCTUnwrap(ServerModelV2Projection.cachedState(store.snapshot, identity: identity).conversations[key("i")])
        XCTAssertEqual(thread.turns.first?.kind, .result)
        XCTAssertEqual(thread.turns.first?.resultStatus?.rawValue, "done")
    }

    func testTheStoreAcceptsTheProjectionThroughItsExistingRestorePath() throws {
        let model = try store([
            V2Fixture.item("i", rev: 1, rankKey: "a", extra: #""created_at_ms":100"#),
            V2Fixture.item("j", rev: 2, rankKey: "b", terminal: #"{"state":"expired","at_ms":3}"#,
                           extra: #""created_at_ms":200"#)
        ]).snapshot
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try repository.restoreCachedServerState(ServerModelV2Projection.cachedState(model, identity: identity),
                                                context: context)
        let snapshot = try repository.snapshot(context: context)
        XCTAssertEqual(Set(snapshot.requests.keys.map(\.messageID.rawValue)), ["i", "j"])
        XCTAssertEqual(snapshot.remoteStates[key("j")]?.state, .expired)
        XCTAssertEqual(snapshot.inboxView?.entries.count, 2)
    }
}
