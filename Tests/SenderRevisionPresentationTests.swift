import AttentionDomain
import XCTest
@testable import Harklight

@MainActor
final class SenderRevisionPresentationTests: XCTestCase {
    func testAcceptedSenderUpdateRetainsEarlierChoicesTurnsAndQueuedAnswerBinding() async throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("reader")), transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("same-item"))
        let oldPayload = try JSONValue.parse(Data(#"{"title":"Earlier wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Earlier choice","kind":"value","value":"old"}]}}"#.utf8))
        let newPayload = try JSONValue.parse(Data(#"{"title":"Current wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"new","label":"Current choice","kind":"value","value":"new"}]}}"#.utf8))
        try await domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: oldPayload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("handle"), eventID: ExactText("1"))), context: context)
        let port = AttentionDomainPort(store: domain)
        let initialProjection = try await port.inspect(context: port.context, request: key)
        let selector = try XCTUnwrap(initialProjection.requests.first?.selector)
        let model = try LivePresentationStore(store: domain, context: context)
        model.updateConversation(for: key, revision: 1, text: "An unsent local discussion edit")
        XCTAssertFalse(model.hasAcceptedUpdate(for: key), "Local edits are not accepted sender revisions")
        let initialSnapshot = try await domain.snapshot(context: context)
        var oldDraft = try XCTUnwrap(initialSnapshot.drafts[key])
        oldDraft.compatibility.selectedActionID = ExactText("old")
        try await domain.saveDraft(oldDraft, selector: selector, context: context)
        let receipt = try await port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
            inputs: [.compatibilityValue(action: ExactText("old"))]))
        let originalIntent = try await domain.lookupIntent(receipt.intentID, context: context)
        let original = try XCTUnwrap(originalIntent)
        let update = ConversationTurn(id: ExactText("3"), binding: ConversationBinding(request: key, revision: 2),
            author: .origin, sessionHandle: ExactText("handle"), text: ExactText(""), kind: .revision)
        var expectedUpdate = update
        expectedUpdate.conversationSequence = 1
        let event = ConversationEvent(sequence: 1, binding: update.binding, fact: .revision(update, payload: newPayload))
        try await domain.applyConversation(event, context: context)
        try await domain.applyConversation(event, context: context)
        try await model.refreshFromDurableStore()
        XCTAssertTrue(model.hasAcceptedUpdate(for: key))
        XCTAssertEqual(model.inboxRows.count, 1)
        XCTAssertEqual(model.inboxRows.first?.key, key)
        XCTAssertTrue(model.inboxRows.first?.status.hasPrefix("Updated · ") == true)
        XCTAssertEqual(model.request(for: key)?.title, ExactText("Current wording"))
        let historicalDraft = try await model.historicalAnswerDraft(for: key, revision: 1)
        let earlier = try XCTUnwrap(historicalDraft)
        XCTAssertEqual(earlier.title, ExactText("Earlier wording"))
        XCTAssertEqual(earlier.draft.compatibility.selectedActionID, ExactText("old"))
        XCTAssertNil(earlier.selector)
        let thread = try XCTUnwrap(model.conversation(for: key))
        XCTAssertEqual(thread.acceptedUpdates, [expectedUpdate], "Replay must not invent another update fact")
        XCTAssertEqual(thread.revisions[1], oldPayload)
        XCTAssertEqual(thread.revisions[2], newPayload)
        XCTAssertEqual(thread.turns.map(\.id), [ExactText("1"), ExactText("3")])
        let retainedIntent = try await domain.lookupIntent(receipt.intentID, context: context)
        let retained = try XCTUnwrap(retainedIntent)
        XCTAssertEqual(retained.intentID, original.intentID)
        XCTAssertEqual(retained.operationID, original.operationID)
        XCTAssertEqual(retained.operation, original.operation)
        XCTAssertEqual(retained.answer, original.answer)
        XCTAssertEqual(retained.requestRevision, 1)
        XCTAssertEqual(retained.disposition, .lost)
        let finalSnapshot = try await domain.snapshot(context: context)
        XCTAssertTrue(finalSnapshot.outbox.isEmpty)
        do {
            try await domain.saveDraft(oldDraft, selector: selector, context: context)
            XCTFail("A draft for the superseded revision must be rejected.")
        } catch {}
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let restoredConversation = try await restored.conversationSnapshot(context: context)
        XCTAssertEqual(restoredConversation.threads[key]?.acceptedUpdates,
                       [expectedUpdate])
        let restoredIntent = try await restored.lookupIntent(receipt.intentID, context: context)
        XCTAssertEqual(restoredIntent?.operation, original.operation)
    }
}
