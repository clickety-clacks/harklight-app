import AttentionDomain
import XCTest
@testable import Harklight

final class ReplyItemAreaTests: XCTestCase {
    private let baselineDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func parent(_ id: String, account: String = "account") -> RequestKey {
        RequestKey(accountScope: ExactText(account),
                   senderID: ExactText("sender"),
                   messageID: ExactText(id))
    }

    private func reply(_ parentID: String, turn: String, sequence: UInt64? = nil,
                       seen: Bool = false, account: String = "account",
                       text: String = "Reply text") -> ReplyItemObservation {
        ReplyItemObservation(parent: parent(parentID, account: account),
                             turnID: ExactText(turn),
                             conversationSequence: sequence,
                             isSeen: seen, text: text)
    }

    func testExistingRepliesAreBaselineAndSeenOnReceiptDoesNotEnter() {
        var ledger = ReplyItemLedger()
        let existing = [reply("message", turn: "reply-1", sequence: 1)]
        ledger.reconcile(existing, now: baselineDate)
        XCTAssertTrue(ledger.entries.isEmpty,
                      "Replies already on the device at first run are history, not arrivals.")

        let readBeforeFetch = reply("message", turn: "reply-2", sequence: 2, seen: true)
        ledger.reconcile(existing + [readBeforeFetch], now: baselineDate.addingTimeInterval(1))
        XCTAssertTrue(ledger.entries.isEmpty,
                      "A reply the read position already covers never enters.")

        let arrival = reply("message", turn: "reply-3", sequence: 3, text: "Newest words")
        let arrivedAt = baselineDate.addingTimeInterval(2)
        ledger.reconcile(existing + [readBeforeFetch, arrival], now: arrivedAt)
        let entry = ledger.entries.first
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(entry?.parent, parent("message"))
        XCTAssertEqual(entry?.unseenCount, 1)
        XCTAssertEqual(entry?.newestUnseenReply?.text, "Newest words")
        XCTAssertEqual(entry?.receivedAt, arrivedAt)
    }

    func testEmptyFirstSnapshotEstablishesBaselinePerAccount() {
        var ledger = ReplyItemLedger()
        let account = ExactText("account")
        ledger.reconcile([], accountScopes: [account], now: baselineDate)

        let first = reply("message", turn: "reply-1", sequence: 1)
        ledger.reconcile([first], accountScopes: [account],
                         now: baselineDate.addingTimeInterval(1))
        XCTAssertEqual(ledger.entries.map(\.parent), [first.parent],
                       "An empty first snapshot must not turn the first later reply into history.")

        let laterAccountHistory = reply("other-message", turn: "reply-9",
                                        sequence: 9, account: "second")
        ledger.reconcile([first, laterAccountHistory],
                         accountScopes: [account, ExactText("second")],
                         now: baselineDate.addingTimeInterval(2))
        XCTAssertEqual(ledger.entries.map(\.parent), [first.parent],
                       "An account first observed later starts with its current replies as baseline.")
    }

    func testJoiningReplyRedatesTheItemAndRestartsItsVisibleClock() {
        var ledger = ReplyItemLedger()
        ledger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        let first = reply("message", turn: "reply-1", sequence: 1, text: "First")
        ledger.reconcile([first], now: baselineDate.addingTimeInterval(1))
        ledger.markFirstSeen(parent("message"), at: baselineDate.addingTimeInterval(2))
        XCTAssertNotNil(ledger.entries.first?.firstSeenAt)

        let second = reply("message", turn: "reply-2", sequence: 2, text: "Second")
        let joinedAt = baselineDate.addingTimeInterval(3)
        ledger.reconcile([first, second], now: joinedAt)

        let entry = ledger.entries.first
        XCTAssertEqual(ledger.entries.count, 1, "Replies to one parent share one item.")
        XCTAssertEqual(entry?.unseenCount, 2)
        XCTAssertEqual(entry?.earliestUnseenReply?.turnID, ExactText("reply-1"))
        XCTAssertEqual(entry?.newestUnseenReply?.text, "Second")
        XCTAssertEqual(entry?.receivedAt, joinedAt,
                       "A joining reply moves the item to the newest-received position.")
        XCTAssertNil(entry?.firstSeenAt,
                     "A joining reply restarts the item's visible-time clock.")
    }

