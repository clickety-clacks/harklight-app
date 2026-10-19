import AttentionDomain
import CryptoKit
import Foundation
import HarklightNativeRelay
import Security
import Observation

struct NativeRelayRefreshResult: Equatable, Sendable {
    enum PushRegistration: Equatable, Sendable {
        case notAttempted
        case confirmed
        case unconfirmed
    }

    let relayConfirmed: Bool
    let pushRegistration: PushRegistration
    // Confirmation belongs to the refresh that produced this result. A queued
    // refresh can start before its predecessor's foreground waiter resumes.
    let confirmedContext: ProfileContext?
    let confirmedTransportAttemptID: UUID?
    static let unavailable = Self(relayConfirmed: false, pushRegistration: .notAttempted,
                                  confirmedContext: nil, confirmedTransportAttemptID: nil)

    func confirms(_ expected: ProfileContext, transportAttemptID: UUID?) -> Bool {
        guard let transportAttemptID else { return false }
        return relayConfirmed && confirmedContext == expected &&
            confirmedTransportAttemptID == transportAttemptID
    }

    // No pending registration is not proof of notification permission/delivery.
    var completedWithoutError: Bool { relayConfirmed && pushRegistration != .unconfirmed }

    @MainActor
    static func afterConfirmedRelay(
        context: ProfileContext? = nil,
        transportAttemptID: UUID? = nil,
        onFailure: @MainActor (Error) -> Void = { _ in },
        _ registration: @MainActor () async throws -> PushRegistration
    ) async -> Self {
        do {
            return Self(relayConfirmed: true, pushRegistration: try await registration(),
                        confirmedContext: context, confirmedTransportAttemptID: transportAttemptID)
        }
        catch {
            onFailure(error)
            return Self(relayConfirmed: true, pushRegistration: .unconfirmed,
                        confirmedContext: context, confirmedTransportAttemptID: transportAttemptID)
        }
    }
}

struct NativeForegroundConnectProgress: Equatable, Sendable {
    enum Validation: String, Equatable, Sendable {
        case notChecked = "not_checked"
        case passed
        case failed
    }

    enum PostAckBoundary: String, Equatable, Sendable {
        case none = "none_observed"
        case nativeCursorAcknowledged = "native_sync_acknowledged"
        case coreDrainCompleted = "post_ack_core_drain_completed"
        case relayRefreshReturned = "post_ack_relay_refresh_returned"
        case foregroundConfirmed = "foreground_confirmed"

        var journalValue: NativeDiagnosticPostAckBoundary {
            switch self {
            case .none: .none
            case .nativeCursorAcknowledged: .nativeCursorAcknowledged
            case .coreDrainCompleted: .coreDrainCompleted
            case .relayRefreshReturned: .relayRefreshReturned
            case .foregroundConfirmed: .foregroundConfirmed
            }
        }

        fileprivate var rank: Int {
            switch self {
            case .none: 0
            case .nativeCursorAcknowledged: 1
            case .coreDrainCompleted: 2
            case .relayRefreshReturned: 3
            case .foregroundConfirmed: 4
            }
        }
    }

    enum TerminalReason: String, Equatable, Sendable {
        case confirmed = "foreground_confirmed"
        case connectionNotConfirmed = "connection_not_confirmed"
        case deadlineExceeded = "foreground_deadline"
        case cancelled
        case generationInvalidated = "generation_invalidated"
        case profileContextChanged = "profile_context_changed"
        case relayContextUnconfirmed = "relay_context_unconfirmed"

        var journalValue: NativeDiagnosticTerminalReason {
            switch self {
            case .confirmed: .confirmed
            case .connectionNotConfirmed: .connectionNotConfirmed
            case .deadlineExceeded: .deadlineExceeded
            case .cancelled: .cancelled
            case .generationInvalidated: .generationInvalidated
            case .profileContextChanged: .profileContextChanged
            case .relayContextUnconfirmed: .relayContextUnconfirmed
            }
        }
    }

    enum Stage: Equatable, Sendable {
        case serverTrustValidated
        case clientIdentityOffered
        case webSocketOpened
        case relayAdmitted
        case nativeSyncResynced
        case nativeSyncAcknowledged
        case foregroundConfirmed

        var label: String {
            switch self {
            case .serverTrustValidated: "The server certificate passed the saved host and CA check."
            case .clientIdentityOffered: "The saved device certificate was selected for the challenge; server acceptance is not known yet."
            case .webSocketOpened: "The WebSocket open event was received."
            case .relayAdmitted: "The relay accepted the native sync request."
            case .nativeSyncResynced: "The replay reached its resynced marker and was saved locally."
            case .nativeSyncAcknowledged: "The relay acknowledged the saved native sync cursor."
            case .foregroundConfirmed: "Foreground connection is confirmed."
            }
        }

        var rank: Int {
            switch self {
            case .serverTrustValidated: 1
            case .clientIdentityOffered: 2
            case .webSocketOpened: 3
            case .relayAdmitted: 4
            case .nativeSyncResynced: 5
            case .nativeSyncAcknowledged: 6
            case .foregroundConfirmed: 7
            }
        }
    }

    enum Issue: Equatable, Sendable {
        case serverTrustRejected
        case clientIdentityChallengeRejected

        var message: String {
            switch self {
            case .serverTrustRejected:
                "The server certificate did not pass the saved host and CA check."
            case .clientIdentityChallengeRejected:
                "The client could not offer its identity to the saved relay host."
            }
        }
    }

    enum Outcome: Equatable, Sendable { case connecting, incomplete, timedOut, confirmed }

    struct PreviousTransportAttempt: Equatable, Sendable {
        let id: UUID
        let lastConfirmedStage: Stage?
        let webSocketOpenObserved: Bool
        let nativeSyncReplayRequested: Bool
        let issue: Issue?
        let failureClass: FailureClass?
        let lastCompletedPostAckBoundary: PostAckBoundary
        let postAckRelayRefresh: Validation
        let postAckDrainTransition: NativeDiagnosticTransition?
        let generationValidation: Validation
        let profileContextValidation: Validation
        let relayContextValidation: Validation
        let terminalReason: TerminalReason?
    }

    enum FailureClass: Equatable, Sendable {
        case foregroundDeadline
        case cancelled
        case serverTrustRejected
        case clientIdentityChallengeRejected
        case urlSession(code: Int)
        case relayProtocol
        case nativeSync
        case unknown

        var diagnosticValue: String {
            switch self {
            case .foregroundDeadline: "foreground_deadline"
            case .cancelled: "cancelled"
            case .serverTrustRejected: "server_trust_rejected"
            case .clientIdentityChallengeRejected: "client_identity_challenge_rejected"
            case let .urlSession(code): "url_session_error_code_\(code)"
            case .relayProtocol: "relay_protocol_error"
            case .nativeSync: "native_sync_error"
            case .unknown: "unknown_error_class"
            }
        }

        static func classify(_ error: Error) -> Self {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
            let value = error as NSError
            if value.domain == NSURLErrorDomain { return .urlSession(code: value.code) }
            if error is InstallationTransportError { return .relayProtocol }
            if error is NativeRelayCoreError { return .nativeSync }
            return .unknown
        }
    }

    var lastConfirmedStage: Stage?
    var webSocketOpenObserved: Bool
    var issue: Issue?
    var outcome: Outcome
    var attemptID: UUID? = nil
    var failureClass: FailureClass? = nil
    var transportAttemptID: UUID? = nil
    var nativeSyncReplayRequested = false
    var previousTransportAttempt: PreviousTransportAttempt? = nil
    var lastCompletedPostAckBoundary: PostAckBoundary = .none
    var postAckRelayRefresh: Validation = .notChecked
    var postAckDrainTransition: NativeDiagnosticTransition? = nil
    var generationValidation: Validation = .notChecked
    var profileContextValidation: Validation = .notChecked
    var relayContextValidation: Validation = .notChecked
    var terminalReason: TerminalReason? = nil

    private var observedCauseText: String {
        failureClass.map { "Observed error class: \($0.diagnosticValue). " } ?? "Cause was not observed. "
    }

    mutating func markGenerationInvalidated() {
        outcome = .incomplete
        generationValidation = .failed
        terminalReason = .generationInvalidated
    }

