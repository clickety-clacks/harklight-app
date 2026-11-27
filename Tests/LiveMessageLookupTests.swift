import AttentionDomain
import XCTest
@testable import Harklight

@MainActor
final class LiveMessageLookupTests: XCTestCase {
    func testFailedSnapshotRestoreKeepsTheCommittedMessageSelectable() async throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("restore-reader"), deviceID: ExactText("reader")), transportMode: .relay)
        let persistence = MemoryPendingActionPersistence()
        let domain = try ClientRepository(context: context, persistence: persistence)
        let sender = ExactText("sender")
        let existing = RequestKey(accountScope: context.identity.personID,
                                  senderID: sender, messageID: ExactText("existing"))
        let fetched = RequestKey(accountScope: context.identity.personID,
                                 senderID: sender, messageID: ExactText("fetched"))
        let existingPayload = try JSONValue.parse(Data(#"{"title":"Committed message"}"#.utf8))
        let fetchedPayload = try JSONValue.parse(Data(#"{"title":"Fetched message"}"#.utf8))
        let existingRequest = StoredRequest(key: existing, originalPayload: existingPayload)
        let fetchedRequest = StoredRequest(key: fetched, originalPayload: fetchedPayload)
        let fixture = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        for store in [domain, fixture] {
            _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(existingRequest, .message)),
                                context: context)
        }
        _ = try fixture.apply(RelayEvent(sequence: 2, body: .delivery(fetchedRequest, .message)),
                              context: context)
        let snapshot = CachedAttentionServerState(identity: context.identity,
            requests: try fixture.snapshot(context: context).requests, remoteStates: [:],
            cursor: 2, conversationCursor: 0, conversations: [:], inboxView: nil,
            currentRequestKeys: [existing, fetched])
        let model = try await LivePresentationStore.makeForActivation(store: domain, context: context).presentation

        persistence.failNextCommit()
        XCTAssertThrowsError(try domain.restoreCachedServerState(snapshot, context: context))
        try model.refreshFromDurableStore()
        model.selectRequest(existing)
        XCTAssertEqual(model.selectedRequest?.title, ExactText("Committed message"))
        model.selectRequest(fetched)
        XCTAssertEqual(model.selectedRequest?.key, existing)
        XCTAssertEqual(try domain.snapshot(context: context).cursor, 1)
        XCTAssertTrue(try domain.snapshot(context: context).pendingMessageOpens.isEmpty)

        try domain.restoreCachedServerState(snapshot, context: context)
        try model.refreshFromDurableStore()
        model.selectRequest(fetched)
        XCTAssertEqual(model.selectedRequest?.title, ExactText("Fetched message"))
    }

    func testActivatedMessageAndSelectionFollowSenderRevisionWithoutRegressing() async throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("lookup-" + UUID().uuidString),
            deviceID: ExactText("reader")), transportMode: .relay)
        let domain = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("message"))
        let laterKey = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("later-message"))
        let original = try JSONValue.parse(Data(#"{"title":"Original wording"}"#.utf8))
        let revised = try JSONValue.parse(Data(#"{"title":"Revised wording"}"#.utf8))
        _ = try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: original), .message),
            conversation: RelayConversationMetadata(revision: 1,
                sessionHandle: ExactText("handle"), eventID: ExactText("1"))), context: context)
        let port = AttentionDomainPort(store: domain)
        let oldSnapshot = try port.observe(context: port.context)
        let model = try await LivePresentationStore.makeForActivation(
            store: domain, context: context).presentation
        XCTAssertEqual(model.request(for: key)?.title, ExactText("Original wording"))
        XCTAssertNil(model.selectedRequest, "Activation leaves the inbox unselected.")
        model.selectRequest(key)
        XCTAssertEqual(model.selectedRequest?.key, key)
        XCTAssertNil(model.request(for: laterKey))

        let revision = ConversationTurn(id: ExactText("revision-2"),
            binding: ConversationBinding(request: key, revision: 2),
            author: .origin, sessionHandle: ExactText("handle"),
            text: ExactText(""), kind: .revision)
        _ = try domain.applyConversation(ConversationEvent(sequence: 1,
            binding: revision.binding, fact: .revision(revision, payload: revised)), context: context)
        _ = try domain.apply(RelayEvent(sequence: 2,
            body: .delivery(StoredRequest(key: laterKey, originalPayload: original), .message)),
            context: context)
        let currentSnapshot = try port.observe(context: port.context)
        _ = try await model.adoptForLiveUpdates(currentSnapshot)
        XCTAssertEqual(model.request(for: key)?.title, ExactText("Revised wording"))
        XCTAssertEqual(model.selectedRequest?.title, ExactText("Revised wording"))
        XCTAssertEqual(model.request(for: laterKey)?.key, laterKey)

        _ = try await model.adoptForLiveUpdates(oldSnapshot)
        XCTAssertEqual(model.request(for: key)?.title, ExactText("Revised wording"))
        XCTAssertEqual(model.selectedRequest?.title, ExactText("Revised wording"))
        XCTAssertEqual(model.request(for: laterKey)?.key, laterKey)
    }
}