    func testAdvancedReadPositionDropsSeenRepliesAndALeftItemNeverReenters() {
        var ledger = ReplyItemLedger()
        ledger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        let first = reply("message", turn: "reply-1", sequence: 1, text: "First")
        let second = reply("message", turn: "reply-2", sequence: 2, text: "Second")
        ledger.reconcile([first, second], now: baselineDate.addingTimeInterval(1))
        XCTAssertEqual(ledger.entries.first?.unseenCount, 2)

        // The account's read position, advanced here or on another device,
        // covers the first reply only.
        let firstSeen = reply("message", turn: "reply-1", sequence: 1, seen: true, text: "First")
        ledger.reconcile([firstSeen, second], now: baselineDate.addingTimeInterval(2))
        XCTAssertEqual(ledger.entries.first?.unseenReplies.map(\.turnID), [ExactText("reply-2")],
                       "Only replies past the read position stay in the item.")

        let secondSeen = reply("message", turn: "reply-2", sequence: 2, seen: true, text: "Second")
        ledger.reconcile([firstSeen, secondSeen], now: baselineDate.addingTimeInterval(3))
        XCTAssertTrue(ledger.entries.isEmpty,
                      "An item with nothing left unseen leaves the area.")

        ledger.reconcile([first, second], now: baselineDate.addingTimeInterval(4))
        XCTAssertTrue(ledger.entries.isEmpty,
                      "A left item never re-enters on replay of the same replies.")

        let third = reply("message", turn: "reply-3", sequence: 3, text: "Third")
        ledger.reconcile([firstSeen, secondSeen, third], now: baselineDate.addingTimeInterval(5))
        XCTAssertEqual(ledger.entries.first?.unseenReplies.map(\.turnID), [ExactText("reply-3")],
                       "A genuinely new reply on the same parent enters as a fresh item.")
    }

    func testFirstSeenPersistsAndExpiresAtOneHourWithoutReentry() throws {
        var ledger = ReplyItemLedger()
        ledger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        let arrival = reply("message", turn: "reply-1", sequence: 1)
        ledger.reconcile([arrival], now: baselineDate.addingTimeInterval(10))
        XCTAssertNil(ledger.entries.first?.firstSeenAt,
                     "Receiving an item does not start its visible-time clock.")

        let firstSeen = baselineDate.addingTimeInterval(20)
        ledger.markFirstSeen(parent("message"), at: firstSeen)
        XCTAssertEqual(ledger.nextExpiry, firstSeen.addingTimeInterval(3_600))

        var restored = try JSONDecoder().decode(ReplyItemLedger.self,
                                                from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.entries.first?.firstSeenAt, firstSeen)

        XCTAssertFalse(restored.pruneExpired(now: firstSeen.addingTimeInterval(3_599)))
        XCTAssertTrue(restored.pruneExpired(now: firstSeen.addingTimeInterval(3_600)))
        XCTAssertTrue(restored.entries.isEmpty)

        restored.reconcile([arrival], now: firstSeen.addingTimeInterval(3_601))
        XCTAssertTrue(restored.entries.isEmpty,
                      "An expired item remains known and cannot re-enter on replay.")
    }

    func testEntriesOrderNewestReceivedFirst() {
        var ledger = ReplyItemLedger()
        ledger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        let older = reply("older-parent", turn: "reply-1", sequence: 1)
        ledger.reconcile([older], now: baselineDate.addingTimeInterval(1))
        let newer = reply("newer-parent", turn: "reply-2", sequence: 2)
        ledger.reconcile([older, newer], now: baselineDate.addingTimeInterval(2))
        XCTAssertEqual(ledger.entries.map(\.parent),
                       [parent("newer-parent"), parent("older-parent")])
    }

