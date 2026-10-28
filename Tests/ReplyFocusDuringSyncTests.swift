import Foundation
import XCTest
@testable import Harklight
import AttentionDomain

private final class CountingAttentionStatePersistence: AttentionStatePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private let backing = MemoryAttentionStatePersistence()
    private var writes = 0

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func load(identity: ProfileIdentity) throws -> Data? {
        try backing.load(identity: identity)
    }

    func commit(_ data: Data, identity: ProfileIdentity) throws {
        lock.lock()
        writes += 1
        lock.unlock()
        try backing.commit(data, identity: identity)
    }
}

/// Reply selections and contents remain local until the checkmark commits them.
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
    func testReplySelectionAndTextStayLocalUntilCheckmarkCommit() async throws {
        let context = makeContext()
        let persistence = CountingAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context,
                                              persistence: persistence)
        let key = try deliverTextRequest(to: domain, context: context)
        let visible = try LivePresentationStore(store: domain, context: context)
        let writesBeforeEditing = persistence.writeCount

        let request = try XCTUnwrap(visible.request(for: key))
        guard case let .compatibility(actions) = request.projection,
              let reply = actions.first, reply.kind == .text else {
            return XCTFail("A plain sender message offers one deliberate text reply.")
        }
        let session = ReplyEditorDraftSession(request: request, canSubmitFromSnapshot: true)
        session.selectAction(reply.id, inputID: nil)
        session.updateText("Typed locally", target: ReplyEditorTarget(inputID: nil,
                                                                       actionID: reply.id.rawValue))

        let beforePause = try domain.snapshot(context: context)
        XCTAssertNil(beforePause.drafts[key], "Reply edits do not write a saved draft.")
        XCTAssertTrue(beforePause.outbox.isEmpty, "Typing does not create an answer operation.")
        XCTAssertEqual(persistence.writeCount, writesBeforeEditing,
                       "Selections and text stay out of durable storage.")

        try await Task.sleep(for: .milliseconds(600))
        let afterPause = try domain.snapshot(context: context)
        XCTAssertNil(afterPause.drafts[key], "Pausing does not save Reply contents.")
        XCTAssertTrue(afterPause.outbox.isEmpty, "Pausing does not submit an answer.")
        XCTAssertEqual(persistence.writeCount, writesBeforeEditing,
                       "A typing pause does not write Reply state.")

        XCTAssertTrue(visible.submitFromUser(key,
                                            answerDraft: session.draft,
                                            requestRevision: session.requestRevision))
        let committed = try domain.snapshot(context: context)
        XCTAssertNil(committed.drafts[key], "Submitting does not create a resumable draft.")
        let submission = try XCTUnwrap(committed.outbox.first)
        XCTAssertEqual(submission.requestRevision, request.requestRevision)
        XCTAssertEqual(submission.typedInputs,
                       [.compatibilityText(action: reply.id, text: ExactText("Typed locally"))],
                       "The checkmark commits the selected action and complete Reply text together.")
        XCTAssertEqual(visible.request(for: key)?.submittedAnswer?.compatibility
            .textByActionID[reply.id], ExactText("Typed locally"),
                       "The committed answer remains visible from its submission record.")
        XCTAssertGreaterThan(persistence.writeCount, writesBeforeEditing,
                             "The checkmark is the first durable write for this Reply.")
    }

    @MainActor
    func testSenderReplyCommitsTextAndPointTogetherWithoutSavingDraft() throws {
        let context = makeContext()
        let persistence = CountingAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let fixtures = try FixtureSet.loadBundled(from: Bundle(for: HarklightTests.self))
        let fixture = try XCTUnwrap(fixtures.requests.first {
            $0.key.messageID == ExactText("facilities-01")
        })
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: fixture.key.senderID,
                             messageID: fixture.key.messageID)
        _ = try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: fixture.originalPayload), .message)),
            context: context)
        let visible = try LivePresentationStore(store: domain, context: context)
        let writesBeforeEditing = persistence.writeCount
        let request = try XCTUnwrap(visible.request(for: key))
        let session = ReplyEditorDraftSession(request: request, canSubmitFromSnapshot: true)
        let point = PointValue(x: 140, y: 625)

        session.setPoint(point, inputID: ExactText("location"))
        session.updateText("Please check the partition.",
                           target: ReplyEditorTarget(inputID: "note", actionID: "input-text",
                                                     isInputText: true))

        XCTAssertNil(try domain.snapshot(context: context).drafts[key])
        XCTAssertEqual(persistence.writeCount, writesBeforeEditing)
        XCTAssertTrue(visible.submitFromUser(key,
                                             answerDraft: session.draft,
                                             requestRevision: session.requestRevision))

        let submission = try XCTUnwrap(domain.snapshot(context: context).outbox.first)
        XCTAssertEqual(submission.typedInputs,
                       [.point(input: ExactText("location"), point: point),
                        .text(input: ExactText("note"), text: ExactText("Please check the partition."))],
                       "The checkmark commits every edited sender field together.")
        let submittedAnswer = try XCTUnwrap(visible.request(for: key)?.submittedAnswer)
        XCTAssertEqual(submittedAnswer.inputs[ExactText("location")]?.effectivePoint, point)
        XCTAssertEqual(submittedAnswer.inputs[ExactText("note")]?.text,
                       ExactText("Please check the partition."))
        XCTAssertNil(try domain.snapshot(context: context).drafts[key],
                     "Submitting does not leave a resumable Reply draft.")
    }

    @MainActor
    func testCheckmarkKeepsTheDisplayedRevisionAndRejectsAnUpdatedRequest() throws {
        let context = makeContext()
        let persistence = CountingAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let key = try deliverTextRequest(to: domain, context: context)
        let firstPayload = try JSONValue.parse(Data(#"{"title":"First wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        let revisedPayload = try JSONValue.parse(Data(#"{"title":"Revised wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        let binding = ConversationBinding(request: key, revision: 1)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("origin"), payload: firstPayload)), context: context)
        let live = try LivePresentationStore(store: domain, context: context)
        let displayed = try XCTUnwrap(live.request(for: key))
        let session = ReplyEditorDraftSession(request: displayed, canSubmitFromSnapshot: true)
        session.selectAction(ExactText("reply"), inputID: nil)
        session.updateText("Answer for the first wording",
                           target: ReplyEditorTarget(inputID: nil, actionID: "reply"))

        try domain.applyConversation(ConversationEvent(sequence: 2,
            binding: ConversationBinding(request: key, revision: 2),
            fact: .request(sessionHandle: ExactText("origin"), payload: revisedPayload)), context: context)
        let beforeCheckmark = persistence.writeCount

        XCTAssertFalse(live.submitFromUser(key, answerDraft: session.draft,
                                           requestRevision: session.requestRevision),
                       "The checkmark validates the original revision and does not send its answer for newer wording.")
        XCTAssertEqual(persistence.writeCount, beforeCheckmark,
                       "A stale checkmark does not persist an editable draft or answer operation.")
        XCTAssertTrue(try domain.snapshot(context: context).outbox.isEmpty)
        XCTAssertNil(try domain.snapshot(context: context).drafts[key])
        XCTAssertEqual(live.request(for: key)?.requestRevision, 2,
                       "The latest wording is shown after the failed checkmark.")
        XCTAssertEqual(live.actionError,
                       "This message changed. Review the latest version before answering.")
    }
}
