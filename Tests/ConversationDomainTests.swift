import AttentionDomain
import CryptoKit
import Foundation
import XCTest

private final class SeededAttentionStatePersistence: AttentionStatePersistence, @unchecked Sendable {
    private let state: Data

    init(state: Data) { self.state = state }

    func load(identity: ProfileIdentity) throws -> Data? { state }
    func commit(_ data: Data, identity: ProfileIdentity) throws {}
}

private func reversePersistedConversationTurnArrays(in value: inout Any) -> Int {
    if var dictionary = value as? [String: Any] {
        var changed = 0
        if let turns = dictionary["turns"] as? [Any] {
            dictionary["turns"] = Array(turns.reversed())
            changed += 1
        }
        for key in Array(dictionary.keys) {
            guard var child = dictionary[key] else { continue }
            changed += reversePersistedConversationTurnArrays(in: &child)
            dictionary[key] = child
        }
        value = dictionary
        return changed
    }
    if var array = value as? [Any] {
        var changed = 0
        for index in array.indices {
            changed += reversePersistedConversationTurnArrays(in: &array[index])
        }
        value = array
        return changed
    }
    return 0
}

private func assertThrowsAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    onError: ((Error) -> Void)? = nil
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        onError?(error)
    }
}

final class ConversationDomainTests: XCTestCase {
    private func context(_ mode: AttentionTransportMode = .relay) -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("conversation-test"),
            personID: ExactText("fictional-person"), deviceID: ExactText("fictional-device")), transportMode: mode)
    }

    private func binding(_ context: ProfileContext, _ revision: UInt64 = 1) -> ConversationBinding {
        ConversationBinding(request: RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request")), revision: revision)
    }

    func testRevisionBoundHistoryDraftAndReceiptsSurviveRestartWithoutAdvancingLegacyCursor() async throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let first = binding(context)
        let second = binding(context, 2)
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: first,
            fact: .request(sessionHandle: ExactText("original-session"), payload: .string(ExactText("First wording")))), context: context)
        let draft = ConversationDraft(binding: first, text: ExactText("Question about the first wording"))
        try await store.saveConversationDraft(draft, context: context)
        let person = ConversationTurn(id: ExactText("turn-1"), binding: first, author: .person,
            sessionHandle: ExactText("original-session"), text: ExactText("Which environment?"))
        try await store.applyConversation(ConversationEvent(sequence: 2, binding: first, fact: .turn(person)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 3, binding: second,
            fact: .request(sessionHandle: ExactText("original-session"), payload: .string(ExactText("New wording")))), context: context)
        // A later receipt names the original turn without rebinding that turn to revision 2.
        try await store.applyConversation(ConversationEvent(sequence: 4, binding: second,
            fact: .delivered(turn: person.id)), context: context)
        let reply = ConversationTurn(id: ExactText("turn-2"), binding: second, author: .origin,
            sessionHandle: ExactText("original-session"), text: ExactText("Production"), inReplyTo: person.id)
        try await store.applyConversation(ConversationEvent(sequence: 5, binding: second, fact: .turn(reply)), context: context)
        let conversationAfterReply = try await store.conversationSnapshot(context: context)
        XCTAssertNil(conversationAfterReply.threads[first.request]?.facts[person.id]?.actedBy,
                     "A reply is not an inferred acted fact")
        try await store.applyConversation(ConversationEvent(sequence: 6, binding: second,
            fact: .acted(turn: person.id, by: reply.id)), context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let snapshot = try await restored.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(snapshot.threads[first.request])
        XCTAssertEqual(snapshot.cursor, 6)
        let restoredState = try await restored.snapshot(context: context)
        XCTAssertEqual(restoredState.cursor, 0)
        XCTAssertEqual(thread.currentRevision, 2)
        XCTAssertEqual(thread.turns.first?.binding, first)
        XCTAssertEqual(thread.turns.last?.inReplyTo, person.id)
        XCTAssertEqual(thread.facts[person.id]?.delivered, true)
        XCTAssertEqual(thread.facts[person.id]?.actedBy, reply.id)
        XCTAssertEqual(thread.drafts[1], draft)
    }

    func testDeliveryAckFactsPersistWithoutBecomingExistingReceiptFacts() async throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = binding(context)
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        let turn = ConversationTurn(id: ExactText("person-chat"), binding: binding,
            author: .person, sessionHandle: ExactText("session"), text: ExactText("Question"),
            kind: .discussion, deliveryAcks: true)
        try await store.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(turn)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .deliveryAck(turn: turn.id, acknowledgement: .listenerReceived(
                atMilliseconds: 40_000, ack2Expected: true,
                acknowledgerSystem: ExactText("Tightbeam"), acknowledgerAgent: nil))), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 4, binding: binding,
            fact: .deliveryAck(turn: turn.id, acknowledgement: .notHanded(
                atMilliseconds: 50_000, reason: ExactText("Not ready"),
                acknowledgerSystem: ExactText("Tightbeam"), acknowledgerAgent: nil))), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 5, binding: binding,
            fact: .deliveryAck(turn: turn.id, acknowledgement: .handed(
                atMilliseconds: 60_000, rerouted: true,
                acknowledgerSystem: ExactText("Tightbeam"),
                acknowledgerAgent: ExactText("Release orchestrator")))), context: context)

        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let restoredConversation = try await restored.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(restoredConversation.threads[binding.request])
        XCTAssertEqual(thread.turns.first?.deliveryAcks, true)
        XCTAssertEqual(thread.facts[turn.id]?.deliveryAck1, .listenerReceived(
            atMilliseconds: 40_000, ack2Expected: true,
            acknowledgerSystem: ExactText("Tightbeam"), acknowledgerAgent: nil))
        XCTAssertEqual(thread.facts[turn.id]?.deliveryAck2, .handed(
            atMilliseconds: 60_000, rerouted: true,
            acknowledgerSystem: ExactText("Tightbeam"),
            acknowledgerAgent: ExactText("Release orchestrator")))
        XCTAssertFalse(thread.facts[turn.id]?.delivered ?? true,
                       "A system ACK2 remains distinct from the existing agent Seen receipt.")
        XCTAssertEqual(restoredConversation.cursor, 5)
    }

    func testLegacySavedTurnsAndFactsDecodeWithoutOptionalTwoAckFields() throws {
        let context = context()
        let binding = binding(context)
        let turn = ConversationTurn(id: ExactText("legacy-turn"), binding: binding,
            author: .person, sessionHandle: ExactText("session"), text: ExactText("Question"),
            kind: .discussion, deliveryAcks: true)
        var encodedTurn = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(turn)) as? [String: Any])
        encodedTurn.removeValue(forKey: "deliveryAcks")
        let restoredTurn = try JSONDecoder().decode(ConversationTurn.self,
            from: JSONSerialization.data(withJSONObject: encodedTurn))
        XCTAssertNil(restoredTurn.deliveryAcks)

        var facts = ConversationTurnFacts(acceptedAtMilliseconds: 25_000)
        facts.deliveryAck1 = .listenerReceived(atMilliseconds: 30_000, ack2Expected: true,
            acknowledgerSystem: nil, acknowledgerAgent: nil)
        facts.deliveryAck2 = .handed(atMilliseconds: 35_000, rerouted: false,
            acknowledgerSystem: nil, acknowledgerAgent: nil)
        var encodedFacts = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(facts)) as? [String: Any])
        encodedFacts.removeValue(forKey: "deliveryAck1")
        encodedFacts.removeValue(forKey: "deliveryAck2")
        let restoredFacts = try JSONDecoder().decode(ConversationTurnFacts.self,
            from: JSONSerialization.data(withJSONObject: encodedFacts))
        XCTAssertEqual(restoredFacts.acceptedAtMilliseconds, 25_000)
        XCTAssertNil(restoredFacts.deliveryAck1)
        XCTAssertNil(restoredFacts.deliveryAck2)
    }

    func testConversationTurnOrderFollowsProjectionSequenceAndPreservesReplyFacts() async throws {
        let context = context()
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let binding = binding(context)
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)

        // These identities descend even though their accepted conversation facts do not.
        let prompt = ConversationTurn(id: ExactText("30"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Which option should we use?"))
        let reply = ConversationTurn(id: ExactText("20"), binding: binding, author: .origin,
            sessionHandle: ExactText("session"), text: ExactText("Use the reversible option."),
            inReplyTo: prompt.id)
        let agentReply = ConversationTurn(id: ExactText("10"), binding: binding, author: .agent,
            sessionHandle: ExactText("session"), text: ExactText("I will use the reversible option."),
            inReplyTo: reply.id, kind: .reply)

        try await store.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(prompt)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .delivered(turn: prompt.id)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 4, binding: binding, fact: .turn(reply)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 5, binding: binding,
            fact: .acted(turn: prompt.id, by: reply.id)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 6, binding: binding, fact: .turn(agentReply)), context: context)

        let conversation = try await store.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(conversation.threads[binding.request])
        XCTAssertEqual(thread.turns.map(\.id), [prompt.id, reply.id, agentReply.id])
        XCTAssertEqual(thread.turns.map(\.inReplyTo), [nil, prompt.id, reply.id])
        XCTAssertEqual(thread.facts[prompt.id]?.delivered, true)
        XCTAssertEqual(thread.facts[prompt.id]?.actedBy, reply.id)
        XCTAssertNil(thread.facts[reply.id]?.actedBy, "A reply does not imply that its own prompt was acted on")
    }

    func testReloadRepairsLegacyTurnOrderFromProjectionSequenceWithoutDroppingHistory() async throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = binding(context)
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        let prompt = ConversationTurn(id: ExactText("30"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Which option should we use?"))
        let reply = ConversationTurn(id: ExactText("20"), binding: binding, author: .origin,
            sessionHandle: ExactText("session"), text: ExactText("Use the reversible option."),
            inReplyTo: prompt.id)
        let agentReply = ConversationTurn(id: ExactText("10"), binding: binding, author: .agent,
            sessionHandle: ExactText("session"), text: ExactText("I will use the reversible option."),
            inReplyTo: reply.id, kind: .reply)
        try await store.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(prompt)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .delivered(turn: prompt.id)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 4, binding: binding, fact: .turn(reply)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 5, binding: binding,
            fact: .acted(turn: prompt.id, by: reply.id)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 6, binding: binding, fact: .turn(agentReply)), context: context)

        // Recreate the legacy saved-array ordering while leaving the sequence journal intact.
        let current = try XCTUnwrap(persistence.load(identity: context.identity))
        var propertyList = try PropertyListSerialization.propertyList(from: current,
            options: [.mutableContainersAndLeaves], format: nil)
        XCTAssertEqual(reversePersistedConversationTurnArrays(in: &propertyList), 1)
        let encoded = try PropertyListSerialization.data(fromPropertyList: propertyList,
            format: .binary, options: 0)

        let restoredStore = try AttentionDomainStore(context: context,
            persistence: SeededAttentionStatePersistence(state: encoded))
        let restoredConversation = try await restoredStore.conversationSnapshot(context: context)
        let restored = try XCTUnwrap(restoredConversation.threads[binding.request])
        XCTAssertEqual(restored.turns.map(\.id), [prompt.id, reply.id, agentReply.id])
        XCTAssertEqual(restored.turns.map(\.inReplyTo), [nil, prompt.id, reply.id])
        XCTAssertEqual(restored.facts[prompt.id]?.delivered, true)
        XCTAssertEqual(restored.facts[prompt.id]?.actedBy, reply.id)
        XCTAssertEqual(restored.turns.count, 3)
    }

    func testReloadOrdersOrdinaryTerminalTurnFromItsConversationProjectionSequence() async throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = binding(context)
        try await store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: binding.request, originalPayload: .null), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)

        // The ordinary lifecycle event contributes this terminal row without borrowing
        // the conversation cursor. Its matching projection fact is the ordering evidence.
        let terminalID = ExactText("20")
        try await store.apply(RelayEvent(sequence: 2, body: .terminal(binding.request, .expired, nil),
            conversation: RelayConversationMetadata(revision: 1, eventID: terminalID, author: .server)),
            context: context)

        let prompt = ConversationTurn(id: ExactText("30"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Which option should we use?"))
        let reply = ConversationTurn(id: ExactText("40"), binding: binding, author: .agent,
            sessionHandle: ExactText("session"), text: ExactText("Use the reversible option."),
            inReplyTo: prompt.id, kind: .reply)
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .turn(prompt)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(reply)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .terminal(turn: terminalID, author: .server, state: .expired)), context: context)

        // This matches the legacy numeric-ID ordering that placed the terminal first.
        let beforeReloadConversation = try await store.conversationSnapshot(context: context)
        let beforeReload = try XCTUnwrap(beforeReloadConversation.threads[binding.request])
        XCTAssertEqual(beforeReload.turns.map(\.id), [terminalID, prompt.id, reply.id])

        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let restoredConversation = try await restored.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(restoredConversation.threads[binding.request])
        XCTAssertEqual(thread.turns.map(\.id), [prompt.id, reply.id, terminalID])
        XCTAssertEqual(thread.turns.map(\.inReplyTo), [nil, prompt.id, nil])
        XCTAssertEqual(thread.turns.last?.kind, .terminal)
        XCTAssertEqual(thread.terminal, .expired)
    }

    func testConversationCanArriveBeforeOrdinaryDeliveryWithoutCreatingOrphanedLegacyState() async throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let first = binding(context)
        let second = binding(context, 2)
        let original = try JSONValue.parse(Data(#"{"title":"Original"}"#.utf8))
        let revised = try JSONValue.parse(Data(#"{"title":"Revised"}"#.utf8))
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: first,
            fact: .request(sessionHandle: ExactText("origin"), payload: original)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 2, binding: second,
            fact: .request(sessionHandle: ExactText("origin"), payload: revised)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 3, binding: second,
            fact: .terminal(turn: ExactText("terminal"), author: .server, state: .expired)), context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let initialState = try await restored.snapshot(context: context)
        XCTAssertTrue(initialState.drafts.isEmpty)
        XCTAssertTrue(initialState.remoteStates.isEmpty)
        try await restored.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: first.request, originalPayload: original), .message)), context: context)
        let snapshot = try await restored.snapshot(context: context)
        XCTAssertEqual(snapshot.requests[first.request]?.originalPayload, revised)
        XCTAssertEqual(snapshot.remoteStates[first.request]?.state, .expired)
        XCTAssertEqual(snapshot.cursor, 1)
        let conversation = try await restored.conversationSnapshot(context: context)
        XCTAssertEqual(conversation.cursor, 3)
        _ = try AttentionDomainStore(context: context, persistence: persistence)
    }

    func testUnknownSubmissionKeepsExactOperationAndDraftUntilMatchingAcceptedTurn() async throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = binding(context)
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        try await store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Keep exactly this")), context: context)
        let operation = try await store.prepareDiscussion(binding, context: context)
        try await store.markDiscussionOutcome(binding, operation: operation, rejection: nil, context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let retainedOperation = try await restored.prepareDiscussion(binding, context: context)
        XCTAssertEqual(retainedOperation, operation)
        let unrelated = ConversationTurn(id: ExactText("other-turn"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Different"), operationID: UUID())
        try await restored.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(unrelated)), context: context)
        let unrelatedConversation = try await restored.conversationSnapshot(context: context)
        XCTAssertEqual(unrelatedConversation.threads[binding.request]?.drafts[1]?.text,
                       ExactText("Keep exactly this"))
        let accepted = ConversationTurn(id: ExactText("accepted-turn"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Keep exactly this"), operationID: operation)
        try await restored.applyConversation(ConversationEvent(sequence: 3, binding: binding, fact: .turn(accepted)), context: context)
        let acceptedConversation = try await restored.conversationSnapshot(context: context)
        XCTAssertNil(acceptedConversation.threads[binding.request]?.drafts[1])
    }

    func testOrdinaryMetadataBootstrapsConversationAndTerminalBeforeHistoryDoesNotLoseHistory() async throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let first = binding(context)
        let original = try JSONValue.parse(Data(#"{"title":"Original"}"#.utf8))
        let request = StoredRequest(key: first.request, originalPayload: original)
        try await store.apply(RelayEvent(sequence: 1, body: .delivery(request, .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"),
                availability: .listening)), context: context)
        let metadataConversation = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(metadataConversation.cursor, 0,
                       "Ordinary metadata must not fabricate a conversation sequence")
        try await store.saveConversationDraft(ConversationDraft(binding: first, text: ExactText("Keep draft")), context: context)
        try await store.apply(RelayEvent(sequence: 2, body: .terminal(first.request, .answered, nil),
            conversation: RelayConversationMetadata(revision: 2, eventID: ExactText("terminal-4"))), context: context)
        let earlier = ConversationTurn(id: ExactText("discussion-2"), binding: first, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Earlier discussion"))
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: first, fact: .turn(earlier)), context: context)
        let revised = try JSONValue.parse(Data(#"{"title":"Revised"}"#.utf8))
        let second = binding(context, 2)
        let revision = ConversationTurn(id: ExactText("revision-3"), binding: second, author: .origin,
            sessionHandle: ExactText("session"), text: ExactText(""), inReplyTo: earlier.id, kind: .revision)
        try await store.applyConversation(ConversationEvent(sequence: 2, binding: second,
            fact: .revision(revision, payload: revised)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 3, binding: second,
            fact: .delivered(turn: ExactText("terminal-4"))), context: context)
        try await store.saveConversationDraft(ConversationDraft(binding: second,
            text: ExactText("Chat remains open after the answer")), context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let snapshot = try await restored.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(snapshot.threads[first.request])
        XCTAssertEqual(snapshot.cursor, 3)
        let restoredState = try await restored.snapshot(context: context)
        XCTAssertEqual(restoredState.cursor, 2)
        XCTAssertEqual(thread.currentRevision, 2)
        XCTAssertEqual(thread.revisions[1], original)
        XCTAssertEqual(thread.revisions[2], revised)
        XCTAssertEqual(thread.turns.map(\.id), [earlier.id, revision.id])
        XCTAssertEqual(thread.terminal, .answered)
        XCTAssertTrue(thread.allowsDiscussion)
        XCTAssertEqual(thread.facts[ExactText("terminal-4")]?.delivered, true)
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("Keep draft"))
        XCTAssertEqual(thread.drafts[2]?.text, ExactText("Chat remains open after the answer"))
    }

    func testAnswerAndNoCommentKeepChatDraftSendAndAgentRepliesAvailable() async throws {
        for terminal in [TerminalState.answered, .noComment] {
            let relayContext = context()
            let store = try AttentionDomainStore(context: relayContext,
                persistence: MemoryAttentionStatePersistence())
            let request = binding(relayContext)
            try await store.applyConversation(ConversationEvent(sequence: 1, binding: request,
                fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: relayContext)
            try await store.saveConversationDraft(ConversationDraft(binding: request,
                text: ExactText("Before answering")), context: relayContext)
            try await store.applyConversation(ConversationEvent(sequence: 2, binding: request,
                fact: .terminal(turn: ExactText("answer"), author: .person, state: terminal)), context: relayContext)

            var conversation = try await store.conversationSnapshot(context: relayContext)
            var thread = try XCTUnwrap(conversation.threads[request.request])
            XCTAssertTrue(thread.allowsDiscussion, "\(terminal) ends the answer flow, not Chat")
            XCTAssertEqual(thread.drafts[1]?.text, ExactText("Before answering"))
            XCTAssertEqual(thread.drafts[1]?.disposition, .saved)
            let edited = try await store.updateConversationDraftText(ExactText("After answering"),
                for: request, context: relayContext)
            XCTAssertEqual(edited.text, ExactText("After answering"))
            let operation = try await store.prepareDiscussion(request, context: relayContext)
            conversation = try await store.conversationSnapshot(context: relayContext)
            thread = try XCTUnwrap(conversation.threads[request.request])
            XCTAssertEqual(thread.drafts[1]?.disposition, .submitting(operation))
            let reply = ConversationTurn(id: ExactText("agent-reply"), binding: request,
                author: .agent, sessionHandle: ExactText("session"),
                text: ExactText("Chat continues"), kind: .reply)
            try await store.applyConversation(ConversationEvent(sequence: 3, binding: request,
                fact: .turn(reply)), context: relayContext)
            conversation = try await store.conversationSnapshot(context: relayContext)
            XCTAssertEqual(conversation.threads[request.request]?.latestAgentReply?.text,
                           ExactText("Chat continues"))

            let fixtureContext = context(.fixture)
            let fixture = try AttentionDomainStore(context: fixtureContext,
                persistence: MemoryAttentionStatePersistence())
            let fixtureRequest = binding(fixtureContext)
            try await fixture.applyConversation(ConversationEvent(sequence: 1, binding: fixtureRequest,
                fact: .request(sessionHandle: ExactText("session"), payload: .null)),
                context: fixtureContext)
            try await fixture.applyConversation(ConversationEvent(sequence: 2, binding: fixtureRequest,
                fact: .terminal(turn: ExactText("answer"), author: .person, state: terminal)),
                context: fixtureContext)
            try await fixture.saveConversationDraft(ConversationDraft(binding: fixtureRequest,
                text: ExactText("Local follow-up")), context: fixtureContext)
            try await fixture.appendFixtureDiscussion(fixtureRequest, context: fixtureContext)
            let fixtureConversation = try await fixture.conversationSnapshot(context: fixtureContext)
            XCTAssertEqual(fixtureConversation.threads[fixtureRequest.request]?.turns.last?.text,
                           ExactText("Local follow-up"))
        }
    }

    func testSenderClosureStillStopsChatDraftAndSend() async throws {
        let context = context(.fixture)
        let store = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
        let request = binding(context)
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: request,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        try await store.saveConversationDraft(ConversationDraft(binding: request,
            text: ExactText("Saved before withdrawal")), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 2, binding: request,
            fact: .terminal(turn: ExactText("withdrawal"), author: .origin, state: .cleared)), context: context)
        let conversation = try await store.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(conversation.threads[request.request])
        XCTAssertFalse(thread.allowsDiscussion)
        XCTAssertEqual(thread.drafts[1]?.disposition,
            .rejected(ExactText("Not delivered: request closed")))
        await assertThrowsAsync { try await store.updateConversationDraftText(ExactText("After withdrawal"),
            for: request, context: context) }
        await assertThrowsAsync { try await store.appendFixtureDiscussion(request, context: context) }
    }

    func testOldOrdinaryReplayCanGainMetadataWithoutChangingItsCursorOrDraft() async throws {
        let context = context()
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let first = binding(context)
        let request = StoredRequest(key: first.request,
            originalPayload: try JSONValue.parse(Data(#"{"title":"Original"}"#.utf8)))
        try await store.apply(RelayEvent(sequence: 1, body: .delivery(request, .message)), context: context)
        let before = try await store.snapshot(context: context)
        try await store.apply(RelayEvent(sequence: 1, body: .delivery(request, .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))), context: context)
        let after = try await store.snapshot(context: context)
        XCTAssertEqual(after.cursor, before.cursor)
        XCTAssertEqual(after.drafts, before.drafts)
        XCTAssertEqual(after.intents, before.intents)
        let conversation = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(conversation.cursor, 0)
        let thread = try XCTUnwrap(conversation.threads[first.request])
        XCTAssertEqual(thread.sessionHandle, ExactText("session"))
        XCTAssertNil(thread.latestAvailabilityObservation,
                     "The legacy unsupported default is not evidence that the Server reported unsupported.")

        var encodedThread = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(thread)) as? [String: Any])
        encodedThread.removeValue(forKey: "latestAvailabilityObservation")
        let priorThreadData = try JSONSerialization.data(withJSONObject: encodedThread)
        let priorThread = try JSONDecoder().decode(ConversationThread.self, from: priorThreadData)
        XCTAssertNil(priorThread.latestAvailabilityObservation)
        XCTAssertNil(priorThread.latestReportedAvailabilityObservation,
                     "A legacy unsupported default is still unknown, not a Server report.")

        var encodedFacts = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ConversationTurnFacts())) as? [String: Any])
        encodedFacts.removeValue(forKey: "acceptedAtMilliseconds")
        let priorFactsData = try JSONSerialization.data(withJSONObject: encodedFacts)
        XCTAssertNil(try JSONDecoder().decode(ConversationTurnFacts.self,
            from: priorFactsData).acceptedAtMilliseconds)
    }

    func testAcceptedFilesMatchOriginalBytesRatherThanLocalCopyIdentity() async throws {
        let context = context()
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let first = binding(context)
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: first,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        let bytes = Data([0, 255, 0, 2])
        let digest = ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let local = ConversationFile(id: ExactText("picker-uuid"), name: ExactText("original.bin"),
            byteCount: 4, sha256: digest, content: .localFile(ExactText("retained-copy")))
        try await store.saveConversationDraft(ConversationDraft(binding: first, text: ExactText("Exact bytes"), files: [local]), context: context)
        let operation = try await store.prepareDiscussion(first, context: context)
        let acceptedFile = ConversationFile(id: ExactText("original.bin"), name: local.name,
            byteCount: 4, sha256: digest, content: .inline(bytes))
        let accepted = ConversationTurn(id: ExactText("feed-2"), binding: first, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Exact bytes"), operationID: operation, files: [acceptedFile])
        try await store.applyConversation(ConversationEvent(sequence: 2, binding: first, fact: .turn(accepted)), context: context)
        let conversation = try await store.conversationSnapshot(context: context)
        XCTAssertNil(conversation.threads[first.request]?.drafts[1])
        XCTAssertEqual(conversation.threads[first.request]?.turns.first?.files, [acceptedFile])
    }

    func testGapConflictAndFailedPersistenceCannotAdvanceConversationOrLegacyCursor() async throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = binding(context)
        let first = ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null))
        persistence.failNextCommit()
        await assertThrowsAsync { try await store.applyConversation(first, context: context) }
        var conversation = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(conversation.cursor, 0)
        try await store.applyConversation(first, context: context)
        try await store.applyConversation(first, context: context)
        await assertThrowsAsync { try await store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .availability(sessionHandle: ExactText("session"), .listening)), context: context) }
        await assertThrowsAsync { try await store.finishConversationReplay(at: 3, context: context) }
        conversation = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(conversation.cursor, 1)
        let state = try await store.snapshot(context: context)
        XCTAssertEqual(state.cursor, 0)
    }

    func testTransferUseAvailabilityAndClosureRemainSeparateAndFixtureCannotSubmit() async throws {
        let context = context(.fixture)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let binding = binding(context)
        let bytes = Data([0, 255, 3, 0])
        let file = ConversationFile(id: ExactText("file"), name: ExactText("sample.bin"), byteCount: 4,
            sha256: ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()), content: .inline(bytes))
        let turn = ConversationTurn(id: ExactText("turn"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Sample"), files: [file])
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(turn)), context: context)
        try await store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .availability(sessionHandle: ExactText("session"), .gone)), context: context)
        var conversation = try await store.conversationSnapshot(context: context)
        var thread = try XCTUnwrap(conversation.threads[binding.request])
        XCTAssertNil(thread.terminal, "Gone is not authoritative closure")
        XCTAssertEqual(thread.latestReportedAvailabilityObservation,
            ConversationAvailabilityObservation(state: .gone))
        XCTAssertFalse(try XCTUnwrap(thread.facts[turn.id]).delivered)

        var priorVersionThreadObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(thread)) as? [String: Any])
        var priorObservation = try XCTUnwrap(
            priorVersionThreadObject["latestAvailabilityObservation"] as? [String: Any])
        priorObservation["source"] = "conversationEvent"
        priorObservation["conversationSequence"] = 3
        priorVersionThreadObject["latestAvailabilityObservation"] = priorObservation
        priorVersionThreadObject["availabilityAtAcceptance"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ConversationAvailability.notListening(lastDetachedAt: nil)))
        let priorVersionThread = try JSONDecoder().decode(ConversationThread.self,
            from: JSONSerialization.data(withJSONObject: priorVersionThreadObject))
        XCTAssertEqual(priorVersionThread.availability, .gone,
                       "The current report, not the retired acceptance snapshot, remains authoritative.")
        XCTAssertEqual(priorVersionThread.latestReportedAvailabilityObservation,
            ConversationAvailabilityObservation(state: .gone),
            "Previously persisted source/sequence fields are ignored while the reported state remains available.")

        var legacyThreadObject = priorVersionThreadObject
        legacyThreadObject.removeValue(forKey: "latestAvailabilityObservation")
        let legacyThread = try JSONDecoder().decode(ConversationThread.self,
            from: JSONSerialization.data(withJSONObject: legacyThreadObject))
        XCTAssertEqual(legacyThread.latestReportedAvailabilityObservation,
            ConversationAvailabilityObservation(state: .gone),
            "A legacy non-default availability value remains current when no observation wrapper was saved.")
        try await store.applyConversation(ConversationEvent(sequence: 4, binding: binding,
            fact: .fileTransfer(turn: turn.id, file: file.id, .transferred)), context: context)
        conversation = try await store.conversationSnapshot(context: context)
        thread = try XCTUnwrap(conversation.threads[binding.request])
        XCTAssertNil(thread.facts[turn.id]?.fileUses[file.id], "Transfer never invents agent use")
        try await store.applyConversation(ConversationEvent(sequence: 5, binding: binding,
            fact: .fileUse(turn: turn.id, file: file.id, .unusable(reason: ExactText("Unsupported format")))), context: context)
        try await store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Saved local draft"), files: [file]), context: context)
        await assertThrowsAsync { try await store.prepareDiscussion(binding, context: context) }
        try await store.applyConversation(ConversationEvent(sequence: 6, binding: binding,
            fact: .terminal(turn: ExactText("terminal"), author: .server, state: .expired)), context: context)
        conversation = try await store.conversationSnapshot(context: context)
        thread = try XCTUnwrap(conversation.threads[binding.request])
        XCTAssertEqual(thread.terminal, .expired)
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("Saved local draft"))
        XCTAssertEqual(thread.drafts[1]?.disposition, .rejected(ExactText("Not delivered: request closed")))
        let state = try await store.snapshot(context: context)
        XCTAssertTrue(state.outbox.isEmpty)
    }

    func testInlineBudgetIsAggregateFreshPerEntryAndUploadCapIsOnlyForUploads() throws {
        func file(_ name: String, _ size: UInt64) -> ConversationFile {
            ConversationFile(id: ExactText(name), name: ExactText(name), byteCount: size,
                sha256: ExactText("draft-digest"), content: .localFile(ExactText(name)))
        }
        let limits = ConversationFileLimits(inlineDecodedBytes: 262_144, uploadCap: nil)
        XCTAssertEqual(try limits.tiers(for: [file("whole", 262_144)]), [.inline])
        XCTAssertEqual(try limits.tiers(for: [file("larger", 262_145)]), [.upload])
        XCTAssertEqual(try limits.tiers(for: [file("a", 150_000), file("b", 150_000)]), [.inline, .upload])
        XCTAssertEqual(try limits.tiers(for: [file("new-entry", 262_144)]), [.inline])
        let testOnly = ConversationFileLimits(inlineDecodedBytes: 262_144, uploadCap: 100_000)
        XCTAssertEqual(try testOnly.tiers(for: [file("inline", 262_144)]), [.inline])
        XCTAssertThrowsError(try testOnly.tiers(for: [file("upload", 262_145)]))
    }
}