    var headline: String {
        guard outcome != .confirmed else { return "Connected" }
        switch lastConfirmedStage {
        case .nativeSyncAcknowledged:
            return outcome == .connecting
                ? "Earlier messages synced; finishing connection"
                : "Earlier messages synced; connection not confirmed"
        case .nativeSyncResynced:
            return "Messages saved; relay acknowledgement not confirmed"
        default:
            return "Connection not confirmed"
        }
    }

    var message: String {
        let last = lastConfirmedStage?.label ?? "No connection milestone was confirmed."
        if lastConfirmedStage == .nativeSyncAcknowledged, outcome != .confirmed {
            let status = "At the last confirmed checkpoint, ordinary messages through that replay's cursor were durably applied and the relay acknowledged that cursor. The progress signal does not establish whether a later replay advanced the saved cursor or whether that later cursor was acknowledged. Full foreground completion remains unconfirmed. This does not establish pending-answer delivery, later conversation replay, upload cleanup, or notification registration. The current progress signal cannot identify the exact post-ACK step; Settings diagnostics retains operation-receipt states."
            switch outcome {
            case .connecting:
                return "\(status) The foreground attempt is still running."
            case .incomplete:
                return "Foreground sync remains incomplete. \(status)\(observedCauseText)Retry with the same approved identity."
            case .timedOut:
                return "Foreground attempt timed out after the ordinary cursor ACK. \(status)\(observedCauseText)Saved state is preserved. Retry with the same approved identity."
            case .confirmed:
                break
            }
        }
        if lastConfirmedStage == .nativeSyncResynced, outcome != .confirmed {
            let status = "Ordinary messages through the replay high-water were durably saved locally, but relay acknowledgement of that cursor is not confirmed. Pending-answer delivery and overall foreground completion are not established."
            switch outcome {
            case .connecting:
                return "\(status) The foreground attempt is still running."
            case .incomplete:
                return "Foreground sync remains incomplete. \(status)\(observedCauseText)Retry with the same approved identity."
            case .timedOut:
                return "Foreground attempt timed out before cursor acknowledgement. \(status)\(observedCauseText)Saved state is preserved. Retry with the same approved identity."
            case .confirmed:
                break
            }
        }
        switch outcome {
        case .connecting:
            return issue?.message ?? last
        case .incomplete:
            let issueText = issue.map { "\($0.message) " } ?? ""
            return "The connection was not confirmed. \(issueText)\(observedCauseText)Last confirmed step: \(last) Try again with the same approved identity."
        case .timedOut:
            let setupLimit = !webSocketOpenObserved && issue == nil
                ? "No WebSocket-open event arrived. Secure relay setup did not complete; this client cannot distinguish a TLS failure from a WebSocket-upgrade timeout. "
                : ""
            let issueText = issue.map { "\($0.message) " } ?? ""
            return "The connection timed out. \(issueText)\(setupLimit)\(observedCauseText)Last confirmed step: \(last) Try again with the same approved identity. Saved profile, local content and pending operation state were preserved; any replay already saved remains saved."
        case .confirmed:
            return lastConfirmedStage?.label ?? "Foreground connection is confirmed."
        }
    }
}

struct NativeForegroundOperationDiagnostic: Equatable, Sendable {
    let operationID: UUID
    let senderID: String
    let messageID: String
    let requestRevision: UInt64?
    let receiptState: String

    init(submission: Submission, receiptState: String) {
        operationID = submission.operationID
        senderID = submission.requestKey.senderID.rawValue
        messageID = submission.requestKey.messageID.rawValue
        requestRevision = submission.requestRevision
        self.receiptState = receiptState
    }

    init(operationID: UUID, senderID: String, messageID: String,
         requestRevision: UInt64?, receiptState: String) {
        self.operationID = operationID
        self.senderID = senderID
        self.messageID = messageID
        self.requestRevision = requestRevision
        self.receiptState = receiptState
    }
}

struct NativeForegroundOperationSnapshot: Equatable, Sendable {
    let available: Bool
    let operations: [NativeForegroundOperationDiagnostic]

    static let unavailable = Self(available: false, operations: [])
}

/// Explicitly shareable, allowlisted diagnostics for the current foreground
/// attempt. It never serializes answers, request payloads, URLs, credentials,
/// tokens, or keychain material.
struct NativeForegroundConnectDiagnostic: Equatable, Sendable {
    let appVersion: String
    let buildNumber: String
    let executableSHA256: String
    let progress: NativeForegroundConnectProgress
    let operationSnapshot: NativeForegroundOperationSnapshot

    private static let mainExecutableSHA256 = executableSHA256(for: Bundle.main.executableURL)

    init(progress: NativeForegroundConnectProgress,
         operationSnapshot: NativeForegroundOperationSnapshot,
         appVersion: String,
         buildNumber: String,
         executableSHA256: String = "unavailable") {
        self.progress = progress
        self.operationSnapshot = operationSnapshot
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.executableSHA256 = executableSHA256
    }

    init(progress: NativeForegroundConnectProgress,
         operationSnapshot: NativeForegroundOperationSnapshot,
         bundle: Bundle = .main) {
        let executableSHA256 = bundle.bundleURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            ? Self.mainExecutableSHA256
            : Self.executableSHA256(for: bundle.executableURL)
        self.init(progress: progress,
                  operationSnapshot: operationSnapshot,
                  appVersion: Self.bundleValue("CFBundleShortVersionString", bundle: bundle),
                  buildNumber: Self.bundleValue("CFBundleVersion", bundle: bundle),
                  executableSHA256: executableSHA256)
    }

    var shareText: String {
        let stage = progress.lastConfirmedStage?.diagnosticValue ?? "none_confirmed"
        let outcome: String
        switch progress.outcome {
        case .connecting: outcome = "connecting"
        case .incomplete: outcome = "incomplete"
        case .timedOut: outcome = "timed_out"
        case .confirmed: outcome = "confirmed"
        }
        let issue: String
        switch progress.issue {
        case .serverTrustRejected: issue = "server_trust_rejected"
        case .clientIdentityChallengeRejected: issue = "client_identity_challenge_rejected"
        case nil: issue = "none_observed"
        }
        let terminal = progress.terminalReason?.rawValue ?? "none_observed"
        let failure = progress.failureClass?.diagnosticValue ?? {
            switch progress.outcome {
            case .incomplete, .timedOut: "unknown_error_class"
            case .connecting, .confirmed: "none_observed"
            }
        }()
        let websocket = progress.webSocketOpenObserved ? "yes" : "no"
        var lines = [
            "Harklight connection diagnostics",
            "app_version=\(appVersion)",
            "app_build=\(buildNumber)",
            "app_executable_sha256=\(executableSHA256)",
            "attempt_id=\(progress.attemptID?.uuidString.lowercased() ?? "unavailable")",
            "outcome=\(outcome)",
            "last_confirmed_phase=\(stage)",
            "last_completed_post_ack_boundary=\(progress.lastCompletedPostAckBoundary.rawValue)",
            "post_ack_relay_refresh=\(progress.postAckRelayRefresh.rawValue)",
            "post_ack_drain=\(progress.postAckDrainTransition?.rawValue ?? "not_started")",
            "generation_validated=\(progress.generationValidation.rawValue)",
            "profile_context_validated=\(progress.profileContextValidation.rawValue)",
            "relay_context_validated=\(progress.relayContextValidation.rawValue)",
            "terminal_reason=\(terminal)",
            "transport_attempt_id=\(progress.transportAttemptID?.uuidString.lowercased() ?? "unavailable")",
            "native_sync_replay_requested_locally=\(progress.nativeSyncReplayRequested ? "yes" : "no")",
            "websocket_open_observed=\(websocket)",
            "issue=\(issue)",
            "error_class=\(failure)"
        ]
        if let previous = progress.previousTransportAttempt {
            lines.append("previous_transport_attempt_id=\(previous.id.uuidString.lowercased())")
            lines.append("previous_last_confirmed_phase=\(previous.lastConfirmedStage?.diagnosticValue ?? "none_confirmed")")
            lines.append("previous_websocket_open_observed=\(previous.webSocketOpenObserved ? "yes" : "no")")
            lines.append("previous_native_sync_replay_requested_locally=\(previous.nativeSyncReplayRequested ? "yes" : "no")")
            lines.append("previous_issue=\(Self.issueValue(previous.issue))")
            lines.append("previous_error_class=\(previous.failureClass?.diagnosticValue ?? "none_observed")")
            lines.append("previous_last_completed_post_ack_boundary=\(previous.lastCompletedPostAckBoundary.rawValue)")
            lines.append("previous_post_ack_relay_refresh=\(previous.postAckRelayRefresh.rawValue)")
            lines.append("previous_post_ack_drain=\(previous.postAckDrainTransition?.rawValue ?? "not_started")")
            lines.append("previous_generation_validated=\(previous.generationValidation.rawValue)")
            lines.append("previous_profile_context_validated=\(previous.profileContextValidation.rawValue)")
            lines.append("previous_relay_context_validated=\(previous.relayContextValidation.rawValue)")
            lines.append("previous_terminal_reason=\(previous.terminalReason?.rawValue ?? "none_observed")")
        }
        guard operationSnapshot.available else {
            lines.append("queued_operation_state=unavailable; outcome remains unknown")
            return lines.joined(separator: "\n")
        }
        guard !operationSnapshot.operations.isEmpty else {
            lines.append("unresolved_original_operation_state=none_at_attempt_start")
            return lines.joined(separator: "\n")
        }
        lines.append("unresolved_original_operation_count=\(operationSnapshot.operations.count)")
        for operation in operationSnapshot.operations {
            let sender = Self.escapedIdentifier(operation.senderID)
            let message = Self.escapedIdentifier(operation.messageID)
            let revision = operation.requestRevision.map { String($0) } ?? "unknown"
            lines.append("operation_id=\(operation.operationID.uuidString.lowercased()) sender_id=\(sender) message_id=\(message) request_revision=\(revision) receipt_state=\(operation.receiptState)")
        }
        return lines.joined(separator: "\n")
    }

