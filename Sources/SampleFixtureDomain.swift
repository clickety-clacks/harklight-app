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

    init() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:harklight-examples"),
            personID: ExactText("local-examples"), deviceID: ExactText("local-example-device"))
        context = ProfileContext(identity: identity, transportMode: .fixture)
        domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        viewModel = try LivePresentationStore(localFixtureStore: domain, context: context)
    }

    func populate() throws {
        try domain.registerFixtureRequests(try SampleCatalog.messages.map { try record($0) }, context: context)
        let requests = try domain.snapshot(context: context).requests
        let existing = try domain.conversationSnapshot(context: context)
        var sequence = existing.cursor
        for message in SampleCatalog.messages where existing.threads[key(for: message)] == nil {
            let key = key(for: message)
            let binding = ConversationBinding(request: key, revision: 1)
            let handle = ExactText("local-session-" + message.id)
            func apply(_ fact: ConversationEvent.Fact, revision: UInt64 = 1) throws {
                sequence += 1
                try domain.applyConversation(ConversationEvent(sequence: sequence,
                    binding: ConversationBinding(request: key, revision: revision), fact: fact), context: context)
            }
            guard let request = requests[key] else { throw ConversationError.missingRequest }
            try apply(.request(sessionHandle: handle, payload: request.originalPayload))
            let availability: ConversationAvailability = message.id.hasSuffix("-1")
                ? .unsupported(reason: ExactText("Fictional route without a listener"))
                : message.id.hasSuffix("-2") ? .notListening(lastDetachedAt: nil) : .listening
            try apply(.availability(sessionHandle: handle, availability))
            if message.hasChat {
                let person = ConversationTurn(id: ExactText(message.id + "-question"), binding: binding,
                    author: .person, sessionHandle: handle, text: ExactText("Could you explain the tradeoff?"))
                let reply = ConversationTurn(id: ExactText(message.id + "-reply"), binding: binding,
                    author: .origin, sessionHandle: handle,
                    text: ExactText("The first option favors speed; the second leaves more room to revise. This is an example conversation."),
                    inReplyTo: person.id)
                try apply(.turn(person))
                try apply(.delivered(turn: person.id))
                try apply(.turn(reply))
                try apply(.acted(turn: person.id, by: reply.id))
            }
            if message.id == "sample-approval-2" {
                var answer = RequestDraft(interface: request.interface)
                answer.inputs[ExactText("answer")]?.selectedActionID = message.options.first.map { ExactText($0.id) }
                try domain.saveDraft(answer, selector: domain.selector(for: key, context: context), context: context)
                let members = request.originalPayload.objectMembers ?? []
                let payload = JSONValue.object(members.map { member in
                    member.key == ExactText("body") ? JSONMember("body", .string(ExactText(message.body + " The local request now asks for a review before archiving."))) : member
                })
                let revised = ConversationTurn(id: ExactText(message.id + "-revision"),
                    binding: ConversationBinding(request: key, revision: 2), author: .origin,
                    sessionHandle: handle, text: ExactText("Please review the sketches before archiving. The earlier answer draft is retained."), kind: .revision)
                try apply(.revision(revised, payload: payload), revision: 2)
            }
            if message.id == "sample-information-2" {
                let bytes = Data("Fictional local file; no upload or service call occurred.".utf8)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let file = ConversationFile(id: ExactText("example.txt"), name: ExactText("example.txt"), byteCount: UInt64(bytes.count),
                    sha256: ExactText(digest), content: .inline(bytes))
                let turn = ConversationTurn(id: ExactText(message.id + "-file"), binding: binding, author: .person,
                    sessionHandle: handle, text: ExactText("This local file demonstrates distinct transfer and use facts."), files: [file])
                try apply(.turn(turn))
                try apply(.fileTransfer(turn: turn.id, file: file.id, .transferred))
                try apply(.fileUse(turn: turn.id, file: file.id, .unusable(reason: ExactText("Fictional unsupported format"))))
            }
            if message.id == "sample-completed-2" {
                try apply(.availability(sessionHandle: handle, .gone))
                try apply(.terminal(turn: ExactText(message.id + "-terminal"), author: .origin, state: .cleared))
            }
        }
        try viewModel.refreshFromDurableStore()
    }

    func key(for message: SampleMessage) -> RequestKey {
        RequestKey(accountScope: context.identity.personID, senderID: ExactText(message.sender),
                   messageID: ExactText(message.id))
    }

    private func record(_ message: SampleMessage) throws -> StoredRequest {
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
        // Notes are actual domain text drafts. Conversation closure examples are
        // applied separately as typed local facts, never accepted answer receipts.
        text("note", "Note")
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
        let payload: [String: Any] = ["sender_id": message.sender, "message_id": message.id,
            "created_at": 1, "title": message.title, "body": message.body, "answer_ui": descriptor]
        let json = try JSONValue.parse(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let stored = StoredRequest(key: key(for: message), originalPayload: json)
        guard case .sender = stored.interface else { throw SampleFixtureError.invalidDescriptor(message.id) }
        return stored
    }
}

enum SampleFixtureError: Error { case invalidDescriptor(String) }
