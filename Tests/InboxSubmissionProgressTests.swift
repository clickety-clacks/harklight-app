import AttentionDomain
import Foundation
import Observation
import XCTest
@testable import Harklight

@MainActor
final class InboxSubmissionProgressTests: XCTestCase {
    private let key = RequestKey(accountScope: ExactText("account"), senderID: ExactText("sender"),
                                 messageID: ExactText("question"))
    private let sentAt = Date(timeIntervalSince1970: 100)
    private var binding: ConversationBinding { ConversationBinding(request: key, revision: 1) }

    func testSavedComposerIsAbsentAndUncertainSendRemainsAwaitingWithoutAClock() throws {
        var thread = makeThread()
        let operation = UUID()
        thread.drafts[1] = ConversationDraft(binding: binding, text: ExactText("Prompt"))
        XCTAssertNil(project(thread)[key])
        thread.drafts[1]?.disposition = .submitting(operation)
        thread.drafts[1]?.operationID = operation
        thread.drafts[1]?.submittedAt = sentAt
        XCTAssertEqual(project(thread)[key], .init(state: .awaiting, since: sentAt))
        thread.drafts[1]?.disposition = .outcomeUnknown(operation)
        thread.latestAvailabilityObservation = .init(state: .notListening(lastDetachedAt: nil))
        let restored = try JSONDecoder().decode(ConversationThread.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(project(restored)[key], .init(state: .awaiting, since: sentAt))
    }

    func testOwnReplayKeepsSendDateAndOnlyItsLinkedReplySettlesIt() throws {
        let operation = UUID()
        var state = ConversationState()
        try state.apply(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)))
        state.threads[key]?.drafts[1] = ConversationDraft(binding: binding, text: ExactText("Prompt"),
            disposition: .submitting(operation), operationID: operation, submittedAt: sentAt)
        let own = turn("own", author: .person, operation: operation)
        try state.apply(ConversationEvent(sequence: 2, binding: binding, fact: .turn(own)))
        var thread = try XCTUnwrap(state.threads[key])
        XCTAssertNil(thread.drafts[1])
        XCTAssertEqual(thread.facts[own.id]?.submittedAt, sentAt)
        XCTAssertEqual(project(thread)[key], .init(state: .awaiting, since: sentAt))
        thread.turns.append(turn("unrelated", author: .origin, replyTo: "another-prompt"))
        XCTAssertNotNil(project(thread)[key])
        thread.turns.append(turn("reply", author: .origin, replyTo: "own"))
        XCTAssertNil(project(thread)[key])
        let restored = try JSONDecoder().decode(ConversationThread.self, from: JSONEncoder().encode(thread))
        XCTAssertNil(project(restored)[key], "Restart cannot resurrect a settled spinner.")
    }

    func testFailureRetryAndEditKeepOnePromptWithStableOrdering() throws {
        var thread = makeThread()
        let operation = UUID()
        let bytes = Data("frozen frame".utf8)
        thread.drafts[1] = ConversationDraft(binding: binding, text: ExactText("Keep this"),
            disposition: .rejected(ExactText("temporarily unavailable")), operationID: operation,
            wireFrame: bytes, submittedAt: sentAt)
        XCTAssertEqual(project(thread)[key], .init(state: .notSent, since: sentAt))
        thread.drafts[1]?.disposition = .submitting(operation)
        XCTAssertEqual(project(thread)[key], .init(state: .awaiting, since: sentAt))
        XCTAssertEqual(thread.drafts[1]?.wireFrame, bytes)
        thread.drafts[1]?.disposition = .saved
        XCTAssertNil(project(thread)[key], "Edit returns the text to the composer, outside the reply area.")
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("Keep this"))
    }

    func testAnswerNeedsAgentResultNotMerelyAcceptanceOrReceivedAcknowledgement() {
        var thread = makeThread()
        thread.terminal = .answered
        thread.terminalTurn = ExactText("terminal")
        thread.turns = [ConversationTurn(id: ExactText("terminal"), binding: binding,
            author: .person, sessionHandle: ExactText("session"), text: ExactText("Answer"), kind: .terminal)]
        let accepted = submission(.accepted(sequence: 2))
        XCTAssertEqual(project(thread, submissions: [accepted])[key], .init(state: .awaiting, since: sentAt))
        thread.turns.append(ConversationTurn(id: ExactText("received"), binding: binding,
            author: .origin, sessionHandle: ExactText("session"), text: ExactText(""),
            inReplyTo: ExactText("terminal"), kind: .result, resultStatus: ExactText("received")))
        XCTAssertNotNil(project(thread, submissions: [accepted])[key])
        thread.turns.append(ConversationTurn(id: ExactText("applied"), binding: binding,
            author: .origin, sessionHandle: ExactText("session"), text: ExactText("Done"),
            inReplyTo: ExactText("terminal"), kind: .result, resultStatus: ExactText("applied")))
        XCTAssertNil(project(thread, submissions: [accepted])[key])
        XCTAssertNil(project(thread, submissions: [submission(.terminal(state: .answered,
            sequence: 2, authorizedAnswer: nil))])[key],
            "An authoritative linked result settles the row even while the original receipt is uncertain.")
    }

    func testDefinitiveAnswerRefusalsStopSpinnerButLostOutcomeDoesNot() {
        let refusals: [IntentDisposition] = [.failed, .refusedClosed, .refusedNotFound,
                                             .staleRevision(currentRevision: 2), .unsupported]
        for disposition in refusals {
            XCTAssertEqual(project(makeThread(), submissions: [submission(disposition)])[key]?.state, .notSent)
        }
        XCTAssertEqual(project(makeThread(), submissions: [submission(.lost)])[key]?.state, .awaiting)
        XCTAssertEqual(project(makeThread(), submissions: [submission(.terminal(state: .answered,
            sequence: 2, authorizedAnswer: nil))])[key]?.state, .awaiting,
            "An account terminal is not a definitive refusal of this original operation.")
    }

    func testNewPendingPromptSurvivesReplyToAnOlderPrompt() {
        var thread = makeThread()
        let old = turn("old", author: .person, operation: UUID())
        thread.turns = [old, turn("old-reply", author: .origin, replyTo: "old")]
        thread.facts[old.id] = ConversationTurnFacts(acceptedAtMilliseconds: 1_000)
        let operation = UUID()
        thread.drafts[1] = ConversationDraft(binding: binding, text: ExactText("New prompt"),
            disposition: .submitting(operation), operationID: operation, submittedAt: sentAt)
        XCTAssertEqual(project(thread)[key], .init(state: .awaiting, since: sentAt))
    }

    func testDurablePreparationPublishesImmediatelyToTheExistingModel() throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: key.accountScope, deviceID: ExactText("device")), transportMode: .relay)
        let persistence = MemoryPendingActionPersistence()
        let repository = try ClientRepository(context: context, persistence: persistence)
        _ = try repository.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: .null), .message)), context: context)
        try repository.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        let model = try LivePresentationStore(store: repository, context: context)
        XCTAssertNil(model.submissionProgress[key])
        try repository.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Prompt")),
                                             context: context)
        let operation = try repository.prepareDiscussion(binding, context: context)
        let draft = try XCTUnwrap(repository.conversationSnapshot(context: context).threads[key]?.drafts[1])
        let date = try XCTUnwrap(draft.submittedAt)
        let observed = ChangeFlag()
        withObservationTracking { _ = model.submissionProgress } onChange: { observed.mark() }
        try model.refreshFromDurableStore()
        XCTAssertTrue(observed.value)
        XCTAssertEqual(model.submissionProgress[key], .init(state: .awaiting, since: date))
        XCTAssertEqual(try repository.prepareDiscussion(binding, context: context), operation)
        XCTAssertEqual(try repository.conversationSnapshot(context: context).threads[key]?.drafts[1]?.submittedAt, date)
        let cache = try repository.serverCacheSnapshot(context: context)
        let conversations = try repository.conversationSnapshot(context: context)
        let restored = try ClientRepository(context: context, persistence: persistence)
        try restored.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: cache.requests, remoteStates: cache.remoteStates, cursor: cache.cursor,
            conversationCursor: conversations.cursor, conversations: conversations.threads,
            inboxView: nil, currentRequestKeys: [key]), context: context)
        XCTAssertEqual(try restored.conversationSnapshot(context: context).threads[key]?.drafts[1]?.submittedAt, date)
    }

    func testLegacyDatesDecodeWithoutInventingANewSendTime() throws {
        var original = submission(.pending)
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "submittedAt")
        original = try JSONDecoder().decode(Submission.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(original.submittedAt)
        XCTAssertEqual(project(makeThread(), submissions: [original])[key]?.since,
                       InboxSubmissionProgress.unknownSubmissionDate)
    }

    private func makeThread() -> ConversationThread {
        ConversationThread(request: key, sessionHandle: ExactText("session"), revision: 1, payload: .null)
    }

    private func turn(_ id: String, author: ConversationAuthor, operation: UUID? = nil,
                      replyTo: String? = nil) -> ConversationTurn {
        ConversationTurn(id: ExactText(id), binding: binding, author: author,
            sessionHandle: ExactText("session"), text: ExactText(id),
            inReplyTo: replyTo.map(ExactText.init), operationID: operation,
            kind: author == .person ? .discussion : .reply)
    }

    private func submission(_ disposition: IntentDisposition) -> Submission {
        Submission(requestKey: key, answer: .string(ExactText("Answer")), intentID: UUID(), operationID: UUID(),
            operation: .null, descriptorFingerprint: "", contentFingerprint: "", disposition: disposition,
            requestRevision: 1, submittedAt: sentAt)
    }

    private func project(_ thread: ConversationThread, submissions: [Submission] = []) -> [RequestKey: InboxSubmissionProgress] {
        let snapshot = AttentionStoreSnapshot(requests: [key: StoredRequest(key: key, originalPayload: .null)],
            drafts: [:], intents: Dictionary(uniqueKeysWithValues: submissions.map { ($0.intentID, $0) }),
            outbox: [], remoteStates: [:], fixtureSessions: [:], revision: 1, cursor: 0,
            replayBarrier: nil, repairIssues: [])
        return InboxSubmissionProgress.project(snapshot: snapshot, threads: [key: thread])
    }
}

private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    var value: Bool { lock.withLock { changed } }
    func mark() { lock.withLock { changed = true } }
}