    private static func bundleValue(_ key: String, bundle: Bundle) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "unavailable" }
        return value
    }

    private static func escapedIdentifier(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "unavailable"
    }

    private static func issueValue(_ issue: NativeForegroundConnectProgress.Issue?) -> String {
        switch issue {
        case .serverTrustRejected: "server_trust_rejected"
        case .clientIdentityChallengeRejected: "client_identity_challenge_rejected"
        case nil: "none_observed"
        }
    }

    static func executableSHA256(for url: URL?) -> String {
        guard let url, let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "unavailable" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

private extension NativeForegroundConnectProgress.Stage {
    var diagnosticValue: String {
        switch self {
        case .serverTrustValidated: "server_trust_validated"
        case .clientIdentityOffered: "client_identity_offered"
        case .webSocketOpened: "websocket_opened"
        case .relayAdmitted: "relay_admitted"
        case .nativeSyncResynced: "native_sync_resynced"
        case .nativeSyncAcknowledged: "native_sync_acknowledged"
        case .foregroundConfirmed: "foreground_confirmed"
        }
    }
}

/// Races one saved-identity foreground connect against a single deadline.
/// Completing after timeout is ignored; the supplied timeout closure closes
/// only the session generation that began this attempt.
@MainActor
final class ForegroundConnectDeadline {
    private struct Attempt {
        let id: UUID
        let continuation: CheckedContinuation<NativeForegroundConnectProgress, Never>
        let onProgress: @MainActor (NativeForegroundConnectProgress) -> Void
        let onTimeout: @MainActor () async -> Void
        var progress: NativeForegroundConnectProgress
    }

    private var attempt: Attempt?
    private var timeoutTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var acceptsEvents = false
    private var activeTransportAttemptID: UUID?
    private(set) var progress = NativeForegroundConnectProgress(lastConfirmedStage: nil,
                                                                 webSocketOpenObserved: false,
                                                                 issue: nil, outcome: .incomplete)

    func beginSession(transportAttemptID: UUID) {
        guard attempt == nil else { return }
        progress = NativeForegroundConnectProgress(lastConfirmedStage: nil, webSocketOpenObserved: false,
                                                   issue: nil, outcome: .connecting,
                                                   transportAttemptID: transportAttemptID)
        activeTransportAttemptID = transportAttemptID
        acceptsEvents = true
    }

    /// A replacement transport gets a fresh phase boundary while retaining
    /// one bounded summary of the transport it replaced.
    func beginTransportAttempt(_ transportAttemptID: UUID) {
        guard acceptsEvents, activeTransportAttemptID != transportAttemptID else { return }
        if let priorID = activeTransportAttemptID {
            progress.previousTransportAttempt = NativeForegroundConnectProgress.PreviousTransportAttempt(
                id: priorID,
                lastConfirmedStage: progress.lastConfirmedStage,
                webSocketOpenObserved: progress.webSocketOpenObserved,
                nativeSyncReplayRequested: progress.nativeSyncReplayRequested,
                issue: progress.issue,
                failureClass: progress.failureClass,
                lastCompletedPostAckBoundary: progress.lastCompletedPostAckBoundary,
                postAckRelayRefresh: progress.postAckRelayRefresh,
                postAckDrainTransition: progress.postAckDrainTransition,
                generationValidation: progress.generationValidation,
                profileContextValidation: progress.profileContextValidation,
                relayContextValidation: progress.relayContextValidation,
                terminalReason: progress.terminalReason)
        }
        activeTransportAttemptID = transportAttemptID
        progress.transportAttemptID = transportAttemptID
        progress.lastConfirmedStage = nil
        progress.webSocketOpenObserved = false
        progress.nativeSyncReplayRequested = false
        progress.issue = nil
        progress.failureClass = nil
        progress.outcome = .connecting
        progress.lastCompletedPostAckBoundary = .none
        progress.postAckRelayRefresh = .notChecked
        progress.postAckDrainTransition = nil
        progress.generationValidation = .notChecked
        progress.profileContextValidation = .notChecked
        progress.relayContextValidation = .notChecked
        progress.terminalReason = nil
        publishProgress()
    }

    func observe(_ event: NativeRelayProgressEvent, transportAttemptID: UUID) {
        guard acceptsEvents, activeTransportAttemptID == transportAttemptID else { return }
        let candidate: NativeForegroundConnectProgress.Stage?
        let issue: NativeForegroundConnectProgress.Issue?
        switch event {
        case .serverTrustValidated:
            candidate = .serverTrustValidated; issue = nil
        case .serverTrustRejected:
            candidate = nil; issue = .serverTrustRejected
            progress.failureClass = .serverTrustRejected
        case .clientIdentityOffered:
            candidate = .clientIdentityOffered; issue = nil
        case .clientIdentityChallengeRejected:
            candidate = nil; issue = .clientIdentityChallengeRejected
            progress.failureClass = .clientIdentityChallengeRejected
        case .webSocketOpened:
            candidate = .webSocketOpened; issue = nil
            progress.webSocketOpenObserved = true
        case .relayAdmitted:
            candidate = .relayAdmitted; issue = nil
        case .nativeSyncReplayRequested:
            candidate = nil; issue = nil
            progress.nativeSyncReplayRequested = true
        case .nativeSyncResynced:
            candidate = .nativeSyncResynced; issue = nil
        case .nativeSyncAcknowledged:
            candidate = .nativeSyncAcknowledged; issue = nil
            advancePostAckBoundary(.nativeCursorAcknowledged)
        case .postAckDrainBegan:
            candidate = nil; issue = nil
            progress.postAckDrainTransition = .began
        case let .postAckDrainFinished(transition):
            candidate = nil; issue = nil
            progress.postAckDrainTransition = transition
            if transition == .completed { advancePostAckBoundary(.coreDrainCompleted) }
        }
        if let candidate,
           progress.lastConfirmedStage.map({ candidate.rank >= $0.rank }) ?? true {
            progress.lastConfirmedStage = candidate
        }
        progress.issue = issue
        progress.outcome = .connecting
        publishProgress()
    }

    func run(deadline: Duration,
             operation: @escaping @MainActor () async -> Bool,
             onTimeout: @escaping @MainActor () async -> Void,
             onBegin: @escaping @MainActor (UUID) -> Void = { _ in },
             onProgress: @escaping @MainActor (NativeForegroundConnectProgress) -> Void) async -> NativeForegroundConnectProgress {
        guard attempt == nil else { return progress }
        let id = UUID()
        progress.attemptID = id
        progress.failureClass = nil
        return await withCheckedContinuation { continuation in
            progress.outcome = .connecting
            attempt = Attempt(id: id, continuation: continuation, onProgress: onProgress,
                             onTimeout: onTimeout, progress: progress)
            onBegin(id)
            onProgress(progress)
            timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: deadline) } catch { return }
                await self?.expire(id)
            }
            operationTask = Task { @MainActor [weak self] in
                let connected = await operation()
                self?.finish(id, connected: connected)
            }
        }
    }

    func finishWithoutAttempt(confirmed: Bool) -> NativeForegroundConnectProgress {
        finishWithoutAttempt(confirmed: confirmed,
                             terminalReason: confirmed ? .confirmed : .connectionNotConfirmed)
    }

    func finishWithoutAttempt(confirmed: Bool,
                              terminalReason: NativeForegroundConnectProgress.TerminalReason) -> NativeForegroundConnectProgress {
        guard attempt == nil else { return progress }
        acceptsEvents = false
        progress.outcome = confirmed ? .confirmed : .incomplete
        progress.terminalReason = terminalReason
        if terminalReason == .generationInvalidated { progress.generationValidation = .failed }
        if terminalReason == .profileContextChanged { progress.profileContextValidation = .failed }
        if confirmed { advancePostAckBoundary(.foregroundConfirmed) }
        return progress
    }

    func recordPostAckCompletion(postAckReached: Bool,
                                 relayRefreshConfirmed: Bool,
                                 generationMatches: Bool,
                                 profileMatches: Bool,
                                 relayContextMatches: Bool) {
        guard acceptsEvents, attempt != nil else { return }
        if postAckReached {
            progress.postAckRelayRefresh = relayRefreshConfirmed ? .passed : .failed
            if relayRefreshConfirmed {
                progress.postAckDrainTransition = .completed
                advancePostAckBoundary(.coreDrainCompleted)
            }
            advancePostAckBoundary(.relayRefreshReturned)
        }
        progress.generationValidation = generationMatches ? .passed : .failed
        progress.profileContextValidation = profileMatches ? .passed : .failed
        progress.relayContextValidation = relayContextMatches ? .passed : .failed
        if progress.failureClass == .cancelled {
            progress.terminalReason = .cancelled
        } else if !generationMatches {
            progress.terminalReason = .generationInvalidated
        } else if !profileMatches {
            progress.terminalReason = .profileContextChanged
        } else if !relayContextMatches || !relayRefreshConfirmed {
            progress.terminalReason = .relayContextUnconfirmed
        }
        if postAckReached, !relayRefreshConfirmed,
           (progress.postAckDrainTransition == nil || progress.postAckDrainTransition == .began) {
            switch progress.terminalReason {
            case .cancelled, .generationInvalidated, .profileContextChanged:
                progress.postAckDrainTransition = .cancelled
            case .deadlineExceeded:
                progress.postAckDrainTransition = .timedOut
            default:
                progress.postAckDrainTransition = progress.failureClass == nil ? .unresolved : .failed
            }
        }
        publishProgress()
    }

    func recordTimedOutValidation(attemptID: UUID,
                                  generationMatches: Bool,
                                  profileMatches: Bool,
                                  relayContextMatches: Bool) {
        guard progress.attemptID == attemptID, progress.outcome == .timedOut else { return }
        progress.generationValidation = generationMatches ? .passed : .failed
        progress.profileContextValidation = profileMatches ? .passed : .failed
        progress.relayContextValidation = relayContextMatches ? .passed : .failed
        if progress.lastCompletedPostAckBoundary != .none {
            progress.postAckRelayRefresh = .failed
        }
        if progress.postAckDrainTransition == .began ||
            progress.lastCompletedPostAckBoundary == .nativeCursorAcknowledged {
            progress.postAckDrainTransition = .timedOut
        }
        // Timeout invalidates this transport generation during cleanup. Keep
        // the deadline as the terminal reason and report validation separately.
        progress.terminalReason = .deadlineExceeded
    }

    func recordFailure(_ error: Error) {
        guard acceptsEvents, attempt != nil else { return }
        progress.failureClass = NativeForegroundConnectProgress.FailureClass.classify(error)
        if progress.failureClass == .cancelled { progress.terminalReason = .cancelled }
        publishProgress()
    }

    private func advancePostAckBoundary(_ candidate: NativeForegroundConnectProgress.PostAckBoundary) {
        guard candidate.rank >= progress.lastCompletedPostAckBoundary.rank else { return }
        progress.lastCompletedPostAckBoundary = candidate
    }

    private func publishProgress() {
        guard var active = attempt else { return }
        active.progress = progress
        attempt = active
        active.onProgress(progress)
    }

    private func finish(_ id: UUID, connected: Bool) {
        guard let active = attempt, active.id == id else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        operationTask = nil
        attempt = nil
        acceptsEvents = false
        if connected {
            progress.lastConfirmedStage = .foregroundConfirmed
            progress.issue = nil
            progress.failureClass = nil
            progress.outcome = .confirmed
            progress.terminalReason = .confirmed
            advancePostAckBoundary(.foregroundConfirmed)
        } else {
            progress.outcome = .incomplete
            if progress.terminalReason == nil {
                progress.terminalReason = progress.failureClass == .cancelled
                    ? .cancelled : .connectionNotConfirmed
            }
        }
        active.onProgress(progress)
        active.continuation.resume(returning: progress)
    }

    private func expire(_ id: UUID) async {
        guard let active = attempt, active.id == id else { return }
        attempt = nil
        timeoutTask = nil
        operationTask?.cancel()
        operationTask = nil
        acceptsEvents = false
        progress = active.progress
        progress.failureClass = .foregroundDeadline
        progress.outcome = .timedOut
        progress.terminalReason = .deadlineExceeded
        active.onProgress(progress)
        await active.onTimeout()
        active.continuation.resume(returning: progress)
    }
}

