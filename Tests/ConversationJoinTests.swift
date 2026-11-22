import AttentionDomain
import HarklightNativeRelay
import XCTest

final class ConversationJoinTests: XCTestCase {
    private func setup() throws -> (ProfileContext, MemoryPendingActionPersistence, ClientRepository, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("reader")), transportMode: .relay)
        let persistence = MemoryPendingActionPersistence()
        let domain = try ClientRepository(context: context, persistence: persistence)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        return (context, persistence, domain, key)
    }
    func testRetainedOriginContentCanGainMetadataWithoutReplacingItsDraftOrCursor() throws {
        let (context, _, domain, key) = try setup()
        let request = StoredRequest(key: key, originalPayload: try JSONValue.parse(Data(#"{"title":"Retained original"}"#.utf8)))
        XCTAssertThrowsError(try domain.apply(RelayEvent(sequence: 1, body: .originReference(key)), context: context))
        try domain.resolveOriginReference(sequence: 1, request: request, context: context)
        let before = try domain.snapshot(context: context)
        try domain.apply(RelayEvent(sequence: 1, body: .originReference(key), conversation: RelayConversationMetadata(
            revision: 1, sessionHandle: ExactText("handle"), eventID: ExactText("1"))), context: context)
        let after = try domain.snapshot(context: context)
        XCTAssertEqual(after.cursor, before.cursor)
        XCTAssertEqual(after.drafts, before.drafts)
        XCTAssertEqual(after.requests[key]?.originalPayload, request.originalPayload)
        XCTAssertEqual(after.requests[key]?.acceptanceOrder, 1)
        XCTAssertEqual(try domain.conversationSnapshot(context: context).cursor, 0)
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[key]?.turns.first?.id, ExactText("1"))
    }
}
