import Foundation
import AttentionDomain

/// The state of the most recent answer, No comment or Seen sent from one
/// message, for the control that sent it. A pure reading of the store's
/// saved operations and server receipts: it keeps no state of its own, writes
/// nothing, and has no timers.
struct SubmissionControlPhase: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case answer, noComment, seen }

    /// Why the server refused, where a person cannot already see it.
    enum RefusalReason: Equatable, Sendable { case changed, closed, retracted }

    enum Phase: Equatable, Sendable {
        /// Saved or in flight, with no server result yet.
        case sending
        /// The server accepted this operation.
        case confirmed
        /// It did not go through, or the outcome is unknown after a dropped
        /// connection. Retry resends the same operation when `retryable`.
        case failed(retryable: Bool)
        /// The server refused it for a reason a retry cannot fix.
        case refused(RefusalReason)
    }

    let kind: Kind
    let phase: Phase
    let operationID: UUID
    let since: Date

    static func project(snapshot: AttentionStoreSnapshot) -> [RequestKey: Self] {
        var result: [RequestKey: Self] = [:]
        for submission in snapshot.intents.values {
            let key = submission.requestKey
            let kind: Kind = if submission.isNoComment {
                .noComment
            } else if snapshot.requests[key]?.hasExplicitInformationalSeenAction == true {
                .seen
            } else {
                .answer
            }
            let closedOnServer = snapshot.remoteStates[key]?.isTerminal == true
            let phase: Phase = switch submission.disposition {
            case .pending: .sending
            case .accepted: .confirmed
            case .lost, .failed, .unsupported: .failed(retryable: !closedOnServer)
            case .repairRequired: .failed(retryable: false)
            case .staleRevision: .refused(.changed)
            case .refusedClosed, .refusedNotFound: .refused(.closed)
            case .refusedByRetraction: .refused(.retracted)
            case let .terminal(state, _, authorizedAnswer):
                if (state == .answered || state == .noComment), authorizedAnswer == submission.answer {
                    .confirmed
                } else {
                    .refused(.closed)
                }
            }
            let candidate = Self(kind: kind, phase: phase, operationID: submission.operationID,
                                 since: submission.submittedAt ?? .distantPast)
            if let previous = result[key] {
                // The most recent operation from this message wins; equal
                // times fall back to a stable order rather than dictionary order.
                guard candidate.since > previous.since ||
                        (candidate.since == previous.since &&
                         candidate.operationID.uuidString > previous.operationID.uuidString) else { continue }
            }
            result[key] = candidate
        }
        return result
    }
}
