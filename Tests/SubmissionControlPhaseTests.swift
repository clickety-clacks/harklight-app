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

    func testRetryIsUnavailableOnceTheServerClosedTheMessage() {
        let closed = RemoteRequestState(state: .answered)
        XCTAssertEqual(project([submission(.lost)], remote: [key: closed])[key]?.phase,
                       .failed(retryable: false, editable: false))
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
            requests: [key: StoredRequest(key: key, originalPayload: payload)], remoteStates: [:], cursor: 1,
            conversationCursor: 0, conversations: [:], inboxView: nil, currentRequestKeys: [key]), context: context)
        let port = AttentionDomainPort(store: domain)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
            inputs: [.compatibilityText(action: ExactText("reply"), text: ExactText("My failed reply"))]))
        let live = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(live.submissionPhases[key]?.phase, .sending)
        XCTAssertFalse(live.releaseFailedSubmissionForEdit(key), "A send in flight cannot become a draft.")
        XCTAssertThrowsError(try domain.releaseFailedOperationForEdit(receipt.intentID, context: context))

        try domain.recordUnresolvedOperation(receipt.intentID, operationID: receipt.opID, context: context)
        try live.refreshFromDurableStore()
        XCTAssertEqual(live.submissionPhases[key]?.phase, .failed(retryable: true, editable: false))
        XCTAssertFalse(live.releaseFailedSubmissionForEdit(key),
                       "A lost send may have arrived, so it keeps its operation for Retry.")
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
            requests: [key: StoredRequest(key: key, originalPayload: payload)], remoteStates: [:], cursor: 1,
            conversationCursor: 0, conversations: [:], inboxView: nil, currentRequestKeys: [key]), context: context)
        let port = AttentionDomainPort(store: domain)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        return LiveFixture(context: context, key: key, domain: domain, port: port, selector: selector,
                           live: try LivePresentationStore(store: domain, context: context))
    }

    private func choicePayload() throws -> JSONValue {
        try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"a","label":"Cover A","kind":"value","value":"a"},{"id":"b","label":"Cover B","kind":"value","value":"b"},{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
    }

    @MainActor
    func testLostChoiceKeepsItsRetryWhileTheOtherChoicesStayLocked() throws {
        let fixture = try liveFixture(payload: try choicePayload())
        let receipt = try fixture.submit([.compatibilityValue(action: ExactText("a"))])
        try fixture.domain.recordUnresolvedOperation(receipt.intentID, operationID: receipt.opID,
                                                     context: fixture.context)
        let detail = try fixture.refresh()
        XCTAssertEqual(detail.submissionPhase?.phase, .failed(retryable: true, editable: false))
        XCTAssertTrue(detail.controlsReadOnly, "A lost send may have arrived, so other answers stay locked.")
        XCTAssertFalse(detail.unlocksAfterDefinitiveFailure)
        XCTAssertNotNil(detail.submissionDisplay.retryAction(.answer), "The picked choice offers Retry.")

        fixture.live.selectAction(ExactText("b"), input: nil, for: fixture.key)
        XCTAssertEqual(try fixture.intents.map(\.operationID), [receipt.opID],
                       "Picking another choice cannot replace a lost send.")
        XCTAssertTrue(fixture.live.retrySubmissionFromUser(fixture.key))
        XCTAssertEqual(try fixture.intents.map(\.operationID), [receipt.opID],
                       "Retry resends the same operation.")
    }

    @MainActor
    func testAfterADefinitiveFailureAnotherChoiceSendsAsANewOperation() throws {
        let fixture = try liveFixture(payload: try choicePayload())
        let failed = try fixture.submit([.compatibilityValue(action: ExactText("a"))])
        try fixture.domain.recordAnswerNotDelivered(failed.intentID, operationID: failed.opID,
                                                    context: fixture.context)
        let detail = try fixture.refresh()
        XCTAssertEqual(detail.submissionPhase?.phase, .failed(retryable: true, editable: true))
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
        let failed = try fixture.submit([.compatibilityText(action: ExactText("reply"),
                                                            text: ExactText("Book the Avenida"))],
                                        persistDraft: false)
        try fixture.domain.recordAnswerNotDelivered(failed.intentID, operationID: failed.opID,
                                                    context: fixture.context)
        let detail = try fixture.refresh()
        XCTAssertTrue(detail.submissionDisplay.canEdit(.answer))
        XCTAssertTrue(fixture.live.releaseFailedSubmissionForEdit(fixture.key))
        XCTAssertTrue(try fixture.intents.isEmpty)
        XCTAssertEqual(fixture.live.draft(for: fixture.key)?.compatibility.textByActionID[ExactText("reply")],
                       ExactText("Book the Avenida"),
                       "A Reply box send keeps no draft, so Edit restores the sent text.")
    }

    @MainActor
    func testASentNoCommentKeepsItsRowWhileSendingAndAfterALostSend() throws {
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
        XCTAssertTrue(detail.showsNoCommentRow, "The No comment row carries its Retry.")
        XCTAssertNotNil(detail.submissionDisplay.retryAction(.noComment))
        XCTAssertTrue(fixture.live.retrySubmissionFromUser(fixture.key))
        XCTAssertEqual(try fixture.intents.map(\.operationID), [receipt.opID])
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

        XCTAssertTrue(fixture.live.releaseFailedSubmissionForEdit(fixture.key))
        let draft = try XCTUnwrap(fixture.live.draft(for: fixture.key))
        XCTAssertEqual(draft.inputs[ExactText("note")]?.text, ExactText("Check the partition."))
        XCTAssertEqual(draft.inputs[ExactText("location")]?.point, point)
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