/// Presentation of a connection-scoped refusal, never persisted with a thread.
@MainActor
@Observable
final class NativeConversationAvailability {
    var unavailableContext: ProfileContext?

    func message(for context: ProfileContext) -> String? {
        unavailableContext == context ? String(localized: "Chat is not available on this server yet.") : nil
    }
}

/// App-owned wake boundary. A future enrollment/profile owner supplies the
/// authenticated installation material and the SAME C store used by live UI.
/// Fixture launch deliberately leaves this unconfigured.
@MainActor
final class NativeRelayLifecycle {
    static let shared = NativeRelayLifecycle()

    let conversationAvailability = NativeConversationAvailability()
    private var core: NativeRelayCore? {
        didSet { conversationAvailability.unavailableContext = nil }
    }
    private var transport: URLSessionInstallationSession?
    private var context: ProfileContext?
    private var confirmedRelayContext: ProfileContext?
    private var requiresExplicitForegroundRetry = false
    private var activeTransportAttemptID: UUID?
    private let foregroundDeadline = ForegroundConnectDeadline()
    private var diagnosticJournal: NativeClientDiagnosticJournal?
    private var foregroundDiagnosticContext: ProfileContext?
    private var foregroundDiagnosticOperationsAtStart: [UUID: NativeForegroundOperationDiagnostic] = [:]
    private var foregroundDiagnosticIntentIDs: [UUID: UUID] = [:]
    private var foregroundDiagnosticSnapshotAvailable = false
    private var configuration: (store: AttentionDomainStore,
                                context: ProfileContext,
                                relayURL: URL,
                                identity: SecIdentity,
                                rootDER: Data)?
    private var refreshGeneration = UUID()
    private lazy var refreshFlights = RelayRefreshFlights(inactive: NativeRelayRefreshResult.unavailable) { [weak self] in
        guard let self else { return .unavailable }
        return await self.performRefresh(generation: self.refreshGeneration)
    }
    private let enrollment = NativeEnrollmentStore()

    init() {}

