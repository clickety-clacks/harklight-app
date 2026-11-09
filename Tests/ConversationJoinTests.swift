import AttentionDomain
import HarklightNativeRelay
import XCTest

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

final class ConversationJoinTests: XCTestCase {
    private func setup() throws -> (ProfileContext, MemoryAttentionStatePersistence, AttentionDomainStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("reader")), transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        return (context, persistence, domain, key)
    }
    func testRedactedNewQuestionCannotExposeOrReuseAnEarlierAnswerSelector() async throws {
        let (context, persistence, domain, key) = try setup()
        let payload = try JSONValue.parse(Data(#"{"title":"First question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Old choice","kind":"value","value":"old"}]}}"#.utf8))
        try await domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("handle"), eventID: ExactText("1"))), context: context)
        let port = AttentionDomainPort(store: domain)
        let initialInspection = try await port.inspect(context: port.context, request: key)
        let old = try XCTUnwrap(initialInspection.requests.first)
        let selector = try XCTUnwrap(old.selector)
        var draft = old.draft
        draft.compatibility.selectedActionID = ExactText("old")
        try await domain.saveDraft(draft, selector: selector, context: context)
        let redacted = ConversationTurn(id: ExactText("2"), binding: ConversationBinding(request: key, revision: 2),
            author: .origin, sessionHandle: ExactText("handle"), text: ExactText(""), contentRedacted: true, kind: .revision)
        try await domain.applyConversation(ConversationEvent(sequence: 1, binding: redacted.binding, fact: .redactedRevision(redacted)), context: context)
        await assertThrowsAsync { try await domain.saveDraft(draft, selector: selector, context: context) }
        await assertThrowsAsync { try await domain.selector(for: key, context: context) }
        let currentInspection = try await port.inspect(context: port.context, request: key)
        let current = try XCTUnwrap(currentInspection.requests.first)
        XCTAssertNil(current.selector)
        XCTAssertEqual(current.title, ExactText("Question content unavailable on this device"))
        let archivedDraft = try await port.inspectAnswerDraft(context: port.context, request: key, revision: 1)
        let archived = try XCTUnwrap(archivedDraft)
        XCTAssertEqual(archived.draft.compatibility.selectedActionID, ExactText("old"))
        XCTAssertNil(archived.selector)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let restoredConversation = try await restored.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(restoredConversation.threads[key])
        XCTAssertEqual(thread.revisionNumbers, [1, 2])
        XCTAssertTrue(thread.currentContentRedacted)
        XCTAssertEqual(thread.revisions[1], payload)
        let restoredState = try await restored.snapshot(context: context)
        XCTAssertEqual(restoredState.cursor, 1)
        XCTAssertEqual(restoredConversation.cursor, 1)
    }
    func testAdditiveInitialIdentityAndTerminalAuthorJoinWithoutExtraConversationEvents() async throws {
        let (context, _, domain, key) = try setup()
        let wire = try RelayWire(profile: context)
        let first = Data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"request","origin":"origin","as":"message","message":{"title":"Question"},"session_handle":"handle","request_revision":1,"event_id":"1","listening_support":{"route":"codex","origin":"origin","reported_at":5}}"#.utf8)
        try await domain.apply(wire.decodeEvent(first), context: context)
        let closed = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"request","origin":"origin","state":"cleared","by":"clear","request_revision":1,"event_id":"3","author":"origin"}"#.utf8)
        try await domain.apply(wire.decodeEvent(closed), context: context)
        let conversation = try await domain.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(conversation.threads[key])
        XCTAssertEqual(thread.turns.map(\.id), [ExactText("1"), ExactText("3")])
        XCTAssertEqual(thread.terminalAuthor, .origin, "Action label is not terminal author")
        XCTAssertEqual(thread.turns.last?.author, .origin)
        XCTAssertEqual(thread.listeningSupport?.uniqueValue(named: "route"), .string(ExactText("codex")))
        XCTAssertEqual(conversation.cursor, 0)
        let state = try await domain.snapshot(context: context)
        XCTAssertEqual(state.cursor, 2)
    }
    func testRetainedOriginContentCanGainMetadataWithoutReplacingItsDraftOrCursor() async throws {
        let (context, _, domain, key) = try setup()
        let request = StoredRequest(key: key, originalPayload: try JSONValue.parse(Data(#"{"title":"Retained original"}"#.utf8)))
        await assertThrowsAsync { try await domain.apply(RelayEvent(sequence: 1, body: .originReference(key)), context: context) }
        try await domain.resolveOriginReference(sequence: 1, request: request, context: context)
        let before = try await domain.snapshot(context: context)
        try await domain.apply(RelayEvent(sequence: 1, body: .originReference(key), conversation: RelayConversationMetadata(
            revision: 1, sessionHandle: ExactText("handle"), eventID: ExactText("1"))), context: context)
        let after = try await domain.snapshot(context: context)
        XCTAssertEqual(after.cursor, before.cursor)
        XCTAssertEqual(after.drafts, before.drafts)
        XCTAssertEqual(after.requests[key]?.originalPayload, request.originalPayload)
        XCTAssertEqual(after.requests[key]?.acceptanceOrder, 1)
        let conversation = try await domain.conversationSnapshot(context: context)
        XCTAssertEqual(conversation.cursor, 0)
        XCTAssertEqual(conversation.threads[key]?.turns.first?.id, ExactText("1"))
    }
    func testOriginPortDiscoveryUsesOnlyTheEnrolledServerAndDisappearsWhenNotPublished() throws {
        let (context, _, _, _) = try setup()
        let wire = try ConversationWire(profile: context)
        let reply = Data(#"{"v":1,"type":"ok","ref":"native-conversation-sync","origin_https_port":9443,"host":"ignored.example"}"#.utf8)
        XCTAssertEqual(try wire.originEndpoint(reply)?.absoluteString, "https://relay.example:9443/origin/v1")
        XCTAssertNil(try wire.originEndpoint(Data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#.utf8)))
        XCTAssertThrowsError(try wire.originEndpoint(Data(#"{"v":1,"type":"ok","ref":"native-conversation-sync","origin_https_port":0}"#.utf8)))
    }
}
