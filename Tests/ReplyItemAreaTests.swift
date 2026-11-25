import AttentionDomain
import HarklightNativeRelay
import XCTest
@testable import Harklight

final class ReplyItemAreaTests: XCTestCase {
    @MainActor
    func testUnreadLocalQuoteStaysInNormalListWithoutDuplicatingAServerReply() {
        let parent = RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                                messageID: ExactText("parent"))
        let local = ReplyItemEntry(parent: parent, unseenReplies: [
            ReplyItemUnseenReply(turnID: ExactText("first"), conversationSequence: 4, text: "First"),
            ReplyItemUnseenReply(turnID: ExactText("latest"), conversationSequence: 5, text: "Latest")
        ], receivedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(local.reference.conversationSequence, 5)
        XCTAssertEqual(local.reference.openAtConversationSequence, 4)
        XCTAssertEqual(local.reference.unseenCount, 2)
        for order: InboxOrder in [.priority, .posted] {
            let old = InboxNormalListProjection.entries(rows: [], serverItems: nil, in: .inbox,
                search: "", order: order, localReplies: [local.reference])
            XCTAssertEqual(old.map(\.id), [.reply(parent)])
            let current = InboxNormalListProjection.entries(rows: [], serverItems: [local.reference],
                in: .inbox, search: "", order: order, localReplies: [local.reference])
            XCTAssertEqual(current.map(\.id), [.reply(parent)])
        }
    }

    private func reopenWithServerCache(_ source: ClientRepository, context: ProfileContext,
                                       persistence: MemoryPendingActionPersistence) async throws -> ClientRepository {
        let inbox = try source.snapshot(context: context)
        let conversations = try source.conversationSnapshot(context: context)
        let serverThreads = conversations.threads.mapValues { original in
            var thread = original
            thread.drafts.removeAll()
            thread.answerDrafts = nil
            thread.uploadGroups = nil
            thread.uploadCleanups = nil
            thread.queuedMessages = nil
            if conversations.chatReadPositionSupport == true {
                thread.accountReadThroughConversationSequence =
                    conversations.chatReadPositions?[thread.request] ?? 0
            }
            return thread
        }
        let restored = try ClientRepository(context: context, persistence: persistence)
        try restored.restoreCachedServerState(CachedAttentionServerState(
            identity: context.identity, requests: inbox.requests, remoteStates: inbox.remoteStates,
            cursor: inbox.cursor, conversationCursor: conversations.cursor, conversations: serverThreads,
            inboxView: inbox.inboxView, currentRequestKeys: inbox.inboxCurrentKeys,
            chatReadPositions: conversations.chatReadPositions, pendingRelayOverlays: inbox.pendingRelayOverlays,
            inboxReferences: inbox.inboxReferences, conversationEvents: conversations.heldEvents,
            priorityLevels: inbox.priorityLevels.confirmedLevels), context: context)
        return restored
    }
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

