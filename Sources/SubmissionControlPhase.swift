import Foundation
import AttentionDomain
import SwiftUI

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

/// What the submission controls in an open message show, read from
/// `SubmissionControlPhase`. The picked control carries the state itself.
struct SubmissionDisplay {
    var phase: SubmissionControlPhase?
    /// Resends the same operation; nil when this phase cannot be retried.
    var retry: (() -> Void)?

    var isSendingAny: Bool { phase?.phase == .sending }

    func isSending(_ kind: SubmissionControlPhase.Kind) -> Bool {
        phase?.kind == kind && phase?.phase == .sending
    }

    func isFailed(_ kind: SubmissionControlPhase.Kind) -> Bool {
        guard phase?.kind == kind, case .failed = phase?.phase else { return false }
        return true
    }

    /// The retry action for a failed control of this kind, when it can retry.
    func retryAction(_ kind: SubmissionControlPhase.Kind) -> (() -> Void)? {
        guard phase?.kind == kind, case .failed(retryable: true) = phase?.phase else { return nil }
        return retry
    }

    /// A one-line reason, only where the person can't already see it.
    var reasonLine: String? {
        if case .refused(.changed) = phase?.phase { return String(localized: "This message changed. Answer again.") }
        return nil
    }
}

extension EnvironmentValues {
    @Entry var harklightSubmissionDisplay = SubmissionDisplay()
}

/// UI-test hook: `--harklight-test-submission-phase=<messageID>:<kind>:<phase>`
/// stands in for the store's projection on one message, so each state can be
/// captured on fixture builds. Kinds: answer, noComment, seen. Phases:
/// sending, confirmed, failed, refusedChanged. Inactive in normal launches.
enum SubmissionPhaseTestHook {
    static func phase(for key: RequestKey) -> SubmissionControlPhase? {
        let prefix = "--harklight-test-submission-phase="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        let parts = argument.dropFirst(prefix.count).split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == key.messageID.rawValue else { return nil }
        let kind: SubmissionControlPhase.Kind
        switch parts[1] {
        case "noComment": kind = .noComment
        case "seen": kind = .seen
        default: kind = .answer
        }
        let phase: SubmissionControlPhase.Phase
        switch parts[2] {
        case "sending": phase = .sending
        case "confirmed": phase = .confirmed
        case "refusedChanged": phase = .refused(.changed)
        default: phase = .failed(retryable: true)
        }
        return SubmissionControlPhase(kind: kind, phase: phase, operationID: UUID(), since: .distantPast)
    }
}
