import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest
@testable import Harklight

@MainActor
final class LiveAnswerConfirmationTests: XCTestCase {
    private func setup() throws -> (ProfileContext, AttentionDomainStore, LivePresentationStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("sample"))
        let payload = try JSONValue.parse(Data(#"{"title":"Sample","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"got-it","label":"Got it","kind":"value","value":"got-it"}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        return (context, store, try LivePresentationStore(store: store, context: context), key)
    }

    private func setupReplyOnly() throws -> (ProfileContext, AttentionDomainStore, LivePresentationStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("reply-only"))
        let payload = try JSONValue.parse(Data(#"{"title":"Reply-only request"}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        return (context, store, try LivePresentationStore(store: store, context: context), key)
    }

    private func setupTextReplyOnly() throws -> (ProfileContext, AttentionDomainStore, LivePresentationStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("text-reply-only"))
        let payload = try JSONValue.parse(Data(#"{"title":"Text reply request","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        return (context, store, try LivePresentationStore(store: store, context: context), key)
    }

    private func commitAnswer(_ store: AttentionDomainStore, key: RequestKey) throws -> IntentReceipt {
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        return try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                                             inputs: [.compatibilityValue(action: ExactText("got-it"))]))
    }

    private func commitNoComment(_ store: AttentionDomainStore, key: RequestKey) throws -> IntentReceipt {
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

    func testDelayedSendAfterDurableAnswerNeverClaimsFailureOrCreatesAnotherIntent() throws {
        let (context, store, live, key) = try setup()
        // The displayed Open view is deliberately older than the durable intent.
        let receipt = try commitAnswer(store, key: key)
        live.submitFromUser(key)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.intentReceipt?.opID, receipt.opID)
        XCTAssertEqual(try store.snapshot(context: context).intents.count, 1)
        XCTAssertEqual(try store.snapshot(context: context).outbox.map(\.operationID), [receipt.opID])

        try store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        _ = try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil)), context: context)
        live.submitFromUser(key)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "A completed account state does not expose the submitting device's receipt.")
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
        XCTAssertEqual(try store.snapshot(context: context).intents.count, 1)
    }

    func testNewDurableReceiptClearsAnObsoleteSubmissionError() throws {
        let (context, store, live, key) = try setup()
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

    func testRejectedNoCommentThenBlankReplyShowsValidationWithoutSendingText() throws {
        let (context, store, live, key) = try setupTextReplyOnly()
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
        XCTAssertEqual(snapshot.intents.count, 1,
                       "Only the rejected No comment intent remains in history.")
        XCTAssertEqual(snapshot.intents[noComment.intentID]?.disposition, .unsupported)
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

    func testWhitespaceOnlyReplyIsRefusedAndTypedSurroundingSpacesAreSentAsIs() throws {
        let (context, store, live, key) = try setupTextReplyOnly()
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
        let sent = try XCTUnwrap(store.snapshot(context: context).outbox.first)
        XCTAssertEqual(sent.typedInputs,
                       [.compatibilityText(action: ExactText("reply"), text: ExactText(typed))],
                       "Ordinary surrounding whitespace goes out exactly as typed.")
    }

    func testNoCommentUsesItsOwnPayloadFreeFrameAndUnsupportedLeavesTheRequestOpen() throws {
        let (context, store, live, key) = try setup()
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key)
            .requests.first?.selector)
        let receipt = try port.submitNoComment(context: port.context, selector: selector, intentID: UUID())

        XCTAssertEqual(receipt.answerKind, .noComment)
        XCTAssertEqual(receipt.inputs, [])
        XCTAssertEqual(receipt.exactAnswer, .null,
                       "The local null placeholder is distinguished by answerKind and is never the wire frame.")
        let submitted = try XCTUnwrap(store.snapshot(context: context).outbox.first)
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
        XCTAssertTrue(unavailableRow.status.contains("No comment not delivered"))
        XCTAssertTrue(LiveRequestDetail(request: reopened, store: live).canAnswer,
                      "The app leaves ordinary answer choices to an explicit user action.")
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)

        live.submitNoCommentFromUser(key)
        XCTAssertTrue(live.draft(for: key)?.noCommentSelected == true,
                      "A swipe submission persists the explicit No comment choice for retry.")
        let retry = try XCTUnwrap(store.snapshot(context: context).outbox.first)
        XCTAssertEqual(retry.answerKind, .noComment)
        XCTAssertEqual(String(decoding: retry.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"sample","request_revision":1}"# + "\n")
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .pending)
        XCTAssertFalse(live.request(for: key)?.noCommentUnavailable ?? true,
                       "A newly queued attempt replaces the prior unsupported result in the current status.")
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied,
                      "A retried No comment response moves to Replied while it is pending.")
    }

    func testAcceptedNoCommentIsFinalAndCannotBeResubmitted() throws {
        let (context, store, live, key) = try setupReplyOnly()
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

    func testDefinitiveNoCommentErrorReturnsToInboxWithNotDeliveredTreatment() async throws {
        let (context, store, live, key) = try setupReplyOnly()
        live.selectNoComment(for: key)
        let failed = try live.submit(key)
        let session = AnswerSession(context.identity)
        session.rejectOperation = true
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let sent = try await core.sendPendingOriginalOperations()
        XCTAssertEqual(sent, 1)
        try live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(try store.lookupIntent(failed.intentID, context: context)?.disposition, .failed)
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty,
                      "A definitive rejection retires the refused operation instead of retrying it.")
        XCTAssertEqual(request.lifecycleStatus, .open)
        XCTAssertNil(request.intentReceipt)
        XCTAssertTrue(request.answerNotDelivered)
        XCTAssertFalse(request.noCommentUnavailable,
                       "A generic rejection must not claim the server lacks No comment support.")
        XCTAssertTrue(LiveRequestDetail(request: request, store: live).canAnswer,
                      "After a definite refusal, the person can choose another response.")

        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertFalse(row.belongsToReplied)
        XCTAssertTrue(row.hasFailedResponse)
        XCTAssertEqual(row.localStatus, "Answer not delivered")
        XCTAssertTrue(row.status.contains("Answer not delivered"))
        XCTAssertEqual(session.sentOperationIDs, [failed.opID])

        live.selectAction(ExactText("reply"), input: nil, for: key)
        live.updateCompatibilityText("Try again", action: ExactText("reply"), for: key)
        let retry = try live.submit(key)
        XCTAssertNotEqual(retry.opID, failed.opID)
        XCTAssertEqual(try store.snapshot(context: context).outbox.map(\.operationID), [retry.opID],
                       "Only the new answer is retryable after the relay explicitly rejected the old one.")
        XCTAssertFalse(try XCTUnwrap(live.request(for: key)).answerNotDelivered,
                       "A new pending attempt replaces the previous failure treatment.")
    }

    func testMissingNoCommentReplyKeepsPendingExplanationAndReusesOperationID() async throws {
        let (context, store, live, key) = try setupReplyOnly()
        let receipt = try commitNoComment(store, key: key)
        let session = AnswerSession(context.identity)
        session.loseOperationReply = true
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let sent = try await core.sendPendingOriginalOperations()
        XCTAssertEqual(sent, 1)
        try live.refreshFromDurableStore()

        let pending = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(pending.lifecycleStatus, .pending)
        XCTAssertEqual(pending.receiptFacts?.evidenceLabel,
                       "Your answer is saved on this device. Relay acceptance is not yet confirmed.")
        XCTAssertFalse(pending.answerNotDelivered)
        XCTAssertFalse(LiveRequestDetail(request: pending, store: live).canAnswer,
                       "An unknown delivery remains locked until the original operation is reconciled.")
        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(row.belongsToReplied,
                      "The pending response stays in Replied while its outcome is unknown.")
        XCTAssertFalse(row.hasFailedResponse)
        XCTAssertNil(row.localStatus)
        XCTAssertEqual(try store.snapshot(context: context).outbox.map(\.operationID), [receipt.opID])

        _ = try await core.sendPendingOriginalOperations()
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID, receipt.opID],
                       "Retry sends the same durable operation rather than creating a duplicate answer.")
        XCTAssertEqual(try store.snapshot(context: context).intents.count, 1)
        XCTAssertEqual(try store.snapshot(context: context).outbox.map(\.operationID), [receipt.opID])
    }

    func testSwipeNoCommentAcceptanceIsFinalAndCannotBeResubmitted() throws {
        let (context, store, live, key) = try setupReplyOnly()
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

    func testServerNoCommentTerminalStaysDistinctAndAppearsInReplied() throws {
        let (context, store, live, key) = try setup()
        let terminal = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"other-installation","state":"no_comment","at":2}"#.utf8)
        let event = try RelayWire(profile: context).decodeEvent(terminal)
        _ = try store.apply(event, context: context)
        try live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.lifecycleStatus, .noComment)
        XCTAssertNil(request.receiptFacts)
        XCTAssertNil(request.accountAnswerOutcome,
                     "An older server still supplies the shared No comment state through lifecycle.")
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied)
    }

    func testAccountSeenOutcomeConfirmsOnAnyDeviceWithoutLocalAnswerReceipt() throws {
        let (context, store, live, key) = try setup()
        _ = try store.apply(RelayEvent(sequence: 2,
            body: .terminal(key, .answered, nil)), context: context)
        let terminal = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","answer_outcome":{"kind":"seen"}}"#.utf8)
        let event = try RelayWire(profile: context).decodeEvent(terminal)
        XCTAssertEqual(event.accountAnswerOutcome, .seen)
        _ = try store.apply(event, context: context)
        try live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.informationalSeenStatus, .confirmed)
        XCTAssertEqual(request.accountAnswerOutcome, .seen)
        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(row.status.contains("Seen"))
        XCTAssertFalse(row.status.contains("confirmed"),
                       "A shared Seen outcome is presented as Seen, without a phone-specific confirmation label.")
        XCTAssertEqual(LiveRequestDetail.informationalSeenText(.confirmed), "Seen")
        XCTAssertNil(request.intentReceipt,
                     "A shared terminal does not expose an actor-device operation receipt.")
        XCTAssertTrue(row.belongsToReplied)
    }

    func testNoCommentTerminalKindAndUnknownOptionalOutcomeDoNotStopLifecycleSync() throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let wire = try RelayWire(profile: context)
        let noComment = try wire.decodeEvent(Data(#"{"v":1,"type":"lifecycle","seq":1,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","terminal_kind":"no_comment"}"#.utf8))
        guard case let .terminal(_, state, _) = noComment.body else {
            return XCTFail("The known lifecycle terminal must continue to decode.")
        }
        XCTAssertEqual(state, .noComment,
                       "The existing terminal_kind field carries No comment across older-server fallback.")

        let commonNoComment = try wire.decodeEvent(Data(#"{"v":1,"type":"lifecycle","seq":4,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","terminal_kind":"no_comment","answer_outcome":{"kind":"no_comment"}}"#.utf8))
        guard case let .terminal(_, commonState, _) = commonNoComment.body else {
            return XCTFail("The shared No comment terminal must continue to decode.")
        }
        XCTAssertEqual(commonState, .noComment)
        XCTAssertEqual(commonNoComment.accountAnswerOutcome, .noComment)

        let futureOutcome = try wire.decodeUpdate(Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","answer_outcome":{"kind":"future_outcome","detail":"ignored"}}"#.utf8))
        guard case let .event(event) = futureOutcome else {
            return XCTFail("An unknown optional answer outcome must not stop the lifecycle stream.")
        }
        XCTAssertNil(event.accountAnswerOutcome)

        let incompleteReply = try wire.decodeUpdate(Data(#"{"v":1,"type":"lifecycle","seq":3,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","answer_outcome":{"kind":"reply"}}"#.utf8))
        guard case let .event(replyEvent) = incompleteReply else {
            return XCTFail("An unusable optional reply outcome must not stop lifecycle replay.")
        }
        XCTAssertNil(replyEvent.accountAnswerOutcome)
    }

    func testAccountReplyOutcomePreservesExactTextAndHidesOriginOnlyLegacyAnswer() throws {
        let (context, store, live, key) = try setup()
        let exactText = "Exact reply, with spaces."
        let terminal = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","answer_outcome":{"kind":"reply","text":"Exact reply, with spaces."}}"#.utf8)
        let event = try RelayWire(profile: context).decodeEvent(terminal)
        XCTAssertEqual(event.accountAnswerOutcome, .reply(ExactText(exactText)))
        _ = try store.apply(event, context: context)
        try live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.accountAnswerOutcome, .reply(ExactText(exactText)))
        XCTAssertNil(request.informationalSeenStatus,
                     "A reply is not a failed Seen action.")
        XCTAssertNil(request.intentReceipt,
                     "The synced account outcome, not a phone-local receipt, supplies the answer text.")
        XCTAssertNil(request.receiptFacts)
    }

    func testDefaultOutcomeShowsServerWordsAndMarksTheMatchingCurrentChoice() throws {
        let (context, _, _, key) = try setup()
        let initialPayload = try JSONValue.parse(Data(#"{"title":"Choose","stake":"Earlier stake","by_when":1793200000000,"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Old choice","kind":"value","value":1}]}}"#.utf8))
        // Replace the setup message with a fresh store to keep the event sequence coherent.
        let freshStore = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
        _ = try freshStore.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: initialPayload), .message)),
            context: context)
        try freshStore.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("origin"), payload: initialPayload)),
            context: context)
        let revisedPayload = try JSONValue.parse(Data(#"{"title":"Choose","stake":"The review deadline slips.","by_when":1793300000000,"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"first","label":"Later","kind":"value","value":1},{"id":"second","label":"Later","kind":"value","value":2}]}}"#.utf8))
        let binding = ConversationBinding(request: key, revision: 2)
        let revision = ConversationTurn(id: ExactText("revision-2"), binding: binding,
            author: .origin, sessionHandle: ExactText("origin"), text: ExactText("Choose"), kind: .revision)
        try freshStore.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .revision(revision, payload: revisedPayload)), context: context)
        let defaultFrame = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"server","state":"answered","by":"default","answer_outcome":{"kind":"default","value":2,"text":"Hold for now"}}"#.utf8)
        _ = try freshStore.apply(RelayWire(profile: context).decodeEvent(defaultFrame), context: context)
        let live = try LivePresentationStore(store: freshStore, context: context)

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertTrue(request.isDefaultAnswered)
        XCTAssertEqual(request.defaultAnswerAction,
                       ProjectedActionReference(inputID: nil, actionID: ExactText("second")))
        XCTAssertEqual(request.defaultAnswerWords, "Hold for now",
                       "Display words come from the shared outcome, not the duplicate action label.")
        XCTAssertEqual(request.defaultAnswerStatusText, "Answered by default: Hold for now")
        XCTAssertEqual(LiveRequestDetail.answeredStatusTitle(
            accountAnswerOutcome: request.accountAnswerOutcome, isLiveRequest: true), "Answered by default")
        XCTAssertEqual(request.byWhenMilliseconds, 1_793_300_000_000)
        XCTAssertEqual(request.stakeText, ExactText("The review deadline slips."))
        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(row.belongsToReplied)
        XCTAssertEqual(row.defaultAnswerStatus, "Answered by default: Hold for now")
    }

    func testDefaultOutcomeWithoutValueStillShowsTextAndDefaultStatus() throws {
        let (context, _, _, key) = try setup()
        let store = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
        let payload = try JSONValue.parse(Data(#"{"title":"Choose","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":true}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let frame = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"server","state":"answered","answer_outcome":{"kind":"default","text":"Yes, automatically"}}"#.utf8)
        _ = try store.apply(RelayWire(profile: context).decodeEvent(frame), context: context)

        let live = try LivePresentationStore(store: store, context: context)
        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertNil(request.defaultAnswerAction)
        XCTAssertEqual(request.defaultAnswerWords, "Yes, automatically")
        XCTAssertEqual(try XCTUnwrap(live.inboxRows.first { $0.key == key }).defaultAnswerStatus,
                       "Answered by default: Yes, automatically")
    }

    func testTerminalInboxPageCarriesTheSharedAccountOutcome() throws {
        let (context, _, _, key) = try setup()
        let paging = try InboxPagingWire(profile: context)
        let page = Data(#"{"v":1,"type":"ok","paging_version":1,"ref":"page","snapshot_id":"snapshot","high_water":2,"items":[{"acceptance":{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"sample","origin":"origin","as":"message","message":{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"first","label":"Later","kind":"value","value":1},{"id":"second","label":"Later","kind":"value","value":2}]}},"session_handle":"handle","request_revision":1,"availability":"not_listening","last_detached_at":123},"terminal":{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","answer_outcome":{"kind":"default","value":2,"text":"Hold for now"}}}],"next_cursor":null}"#.utf8)

        let decoded = try paging.decodePage(page, ref: "page", snapshotID: "snapshot", highWater: 2)

        XCTAssertEqual(decoded.items.first?.terminal?.accountAnswerOutcome,
                       .defaultAnswer(value: .number(JSONNumber(lexeme: "2")),
                                      text: ExactText("Hold for now")))

        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        _ = try store.beginInboxCandidate(startupID: "startup", since: 0, batches: [], context: context)
        try store.saveInboxInitialPage(snapshotID: "snapshot", highWater: 2,
            items: decoded.items, nextCursor: nil, receiptCursor: nil, context: context)
        _ = try store.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try store.acceptInboxCheckpoint(snapshotID: "snapshot", highWater: 2, context: context)
        let reconnected = try AttentionDomainStore(context: context, persistence: persistence)
        let live = try LivePresentationStore(store: reconnected, context: context)
        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertTrue(request.isDefaultAnswered)
        XCTAssertEqual(request.defaultAnswerAction,
                       ProjectedActionReference(inputID: nil, actionID: ExactText("second")))
        XCTAssertEqual(request.defaultAnswerWords, "Hold for now")
        XCTAssertEqual(try XCTUnwrap(live.inboxRows.first { $0.key == key }).defaultAnswerStatus,
                       "Answered by default: Hold for now")
    }

    func testOlderServerOriginOnlyAnswerDoesNotCreatePhoneSpecificSeenState() throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("sample"))
        let payload = try JSONValue.parse(Data(#"{"title":"Sample","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let live = try LivePresentationStore(store: store, context: context)
        let terminal = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"device","state":"answered","answer":{"acknowledgment":"seen"}}"#.utf8)
        _ = try store.apply(RelayWire(profile: context).decodeEvent(terminal), context: context)
        try live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.lifecycleStatus, .answered)
        XCTAssertNil(request.accountAnswerOutcome)
        XCTAssertNil(request.informationalSeenStatus,
                     "An older server's origin-only answer is not the shared account outcome.")
        XCTAssertNil(request.intentReceipt)
        XCTAssertNil(request.receiptFacts)
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).status.contains("Answered"))
        XCTAssertEqual(LiveRequestDetail.answeredStatusTitle(
            accountAnswerOutcome: request.accountAnswerOutcome, isLiveRequest: true), "Answered",
            "An older server's terminal stays generic instead of claiming Replied or Seen.")
    }

    func testRemoteRequestStateReadsPersistedRecordsWithoutAccountOutcome() throws {
        let saved = try JSONDecoder().decode(RemoteRequestState.self,
                                             from: Data(#"{"state":"answered"}"#.utf8))
        XCTAssertEqual(saved.state, .answered)
        XCTAssertNil(saved.accountAnswerOutcome)
    }

    func testNoCommentCheckmarkCommitsWithoutSavingReplyContents() throws {
        let (context, store, live, key) = try setupReplyOnly()
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

        let submitted = try XCTUnwrap(store.snapshot(context: context).outbox.first)
        XCTAssertEqual(String(decoding: submitted.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"reply-only","request_revision":1}"# + "\n")
        XCTAssertNil(try store.snapshot(context: context).drafts[key])
        XCTAssertTrue(try XCTUnwrap(live.request(for: key)).submittedAnswer?.noCommentSelected == true)
        XCTAssertEqual(submitted.answerKind, .noComment)
    }

    func testNoCommentUsesDisplayedRevisionAndStaleTapKeepsCurrentQuestionOpen() throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
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
        let staleSubmission = try XCTUnwrap(store.snapshot(context: context).outbox.first)
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
    }

    func testDisconnectedInboxKeepsDraftReadOnlyAndCannotCreateOrRetryAnAnswer() throws {
        let (context, store, live, key) = try setup()
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

    func testLateSendOnAnotherDevicesTerminalRequestDoesNotClaimOurAnswerWasAccepted() throws {
        let (context, store, live, key) = try setup()
        _ = try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil)), context: context)
        live.submitFromUser(key)
        XCTAssertEqual(live.actionError, "This request is no longer open for an answer.")
        XCTAssertTrue(try store.snapshot(context: context).intents.isEmpty)
        XCTAssertNil(live.request(for: key)?.receiptFacts)
    }

    func testAcceptedAnswerReplaysTerminalEventBeforeCompletingRefresh() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        try live.refreshFromDurableStore()
        XCTAssertEqual(high, 2)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(session.acknowledgedCursors, [2],
                       "The checkpoint ACK is distinct; ordinary ACKs cover only post-H events.")
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "Without the common outcome field, local acceptance is not displayed as shared state.")
    }

    func testServerAnsweredAfterLostOperationReplyMovesToRepliedWithoutInventingAcceptance() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        session.loseOperationReply = true
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try live.refreshFromDurableStore()
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "A terminal received from the account feed supersedes local delivery uncertainty.")
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
        XCTAssertNil(live.actionError)
        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(row.belongsToReplied,
                      "The server's answered lifecycle moves the row to Replied.")
        XCTAssertFalse(row.hasFailedResponse)
        XCTAssertTrue(row.isResolved)
        XCTAssertNil(row.localStatus)
        XCTAssertTrue(row.status.contains("Answered"),
                      "Keep the server's answered wording without attributing it to this device.")
    }

    func testServerNoCommentAfterLostOperationReplyMovesToRepliedWithoutInventingAcceptance() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitNoComment(store, key: key)
        let session = AnswerSession(context.identity)
        session.loseOperationReply = true
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let sentCount = try await core.sendPendingOriginalOperations()
        XCTAssertEqual(sentCount, 1)
        try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)), context: context)
        try live.refreshFromDurableStore()

        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .noComment)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "The common answered state is shown without phone-specific operation attribution.")
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
        XCTAssertNil(live.actionError)

        let liveRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(liveRow.belongsToReplied,
                      "The server's no-comment lifecycle moves the row to Replied.")
        XCTAssertFalse(liveRow.hasFailedResponse)
        XCTAssertTrue(liveRow.isResolved)
        XCTAssertNil(liveRow.localStatus)
        XCTAssertTrue(liveRow.status.contains("No comment"),
                      "Show the server's lifecycle wording without claiming this device's send was accepted.")

        let sampleResponse = sampleResponse(for: live, key: key)
        let sampleRow = try XCTUnwrap(sampleResponse.inboxRow)
        XCTAssertTrue(sampleRow.belongsToReplied,
                      "The sample projection follows the same server-reported final response.")
        XCTAssertFalse(sampleRow.hasFailedResponse)
        XCTAssertNil(sampleRow.localStatus)
    }

    func testServerNoCommentHidesPriorUnsupportedNoteFromBothRepliedProjections() throws {
        let (context, store, live, key) = try setupReplyOnly()
        let receipt = try commitNoComment(store, key: key)
        try store.recordNoCommentUnsupported(receipt.intentID, operationID: receipt.opID, context: context)
        try live.refreshFromDurableStore()
        XCTAssertTrue(live.request(for: key)?.noCommentUnavailable == true)
        let unsupportedLiveRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertFalse(unsupportedLiveRow.belongsToReplied,
                       "An unsupported No comment leaves the request in Inbox.")
        XCTAssertTrue(unsupportedLiveRow.status.contains("No comment not delivered"))
        try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)), context: context)
        try live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertFalse(request.noCommentUnavailable,
                       "A terminal account state supersedes the device-local failed attempt.")
        let liveRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(liveRow.belongsToReplied)
        XCTAssertFalse(liveRow.status.contains("No comment not delivered"))
        XCTAssertFalse(liveRow.localStatus?.contains("No comment not delivered") == true)

        let sampleResponse = sampleResponse(for: live, key: key)
        let sampleRow = try XCTUnwrap(sampleResponse.inboxRow)
        XCTAssertTrue(sampleRow.belongsToReplied)
        XCTAssertFalse(sampleRow.status.contains("No comment not delivered"))
        XCTAssertNil(sampleRow.localStatus)
    }

    func testFailedTerminalReplayDoesNotEraseAcceptedAnswerOrResendItOnReconnect() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        session.failReplayAfterSend = true
        let core = try NativeRelayCore(store: store, context: context, session: session)
        do { _ = try await core.resyncAndDrainOutbox(); XCTFail("The second replay is interrupted") }
        catch InstallationTransportError.unexpectedServerFrame {}
        try live.refreshFromDurableStore()
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted,
                       "A sent answer remains pending locally until its lifecycle terminal arrives.")
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        session.failReplayAfterSend = false
        // A failed replay retires its connection's core; reconnect, as the
        // lifecycle does, with a fresh core over the same durable store.
        let reconnected = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await reconnected.resyncAndDrainOutbox()
        try live.refreshFromDurableStore()
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "The shared terminal projection replaces local operation attribution.")
    }

    func testNotificationRegistrationRefusalDoesNotDowngradeAcceptedAnswer() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try live.refreshFromDurableStore()

        let result = await NativeRelayRefreshResult.afterConfirmedRelay(
            context: context, transportAttemptID: UUID()) {
            throw InstallationTransportError.serverRejected
        }
        live.applyRefreshResult(result)
        XCTAssertTrue(result.relayConfirmed)
        XCTAssertEqual(result.pushRegistration, .unconfirmed)
        XCTAssertFalse(result.completedWithoutError)
        XCTAssertNil(live.connectionWarning, "A refused notification setup is not a failed relay answer.")
        XCTAssertNotNil(live.pushRegistrationWarning)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "Shared terminal state does not depend on which device sent the answer.")
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty)
    }

    func testLaterRelayFailureKeepsAcceptedReceiptAndNoRegistrationIsInventedOnRecovery() async throws {
        let (context, store, live, key) = try setup()
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

    func testConfirmedNotificationSetupClearsItsWarningWithoutCreatingAnAnswer() async throws {
        let (context, store, live, key) = try setup()
        let refused = await NativeRelayRefreshResult.afterConfirmedRelay(
            context: context, transportAttemptID: UUID()) {
            throw InstallationTransportError.serverRejected
        }
        live.applyRefreshResult(refused)
        XCTAssertNotNil(live.pushRegistrationWarning)
        let registered = await NativeRelayRefreshResult.afterConfirmedRelay(
            context: context, transportAttemptID: UUID()) { .confirmed }
        live.applyRefreshResult(registered)
        XCTAssertEqual(registered.pushRegistration, .confirmed)
        XCTAssertNil(live.pushRegistrationWarning)
        XCTAssertNil(live.connectionWarning)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .open)
        XCTAssertTrue(try store.snapshot(context: context).intents.isEmpty)
    }
}

