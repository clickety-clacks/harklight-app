import AttentionDomain
import HarklightNativeRelay
import XCTest
@testable import Harklight

@MainActor
final class LiveMessageLookupTests: XCTestCase {
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


    private func waitUntil(_ condition: () -> Bool, _ message: String) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    private func unorderedCache(_ key: RequestKey, payload: JSONValue,
                                identity: ProfileIdentity) -> CachedAttentionServerState {
        // A restored request that has lost its inbox order cannot be presented.
        CachedAttentionServerState(identity: identity,
            requests: [key: StoredRequest(key: key, originalPayload: payload)], remoteStates: [:],
            cursor: 1, conversationCursor: 0, conversations: [:], inboxView: nil, currentRequestKeys: [key])
    }

    func testActivationRebuildsAnUnpresentableRestoredCacheAndKeepsTheQueue() async throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("activation-" + UUID().uuidString),
            deviceID: ExactText("reader")), transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("message"))
        let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":{"ok":true}}]}}"#.utf8))
        _ = try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let port = AttentionDomainPort(store: domain)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let unsent = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        try domain.restoreCachedServerState(unorderedCache(key, payload: payload, identity: context.identity),
                                            context: context)
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cache = FileServerStateCache(identity: context.identity, fileURL: cacheURL)
        try await cache.save(ServerStateCacheSnapshot(identity: context.identity, cursor: 1, conversationCursor: 0,
            requests: [], conversations: [], inboxView: nil, currentRequestKeys: nil))

        let activation = try await LivePresentationStore.makeForActivationRecoveringSavedState(
            store: domain, context: context, serverStateCache: cache)

        XCTAssertNil(activation.presentation.request(for: key), "The bad cache is gone; the relay rebuilds it.")
        let savedCache = try await cache.load()
        XCTAssertNil(savedCache, "The cache file is discarded too, so a relaunch cannot restore it.")
        XCTAssertEqual(try domain.snapshot(context: context).intents[unsent.intentID]?.operationID, unsent.opID,
                       "The unsent answer is kept under its original operation ID.")
    }

    func testLiveObserverRecoversFromUnpresentableStateAndKeepsUpdating() async throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("observer-" + UUID().uuidString),
            deviceID: ExactText("reader")), transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("message"))
        let laterKey = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("later-message"))
        let payload = try JSONValue.parse(Data(#"{"title":"Question"}"#.utf8))
        _ = try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let model = try await LivePresentationStore.makeForActivation(store: domain, context: context).presentation
        model.startObserving()
        defer { model.stopObserving() }

        try domain.restoreCachedServerState(unorderedCache(key, payload: payload, identity: context.identity),
                                            context: context)
        try await waitUntil({ (try? domain.snapshot(context: context).requests.isEmpty) == true },
                            "The observer discards the saved state it cannot present.")

        _ = try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: laterKey, originalPayload: payload), .message)), context: context)
        try await waitUntil({ model.request(for: laterKey) != nil },
                            "Later updates still reach the view without a relaunch.")
        XCTAssertNil(model.observationError)
    }
}
