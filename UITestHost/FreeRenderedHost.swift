import AttentionDomain
import HarklightNativeRelay
import Observation
import SwiftUI

/// UI-test-only composition. Captured view frames are unchanged; all message,
/// chat, legacy and read-acknowledgement data here is generated, never live data.
@MainActor
struct FreeRenderedHost: View {
    @State private var fixture: FreeRenderedFixture
    @State private var samples = SampleLibrary()

    init() {
        do {
            _fixture = State(initialValue: try FreeRenderedFixture(
                legacy: ProcessInfo.processInfo.arguments.contains("--free-rendered-legacy")))
        } catch {
            preconditionFailure("Free rendered fixture failed: \(error)")
        }
    }

    var body: some View {
        LiveContentView(store: fixture.viewModel, samples: samples)
            // Test-only status must not obscure or resize the product UI.
            // Captures and generated message content carry visible provenance.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("free-rendered-provenance")
            .accessibilityValue(fixture.phase)
            .onChange(of: fixture.viewModel.conversation(for: fixture.olderKey)?.accountReadThroughConversationSequence) { _, turn in
                guard let turn, turn > 0 else { return }
                // A mismatch fails the test's read check instead of stopping the host.
                do { try fixture.replayHistoryAfterObservedRead(readThrough: turn) }
                catch { fixture.phase = "Free read replay failed: \(error)" }
            }
    }
}

@MainActor
@Observable
private final class FreeRenderedFixture {
    let context: ProfileContext
    let domain: ClientRepository
    let viewModel: LivePresentationStore
    let olderKey: RequestKey
    var phase: String
    private let legacy: Bool
    private var sequence: UInt64 = 0