    func testJoiningReplyRedatesTheItem() {
        var ledger = ReplyItemLedger()
        ledger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        let first = reply("message", turn: "reply-1", sequence: 1, text: "First")
        ledger.reconcile([first], now: baselineDate.addingTimeInterval(1))

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

    func testReadPositionReconciliationOnlyChangesTheViewedRequest() throws {
        var ledger = ReplyItemLedger()
        let account = ExactText("account")
        ledger.reconcile([], accountScopes: [account], now: baselineDate)

        let viewed = reply("viewed", turn: "reply-1", sequence: 1, text: "Viewed reply")
        let other = reply("other", turn: "reply-2", sequence: 2, text: "Other reply")
        ledger.reconcile([viewed, other], now: baselineDate.addingTimeInterval(1))
        let otherBeforeRead = try XCTUnwrap(ledger.entries.first { $0.parent == other.parent })

        let viewedAsRead = reply("viewed", turn: "reply-1", sequence: 1,
                                 seen: true, text: "Viewed reply")
        ledger.reconcile([viewedAsRead], accountScopes: [account],
                         parentScope: [viewed.parent],
                         now: baselineDate.addingTimeInterval(2))

        XCTAssertNil(ledger.entries.first { $0.parent == viewed.parent })
        XCTAssertEqual(ledger.entries.first { $0.parent == other.parent }, otherBeforeRead,
                       "Reading one conversation must leave another conversation's unread replies unchanged.")
    }

    @MainActor
    func testOfflineUnreadReplyStaysInBothNormalOrdersAfterAnHour() throws {
        let suite = "ReplyItemAreaUpgrade.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let arrival = reply("message", turn: "reply-1", sequence: 1, text: "Still unread")
        let receivedAt = baselineDate.addingTimeInterval(10)
        let firstVisible = receivedAt.addingTimeInterval(10)
        var ledger = ReplyItemLedger()
        ledger.reconcile([], accountScopes: [arrival.accountScope], now: baselineDate)
        ledger.reconcile([arrival], now: receivedAt)

        // Older builds stored visibility independently of the chat read receipt.
        let encoded = try JSONEncoder().encode(ledger)
        var oldLedger = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var rows = try XCTUnwrap(oldLedger["entriesByParent"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        rows[1]["firstSeenAt"] = firstVisible.timeIntervalSinceReferenceDate
        oldLedger["entriesByParent"] = rows
        defaults.set(try JSONSerialization.data(withJSONObject: oldLedger), forKey: ReplyItemAreaStore.defaultsKey)

        let offline = ReplyItemAreaStore(defaults: defaults)
        XCTAssertEqual(offline.entries.first?.newestUnseenReply?.turnID, arrival.turnID)
        offline.reconcile([arrival], now: firstVisible.addingTimeInterval(3_601))

        for order: InboxOrder in [.priority, .posted] {
            let entries = InboxNormalListProjection.entries(rows: [], serverItems: [],
                in: .inbox, search: "", order: order, localReplies: offline.entries.map(\.reference))
            XCTAssertEqual(entries.map(\.id), [.reply(arrival.parent)], order.rawValue)
        }
        XCTAssertEqual(offline.entries.first?.receivedAt, receivedAt)
        XCTAssertEqual(offline.entries.first?.newestUnseenReply?.text, arrival.text)

        offline.reconcile([reply("message", turn: "reply-1", sequence: 1, seen: true)],
                          now: firstVisible.addingTimeInterval(3_602))
        XCTAssertTrue(offline.entries.isEmpty, "A chat read receipt removes the local fallback.")
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
    func testStorePersistsEntriesInTheLocalDefaultsDomain() async throws {
        let suite = "ReplyItemAreaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let receivedAt = baselineDate.addingTimeInterval(1)

        let store = ReplyItemAreaStore(defaults: defaults)
        store.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        store.reconcile([reply("message", turn: "reply-1", sequence: 1, text: "Saved")],
                        now: receivedAt)

        await waitUntil {
            guard let data = defaults.data(forKey: ReplyItemAreaStore.defaultsKey),
                  let ledger = try? JSONDecoder().decode(ReplyItemLedger.self, from: data) else {
                return false
            }
            return ledger.entriesByParent[parent("message")]?.receivedAt == receivedAt
        }
        let restored = ReplyItemAreaStore(defaults: defaults)
        XCTAssertEqual(restored.entries.first?.parent, parent("message"))
        XCTAssertEqual(restored.entries.first?.receivedAt, receivedAt)
        XCTAssertEqual(restored.entries.first?.newestUnseenReply?.text, "Saved")
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The reply ledger was not persisted.")
    }

    func testNormalReplyProjectionUsesServerQuoteAndOpenTargets() throws {
        let key = parent("message")
        func turn(_ id: String, sequence: UInt64, text: String) -> ConversationTurn {
            ConversationTurn(id: ExactText(id),
                binding: ConversationBinding(request: key, revision: 1),
                author: .origin, sessionHandle: ExactText("session"),
                text: ExactText(text), kind: .reply, conversationSequence: sequence)
        }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: key.accountScope,
                                       deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context,
                                             persistence: MemoryPendingActionPersistence())
        let binding = ConversationBinding(request: key, revision: 1)
        let session = ExactText("session")
        try store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: session, payload: .null)), context: context)
        let discussion = ConversationTurn(id: ExactText("question"), binding: binding,
            author: .person, sessionHandle: session, text: ExactText("Question"),
            kind: .discussion, conversationSequence: 2)
        try store.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(discussion)), context: context)
        let earliest = ConversationTurn(id: ExactText("reply-7"), binding: binding,
            author: .origin, sessionHandle: session, text: ExactText("Earliest unseen"),
            inReplyTo: discussion.id, kind: .reply, conversationSequence: 3)
        let quote = ConversationTurn(id: ExactText("reply-9"), binding: binding,
            author: .origin, sessionHandle: session, text: ExactText("Newest quote"),
            inReplyTo: discussion.id, kind: .reply, conversationSequence: 4)
        try store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .turn(earliest)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 4, binding: binding,
            fact: .turn(quote)), context: context)
        var thread = try XCTUnwrap(store.conversationSnapshot(context: context).threads[key])
        XCTAssertEqual(thread.turns.map(\.id.rawValue), ["question", "reply-7", "reply-9"])
        XCTAssertEqual(thread.turns.compactMap(\.conversationSequence), [2, 3, 4])
        thread.facts[quote.id] = ConversationTurnFacts(
            acceptedAtMilliseconds: 1_800_000_123_000)

        let active = InboxViewListItem(kind: .reply, key: key,
            conversationSequence: 4, openAtConversationSequence: 3,
            unseenCount: 2, score: 0.9, scoreKind: .current)
        let activeRow = ReplyItemNormalRowProjection.resolve(active, in: thread)
        XCTAssertEqual(activeRow?.quotedReply.text, ExactText("Newest quote"))
        XCTAssertEqual(activeRow?.openTargetTurnID, ExactText("reply-7"))
        XCTAssertNil(activeRow?.receivedAt,
                     "A discussion acceptance time is not a receipt time for an agent reply.")
        var liveThread = thread
        liveThread.facts[quote.id] = ConversationTurnFacts(
            localLiveArrivalAtMilliseconds: 1_800_000_456_000)
        XCTAssertEqual(ReplyItemNormalRowProjection.resolve(active, in: liveThread)?.receivedAt,
                       Date(timeIntervalSince1970: 1_800_000_456),
                       "The retained local live-arrival fact supplies the reply time.")

        let historical = InboxViewListItem(kind: .reply, key: key,
            conversationSequence: 4, openAtConversationSequence: 4,
            unseenCount: 0, score: 0.9, scoreKind: .historical)
        let historicalRow = ReplyItemNormalRowProjection.resolve(historical, in: thread)
        XCTAssertEqual(historicalRow?.openTargetTurnID, ExactText("reply-9"),
                       "All-seen groups open at the newest reply they quote.")
        XCTAssertNil(ReplyItemNormalRowProjection.resolve(active, in: nil),
                     "The client waits for existing conversation content instead of fabricating a quote.")
    }

    func testLiveReplyReceiptTimeIsRetainedOnceAndHistoryHasNoTime() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"),
                                       deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryPendingActionPersistence()
        let store = try ClientRepository(context: context, persistence: persistence)
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("sender"),
                             messageID: ExactText("receipt-time"))
        let binding = ConversationBinding(request: key, revision: 1)
        let session = ExactText("origin-session")
        try store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: session, payload: .null)), context: context)

        let discussion = ConversationTurn(id: ExactText("person-turn"), binding: binding,
            author: .person, sessionHandle: session, text: ExactText("Question"),
            kind: .discussion, conversationSequence: 2)
        try store.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(discussion)), context: context)

        let liveReply = ConversationTurn(id: ExactText("live-reply"), binding: binding,
            author: .origin, sessionHandle: session, text: ExactText("Answer"),
            inReplyTo: discussion.id, kind: .reply, conversationSequence: 3)
        let liveEvent = ConversationEvent(sequence: 3, binding: binding, fact: .turn(liveReply))
        try store.applyConversation(liveEvent, context: context,
                                    locallyReceivedAtMilliseconds: 1_800_000_123_000)
        try store.applyConversation(liveEvent, context: context,
                                    locallyReceivedAtMilliseconds: 1_800_000_456_000)
        let liveFacts = try XCTUnwrap(store.conversationSnapshot(context: context)
            .threads[key]?.facts[liveReply.id])
        XCTAssertEqual(liveFacts.localLiveArrivalAtMilliseconds, 1_800_000_123_000,
                       "A duplicate stream event cannot replace the receipt time recorded at first application.")

        let historyReply = ConversationTurn(id: ExactText("history-reply"), binding: binding,
            author: .origin, sessionHandle: session, text: ExactText("Fetched history"),
            inReplyTo: discussion.id, kind: .reply, conversationSequence: 4)
        try store.applyConversation(ConversationEvent(sequence: 4, binding: binding,
            fact: .turn(historyReply)), context: context)
        let personTurn = ConversationTurn(id: ExactText("person-turn-5"), binding: binding,
            author: .person, sessionHandle: session, text: ExactText("Follow-up"),
            kind: .discussion, conversationSequence: 5)
        try store.applyConversation(ConversationEvent(sequence: 5, binding: binding,
            fact: .turn(personTurn)), context: context,
            locallyReceivedAtMilliseconds: 1_800_000_789_000)
        let restored = try await reopenWithServerCache(store, context: context, persistence: persistence)
        let snapshot = try restored.conversationSnapshot(context: context)
        XCTAssertEqual(snapshot.threads[key]?.facts[liveReply.id]?.localLiveArrivalAtMilliseconds,
                       1_800_000_123_000,
                       "The local reply receipt survives an app-store reload.")
        XCTAssertNil(snapshot.threads[key]?.facts[historyReply.id]?.localLiveArrivalAtMilliseconds,
                     "History applied without a live receipt timestamp stays unknown.")
        XCTAssertNil(snapshot.threads[key]?.facts[personTurn.id]?.localLiveArrivalAtMilliseconds,
                     "The local reply receipt field is limited to origin replies.")
    }

    @MainActor
    func testNewReplyPriorityFlowsFromServerViewThroughLiveInboxRow() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("reply-priority"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("parent"))
        let payload = try JSONValue.parse(Data(#"{"title":"Parent","urgency":"low"}"#.utf8))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let entry = ReplyItemEntry(parent: key, unseenReplies: [
            ReplyItemUnseenReply(turnID: ExactText("reply"), conversationSequence: 7, text: "Update")
        ], receivedAt: baselineDate)
        for (algorithm, basis) in [("baseline", "selected"), ("jev-set", "fallback")] {
            try store.setInboxView(InboxView(revision: ExactText(algorithm),
                algorithm: ExactText(algorithm), basis: ExactText(basis), entries: [],
                replies: [InboxViewReply(key: key, conversationSequence: 7, priority: .now)],
                listItems: [InboxViewListItem(kind: .reply, key: key, conversationSequence: 7,
                    openAtConversationSequence: 7, unseenCount: 1, scoreKind: .current)]), context: context)
            let live = try LivePresentationStore(store: store, context: context)
            let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
            XCTAssertEqual(row.inboxReplyPriorities, [7: .now])
            XCTAssertTrue(row.inboxReplyScores.isEmpty)
            let reference = try XCTUnwrap(live.presentation.inboxViewListItems?.first)
            XCTAssertEqual(ReplyItemPriorityProjection.display(for: reference,
                perReplyPriorities: row.inboxReplyPriorities), .urgent)
            XCTAssertEqual(ReplyItemPriorityProjection.display(for: entry,
                perReplyScores: row.inboxReplyScores, perReplyPriorities: row.inboxReplyPriorities,
                serverListItems: live.presentation.inboxViewListItems), .urgent)
        }
        try store.setInboxView(InboxView(revision: ExactText("both"), entries: [], replies: [
            InboxViewReply(key: key, conversationSequence: 7, priority: .now, score: 0.50)
        ]), context: context)
        let live = try LivePresentationStore(store: store, context: context)
        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertEqual(row.inboxReplyPriorities, [7: .now])
        XCTAssertEqual(row.inboxReplyScores, [7: 0.50])
        XCTAssertNil(ReplyItemPriorityProjection.display(for: entry,
            perReplyScores: row.inboxReplyScores, perReplyPriorities: row.inboxReplyPriorities,
            serverListItems: live.presentation.inboxViewListItems),
            "A usable Normal score wins over an Urgent reply priority.")
    }

    func testNormalReplyPriorityUsesOnlyActiveGroupMetadataAndRetainedHistoryScore() {
        let key = parent("priority")
        func group(_ score: Double? = nil, historical: Bool = false) -> InboxViewListItem {
            InboxViewListItem(kind: .reply, key: key, conversationSequence: 9,
                openAtConversationSequence: historical ? 9 : 7, unseenCount: historical ? 0 : 2,
                score: score, scoreKind: score == nil ? nil : historical ? .historical : .current)
        }
        for (priority, display) in [(InboxMessagePriority.now, InboxPriorityDisplay.urgent),
                                    (.high, .high), (.low, .low)] {
            XCTAssertEqual(ReplyItemPriorityProjection.display(for: group(),
                perReplyPriorities: [6: .now, 7: priority, 9: .low, 10: .now]), display)
        }
        XCTAssertNil(ReplyItemPriorityProjection.display(for: group(),
            perReplyPriorities: [7: .normal, 9: .low]))
        XCTAssertNil(ReplyItemPriorityProjection.display(for: group(0.5),
            perReplyPriorities: [7: .now]))
        XCTAssertEqual(ReplyItemPriorityProjection.display(for: group(0.93, historical: true),
            perReplyPriorities: [7: .low]), .urgent)
        XCTAssertNil(ReplyItemPriorityProjection.display(for: group(historical: true),
            perReplyPriorities: [9: .now]), "Current metadata cannot supply a historical priority.")
        XCTAssertNil(ReplyItemPriorityProjection.display(for: group(), perReplyPriorities: [:]))
    }

    func testNewReplyPriorityUsesServerGroupScoreOrLegacyReplyMaximum() throws {
        var ledger = ReplyItemLedger()
        ledger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        let older = reply("message", turn: "reply-1", sequence: 1)
        let newer = reply("message", turn: "reply-2", sequence: 2)
        ledger.reconcile([older, newer], now: baselineDate.addingTimeInterval(1))
        let entry = try XCTUnwrap(ledger.entries.first)

        XCTAssertEqual(ReplyItemPriorityProjection.score(for: entry,
            perReplyScores: [1: 0.93, 2: 0.4], serverListItems: nil), 0.93,
            "Legacy fallback uses the highest available unseen score, not the newest reply's score.")

        let reference = InboxViewListItem(kind: .reply, key: entry.parent,
            conversationSequence: 2, openAtConversationSequence: 1,
            unseenCount: 2, score: 0.82, scoreKind: .current)
        XCTAssertEqual(ReplyItemPriorityProjection.score(for: entry,
            perReplyScores: [1: 0.93, 2: 0.4], serverListItems: [reference]), 0.82,
            "The server group score is authoritative when list_items is supported.")
        XCTAssertNil(ReplyItemPriorityProjection.score(for: entry,
            perReplyScores: [1: 0.93, 2: 0.4], serverListItems: []),
            "A supported projection with no reply row does not borrow per-reply scores.")
    }

    func testInboxReplyScoresComeFromTheViewAndSurviveTheParentResolving() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"),
                                       deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context,
                                             persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("agent"), messageID: ExactText("parent"))
        let other = RequestKey(accountScope: identity.personID,
                               senderID: ExactText("agent"), messageID: ExactText("other"))
        let payload = try JSONValue.parse(Data(#"{"title":"Parent","answer_ui":null}"#.utf8))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)),
            context: context)
        let listItems = [
            InboxViewListItem(kind: .reply, key: key,
                conversationSequence: 9, openAtConversationSequence: 7,
                unseenCount: 2, score: 0.93, scoreKind: .current),
            InboxViewListItem(kind: .message, key: key)
        ]
        try store.setInboxView(InboxView(revision: ExactText("view-1"), entries: [
            InboxViewEntry(key: key, score: 0.4)
        ], replies: [
            InboxViewReply(key: key, conversationSequence: 7, score: 0.93),
            InboxViewReply(key: key, conversationSequence: 9),
            InboxViewReply(key: other, conversationSequence: 7, score: 0.5)
        ], listItems: listItems), context: context)

        let port = AttentionDomainPort(store: store)
        let snapshot = try port.observe(context: port.context)
        let presented = try XCTUnwrap(snapshot.requests.first)
        XCTAssertEqual(snapshot.inboxViewListItems, listItems)
        XCTAssertEqual(try port.inspect(context: port.context, request: key).inboxViewListItems,
                       listItems, "Detail filtering keeps the account-wide normal order available to its list.")
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
