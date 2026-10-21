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

    private func sampleProjection(for live: LivePresentationStore, key: RequestKey) -> InboxRequestRow? {
        let message = SampleMessage(id: key.messageID.rawValue, kind: .note,
            sender: key.senderID.rawValue, initials: "", title: "Sample request", body: "",
            options: [], deadline: nil, missed: false, revised: false,
            chatUnread: false, hasChat: false, fixtureCreatedAtMilliseconds: 0)
        return SampleResponse(viewModel: live, key: key, message: message).inboxRow
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
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
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
        XCTAssertNil(submitted.requestRevision,
                     "Ordinary requests have no server-supplied request revision.")
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
        XCTAssertEqual(accepted.receiptFacts?.ownOutcome, .accepted)
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
        XCTAssertEqual(request.receiptFacts?.evidenceLabel, "The sender recorded your No comment answer.")
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied)
    }

    func testNoCommentKeepsTypedDraftSavedWithoutPuttingItInTheFrame() throws {
        let (context, store, live, key) = try setupReplyOnly()
        live.updateCompatibilityText("Keep this as an unsent draft.", action: ExactText("reply"), for: key)
        live.flushPendingDraft(for: key)
        live.selectNoComment(for: key)

        XCTAssertTrue(live.request(for: key)?.draft.noCommentSelected == true)
        XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied,
                       "Selecting No comment is still an unsent draft.")
        live.submitFromUser(key)

        let submitted = try XCTUnwrap(store.snapshot(context: context).outbox.first)
        XCTAssertEqual(String(decoding: submitted.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"reply-only","request_revision":1}"# + "\n")
        let savedDraft = try store.snapshot(context: context).drafts[key]
        XCTAssertEqual(savedDraft?.compatibility
            .textByActionID[ExactText("reply")], ExactText("Keep this as an unsent draft."))
        XCTAssertTrue(savedDraft?.noCommentSelected == true)
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

        // A stale refusal stays unconfirmed; replay supplies the newer open revision.
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
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .unconfirmed)
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
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
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
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .unconfirmed)
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
        session.terminalState = .noComment
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try live.refreshFromDurableStore()

        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .noComment)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .unconfirmed)
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

        let sampleRow = try XCTUnwrap(sampleProjection(for: live, key: key))
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
        let unsupportedSampleRow = try XCTUnwrap(sampleProjection(for: live, key: key))
        XCTAssertFalse(unsupportedSampleRow.belongsToReplied)
        XCTAssertTrue(unsupportedSampleRow.localStatus?.contains("No comment not delivered") == true)

        try store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)), context: context)
        try live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertTrue(request.noCommentUnavailable,
                      "The underlying unsupported-send fact remains available for detail behavior.")
        let liveRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(liveRow.belongsToReplied)
        XCTAssertFalse(liveRow.status.contains("No comment not delivered"))
        XCTAssertFalse(liveRow.localStatus?.contains("No comment not delivered") == true)

        let sampleRow = try XCTUnwrap(sampleProjection(for: live, key: key))
        XCTAssertTrue(sampleRow.belongsToReplied)
        XCTAssertFalse(sampleRow.status.contains("No comment not delivered"))
        XCTAssertFalse(sampleRow.localStatus?.contains("No comment not delivered") == true)
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
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
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
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
    }

    func testNotificationRegistrationRefusalDoesNotDowngradeAcceptedAnswer() async throws {
        let (context, store, live, key) = try setup()
        let receipt = try commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try live.refreshFromDurableStore()

        let result = await NativeRelayRefreshResult.afterConfirmedRelay {
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
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
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

        let result = await NativeRelayRefreshResult.afterConfirmedRelay { .notAttempted }
        live.applyRefreshResult(result)
        XCTAssertNil(live.connectionWarning)
        XCTAssertEqual(result.pushRegistration, .notAttempted,
                       "A working relay alone cannot establish APNs registration.")
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
    }

    func testConfirmedNotificationSetupClearsItsWarningWithoutCreatingAnAnswer() async throws {
        let (context, store, live, key) = try setup()
        let refused = await NativeRelayRefreshResult.afterConfirmedRelay {
            throw InstallationTransportError.serverRejected
        }
        live.applyRefreshResult(refused)
        XCTAssertNotNil(live.pushRegistrationWarning)
        let registered = await NativeRelayRefreshResult.afterConfirmedRelay { .confirmed }
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
    var failReplayAfterSend = false
    var terminalState = TerminalState.answered

    init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        if !sentOperationIDs.isEmpty && failReplayAfterSend {
            throw InstallationTransportError.unexpectedServerFrame
        }
        try await consume(Data("{\"v\":1,\"type\":\"ok\",\"ref\":\"native-sync\"}\n".utf8))
        let since = try JSONValue.parse(request).uniqueValue(named: "since")
        if !sentOperationIDs.isEmpty {
            if case .number(let number)? = since, number.lexeme == "1" {
                let answer = terminalState == .answered ? ",\"answer\":\"got-it\"" : ""
                let event = "{\"v\":1,\"type\":\"lifecycle\",\"seq\":2,\"sender_id\":\"sender\",\"message_id\":\"sample\",\"origin\":\"device\",\"state\":\"\(terminalState.rawValue)\",\"at\":1\(answer)}\n"
                try await consume(Data(event.utf8))
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
