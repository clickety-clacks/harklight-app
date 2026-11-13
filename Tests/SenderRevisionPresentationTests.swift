import AttentionDomain
import HarklightNativeRelay
import XCTest
@testable import Harklight

@MainActor
final class SenderRevisionPresentationTests: XCTestCase {
    func testAcceptedSenderUpdateRetainsEarlierChoicesTurnsAndQueuedAnswerBinding() async throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("reader")), transportMode: .relay)
        let persistence = MemoryPendingActionPersistence()
        let domain = try ClientRepository(context: context, persistence: persistence)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("same-item"))
        let oldPayload = try JSONValue.parse(Data(#"{"title":"Earlier wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Earlier choice","kind":"value","value":"old"}]}}"#.utf8))
        let newPayload = try JSONValue.parse(Data(#"{"title":"Current wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"new","label":"Current choice","kind":"value","value":"new"}]}}"#.utf8))
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cacheURL = cacheDirectory.appendingPathComponent("server-cache.json")
        let cache = FileServerStateCache(identity: context.identity, fileURL: cacheURL)
        let confirmation = try await NativeRelayLifecycle.shared.confirmInProcessSessionForTesting(
            store: domain, context: context,
            session: ReplyCheckpointSession(identity: context.identity, key: key, payload: oldPayload),
            serverStateCache: cache)
        XCTAssertTrue(confirmation.relayConfirmed)
        try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: oldPayload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("handle"), eventID: ExactText("1"))), context: context)
        let port = AttentionDomainPort(store: domain)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let model = try LivePresentationStore(store: domain, context: context)
        model.updateConversation(for: key, revision: 1, text: "An unsent local discussion edit")
        XCTAssertFalse(model.hasAcceptedUpdate(for: key), "Local edits are not accepted sender revisions")
        var oldDraft = try XCTUnwrap(domain.snapshot(context: context).drafts[key])
        oldDraft.compatibility.selectedActionID = ExactText("old")
        try domain.saveDraft(oldDraft, selector: selector, context: context)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
            inputs: [.compatibilityValue(action: ExactText("old"))]))
        let original = try XCTUnwrap(domain.lookupIntent(receipt.intentID, context: context))
        let update = ConversationTurn(id: ExactText("3"), binding: ConversationBinding(request: key, revision: 2),
            author: .origin, sessionHandle: ExactText("handle"), text: ExactText(""), kind: .revision)
        var expectedUpdate = update
        expectedUpdate.conversationSequence = 1
        let event = ConversationEvent(sequence: 1, binding: update.binding, fact: .revision(update, payload: newPayload))
        try domain.applyConversation(event, context: context)
        try domain.applyConversation(event, context: context)
        try model.refreshFromDurableStore()
        XCTAssertTrue(model.hasAcceptedUpdate(for: key))
        XCTAssertEqual(model.inboxRows.count, 1)
        XCTAssertEqual(model.inboxRows.first?.key, key)
        XCTAssertTrue(try XCTUnwrap(model.request(for: key)).inboxStateIsCurrent)
        let currentStatusParts = try XCTUnwrap(model.inboxRows.first?.status).components(separatedBy: " · ")
        XCTAssertTrue(currentStatusParts.contains("Updated"))
        XCTAssertTrue(currentStatusParts.contains("Open"),
                      "A current open request retains its lifecycle label beside Updated.")
        XCTAssertEqual(model.request(for: key)?.title, ExactText("Current wording"))
        let earlier = try XCTUnwrap(model.historicalAnswerDraft(for: key, revision: 1))
        XCTAssertEqual(earlier.title, ExactText("Earlier wording"))
        XCTAssertEqual(earlier.draft.compatibility.selectedActionID, ExactText("old"))
        XCTAssertNil(earlier.selector)
        let thread = try XCTUnwrap(model.conversation(for: key))
        XCTAssertEqual(thread.acceptedUpdates, [expectedUpdate], "Replay must not invent another update fact")
        XCTAssertEqual(thread.revisions[1], oldPayload)
        XCTAssertEqual(thread.revisions[2], newPayload)
        XCTAssertEqual(thread.turns.map(\.id), [ExactText("1"), ExactText("3")])
        let retained = try XCTUnwrap(domain.lookupIntent(receipt.intentID, context: context))
        XCTAssertEqual(retained.intentID, original.intentID)
        XCTAssertEqual(retained.operationID, original.operationID)
        XCTAssertEqual(retained.operation, original.operation)
        XCTAssertEqual(retained.answer, original.answer)
        XCTAssertEqual(retained.requestRevision, 1)
        XCTAssertEqual(retained.disposition, .lost)
        XCTAssertTrue(try domain.snapshot(context: context).outbox.isEmpty)
        XCTAssertThrowsError(try domain.saveDraft(oldDraft, selector: selector, context: context))
        try await cache.save(ServerStateCacheSnapshot.make(identity: context.identity,
            from: domain.snapshot(context: context), conversations: domain.conversationSnapshot(context: context)))
        let cachedValue = try await FileServerStateCache(identity: context.identity, fileURL: cacheURL).load()
        let cached = try XCTUnwrap(cachedValue)
        let restored = try ClientRepository(context: context, persistence: persistence)
        XCTAssertTrue(try restored.conversationSnapshot(context: context).threads.isEmpty)
        try restored.restoreCachedServerState(cached.attentionDomainState(for: context.identity),
                                              context: context)
        XCTAssertEqual(try restored.conversationSnapshot(context: context).threads[key]?.acceptedUpdates,
                       [expectedUpdate])
        XCTAssertNil(try restored.lookupIntent(receipt.intentID, context: context),
                     "The old revision is no longer an eligible unsent operation after the server replaces it.")
        XCTAssertTrue(try restored.snapshot(context: context).outbox.isEmpty)
        XCTAssertEqual(try restored.snapshot(context: context).requests[key]?.originalPayload, newPayload)

        let staleSnapshot = ServerStateCacheSnapshot(identity: context.identity,
            cursor: cached.cursor, conversationCursor: cached.conversationCursor,
            requests: cached.requests, conversations: cached.conversations,
            inboxView: cached.inboxView, currentRequestKeys: [],
            chatReadPositions: cached.chatReadPositions)
        try await cache.save(staleSnapshot)
        let staleCachedValue = try await cache.load()
        let staleCached = try XCTUnwrap(staleCachedValue)
        let staleRepository = try ClientRepository(context: context, persistence: persistence)
        try staleRepository.restoreCachedServerState(
            staleCached.attentionDomainState(for: context.identity), context: context)
        let staleModel = try LivePresentationStore(store: staleRepository, context: context)
        let staleRequest = try XCTUnwrap(staleModel.request(for: key))
        let staleRow = try XCTUnwrap(staleModel.inboxRows.first { $0.key == key })
        XCTAssertFalse(staleRequest.inboxStateIsCurrent)
        XCTAssertTrue(staleModel.hasAcceptedUpdate(for: key),
                      "The accepted revision must still come from the server conversation cache.")
        let staleStatusParts = staleRow.status.components(separatedBy: " · ")
        XCTAssertTrue(staleStatusParts.contains("Updated"),
                      "A noncurrent cached inbox must retain the server-supplied accepted-revision label.")
        XCTAssertTrue(staleRow.status.contains("Cached history · status not refreshed"),
                      "The Updated label does not imply that the cached inbox itself is current.")
        XCTAssertFalse(staleStatusParts.contains("Open"),
                       "A noncurrent cached inbox must not expose an unrefreshed lifecycle status.")
    }
}
