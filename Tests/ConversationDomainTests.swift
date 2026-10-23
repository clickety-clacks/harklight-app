import AttentionDomain
import CryptoKit
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

final class ConversationDomainTests: XCTestCase {
    private func context(_ mode: AttentionTransportMode = .relay) -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("conversation-test"),
            personID: ExactText("fictional-person"), deviceID: ExactText("fictional-device")), transportMode: mode)
    }

    private func binding(_ context: ProfileContext, _ revision: UInt64 = 1) -> ConversationBinding {
        ConversationBinding(request: RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request")), revision: revision)
    }

    func testRevisionBoundHistoryDraftAndReceiptsSurviveRestartWithoutAdvancingLegacyCursor() throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let first = binding(context)
        let second = binding(context, 2)
        try store.applyConversation(ConversationEvent(sequence: 1, binding: first,
            fact: .request(sessionHandle: ExactText("original-session"), payload: .string(ExactText("First wording")))), context: context)
        let draft = ConversationDraft(binding: first, text: ExactText("Question about the first wording"))
        try store.saveConversationDraft(draft, context: context)
        let person = ConversationTurn(id: ExactText("turn-1"), binding: first, author: .person,
            sessionHandle: ExactText("original-session"), text: ExactText("Which environment?"))
        try store.applyConversation(ConversationEvent(sequence: 2, binding: first, fact: .turn(person)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 3, binding: second,
            fact: .request(sessionHandle: ExactText("original-session"), payload: .string(ExactText("New wording")))), context: context)
        // A later receipt names the original turn without rebinding that turn to revision 2.
        try store.applyConversation(ConversationEvent(sequence: 4, binding: second,
            fact: .delivered(turn: person.id)), context: context)
        let reply = ConversationTurn(id: ExactText("turn-2"), binding: second, author: .origin,
            sessionHandle: ExactText("original-session"), text: ExactText("Production"), inReplyTo: person.id)
        try store.applyConversation(ConversationEvent(sequence: 5, binding: second, fact: .turn(reply)), context: context)
        XCTAssertNil(try store.conversationSnapshot(context: context).threads[first.request]?.facts[person.id]?.actedBy,
                     "A reply is not an inferred acted fact")
        try store.applyConversation(ConversationEvent(sequence: 6, binding: second,
            fact: .acted(turn: person.id, by: reply.id)), context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let snapshot = try restored.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(snapshot.threads[first.request])
        XCTAssertEqual(snapshot.cursor, 6)
        XCTAssertEqual(try restored.snapshot(context: context).cursor, 0)
        XCTAssertEqual(thread.currentRevision, 2)
        XCTAssertEqual(thread.turns.first?.binding, first)
        XCTAssertEqual(thread.turns.last?.inReplyTo, person.id)
        XCTAssertEqual(thread.facts[person.id]?.delivered, true)
        XCTAssertEqual(thread.facts[person.id]?.actedBy, reply.id)
        XCTAssertEqual(thread.drafts[1], draft)
    }

    func testConversationTurnOrderFollowsProjectionSequenceAndPreservesReplyFacts() throws {
        let context = context()
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let binding = binding(context)
        try store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
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

        try store.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(prompt)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .delivered(turn: prompt.id)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 4, binding: binding, fact: .turn(reply)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 5, binding: binding,
            fact: .acted(turn: prompt.id, by: reply.id)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 6, binding: binding, fact: .turn(agentReply)), context: context)

        let thread = try XCTUnwrap(store.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(thread.turns.map(\.id), [prompt.id, reply.id, agentReply.id])
        XCTAssertEqual(thread.turns.map(\.inReplyTo), [nil, prompt.id, reply.id])
        XCTAssertEqual(thread.facts[prompt.id]?.delivered, true)
        XCTAssertEqual(thread.facts[prompt.id]?.actedBy, reply.id)
        XCTAssertNil(thread.facts[reply.id]?.actedBy, "A reply does not imply that its own prompt was acted on")
    }

    func testReloadRepairsLegacyTurnOrderFromProjectionSequenceWithoutDroppingHistory() throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = binding(context)
        try store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        let prompt = ConversationTurn(id: ExactText("30"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Which option should we use?"))
        let reply = ConversationTurn(id: ExactText("20"), binding: binding, author: .origin,
            sessionHandle: ExactText("session"), text: ExactText("Use the reversible option."),
            inReplyTo: prompt.id)
        let agentReply = ConversationTurn(id: ExactText("10"), binding: binding, author: .agent,
            sessionHandle: ExactText("session"), text: ExactText("I will use the reversible option."),
            inReplyTo: reply.id, kind: .reply)
        try store.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(prompt)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .delivered(turn: prompt.id)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 4, binding: binding, fact: .turn(reply)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 5, binding: binding,
            fact: .acted(turn: prompt.id, by: reply.id)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 6, binding: binding, fact: .turn(agentReply)), context: context)

        // Recreate the legacy saved-array ordering while leaving the sequence journal intact.
        let current = try XCTUnwrap(persistence.load(identity: context.identity))
        var propertyList = try PropertyListSerialization.propertyList(from: current,
            options: [.mutableContainersAndLeaves], format: nil)
        XCTAssertEqual(reversePersistedConversationTurnArrays(in: &propertyList), 1)
        let encoded = try PropertyListSerialization.data(fromPropertyList: propertyList,
            format: .binary, options: 0)

        let restoredStore = try AttentionDomainStore(context: context,
            persistence: SeededAttentionStatePersistence(state: encoded))
        let restored = try XCTUnwrap(restoredStore.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(restored.turns.map(\.id), [prompt.id, reply.id, agentReply.id])
        XCTAssertEqual(restored.turns.map(\.inReplyTo), [nil, prompt.id, reply.id])
        XCTAssertEqual(restored.facts[prompt.id]?.delivered, true)
        XCTAssertEqual(restored.facts[prompt.id]?.actedBy, reply.id)
        XCTAssertEqual(restored.turns.count, 3)
    }

    func testReloadOrdersOrdinaryTerminalTurnFromItsConversationProjectionSequence() throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = binding(context)
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: binding.request, originalPayload: .null), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)

        // The ordinary lifecycle event contributes this terminal row without borrowing
        // the conversation cursor. Its matching projection fact is the ordering evidence.
        let terminalID = ExactText("20")
        try store.apply(RelayEvent(sequence: 2, body: .terminal(binding.request, .expired, nil),
            conversation: RelayConversationMetadata(revision: 1, eventID: terminalID, author: .server)),
            context: context)

        let prompt = ConversationTurn(id: ExactText("30"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Which option should we use?"))
        let reply = ConversationTurn(id: ExactText("40"), binding: binding, author: .agent,
            sessionHandle: ExactText("session"), text: ExactText("Use the reversible option."),
            inReplyTo: prompt.id, kind: .reply)
        try store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .turn(prompt)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(reply)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .terminal(turn: terminalID, author: .server, state: .expired)), context: context)

        // This matches the legacy numeric-ID ordering that placed the terminal first.
        let beforeReload = try XCTUnwrap(store.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(beforeReload.turns.map(\.id), [terminalID, prompt.id, reply.id])

        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let thread = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(thread.turns.map(\.id), [prompt.id, reply.id, terminalID])
        XCTAssertEqual(thread.turns.map(\.inReplyTo), [nil, prompt.id, nil])
        XCTAssertEqual(thread.turns.last?.kind, .terminal)
        XCTAssertEqual(thread.terminal, .expired)
    }

    func testConversationCanArriveBeforeOrdinaryDeliveryWithoutCreatingOrphanedLegacyState() throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let first = binding(context)
        let second = binding(context, 2)
        let original = try JSONValue.parse(Data(#"{"title":"Original"}"#.utf8))
        let revised = try JSONValue.parse(Data(#"{"title":"Revised"}"#.utf8))
        try store.applyConversation(ConversationEvent(sequence: 1, binding: first,
            fact: .request(sessionHandle: ExactText("origin"), payload: original)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 2, binding: second,
            fact: .request(sessionHandle: ExactText("origin"), payload: revised)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 3, binding: second,
            fact: .terminal(turn: ExactText("terminal"), author: .server, state: .expired)), context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        XCTAssertTrue(try restored.snapshot(context: context).drafts.isEmpty)
        XCTAssertTrue(try restored.snapshot(context: context).remoteStates.isEmpty)
        try restored.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: first.request, originalPayload: original), .message)), context: context)
        let snapshot = try restored.snapshot(context: context)
        XCTAssertEqual(snapshot.requests[first.request]?.originalPayload, revised)
        XCTAssertEqual(snapshot.remoteStates[first.request]?.state, .expired)
        XCTAssertEqual(snapshot.cursor, 1)
        XCTAssertEqual(try restored.conversationSnapshot(context: context).cursor, 3)
        _ = try AttentionDomainStore(context: context, persistence: persistence)
    }

    func testUnknownSubmissionKeepsExactOperationAndDraftUntilMatchingAcceptedTurn() throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = binding(context)
        try store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Keep exactly this")), context: context)
        let operation = try store.prepareDiscussion(binding, context: context)
        try store.markDiscussionOutcome(binding, operation: operation, rejection: nil, context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        XCTAssertEqual(try restored.prepareDiscussion(binding, context: context), operation)
        let unrelated = ConversationTurn(id: ExactText("other-turn"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Different"), operationID: UUID())
        try restored.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(unrelated)), context: context)
        XCTAssertEqual(try restored.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.text,
                       ExactText("Keep exactly this"))
        let accepted = ConversationTurn(id: ExactText("accepted-turn"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Keep exactly this"), operationID: operation)
        try restored.applyConversation(ConversationEvent(sequence: 3, binding: binding, fact: .turn(accepted)), context: context)
        XCTAssertNil(try restored.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
    }

    func testOrdinaryMetadataBootstrapsConversationAndTerminalBeforeHistoryDoesNotLoseHistory() throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let first = binding(context)
        let original = try JSONValue.parse(Data(#"{"title":"Original"}"#.utf8))
        let request = StoredRequest(key: first.request, originalPayload: original)
        try store.apply(RelayEvent(sequence: 1, body: .delivery(request, .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"),
                availability: .listening)), context: context)
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 0,
                       "Ordinary metadata must not fabricate a conversation sequence")
        try store.saveConversationDraft(ConversationDraft(binding: first, text: ExactText("Keep draft")), context: context)
        try store.apply(RelayEvent(sequence: 2, body: .terminal(first.request, .answered, nil),
            conversation: RelayConversationMetadata(revision: 2, eventID: ExactText("terminal-4"))), context: context)
        let earlier = ConversationTurn(id: ExactText("discussion-2"), binding: first, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Earlier discussion"))
        try store.applyConversation(ConversationEvent(sequence: 1, binding: first, fact: .turn(earlier)), context: context)
        let revised = try JSONValue.parse(Data(#"{"title":"Revised"}"#.utf8))
        let second = binding(context, 2)
        let revision = ConversationTurn(id: ExactText("revision-3"), binding: second, author: .origin,
            sessionHandle: ExactText("session"), text: ExactText(""), inReplyTo: earlier.id, kind: .revision)
        try store.applyConversation(ConversationEvent(sequence: 2, binding: second,
            fact: .revision(revision, payload: revised)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 3, binding: second,
            fact: .delivered(turn: ExactText("terminal-4"))), context: context)
        XCTAssertThrowsError(try store.saveConversationDraft(ConversationDraft(binding: second,
            text: ExactText("Cannot submit after closure")), context: context))
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let snapshot = try restored.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(snapshot.threads[first.request])
        XCTAssertEqual(snapshot.cursor, 3)
        XCTAssertEqual(try restored.snapshot(context: context).cursor, 2)
        XCTAssertEqual(thread.currentRevision, 2)
        XCTAssertEqual(thread.revisions[1], original)
        XCTAssertEqual(thread.revisions[2], revised)
        XCTAssertEqual(thread.turns.map(\.id), [earlier.id, revision.id])
        XCTAssertEqual(thread.terminal, .answered)
        XCTAssertEqual(thread.facts[ExactText("terminal-4")]?.delivered, true)
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("Keep draft"))
    }

    func testOldOrdinaryReplayCanGainMetadataWithoutChangingItsCursorOrDraft() throws {
        let context = context()
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let first = binding(context)
        let request = StoredRequest(key: first.request,
            originalPayload: try JSONValue.parse(Data(#"{"title":"Original"}"#.utf8)))
        try store.apply(RelayEvent(sequence: 1, body: .delivery(request, .message)), context: context)
        let before = try store.snapshot(context: context)
        try store.apply(RelayEvent(sequence: 1, body: .delivery(request, .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))), context: context)
        let after = try store.snapshot(context: context)
        XCTAssertEqual(after.cursor, before.cursor)
        XCTAssertEqual(after.drafts, before.drafts)
        XCTAssertEqual(after.intents, before.intents)
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 0)
        XCTAssertEqual(try store.conversationSnapshot(context: context).threads[first.request]?.sessionHandle, ExactText("session"))
    }

    func testAcceptedFilesMatchOriginalBytesRatherThanLocalCopyIdentity() throws {
        let context = context()
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let first = binding(context)
        try store.applyConversation(ConversationEvent(sequence: 1, binding: first,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        let bytes = Data([0, 255, 0, 2])
        let digest = ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let local = ConversationFile(id: ExactText("picker-uuid"), name: ExactText("original.bin"),
            byteCount: 4, sha256: digest, content: .localFile(ExactText("retained-copy")))
        try store.saveConversationDraft(ConversationDraft(binding: first, text: ExactText("Exact bytes"), files: [local]), context: context)
        let operation = try store.prepareDiscussion(first, context: context)
        let acceptedFile = ConversationFile(id: ExactText("original.bin"), name: local.name,
            byteCount: 4, sha256: digest, content: .inline(bytes))
        let accepted = ConversationTurn(id: ExactText("feed-2"), binding: first, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Exact bytes"), operationID: operation, files: [acceptedFile])
        try store.applyConversation(ConversationEvent(sequence: 2, binding: first, fact: .turn(accepted)), context: context)
        XCTAssertNil(try store.conversationSnapshot(context: context).threads[first.request]?.drafts[1])
        XCTAssertEqual(try store.conversationSnapshot(context: context).threads[first.request]?.turns.first?.files, [acceptedFile])
    }

    func testGapConflictAndFailedPersistenceCannotAdvanceConversationOrLegacyCursor() throws {
        let context = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = binding(context)
        let first = ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null))
        persistence.failNextCommit()
        XCTAssertThrowsError(try store.applyConversation(first, context: context))
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 0)
        try store.applyConversation(first, context: context)
        try store.applyConversation(first, context: context)
        XCTAssertThrowsError(try store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .availability(sessionHandle: ExactText("session"), .listening)), context: context))
        XCTAssertThrowsError(try store.finishConversationReplay(at: 3, context: context))
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 1)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 0)
    }

    func testTransferUseAvailabilityAndClosureRemainSeparateAndFixtureCannotSubmit() throws {
        let context = context(.fixture)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let binding = binding(context)
        let bytes = Data([0, 255, 3, 0])
        let file = ConversationFile(id: ExactText("file"), name: ExactText("sample.bin"), byteCount: 4,
            sha256: ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()), content: .inline(bytes))
        let turn = ConversationTurn(id: ExactText("turn"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Sample"), files: [file])
        try store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(turn)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .availability(sessionHandle: ExactText("session"), .gone)), context: context)
        var thread = try XCTUnwrap(store.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertNil(thread.terminal, "Gone is not authoritative closure")
        XCTAssertFalse(try XCTUnwrap(thread.facts[turn.id]).delivered)
        try store.applyConversation(ConversationEvent(sequence: 4, binding: binding,
            fact: .fileTransfer(turn: turn.id, file: file.id, .transferred)), context: context)
        thread = try XCTUnwrap(store.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertNil(thread.facts[turn.id]?.fileUses[file.id], "Transfer never invents agent use")
        try store.applyConversation(ConversationEvent(sequence: 5, binding: binding,
            fact: .fileUse(turn: turn.id, file: file.id, .unusable(reason: ExactText("Unsupported format")))), context: context)
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Saved local draft"), files: [file]), context: context)
        XCTAssertThrowsError(try store.prepareDiscussion(binding, context: context))
        try store.applyConversation(ConversationEvent(sequence: 6, binding: binding,
            fact: .terminal(turn: ExactText("terminal"), author: .server, state: .expired)), context: context)
        thread = try XCTUnwrap(store.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(thread.terminal, .expired)
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("Saved local draft"))
        XCTAssertEqual(thread.drafts[1]?.disposition, .rejected(ExactText("Not delivered: request closed")))
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
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
