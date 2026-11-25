import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest
@testable import Harklight

final class InboxFreeOrderTests: XCTestCase {
    func testDelayedThreadSortScrollIsAbandonedWhenLeavingAndReturning() throws {
        let child = InboxSelection.sample("thread-child")
        let target = InboxSortScrollTarget.thread(
            group: .init(tab: .inbox, selection: .sample("thread-first"), placement: .threadGroup),
            member: .init(tab: .inbox, selection: child))
        let current = InboxSortScrollState.Context(selection: child, search: "", tab: .inbox, order: .priority)
        let interruptions: [InboxSortScrollState.Context] = [
            .init(selection: .sample("next-row"), search: "", tab: .inbox, order: .priority),
            .init(selection: child, search: "filter", tab: .inbox, order: .priority),
            .init(selection: child, search: "", tab: .replied, order: .priority),
            .init(selection: child, search: "", tab: .inbox, order: .posted),
        ]
        var scroll = InboxSortScrollState()
        for interruption in interruptions {
            scroll.start(target, in: current)
            let delayed = try XCTUnwrap(scroll.pending)
            XCTAssertTrue(scroll.accepts(delayed, in: current))
            // The task or first-child callback can arrive before the view observes the change.
            XCTAssertFalse(scroll.accepts(delayed, in: interruption))
            scroll.contextDidChange(to: interruption)
            scroll.contextDidChange(to: current)
            XCTAssertNil(scroll.pending)
            XCTAssertFalse(scroll.accepts(delayed, in: current), "Returning must not revive \(interruption).")
        }

        scroll.start(target, in: current)
        let beforeDisappearance = try XCTUnwrap(scroll.pending)
        scroll.cancel()
        XCTAssertFalse(scroll.accepts(beforeDisappearance, in: current))
    }

    func testNewSortScrollRejectsAnEarlierCallbackEvenForTheSameThreadAndSelection() throws {
        let child = InboxSelection.sample("thread-child")
        let target = InboxSortScrollTarget.thread(
            group: .init(tab: .inbox, selection: .sample("thread-first"), placement: .threadGroup),
            member: .init(tab: .inbox, selection: child))
        let context = InboxSortScrollState.Context(selection: child, search: "", tab: .inbox, order: .priority)
        var scroll = InboxSortScrollState()
        scroll.start(target, in: context)
        let earlier = try XCTUnwrap(scroll.pending)

        scroll.start(target, in: context)
        let replacement = try XCTUnwrap(scroll.pending)
        XCTAssertFalse(scroll.accepts(earlier, in: context))
        XCTAssertTrue(scroll.accepts(replacement, in: context))
    }

