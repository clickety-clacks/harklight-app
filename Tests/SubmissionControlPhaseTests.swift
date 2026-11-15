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
