@testable import AttentionDomain
import Foundation
import XCTest
@testable import Harklight

final class SubmissionControlPhaseTests: XCTestCase {
    private let key = RequestKey(accountScope: ExactText("account"), senderID: ExactText("sender"),
                                 messageID: ExactText("question"))
    private let sentAt = Date(timeIntervalSince1970: 100)

    func testEachOperationOutcomeMapsToOneControlPhase() {
        let cases: [(IntentDisposition, SubmissionControlPhase.Phase)] = [
            (.pending, .sending),
            (.accepted(sequence: 2), .confirmed),
            (.lost, .failed(retryable: true, editable: false)),
            (.failed, .failed(retryable: true, editable: true)),
            (.unsupported, .failed(retryable: true, editable: true)),
            (.repairRequired, .failed(retryable: false, editable: false)),
            (.staleRevision(currentRevision: 2), .refused(.changed)),
            (.refusedClosed, .refused(.closed)),
            (.refusedNotFound, .refused(.closed)),
            (.refusedByRetraction(retractedAtMilliseconds: 5), .refused(.retracted)),
        ]
        for (disposition, expected) in cases {
            XCTAssertEqual(project([submission(disposition)])[key]?.phase, expected, "\(disposition)")
        }
    }

    func testReplayedTerminalConfirmsOnlyTheSameAnswer() {
        let mine = submission(.terminal(state: .answered, sequence: 3,
                                        authorizedAnswer: .string(ExactText("Answer"))))
        XCTAssertEqual(project([mine])[key]?.phase, .confirmed,
                       "A replay showing this answer arrived goes straight to confirmed.")
        let other = submission(.terminal(state: .answered, sequence: 3,
                                         authorizedAnswer: .string(ExactText("Someone else's"))))
        XCTAssertEqual(project([other])[key]?.phase, .refused(.closed))
        let expired = submission(.terminal(state: .expired, sequence: 3, authorizedAnswer: nil))
        XCTAssertEqual(project([expired])[key]?.phase, .refused(.closed))
    }

    func testTheMessagesFinalStateEndsSending() {
        let answered = [key: RemoteRequestState(state: .answered)]
        XCTAssertEqual(project([submission(.accepted(sequence: 2))], remote: answered)[key]?.phase, .confirmed)
        XCTAssertEqual(project([submission(.accepted(sequence: 2))],
                               remote: [key: RemoteRequestState(state: .expired)])[key]?.phase,
                       .refused(.closed), "A final state that is not an answer reverts the confirmation.")
        XCTAssertEqual(project([submission(.lost)], remote: answered)[key]?.phase, .refused(.closed))
        XCTAssertEqual(project([submission(.failed)], remote: answered)[key]?.phase,
                       .failed(retryable: false, editable: false), "No Retry once the message is closed.")
    }

    func testKindComesFromTheOperation() {
        XCTAssertEqual(project([submission(.pending)])[key]?.kind, .answer)
        XCTAssertEqual(project([submission(.pending, kind: .noComment)])[key]?.kind, .noComment)
    }

    func testTheMostRecentOperationWinsAndTheProjectionIsPure() {
        let older = submission(.failed, at: sentAt)
        let newer = submission(.pending, at: sentAt.addingTimeInterval(10))
        let snapshot = makeSnapshot([older, newer])
        let first = SubmissionControlPhase.project(snapshot: snapshot)
        XCTAssertEqual(first[key]?.phase, .sending)
        XCTAssertEqual(first[key]?.operationID, newer.operationID)
        XCTAssertEqual(SubmissionControlPhase.project(snapshot: snapshot), first,
                       "The same store always gives the same phases.")
        XCTAssertNil(SubmissionControlPhase.project(snapshot: makeSnapshot([]))[key])
    }