    private static func reopenWithServerCache(_ source: ClientRepository, context: ProfileContext,
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
            inboxView: inbox.inboxView, currentRequestKeys: inbox.inboxCandidate?.currentKeys ?? inbox.inboxCurrentKeys,
            chatReadPositions: conversations.chatReadPositions, pendingRelayOverlays: inbox.pendingRelayOverlays,
            inboxReferences: inbox.inboxReferences, conversationEvents: conversations.heldEvents,
            priorityLevels: inbox.priorityLevels.confirmedLevels), context: context)
        return restored
    }
    private let context = ProfileContext(identity: ProfileIdentity(
        trustedRelayAuthority: ExactText("relay.example"),
        personID: ExactText("reader"), deviceID: ExactText("device")), transportMode: .relay)

    private func reference(_ id: String, kind: String = "message",
                           state: String = "active", group: String = "common") -> [String: Any] {
        var result: [String: Any] = [
            "kind": kind, "sender_id": "agent", "message_id": id,
            "free_section": ["state": state, "group": group]
        ]
        if kind == "reply" {
            result["conversation_seq"] = 900
            result["open_at_conversation_seq"] = 900
            result["unseen_count"] = state == "active" ? 1 : 0
        }
        return result
    }

    private func decode(_ items: [[String: Any]]?, version: Any? = 1,
                        revision: String = "view-1") throws -> InboxView {
        let references = items?.compactMap { item -> InboxViewListItem? in
            guard let id = item["message_id"] as? String, let sender = item["sender_id"] as? String,
                  let kind = (item["kind"] as? String).flatMap(InboxViewListItemKind.init(rawValue:)) else {
                return nil
            }
            let section = item["free_section"] as? [String: Any]
            let placement: InboxFreeSection?
            if let state = (section?["state"] as? String).flatMap(InboxFreeSection.State.init(rawValue:)),
               let group = (section?["group"] as? String).flatMap(InboxFreeSection.Group.init(rawValue:)) {
                placement = InboxFreeSection(state: state, group: group)
            } else {
                placement = nil
            }
            return InboxViewListItem(kind: kind, key: RequestKey(accountScope: context.identity.personID,
                senderID: ExactText(sender), messageID: ExactText(id)),
                conversationSequence: (item["conversation_seq"] as? Int).flatMap(UInt64.init(exactly:)),
                openAtConversationSequence: (item["open_at_conversation_seq"] as? Int).flatMap(UInt64.init(exactly:)),
                unseenCount: item["unseen_count"] as? Int, freeSection: placement)
        }
        // These fixtures stand in for a complete projection. If a reference
        // was dropped, the partial list must lose its ordering authority.
        let complete = references?.count == items?.count
        return InboxView(revision: ExactText(revision), entries: [], listItems: complete ? references : nil,
                         freeOrderVersion: complete ? version as? Int : nil)
    }

    private func supported(_ view: InboxView) -> Bool {
        InboxFreeOrder.isSupported(version: view.freeOrderVersion, items: view.listItems)
    }

    @MainActor
    private func rows(for view: InboxView) -> [InboxItem] {
        (view.listItems ?? []).filter { $0.kind == .message }.map { item in
            .request(InboxRequestRow(key: item.key, title: item.key.messageID.rawValue,
                sender: "Assistant", status: "", isResolved: item.freeSection?.state == .history,
                hasUserAction: item.freeSection?.state == .history,
                hasInboxViewEntry: true))
        }
    }

    @MainActor
    private func projection(_ view: InboxView, search: String = "") -> [InboxNormalListDisplayEntry] {
        InboxNormalListProjection.entries(rows: rows(for: view), serverItems: view.listItems,
            freeOrderVersion: view.freeOrderVersion, in: .inbox, search: search)
    }

    private func rowIDs(_ entries: [InboxNormalListDisplayEntry]) -> [InboxNormalListDisplayEntry.ID] {
        entries.compactMap { if case .heading = $0 { return nil }; return $0.id }
    }

    @MainActor
    func testPostedUsesAuthoredDatesWhenAnOlderSavedInboxIsReopenedOffline() async throws {
        let older = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("saved-older"))
        let newer = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("saved-newer"))
        let storedView = InboxView(revision: ExactText("saved"),
            entries: [.init(key: older, priority: .high), .init(key: newer, priority: .normal)],
            listItems: [.init(kind: .message, key: older), .init(kind: .message, key: newer)])
        let savedData = try JSONEncoder().encode(storedView)
        XCTAssertFalse(String(decoding: savedData, as: UTF8.self).contains("itemCreatedAtMilliseconds"))
        let savedView = try JSONDecoder().decode(InboxView.self, from: savedData)
        let model = ServerModelV2Store(fileURL: nil)
        let items = try [older, newer].enumerated().map { index, key in
            try APIItem(json: JSONValue.parse(Data(#"""
            {"item_id":"\#(key.messageID.rawValue)","rev":1,"sender":"agent","request_revision":1,
             "message":{"title":"Saved message","created_at":\#((index + 1) * 1000)},
             "files":[],"seen":false,"chat":{"started":false},"rank":{"key":"\#(index)","section":"current"}}
            """#.utf8)))
        }
        try model.rebaseline(items: items, counts: APICounts(unresolved: 2), position: 1)
        let cached = ServerModelV2Projection.cachedState(model.snapshot, identity: context.identity)
        let initial = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try initial.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: cached.requests, remoteStates: cached.remoteStates, cursor: 1, conversationCursor: 0,
            conversations: cached.conversations, inboxView: savedView,
            currentRequestKeys: cached.currentRequestKeys), context: context)
        let reopened = try await Self.reopenWithServerCache(initial, context: context,
            persistence: MemoryPendingActionPersistence())
        let presentation = try LivePresentationStore(disconnectedStore: reopened, context: context)
        let rows = presentation.inboxRows.map(InboxItem.request)
        let refs = try XCTUnwrap(presentation.presentation.inboxViewListItems)
        let priority = InboxNormalListProjection.entries(rows: rows, serverItems: refs, in: .inbox, search: "")
        let posted = InboxNormalListProjection.entries(rows: rows, serverItems: refs, in: .inbox, search: "", order: .posted)
        XCTAssertEqual(priority.map(\.id), [.message(.row(.request(older))), .message(.row(.request(newer)))])
        XCTAssertEqual(posted.map(\.id), [.message(.row(.request(newer))), .message(.row(.request(older)))])
    }

    @MainActor
    func testPostedWithoutServerListUsesAvailableDatesAndKeepsUndatedRowsLast() throws {
        let view = try decode([reference("older"), reference("undated-first"),
                               reference("newer"), reference("undated-second")], version: nil)
        let rows = rows(for: view).map { item -> InboxItem in
            guard case var .request(row) = item else { return item }
            switch row.title {
            case "older": row.createdAt = Date(timeIntervalSince1970: 100)
            case "newer": row.createdAt = Date(timeIntervalSince1970: 300)
            default: break
            }
            return .request(row)
        }
        let priority = InboxNormalListProjection.entries(rows: rows, serverItems: nil, in: .inbox, search: "")
        let posted = InboxNormalListProjection.entries(rows: rows, serverItems: nil, in: .inbox, search: "", order: .posted)
        XCTAssertEqual(posted.map(\.id), [priority[2].id, priority[0].id, priority[1].id, priority[3].id])
    }

    @MainActor
    func testPostedOrderKeepsEveryFreeOrderRowAndUsesOriginalTimes() throws {
        let view = try decode([
            reference("older"), reference("newer"), reference("same-time"),
            reference("authored-date", group: "earlier_messages"),
            reference("without-date", group: "earlier_messages"),
            reference("newest-reply", kind: "reply", group: "earlier_chat_replies"),
            reference("undated-reply", kind: "reply", group: "earlier_chat_replies_unknown"),
            reference("history", state: "history")
        ])
        let times = ["older": 100, "newer": 300, "same-time": 300, "history": 200]
        let rows = rows(for: view).map { item -> InboxItem in
            guard case var .request(row) = item else { return item }
            row.createdAt = switch row.title {
            case "without-date": nil
            case "authored-date": Date(timeIntervalSince1970: 350)
            default: Date(timeIntervalSince1970: 600)
            }
            row.serverPostedAt = times[row.key.messageID.rawValue].map {
                Date(timeIntervalSince1970: Double($0))
            }
            if ["older", "newer"].contains(row.key.messageID.rawValue) {
                row.thread = ExactText("same-thread")
            }
            return .request(row)
        }
        let references = try XCTUnwrap(view.listItems).map { item in
            guard item.key.messageID == ExactText("newest-reply") else { return item }
            return InboxViewListItem(kind: .reply, key: item.key,
                conversationSequence: item.conversationSequence,
                openAtConversationSequence: item.openAtConversationSequence,
                unseenCount: item.unseenCount, freeSection: item.freeSection,
                postedAtMilliseconds: 400_000)
        }
        let priority = InboxNormalListProjection.entries(rows: rows, serverItems: references,
            freeOrderVersion: 1, in: .inbox, search: "")
        let posted = InboxNormalListProjection.entries(rows: rows, serverItems: references,
            freeOrderVersion: 1, in: .inbox, search: "", order: .posted)
        func ids(_ entries: [InboxNormalListDisplayEntry]) -> [String] {
            entries.flatMap { entry -> [String] in
                switch entry {
                case let .message(message):
                    return message.members.compactMap {
                        guard case let .request(row) = $0 else { return nil }
                        return row.key.messageID.rawValue
                    }
                case let .reply(item): return [item.key.messageID.rawValue]
                case .heading: return []
                }
            }
        }

        XCTAssertGreaterThan(priority.count, rowIDs(priority).count)
        XCTAssertEqual(posted.count, rows.count + 2, "No member should vanish inside a thread or section.")
        XCTAssertEqual(ids(posted), ["newest-reply", "authored-date", "newer", "same-time",
                                     "history", "older", "without-date", "undated-reply"])
        XCTAssertEqual(Set(ids(posted)), Set(ids(priority)))
    }

    @MainActor
    func testPostedOrderKeepsNonFreeInboxMembershipAndSearch() throws {
        let view = try decode([
            reference("first"), reference("later"),
            reference("history", state: "history"),
            reference("unread-reply", kind: "reply"),
            reference("read-reply", kind: "reply", state: "history")
        ], version: nil)
        let rows = rows(for: view).map { item -> InboxItem in
            guard case var .request(row) = item else { return item }
            row.serverPostedAt = Date(timeIntervalSince1970: row.title == "later" ? 20 : 10)
            row.bodyText = "Shared search terms"
            return .request(row)
        }
        let priority = InboxNormalListProjection.entries(rows: rows, serverItems: view.listItems,
            in: .inbox, search: "")
        let posted = InboxNormalListProjection.entries(rows: rows, serverItems: view.listItems,
            in: .inbox, search: "", order: .posted)
        XCTAssertEqual(posted.map(\.id), [priority[1].id, priority[0].id, priority[2].id])
        let matches = InboxNormalListProjection.entries(rows: rows, serverItems: view.listItems,
            in: .inbox, search: "shared search", order: .posted)
        XCTAssertEqual(matches.map(\.id), Array(priority.prefix(2).map(\.id)))
        let replied = InboxNormalListProjection.entries(rows: rows, serverItems: view.listItems,
            in: .replied, search: "", order: .posted)
        let originalReplied = InboxNormalListProjection.entries(rows: rows, serverItems: view.listItems,
            in: .replied, search: "")
        XCTAssertEqual(replied.map(\.id), originalReplied.map(\.id))
    }

    @MainActor
    func testPostedOrderUsesTheLiveReplyQuotesServerTime() throws {
        let store = ServerModelV2Store(fileURL: nil)
        let original = #"{"item_id":"parent","rev":1,"sender":"agent","request_revision":1,"created_at_ms":100,"message":{"title":"Parent","created_at":999},"files":[],"seen":false,"chat":{"started":true,"last_origin_reply":"first","unread_replies":1,"reply_group":"earlier_chat_replies","reply_rank_key":"b"},"rank":{"key":"a","section":"current"}}"#
        let other = #"{"item_id":"other","rev":2,"sender":"agent","request_revision":1,"created_at_ms":200,"message":{"title":"Other"},"files":[],"seen":false,"chat":{"started":false},"rank":{"key":"c","section":"current"}}"#
        let first = #"{"entry_id":"first","item_id":"parent","rev":2,"position":1,"at_ms":150,"kind":"reply","author":"origin","request_revision":1,"text":"First reply","files":[]}"#
        let updated = #"{"item_id":"parent","rev":3,"sender":"agent","request_revision":1,"created_at_ms":100,"message":{"title":"Parent","created_at":999},"files":[],"seen":false,"chat":{"started":true,"last_origin_reply":"second","unread_replies":2,"reply_group":"earlier_chat_replies","reply_rank_key":"b"},"rank":{"key":"a","section":"current"}}"#
        let second = #"{"entry_id":"second","item_id":"parent","rev":4,"position":2,"at_ms":250,"kind":"reply","author":"origin","request_revision":1,"text":"Second reply","files":[]}"#
        func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }
        let items = try [original, other].map { try APIItem(json: json($0)) }
        try store.rebaseline(items: items, counts: APICounts(unresolved: 2), position: 2)
        try store.apply(APIEntriesPage(json: json(#"{"rev":2,"entries":[\#(first)],"older":false}"#)), of: ExactText("parent"))

        func posted() throws -> [InboxNormalListDisplayEntry.ID] {
            let cached = ServerModelV2Projection.cachedState(store.snapshot, identity: context.identity)
            let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
            try repository.restoreCachedServerState(cached, context: context)
            let presentation = try LivePresentationStore(store: repository, context: context)
            return InboxNormalListProjection.entries(rows: presentation.inboxRows.map(InboxItem.request),
                serverItems: presentation.presentation.inboxViewListItems,
                freeOrderVersion: presentation.presentation.inboxFreeOrderVersion,
                in: .inbox, search: "", order: .posted).map(\.id)
        }
        let parentKey = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("parent"))
        let otherKey = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("other"))
        XCTAssertEqual(try posted(), [.message(.row(.request(otherKey))),
                                      .reply(parentKey), .message(.row(.request(parentKey)))])

        try store.apply([
            .init(rev: 3, kind: "item", data: Data(updated.utf8)),
            .init(rev: 4, kind: "entry", data: Data(second.utf8))
        ], cursor: 4)
        XCTAssertEqual(try posted(), [.reply(parentKey), .message(.row(.request(otherKey))),
                                      .message(.row(.request(parentKey)))])
    }

    func testCompleteFreeSectionsPreserveExactServerSequenceAndRevision() throws {
        let view = try decode([
            reference("reply-first", kind: "reply"), reference("parent"),
            reference("legacy-parent", group: "earlier_messages"),
            reference("legacy-chat", kind: "reply", group: "earlier_chat_replies"),
            reference("unknown-chat", kind: "reply", group: "earlier_chat_replies_unknown"),
            reference("seen-chat", kind: "reply", state: "history"),
            reference("terminal", state: "history"),
            reference("legacy-terminal", state: "history", group: "earlier_messages"),
            reference("legacy-seen", kind: "reply", state: "history", group: "earlier_chat_replies"),
            reference("unknown-seen", kind: "reply", state: "history", group: "earlier_chat_replies_unknown")
        ])
        XCTAssertTrue(supported(view))
        XCTAssertEqual(view.revision, ExactText("view-1"))
        XCTAssertEqual(view.listItems?.map(\.key.messageID.rawValue), [
            "reply-first", "parent", "legacy-parent", "legacy-chat", "unknown-chat",
            "seen-chat", "terminal", "legacy-terminal", "legacy-seen", "unknown-seen"
        ])
        XCTAssertEqual(view.listItems?.last?.freeSection,
                       InboxFreeSection(state: .history, group: .earlierChatRepliesUnknown))
        XCTAssertEqual(try JSONDecoder().decode(InboxView.self,
            from: JSONEncoder().encode(view)), view)
    }

    func testMissingUnsupportedAndMalformedMetadataRetainsCompatibleReferences() throws {
        let versions: [Any?] = [nil, 2, "1", true]
        for version in versions {
            let view = try decode([reference("parent")], version: version)
            XCTAssertFalse(supported(view))
            XCTAssertEqual(view.listItems?.count, 1)
        }
        let badSections: [Any?] = [nil, NSNull(), "active", [:],
            ["state": "active"], ["group": "common"],
            ["state": "pending", "group": "common"],
            ["state": "active", "group": "future"]]
        for section in badSections {
            var bad = reference("parent")
            bad["free_section"] = section
            let view = try decode([reference("chat", kind: "reply"), bad])
            XCTAssertFalse(supported(view))
            XCTAssertEqual(view.listItems?.map(\.key.messageID.rawValue), ["chat", "parent"])
        }
    }

    func testWrongKindsAndSectionRegressionsRejectWholeFreeViewWithoutDroppingRows() throws {
        let cases = [
            [reference("wrong", kind: "reply", group: "earlier_messages")],
            [reference("wrong", group: "earlier_chat_replies")],
            [reference("wrong", group: "earlier_chat_replies_unknown")],
            [reference("terminal", state: "history"), reference("open")],
            [reference("old", group: "earlier_messages"), reference("new")],
            [reference("new"), reference("old", group: "earlier_messages"), reference("new-again")],
            [reference("unknown", kind: "reply", group: "earlier_chat_replies_unknown"),
             reference("verified", kind: "reply", group: "earlier_chat_replies")]
        ]
        for items in cases {
            let view = try decode(items)
            XCTAssertFalse(supported(view))
            XCTAssertEqual(view.listItems?.count, items.count)
        }
    }

    func testEmptyFreeViewIsSupportedButAbsentProjectionAndPartialDecodeAreNot() throws {
        XCTAssertTrue(supported(try decode([])))
        XCTAssertFalse(supported(try decode(nil)))
        XCTAssertFalse(supported(try decode([], version: nil)))
        let partial = try decode([reference("good"), reference("unknown", kind: "future")])
        XCTAssertFalse(supported(partial))
        XCTAssertNil(partial.listItems, "A partial Free list cannot remain the authority for compatible row membership.")
    }

    @MainActor
    func testPartialFreeReferencesPreserveLoadedMessageAndHistoryAccessAfterRestart() async throws {
        let persistence = MemoryPendingActionPersistence()
        let store = try ClientRepository(context: context, persistence: persistence)
        var loadedRows: [InboxItem] = []
        for (index, id) in ["valid", "omitted-open", "omitted-history"].enumerated() {
            let key = RequestKey(accountScope: context.identity.personID,
                senderID: ExactText("agent"), messageID: ExactText(id))
            let payload = try JSONValue.parse(Data("{\"title\":\"\(id)\"}".utf8))
            try store.apply(RelayEvent(sequence: UInt64(index + 1),
                body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
            loadedRows.append(.request(InboxRequestRow(key: key, title: id, sender: "Assistant", status: "",
                isResolved: id == "omitted-history", hasUserAction: id == "omitted-history")))
        }
        var malformedReply = reference("omitted-history", kind: "reply", state: "history")
        malformedReply.removeValue(forKey: "open_at_conversation_seq")
        let view = try decode([reference("valid"), reference("omitted-open", kind: "future"), malformedReply])
        try store.setInboxView(view, context: context)
        let restored = try await Self.reopenWithServerCache(store, context: context, persistence: persistence)
        let port = AttentionDomainPort(store: restored)
        let presentation = try port.observe(context: port.context)
        XCTAssertEqual(presentation.requests.count, 3)
        XCTAssertNil(presentation.inboxViewListItems)
        XCTAssertNil(presentation.inboxFreeOrderVersion)
        for tab in [InboxWorkspaceTab.inbox, .replied] {
            let visible = InboxNormalListProjection.entries(rows: loadedRows,
                serverItems: presentation.inboxViewListItems,
                freeOrderVersion: presentation.inboxFreeOrderVersion, in: tab, search: "")
            let expected = InboxListProjection.filteredRows(loadedRows, in: tab, search: "")
            XCTAssertEqual(rowIDs(visible), expected.map { .message(.row($0.id)) })
            XCTAssertEqual(visible.count, tab == .inbox ? 2 : 1)
            XCTAssertFalse(visible.contains { if case .heading = $0 { return true }; return false })
            XCTAssertFalse(visible.contains { if case .reply = $0 { return true }; return false },
                           "Fallback must not construct a mixed order from the remaining references.")
        }
    }


    func testSectionTransitionReplacesPersistedViewAndReachesPresentationAtomically() async throws {
        let persistence = MemoryPendingActionPersistence()
        let store = try ClientRepository(context: context, persistence: persistence)
        let active = try decode([reference("parent")])
        let history = try decode([reference("parent", state: "history")], revision: "view-2")
        try store.setInboxView(active, context: context)
        try store.setInboxView(history, context: context)
        let restored = try await Self.reopenWithServerCache(store, context: context, persistence: persistence)
        let port = AttentionDomainPort(store: restored)
        let presentation = try port.observe(context: port.context)
        XCTAssertEqual(presentation.inboxFreeOrderVersion, 1)
        XCTAssertEqual(presentation.inboxViewListItems, history.listItems)
        let compatible = try decode([reference("parent")], version: nil, revision: "view-3")
        try restored.setInboxView(compatible, context: context)
        let fallback = try port.observe(context: port.context)
        XCTAssertNil(fallback.inboxFreeOrderVersion)
        XCTAssertFalse(InboxFreeOrder.isSupported(version: fallback.inboxFreeOrderVersion,
                                                  items: fallback.inboxViewListItems))
    }

    @MainActor
    func testFreeNormalViewIncludesAllHistoryAndTruthfulLegacyHeadings() throws {
        let view = try decode([
            reference("new-reply", kind: "reply"), reference("open"),
            reference("old", group: "earlier_messages"),
            reference("old-chat", kind: "reply", group: "earlier_chat_replies"),
            reference("unknown", kind: "reply", group: "earlier_chat_replies_unknown"),
            reference("seen", kind: "reply", state: "history"),
            reference("terminal", state: "history"),
            reference("old-terminal", state: "history", group: "earlier_messages"),
            reference("old-seen", kind: "reply", state: "history", group: "earlier_chat_replies")
        ])
        let entries = projection(view)
        XCTAssertEqual(rowIDs(entries), view.listItems?.map {
            $0.kind == .reply ? .reply($0.key) : .message(.row(.request($0.key)))
        })
        let headings = entries.compactMap { entry -> InboxFreeHeading? in
            guard case let .heading(heading) = entry else { return nil }
            return heading
        }
        XCTAssertEqual(headings.map(\.title), [
            "Earlier activity", "Earlier messages", "Earlier chat replies", "Arrival order unavailable",
            "History", "Earlier activity", "Earlier messages", "Earlier chat replies"
        ])
        XCTAssertEqual(headings.filter { $0.kind == .earlierActivity }.map(\.state), [.active, .history])
        XCTAssertTrue(headings.first?.explanation?.contains("combined arrival order is unavailable") == true)
        XCTAssertTrue(headings.first { $0.kind == .unknownOrder }?.explanation?.contains("does not mean they are older") == true)
        XCTAssertTrue(projection(view, search: "no-match").isEmpty, "No empty section placeholders.")
    }

    @MainActor
    func testInvalidMetadataUsesCompatibleTabsWithoutInventingHeadingsOrDroppingHistory() throws {
        let view = try decode([reference("open"), reference("done", state: "history")], version: 2)
        XCTAssertEqual(rowIDs(projection(view)).count, 1)
        XCTAssertFalse(projection(view).contains { if case .heading = $0 { return true }; return false })
        let history = InboxNormalListProjection.entries(rows: rows(for: view), serverItems: view.listItems,
            freeOrderVersion: view.freeOrderVersion, in: .replied, search: "")
        XCTAssertEqual(rowIDs(history), [.message(.row(.request(try XCTUnwrap(view.listItems?.last?.key))))])
    }

    @MainActor
    func testHistoryTransitionKeepsReplyIdentityAndNavigationTarget() throws {
        let active = try decode([reference("parent", kind: "reply")])
        let reference = try XCTUnwrap(active.listItems?.first)
        XCTAssertEqual(rowIDs(projection(active)), [.reply(reference.key)])
        let history = try decode([self.reference("parent", kind: "reply", state: "history")], revision: "seen")
        XCTAssertEqual(rowIDs(projection(history)), [.reply(reference.key)])
        XCTAssertEqual(history.listItems?.first?.openAtConversationSequence, reference.openAtConversationSequence)
    }

    @MainActor
    func testHistoryNotificationUsesSameFreeListAndThreadHistoryRemainsIndividual() throws {
        let view = try decode([reference("a"), reference("b"),
                               reference("c", state: "history"), reference("d", state: "history")])
        let items = try XCTUnwrap(view.listItems)
        // Even if loaded parent lifecycle lags this view, its history metadata
        // must prevent terminal parents from being folded into an active unit.
        let rows: [InboxItem] = items.map { item in
            .request(InboxRequestRow(key: item.key, title: "Thread", sender: "Assistant", status: "",
                thread: ExactText("thread"), hasInboxViewEntry: true))
        }
        let entries = InboxNormalListProjection.entries(rows: rows, serverItems: items,
            freeOrderVersion: 1, in: .inbox, search: "")
        XCTAssertEqual(rowIDs(entries), [.message(.thread(firstMember: .request(items[0].key))),
            .message(.row(.request(items[2].key))), .message(.row(.request(items[3].key)))])
        let resolvedRows = self.rows(for: view)
        let destination = InboxNotificationDestination(
            route: NativeInboxNavigation(serial: 1, request: items[2].key), rows: resolvedRows, usesFreeOrder: true)
        XCTAssertEqual(destination.workspaceTab, .inbox)
        XCTAssertEqual(destination.selection, .request(items[2].key))
    }
}
