import AttentionDomain
import CryptoKit
import XCTest

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