    @MainActor
    func testStorePersistsEntriesInTheLocalDefaultsDomain() throws {
        let suite = "ReplyItemAreaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let receivedAt = baselineDate.addingTimeInterval(1)
        let firstSeenAt = baselineDate.addingTimeInterval(2)

        let store = ReplyItemAreaStore(defaults: defaults)
        store.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        store.reconcile([reply("message", turn: "reply-1", sequence: 1, text: "Saved")],
                        now: receivedAt)
        store.markFirstSeen(parent("message"), at: firstSeenAt)

        let restored = ReplyItemAreaStore(defaults: defaults)
        XCTAssertEqual(restored.entries.first?.parent, parent("message"))
        XCTAssertEqual(restored.entries.first?.receivedAt, receivedAt)
        XCTAssertEqual(restored.entries.first?.firstSeenAt, firstSeenAt)
        XCTAssertEqual(restored.entries.first?.newestUnseenReply?.text, "Saved")
        XCTAssertEqual(restored.nextExpiry, firstSeenAt.addingTimeInterval(3_600))
    }

    func testMergedRowsAreNewestFirstWithTiesGoingToTheMessage() {
        func at(_ offset: TimeInterval) -> Date { baselineDate.addingTimeInterval(offset) }
        let messages: [(String, Date)] = [("message-30", at(30)), ("message-10", at(10))]
        let replies: [(String, Date)] = [("reply-20", at(20)), ("reply-10", at(10)),
                                         ("reply-5", at(5))]

        let merged = NewMessageAreaRowOrder.merged(
            messages: messages, replies: replies,
            messageDate: { $0.1 }, replyDate: { $0.1 },
            message: { $0.0 }, reply: { $0.0 })
        XCTAssertEqual(merged, ["message-30", "reply-20", "message-10", "reply-10", "reply-5"],
                       "One newest-first order; a same-moment pair keeps the message first.")

        XCTAssertEqual(NewMessageAreaRowOrder.merged(
            messages: [(String, Date)](), replies: replies,
            messageDate: { $0.1 }, replyDate: { $0.1 },
            message: { $0.0 }, reply: { $0.0 }), ["reply-20", "reply-10", "reply-5"])
        XCTAssertEqual(NewMessageAreaRowOrder.merged(
            messages: messages, replies: [(String, Date)](),
            messageDate: { $0.1 }, replyDate: { $0.1 },
            message: { $0.0 }, reply: { $0.0 }), ["message-30", "message-10"])
    }

    func testInboxReplyScoresComeFromTheViewAndSurviveTheParentResolving() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"),
                                       deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("agent"), messageID: ExactText("parent"))
        let other = RequestKey(accountScope: identity.personID,
                               senderID: ExactText("agent"), messageID: ExactText("other"))
        let payload = try JSONValue.parse(Data(#"{"title":"Parent","answer_ui":null}"#.utf8))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)),
            context: context)
        try store.setInboxView(InboxView(revision: ExactText("view-1"), entries: [
            InboxViewEntry(key: key, score: 0.4)
        ], replies: [
            InboxViewReply(key: key, conversationSequence: 7, score: 0.93),
            InboxViewReply(key: key, conversationSequence: 9),
            InboxViewReply(key: other, conversationSequence: 7, score: 0.5)
        ]), context: context)

        let port = AttentionDomainPort(store: store)
        let presented = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(presented.inboxReplyScores, [7: 0.93],
                       "Scores keep their sequence, skip unscored replies and never cross parents.")

        try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil)),
                        context: context)
        let resolved = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertNil(resolved.inboxScore,
                     "Row-level view fields stay gated to open or pending requests.")
        XCTAssertEqual(resolved.inboxReplyScores, [7: 0.93],
                       "A reply item can outlive its parent's open state, so its scores survive.")
    }
}