    init(legacy: Bool) throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:free-rendered"),
            personID: ExactText("person-a"), deviceID: ExactText("device-b"))
        context = ProfileContext(identity: identity, transportMode: .fixture)
        domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        olderKey = RequestKey(accountScope: identity.personID,
            senderID: ExactText("app:test"), messageID: ExactText("older"))
        self.legacy = legacy
        phase = legacy ? "Generated legacy view and content" : "Captured active view · generated content · unread"
        let defaults = UserDefaults(suiteName: "free-rendered-\(UUID().uuidString)")!
        // Establish the ordinary empty New baseline before generated arrivals.
        viewModel = try LivePresentationStore(localFixtureStore: domain, context: context,
                                               replyItemAreaDefaults: legacy ? nil : defaults)
        if legacy {
            try populateLegacy()
        } else {
            try addMessage("older", title: "Generated older parent")
            try addReply("older", text: "Generated reply for the captured older chat", expectedSequence: 2)
            try addMessage("newer", title: "Generated newer parent")
            try setCapturedView("free-active")
        }
        // Generated replay completion advertises the existing read-position
        // capability. Local visibility can then queue its real read operation.
        try domain.finishConversationReplay(at: sequence, chatReadPositions: [], context: context)
        try viewModel.refreshFromDurableStore()
    }

    private func key(_ id: String) -> RequestKey {
        RequestKey(accountScope: context.identity.personID, senderID: ExactText("app:test"),
                   messageID: ExactText(id))
    }

    private func addMessage(_ id: String, title: String, history: Bool = false) throws {
        let payload: [String: Any] = ["title": title, "body": "Generated UI evidence content.",
            "answer_ui": ["schema": "attention-client.actions/1", "actions": [
                ["id": "continue", "label": "Continue", "kind": "value", "value": true]]]]
        let stored = StoredRequest(key: key(id), originalPayload:
            try JSONValue.parse(JSONSerialization.data(withJSONObject: payload)))
        try domain.registerFixtureRequests([stored], context: context)
        if history {
            let selector = try domain.selector(for: key(id), context: context)
            _ = try domain.submitNoComment(intentID: UUID(), selector: selector, context: context)
            try domain.recordFixtureTerminal(FixtureTerminal(state: .noComment,
                evidenceLabel: "Generated history", authorizedAnswer: nil, ownOutcome: .accepted),
                for: key(id), context: context)
        }
    }

    @discardableResult
    private func addReply(_ id: String, text: String, expectedSequence: UInt64? = nil,
                          seen: Bool = false) throws -> UInt64 {
        let binding = ConversationBinding(request: key(id), revision: 1)
        let request = try domain.snapshot(context: context).requests[key(id)]!
        let handle = ExactText("generated-session-\(id)")
        sequence += 1
        try domain.applyConversation(ConversationEvent(sequence: sequence, binding: binding,
            fact: .request(sessionHandle: handle, payload: request.originalPayload)), context: context)
        sequence += 1
        if let expectedSequence { precondition(sequence == expectedSequence) }
        let replySequence = sequence
        let turn = ConversationTurn(id: ExactText("generated-reply-\(id)"), binding: binding,
            author: .origin, sessionHandle: handle, text: ExactText(text), kind: .reply,
            conversationSequence: replySequence)
        try domain.applyConversation(ConversationEvent(sequence: sequence, binding: binding,
            fact: .turn(turn)), context: context)
        sequence += 1
        try domain.applyConversation(ConversationEvent(sequence: sequence, binding: binding,
            fact: .availability(sessionHandle: handle, .listening)), context: context)
        if seen {
            sequence += 1
            try domain.applyConversation(ConversationEvent(sequence: sequence,
                binding: ConversationBinding(request: key(id), revision: 0),
                fact: .readPosition(eventID: ExactText("generated-read-\(id)"),
                                    readThroughConversationSequence: replySequence)), context: context)
        }
        return replySequence
    }

    private func setView(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let capture = try decoder.decode(CapturedView.self, from: data)
        func request(_ row: CapturedView.Row) -> RequestKey {
            RequestKey(accountScope: context.identity.personID, senderID: ExactText(row.senderId),
                       messageID: ExactText(row.messageId))
        }
        let items = try capture.listItems.map { row in
            guard let kind = row.kind else { throw CocoaError(.fileReadCorruptFile) }
            return InboxViewListItem(kind: kind, key: request(row), conversationSequence: row.conversationSeq,
                openAtConversationSequence: row.openAtConversationSeq, unseenCount: row.unseenCount,
                freeSection: row.freeSection)
        }
        let replies = capture.replies?.compactMap { row -> InboxViewReply? in
            row.conversationSeq.map { InboxViewReply(key: request(row), conversationSequence: $0) }
        }
        let view = InboxView(revision: ExactText(capture.viewRev), algorithm: capture.algorithm.map(ExactText.init),
            basis: capture.basis.map(ExactText.init), entries: capture.entries.map { InboxViewEntry(key: request($0)) },
            replies: replies, listItems: items, freeOrderVersion: capture.freeOrderVersion)
        precondition(InboxFreeOrder.isSupported(version: view.freeOrderVersion, items: view.listItems))
        try domain.setFixtureInboxView(view, context: context)
    }

    private struct CapturedView: Decodable {
        struct Row: Decodable {
            let senderId: String
            let messageId: String
            let kind: InboxViewListItemKind?
            let conversationSeq: UInt64?
            let openAtConversationSeq: UInt64?
            let unseenCount: Int?
            let freeSection: InboxFreeSection?
        }

        let viewRev: String
        let algorithm: String?
        let basis: String?
        let entries: [Row]
        let replies: [Row]?
        let listItems: [Row]
        let freeOrderVersion: Int
    }

    private func setCapturedView(_ name: String) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        try setView(Data(contentsOf: url))
    }

    func replayHistoryAfterObservedRead(readThrough turn: UInt64) throws {
        guard !legacy, phase.contains("unread") else { return }
        // This fixture has no server, so the production chat's actual read effect
        // records the read in its own store and queues nothing to acknowledge.
        let snapshot = try domain.conversationSnapshot(context: context)
        guard turn == 2,
              !snapshot.pendingChatReadPositions.contains(where: { $0.request == olderKey }) else {
            throw ConversationError.conflict
        }
        try setCapturedView("free-history")
        try viewModel.refreshFromDurableStore()
        phase = "Captured history view · local read · read=2"
    }

    private func populateLegacy() throws {
        // No captured response establishes legacy ordering. This entire scenario
        // is explicitly generated from the bound state/group contract.
        var references: [[String: Any]] = []
        func message(_ id: String, title: String, state: String, group: String) throws {
            try addMessage(id, title: title, history: state == "history")
            references.append(["kind": "message", "sender_id": "app:test", "message_id": id,
                               "free_section": ["state": state, "group": group]])
        }
        func reply(_ id: String, title: String, state: String, group: String) throws {
            try addMessage(id, title: title, history: true)
            let seq = try addReply(id, text: "Generated \(title) reply", seen: state == "history")
            references.append(["kind": "reply", "sender_id": "app:test", "message_id": id,
                "conversation_seq": seq, "open_at_conversation_seq": seq,
                "unseen_count": state == "active" ? 1 : 0,
                "free_section": ["state": state, "group": group]])
        }
        try message("active-common", title: "Active common message", state: "active", group: "common")
        try message("active-earlier", title: "Earlier active message", state: "active", group: "earlier_messages")
        try reply("active-chat", title: "Earlier active chat", state: "active", group: "earlier_chat_replies")
        try reply("active-unknown", title: "Unknown-order active chat", state: "active", group: "earlier_chat_replies_unknown")
        try message("history-common", title: "Common historical message", state: "history", group: "common")
        try message("history-earlier", title: "Earlier historical message", state: "history", group: "earlier_messages")
        try reply("history-chat", title: "Earlier historical chat", state: "history", group: "earlier_chat_replies")
        try reply("history-unknown", title: "Unknown-order historical chat", state: "history", group: "earlier_chat_replies_unknown")
        try setView(JSONSerialization.data(withJSONObject: [
            "v": 1, "type": "ok", "ref": "free-pair-view", "view_rev": "generated-legacy",
            "entries": [], "free_order_version": 1, "list_items": references]))
    }
}
