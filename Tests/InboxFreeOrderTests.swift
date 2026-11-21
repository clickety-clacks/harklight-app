import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest
@testable import Harklight

final class InboxFreeOrderTests: XCTestCase {
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
        return InboxView(revision: ExactText(revision), entries: [], listItems: references,
                         freeOrderVersion: version as? Int)
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
    func testNewDepartureAndSectionTransitionKeepReplyIdentityAndNavigationTarget() throws {
        let active = try decode([reference("parent", kind: "reply")])
        let reference = try XCTUnwrap(active.listItems?.first)
        var ledger = ReplyItemLedger()
        ledger.reconcile([], accountScopes: [reference.key.accountScope], now: .now)
        ledger.reconcile([ReplyItemObservation(parent: reference.key, turnID: ExactText("reply"),
            conversationSequence: 900, isSeen: false, text: "Reply")], now: .now)
        XCTAssertEqual(ledger.entries.map(\.parent), [reference.key])
        XCTAssertEqual(rowIDs(projection(active)), [.reply(reference.key)])
        XCTAssertTrue(ledger.removeForSelection(reference.key))
        XCTAssertEqual(rowIDs(projection(active)), [.reply(reference.key)])
        XCTAssertEqual(active.listItems?.first?.unseenCount, 1, "Local New selection is not a Seen receipt.")
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