    func activate(store: AttentionDomainStore,
                  context: ProfileContext,
                  relayURL: URL,
                  clientIdentity: SecIdentity,
                  trustedRootDER: Data,
                  diagnostics: NativeClientDiagnosticJournal? = nil) async throws {
        _ = try store.snapshot(context: context)
        let generation = UUID()
        let transportAttemptID = UUID()
        self.diagnosticJournal = diagnostics
        recordDiagnostic(.connection, .approvedConnection, .began,
                         attemptID: transportAttemptID, transportAttemptID: transportAttemptID)
        let nextTransport: URLSessionInstallationSession
        do {
            nextTransport = try URLSessionInstallationSession(profile: context,
                                                              relayURL: relayURL,
                                                              clientIdentity: TrustedKeychainIdentity(clientIdentity),
                                                              trustedRootDER: trustedRootDER,
                                                              attemptID: transportAttemptID,
                                                              onProgress: progressHandler(generation: generation,
                                                                                          transportAttemptID: transportAttemptID),
                                                              onDiagnostic: diagnosticSink())
        } catch {
            recordDiagnostic(.connection, .approvedConnection,
                             NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                             attemptID: transportAttemptID, transportAttemptID: transportAttemptID)
            throw error
        }
        let nextCore: NativeRelayCore
        do {
            nextCore = try NativeRelayCore(store: store, context: context, session: nextTransport,
                                           attemptID: transportAttemptID,
                                           onProgress: progressHandler(generation: generation,
                                                                       transportAttemptID: transportAttemptID),
                                           onDiagnostic: diagnosticSink())
        } catch {
            recordDiagnostic(.connection, .approvedConnection, .failed, error: error,
                             attemptID: transportAttemptID, transportAttemptID: transportAttemptID)
            await nextTransport.close()
            throw error
        }
        refreshGeneration = generation
        refreshFlights.reset()
        foregroundDeadline.beginSession(transportAttemptID: transportAttemptID)
        requiresExplicitForegroundRetry = false
        let priorCore = core
        let priorTransport = transport
        core = nil
        transport = nil
        self.context = nil
        confirmedRelayContext = nil
        configuration = nil
        if let priorCore { await priorCore.deactivate() }
        if let priorTransport { await priorTransport.close() }
        guard refreshGeneration == generation else {
            await nextCore.deactivate()
            await nextTransport.close()
            throw NativeRelayCoreError.inactive
        }
        transport = nextTransport
        core = nextCore
        self.context = context
        activeTransportAttemptID = transportAttemptID
        configuration = (store, context, relayURL, clientIdentity, trustedRootDER)
    }

    /// Validates a fixed, approved endpoint with the same client identity and
    /// root before replacing the current transport. The persistence closure is
    /// called only after the candidate TLS/WebSocket endpoint answers a ping.
    func migrateEndpoint(to relayURL: URL, persist: () throws -> Void) async throws {
        guard let current = configuration, let priorCore = core, let priorTransport = transport,
              current.context.identity.trustedRelayAuthority.rawValue == NativeEndpointMigrationPolicy.sourceHost,
              current.relayURL.host == NativeEndpointMigrationPolicy.sourceHost,
              NativeEndpointMigrationPolicy.matchesApprovedRoot(current.rootDER),
              relayURL.scheme == "wss", relayURL.host == NativeEndpointMigrationPolicy.gibsonHost,
              relayURL.port == NativeEndpointMigrationPolicy.gibsonRelayPort,
              relayURL.path == "/relay", relayURL.query == nil, relayURL.fragment == nil,
              relayURL.user == nil, relayURL.password == nil else {
            throw NativeRelayCoreError.inactive
        }
        let expectedGeneration = refreshGeneration
        let nextTransport = try URLSessionInstallationSession(profile: current.context,
                                                              relayURL: relayURL,
                                                              clientIdentity: TrustedKeychainIdentity(current.identity),
                                                              trustedRootDER: current.rootDER)
        var nextCore: NativeRelayCore?
        do {
            nextCore = try NativeRelayCore(store: current.store, context: current.context, session: nextTransport)
            try await nextTransport.verifyEndpoint()
            guard refreshGeneration == expectedGeneration,
                  core === priorCore, transport === priorTransport,
                  configuration?.relayURL == current.relayURL else {
                throw NativeRelayCoreError.inactive
            }
            try persist()

            refreshGeneration = UUID()
            refreshFlights.reset()
            confirmedRelayContext = nil
            core = nextCore
            transport = nextTransport
            configuration = (current.store, current.context, relayURL, current.identity, current.rootDER)
            nextCore = nil
            await priorCore.deactivate()
            await priorTransport.close()
        } catch {
            if let nextCore { await nextCore.deactivate() }
            await nextTransport.close()
            throw error
        }
    }

    func deactivate() async {
        refreshGeneration = UUID()
        refreshFlights.reset()
        requiresExplicitForegroundRetry = false
        let priorCore = core
        let priorTransport = transport
        core = nil
        transport = nil
        context = nil
        confirmedRelayContext = nil
        activeTransportAttemptID = nil
        configuration = nil
        foregroundDiagnosticContext = nil
        foregroundDiagnosticOperationsAtStart = [:]
        foregroundDiagnosticIntentIDs = [:]
        foregroundDiagnosticSnapshotAvailable = false
        diagnosticJournal = nil
        if let priorCore { await priorCore.deactivate() }
        if let priorTransport { await priorTransport.close() }
    }

    /// APNs data is a wake hint only. The payload cannot choose account,
    /// sender, message, cursor, operation or answer.
    @discardableResult
    func refreshFromTrustedRelay() async -> Bool {
        guard !requiresExplicitForegroundRetry else { return false }
        return await refreshResultFromTrustedRelay().relayConfirmed
    }

    func refreshResultFromTrustedRelay() async -> NativeRelayRefreshResult {
        guard !requiresExplicitForegroundRetry else { return .unavailable }
        return await refreshFlights.coalesced()
    }

    /// The terminal event batch used by the foreground lifecycle and its
    /// focused behavior test. Keeping the mapping here makes the emitted
    /// boundary and validation facts testable without constructing journal
    /// events by hand.
    static func foregroundTerminalDiagnosticEvents(
        progress: NativeForegroundConnectProgress,
        confirmed: Bool,
        timedOut: Bool = false,
        fallbackTransportAttemptID: UUID? = nil,
        generationMatches: Bool,
        profileMatches: Bool,
        relayContextMatches: Bool
    ) -> [NativeClientDiagnosticEvent] {
        let attemptID = progress.attemptID
        let transportAttemptID = progress.transportAttemptID ?? fallbackTransportAttemptID
        let cancelled = progress.failureClass == .cancelled || !generationMatches || !profileMatches
        let transition: NativeDiagnosticTransition = timedOut ? .timedOut :
            (confirmed ? .completed : (cancelled ? .cancelled : .failed))
        let terminalReason = confirmed ? NativeDiagnosticTerminalReason.confirmed :
            progress.terminalReason?.journalValue
        let postAckBoundary = confirmed ? NativeDiagnosticPostAckBoundary.foregroundConfirmed :
            progress.lastCompletedPostAckBoundary.journalValue

        return [
            NativeClientDiagnosticEvent(area: .connection, phase: .foregroundGenerationValidation,
                transition: generationMatches ? .completed : .cancelled,
                causeCode: generationMatches ? nil : "foreground_generation_invalidated",
                attemptID: attemptID, transportAttemptID: transportAttemptID),
            NativeClientDiagnosticEvent(area: .connection, phase: .foregroundProfileValidation,
                transition: profileMatches ? .completed : .cancelled,
                causeCode: profileMatches ? nil : "foreground_profile_context_changed",
                attemptID: attemptID, transportAttemptID: transportAttemptID),
            NativeClientDiagnosticEvent(area: .connection, phase: .foregroundContextValidation,
                transition: relayContextMatches ? .completed : .unresolved,
                causeCode: relayContextMatches ? nil : "foreground_relay_context_unconfirmed",
                attemptID: attemptID, transportAttemptID: transportAttemptID),
            NativeClientDiagnosticEvent(area: .connection, phase: .foregroundCompletion,
                transition: transition,
                causeCode: progress.failureClass?.diagnosticValue,
                terminalReason: terminalReason,
                postAckBoundary: postAckBoundary,
                postAckDrainTransition: progress.postAckDrainTransition,
                attemptID: attemptID, transportAttemptID: transportAttemptID)
        ]
    }

