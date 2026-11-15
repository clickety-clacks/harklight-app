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
