import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest
@testable import Harklight

@MainActor
final class LiveAnswerConfirmationTests: XCTestCase {
    private func setup() async throws -> (ProfileContext, ClientRepository, LivePresentationStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("sample"))
        let payload = try JSONValue.parse(Data(#"{"title":"Sample","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"got-it","label":"Got it","kind":"value","value":"got-it"}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        return (context, store, try confirmedPresentation(store: store, context: context, key: key), key)
    }

    private func setupReplyOnly() async throws -> (ProfileContext, ClientRepository, LivePresentationStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("reply-only"))
        let payload = try JSONValue.parse(Data(#"{"title":"Reply-only request"}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        return (context, store, try confirmedPresentation(store: store, context: context, key: key), key)
    }

    func testCachedCurrentRowAcceptsAnswerBeforeRelayConfirmsIt() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("cached-answer"))
        let payload = try JSONValue.parse(Data(#"{"title":"Cached question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"got-it","label":"Got it","kind":"value","value":"got-it"}]}}"#.utf8))
        let stored = StoredRequest(key: key, originalPayload: payload)
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(stored, .message)),
                            context: context)
        let inbox = try store.snapshot(context: context)
        try store.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: inbox.requests, remoteStates: inbox.remoteStates, cursor: inbox.cursor,
            conversationCursor: 0, conversations: [:], inboxView: nil,
            currentRequestKeys: [key]), context: context)
        let live = try LivePresentationStore(store: store, context: context)
        let cachedRequest = try XCTUnwrap(live.request(for: key))
        XCTAssertTrue(cachedRequest.inboxStateIsCurrent,
                      "The saved copy can render the row immediately.")
        XCTAssertTrue(live.canSendToCurrentServer,
                      "An applicable action does not wait for a relay checkpoint.")

        let answerDraft = RequestDraft(inputs: [:],
            compatibility: CompatibilityDraft(selectedActionID: ExactText("got-it")))
        XCTAssertTrue(live.submitFromUser(key, answerDraft: answerDraft, requestRevision: 1))
        let receipt = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .pending)
        XCTAssertEqual(try store.snapshot(context: context).intents.count, 1)
        try store.queueRecoverableOperations(context: context)
        XCTAssertEqual(try store.snapshot(context: context).outbox.map(\.operationID), [receipt.opID])
    }

    private func setupTextReplyOnly() async throws -> (ProfileContext, ClientRepository, LivePresentationStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("text-reply-only"))
        let payload = try JSONValue.parse(Data(#"{"title":"Text reply request","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        return (context, store, try confirmedPresentation(store: store, context: context, key: key), key)
    }

    private func confirmedPresentation(store: ClientRepository, context: ProfileContext,
                                       key: RequestKey) throws -> LivePresentationStore {
        let snapshot = try store.snapshot(context: context)
        try store.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: snapshot.requests, remoteStates: snapshot.remoteStates, cursor: snapshot.cursor,
            conversationCursor: 0, conversations: [:], inboxView: nil, currentRequestKeys: [key]),
            context: context)
        return try LivePresentationStore(store: store, context: context)
    }

    private func commitAnswer(_ store: ClientRepository, key: RequestKey) throws -> IntentReceipt {
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        return try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                                             inputs: [.compatibilityValue(action: ExactText("got-it"))]))
    }

    private func commitNoComment(_ store: ClientRepository, key: RequestKey) throws -> IntentReceipt {
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        return try port.submitNoComment(context: port.context, selector: selector, intentID: UUID())
    }

    private func sampleResponse(for live: LivePresentationStore, key: RequestKey) -> SampleResponse {
        let message = SampleMessage(id: key.messageID.rawValue, kind: .note,
            sender: key.senderID.rawValue, initials: "", title: "Sample request", body: "",
            options: [], deadline: nil, missed: false, revised: false,
            chatUnread: false, hasChat: false, fixtureCreatedAtMilliseconds: 0)
        return SampleResponse(viewModel: live, key: key, message: message)
    }

    func testDelayedSendAfterDurableAnswerNeverClaimsFailureOrCreatesAnotherIntent() async throws {
        let (context, store, live, key) = try await setup()
        // The displayed Open view is deliberately older than the durable intent.
        let receipt = try commitAnswer(store, key: key)
        live.submitFromUser(key)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.intentReceipt?.opID, receipt.opID)
        XCTAssertEqual(try store.snapshot(context: context).intents.count, 1)
        XCTAssertEqual(try store.lookupIntent(receipt.intentID, context: context)?.operationID, receipt.opID)
        try store.queueRecoverableOperations(context: context)
        XCTAssertEqual(try store.snapshot(context: context).outbox.map(\.operationID), [receipt.opID],
                       "Duplicate callbacks leave one saved operation eligible for recovery.")

        try store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        _ = try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil)), context: context)
        try live.refreshFromDurableStore()
        XCTAssertNil(live.request(for: key)?.intentReceipt,
                     "The account-level answered state does not expose this device's receipt.")
        XCTAssertNil(live.request(for: key)?.submittedAnswer,
                     "A server terminal replaces the device's pending answer projection.")
        live.submitFromUser(key)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "A completed account state does not expose the submitting device's receipt.")
        let settled = try store.snapshot(context: context)
        XCTAssertTrue(settled.outbox.isEmpty)
        // The Server's answered terminal settles the operation, so the device
        // keeps no unsent answer, and the stale callback recreates none.
        XCTAssertTrue(settled.intents.isEmpty,
                      "No unsent or duplicate answer remains after the answered terminal.")
        XCTAssertNil(try store.lookupIntent(receipt.intentID, context: context))
    }

    func testNewDurableReceiptClearsAnObsoleteSubmissionError() async throws {
        let (context, store, live, key) = try await setup()
        live.submitFromUser(key) // No choice made: a genuine local validation error.
        XCTAssertEqual(live.actionError, "Complete the response before sending your answer.")
        XCTAssertTrue(try store.snapshot(context: context).intents.isEmpty)
        let receipt = try commitAnswer(store, key: key)
        try store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        try live.refreshFromDurableStore()
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
    }

    func testRejectedNoCommentThenBlankReplyShowsValidationWithoutSendingText() async throws {
        let (context, store, live, key) = try await setupTextReplyOnly()
        live.selectNoComment(for: key)
        live.submitFromUser(key)
        let noComment = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        try store.recordNoCommentUnsupported(noComment.intentID,
                                             operationID: noComment.opID,
                                             context: context)
        try live.refreshFromDurableStore()
        XCTAssertTrue(live.request(for: key)?.noCommentUnavailable == true)
        XCTAssertTrue(LiveRequestDetail(request: try XCTUnwrap(live.request(for: key)),
                                        store: live).canAnswer)

        live.selectAction(ExactText("reply"), input: nil, for: key)
        let draftBeforeBlankReply = try store.snapshot(context: context).drafts[key]
        live.submitFromUser(key)

        XCTAssertEqual(live.actionError, "Complete the response before sending your answer.")
        let snapshot = try store.snapshot(context: context)
        // Picking another answer after a definitive failure replaces it, so the
        // next send is a new operation (approved submission-state behavior).
        XCTAssertTrue(snapshot.intents.isEmpty,
                      "Choosing Reply releases the rejected No comment; the blank Reply sends nothing.")
        XCTAssertTrue(snapshot.outbox.isEmpty,
                      "The blank Reply must not create a sendable ordinary answer.")
        XCTAssertEqual(snapshot.drafts[key], draftBeforeBlankReply,
                       "The blank Reply attempt must not save or alter the persisted draft.")
        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.lifecycleStatus, .open)
        XCTAssertNil(request.intentReceipt)
        XCTAssertFalse(request.draft.noCommentSelected)
        XCTAssertTrue(LiveRequestDetail(request: request, store: live).canAnswer,
                      "The person can add text and submit after the empty attempt is refused.")
    }

    func testWhitespaceOnlyReplyIsRefusedAndTypedSurroundingSpacesAreSentAsIs() async throws {
        let (context, store, live, key) = try await setupTextReplyOnly()
        live.selectAction(ExactText("reply"), input: nil, for: key)
        live.updateCompatibilityText("  \n \n  ", action: ExactText("reply"), for: key)
        live.submitFromUser(key)

        XCTAssertEqual(live.actionError, "Complete the response before sending your answer.")
        let refused = try store.snapshot(context: context)
        XCTAssertTrue(refused.intents.isEmpty,
                      "A whitespace-only Reply must not create an intent.")
        XCTAssertTrue(refused.outbox.isEmpty,
                      "A whitespace-only Reply must not queue anything to send.")
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .open)

        let typed = "  Near the east entrance \n"
        live.updateCompatibilityText(typed, action: ExactText("reply"), for: key)
        live.submitFromUser(key)

        XCTAssertNil(live.actionError)
        let queuedID = try XCTUnwrap(live.request(for: key)?.intentReceipt?.intentID)
        let sent = try XCTUnwrap(store.snapshot(context: context).intents[queuedID])
        XCTAssertEqual(sent.typedInputs,
                       [.compatibilityText(action: ExactText("reply"), text: ExactText(typed))],
                       "Ordinary surrounding whitespace goes out exactly as typed.")
    }

    func testNoCommentUsesItsOwnPayloadFreeFrameAndUnsupportedLeavesTheRequestOpen() async throws {
        let (context, store, live, key) = try await setup()
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key)
            .requests.first?.selector)
        let receipt = try port.submitNoComment(context: port.context, selector: selector, intentID: UUID())

        XCTAssertEqual(receipt.answerKind, .noComment)
        XCTAssertEqual(receipt.inputs, [])
        XCTAssertEqual(receipt.exactAnswer, .null,
                       "The local null placeholder is distinguished by answerKind and is never the wire frame.")
        let submitted = try XCTUnwrap(store.snapshot(context: context).intents[receipt.intentID])
        XCTAssertEqual(submitted.requestRevision, 1,
                       "An ordinary request is the first revision even without conversation history.")
        XCTAssertEqual(String(decoding: submitted.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"sample","request_revision":1}"# + "\n")
        try live.refreshFromDurableStore()
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .pending)
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied)

        try store.recordNoCommentUnsupported(receipt.intentID, operationID: receipt.opID, context: context)
        try live.refreshFromDurableStore()
        let reopened = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(reopened.lifecycleStatus, .open)
        XCTAssertTrue(reopened.noCommentUnavailable)
        XCTAssertNil(reopened.intentReceipt)
        let unavailableRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertFalse(unavailableRow.belongsToReplied,
                       "Unsupported No comment was not accepted, so the request stays in Inbox.")
        XCTAssertTrue(unavailableRow.hasDeliveryWarning)
        XCTAssertFalse(unavailableRow.visibleStatus.contains("Open"))
        XCTAssertFalse(unavailableRow.visibleStatus.contains("not delivered"))
        XCTAssertNil(unavailableRow.localStatus)
        let warning = try XCTUnwrap(live.failedResponseWarning(for: key))
        XCTAssertEqual(String(localized: warning.summary),
                       "Your No comment response was not delivered.")
        XCTAssertFalse(String(localized: warning.detail).contains("unsupported by this server"),
                       "The dialog must not repeat an unverified cause.")
        XCTAssertTrue(LiveRequestDetail(request: reopened, store: live).canAnswer,
                      "The app leaves ordinary answer choices to an explicit user action.")
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)

        live.submitNoCommentFromUser(key)
        XCTAssertTrue(live.draft(for: key)?.noCommentSelected == true,
                      "A swipe submission persists the explicit No comment choice for retry.")
        let retryID = try XCTUnwrap(live.request(for: key)?.intentReceipt?.intentID)
        let retry = try XCTUnwrap(store.snapshot(context: context).intents[retryID])
        try store.queueRecoverableOperations(context: context)
        XCTAssertEqual(try store.snapshot(context: context).outbox.map(\.operationID), [retry.operationID],
                       "An explicitly retried choice is eligible for automatic delivery using its saved frame.")
        XCTAssertEqual(retry.answerKind, .noComment)
        XCTAssertEqual(String(decoding: retry.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"sample","request_revision":1}"# + "\n")
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .pending)
        XCTAssertFalse(live.request(for: key)?.noCommentUnavailable ?? true,
                       "A newly queued attempt replaces the prior unsupported result in the current status.")
        // Sending No comment again is a new operation that shows its own
        // Sending state; the earlier unsupported result is released, not kept
        // as a lingering warning (approved submission-state behavior).
        XCTAssertEqual(try store.snapshot(context: context).intents.count, 1,
                       "Only the new No comment operation remains.")
        XCTAssertEqual(live.submissionPhases[key]?.kind, .noComment)
        XCTAssertEqual(live.submissionPhases[key]?.phase, .sending)
    }

    func testAcceptedNoCommentIsFinalAndCannotBeResubmitted() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        live.selectNoComment(for: key)
        live.submitFromUser(key)
        let receipt = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        try store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)), context: context)
        try live.refreshFromDurableStore()

        let accepted = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(accepted.lifecycleStatus, .noComment)
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied)
        XCTAssertFalse(LiveRequestDetail(request: accepted, store: live).canAnswer)
        let intentCount = try store.snapshot(context: context).intents.count
        live.submitNoCommentFromUser(key)
        XCTAssertEqual(try store.snapshot(context: context).intents.count, intentCount,
                       "An accepted final No comment answer cannot be submitted a second time.")
    }


    func testFailedResponseRetryKeepsOriginalIdentityAndReturnsToPendingUntilConfirmation() async throws {
        let (context, store, live, key) = try await setup()
        live.selectAction(ExactText("got-it"), input: nil, for: key)
        let original = try live.submit(key)
        let originalFrame = try XCTUnwrap(store.snapshot(context: context).intents[original.intentID]).wireFrame
        try store.recordAnswerNotDelivered(original.intentID, operationID: original.opID,
                                           context: context)
        try live.refreshFromDurableStore()

        let warning = try XCTUnwrap(live.failedResponseWarning(for: key))
        XCTAssertEqual(String(localized: warning.summary), "Your response was not delivered.")
        XCTAssertEqual(String(localized: warning.detail), "No additional safe failure detail was retained.")
        XCTAssertEqual(warning.submittedInputs, original.inputs)
        XCTAssertTrue(live.canRetryFailedResponse(for: key))

        let failedRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(failedRow.hasDeliveryWarning)
        XCTAssertNil(failedRow.localStatus)
        XCTAssertFalse(failedRow.visibleStatus.contains("Open"))
        XCTAssertFalse(failedRow.visibleStatus.contains("not delivered"))

        XCTAssertTrue(live.retryFailedResponse(for: key))
        let retried = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        XCTAssertEqual(retried.opID, original.opID,
                       "Retry must preserve the original operation ID after a definite failure.")
        XCTAssertEqual(retried.intentID, original.intentID)
        XCTAssertEqual(try store.snapshot(context: context).intents[retried.intentID]?.wireFrame, originalFrame)
        XCTAssertEqual(retried.inputs, original.inputs,
                       "Retry uses the exact submitted response, not the editable draft.")
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .pending)
        XCTAssertNil(live.failedResponseWarning(for: key),
                     "Retry replaces the previous failure display with the saved pending answer.")

        try store.recordAcceptedOperation(retried.intentID, operationID: retried.opID,
                                          terminalSequence: 2, context: context)
        _ = try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil)),
                            context: context)
        try live.refreshFromDurableStore()

        XCTAssertNil(live.failedResponseWarning(for: key),
                     "Server confirmation completes the pending retry without restoring the old failure.")
        XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == key }).hasDeliveryWarning)
    }

    func testFailedNoCommentWarningRetriesTheSameNoCommentResponse() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        XCTAssertTrue(live.submitNoCommentFromUser(key))
        let original = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        let originalFrame = try XCTUnwrap(store.snapshot(context: context).intents[original.intentID]).wireFrame
        try store.recordNoCommentUnsupported(original.intentID, operationID: original.opID,
                                             context: context)
        try live.refreshFromDurableStore()

        let warning = try XCTUnwrap(live.failedResponseWarning(for: key))
        XCTAssertEqual(warning.answerKind, .noComment)
        XCTAssertTrue(warning.canRetry)
        XCTAssertTrue(live.retryFailedResponse(for: key))

        let retried = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        XCTAssertEqual(retried.answerKind, .noComment)
        XCTAssertEqual(retried.inputs, [])
        XCTAssertEqual(retried.opID, original.opID)
        XCTAssertEqual(retried.intentID, original.intentID)
        XCTAssertEqual(try store.snapshot(context: context).intents[retried.intentID]?.wireFrame, originalFrame)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .pending)
        XCTAssertNil(live.failedResponseWarning(for: key))

        try store.recordAcceptedOperation(retried.intentID, operationID: retried.opID,
                                          terminalSequence: 2, context: context)
        _ = try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)),
                            context: context)
        try live.refreshFromDurableStore()

        XCTAssertNil(live.failedResponseWarning(for: key))
        XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == key }).hasDeliveryWarning)
    }


    func testSwipeNoCommentAcceptanceIsFinalAndCannotBeResubmitted() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        live.submitNoCommentFromUser(key)

        let receipt = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        let pending = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertEqual(receipt.answerKind, .noComment)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .pending)
        XCTAssertTrue(pending.belongsToReplied,
                      "The swipe records the chosen response locally while server confirmation is pending.")

        try store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)), context: context)
        try live.refreshFromDurableStore()

        let accepted = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(accepted.lifecycleStatus, .noComment)
        XCTAssertNil(accepted.receiptFacts,
                     "A common No comment terminal does not expose which phone submitted it.")
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied)
        XCTAssertFalse(LiveRequestDetail(request: accepted, store: live).canAnswer)
        let intentCount = try store.snapshot(context: context).intents.count
        live.submitNoCommentFromUser(key)
        XCTAssertEqual(try store.snapshot(context: context).intents.count, intentCount,
                       "An accepted swipe choice cannot create another answer.")
    }










    func testNoCommentCheckmarkCommitsWithoutSavingReplyContents() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        let draftBeforeEditing = try XCTUnwrap(store.snapshot(context: context).drafts[key])
        let request = try XCTUnwrap(live.request(for: key))
        let session = ReplyEditorDraftSession(request: request, canSubmitFromSnapshot: true)
        session.selectAction(ExactText("reply"), inputID: nil)
        session.updateText("Keep this local.", target: ReplyEditorTarget(inputID: nil,
                                                                          actionID: "reply"))
        session.selectNoComment()
        XCTAssertTrue(session.noCommentSelected)
        XCTAssertEqual(try store.snapshot(context: context).drafts[key], draftBeforeEditing,
                       "Selecting No comment does not save Reply contents over the request's empty baseline.")
        XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied,
                       "Selecting No comment does not submit before the checkmark is tapped.")
        XCTAssertTrue(live.submitNoCommentFromUser(key,
                                                   requestRevision: request.requestRevision,
                                                   selectionIsLocal: true))

        let queuedID = try XCTUnwrap(live.request(for: key)?.intentReceipt?.intentID)
        let submitted = try XCTUnwrap(store.snapshot(context: context).intents[queuedID])
        XCTAssertEqual(String(decoding: submitted.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"reply-only","request_revision":1}"# + "\n")
        let queuedDraft = try store.snapshot(context: context).drafts[key]
        var expectedDraft = RequestDraft(inputs: [:])
        expectedDraft.noCommentSelected = true
        XCTAssertTrue(queuedDraft == nil || queuedDraft == expectedDraft,
                      "Any retained draft contains only No comment, never the local Reply text.")
        // The queued operation is projected internally while it sends. It is
        // No comment with no Reply text, and it is not the Server's confirmation.
        let queued = try XCTUnwrap(live.request(for: key))
        if let projected = queued.submittedAnswer {
            XCTAssertTrue(projected.noCommentSelected)
            XCTAssertTrue(projected.compatibility.textByActionID.isEmpty,
                          "The pending projection carries no Reply text.")
        }
        XCTAssertEqual(queued.lifecycleStatus, .pending)
        XCTAssertNil(queued.accountAnswerOutcome, "No Server terminal is recorded for the queued answer.")
        XCTAssertNotEqual(queued.receiptFacts?.ownOutcome, .accepted)
        XCTAssertEqual(live.submissionPhases[key]?.kind, .noComment)
        XCTAssertEqual(live.submissionPhases[key]?.phase, .sending,
                       "The tapped No comment control shows Sending, not a confirmed card.")
        XCTAssertFalse(LiveRequestDetail(request: queued, store: live).isDurablyAccepted(.noComment))
        XCTAssertEqual(submitted.answerKind, .noComment)
    }

    func testNoCommentUsesDisplayedRevisionAndStaleTapKeepsCurrentQuestionOpen() async throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("conversation"))
        let first = JSONValue.object([JSONMember("title", .string(ExactText("First wording")))])
        let second = JSONValue.object([JSONMember("title", .string(ExactText("Second wording")))])
        let third = JSONValue.object([JSONMember("title", .string(ExactText("Current wording")))])
        let firstBinding = ConversationBinding(request: key, revision: 1)
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: first), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("origin"))),
            context: context)
        _ = try confirmedPresentation(store: store, context: context, key: key)
        try store.applyConversation(ConversationEvent(sequence: 1, binding: firstBinding,
            fact: .request(sessionHandle: ExactText("origin"), payload: first)), context: context)

        let secondBinding = ConversationBinding(request: key, revision: 2)
        let secondRevision = ConversationTurn(id: ExactText("revision-2"), binding: secondBinding,
            author: .origin, sessionHandle: ExactText("origin"), text: ExactText("Second wording"),
            kind: .revision)
        try store.applyConversation(ConversationEvent(sequence: 2, binding: secondBinding,
            fact: .revision(secondRevision, payload: second)), context: context)

        let live = try LivePresentationStore(store: store, context: context)
        XCTAssertEqual(live.request(for: key)?.title, ExactText("Second wording"))
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submitNoComment(context: port.context, selector: selector, intentID: UUID())
        let staleSubmission = try XCTUnwrap(store.snapshot(context: context).intents[receipt.intentID])
        XCTAssertEqual(staleSubmission.requestRevision, 2)
        XCTAssertEqual(String(decoding: staleSubmission.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"conversation","request_revision":2}"# + "\n")

        // A newer replayed revision supersedes the locally pending older attempt.
        let thirdBinding = ConversationBinding(request: key, revision: 3)
        let thirdRevision = ConversationTurn(id: ExactText("revision-3"), binding: thirdBinding,
            author: .origin, sessionHandle: ExactText("origin"), text: ExactText("Current wording"),
            kind: .revision)
        try store.applyConversation(ConversationEvent(sequence: 3, binding: thirdBinding,
            fact: .revision(thirdRevision, payload: third)), context: context)
        try live.refreshFromDurableStore()

        let current = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(current.title, ExactText("Current wording"))
        XCTAssertEqual(current.lifecycleStatus, .open)
        XCTAssertNil(current.intentReceipt)
        XCTAssertEqual(try store.conversationSnapshot(context: context).threads[key]?.currentRevision, 3)
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
        XCTAssertEqual(try store.lookupIntent(receipt.intentID, context: context)?.disposition, .lost)
        XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied,
                       "The current open revision belongs in Inbox after the older No comment intent is superseded.")
    }

    func testDisconnectedInboxKeepsDraftReadOnlyAndCannotCreateOrRetryAnAnswer() async throws {
        let (context, store, live, key) = try await setup()
        live.selectAction(ExactText("got-it"), input: nil, for: key)
        let savedDraft = try XCTUnwrap(live.request(for: key)?.draft)
        XCTAssertTrue(savedDraft.hasEdits)

        live.enterReadOnlyMode()
        live.selectAction(ExactText("different"), input: nil, for: key)
        live.updateCompatibilityText("changed after disconnect", action: ExactText("got-it"), for: key)
        live.submitFromUser(key)
        live.retryPendingDelivery()

        XCTAssertTrue(live.isReadOnly)
        XCTAssertEqual(live.request(for: key)?.draft, savedDraft)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .open)
        XCTAssertThrowsError(try live.submit(key))
        let snapshot = try store.snapshot(context: context)
        XCTAssertTrue(snapshot.intents.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
    }

    func testAnswerCommittedDuringRefreshGetsADeliveryPassAfterThatRefresh() async {
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let (queued, queuedSignal) = AsyncStream<Void>.makeStream()
        var hasSavedAnswer = false
        var passes = 0
        var deliveries = 0
        let flights = RelayRefreshFlights(inactive: false) {
            passes += 1
            let answerSeen = hasSavedAnswer
            if passes == 1 {
                startedSignal.yield()
                for await _ in release { break }
            }
            if answerSeen { deliveries += 1 }
            return true
        }
        let initial = Task { await flights.coalesced() }
        for await _ in started { break }
        hasSavedAnswer = true
        let delivery = Task {
            queuedSignal.yield()
            return await flights.afterCurrent()
        }
        for await _ in queued { break }
        releaseSignal.yield()
        let initialReached = await initial.value
        let deliveryReached = await delivery.value
        XCTAssertTrue(initialReached)
        XCTAssertTrue(deliveryReached)
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(deliveries, 1, "The saved original operation cannot wait for another app wake.")
    }

    func testLateSendOnAnotherDevicesTerminalRequestDoesNotClaimOurAnswerWasAccepted() async throws {
        let (context, store, live, key) = try await setup()
        _ = try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil)), context: context)
        live.submitFromUser(key)
        XCTAssertNil(live.actionError, "Show the server terminal state without claiming a local answer.")
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.submittedAnswer)
        XCTAssertTrue(try store.snapshot(context: context).intents.isEmpty)
        XCTAssertNil(live.request(for: key)?.receiptFacts)
    }




    func testServerNoCommentHidesPriorUnsupportedNoteFromBothRepliedProjections() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        let receipt = try commitNoComment(store, key: key)
        try store.recordNoCommentUnsupported(receipt.intentID, operationID: receipt.opID, context: context)
        try live.refreshFromDurableStore()
        XCTAssertTrue(live.request(for: key)?.noCommentUnavailable == true)
        let unsupportedLiveRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertFalse(unsupportedLiveRow.belongsToReplied,
                       "An unsupported No comment leaves the request in Inbox.")
        XCTAssertTrue(unsupportedLiveRow.hasDeliveryWarning)
        XCTAssertNil(unsupportedLiveRow.localStatus)
        try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)), context: context)
        try live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertFalse(request.noCommentUnavailable,
                       "A terminal account state supersedes the device-local failed attempt.")
        let liveRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(liveRow.belongsToReplied)
        XCTAssertFalse(liveRow.hasDeliveryWarning)
        XCTAssertFalse(liveRow.visibleStatus.contains("Open"))
        XCTAssertFalse(liveRow.localStatus?.contains("No comment not delivered") == true)

        let sampleResponse = sampleResponse(for: live, key: key)
        let sampleRow = try XCTUnwrap(sampleResponse.inboxRow)
        XCTAssertTrue(sampleRow.belongsToReplied)
        XCTAssertFalse(sampleRow.status.contains("No comment not delivered"))
        XCTAssertNil(sampleRow.localStatus)
    }



    func testLaterRelayFailureKeepsAcceptedReceiptAndNoRegistrationIsInventedOnRecovery() async throws {
        let (context, store, live, key) = try await setup()
        let receipt = try commitAnswer(store, key: key)
        try store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        try live.refreshFromDurableStore()
        live.applyRefreshResult(.unavailable)
        XCTAssertNotNil(live.connectionWarning)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
        XCTAssertNil(live.actionError)

        let result = await NativeRelayRefreshResult.afterConfirmedRelay(
            context: context, transportAttemptID: UUID()) { .notAttempted }
        live.applyRefreshResult(result)
        XCTAssertNil(live.connectionWarning)
        XCTAssertEqual(result.pushRegistration, .notAttempted,
                       "A working relay alone cannot establish APNs registration.")
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
    }

}