    /// Enrollment readiness is actual authenticated replay progress. A later
    /// push-register failure must not hide a working foreground connection.
    func confirmForegroundProgress(for expected: ProfileContext,
                                   deadline: Duration = .seconds(30),
                                   onProgress: @escaping @MainActor (NativeForegroundConnectProgress) -> Void = { _ in }) async -> NativeForegroundConnectProgress {
        guard context == expected else {
            let failed = foregroundDeadline.finishWithoutAttempt(
                confirmed: false, terminalReason: .profileContextChanged)
            recordDiagnostic(.connection, .approvedConnection, .failed,
                             causeCode: "approved_profile_not_active",
                             terminalReason: NativeDiagnosticTerminalReason.profileContextChanged)
            recordDiagnostic(.connection, .foregroundProfileValidation, .cancelled,
                             causeCode: "foreground_profile_context_changed",
                             terminalReason: NativeDiagnosticTerminalReason.profileContextChanged)
            recordDiagnostic(.connection, .foregroundCompletion, .cancelled,
                             causeCode: "foreground_profile_context_changed",
                             terminalReason: NativeDiagnosticTerminalReason.profileContextChanged)
            onProgress(failed)
            return failed
        }
        foregroundDiagnosticContext = expected
        if let configuration, configuration.context == expected {
            do {
                let snapshot = try configuration.store.snapshot(context: expected)
                foregroundDiagnosticSnapshotAvailable = true
                var submissions = Dictionary(uniqueKeysWithValues: snapshot.intents.values
                    .filter { Self.isUnresolved($0, remoteStates: snapshot.remoteStates) }
                    .map { ($0.operationID, $0) })
                for submission in snapshot.outbox { submissions[submission.operationID] = submission }
                foregroundDiagnosticOperationsAtStart = Dictionary(uniqueKeysWithValues: submissions.values.map { submission in
                    let item = NativeForegroundOperationDiagnostic(submission: submission,
                        receiptState: Self.receiptState(for: submission.disposition))
                    return (submission.operationID, item)
                })
                foregroundDiagnosticIntentIDs = Dictionary(uniqueKeysWithValues: submissions.values.map {
                    ($0.operationID, $0.intentID)
                })
            } catch {
                foregroundDiagnosticSnapshotAvailable = false
                foregroundDiagnosticOperationsAtStart = [:]
                foregroundDiagnosticIntentIDs = [:]
                recordDiagnostic(.localStore, .projectionRefresh,
                                 NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                                 attemptID: activeTransportAttemptID)
            }
        } else {
            foregroundDiagnosticSnapshotAvailable = false
            foregroundDiagnosticOperationsAtStart = [:]
            foregroundDiagnosticIntentIDs = [:]
        }
        let epoch = refreshGeneration
        var result = await foregroundDeadline.run(deadline: deadline, operation: { [weak self] in
            guard let self else { return false }
            let refresh = await self.refreshResultFromTrustedRelay()
            let relayConfirmed = refresh.relayConfirmed
            let generationMatches = self.refreshGeneration == epoch
            let profileMatches = self.context == expected
            let relayContextMatches = refresh.confirms(expected, transportAttemptID: self.activeTransportAttemptID)
            guard self.foregroundDeadline.progress.outcome == .connecting else { return false }
            let beforeValidation = self.foregroundDeadline.progress
            let postAckReached = beforeValidation.lastCompletedPostAckBoundary != .none || relayConfirmed
            self.foregroundDeadline.recordPostAckCompletion(
                postAckReached: postAckReached,
                relayRefreshConfirmed: relayConfirmed,
                generationMatches: generationMatches,
                profileMatches: profileMatches,
                relayContextMatches: relayContextMatches)
            let reached = relayConfirmed && generationMatches && profileMatches && relayContextMatches
            let terminalProgress = self.foregroundDeadline.progress
            self.recordDiagnosticEvents(Self.foregroundTerminalDiagnosticEvents(
                progress: terminalProgress, confirmed: reached,
                fallbackTransportAttemptID: self.activeTransportAttemptID,
                generationMatches: generationMatches, profileMatches: profileMatches,
                relayContextMatches: relayContextMatches))
            return reached
        }, onTimeout: { [weak self] in
            await self?.cancelTimedOutSession(generation: epoch, expected: expected)
        }, onBegin: { [weak self] foregroundAttemptID in
            self?.recordDiagnostic(.connection, .approvedConnection, .began,
                                   attemptID: foregroundAttemptID,
                                   transportAttemptID: self?.activeTransportAttemptID)
        }, onProgress: onProgress)
        if result.outcome == .timedOut, let attemptID = result.attemptID {
            let generationMatches = refreshGeneration == epoch
            let profileMatches = context == expected
            let relayContextMatches = confirmedRelayContext == expected
            foregroundDeadline.recordTimedOutValidation(attemptID: attemptID,
                generationMatches: generationMatches, profileMatches: profileMatches,
                relayContextMatches: relayContextMatches)
            result = foregroundDeadline.progress
            onProgress(result)

            recordDiagnosticEvents(Self.foregroundTerminalDiagnosticEvents(
                progress: result, confirmed: false, timedOut: true,
                generationMatches: generationMatches, profileMatches: profileMatches,
                relayContextMatches: relayContextMatches))
        }
        let transition: NativeDiagnosticTransition
        switch result.outcome {
        case .connecting: transition = .observed
        case .incomplete: transition = result.failureClass == .cancelled ? .cancelled : .failed
        case .timedOut: transition = .timedOut
        case .confirmed: transition = .completed
        }
        recordDiagnostic(.connection, .approvedConnection, transition,
                         causeCode: result.failureClass?.diagnosticValue,
                         terminalReason: result.terminalReason?.journalValue,
                         attemptID: result.attemptID ?? activeTransportAttemptID,
                         transportAttemptID: result.transportAttemptID ?? activeTransportAttemptID,
                         receipt: nil)
        return result
    }

    func foregroundOperationDiagnostics(for expected: ProfileContext) -> NativeForegroundOperationSnapshot {
        guard foregroundDiagnosticContext == expected, context == expected,
              foregroundDiagnosticSnapshotAvailable,
              let configuration, configuration.context == expected else {
            return .unavailable
        }
        let operations = foregroundDiagnosticOperationsAtStart.values.map { initial in
            guard let intentID = foregroundDiagnosticIntentIDs[initial.operationID] else {
                return NativeForegroundOperationDiagnostic(operationID: initial.operationID,
                    senderID: initial.senderID, messageID: initial.messageID,
                    requestRevision: initial.requestRevision, receiptState: "unknown_after_attempt")
            }
            do {
                guard let submission = try configuration.store.lookupIntent(intentID, context: expected) else {
                    return NativeForegroundOperationDiagnostic(operationID: initial.operationID,
                        senderID: initial.senderID, messageID: initial.messageID,
                        requestRevision: initial.requestRevision, receiptState: "unknown_after_attempt")
                }
                return NativeForegroundOperationDiagnostic(operationID: initial.operationID,
                    senderID: initial.senderID, messageID: initial.messageID,
                    requestRevision: initial.requestRevision,
                    receiptState: Self.receiptState(for: submission.disposition))
            } catch {
                recordDiagnostic(.localStore, .projectionRefresh,
                                 NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                                 attemptID: activeTransportAttemptID, operationID: initial.operationID,
                                 revision: initial.requestRevision, receipt: .unknown)
                return NativeForegroundOperationDiagnostic(operationID: initial.operationID,
                    senderID: initial.senderID, messageID: initial.messageID,
                    requestRevision: initial.requestRevision, receiptState: "unknown_after_attempt")
            }
        }.sorted { $0.operationID.uuidString < $1.operationID.uuidString }
        return NativeForegroundOperationSnapshot(available: true, operations: operations)
    }

    private static func receiptState(for disposition: IntentDisposition) -> String {
        switch disposition {
        case .pending: "pending_unconfirmed"
        case let .accepted(sequence): "relay_accepted_sequence_\(sequence.map { String($0) } ?? "unknown")_awaiting_terminal_state"
        case .lost: "locally_lost_unconfirmed"
        case let .terminal(state, sequence, _): "terminal_\(state.rawValue)_sequence_\(sequence)"
        case let .refusedByRetraction(retractedAt): "refused_retracted_at_\(retractedAt)"
        case .repairRequired: "repair_required"
        }
    }

