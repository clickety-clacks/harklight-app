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
        let store = try store([
            V2Fixture.item("late", rev: 1, rankKey: "a", extra: #""created_at_ms":200"#),
            V2Fixture.item("early", rev: 2, rankKey: "b", extra: #""created_at_ms":100"#)
        ])
        let cached = ServerModelV2Projection.cachedState(store.snapshot, identity: identity)
        XCTAssertEqual(cached.requests[key("early")]?.acceptanceOrder, 1, "Arrival order follows created_at_ms.")
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
                chat: #"{"available":true,"started":true,"unread_replies":2,"reply_group":"earlier_chat_replies","reply_rank_key":"a5"}"#)
                .replacingOccurrences(of: #""section":"current"}"#, with: #""section":"current","group":"common"}"#),
            V2Fixture.item("older", rev: 2, rankKey: "a3")
                .replacingOccurrences(of: #""section":"current"}"#, with: #""section":"current","group":"earlier_messages"}"#),
            V2Fixture.item("done", rev: 3, rankKey: "b0", section: "resolved")
        ])
        let view = try XCTUnwrap(ServerModelV2Projection.cachedState(store.snapshot, identity: identity).inboxView)
        let rows = try XCTUnwrap(view.listItems)
        XCTAssertEqual(rows.map { "\($0.kind.rawValue):\($0.key.messageID.rawValue)" },
                       ["message:current", "message:older", "reply:current", "message:done"],
                       "The reply row sorts by reply_rank_key among item rows.")
        XCTAssertEqual(rows.map(\.freeSection?.group), [.common, .earlierMessages, .earlierChatReplies, .common])
        XCTAssertEqual(rows.last?.freeSection?.state, .history, "Resolved items are drawn under History.")
        XCTAssertEqual(rows[2].unseenCount, 2)
        XCTAssertEqual(view.freeOrderVersion, 1)
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
