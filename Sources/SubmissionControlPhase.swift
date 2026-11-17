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
        /// Saved or in flight: the
        /// server has not durably accepted it yet.
        case sending
        /// The server durably accepted it. A later refusal from the message's
        /// final state turns it into `refused`.
        case confirmed
        /// The store gave up on it. Retry resends the same operation when
        /// `retryable`. `editable` only where the server definitively did not
        /// take it, so a fresh operation cannot record a second answer.
        case failed(retryable: Bool, editable: Bool)
        /// The server refused it for a reason a retry cannot fix.
        case refused(RefusalReason)
    }

    let kind: Kind
    let phase: Phase
    let operationID: UUID
    let since: Date

    /// An operation answering an older version than the message's current
    /// one. The store keeps it as history; nothing recovers it.
    static func isRetiredByNewerVersion(_ submission: Submission, in snapshot: AttentionStoreSnapshot) -> Bool {
        guard let current = snapshot.conversationThreads[submission.requestKey]?.currentRevision else { return false }
        return (submission.requestRevision ?? 1) < current
    }

    static func project(snapshot: AttentionStoreSnapshot) -> [RequestKey: Self] {
        var result: [RequestKey: Self] = [:]
        func kind(of submission: Submission) -> Kind {
            if submission.isNoComment { return .noComment }
            if snapshot.requests[submission.requestKey]?.hasExplicitInformationalSeenAction == true { return .seen }
            return .answer
        }
        // Fixture builds keep their sends in fixture sessions rather than the
        // relay outbox; the same phases apply.
        for (key, session) in snapshot.fixtureSessions {
            switch session.lifecycle {
            case .open:
                continue
            case let .pending(submission):
                result[key] = Self(kind: kind(of: submission), phase: .sending,
                                   operationID: submission.operationID,
                                   since: submission.submittedAt ?? .distantPast)
            case let .terminal(terminal, submission):
                let ownAnswer = (terminal.state == .answered || terminal.state == .noComment) &&
                    terminal.ownOutcome == .accepted
                result[key] = Self(kind: kind(of: submission),
                                   phase: ownAnswer ? .confirmed : .refused(.closed),
                                   operationID: submission.operationID,
                                   since: submission.submittedAt ?? .distantPast)
            }
        }
        for submission in snapshot.intents.values {
            let key = submission.requestKey
            let closedOnServer = snapshot.remoteStates[key]?.isTerminal == true
            let phase: Phase = switch submission.disposition {
            case .pending: .sending
            // Durable acceptance is the server's confirmation. A final state
            // that is not an answer (expired, cleared, superseded) refuses it.
            case .accepted:
                if closedOnServer, let state = snapshot.remoteStates[key]?.state,
                   state != .answered, state != .noComment {
                    .refused(.closed)
                } else {
                    .confirmed
                }
            // A dropped connection leaves the outcome unknown. Show failure
            // with Retry of the same operation; editing could duplicate an answer.
            // A newer open version of the message retires an earlier answer
            // as lost too; that one is history, and the message changed.
            case .lost:
                if Self.isRetiredByNewerVersion(submission, in: snapshot) {
                    .refused(.changed)
                } else {
                    closedOnServer ? .refused(.closed) : .failed(retryable: true, editable: false)
                }
            case .failed, .unsupported: .failed(retryable: !closedOnServer, editable: !closedOnServer)
            case .repairRequired: .failed(retryable: false, editable: false)
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
            let candidate = Self(kind: kind(of: submission), phase: phase, operationID: submission.operationID,
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
    /// Turns a failed written reply back into a draft; the next send is a
    /// new operation.
    var edit: (() -> Void)? = nil

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
        guard phase?.kind == kind, case .failed(retryable: true, _) = phase?.phase else { return nil }
        return retry
    }

    /// Whether a failed send of this kind may become a draft again (Edit).
    func canEdit(_ kind: SubmissionControlPhase.Kind) -> Bool {
        guard edit != nil, phase?.kind == kind, case .failed(_, editable: true) = phase?.phase else { return false }
        return true
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

/// UI-test hook: `--harklight-test-submission-phase=<messageID>:<kind>:<phase>`,
/// repeatable, stands in for the store's projection on that message, so each state can be
/// captured on fixture builds. Kinds: answer, noComment, seen. Phases:
/// sending, confirmed, failed, refusedChanged. Debug builds only.
enum SubmissionPhaseTestHook {
    private static let testOperationID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    static func phase(for key: RequestKey) -> SubmissionControlPhase? {
        #if DEBUG
        let prefix = "--harklight-test-submission-phase="
        guard let parts = ProcessInfo.processInfo.arguments
            .filter({ $0.hasPrefix(prefix) })
            .map({ $0.dropFirst(prefix.count).split(separator: ":").map(String.init) })
            .first(where: { $0.count == 3 && $0[0] == key.messageID.rawValue }) else { return nil }
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
        default: phase = .failed(retryable: true, editable: true)
        }
        return SubmissionControlPhase(kind: kind, phase: phase, operationID: testOperationID, since: .distantPast)
        #else
        return nil
        #endif
    }
}