    private static func isUnresolved(_ submission: Submission,
                                     remoteStates: [RequestKey: RemoteRequestState]) -> Bool {
        guard remoteStates[submission.requestKey]?.isTerminal != true else { return false }
        if case .terminal = submission.disposition { return false }
        return true
    }

    /// A token callback can arrive after an in-flight resync has already read
    /// the protected address. Queue one more authenticated pass in that case.
    @discardableResult
    func refreshAfterPushAddressStored() async -> Bool {
        await refreshFlights.afterCurrent().completedWithoutError
    }

    /// The current flight may already have read C's outbox before the person
    /// committed this answer. A later pass must see that original operation.
    func refreshAfterAnswerStored() async -> NativeRelayRefreshResult {
        await refreshFlights.afterCurrent()
    }

    @discardableResult
    func fetchNextInboxPage() async -> Bool {
        guard let core, let context, !requiresExplicitForegroundRetry else { return false }
        do {
            let fetched = try await core.fetchNextInboxPage()
            guard self.context == context else { return false }
            return fetched
        } catch {
            recordDiagnostic(.relay, .ordinaryReplay,
                NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                attemptID: activeTransportAttemptID)
            return false
        }
    }

    func recordPushRegistrationFailure(_ error: Error? = nil,
                                      causeCode: String? = nil,
                                      area: NativeDiagnosticArea = .notifications) {
        recordDiagnostic(area, .pushRegistration, .failed,
                         error: error, causeCode: causeCode,
                         attemptID: activeTransportAttemptID)
    }

    func submitDiscussion(_ binding: ConversationBinding, expected: ProfileContext,
                          retainedFile: @Sendable (ConversationFile) async throws -> URL) async throws -> DiscussionOperationResult {
        guard context == expected, let configuration else { throw NativeRelayCoreError.inactive }
        let pending = try configuration.store.conversationSnapshot(context: expected).threads[binding.request]?.drafts[binding.revision]
        let operation: UUID?
        switch pending?.disposition {
        case let .submitting(id), let .outcomeUnknown(id), let .acceptedPendingReplay(id, _): operation = id
        default: operation = nil
        }
        _ = await refreshFlights.coalesced()
        guard context == expected, let core else { throw NativeRelayCoreError.inactive }
        // Refresh may already have joined the uncertain operation. Do not turn
        // that successful reconciliation into a new send or a missing-draft error.
        if let operation, let accepted = try configuration.store.conversationSnapshot(context: expected)
            .threads[binding.request]?.turns.first(where: { $0.operationID == operation }) {
            return .accepted(turnID: accepted.id)
        }
        return try await core.submitDiscussion(binding, retainedFile: retainedFile)
    }

    func discardAbandonedUploads(for request: RequestKey, expected: ProfileContext) async throws {
        guard context == expected, let core else { throw NativeRelayCoreError.inactive }
        // Do not wait for the active send flight: departure fences its upload.
        try await core.discardAbandonedUploads(for: request)
        guard context == expected else { throw NativeRelayCoreError.inactive }
    }

    func fetchConversationFile(_ file: ConversationFile, to destination: URL, expected: ProfileContext) async throws {
        guard context == expected else { throw NativeRelayCoreError.inactive }
        _ = await refreshFlights.coalesced()
        guard context == expected, let core, let transport,
              let endpoint = try await core.conversationOriginURL() else {
            throw ConversationError.uploadRequired(file.name)
        }
        try await transport.fetchConversationFile(file, to: destination, originURL: endpoint)
        guard context == expected else { throw NativeRelayCoreError.inactive }
    }

    private func performRefresh(generation: UUID) async -> NativeRelayRefreshResult {
        guard refreshGeneration == generation, !requiresExplicitForegroundRetry else { return .unavailable }
        // A past replay is not proof that this connection attempt worked.
        confirmedRelayContext = nil
        recordDiagnostic(.relay, .projectionRefresh, .began, attemptID: activeTransportAttemptID)
        do {
            let result = try await refreshOnce(generation: generation)
            recordDiagnostic(.relay, .projectionRefresh,
                             result.relayConfirmed ? .completed : .unresolved,
                             attemptID: activeTransportAttemptID)
            return refreshGeneration == generation ? result : .unavailable
        } catch {
            guard refreshGeneration == generation else { return .unavailable }
            recordDiagnostic(.relay, .projectionRefresh, .retrying, error: error,
                             attemptID: activeTransportAttemptID)
            foregroundDeadline.recordFailure(error)
            // Retire an ambiguous WebSocket before retrying C's exact durable
            // outbox and cursor once on a fresh authenticated session.
            do {
                try await reconnect(generation: generation)
                guard refreshGeneration == generation else { return .unavailable }
                let result = try await refreshOnce(generation: generation)
                recordDiagnostic(.relay, .projectionRefresh,
                                 result.relayConfirmed ? .completed : .unresolved,
                                 attemptID: activeTransportAttemptID)
                return refreshGeneration == generation ? result : .unavailable
            } catch {
                guard refreshGeneration == generation else { return .unavailable }
                recordDiagnostic(.relay, .projectionRefresh, .failed, error: error,
                                 attemptID: activeTransportAttemptID)
                foregroundDeadline.recordFailure(error)
                return .unavailable
            }
        }
    }

    private func refreshOnce(generation: UUID) async throws -> NativeRelayRefreshResult {
        guard refreshGeneration == generation else { throw NativeRelayCoreError.inactive }
        guard let core, let transport, let context else { throw NativeRelayCoreError.inactive }
        _ = try await core.resyncAndDrainOutbox()
        let conversationsUnavailable = await core.conversationsUnavailable
        guard refreshGeneration == generation, self.context == context, self.core === core else {
            throw NativeRelayCoreError.inactive
        }
        conversationAvailability.unavailableContext = conversationsUnavailable ? context : nil
        confirmedRelayContext = context
        if let configuration {
            let threads = try configuration.store.conversationSnapshot(context: context).threads
            for (request, thread) in threads where (thread.uploadCleanups ?? [:]).values.contains(where: {
                if case .acknowledged = $0.outcome { return false }; return true
            }) {
                // Cleanup retry never resends a discussion or changes a replay cursor.
                try? await core.discardAbandonedUploads(for: request)
            }
        }
        // Notification setup is a separate fact from the replay/answer receipt
        // already committed above. Its refusal cannot undo that success.
        return await NativeRelayRefreshResult.afterConfirmedRelay(
            context: context, transportAttemptID: activeTransportAttemptID, onFailure: { [weak self] error in
            self?.recordDiagnostic(.notifications, .pushRegistration, .failed,
                                   error: error, attemptID: self?.activeTransportAttemptID)
        }) {
            if let address = try DevelopmentPushRegistration.addressStore().load(),
               let binding = try enrollment.pendingPushRegistration(address: address,
                                                                     for: context.identity.deviceID.rawValue) {
                guard let expected = try enrollment.load(), expected.matchesNotificationIdentity(context.identity) else {
                    throw NativeJoinError.superseded
                }
                let bindingID = try await transport.registerPush(address: binding.address,
                                                 operationID: binding.operationID,
                                                 revision: binding.revision)
                guard self.refreshGeneration == generation, self.context == context else {
                    throw NativeRelayCoreError.inactive
                }
                try enrollment.markPushAccepted(binding, bindingID: bindingID, expected: expected)
                return .confirmed
            }
            if let expected = try enrollment.load(), expected.matchesNotificationIdentity(context.identity),
               let binding = expected.pushBinding, binding.accepted,
               !(expected.notificationBindings ?? []).contains(where: {
                   $0.operationID == binding.operationID && $0.revision == binding.revision
               }), let bindingID = try await transport.currentPushBindingID(revision: binding.revision) {
                guard self.refreshGeneration == generation, self.context == context else {
                    throw NativeRelayCoreError.inactive
                }
                try enrollment.markPushAccepted(binding, bindingID: bindingID, expected: expected)
                return .confirmed
            }
            return .notAttempted
        }
    }

