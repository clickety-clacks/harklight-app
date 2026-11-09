import Foundation
import AttentionDomain
import CryptoKit

/// Local examples use the existing sender descriptor grammar, domain registration,
/// memory persistence, projection and ordinary app view model. No wire schema changes.
@MainActor
final class SampleFixtureDomain {
    let context: ProfileContext
    let domain: AttentionDomainStore
    let viewModel: LivePresentationStore

    init() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:harklight-examples"),
            personID: ExactText("local-examples"), deviceID: ExactText("local-example-device"))
        context = ProfileContext(identity: identity, transportMode: .fixture)
        domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        viewModel = try LivePresentationStore(localFixtureStore: domain, context: context,
                                              newMessageAreaDefaults: Self.replyItemAreaTestDefaults())
    }

    /// The reply-item UI test runs the ordinary new-message-area stores
    /// against a scratch defaults suite; other launches keep them absent.
    private static func replyItemAreaTestDefaults() -> UserDefaults? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--harklight-test-reply-item-area") ||
                arguments.contains("--harklight-test-markdown-reply-item") else { return nil }
        let suiteName = "harklight-examples.reply-item-area.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func populate() async throws {
        try await domain.registerFixtureRequests(try SampleCatalog.messages.map { try record($0) }, context: context)
        let requests = try await domain.snapshot(context: context).requests
        let existing = try await domain.conversationSnapshot(context: context)
        var sequence = existing.cursor
        for message in SampleCatalog.messages where message.hasChat && existing.threads[key(for: message)] == nil {
            let key = key(for: message)
            let binding = ConversationBinding(request: key, revision: 1)
            let handle = ExactText("local-session-" + message.id)
            func apply(_ fact: ConversationEvent.Fact, revision: UInt64 = 1) async throws {
                sequence += 1
                let sequencedFact: ConversationEvent.Fact
                switch fact {
                case .turn(var turn):
                    turn.conversationSequence = sequence
                    sequencedFact = .turn(turn)
                case .revision(var turn, let payload):
                    turn.conversationSequence = sequence
                    sequencedFact = .revision(turn, payload: payload)
                default:
                    sequencedFact = fact
                }
                try await domain.applyConversation(ConversationEvent(sequence: sequence,
                    binding: ConversationBinding(request: key, revision: revision), fact: sequencedFact), context: context)
            }
            guard let request = requests[key] else { throw ConversationError.missingRequest }
            try await apply(.request(sessionHandle: handle, payload: request.originalPayload))
            let showUnsupportedChatNotice = message.id == "sample-information-2" &&
                ProcessInfo.processInfo.arguments.contains("--harklight-test-chat-status-unsupported")
            let availability: ConversationAvailability
            if showUnsupportedChatNotice || message.id.hasSuffix("-1") {
                availability = .unsupported(reason: ExactText("Fictional route without a listener"))
            } else if message.id.hasSuffix("-2") {
                availability = .notListening(lastDetachedAt: nil)
            } else {
                availability = .listening
            }
            try await apply(.availability(sessionHandle: handle, availability))
            if message.hasChat {
                let personID = message.id == "sample-information-0" ? "30" : message.id + "-question"
                let replyID = message.id == "sample-information-0" ? "20" : message.id + "-reply"
                let isMarkdownAcceptance = message.id == "sample-markdown-acceptance"
                let person = ConversationTurn(id: ExactText(personID), binding: binding,
                    author: .person, sessionHandle: handle,
                    text: ExactText(isMarkdownAcceptance
                        ? "Could you **explain** the [guide](https://example.invalid/turn-guide)?"
                        : "Could you explain the tradeoff?"))
                let reply = ConversationTurn(id: ExactText(replyID), binding: binding,
                    author: .origin, sessionHandle: handle,
                    text: ExactText(isMarkdownAcceptance
                        ? "The first option favors *speed*; the second leaves more room to revise."
                        : "The first option favors speed; the second leaves more room to revise. This is an example conversation."),
                    inReplyTo: person.id)
                try await apply(.turn(person))
                try await apply(.delivered(turn: person.id))
                try await apply(.turn(reply))
                try await apply(.acted(turn: person.id, by: reply.id))
                if message.id == "sample-information-0" || isMarkdownAcceptance {
                    let agentReply = ConversationTurn(id: ExactText("10"), binding: binding,
                        author: .agent, sessionHandle: handle,
                        text: ExactText(isMarkdownAcceptance
                            ? "Agent reply with `inline code`, a **clear** summary, and [Open reply guide](https://example.invalid/reply-guide)."
                            : "Agent example: the shorter path is faster, while the longer path is easier to revise."),
                        inReplyTo: reply.id, kind: .reply)
                    try await apply(.turn(agentReply))

                    if isMarkdownAcceptance && ProcessInfo.processInfo.arguments.contains(
                        "--harklight-test-markdown-reply-item") {
                        let markdownReply = ConversationTurn(
                            id: ExactText("markdown-reply-item"), binding: binding,
                            author: .origin, sessionHandle: handle,
                            text: ExactText(
                                "Open [reply guide](https://example.invalid/reply-guide): an *important* response with `inline code`."),
                            inReplyTo: reply.id, kind: .reply)
                        try await apply(.turn(markdownReply))
                    }

                    if ProcessInfo.processInfo.arguments.contains("--harklight-test-chat-status-two-ack") {
                        try await apply(.availability(sessionHandle: handle,
                            .notListening(lastDetachedAt: nil)))
                        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
                        let ack1FinalOnly = ProcessInfo.processInfo.arguments.contains(
                            "--harklight-test-chat-status-ack1-final-only")
                        func appendStatusExample(_ suffix: String, _ text: String) async throws -> ConversationTurn {
                            let turn = ConversationTurn(id: ExactText("two-ack-" + suffix), binding: binding,
                                author: .person, sessionHandle: handle, text: ExactText(text),
                                kind: .discussion, deliveryAcks: true)
                            try await apply(.turn(turn))
                            return turn
                        }
                        if !ack1FinalOnly {
                            let sending = try await appendStatusExample("sending", "Agent not given yet.")
                            try await apply(.deliveryAck(turn: sending.id, acknowledgement: .listenerReceived(
                                atMilliseconds: now - 30_000, ack2Expected: true,
                                acknowledgerSystem: ExactText("Tightbeam"), acknowledgerAgent: nil)))

                            let waiting = try await appendStatusExample("waiting", "First acknowledgement received.")
                            try await apply(.deliveryAck(turn: waiting.id, acknowledgement: .listenerReceived(
                                atMilliseconds: now - 180_000, ack2Expected: true,
                                acknowledgerSystem: ExactText("Tightbeam"), acknowledgerAgent: nil)))
                        }

                        let incapable = try await appendStatusExample("ack1-final", "This listener cannot send ACK2.")
                        try await apply(.deliveryAck(turn: incapable.id, acknowledgement: .listenerReceived(
                            atMilliseconds: now, ack2Expected: false,
                            acknowledgerSystem: ExactText("Harklight Agent"), acknowledgerAgent: nil)))

                        if !ack1FinalOnly {
                            _ = try await appendStatusExample("no-listener", "No first acknowledgement.")

                            let delivered = try await appendStatusExample("handed", "Handed to an agent.")
                            try await apply(.deliveryAck(turn: delivered.id, acknowledgement: .handed(
                                atMilliseconds: now, rerouted: false,
                                acknowledgerSystem: ExactText("Tightbeam"),
                                acknowledgerAgent: ExactText("Release orchestrator"))))

                            let deliveredTo = try await appendStatusExample("rerouted", "Handed to a follower.")
                            try await apply(.deliveryAck(turn: deliveredTo.id, acknowledgement: .handed(
                                atMilliseconds: now, rerouted: true,
                                acknowledgerSystem: ExactText("Tightbeam"),
                                acknowledgerAgent: ExactText("Release orchestrator"))))

                            let notHanded = try await appendStatusExample("not-handed", "Handoff unavailable.")
                            try await apply(.deliveryAck(turn: notHanded.id, acknowledgement: .notHanded(
                                atMilliseconds: now, reason: ExactText("The receiving system is unavailable."),
                                acknowledgerSystem: ExactText("Harklight Agent"), acknowledgerAgent: nil)))
                        }

                    }

                    if ProcessInfo.processInfo.arguments.contains("--harklight-test-reply-item-area") {
                        func appendHistory(_ index: Int) async throws {
                            try await apply(.turn(ConversationTurn(id: ExactText("reply-area-history-\(index)"),
                                binding: binding, author: .person, sessionHandle: handle,
                                text: ExactText("Earlier local discussion turn \(index) keeps this example history long."),
                                kind: .discussion)))
                        }
                        for index in 1...20 { try await appendHistory(index) }
                        try await apply(.turn(ConversationTurn(id: ExactText("reply-area-earliest"), binding: binding,
                            author: .origin, sessionHandle: handle,
                            text: ExactText("Earliest unseen chat reply: the middle section of the draft now reads better."),
                            inReplyTo: person.id, kind: .reply)))
                        for index in 21...30 { try await appendHistory(index) }
                        try await apply(.turn(ConversationTurn(id: ExactText("reply-area-newest"), binding: binding,
                            author: .origin, sessionHandle: handle,
                            text: ExactText("Newest unseen chat reply: the revised draft tightens the opening, keeps the middle section's new ordering, and closes with the shorter summary we discussed, so the whole note should now fit on one screen."),
                            inReplyTo: person.id, kind: .reply)))
                    }
                }
            }
            if message.id == "sample-approval-2" {
                let usesMarkdownHistory = ProcessInfo.processInfo.arguments.contains(
                    "--harklight-test-markdown-history")
                var answer = RequestDraft(interface: request.interface)
                answer.inputs[ExactText("answer")]?.selectedActionID = message.options.first.map { ExactText($0.id) }
                try await domain.saveDraft(answer, selector: domain.selector(for: key, context: context), context: context)
                let members = request.originalPayload.objectMembers ?? []
                let revisedBody = usesMarkdownHistory
                    ? "The new request adds a **review** before archiving."
                    : message.body + " The local request now asks for a review before archiving."
                let payload = JSONValue.object(members.map { member in
                    member.key == ExactText("body")
                        ? JSONMember("body", .string(ExactText(revisedBody)))
                        : member
                })
                let revised = ConversationTurn(id: ExactText(message.id + "-revision"),
                    binding: ConversationBinding(request: key, revision: 2), author: .origin,
                    sessionHandle: handle, text: ExactText("Please review the sketches before archiving. The earlier answer draft is retained."), kind: .revision)
                try await apply(.revision(revised, payload: payload), revision: 2)
            }
            if message.id == "sample-information-2" {
                let bytes = Data("Fictional local file; no upload or service call occurred.".utf8)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let file = ConversationFile(id: ExactText("example.txt"), name: ExactText("example.txt"), byteCount: UInt64(bytes.count),
                    sha256: ExactText(digest), content: .inline(bytes))
                let turn = ConversationTurn(id: ExactText(message.id + "-file"), binding: binding, author: .person,
                    sessionHandle: handle, text: ExactText("This local file demonstrates distinct transfer and use facts."), files: [file])
                try await apply(.turn(turn))
                try await apply(.fileTransfer(turn: turn.id, file: file.id, .transferred))
                try await apply(.fileUse(turn: turn.id, file: file.id, .unusable(reason: ExactText("Fictional unsupported format"))))
                let simulatedAcceptedAt = UInt64(max(0, Date().timeIntervalSince1970 * 1_000 - 180_000))
                try await domain.saveConversationDraft(ConversationDraft(binding: binding,
                    text: ExactText("Could you check whether this message reached anyone?")), context: context)
                try await domain.appendFixtureDiscussion(binding, context: context,
                    simulatedAcceptanceObservedAtMilliseconds: simulatedAcceptedAt)
                sequence += 1
            }
            if message.id == "sample-completed-2" {
                try await apply(.availability(sessionHandle: handle, .gone))
                try await apply(.terminal(turn: ExactText(message.id + "-terminal"), author: .origin, state: .cleared))
            }
            if message.id == "sample-review-0" {
                let bytes = Data(repeating: 66, count: 300_000)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let file = ConversationFile(id: ExactText("local-mixed-file"), name: ExactText("Unidentified example.txt"),
                    byteCount: UInt64(bytes.count), sha256: ExactText(digest), content: .inline(bytes))
                try await domain.stageFixtureConversationUpload(file, binding: binding,
                    text: ExactText("Keep the original mixed-result note."), context: context)
            }
            if message.id == "sample-review-2" {
                let bytes = Data(repeating: 65, count: 300_000)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let file = ConversationFile(id: ExactText("local-cleanup-file"), name: ExactText("Unsubmitted example.txt"),
                    byteCount: UInt64(bytes.count), sha256: ExactText(digest), content: .inline(bytes))
                try await domain.stageFixtureConversationUpload(file, binding: binding,
                    text: ExactText("Keep this file note."), context: context)
            }
            if message.id == "sample-approval-1" {
                var answer = RequestDraft(interface: request.interface)
                answer.inputs[ExactText("answer")]?.selectedActionID = message.options.first.map { ExactText($0.id) }
                try await domain.saveDraft(answer, selector: domain.selector(for: key, context: context), context: context)
                try await domain.saveConversationDraft(ConversationDraft(binding: binding,
                    text: ExactText("Please keep this unsent note.")), context: context)
                try await apply(.retraction(turn: ExactText(message.id + "-retracted"), terminalSequence: 1))
            }
        }
        try await viewModel.refreshFromDurableStore()
        if ProcessInfo.processInfo.arguments.contains("--harklight-test-reply-item-area") {
            guard let parentMessage = SampleCatalog.messages.first(where: {
                $0.id == "sample-information-0"
            }) else { throw ConversationError.missingRequest }
            let replyParent = key(for: parentMessage)
            guard let thread = viewModel.conversation(for: replyParent) else {
                throw ConversationError.missingRequest
            }
            let unseenReplies = thread.turns.filter {
                $0.author == .origin && $0.kind == .reply
            }.sorted { ($0.conversationSequence ?? 0) < ($1.conversationSequence ?? 0) }
            let groupedReplies = Array(unseenReplies.suffix(2))
            guard groupedReplies.count == 2,
                  let earliestSequence = groupedReplies.first?.conversationSequence,
                  let newestSequence = groupedReplies.last?.conversationSequence else {
                throw ConversationError.conflict
            }
            let perReplyScores = [earliestSequence: 0.93, newestSequence: 0.4]
            let listItems = [
                InboxViewListItem(kind: .reply, key: replyParent,
                    conversationSequence: newestSequence,
                    openAtConversationSequence: earliestSequence,
                    unseenCount: groupedReplies.count, score: 0.93, scoreKind: .current),
                InboxViewListItem(kind: .message, key: replyParent)
            ]
            try await domain.setFixtureInboxView(InboxView(
                revision: ExactText("sample-reply-item-list"),
                entries: [],
                replies: groupedReplies.compactMap { turn in
                    guard let sequence = turn.conversationSequence else { return nil }
                    return InboxViewReply(key: replyParent, conversationSequence: sequence,
                                          score: perReplyScores[sequence])
                },
                listItems: listItems), context: context)
            try await viewModel.refreshFromDurableStore()
        }
        if ProcessInfo.processInfo.arguments.contains("--harklight-test-markdown-reply-item") {
            guard let parentMessage = SampleCatalog.messages.first(where: {
                $0.id == "sample-markdown-acceptance"
            }) else { throw ConversationError.missingRequest }
            let replyParent = key(for: parentMessage)
            guard let thread = viewModel.conversation(for: replyParent),
                  let markdownReply = thread.turns.first(where: {
                      $0.id == ExactText("markdown-reply-item") &&
                          $0.author == .origin && $0.kind == .reply
                  }),
                  let replySequence = markdownReply.conversationSequence else {
                throw ConversationError.missingRequest
            }
            try await domain.setFixtureInboxView(InboxView(
                revision: ExactText("sample-markdown-reply-list"),
                entries: [],
                replies: [InboxViewReply(key: replyParent,
                                         conversationSequence: replySequence,
                                         score: 0.84)],
                listItems: [
                    InboxViewListItem(kind: .reply, key: replyParent,
                        conversationSequence: replySequence,
                        openAtConversationSequence: replySequence,
                        unseenCount: 1, score: 0.84, scoreKind: .current),
                    InboxViewListItem(kind: .message, key: replyParent)
                ]), context: context)
            try await viewModel.refreshFromDurableStore()
        }
    }

    func key(for message: SampleMessage) -> RequestKey {
        RequestKey(accountScope: context.identity.personID, senderID: ExactText(message.sender),
                   messageID: ExactText(message.id))
    }

    private func record(_ message: SampleMessage) throws -> StoredRequest {
        let usesMarkdownHistory = message.id == "sample-approval-2" &&
            ProcessInfo.processInfo.arguments.contains("--harklight-test-markdown-history")
        let authoredTitle = message.title
        let authoredBody = usesMarkdownHistory
            ? "The **new collection** is ready. Choose what happens to the *earlier sketches*."
            : message.body

        func storedRequest(_ payload: [String: Any]) throws -> StoredRequest {
            var payload = payload
            if let messageType = message.declaredMessageType {
                payload["message_type"] = messageType.rawValue
            }
            if let messageKind = message.declaredMessageKind {
                payload["message_kind"] = messageKind.rawValue
            }
            let json = try JSONValue.parse(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            let stored = StoredRequest(key: key(for: message), originalPayload: json)
            switch stored.interface {
            case .sender, .compatibility:
                return stored
            case .unsupported:
                throw SampleFixtureError.invalidDescriptor(message.id)
            }
        }

        // Re-registration is intentionally strict about original payloads. Keep
        // this identity-bound fixture fact stable across every Shake/populate.
        let createdAt = message.fixtureCreatedAtMilliseconds
        if message.kind.isNotice {
            var payload: [String: Any] = [
                "sender_id": message.sender,
                "message_id": message.id,
                "created_at": createdAt,
                "title": authoredTitle,
                "body": authoredBody,
                "answer_ui": [
                    "schema": "attention-client.actions/1",
                    "actions": [[
                        "id": "seen", "label": "Seen", "kind": "value",
                        "value": ["acknowledgment": "seen"]
                    ]]
                ]
            ]
            if message.id == "sample-markdown-acceptance" {
                payload["stake"] = "The **main risk** is losing the link and its context."
            }
            return try storedRequest(payload)
        }
        if message.kind == .note {
            return try storedRequest([
                "sender_id": message.sender,
                "message_id": message.id,
                "created_at": createdAt,
                "title": authoredTitle,
                "body": authoredBody,
                "answer_ui": [
                    "schema": "attention-client.actions/1",
                    "actions": [["id": "reply", "label": "Reply", "kind": "text"]]
                ]
            ])
        }

        var inputs: [[String: Any]] = []
        var illustrations: [[String: Any]] = []
        var capabilities = ["scene/1", "result/1"]
        func response(_ id: String, _ label: String, _ actions: [[String: Any]]) {
            inputs.append(["kind": "response", "id": id, "label": label, "actions": actions])
            if !capabilities.contains("response/1") { capabilities.append("response/1") }
        }
        func text(_ id: String, _ label: String) {
            inputs.append(["kind": "text", "id": id, "label": label])
            if !capabilities.contains("text/1") { capabilities.append("text/1") }
        }
        switch message.kind {
        case .approval, .textChoice, .pictureChoice, .review, .colorChoice, .soundChoice:
            var actions: [[String: Any]] = message.options.map {
                ["id": $0.id, "label": $0.title, "kind": "value", "value": $0.id]
            }
            if message.kind != .pictureChoice {
                actions.append(["id": "own", "label": "Your own answer", "kind": "text"])
            }
            response("answer", "Response", actions)
        case .multipleChoice:
            for option in message.options {
                response(option.id, option.title, [
                    ["id": "yes", "label": "Selected", "kind": "value", "value": true],
                    ["id": "no", "label": "Not selected", "kind": "value", "value": false]
                ])
            }
            response("answer", "Response", [
                ["id": "options", "label": "Selected options", "kind": "value", "value": true],
                ["id": "own", "label": "Your own answer", "kind": "text"]
            ])
        case .value:
            text("value", "Days")
        case .point:
            illustrations = [["id": "cover", "label": "Cover placement", "width": 1000, "height": 1000,
                "primitives": [["kind": "rect", "x": 0, "y": 0, "width": 1000, "height": 1000, "fill": "#E4EDF4"]]]]
            inputs.append(["kind": "point", "id": "point", "label": "Title position", "illustration": "cover"])
            capabilities += ["illustration/1", "point/1"]
            text("annotation", "Local annotation history")
        case .instructions:
            response("answer", "Acknowledgment", [["id": "done", "label": "Done", "kind": "value", "value": true]])
        case .note, .error, .warning, .information, .completed:
            break
        }
        // Text choices already offer "Your own answer" for free-form input.
        // Other examples retain their actual domain note drafts.
        if message.kind != .textChoice {
            text("note", "Note")
        }
        let nodes: [[String: Any]] = inputs.map { input in
            let kind = input["kind"] as? String
            return ["kind": "input", "id": input["id"]!,
                    "layout": kind == "point" ? "diagram" : kind == "text" ? "editor" : "list"]
        }
        let descriptor: [String: Any] = [
            "schema": "attention-client.ui/1", "requires": capabilities,
            "illustrations": illustrations, "inputs": inputs,
            "open": ["kind": "stack", "axis": "vertical", "children": nodes],
            "resolved": ["kind": "text", "text": "Local example", "style": "body"],
            "submission": ["label": "Finish locally", "result": ["kind": "array", "items": inputs.map {
                ["kind": "input", "id": $0["id"]!]
            }]]
        ]
        return try storedRequest(["sender_id": message.sender, "message_id": message.id,
            "created_at": createdAt, "title": authoredTitle, "body": authoredBody, "answer_ui": descriptor])
    }
}

enum SampleFixtureError: Error { case invalidDescriptor(String) }
