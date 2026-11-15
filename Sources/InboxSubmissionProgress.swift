import Foundation
import AttentionDomain

/// A presentation of existing durable sends, not another queue or reply event.
struct InboxSubmissionProgress: Equatable, Sendable {
    enum State: Equatable, Sendable { case awaiting, notSent }
    let state: State
    let since: Date
    let detail: String?

    init(state: State, since: Date, detail: String? = nil) {
        self.state = state
        self.since = since
        self.detail = detail
    }

    /// Old records have no local send date. Keep their ordering stable rather
    /// than making them look newly submitted whenever the view is refreshed.
    static let unknownSubmissionDate = Date.distantPast

    static func project(snapshot: AttentionStoreSnapshot,
                        threads: [RequestKey: ConversationThread]) -> [RequestKey: Self] {
        var result: [RequestKey: Self] = [:]
        func include(_ key: RequestKey, state: State, date: Date?, detail: String? = nil) {
            let candidate = Self(state: state, since: date ?? unknownSubmissionDate, detail: detail)
            if let previous = result[key] {
                guard candidate.since > previous.since ||
                        (candidate.since == previous.since && candidate.state == .notSent) else { return }
            }
            result[key] = candidate
        }

        // Index response references once per thread, rather than repeatedly
        // walking every turn for each row or each pending operation.
        var replies: [RequestKey: Set<ExactText>] = [:]
        for (key, thread) in threads {
            replies[key] = Set(thread.turns.compactMap { turn in
                guard turn.author == .origin || turn.author == .agent,
                      turn.kind == .reply || turn.kind == nil else { return nil }
                return turn.inReplyTo
            })
            let replyTargets = replies[key] ?? []
            let ownTurns = thread.turns.filter {
                $0.author == .person && ($0.kind == .discussion || $0.kind == nil)
            }
            let replayedOperations = Set(ownTurns.compactMap(\.operationID))
            for turn in ownTurns where !replyTargets.contains(turn.id) {
                let facts = thread.facts[turn.id] ?? ConversationTurnFacts()
                // History from other devices is not a newly queued local send.
                // Existing accepted-at metadata also supports older local sends.
                guard facts.submittedAt != nil || facts.acceptedAtMilliseconds != nil else { continue }
                let delivery = ConversationSentChatStatusPresentation.delivery(for: turn, facts: facts,
                    availability: thread.latestReportedAvailabilityObservation, hasReply: false,
                    conversationAgentName: "", nowMilliseconds: 0)
                let state: State
                switch delivery {
                case .noOneWillGetThis, .notDelivered: state = .notSent
                default: state = .awaiting
                }
                include(key, state: state, date: facts.submittedAt ?? facts.acceptedAtMilliseconds.map {
                    Date(timeIntervalSince1970: Double($0) / 1_000)
                })
            }
            for draft in thread.drafts.values {
                if let operation = draft.operationID, replayedOperations.contains(operation) { continue }
                let state: State
                switch draft.disposition {
                case .saved: continue // Unsent editor text is not a prompt.
                case .submitting, .outcomeUnknown: state = .awaiting
                case let .acceptedPendingReplay(_, turn):
                    if replyTargets.contains(turn) { continue }
                    state = .awaiting
                case .rejected:
                    guard draft.operationID != nil || draft.submittedAt != nil else { continue }
                    state = .notSent
                }
                include(key, state: state, date: draft.submittedAt)
            }
        }

        for submission in snapshot.intents.values {
            let key = submission.requestKey
            // Seen and No comment acknowledge a message rather than submit a
            // prompt for an agent response. Their existing receipt UI remains.
            guard !submission.isNoComment,
                  snapshot.requests[key]?.hasExplicitInformationalSeenAction != true else { continue }
            let state: State
            switch submission.disposition {
            case .pending:
                state = .awaiting
            case .lost:
                // Still on its way, matching the control: a dropped connection
                // leaves the same operation recovering. Not sent is only for a
                // send the store gave up on.
                guard snapshot.remoteStates[key]?.isTerminal != true else { continue }
                state = .awaiting
            case .accepted:
                // Durable acceptance is the server's confirmation; answers do
                // not wait for an origin reply or the message's final state.
                continue
            case .terminal, .refusedClosed, .refusedNotFound, .staleRevision, .refusedByRetraction:
                // Not a Retry case: the message's own closed, retracted or
                // current state shows instead of a not-sent mark.
                continue
            case .failed, .unsupported, .repairRequired:
                // Retry is the indicator; no reason line for a plain failure.
                state = .notSent
            }
            let detail: String? = nil
            include(key, state: state, date: submission.submittedAt, detail: detail)
        }
        return result
    }
}