    @MainActor
    func testEditDropsOnlyAFailedReplyAndKeepsItsDraft() throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("edit-reply"), deviceID: ExactText("device")), transportMode: .relay)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"),
                             messageID: ExactText("reply"))
        let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try domain.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: try Self.deliveredRequests(key: key, payload: payload, context: context), remoteStates: [:],
            cursor: 1, conversationCursor: 0, conversations: [:], inboxView: nil, currentRequestKeys: [key]),
            context: context)
        let port = AttentionDomainPort(store: domain)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
            inputs: [.compatibilityText(action: ExactText("reply"), text: ExactText("My failed reply"))]))
        let live = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(live.submissionPhases[key]?.phase, .failed(retryable: true, editable: false))
        XCTAssertFalse(live.releaseFailedSubmissionForEdit(key), "A send in flight cannot become a draft.")
        XCTAssertThrowsError(try domain.releaseFailedOperationForEdit(receipt.intentID, context: context))

        try domain.recordUnresolvedOperation(receipt.intentID, operationID: receipt.opID, context: context)
        try live.refreshFromDurableStore()
        XCTAssertEqual(live.submissionPhases[key]?.phase, .failed(retryable: true, editable: false))
        XCTAssertFalse(live.releaseFailedSubmissionForEdit(key),
                       "A lost send may have arrived, so it keeps its operation.")
        XCTAssertThrowsError(try domain.releaseFailedOperationForEdit(receipt.intentID, context: context))

        try domain.recordAnswerNotDelivered(receipt.intentID, operationID: receipt.opID, context: context)
        try live.refreshFromDurableStore()
        XCTAssertEqual(live.submissionPhases[key]?.phase, .failed(retryable: true, editable: true))
        XCTAssertTrue(live.releaseFailedSubmissionForEdit(key))
        let released = try domain.snapshot(context: context)
        XCTAssertNil(released.intents[receipt.intentID])
        XCTAssertFalse(released.outbox.contains { $0.intentID == receipt.intentID })
        XCTAssertNil(live.submissionPhases[key])
        XCTAssertNil(live.request(for: key)?.intentReceipt)
        XCTAssertNotNil(released.drafts[key], "The written text stays as a draft to edit.")
    }

    // MARK: - Real saved-operation transitions

    private struct LiveFixture {
        let context: ProfileContext
        let key: RequestKey
        let domain: ClientRepository
        let port: AttentionDomainPort
        let selector: BoundDocumentSelector
        let live: LivePresentationStore

        @MainActor
        func submit(_ inputs: [TypedInputRecord], persistDraft: Bool = true) throws -> IntentReceipt {
            try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                                         inputs: inputs, persistAnswerDraft: persistDraft))
        }

        @MainActor
        func refresh() throws -> LiveRequestDetail {
            try live.refreshFromDurableStore()
            return LiveRequestDetail(request: try XCTUnwrap(live.request(for: key)), store: live)
        }

        var intents: [Submission] {
            get throws { Array(try domain.snapshot(context: context).intents.values) }
        }
    }

    @MainActor
    private func liveFixture(payload: JSONValue, name: String = #function) throws -> LiveFixture {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("phase-\(name)"), deviceID: ExactText("device")), transportMode: .relay)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"),
                             messageID: ExactText("question"))
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try domain.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: try Self.deliveredRequests(key: key, payload: payload, context: context), remoteStates: [:],
            cursor: 1, conversationCursor: 0, conversations: [:], inboxView: nil, currentRequestKeys: [key]),
            context: context)
        let port = AttentionDomainPort(store: domain)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        return LiveFixture(context: context, key: key, domain: domain, port: port, selector: selector,
                           live: try LivePresentationStore(store: domain, context: context))
    }

    /// Requests as the store keeps them after a delivery, with their durable
    /// order, for a cache restore.
    private static func deliveredRequests(key: RequestKey, payload: JSONValue,
                                          context: ProfileContext) throws -> [RequestKey: StoredRequest] {
        let previous = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        _ = try previous.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        return try previous.snapshot(context: context).requests
    }

    private func choicePayload() throws -> JSONValue {
        try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"a","label":"Cover A","kind":"value","value":"a"},{"id":"b","label":"Cover B","kind":"value","value":"b"},{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
    }

    @MainActor
    func testADroppedLargeAnswerOffersRetryThenConfirmsOnlyAtAcceptance() throws {
        let fixture = try liveFixture(payload: try choicePayload())
        let text = ExactText(String(repeating: "x", count: 2 * 1024 * 1024 + 1))
        let receipt = try fixture.submit([.compatibilityText(action: ExactText("reply"), text: text)])
        let saved = try XCTUnwrap(fixture.intents.first)
        XCTAssertGreaterThan(saved.wireFrame.count, 2 * 1024 * 1024)
        XCTAssertEqual(try fixture.refresh().submissionPhase?.phase, .sending)

        // The connection drops mid-send: the outcome is unknown and the store
        // keeps the same operation for recovery.
        try fixture.domain.recordUnresolvedOperation(receipt.intentID, operationID: receipt.opID,
                                                     context: fixture.context)
        var detail = try fixture.refresh()
        XCTAssertEqual(detail.submissionPhase?.phase, .failed(retryable: true, editable: false))
        XCTAssertNotNil(detail.submissionDisplay.retryAction(.answer))
        XCTAssertTrue(detail.submissionDisplay.isFailed(.answer))
        XCTAssertFalse(detail.submissionDisplay.canEdit(.answer))
        XCTAssertFalse(detail.isDurablyAccepted(.answer))
        XCTAssertTrue(detail.controlsReadOnly, "Other answers stay locked while it may have arrived.")
        fixture.live.selectAction(ExactText("b"), input: nil, for: fixture.key)
        XCTAssertEqual(try fixture.intents.map(\.operationID), [receipt.opID])

        // Reconnect: the same operation is sent again, then accepted.
        _ = try fixture.domain.queueOriginalOperationForUserTap(receipt.intentID, context: fixture.context)
        XCTAssertEqual(try fixture.refresh().submissionPhase?.phase, .sending)
        try fixture.domain.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                                   terminalSequence: 2, context: fixture.context)
        detail = try fixture.refresh()
        XCTAssertEqual(detail.submissionPhase?.phase, .confirmed,
                       "Durable acceptance is the server's confirmation.")
        XCTAssertTrue(detail.isDurablyAccepted(.answer), "The control becomes the answered card.")
        XCTAssertFalse(detail.submissionDisplay.isSendingAny)

        try finish(fixture, intentID: receipt.intentID, state: .answered)
        detail = try fixture.refresh()
        XCTAssertEqual(fixture.live.request(for: fixture.key)?.lifecycleStatus, .answered)
        XCTAssertFalse(detail.submissionDisplay.isSendingAny)
        XCTAssertFalse(detail.submissionDisplay.isFailed(.answer))
    }

    @MainActor
    func testAnAcceptedAnswerRevertsWhenTheFinalStateRefusesIt() throws {
        let fixture = try liveFixture(payload: try choicePayload())
        let receipt = try fixture.submit([.compatibilityValue(action: ExactText("a"))])
        try fixture.domain.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                                   terminalSequence: 2, context: fixture.context)
        XCTAssertTrue(try fixture.refresh().isDurablyAccepted(.answer))

        try finish(fixture, intentID: receipt.intentID, state: .expired)
        let detail = try fixture.refresh()
        XCTAssertFalse(detail.isDurablyAccepted(.answer), "The answered card goes.")
        XCTAssertFalse(detail.submissionDisplay.isSendingAny)
        XCTAssertFalse(detail.submissionDisplay.isFailed(.answer), "A refusal is not a failure; no Retry.")
        XCTAssertNil(detail.submissionDisplay.reasonLine, "Closed shows in place, with no extra line.")
    }

    @MainActor
    func testANewerVersionRetiresTheOldAnswerAndTakesANewOne() throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("phase-revision"), deviceID: ExactText("device")), transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"),
                             messageID: ExactText("request"))
        let first = try JSONValue.parse(Data(#"{"title":"First wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Old choice","kind":"text"}]}}"#.utf8))
        let second = try JSONValue.parse(Data(#"{"title":"Revised wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"new","label":"New choice","kind":"text"}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: first), .message)),
                         context: context)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("origin"), payload: first)), context: context)
        let port = AttentionDomainPort(store: domain)
        let oldSelector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let old = try port.submit(SubmitIntent(context: port.context, selector: oldSelector, intentID: UUID(),
            inputs: [.compatibilityText(action: ExactText("old"), text: ExactText("Old answer"))]))
        try domain.recordAcceptedOperation(old.intentID, operationID: old.opID, terminalSequence: 2, context: context)

        // The sender sends a newer open version: the store retires the old
        // answer as lost history.
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: ConversationBinding(request: key, revision: 2),
            fact: .request(sessionHandle: ExactText("origin"), payload: second)), context: context)
        try domain.setInboxView(InboxView(revision: ExactText("view-1"), entries: [
            InboxViewEntry(key: key, priority: .high, thread: ExactText("release"))
        ]), context: context)
        let retired = try XCTUnwrap(domain.lookupIntent(old.intentID, context: context))
        XCTAssertEqual(retired.disposition, .lost)
        let live = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(live.submissionPhases[key]?.phase, .refused(.changed),
                       "Retired history is not in flight: the message changed.")
        XCTAssertEqual(SubmissionDisplay(phase: live.submissionPhases[key]).reasonLine,
                       "This message changed. Answer again.")
        XCTAssertNil(InboxSubmissionProgress.project(snapshot: try domain.snapshot(context: context),
                                                     threads: [:])[key], "No row spinner for retired history.")

        let newSelector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let next = try port.submit(SubmitIntent(context: port.context, selector: newSelector, intentID: UUID(),
            inputs: [.compatibilityText(action: ExactText("new"), text: ExactText("New answer"))]))
        XCTAssertEqual(try domain.lookupIntent(next.intentID, context: context)?.requestRevision, 2)
        try live.refreshFromDurableStore()
        XCTAssertEqual(live.submissionPhases[key]?.phase, .sending, "The new answer is the one in flight.")
        XCTAssertEqual(live.submissionPhases[key]?.operationID, next.opID)
    }

    func testAChangedMessageShowsItsReasonLine() {
        let display = SubmissionDisplay(phase: project([submission(.staleRevision(currentRevision: 2))])[key])
        XCTAssertEqual(display.reasonLine, "This message changed. Answer again.")
        XCTAssertNil(display.retryAction(.answer))
    }

    @MainActor
    func testAfterADefinitiveFailureAnotherChoiceSendsAsANewOperation() throws {
        let fixture = try liveFixture(payload: try choicePayload())
        let failed = try fixture.submit([.compatibilityValue(action: ExactText("a"))])
        try fixture.domain.recordAnswerNotDelivered(failed.intentID, operationID: failed.opID,
                                                    context: fixture.context)
        let detail = try fixture.refresh()
        XCTAssertEqual(detail.submissionPhase?.phase, .failed(retryable: true, editable: true))
        XCTAssertTrue(detail.submissionDisplay.isFailed(.answer), "A send the store gave up on shows failed.")
        XCTAssertFalse(detail.controlsReadOnly, "The other choices open again.")
        XCTAssertNotNil(detail.submissionDisplay.retryAction(.answer))

        fixture.live.selectAction(ExactText("b"), input: nil, for: fixture.key)
        XCTAssertTrue(try fixture.intents.isEmpty, "Picking another answer drops the failed operation.")
        XCTAssertEqual(fixture.live.draft(for: fixture.key)?.compatibility.selectedActionID, ExactText("b"))
        let next = try fixture.live.submit(fixture.key)
        XCTAssertNotEqual(next.opID, failed.opID, "The new answer is a new operation.")
        XCTAssertEqual(try fixture.intents.map(\.operationID), [next.opID])
    }

    @MainActor
    func testEditOnAFailedReplyBringsBackTheSentText() throws {
        let fixture = try liveFixture(payload: try choicePayload())
        let text = ExactText(String(repeating: "x", count: 2 * 1024 * 1024 + 1))
        let failed = try fixture.submit([.compatibilityText(action: ExactText("reply"), text: text)],
                                        persistDraft: false)
        try fixture.domain.recordAnswerNotDelivered(failed.intentID, operationID: failed.opID,
                                                    context: fixture.context)
        let detail = try fixture.refresh()
        XCTAssertTrue(detail.submissionDisplay.canEdit(.answer))
        XCTAssertNotNil(detail.submissionDisplay.retryAction(.answer))
        let request = try XCTUnwrap(fixture.live.request(for: fixture.key))
        XCTAssertNil(request.intentReceipt, "A definitively failed send is not the presented submission.")
        let session = fixture.live.replyEditorSession(for: request)
        XCTAssertEqual(session.draft.compatibility.selectedActionID, ExactText("reply"),
                       "Reopening the message shows the failed reply picked.")
        XCTAssertEqual(session.draft.compatibility.textByActionID[ExactText("reply")],
                       text, "and its sent text, locked until Edit.")

        XCTAssertTrue(fixture.live.releaseFailedSubmissionForEdit(fixture.key))
        XCTAssertTrue(try fixture.intents.isEmpty)
        XCTAssertNil(fixture.live.submissionPhases[fixture.key])
        XCTAssertTrue(session.hasLocalChanges, "Edit keeps the sent text as the edited draft.")
        XCTAssertEqual(session.draft.compatibility.textByActionID[ExactText("reply")],
                       text)
        XCTAssertEqual(fixture.live.draft(for: fixture.key)?.compatibility.textByActionID[ExactText("reply")],
                       text,
                       "A Reply box send keeps no draft, so Edit restores the sent text.")
    }

    @MainActor
    func testRetryResendsADefinitivelyFailedOperation() throws {
        let fixture = try liveFixture(payload: try choicePayload())
        let failed = try fixture.submit([.compatibilityValue(action: ExactText("a"))])
        try fixture.domain.recordAnswerNotDelivered(failed.intentID, operationID: failed.opID,
                                                    context: fixture.context)
        _ = try fixture.refresh()
        XCTAssertTrue(fixture.live.retrySubmissionFromUser(fixture.key))
        let intents = try fixture.intents
        XCTAssertEqual(intents.map(\.operationID), [failed.opID], "Retry resends the same operation.")
        XCTAssertEqual(intents.first?.disposition, .pending)
        XCTAssertEqual(fixture.live.submissionPhases[fixture.key]?.phase, .sending)
    }

    @MainActor
    func testAReplyBoxChoiceChangeReplacesADefinitivelyFailedAnswer() throws {
        let fixture = try liveFixture(payload: try choicePayload())
        let failed = try fixture.submit([.compatibilityValue(action: ExactText("a"))], persistDraft: false)
        try fixture.domain.recordAnswerNotDelivered(failed.intentID, operationID: failed.opID,
                                                    context: fixture.context)
        _ = try fixture.refresh()
        let request = try XCTUnwrap(fixture.live.request(for: fixture.key))
        let session = fixture.live.replyEditorSession(for: request)
        XCTAssertEqual(session.draft.compatibility.selectedActionID, ExactText("a"))
        session.selectAction(ExactText("b"), inputID: nil)
        fixture.live.releaseDefinitiveFailureBeforeChange(fixture.key)
        XCTAssertTrue(try fixture.intents.isEmpty)
        XCTAssertEqual(session.draft.compatibility.selectedActionID, ExactText("b"),
                       "The new pick is kept, not replaced by the failed answer.")
        XCTAssertTrue(fixture.live.submitFromUser(fixture.key, answerDraft: session.draft,
                                                  requestRevision: session.requestRevision))
        let next = try XCTUnwrap(try fixture.intents.first)
        XCTAssertNotEqual(next.operationID, failed.opID)
    }

    @MainActor
    func testASentNoCommentKeepsSendingThroughADropThenShowsItsCardAtAcceptance() throws {
        let fixture = try liveFixture(payload: try choicePayload())
        let receipt = try fixture.port.submitNoComment(context: fixture.port.context, selector: fixture.selector,
                                                       intentID: UUID())
        var detail = try fixture.refresh()
        XCTAssertEqual(detail.submissionPhase?.kind, .noComment)
        XCTAssertEqual(detail.submissionPhase?.phase, .sending)
        XCTAssertTrue(detail.showsNoCommentRow, "The No comment row carries its spinner.")

        try fixture.domain.recordUnresolvedOperation(receipt.intentID, operationID: receipt.opID,
                                                     context: fixture.context)
        detail = try fixture.refresh()
        XCTAssertEqual(detail.submissionPhase?.phase, .failed(retryable: true, editable: false))
        XCTAssertTrue(detail.showsNoCommentRow)
        XCTAssertNotNil(detail.submissionDisplay.retryAction(.noComment))

        _ = try fixture.domain.queueOriginalOperationForUserTap(receipt.intentID, context: fixture.context)
        try fixture.domain.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                                   terminalSequence: 2, context: fixture.context)
        detail = try fixture.refresh()
        XCTAssertEqual(detail.submissionPhase?.phase, .confirmed)
        XCTAssertTrue(detail.isDurablyAccepted(.noComment), "Accepted No comment shows its card.")

        try finish(fixture, intentID: receipt.intentID, state: .noComment)
        detail = try fixture.refresh()
        XCTAssertEqual(fixture.live.request(for: fixture.key)?.lifecycleStatus, .noComment)
        XCTAssertFalse(detail.submissionDisplay.isSendingAny)
    }

    /// The server's final state for the message, carrying this operation's answer.
    @MainActor
    private func finish(_ fixture: LiveFixture, intentID: UUID, state: TerminalState) throws {
        let answer = try XCTUnwrap(fixture.domain.snapshot(context: fixture.context).intents[intentID]).answer
        _ = try fixture.domain.apply(RelayEvent(sequence: 2,
            body: .terminal(fixture.key, state, state == .answered ? answer : nil)), context: fixture.context)
    }

    @MainActor
    func testAFailedSeenOffersRetrySeen() throws {
        let payload = try JSONValue.parse(Data(#"{"title":"Information","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        let fixture = try liveFixture(payload: payload)
        let receipt = try fixture.submit([.compatibilityValue(action: ExactText("seen"))])
        try fixture.domain.recordAnswerNotDelivered(receipt.intentID, operationID: receipt.opID,
                                                    context: fixture.context)
        let detail = try fixture.refresh()
        XCTAssertEqual(detail.submissionPhase?.kind, .seen)
        XCTAssertNotNil(detail.submissionDisplay.retryAction(.seen),
                        "A failed Seen reports pending but still offers Retry Seen.")
        XCTAssertFalse(detail.unlocksAfterDefinitiveFailure, "Seen only retries.")
    }

    @MainActor
    func testAFailedTypedFormOffersRetryAndEditWithItsFieldsRestored() throws {
        let fixtures = try FixtureSet.loadBundled(from: Bundle(for: HarklightTests.self))
        let form = try XCTUnwrap(fixtures.requests.first { $0.key.messageID == ExactText("facilities-01") })
        let fixture = try liveFixture(payload: form.originalPayload)
        let point = PointValue(x: 140, y: 625)
        let failed = try fixture.submit([.point(input: ExactText("location"), point: point),
                                         .text(input: ExactText("note"), text: ExactText("Check the partition."))],
                                        persistDraft: false)
        try fixture.domain.recordAnswerNotDelivered(failed.intentID, operationID: failed.opID,
                                                    context: fixture.context)
        let detail = try fixture.refresh()
        XCTAssertTrue(detail.submissionDisplay.isFailed(.answer))
        XCTAssertNotNil(detail.submissionDisplay.retryAction(.answer), "The form offers Retry.")
        XCTAssertTrue(detail.submissionDisplay.canEdit(.answer), "The form offers Edit.")

        let session = fixture.live.replyEditorSession(for: try XCTUnwrap(fixture.live.request(for: fixture.key)))
        XCTAssertEqual(session.draft.inputs[ExactText("note")]?.text, ExactText("Check the partition."),
                       "The failed form shows its sent fields, not blank ones.")
        XCTAssertEqual(session.draft.inputs[ExactText("location")]?.point, point)

        XCTAssertTrue(fixture.live.releaseFailedSubmissionForEdit(fixture.key))
        let draft = try XCTUnwrap(fixture.live.draft(for: fixture.key))
        XCTAssertEqual(draft.inputs[ExactText("note")]?.text, ExactText("Check the partition."))
        XCTAssertEqual(draft.inputs[ExactText("location")]?.point, point)
        XCTAssertEqual(session.draft.inputs[ExactText("note")]?.text, ExactText("Check the partition."))
    }

    private func submission(_ disposition: IntentDisposition, kind: SubmissionAnswerKind? = nil,
                            at date: Date? = nil) -> Submission {
        Submission(requestKey: key, answer: .string(ExactText("Answer")), answerKind: kind,
            intentID: UUID(), operationID: UUID(), operation: .null, descriptorFingerprint: "",
            contentFingerprint: "", disposition: disposition, requestRevision: 1,
            submittedAt: date ?? sentAt)
    }

    private func makeSnapshot(_ submissions: [Submission],
                              remote: [RequestKey: RemoteRequestState] = [:]) -> AttentionStoreSnapshot {
        AttentionStoreSnapshot(requests: [key: StoredRequest(key: key, originalPayload: .null)],
            drafts: [:], intents: Dictionary(uniqueKeysWithValues: submissions.map { ($0.intentID, $0) }),
            outbox: [], remoteStates: remote, fixtureSessions: [:], revision: 1, cursor: 0,
            replayBarrier: nil, repairIssues: [])
    }

    private func project(_ submissions: [Submission],
                         remote: [RequestKey: RemoteRequestState] = [:]) -> [RequestKey: SubmissionControlPhase] {
        SubmissionControlPhase.project(snapshot: makeSnapshot(submissions, remote: remote))
    }
}