    private func reconnect(generation: UUID) async throws {
        guard refreshGeneration == generation else { throw NativeRelayCoreError.inactive }
        guard let configuration else { throw NativeRelayCoreError.inactive }
        let transportAttemptID = UUID()
        let previousProgress = foregroundDeadline.progress
        var retryEvents: [NativeClientDiagnosticEvent] = []
        if previousProgress.postAckDrainTransition == .completed,
           previousProgress.lastCompletedPostAckBoundary != .none,
           let previousTransportAttemptID = activeTransportAttemptID {
            // A completed drain can be followed by a later refresh failure
            // before foreground completion. Preserve that transport's boundary
            // before the retry resets the in-memory progress to a new attempt.
            retryEvents.append(NativeClientDiagnosticEvent(area: .relay, phase: .postAckDrain,
                transition: .completed,
                postAckBoundary: previousProgress.lastCompletedPostAckBoundary.journalValue,
                postAckDrainTransition: .completed,
                attemptID: previousProgress.attemptID,
                transportAttemptID: previousTransportAttemptID))
        }
        retryEvents.append(NativeClientDiagnosticEvent(area: .connection, phase: .approvedConnection,
            transition: .retrying, attemptID: transportAttemptID,
            transportAttemptID: transportAttemptID))
        diagnosticJournal?.record(retryEvents)
        foregroundDeadline.beginTransportAttempt(transportAttemptID)
        activeTransportAttemptID = transportAttemptID
        let priorCore = core
        let priorTransport = transport
        core = nil
        transport = nil
        if let priorCore { await priorCore.deactivate() }
        if let priorTransport { await priorTransport.close() }
        guard refreshGeneration == generation else { throw NativeRelayCoreError.inactive }
        let nextTransport: URLSessionInstallationSession
        do {
            nextTransport = try URLSessionInstallationSession(profile: configuration.context,
                                                              relayURL: configuration.relayURL,
                                                              clientIdentity: TrustedKeychainIdentity(configuration.identity),
                                                              trustedRootDER: configuration.rootDER,
                                                              attemptID: transportAttemptID,
                                                              onProgress: progressHandler(generation: generation,
                                                                                          transportAttemptID: transportAttemptID),
                                                              onDiagnostic: diagnosticSink())
        } catch {
            recordDiagnostic(.connection, .approvedConnection,
                             NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                             attemptID: transportAttemptID, transportAttemptID: transportAttemptID)
            throw error
        }
        let nextCore: NativeRelayCore
        do {
            nextCore = try NativeRelayCore(store: configuration.store,
                                           context: configuration.context,
                                           session: nextTransport,
                                           attemptID: transportAttemptID,
                                           onProgress: progressHandler(generation: generation,
                                                                       transportAttemptID: transportAttemptID),
                                           onDiagnostic: diagnosticSink())
        } catch {
            recordDiagnostic(.connection, .approvedConnection, .failed, error: error,
                             attemptID: transportAttemptID, transportAttemptID: transportAttemptID)
            await nextTransport.close()
            throw error
        }
        guard refreshGeneration == generation else {
            await nextCore.deactivate()
            await nextTransport.close()
            throw NativeRelayCoreError.inactive
        }
        self.transport = nextTransport
        self.core = nextCore
    }

    private func progressHandler(generation: UUID,
                                 transportAttemptID: UUID) -> @Sendable (NativeRelayProgressEvent) -> Void {
        { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation,
                      self.activeTransportAttemptID == transportAttemptID else { return }
                self.foregroundDeadline.observe(event, transportAttemptID: transportAttemptID)
                switch event {
                case .serverTrustValidated:
                    self.recordDiagnostic(.connection, .serverTrust, .completed, attemptID: transportAttemptID)
                case .serverTrustRejected:
                    self.recordDiagnostic(.connection, .serverTrust, .failed,
                                          causeCode: "server_trust_rejected", attemptID: transportAttemptID)
                case .clientIdentityOffered:
                    self.recordDiagnostic(.connection, .clientIdentity, .observed, attemptID: transportAttemptID)
                case .clientIdentityChallengeRejected:
                    self.recordDiagnostic(.connection, .clientIdentity, .failed,
                                          causeCode: "client_identity_challenge_rejected", attemptID: transportAttemptID)
                case .webSocketOpened:
                    self.recordDiagnostic(.connection, .webSocketOpen, .completed, attemptID: transportAttemptID)
                case .relayAdmitted:
                    self.recordDiagnostic(.connection, .relayAdmission, .completed, attemptID: transportAttemptID)
                case .nativeSyncReplayRequested:
                    self.recordDiagnostic(.relay, .ordinaryReplay, .began, attemptID: transportAttemptID)
                case .nativeSyncResynced:
                    self.recordDiagnostic(.relay, .ordinaryReplay, .completed, attemptID: transportAttemptID)
                case .nativeSyncAcknowledged:
                    self.recordDiagnostic(.relay, .acknowledgement, .completed, attemptID: transportAttemptID)
                case .postAckDrainBegan, .postAckDrainFinished(_):
                    break
                }
            }
        }
    }

    private func diagnosticSink() -> NativeClientDiagnosticSink {
        guard let diagnosticJournal else { return { _ in } }
        return { [weak diagnosticJournal] event in
            Task { @MainActor [weak diagnosticJournal] in diagnosticJournal?.record(event) }
        }
    }

    private func recordDiagnostic(_ area: NativeDiagnosticArea,
                                  _ phase: NativeDiagnosticPhase,
                                  _ transition: NativeDiagnosticTransition,
                                  error: Error? = nil,
                                  causeCode: String? = nil,
                                  terminalReason: NativeDiagnosticTerminalReason? = nil,
                                  postAckBoundary: NativeDiagnosticPostAckBoundary? = nil,
                                  postAckDrainTransition: NativeDiagnosticTransition? = nil,
                                  attemptID: UUID? = nil,
                                  transportAttemptID: UUID? = nil,
                                  operationID: UUID? = nil,
                                  request: RequestKey? = nil,
                                  revision: UInt64? = nil,
                                  receipt: NativeDiagnosticReceiptState? = nil) {
        let associatedTransport = transportAttemptID ?? (attemptID == activeTransportAttemptID ? attemptID : nil)
        diagnosticJournal?.record(area: area, phase: phase, transition: transition,
            error: error, causeCode: causeCode, terminalReason: terminalReason,
            postAckBoundary: postAckBoundary, postAckDrainTransition: postAckDrainTransition,
            attemptID: attemptID,
            transportAttemptID: associatedTransport, operationID: operationID,
            request: request, requestRevision: revision, receiptState: receipt)
    }

    private func recordDiagnosticEvents(_ events: [NativeClientDiagnosticEvent]) {
        diagnosticJournal?.record(events)
    }

    private func cancelTimedOutSession(generation: UUID, expected: ProfileContext) async {
        guard refreshGeneration == generation, context == expected else { return }
        // Invalidate callbacks before awaiting actor shutdown. Keep the approved
        // profile and immutable relay configuration so only an explicit retry
        // can reopen this identity after timeout.
        refreshGeneration = UUID()
        requiresExplicitForegroundRetry = true
        activeTransportAttemptID = nil
        refreshFlights.reset()
        confirmedRelayContext = nil
        let priorCore = core
        let priorTransport = transport
        core = nil
        transport = nil
        if let priorCore { await priorCore.deactivate() }
        if let priorTransport { await priorTransport.close() }
    }
}

/// Normal foreground/push wakes share a flight. A newly stored APNs address
/// must be checked *after* the current flight, even when it arrived during it.
@MainActor
final class RelayRefreshFlights<Output: Sendable> {
    private let inactive: Output
    private let operation: @MainActor () async -> Output
    private var latest: Task<Output, Never>?
    private var latestID: UUID?
    private var generation = UUID()

    init(inactive: Output, operation: @escaping @MainActor () async -> Output) {
        self.inactive = inactive
        self.operation = operation
    }

    func coalesced() async -> Output {
        if let latest { return await latest.value }
        return await start(after: nil)
    }

    func afterCurrent() async -> Output {
        await start(after: latest)
    }

    func reset() {
        generation = UUID()
        latest = nil
        latestID = nil
    }

    private func start(after previous: Task<Output, Never>?) async -> Output {
        let requestedGeneration = generation
        let id = UUID()
        let task = Task { @MainActor in
            if let previous { _ = await previous.value }
            guard generation == requestedGeneration else { return inactive }
            let result = await operation()
            if generation == requestedGeneration && latestID == id {
                latest = nil
                latestID = nil
            }
            return result
        }
        latest = task
        latestID = id
        return await task.value
    }
}
