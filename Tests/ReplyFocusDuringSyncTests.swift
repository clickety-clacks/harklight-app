import XCTest
@testable import Harklight
import AttentionDomain

/// A refresh temporarily makes inbox freshness unknown. Reply editing and
/// submission remain available against the exact request revision on screen.
final class ReplyFocusDuringSyncTests: XCTestCase {
    private func makeContext() -> ProfileContext {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("focus-\(UUID().uuidString)"),
                                       deviceID: ExactText("device-A"))
        return ProfileContext(identity: identity, transportMode: .relay)
    }

    @MainActor
    private func deliverTextRequest(to store: AttentionDomainStore,
                                    context: ProfileContext) throws -> RequestKey {
        let payload = try JSONValue.parse(Data(#"{"sender_id":"app:test","message_id":"m1","created_at":1,"title":"Needs a reply","body":"Reply requested"}"#.utf8))
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("app:test"), messageID: ExactText("m1"))
        _ = try store.apply(RelayEvent(sequence: 1,
                                       body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)),
                            context: context)
        return key
    }

    @MainActor
    func testFocusedReplyEditorStaysEditableAndKeepsTextAcrossInboxCandidate() throws {
        let context = makeContext()
        let domain = try AttentionDomainStore(context: context,
                                              persistence: MemoryAttentionStatePersistence())
        let key = try deliverTextRequest(to: domain, context: context)
        let visible = try LivePresentationStore(store: domain, context: context)

        let request = try XCTUnwrap(visible.request(for: key))
        guard case let .compatibility(actions) = request.projection,
              let reply = actions.first, reply.kind == .text else {
            return XCTFail("A plain sender message offers one deliberate text reply.")
        }
        visible.selectAction(reply.id, input: nil, for: key)
        visible.updateCompatibilityText("Half-typed reply", action: reply.id, for: key)
        let before = LiveRequestDetail(request: try XCTUnwrap(visible.request(for: key)),
                                       store: visible)
        XCTAssertTrue(before.canEdit)
        XCTAssertTrue(before.canAnswer)

        _ = try domain.beginInboxCandidate(startupID: "startup", since: 0, batches: [],
                                           context: context)
        try visible.refreshFromDurableStore()

        let during = try XCTUnwrap(visible.request(for: key))
        XCTAssertFalse(during.inboxStateIsCurrent,
                       "The candidate clears the current keys; the request is briefly not current.")
        let detail = LiveRequestDetail(request: during, store: visible)
        XCTAssertTrue(detail.canEdit,
                      "The focused editor stays enabled while the snapshot runs.")
        XCTAssertTrue(detail.canAnswer,
                      "Freshness checks must not disable the answer controls.")
        XCTAssertEqual(visible.draft(for: key)?.compatibility.textByActionID[reply.id],
                       ExactText("Half-typed reply"),
                       "Typed text survives the inbox candidate.")
        XCTAssertEqual(visible.draft(for: key)?.compatibility.selectedActionID, reply.id)

        XCTAssertTrue(visible.submitFromUser(key, requestRevision: during.requestRevision),
                      "An answer can be submitted while the refresh candidate is pending.")
        let submission = try XCTUnwrap(domain.snapshot(context: context).outbox.first)
        XCTAssertEqual(submission.requestRevision, during.requestRevision,
                       "The answer uses the exact revision the user saw.")
    }

    @MainActor
    func testDraftWithSelectedTextActionRoundTripsThroughRequestDraft() throws {
        let context = makeContext()
        let persistence = MemoryAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let key = try deliverTextRequest(to: domain, context: context)
        let visible = try LivePresentationStore(store: domain, context: context)

        let request = try XCTUnwrap(visible.request(for: key))
        guard case let .compatibility(actions) = request.projection,
              let reply = actions.first else {
            return XCTFail("The open request should expose its reply action.")
        }
        visible.selectAction(reply.id, input: nil, for: key)
        visible.updateCompatibilityText("Saved draft text", action: reply.id, for: key)
        XCTAssertTrue(visible.flushPendingDraft(for: key))

        let saved = try XCTUnwrap(visible.request(for: key)).draft
        XCTAssertEqual(saved.compatibility.selectedActionID, reply.id)
        XCTAssertEqual(saved.compatibility.textByActionID[reply.id], ExactText("Saved draft text"))

        let restoredDomain = try AttentionDomainStore(context: context, persistence: persistence)
        let restored = try LivePresentationStore(store: restoredDomain, context: context)
        let readBack = try XCTUnwrap(restored.request(for: key)).draft
        XCTAssertEqual(readBack.compatibility.selectedActionID, reply.id)
        XCTAssertEqual(readBack.compatibility.textByActionID[reply.id], ExactText("Saved draft text"))
    }
}
