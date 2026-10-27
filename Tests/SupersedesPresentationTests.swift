import AttentionDomain
import XCTest
@testable import Harklight

@MainActor
final class SupersedesPresentationTests: XCTestCase {
    private func profile() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("supersedes-test"),
            personID: ExactText("person"), deviceID: ExactText("reader")), transportMode: .relay)
    }

    func testDeliveryIDsAreOrderedDeduplicatedAndUnaffectedByLaterRevisionPayloads() throws {
        let context = profile()
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("new"))
        let original = try JSONValue.parse(Data(#"{"title":"New message","supersedes":["old",7,"older","old"]}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: original), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("origin"),
                                                     eventID: ExactText("delivery-event"))), context: context)

        let model = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(model.request(for: key)?.supersedesMessageIDs.map(\.rawValue), ["old", "older"])

        let revisionKey = ConversationBinding(request: key, revision: 2)
        let revision = ConversationTurn(id: ExactText("revision-event"), binding: revisionKey,
            author: .origin, sessionHandle: ExactText("origin"), text: ExactText("Updated wording"), kind: .revision)
        let revisedPayload = try JSONValue.parse(Data(#"{"title":"Updated wording","supersedes":["revision-only"]}"#.utf8))
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: revisionKey,
            fact: .revision(revision, payload: revisedPayload)), context: context)
        try model.refreshFromDurableStore()
        XCTAssertEqual(model.request(for: key)?.requestRevision, 2)
        XCTAssertEqual(model.request(for: key)?.supersedesMessageIDs.map(\.rawValue), ["old", "older"])

        let malformed = try JSONValue.parse(Data(#"{"supersedes":"old"}"#.utf8))
        let malformedRequest = StoredRequest(key: key, originalPayload: malformed)
        XCTAssertEqual(malformedRequest.supersedesMessageIDs, [])
    }

    func testSupersededTargetIsHiddenFromListProjectionsButRemainsReadableByKey() throws {
        let context = profile()
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let target = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("old"))
        let replacement = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("agent"), messageID: ExactText("new"))
        let payload = try JSONValue.parse(Data(#"{"title":"Message","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":"yes"}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: target, originalPayload: payload), .message)), context: context)
        try domain.apply(RelayEvent(sequence: 2,
            body: .delivery(StoredRequest(key: replacement, originalPayload: payload), .message)), context: context)
        try domain.apply(RelayEvent(sequence: 3,
            body: .terminal(target, .superseded, nil)), context: context)

        let model = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(model.inboxRows.map(\.key), [replacement])
        XCTAssertFalse(model.resolvedRequests.contains { $0.key == target })
        XCTAssertEqual(model.request(for: target)?.lifecycleStatus, .superseded)
    }
}