private final class AnswerSession: AuthenticatedInboxPagingSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    var sentOperationIDs: [UUID] = []
    var acceptedOperationIDs: Set<UUID> = []
    var acknowledgedCursors: [UInt64] = []
    var loseOperationReply = false
    var rejectOperation = false
    var failReplayAfterSend = false

    init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        if !sentOperationIDs.isEmpty && failReplayAfterSend {
            throw InstallationTransportError.unexpectedServerFrame
        }
        try await consume(Data("{\"v\":1,\"type\":\"ok\",\"ref\":\"native-sync\"}\n".utf8))
        let since = try JSONValue.parse(request).uniqueValue(named: "since")
        if !sentOperationIDs.isEmpty {
            if case .number(let number)? = since, number.lexeme == "1" {
                try await consume(Data("{\"v\":1,\"type\":\"lifecycle\",\"seq\":2,\"sender_id\":\"sender\",\"message_id\":\"sample\",\"origin\":\"device\",\"state\":\"answered\",\"at\":1,\"answer\":\"got-it\"}\n".utf8))
            }
            try await consume(Data("{\"v\":1,\"type\":\"resynced\",\"seq\":2}\n".utf8))
        } else {
            try await consume(Data("{\"v\":1,\"type\":\"resynced\",\"seq\":1}\n".utf8))
        }
    }

    func acknowledge(_ request: Data) async throws {
        if case .number(let value)? = try JSONValue.parse(request).uniqueValue(named: "seq"),
           let sequence = UInt64(value.lexeme) { acknowledgedCursors.append(sequence) }
    }

    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        sentOperationIDs.append(operationID)
        if rejectOperation { return .failed(operationID: operationID) }
        if loseOperationReply { return .unresolved }
        acceptedOperationIDs.insert(operationID)
        return .accepted(operationID: operationID, terminalSequence: 2)
    }

    /// Once the relay has accepted an answer, a new connection's inbox
    /// snapshot includes its terminal at sequence 2 and reconciles the
    /// operation as committed, as the relay reports an accepted original.
    func inboxRequest(_ request: Data, ref: String) async throws -> Data {
        let value = try JSONValue.parse(request)
        let kind = value.uniqueValue(named: "type")?.stringValue?.rawValue
        guard !acceptedOperationIDs.isEmpty, kind == "inbox_start" || kind == "inbox_reconcile" else {
            return try await emptyInboxReply(request, ref: ref)
        }
        var reply = "{\"v\":1,\"type\":\"ok\",\"ref\":\"\(ref)\",\"paging_version\":1,\"high_water\":2"
        if kind == "inbox_start" {
            let startupID = value.uniqueValue(named: "startup_id")?.stringValue?.rawValue ?? ""
            reply += ",\"snapshot_id\":\"test-\(startupID)-h2\",\"items\":[],\"next_cursor\":null,\"receipt_cursor\":null}"
        } else {
            let snapshotID = value.uniqueValue(named: "snapshot_id")?.stringValue?.rawValue ?? ""
            let batchID = value.uniqueValue(named: "batch_id")?.stringValue?.rawValue ?? ""
            let results = (value.uniqueValue(named: "operations")?.arrayValues ?? []).map { operation -> String in
                let opID = operation.uniqueValue(named: "op_id")?.stringValue?.rawValue ?? ""
                guard let id = UUID(uuidString: opID), acceptedOperationIDs.contains(id) else {
                    return "{\"op_id\":\"\(opID)\",\"status\":\"not_committed_at_snapshot\"}"
                }
                return "{\"op_id\":\"\(opID)\",\"status\":\"committed\",\"result\":{\"v\":1,\"type\":\"ok\",\"seq\":2,\"duplicate\":true},\"terminal\":{\"v\":1,\"type\":\"lifecycle\",\"seq\":2,\"sender_id\":\"sender\",\"message_id\":\"sample\",\"origin\":\"device\",\"state\":\"answered\",\"at\":1,\"answer\":\"got-it\"}}"
            }
            reply += ",\"snapshot_id\":\"\(snapshotID)\",\"batch_id\":\"\(batchID)\",\"results\":[\(results.joined(separator: ","))]}"
        }
        return Data((reply + "\n").utf8)
    }
}
