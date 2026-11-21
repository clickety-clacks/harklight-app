import AttentionDomain
import CryptoKit
import Foundation
import HarklightNativeRelay
import Security
import Observation
import Network
import enum SwiftUI.ScenePhase

/// Shareable error details deliberately exclude response bodies, decoder context,
/// persistence messages and NSError userInfo, all of which may contain message text.
struct NativeForegroundConnectErrorDetails: Equatable, Sendable {
    let type: String
    let cause: String
    let description: String

    init(_ error: Error) {
        type = String(reflecting: Swift.type(of: error))
        let code: String
        if let paging = error as? InboxPagingWireError {
            switch paging {
            case .invalidFrame: code = "inbox_paging_invalid_frame"
            case .serverRefused: code = "inbox_paging_server_refused"
            }
        } else {
            code = NativeClientDiagnosticJournal.causeCode(for: error)
        }
        cause = code == "unknown_error" ? type : code
        description = Self.describe(error, cause: code)
    }

    private static func describe(_ error: Error, cause: String) -> String {
        if let value = error as? InboxPagingWireError {
            switch value {
            case .invalidFrame: return "The inbox paging response was invalid."
            case .serverRefused: return "The server refused inbox paging (response text omitted)."
            }
        }
        if let value = error as? DecodingError {
            switch value {
            case .dataCorrupted: return "Decoding failed because the data was corrupted."
            case .keyNotFound: return "Decoding failed because a required key was missing."
            case .typeMismatch: return "Decoding failed because a value had the wrong type."
            case .valueNotFound: return "Decoding failed because a required value was missing."
            @unknown default: return "Decoding failed (context omitted)."
            }
        }
        if let value = error as? EncodingError {
            switch value {
            case .invalidValue: return "Encoding failed because a value was invalid."
            @unknown default: return "Encoding failed (context omitted)."
            }
        }
        if let value = error as? AttentionStoreError {
            switch value {
            case .persistence: return "Durable state could not be committed (underlying text omitted)."
            case .missingOriginContent: return "Origin content is missing; the cursor was not advanced."
            case .competingIntent: return "A different durable intent already owns this request."
            default: return value.localizedDescription
            }
        }
        let value = error as NSError
        switch value.domain {
        case NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, "NSOSStatusErrorDomain":
            // Reconstruct the system description without filenames, URLs, custom
            // localized text or underlying errors supplied in userInfo.
            return "\(value.domain) code \(value.code): \(NSError(domain: value.domain, code: value.code).localizedDescription)"
        default:
            return cause == "unknown_error"
                ? "Error code \(value.code); unrecognized error description omitted."
                : cause.replacingOccurrences(of: "_", with: " ")
        }
    }
}

struct NativeRelayRefreshResult: Equatable, Sendable {
    enum PushRegistration: Equatable, Sendable {
        case notAttempted
        case confirmed
        case unconfirmed
    }

    let relayConfirmed: Bool
    let pushRegistration: PushRegistration
    let failureMessage: String?
    // Confirmation belongs to the refresh that produced this result. A queued
    // refresh can start before its predecessor's foreground waiter resumes.
    let confirmedContext: ProfileContext?
    let confirmedTransportAttemptID: UUID?

    init(relayConfirmed: Bool,
         pushRegistration: PushRegistration,
         confirmedContext: ProfileContext?,
         confirmedTransportAttemptID: UUID?,
         failureMessage: String? = nil) {
        self.relayConfirmed = relayConfirmed
        self.pushRegistration = pushRegistration
        self.confirmedContext = confirmedContext
        self.confirmedTransportAttemptID = confirmedTransportAttemptID
        self.failureMessage = failureMessage
    }

    static let unavailable = Self(relayConfirmed: false, pushRegistration: .notAttempted,
                                  confirmedContext: nil, confirmedTransportAttemptID: nil)

    static func failed(error: Error) -> Self {
        Self(relayConfirmed: false, pushRegistration: .notAttempted,
             confirmedContext: nil, confirmedTransportAttemptID: nil,
             failureMessage: "The relay refresh failed: \(error.localizedDescription). Saved requests and answers remain on this device.")
    }

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
        let errorDetails: NativeForegroundConnectErrorDetails?
        let lastCompletedPostAckBoundary: PostAckBoundary
        let postAckRelayRefresh: Validation
        let postAckDrainTransition: NativeDiagnosticTransition?
        let postAckFailureStep: NativeDiagnosticPostAckStep?
        let postAckFailureErrorCode: String?
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
    var errorDetails: NativeForegroundConnectErrorDetails? = nil
    var observedErrorMessage: String? = nil
    var transportAttemptID: UUID? = nil
    var nativeSyncReplayRequested = false
    var previousTransportAttempt: PreviousTransportAttempt? = nil
    var lastCompletedPostAckBoundary: PostAckBoundary = .none
    var postAckRelayRefresh: Validation = .notChecked
    var postAckDrainTransition: NativeDiagnosticTransition? = nil
    var postAckFailureStep: NativeDiagnosticPostAckStep? = nil
    var postAckFailureErrorCode: String? = nil
    var generationValidation: Validation = .notChecked
    var profileContextValidation: Validation = .notChecked
    var relayContextValidation: Validation = .notChecked
    var terminalReason: TerminalReason? = nil

    private var observedCauseText: String {
        if let observedErrorMessage, !observedErrorMessage.isEmpty {
            return "Observed error: \(observedErrorMessage). "
        }
        return failureClass.map { "Observed error class: \($0.diagnosticValue). " } ?? "Cause was not observed. "
    }

    mutating func markGenerationInvalidated() {
        outcome = .incomplete
        generationValidation = .failed
        terminalReason = .generationInvalidated
    }

    /// Product status; detailed replay and acknowledgement facts remain in `message`.
    var userFacingMessage: String {
        switch outcome {
        case .confirmed: "Connected"
        case .connecting: "Connecting to the server… Your pending actions are saved."
        case .timedOut, .incomplete: "Can't reach the server. Your pending actions are saved."
        }
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
        if let postAckFailureText { return postAckFailureText }
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

    private var postAckFailureText: String? {
        guard let step = postAckFailureStep, outcome != .confirmed else { return nil }
        let detail = "Harklight stopped while \(step.userFacingDescription) after syncing earlier messages. Pending-action delivery is not confirmed. Retry with the same approved identity. Share connection details to include the exact failure code."
        switch outcome {
        case .connecting:
            return "The connection attempt is still in progress. \(detail)"
        case .incomplete:
            return "The connection is not confirmed. \(detail)"
        case .timedOut:
            return "The connection attempt timed out. \(detail)"
        case .confirmed:
            return nil
        }
    }
}

private extension NativeDiagnosticPostAckStep {
    var userFacingDescription: String {
        switch self {
        case .readAcceptedOperationsBeforeDrain: "checking accepted pending actions"
        case .readOutboxBeforeDrain: "checking pending actions"
        case .drainPendingOperations: "sending pending actions"
        case .readOutboxAfterDrain: "checking the pending-action results"
        case .readAcceptedOperationsAfterDrain: "checking which actions the relay accepted"
        case .waitForAcceptedOperationAcknowledgement: "waiting for the relay to confirm accepted actions"
        case .replayInboxAfterDrain: "replaying newly received messages"
        case .readInboxCursorAfterAcknowledgement: "checking the saved message checkpoint"
        case .readConversationState: "checking conversation state"
        case .replayConversationsAndAcknowledge: "updating conversations"
        case .readFinalRelayCursor: "checking the final saved message checkpoint"
        case .validateRelayState: "validating the relay connection"
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
        let failure = Self.failureValue(progress.failureClass, details: progress.errorDetails)
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
            "post_ack_failure_step=\(progress.postAckFailureStep?.rawValue ?? "none_observed")",
            "post_ack_failure_error_code=\(progress.postAckFailureErrorCode ?? "none_observed")",
            "generation_validated=\(progress.generationValidation.rawValue)",
            "profile_context_validated=\(progress.profileContextValidation.rawValue)",
            "relay_context_validated=\(progress.relayContextValidation.rawValue)",
            "terminal_reason=\(terminal)",
            "transport_attempt_id=\(progress.transportAttemptID?.uuidString.lowercased() ?? "unavailable")",
            "native_sync_replay_requested_locally=\(progress.nativeSyncReplayRequested ? "yes" : "no")",
            "websocket_open_observed=\(websocket)",
            "issue=\(issue)",
            "error_class=\(failure)",
            "error_type=\(progress.errorDetails?.type ?? "none_observed")",
            "error_description=\(progress.errorDetails?.description ?? "none_observed")"
        ]
        if let previous = progress.previousTransportAttempt {
            lines.append("previous_transport_attempt_id=\(previous.id.uuidString.lowercased())")
            lines.append("previous_last_confirmed_phase=\(previous.lastConfirmedStage?.diagnosticValue ?? "none_confirmed")")
            lines.append("previous_websocket_open_observed=\(previous.webSocketOpenObserved ? "yes" : "no")")
            lines.append("previous_native_sync_replay_requested_locally=\(previous.nativeSyncReplayRequested ? "yes" : "no")")
            lines.append("previous_issue=\(Self.issueValue(previous.issue))")
            lines.append("previous_error_class=\(Self.failureValue(previous.failureClass, details: previous.errorDetails))")
            lines.append("previous_error_type=\(previous.errorDetails?.type ?? "none_observed")")
            lines.append("previous_error_description=\(previous.errorDetails?.description ?? "none_observed")")
            lines.append("previous_last_completed_post_ack_boundary=\(previous.lastCompletedPostAckBoundary.rawValue)")
            lines.append("previous_post_ack_relay_refresh=\(previous.postAckRelayRefresh.rawValue)")
            lines.append("previous_post_ack_drain=\(previous.postAckDrainTransition?.rawValue ?? "not_started")")
            lines.append("previous_post_ack_failure_step=\(previous.postAckFailureStep?.rawValue ?? "none_observed")")
            lines.append("previous_post_ack_failure_error_code=\(previous.postAckFailureErrorCode ?? "none_observed")")
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

    private static func failureValue(_ failure: NativeForegroundConnectProgress.FailureClass?,
                                     details: NativeForegroundConnectErrorDetails?) -> String {
        if failure == .unknown, let details { return details.cause }
        return failure?.diagnosticValue ?? "none_observed"
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

extension NativeForegroundConnectProgress.Stage {
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

/// Tracks one saved-identity foreground connection until its operation finishes.
/// Catch-up duration is not a failure: only the transport or Server can fail it.
@MainActor
final class ForegroundConnectProgressTracker {
    private struct Attempt {
        let id: UUID
        let onProgress: @MainActor (NativeForegroundConnectProgress) -> Void
        var progress: NativeForegroundConnectProgress
    }

    private var attempt: Attempt?
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
                errorDetails: progress.errorDetails,
                lastCompletedPostAckBoundary: progress.lastCompletedPostAckBoundary,
                postAckRelayRefresh: progress.postAckRelayRefresh,
                postAckDrainTransition: progress.postAckDrainTransition,
                postAckFailureStep: progress.postAckFailureStep,
                postAckFailureErrorCode: progress.postAckFailureErrorCode,
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
        progress.errorDetails = nil
        progress.observedErrorMessage = nil
        progress.outcome = .connecting
        progress.lastCompletedPostAckBoundary = .none
        progress.postAckRelayRefresh = .notChecked
        progress.postAckDrainTransition = nil
        progress.postAckFailureStep = nil
        progress.postAckFailureErrorCode = nil
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

    func run(operation: @escaping @MainActor () async -> Bool,
             onBegin: @escaping @MainActor (UUID) -> Void = { _ in },
             onProgress: @escaping @MainActor (NativeForegroundConnectProgress) -> Void) async -> NativeForegroundConnectProgress {
        guard attempt == nil else { return progress }
        let id = UUID()
        progress.attemptID = id
        progress.failureClass = nil
        progress.errorDetails = nil
        progress.outcome = .connecting
        attempt = Attempt(id: id, onProgress: onProgress, progress: progress)
        onBegin(id)
        onProgress(progress)
        let connected = await operation()
        finish(id, connected: connected)
        return progress
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

    func recordPostAckFailure(_ details: NativePostAckFailureDetails) {
        guard acceptsEvents, attempt != nil else { return }
        progress.postAckFailureStep = details.step
        progress.postAckFailureErrorCode = details.errorCode
        publishProgress()
    }

    func recordFailure(_ error: Error) {
        guard acceptsEvents, attempt != nil else { return }
        progress.failureClass = NativeForegroundConnectProgress.FailureClass.classify(error)
        progress.errorDetails = NativeForegroundConnectErrorDetails(error)
        progress.observedErrorMessage = progress.postAckFailureStep == nil
            ? error.localizedDescription : nil
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
        attempt = nil
        acceptsEvents = false
        if connected {
            progress.lastConfirmedStage = .foregroundConfirmed
            progress.issue = nil
            progress.failureClass = nil
            progress.errorDetails = nil
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
    }


}

/// Presentation of a connection-scoped refusal, never persisted with a thread.
@MainActor
@Observable
final class NativeConversationAvailability {
    enum State: Equatable {
        case unconfirmed
        case available
        case unavailable
    }

    // A missing thread is authoritative only after this profile's refresh confirms chat availability.
    private(set) var confirmedContext: ProfileContext?
    private(set) var unavailableContext: ProfileContext?

    func state(for context: ProfileContext) -> State {
        guard confirmedContext == context else { return .unconfirmed }
        return unavailableContext == context ? .unavailable : .available
    }

    func confirm(for context: ProfileContext, conversationsUnavailable: Bool) {
        confirmedContext = context
        unavailableContext = conversationsUnavailable ? context : nil
    }

    func reset() {
        confirmedContext = nil
        unavailableContext = nil
    }

    func message(for context: ProfileContext) -> String? {
        state(for: context) == .unavailable ? String(localized: "Chat is not available on this server yet.") : nil
    }
}

/// SwiftUI must observe connection confirmation even when a push callback,
/// rather than a view-owned refresh, changes it.
@MainActor
@Observable
private final class NativeRelaySnapshotState {
    var confirmedContext: ProfileContext?
    var failureContext: ProfileContext?
    var failureMessage: String?
}

/// App-owned wake boundary. A future enrollment/profile owner supplies the
/// authenticated installation material and the SAME C store used by live UI.
/// Fixture launch deliberately leaves this unconfigured.
@MainActor
final class NativeRelayLifecycle {
    static let shared = NativeRelayLifecycle()

    private struct PriorityLevelsObserver {
        let context: ProfileContext
        let continuation: AsyncStream<Void>.Continuation
    }

    let conversationAvailability = NativeConversationAvailability()
    let featureFlags = RemoteFeatureFlags()
    private var core: NativeRelayCore? {
        didSet { conversationAvailability.reset() }
    }
    // client_api_v2 is a release gate. B4 removes it with the relay.
    let clientAPIV2Enabled: Bool
    private var v2Connection: ClientAPIv2Connection?
    private var v2FocusChannel: ClientAPIFocusChannel?
    private var v2ShowLookup: Task<Void, Never>?
    private var pendingV2Show: (show: ClientAPIShow, receivedAt: Date)?
    private let v2FocusReporter: NativeFocusReporter
    private let v2ShowCoordinator: NativePushedViewCoordinator
    private var v2ForegroundTask: Task<Void, Never>?
    private var sceneIsActive = false

    var usesClientAPIV2: Bool { v2Connection != nil }

    private var transport: URLSessionInstallationSession?
    private var context: ProfileContext?
    private let snapshotState = NativeRelaySnapshotState()
    private var confirmedRelayContext: ProfileContext? {
        get { snapshotState.confirmedContext }
        set { snapshotState.confirmedContext = newValue }
    }
    private var activeTransportAttemptID: UUID?
    private var focusTransportID: UUID?
    private let foregroundProgress = ForegroundConnectProgressTracker()
    private var priorityLevelsLostTransportAttemptID: UUID?
    private var diagnosticJournal: NativeClientDiagnosticJournal?
    /// The app's Error Log, which the relay components report failures to.
    var errorLog: any ErrorLogging = NoopErrorLog()

    /// The live connection's attempt and whether it may send focus reports,
    /// for tests that follow focus suppression across reconnects.
    var liveConnectionFocusState: (attemptID: UUID?, sendsFocusReports: Bool?) {
        get async { (activeTransportAttemptID, await transport?.sendsFocusReports) }
    }
    private var foregroundDiagnosticContext: ProfileContext?
    private var foregroundDiagnosticOperationsAtStart: [UUID: NativeForegroundOperationDiagnostic] = [:]
    private var foregroundDiagnosticIntentIDs: [UUID: UUID] = [:]
    private var foregroundDiagnosticSnapshotAvailable = false
    private var foregroundDiagnosticAttemptID = UUID()
    private var foregroundDiagnosticOperations = NativeForegroundOperationSnapshot.unavailable
    private var priorityLevelsObservers: [UUID: PriorityLevelsObserver] = [:]
    private var configuration: (store: ClientRepository,
                                context: ProfileContext,
                                relayURL: URL,
                                identity: SecIdentity,
                                rootDER: Data,
                                serverStateCache: (any ServerStateCaching)?)?
    private var answerFlights: [UUID: (token: UUID, task: Task<Void, Error>)] = [:]
    private var reconnectFlight: (token: UUID, task: Task<Void, Error>)?
    private var discussionFlights: [UUID: (token: UUID, task: Task<DiscussionOperationResult, Error>)] = [:]
    private var discussionTransports: [UUID: URLSessionInstallationSession] = [:]
    private var fileTransports: [UUID: URLSessionInstallationSession] = [:]
    private var awaitingFirstConnection = false
    private var refreshGeneration = UUID()
    private var pathMonitor: NWPathMonitor?
    private var hasObservedInitialPath = false
    private var connectionHealthTask: Task<Void, Never>?
    private var connectionRecoveryTask: Task<Void, Never>?
    private var connectionHealthCheckID: UUID?
    private lazy var refreshFlights = RelayRefreshFlights(inactive: NativeRelayRefreshResult.unavailable) { [weak self] in
        guard let self else { return .unavailable }
        return await self.performRefresh(generation: self.refreshGeneration)
    }
    private let enrollment = NativeEnrollmentStore()

    init(clientAPIV2Enabled: Bool = false, v2FocusReporter: NativeFocusReporter = .shared,
         v2ShowCoordinator: NativePushedViewCoordinator = .shared) {
        self.clientAPIV2Enabled = clientAPIV2Enabled
        self.v2FocusReporter = v2FocusReporter
        self.v2ShowCoordinator = v2ShowCoordinator
    }

    func v2FocusScenePhaseChanged(_ phase: ScenePhase) {
        guard clientAPIV2Enabled else { return }
        v2FocusReporter.scenePhaseChanged(phase)
    }

    func sceneActivityChanged(isActive: Bool) {
        guard clientAPIV2Enabled else { return }
        sceneIsActive = isActive
        if isActive {
            startV2Foreground()
        } else {
            v2ForegroundTask?.cancel()
        }
    }

    private func startV2Foreground() {
        guard sceneIsActive, let connection = v2Connection, v2ForegroundTask == nil else { return }
        v2ForegroundTask = Task { [weak self] in
            await connection.runForeground()
            guard let self, self.v2Connection === connection else { return }
            self.v2ForegroundTask = nil
            // A foreground transition may arrive before the cancelled feed exits.
            if Task.isCancelled { self.startV2Foreground() }
        }
    }

    private static func v2Directory(for identity: ProfileIdentity) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let key = [identity.trustedRelayAuthority.rawValue, identity.personID.rawValue, identity.deviceID.rawValue]
            .joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("ClientAPIv2", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }



    private func observeNetworkPath(generation: UUID) {
        pathMonitor?.cancel()
        connectionHealthTask?.cancel()
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
        connectionHealthCheckID = nil
        hasObservedInitialPath = false
        // This is check cadence, never a catch-up or pong deadline. A healthy
        // peer may keep replay open across any number of these checks.
        connectionHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                guard let self, self.refreshGeneration == generation else { return }
                await self.checkConnectionHealth(allowReconnect: true, generation: generation)
            }
        }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                await self?.networkPathChanged(available: available, generation: generation)
            }
        }
        monitor.start(queue: DispatchQueue(label: "Harklight.relay-network-path"))
    }

    private func networkPathChanged(available: Bool, generation: UUID) async {
        guard refreshGeneration == generation else { return }
        // The first callback describes the current path, not a network change.
        guard hasObservedInitialPath else { hasObservedInitialPath = true; return }
        await checkConnectionHealth(allowReconnect: available, generation: generation)
    }

    private func checkConnectionHealth(allowReconnect: Bool, generation: UUID) async {
        guard refreshGeneration == generation, let current = transport,
              connectionHealthCheckID == nil else { return }
        let checkID = UUID()
        connectionHealthCheckID = checkID
        defer {
            if connectionHealthCheckID == checkID { connectionHealthCheckID = nil }
        }
        do {
            try await current.checkConnection()
            // A healthy pong is not a new delivery opportunity. Recovery is
            // triggered by launch, refresh, or a replacement connection, not
            // by the periodic health-check cadence.
        } catch {
            guard refreshGeneration == generation, allowReconnect,
                  connectionRecoveryTask == nil else { return }
            // A failed ping unblocks the current replay with its actual error.
            // Serialize replacement after that replay saves its validated prefix.
            // Recovery must not occupy the health cadence: the replacement replay
            // can also be long-running and still needs independent pings.
            connectionRecoveryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.refreshGeneration == generation { self.connectionRecoveryTask = nil }
                }
                _ = await self.refreshFlights.afterCurrent { [weak self] in
                    guard let self, self.refreshGeneration == generation else { return .unavailable }
                    do {
                        try await self.reconnect(replacing: current, generation: generation)
                    } catch { return .failed(error: error) }
                    return await self.performRefresh(generation: generation)
                }
            }
        }
    }

    private func focusReportingReadyHandler(generation: UUID,
                                            transportID: UUID) -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.refreshGeneration == generation,
                      self.focusTransportID == transportID else { return }
                NativeFocusReporter.shared.relaySessionBecameReady(transportID)
            }
        }
    }

    private func focusReportingUnsupportedHandler(generation: UUID,
                                                  transportID: UUID) -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.refreshGeneration == generation,
                      self.focusTransportID == transportID else { return }
                // The refusal ends focus reports on this connection only. Each
                // new relay session sends the current focus again, so a Server
                // that gains support (or a supported session) gets it.
                NativeFocusReporter.shared.relaySessionDoesNotSupportFocus(transportID)
            }
        }
    }

    private func viewShowHandler(generation: UUID,
                                 transportID: UUID) -> @Sendable (Data) -> Void {
        { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self,
                      self.refreshGeneration == generation,
                      self.focusTransportID == transportID else { return }
                NativePushedViewCoordinator.shared.receive(data)
            }
        }
    }

    private func installFocusReportHandler(for session: URLSessionInstallationSession?,
                                           transportID: UUID?) {
        guard let session, let transportID else {
            NativeFocusReporter.shared.installReportHandler(for: nil, handler: nil)
            return
        }
        NativeFocusReporter.shared.installReportHandler(for: transportID) { report in
            await session.sendFocusReport(report)
        }
    }

    func activate(store: ClientRepository,
                  context: ProfileContext,
                  relayURL: URL,
                  clientIdentity: SecIdentity,
                  trustedRootDER: Data,
                  diagnostics: NativeClientDiagnosticJournal? = nil,
                  serverStateCache: (any ServerStateCaching)? = nil,
                  awaitingFirstConnection: Bool = false) async throws {
        if clientAPIV2Enabled {
            try activateV2(store: store, context: context, relayURL: relayURL,
                           clientIdentity: clientIdentity, trustedRootDER: trustedRootDER)
            return
        }
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
                                                              serverMatchedPushRoutingEnabled: pushRoutingEnabledHandler(),
                                                              onProgress: progressHandler(generation: generation,
                                                                                          transportAttemptID: transportAttemptID),
                                                              onFocusReportingReady: focusReportingReadyHandler(
                                                                generation: generation,
                                                                transportID: transportAttemptID),
                                                              onFocusReportingUnsupported: focusReportingUnsupportedHandler(
                                                                generation: generation,
                                                                transportID: transportAttemptID),
                                                              onViewShow: viewShowHandler(
                                                                generation: generation,
                                                                transportID: transportAttemptID),
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
                                           automaticallySendsPendingOperations: false,
                                           attemptID: transportAttemptID,
                                           serverStateCache: serverStateCache,
                                           onProgress: progressHandler(generation: generation,
                                                                       transportAttemptID: transportAttemptID),
                                           onPriorityLevelsChanged: priorityLevelsChangeHandler(for: context),
                                           onPriorityLevelsConnectionLost: priorityLevelsConnectionLostHandler(
                                               for: context, transportAttemptID: transportAttemptID),
                                           onPriorityLevelsFeatureEnabled: priorityLevelsFeatureEnabledHandler(),
                                           onDiagnostic: diagnosticSink(),
                                           onFeatureFlags: featureFlagsHandler(connectionID: transportAttemptID), errorLog: errorLog)
        } catch {
            recordDiagnostic(.connection, .approvedConnection, .failed, error: error,
                             attemptID: transportAttemptID, transportAttemptID: transportAttemptID)
            await nextTransport.close()
            throw error
        }
        featureFlags.reset()
        refreshGeneration = generation
        refreshFlights.reset()
        foregroundProgress.beginSession(transportAttemptID: transportAttemptID)
        let priorCore = core
        let priorTransport = transport
        if priorTransport != nil, let priorContext = self.context, priorContext != context {
            await NativeFocusReporter.shared.accountConnectionWillBeRemoved()
        }
        core = nil
        transport = nil
        self.context = nil
        await stopMutationFlights()
        snapshotState.failureContext = nil
        snapshotState.failureMessage = nil
        confirmedRelayContext = nil
        priorityLevelsLostTransportAttemptID = nil
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
        focusTransportID = transportAttemptID
        featureFlags.connect(context: context, connectionID: transportAttemptID)
        installFocusReportHandler(for: nextTransport, transportID: transportAttemptID)
        configuration = (store, context, relayURL, clientIdentity, trustedRootDER, serverStateCache)
        self.awaitingFirstConnection = awaitingFirstConnection
        observeNetworkPath(generation: generation)
        resumeSavedAnswers()
        resumeSavedDiscussions()
    }

    private func activateV2(store: ClientRepository, context: ProfileContext, relayURL: URL,
                            clientIdentity: SecIdentity, trustedRootDER: Data) throws {
        guard let baseURL = ClientAPIv2Endpoint.baseURL(fromRelayURL: relayURL) else {
            throw InstallationTransportError.invalidEndpoint
        }
        let transport = try HTTPSClientAPITransport(baseURL: baseURL,
            clientIdentity: TrustedKeychainIdentity(clientIdentity), trustedRootDER: trustedRootDER)
        let retainedFiles = try ConversationFileStorage(identity: context.identity)
        let attempt = UUID()
        let focus = ClientAPIFocusChannel(transport: transport, errors: errorLog) { [weak self] show, receivedAt in
            await self?.receiveV2Show(show, receivedAt: receivedAt, attempt: attempt)
        }
        let connection = try ClientAPIv2Connection(transport: transport, repository: store, context: context,
            directory: Self.v2Directory(for: context.identity), errors: errorLog, foregroundOnlyWrites: true,
            retainedUploadURL: { try retainedFiles.verifiedUploadURL(for: $0) },
            onLiveState: { [weak self] state in
                guard state == .live else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.activeTransportAttemptID == attempt else { return }
                    self.confirmedRelayContext = context
                }
            }, onShow: { data in
                await focus.received(feedShow: data)
            }, onPublished: { [weak self] in
                Task { @MainActor [weak self] in self?.deliverV2ShowIfHydrated(attempt: attempt) }
            })
        installV2Connection(connection, context: context, attempt: attempt)
        installV2FocusChannel(focus, attempt: attempt)
    }

    func installV2Connection(_ connection: ClientAPIv2Connection, context: ProfileContext, attempt: UUID = UUID()) {
        guard clientAPIV2Enabled, v2Connection == nil else { return }
        self.context = context
        activeTransportAttemptID = attempt
        v2Connection = connection
        startV2Foreground()
    }

    func installV2FocusChannel(_ focus: ClientAPIFocusChannel, attempt: UUID) {
        guard clientAPIV2Enabled, activeTransportAttemptID == attempt, v2Connection != nil else { return }
        v2FocusChannel = focus
        v2FocusReporter.installReportHandler(for: attempt) { report in
            // The channel may return the last drained reply, so this sender
            // does not treat a reply as acknowledgement of an individual write.
            if report.screen == .signedOut {
                _ = await focus.report(report)
            } else {
                await focus.enqueue(report)
            }
        }
        v2FocusReporter.relaySessionBecameReady(attempt)
    }

    func receiveV2Show(_ show: ClientAPIShow, receivedAt: Date, attempt: UUID) {
        guard activeTransportAttemptID == attempt, let connection = v2Connection,
              context?.identity.deviceID.rawValue == show.deviceID else { return }
        v2ShowLookup?.cancel()
        v2ShowCoordinator.supersedePendingShow()
        pendingV2Show = (show, receivedAt)
        if connection.model.snapshot.items[ExactText(show.itemID)] != nil {
            deliverV2ShowIfHydrated(attempt: attempt)
            return
        }
        // The item lookup is an independent request; a slow read must not
        // block a focus PUT or consumption of the change feed.
        v2ShowLookup = Task { [weak self] in
            let notFound: Bool
            do {
                notFound = try await connection.resolveShowItem(itemID: ExactText(show.itemID)) == nil
            } catch {
                notFound = (error as? APIError)?.status == 404
            }
            guard let self, !Task.isCancelled, self.activeTransportAttemptID == attempt,
                  self.pendingV2Show?.show.showID == show.showID else { return }
            if connection.model.snapshot.items[ExactText(show.itemID)] != nil {
                self.deliverV2ShowIfHydrated(attempt: attempt)
            } else {
                if notFound { self.pendingV2Show = nil }
                self.v2ShowCoordinator.receiveV2(.clientAPIUnavailable(show, notFound: notFound),
                    elapsedSinceReceipt: max(0, Date().timeIntervalSince(receivedAt)))
            }
        }
    }

    func deliverV2ShowIfHydrated(attempt: UUID) {
        guard activeTransportAttemptID == attempt, let pending = pendingV2Show,
              let item = v2Connection?.model.snapshot.items[ExactText(pending.show.itemID)] else { return }
        pendingV2Show = nil
        v2ShowCoordinator.receiveV2(.clientAPI(pending.show, senderID: item.sender.rawValue),
            elapsedSinceReceipt: max(0, Date().timeIntervalSince(pending.receivedAt)))
    }

    func sendV2QueuedReply(_ message: ConversationDraft, expected: ProfileContext) async {
        guard let connection = v2Connection, context == expected else { return }
        do {
            try await connection.queuedReplyWasSaved(message)
        } catch {
            errorLog.report(ErrorLogReport(concern: .actions, connectionRole: .request,
                operation: "reply", phase: "queue", reason: .from(error: error),
                initiator: .unknown, retryable: true))
        }
    }

    func v2QueuedReplyWasEdited(_ operation: UUID, expected: ProfileContext) async {
        guard let connection = v2Connection, context == expected else { return }
        await connection.queuedReplyWasEdited(operation)
    }

    func cancelV2QueuedAttachmentReply(_ operation: UUID, for key: RequestKey,
                                       expected: ProfileContext) async throws {
        guard let connection = v2Connection, context == expected else { throw NativeRelayCoreError.inactive }
        try await connection.cancelQueuedAttachmentReply(operation, request: key)
    }

    @discardableResult
    func loadV2EntriesOnOpen(_ key: RequestKey, expected: ProfileContext) async -> Bool {
        guard let connection = v2Connection, context == expected,
              key.accountScope == expected.identity.personID else { return true }
        do {
            try await connection.loadEntriesIfNeeded(itemID: key.messageID)
            return true
        } catch is CancellationError {
            return false
        } catch {
            let reason: ErrorLogReason = error is ServerModelV2Store.SupersededGeneration
                ? .app("snapshot_superseded") : .from(error: error)
            errorLog.report(ErrorLogReport(concern: .snapshot, connectionRole: .request,
                operation: "load_entries", phase: "read", reason: reason,
                initiator: .unknown, retryable: true))
            return false
        }
    }

    func refreshV2ForPush(_ payload: JSONValue, enrollment: NativeEnrollmentRecord) async -> Bool {
        guard clientAPIV2Enabled, let connection = v2Connection, let context,
              let revision = NativeV2PushWake.revision(payload, enrollment: enrollment,
                                                       identity: context.identity) else { return false }
        do {
            let changed = try await connection.catchUp(forPushRevision: revision)
            return v2Connection === connection && changed
        } catch {
            // Sync records transport failures with its Request-Id.
            return false
        }
    }

    func checkAcceptedV2Reply(_ key: RequestKey, expected: ProfileContext) async {
        guard sceneIsActive, let connection = v2Connection, context == expected,
              key.accountScope == expected.identity.personID else { return }
        await connection.checkAcceptedReply(itemID: key.messageID)
    }

    func v2LocatorForPush(_ payload: JSONValue) async -> NativeNotificationLocator? {
        guard clientAPIV2Enabled, let connection = v2Connection, let context,
              let record = try? enrollment.load(),
              NativeV2PushWake.revision(payload, enrollment: record, identity: context.identity) != nil,
              let server = record.serverID,
              let locator = payload.uniqueValue(named: "attention")?.uniqueValue(named: "locator"),
              let itemID = locator.uniqueValue(named: "item_id")?.stringValue,
              let binding = locator.uniqueValue(named: "binding_id")?.stringValue else { return nil }
        _ = await refreshV2ForPush(payload, enrollment: record)
        guard v2Connection === connection, let item = connection.model.snapshot.items[itemID] else { return nil }
        let request = ServerModelV2Projection.key(for: itemID, sender: item.sender, identity: context.identity)
        return NativeNotificationLocator(v2Request: request, bindingID: binding,
            deviceID: context.identity.deviceID, serverID: server,
            target: locator.uniqueValue(named: "target")?.stringValue?.rawValue)
    }

    func refreshForRemotePush(_ payload: JSONValue?) async -> Bool {
        if !clientAPIV2Enabled { return await refreshFromTrustedRelay() }
        guard let payload, let record = try? enrollment.load() else { return false }
        return await refreshV2ForPush(payload, enrollment: record)
    }

    private func stopMutationFlights() async {
        for flight in answerFlights.values { flight.task.cancel() }
        for flight in discussionFlights.values { flight.task.cancel() }
        let sessions = Array(discussionTransports.values) + Array(fileTransports.values)
        answerFlights.removeAll()
        discussionFlights.removeAll()
        discussionTransports.removeAll()
        fileTransports.removeAll()
        for session in sessions { await session.close() }
    }

    func removePushBeforeDeparture(for record: NativeEnrollmentRecord,
                                   enrollment: NativeEnrollmentStore) async {
        guard featureFlags.isEnabled(.serverMatchedPushRouting) else { return }
        guard let transport, let context, record.matchesNotificationIdentity(context.identity) else {
            recordDiagnostic(.notifications, .pushRegistration, .failed, error: NativeRelayCoreError.inactive)
            return
        }
        do {
            try await enrollment.retryPendingPushRemoval(using: transport)
        } catch {
            recordDiagnostic(.notifications, .pushRegistration, .failed, error: error,
                             attemptID: activeTransportAttemptID)
        }
    }

    func deactivate() async {
        let v2Task = v2ForegroundTask
        let focus = v2FocusChannel
        v2FocusChannel = nil
        v2ShowLookup?.cancel()
        v2ShowLookup = nil
        pendingV2Show = nil
        v2ForegroundTask = nil
        v2Connection = nil
        v2Task?.cancel()
        featureFlags.reset()
        pathMonitor?.cancel()
        pathMonitor = nil
        connectionHealthTask?.cancel()
        connectionHealthTask = nil
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
        connectionHealthCheckID = nil
        hasObservedInitialPath = false
        refreshGeneration = UUID()
        refreshFlights.reset()
        let priorCore = core
        let priorTransport = transport
        if let focus {
            await v2FocusReporter.accountConnectionWillBeRemoved()
            await focus.stop()
        } else {
            await NativeFocusReporter.shared.accountConnectionWillBeRemoved()
        }
        core = nil
        transport = nil
        context = nil
        await stopMutationFlights()
        snapshotState.failureContext = nil
        snapshotState.failureMessage = nil
        confirmedRelayContext = nil
        activeTransportAttemptID = nil
        focusTransportID = nil
        installFocusReportHandler(for: nil, transportID: nil)
        priorityLevelsLostTransportAttemptID = nil
        configuration = nil
        foregroundDiagnosticContext = nil
        foregroundDiagnosticOperationsAtStart = [:]
        foregroundDiagnosticIntentIDs = [:]
        foregroundDiagnosticSnapshotAvailable = false
        foregroundDiagnosticAttemptID = UUID()
        foregroundDiagnosticOperations = .unavailable
        diagnosticJournal = nil
        if let priorCore { await priorCore.deactivate() }
        if let priorTransport { await priorTransport.close() }
        await v2Task?.value
    }

    /// APNs data is a wake hint only. The payload cannot choose account,
    /// sender, message, cursor, operation or answer.
    @discardableResult
    /// Whether the relay is currently configured for this account context.
    func isActive(for expected: ProfileContext) -> Bool { context == expected }

    func refreshFromTrustedRelay() async -> Bool {
        return await refreshResultFromTrustedRelay().relayConfirmed
    }

    func refreshResultFromTrustedRelay(checkBlockedPush: Bool = false) async -> NativeRelayRefreshResult {
        if let connection = v2Connection, let context {
            let attempt = activeTransportAttemptID
            do {
                try await connection.catchUp()
                guard v2Connection === connection else { return .unavailable }
                confirmedRelayContext = context
                return NativeRelayRefreshResult(relayConfirmed: true, pushRegistration: .notAttempted,
                    confirmedContext: context, confirmedTransportAttemptID: attempt)
            } catch {
                guard v2Connection === connection else { return .unavailable }
                return .failed(error: error)
            }
        }
        if checkBlockedPush {
            return await refreshFlights.afterCurrent { [weak self] in
                guard let self else { return .unavailable }
                return await self.performRefresh(generation: self.refreshGeneration,
                                                 checkBlockedPush: true)
            }
        }
        return await refreshFlights.coalesced()
    }

    /// Attempts durable message-open reports on the current authenticated
    /// relay session. With no active session, the store keeps them for the
    /// ordinary reconnect drain.
    func sendPendingMessageOpens() async {
        _ = await core?.sendPendingMessageOpens()
    }

    func hasConfirmedPriorityLevelsRelay(for expected: ProfileContext) -> Bool {
        guard featureFlags.isEnabled(.priorityLevelEditing) else { return false }
        guard let activeTransportAttemptID else { return false }
        return confirmedRelayContext == expected && context == expected && core != nil &&
            priorityLevelsLostTransportAttemptID != activeTransportAttemptID
    }

    func refreshPriorityLevels(expected: ProfileContext) async {
        guard featureFlags.isEnabled(.priorityLevelEditing),
              hasConfirmedPriorityLevelsRelay(for: expected), let core else { return }
        await core.refreshPriorityLevels()
    }

    func sendPendingPriorityLevelsSave(expected: ProfileContext) async {
        guard featureFlags.isEnabled(.priorityLevelEditing),
              hasConfirmedPriorityLevelsRelay(for: expected), let core else { return }
        await core.sendPendingPriorityLevelsSave()
    }

    private var priorityLevelsFeatureEnabled: Bool {
        featureFlags.isEnabled(.priorityLevelEditing)
    }

    private func priorityLevelsFeatureEnabledHandler() -> @Sendable () async -> Bool {
        { [weak self] in
            guard let self else { return false }
            return await self.priorityLevelsFeatureEnabled
        }
    }

    func priorityLevelsUpdates(for expected: ProfileContext) -> AsyncStream<Void> {
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            priorityLevelsObservers[observerID] = PriorityLevelsObserver(context: expected,
                                                                         continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.priorityLevelsObservers.removeValue(forKey: observerID)
                }
            }
        }
    }

    private func priorityLevelsChangeHandler(for expected: ProfileContext) -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                self?.publishPriorityLevelsUpdate(for: expected)
            }
        }
    }

    private func priorityLevelsConnectionLostHandler(for expected: ProfileContext,
                                                      transportAttemptID: UUID) -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.context == expected,
                      self.activeTransportAttemptID == transportAttemptID else { return }
                self.priorityLevelsLostTransportAttemptID = transportAttemptID
                self.publishPriorityLevelsUpdate(for: expected)
            }
        }
    }

    private func publishPriorityLevelsUpdate(for changedContext: ProfileContext) {
        for observer in priorityLevelsObservers.values where observer.context == changedContext {
            observer.continuation.yield(())
        }
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
                                   checkBlockedPush: Bool = false,
                                   onProgress: @escaping @MainActor (NativeForegroundConnectProgress) -> Void = { _ in }) async -> NativeForegroundConnectProgress {
        guard context == expected else {
            let failed = foregroundProgress.finishWithoutAttempt(
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
        let diagnosticAttemptID = UUID()
        foregroundDiagnosticAttemptID = diagnosticAttemptID
        foregroundDiagnosticOperations = .unavailable
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
        // Prepare operation receipts away from the main actor before delivering
        // each progress update. The UI's synchronous diagnostic accessor then
        // reads this prepared value instead of waiting on the store writer.
        var progressDelivery: Task<Void, Never>?
        let deliverProgress: @MainActor (NativeForegroundConnectProgress) -> Void = { [weak self] progress in
            let priorDelivery = progressDelivery
            progressDelivery = Task { @MainActor [weak self] in
                await priorDelivery?.value
                guard let self, self.foregroundDiagnosticAttemptID == diagnosticAttemptID,
                      self.context == expected else { return }
                let operations = await self.prepareForegroundOperationDiagnostics(for: expected)
                guard self.foregroundDiagnosticAttemptID == diagnosticAttemptID,
                      self.context == expected else { return }
                self.foregroundDiagnosticOperations = operations
                onProgress(progress)
            }
        }
        let result = await foregroundProgress.run(operation: { [weak self] in
            guard let self else { return false }
            let refresh = await self.refreshResultFromTrustedRelay(
                checkBlockedPush: checkBlockedPush)
            let relayConfirmed = refresh.relayConfirmed
            let generationMatches = self.refreshGeneration == epoch
            let profileMatches = self.context == expected
            let relayContextMatches = refresh.confirms(expected, transportAttemptID: self.activeTransportAttemptID)
            guard self.foregroundProgress.progress.outcome == .connecting else { return false }
            let beforeValidation = self.foregroundProgress.progress
            let postAckReached = beforeValidation.lastCompletedPostAckBoundary != .none || relayConfirmed
            self.foregroundProgress.recordPostAckCompletion(
                postAckReached: postAckReached,
                relayRefreshConfirmed: relayConfirmed,
                generationMatches: generationMatches,
                profileMatches: profileMatches,
                relayContextMatches: relayContextMatches)
            let reached = relayConfirmed && generationMatches && profileMatches && relayContextMatches
            let terminalProgress = self.foregroundProgress.progress
            self.recordDiagnosticEvents(Self.foregroundTerminalDiagnosticEvents(
                progress: terminalProgress, confirmed: reached,
                fallbackTransportAttemptID: self.activeTransportAttemptID,
                generationMatches: generationMatches, profileMatches: profileMatches,
                relayContextMatches: relayContextMatches))
            return reached
        }, onBegin: { [weak self] foregroundAttemptID in
            self?.recordDiagnostic(.connection, .approvedConnection, .began,
                                   attemptID: foregroundAttemptID,
                                   transportAttemptID: self?.activeTransportAttemptID)
        }, onProgress: deliverProgress)
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
        await progressDelivery?.value
        if result.outcome == .confirmed { awaitingFirstConnection = false }
        return result
    }

    func foregroundOperationDiagnostics(for expected: ProfileContext) -> NativeForegroundOperationSnapshot {
        guard foregroundDiagnosticContext == expected, context == expected else { return .unavailable }
        return foregroundDiagnosticOperations
    }

    private func prepareForegroundOperationDiagnostics(for expected: ProfileContext) async -> NativeForegroundOperationSnapshot {
        guard foregroundDiagnosticContext == expected, context == expected,
              foregroundDiagnosticSnapshotAvailable,
              let configuration, configuration.context == expected else {
            return .unavailable
        }
        guard !foregroundDiagnosticOperationsAtStart.isEmpty else {
            return NativeForegroundOperationSnapshot(available: true, operations: [])
        }
        let store = configuration.store
        let initialOperations = foregroundDiagnosticOperationsAtStart
        let intentIDs = foregroundDiagnosticIntentIDs
        let transportAttemptID = activeTransportAttemptID
        let (snapshot, failures) = await Task.detached(priority: .utility) {
            var failures: [NativeClientDiagnosticEvent] = []
            let operations = initialOperations.values.map { initial in
                let unknown = NativeForegroundOperationDiagnostic(operationID: initial.operationID,
                    senderID: initial.senderID, messageID: initial.messageID,
                    requestRevision: initial.requestRevision, receiptState: "unknown_after_attempt")
                guard let intentID = intentIDs[initial.operationID] else { return unknown }
                do {
                    guard let submission = try store.lookupIntent(intentID, context: expected) else { return unknown }
                    return NativeForegroundOperationDiagnostic(operationID: initial.operationID,
                        senderID: initial.senderID, messageID: initial.messageID,
                        requestRevision: initial.requestRevision,
                        receiptState: Self.receiptState(for: submission.disposition))
                } catch {
                    failures.append(NativeClientDiagnosticEvent(area: .localStore, phase: .projectionRefresh,
                        transition: NativeDiagnosticCauseCode.failureTransition(for: error),
                        causeCode: NativeDiagnosticCauseCode.forError(error),
                        attemptID: transportAttemptID, transportAttemptID: transportAttemptID,
                        operationID: initial.operationID, requestRevision: initial.requestRevision,
                        receiptState: .unknown))
                    return unknown
                }
            }.sorted { $0.operationID.uuidString < $1.operationID.uuidString }
            return (NativeForegroundOperationSnapshot(available: true, operations: operations), failures)
        }.value
        recordDiagnosticEvents(failures)
        return snapshot
    }

    nonisolated private static func receiptState(for disposition: IntentDisposition) -> String {
        switch disposition {
        case .pending: "pending_unconfirmed"
        case let .accepted(sequence): "relay_accepted_sequence_\(sequence.map { String($0) } ?? "unknown")_awaiting_terminal_state"
        case .lost: "locally_lost_unconfirmed"
        case .failed: "not_delivered"
        case .refusedClosed: "request_closed"
        case .refusedNotFound: "request_not_found"
        case let .staleRevision(currentRevision): "stale_revision_current_\(currentRevision)"
        case let .terminal(state, sequence, _): "terminal_\(state.rawValue)_sequence_\(sequence)"
        case let .refusedByRetraction(retractedAt): "refused_retracted_at_\(retractedAt)"
        case .unsupported: "unsupported"
        case .repairRequired: "repair_required"
        }
    }

    private static func isUnresolved(_ submission: Submission,
                                     remoteStates: [RequestKey: RemoteRequestState]) -> Bool {
        guard remoteStates[submission.requestKey]?.isTerminal != true else { return false }
        if case .terminal = submission.disposition { return false }
        if case .unsupported = submission.disposition { return false }
        if case .failed = submission.disposition { return false }
        if case .refusedClosed = submission.disposition { return false }
        if case .refusedNotFound = submission.disposition { return false }
        if case .staleRevision = submission.disposition { return false }
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

    func hasConfirmedServerSnapshot(for expected: ProfileContext) -> Bool {
        // Read the observable value first, including before activation.
        confirmedRelayContext == expected && context == expected
    }

    func refreshFailureMessage(for expected: ProfileContext) -> String? {
        guard snapshotState.failureContext == expected, context == expected else { return nil }
        return snapshotState.failureMessage
    }

    /// A send joins only the same saved intent's flight, never the catch-up flight.
    func sendOriginalOperationForUserTap(_ intentID: UUID,
                                         expected: ProfileContext,
                                         onSendCallStateChange: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
                                         onSendCallCompleted: @MainActor () -> Void = {}) async throws {
        guard context == expected, let configuration else {
            throw NativeRelayCoreError.inactive
        }
        if let existing = answerFlights[intentID] {
            try await existing.task.value
            onSendCallCompleted()
            return
        }
        let token = UUID()
        let flight = Task { @MainActor [self] in
            // The Server keeps one relay session per device and closes the
            // others whenever a new one opens, so a submission goes on the live
            // connection. A second connection would close the live one and
            // restart its catch-up.
            guard context == expected, !Task.isCancelled, let core, let transport else {
                throw NativeRelayCoreError.inactive
            }
            try await core.sendOriginalOperationForUserTap(intentID, using: transport,
                onSendCallStateChange: { sending in onSendCallStateChange(sending) })
        }
        answerFlights[intentID] = (token, flight)
        defer {
            if answerFlights[intentID]?.token == token { answerFlights.removeValue(forKey: intentID) }
            onSendCallCompleted()
        }
        try await flight.value
        // Only a receipt calls for immediate reconciliation. An unresolved
        // transport waits for a launch/refresh/reconnect trigger rather than
        // recursively creating refresh/send attempts.
        if case .accepted = try configuration.store.snapshot(context: expected).intents[intentID]?.disposition {
            Task { [weak self] in _ = await self?.refreshResultFromTrustedRelay() }
        }
    }

    private func resumeSavedAnswers() {
        guard let expected = context, let configuration else { return }
        do {
            try configuration.store.queueRecoverableOperations(context: expected)
            let pending = try configuration.store.snapshot(context: expected).outbox
            for operation in pending where answerFlights[operation.intentID] == nil {
                Task { [weak self] in
                    guard let self else { return }
                    do { _ = try await self.sendOriginalOperationForUserTap(operation.intentID, expected: expected) }
                    catch {
                        self.recordDiagnostic(.answer, .originalOperationDelivery, .unresolved,
                            error: error, attemptID: self.activeTransportAttemptID)
                    }
                }
            }
        } catch {
            recordDiagnostic(.localStore, .originalOperationDelivery, .failed, error: error)
        }
    }

    @discardableResult
    func fetchNextInboxPage() async -> Bool {
        guard let core, let context else { return false }
        do {
            let fetched = try await core.fetchNextInboxPage()
            guard self.context == context else { return false }
            return fetched
        } catch {
            recordDiagnostic(.relay, .ordinaryReplay,
                NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                attemptID: activeTransportAttemptID)
            if NativeRelayCoreError.isInvalidSavedServerState(error), self.context == context {
                // The core has discarded the saved state that no longer
                // validates. Rebuild it from the Server on a fresh connection
                // instead of leaving older pages unloadable.
                let generation = refreshGeneration
                Task { [weak self] in
                    guard let self, self.refreshGeneration == generation else { return }
                    _ = await self.refreshFlights.afterCurrent { [weak self] in
                        guard let self, self.refreshGeneration == generation else { return .unavailable }
                        do { try await self.reconnect(replacing: nil, generation: generation) }
                        catch { return .failed(error: error) }
                        return await self.performRefresh(generation: generation)
                    }
                }
            }
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
                          retainedFile: @escaping @Sendable (ConversationFile) async throws -> URL) async throws -> DiscussionOperationResult {
        guard context == expected, let configuration else {
            throw NativeRelayCoreError.inactive
        }
        let pending = try configuration.store.conversationSnapshot(context: expected)
            .threads[binding.request]?.drafts[binding.revision]
        if case let .acceptedPendingReplay(_, turn) = pending?.disposition { return .accepted(turnID: turn) }
        let operation = try configuration.store.prepareDiscussion(binding, context: expected)
        if let existing = discussionFlights[operation] { return try await existing.task.value }
        let token = UUID()
        let flight = Task { @MainActor [self] in
            guard context == expected, !Task.isCancelled else {
                throw NativeRelayCoreError.inactive
            }
            // One relay session per device (see sendOriginalOperationForUserTap):
            // the discussion goes on the live connection, and the file origin
            // comes from the live conversation catch-up rather than a second
            // connection.
            guard let core, let transport else { throw NativeRelayCoreError.inactive }
            let endpoint = try await core.conversationOriginURL()
            if pending?.wireFrame == nil, pending?.files.isEmpty == false, endpoint == nil {
                // Saved, not rejected: the next refresh opens the conversation
                // catch-up, which reports the origin, and resumes this discussion.
                try configuration.store.markDiscussionOutcome(binding, operation: operation,
                    rejection: nil, context: expected)
                return DiscussionOperationResult.unresolved
            }
            guard context == expected, !Task.isCancelled else { throw NativeRelayCoreError.inactive }
            return try await core.submitDiscussion(binding, using: transport,
                originURL: endpoint, retainedFile: retainedFile)
        }
        discussionFlights[operation] = (token, flight)
        defer {
            if discussionFlights[operation]?.token == token {
                discussionFlights.removeValue(forKey: operation)
                discussionTransports.removeValue(forKey: operation)
            }
        }
        let result = try await flight.value
        if case .accepted = result {
            Task { [weak self] in _ = await self?.refreshResultFromTrustedRelay() }
        }
        return result
    }

    private func resumeSavedDiscussions() {
        guard let expected = context, let configuration else { return }
        do {
            let files = try ConversationFileStorage(identity: expected.identity)
            let threads = try configuration.store.conversationSnapshot(context: expected).threads
            for thread in threads.values {
                for draft in thread.drafts.values {
                    let operation: UUID
                    switch draft.disposition {
                    case let .submitting(id), let .outcomeUnknown(id): operation = id
                    case .saved, .rejected, .acceptedPendingReplay: continue
                    }
                    guard discussionFlights[operation] == nil,
                          thread.uploadGroups?[operation]?.cleanupID == nil else { continue }
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            _ = try await self.submitDiscussion(draft.binding, expected: expected) {
                                try files.fileURL(for: $0)
                            }
                        } catch {
                            self.recordDiagnostic(.conversation, .discussionSubmission, .unresolved, error: error)
                        }
                    }
                }
            }
        } catch {
            recordDiagnostic(.localStore, .discussionSubmission, .failed, error: error)
        }
    }

    func sendPendingConversationReadPositions(expected: ProfileContext) async {
        guard context == expected, let core else { return }
        await core.sendPendingConversationReadPositions()
        guard context == expected else { return }
    }

    func discardAbandonedUploads(for request: RequestKey, expected: ProfileContext) async throws {
        guard context == expected, let core else { throw NativeRelayCoreError.inactive }
        // Do not wait for the active send flight: departure fences its upload.
        try await core.discardAbandonedUploads(for: request)
        guard context == expected else { throw NativeRelayCoreError.inactive }
    }

    func fetchConversationFile(_ file: ConversationFile, to destination: URL, expected: ProfileContext) async throws {
        guard context == expected else { throw NativeRelayCoreError.inactive }
        if case let .v2Download(id) = file.content {
            guard let connection = v2Connection else { throw NativeRelayCoreError.inactive }
            let bytes = try await connection.files.download(id)
            try Task.checkCancellation()
            guard context == expected, v2Connection === connection else { throw NativeRelayCoreError.inactive }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard UInt64(bytes.count) == file.byteCount, ExactText(digest) == file.sha256 else {
                throw ConversationError.fileMismatch
            }
            try bytes.write(to: destination, options: .atomic)
            return
        }
        guard let configuration else { throw NativeRelayCoreError.inactive }
        let token = UUID()
        defer { fileTransports.removeValue(forKey: token) }
        // The file origin comes from the live conversation catch-up. Opening a
        // second relay connection to ask would make the Server close the live
        // one (one relay session per device).
        let endpoint = try await core?.conversationOriginURL()
        guard context == expected, !Task.isCancelled else { throw NativeRelayCoreError.inactive }
        guard let endpoint else { throw NativeRelayCoreError.inactive }
        // HTTPS only: this session never opens a relay WebSocket.
        let download = try URLSessionInstallationSession(profile: expected,
            relayURL: configuration.relayURL,
            clientIdentity: TrustedKeychainIdentity(configuration.identity),
            trustedRootDER: configuration.rootDER, attemptID: token,
            onDiagnostic: diagnosticSink(), opensRelaySocket: false)
        fileTransports[token] = download
        do {
            try await download.fetchConversationFile(file, to: destination, originURL: endpoint)
            await download.close()
        } catch {
            await download.close()
            throw error
        }
        guard context == expected else { throw NativeRelayCoreError.inactive }
    }

    private func performRefresh(generation: UUID,
                                checkBlockedPush: Bool = false) async -> NativeRelayRefreshResult {
        guard refreshGeneration == generation else { return .unavailable }
        guard let expected = context else { return .unavailable }
        let result = await performRefreshAttempt(generation: generation, checkBlockedPush: checkBlockedPush)
        guard refreshGeneration == generation else { return .unavailable }
        snapshotState.failureContext = expected
        snapshotState.failureMessage = result.failureMessage
        return result
    }

    private func performRefreshAttempt(generation: UUID,
                                       checkBlockedPush: Bool) async -> NativeRelayRefreshResult {
        var needsReconnect = false
        // The connection that failed; nil when a rebuild needs a fresh one anyway.
        var failedTransport: URLSessionInstallationSession?
        // Set after discarding saved Server state. Cleared by a socket
        // interruption, or when the rebuilt connection got further than the
        // previous failure (its accepted checkpoint moved the cursor past the
        // cursor seen at that failure). Only a rebuild that fails again with
        // no progress is reported; the next foreground, push, network change,
        // answer or relaunch rebuilds again.
        var rebuiltSavedServerState = false
        var cursorAtLastRebuild: UInt64 = 0
        while refreshGeneration == generation && !Task.isCancelled {
            var attempted: URLSessionInstallationSession?
            do {
                if needsReconnect {
                    try await reconnect(replacing: failedTransport, generation: generation)
                    needsReconnect = false
                }
                attempted = transport
                recordDiagnostic(.relay, .projectionRefresh, .began, attemptID: activeTransportAttemptID)
                let result = try await refreshOnce(generation: generation,
                                                   checkBlockedPush: checkBlockedPush)
                recordDiagnostic(.relay, .projectionRefresh,
                                 result.relayConfirmed ? .completed : .unresolved,
                                 attemptID: activeTransportAttemptID)
                return refreshGeneration == generation ? result : .unavailable
            } catch {
                guard refreshGeneration == generation, !Task.isCancelled else { return .unavailable }
                foregroundProgress.recordFailure(error)
                confirmedRelayContext = nil
                if rebuiltSavedServerState, let cursor = savedRelayCursor(), cursor > cursorAtLastRebuild {
                    rebuiltSavedServerState = false
                    cursorAtLastRebuild = cursor
                }
                if !rebuiltSavedServerState, NativeRelayCoreError.isInvalidSavedServerState(error),
                   await discardSavedServerState(after: error) {
                    // Saved Server state is a cache. Report it, drop it, and
                    // rebuild from the Server on a fresh connection.
                    rebuiltSavedServerState = true
                    needsReconnect = true
                    failedTransport = nil
                    continue
                }
                guard Self.shouldReconnectAfterConnectionError(error, awaitingFirstConnection: awaitingFirstConnection) else {
                    recordDiagnostic(.relay, .projectionRefresh, .failed, error: error,
                                     attemptID: activeTransportAttemptID)
                    return .failed(error: error)
                }
                // A real reset/closure ends this socket, not the catch-up.
                // Each replacement starts from the committed repository/cache
                // prefix. There is no elapsed-time or retry-count cutoff.
                recordDiagnostic(.relay, .projectionRefresh, .retrying, error: error,
                                 attemptID: activeTransportAttemptID)
                rebuiltSavedServerState = false
                needsReconnect = true
                failedTransport = attempted
            }
        }
        return .unavailable
    }

    /// A rebuild starts from cursor 0; only an accepted Server checkpoint or
    /// replayed events move it, so it measures progress made from the Server.
    private func savedRelayCursor() -> UInt64? {
        guard let expected = context, let configuration else { return nil }
        return try? configuration.store.snapshot(context: expected).cursor
    }

    /// Records the validation failure and discards every saved copy of
    /// Server state (repository and cache file), keeping the person's queue.
    /// Returns false only when the discard itself cannot be committed.
    private func discardSavedServerState(after error: Error) async -> Bool {
        guard let expected = context, let configuration else { return false }
        recordDiagnostic(.localStore, .projectionRefresh, .retrying, error: error,
                         attemptID: activeTransportAttemptID)
        do {
            if let core {
                try await core.discardSavedServerState()
            } else {
                try configuration.store.discardServerState(context: expected)
                try await configuration.serverStateCache?.discard()
            }
        } catch {
            recordDiagnostic(.localStore, .projectionRefresh, .failed, error: error,
                             attemptID: activeTransportAttemptID)
            return false
        }
        recordDiagnostic(.localStore, .projectionRefresh, .completed,
                         causeCode: "saved_server_state_rebuilt",
                         attemptID: activeTransportAttemptID)
        return true
    }

    static func shouldReconnectAfterConnectionError(_ error: Error, awaitingFirstConnection: Bool = false) -> Bool {
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            return value.code == URLError.timedOut.rawValue ||
                (!awaitingFirstConnection && value.code == URLError.networkConnectionLost.rawValue)
        }
        if value.domain == NSPOSIXErrorDomain {
            return !awaitingFirstConnection && [POSIXErrorCode.ECONNRESET, .ECONNABORTED, .ENOTCONN, .EPIPE]
                .contains { Int($0.rawValue) == value.code }
        }
        // A refusal, invalid frame, or failed local write needs its actual
        // reason surfaced; reconnecting cannot turn that fact into acceptance.
        return false
    }

    private func refreshConfirmedProjection(core: NativeRelayCore, context: ProfileContext,
                                            generation: UUID) async throws {
        do {
            _ = try await core.resyncAndDrainOutbox()
        } catch {
            if let details = await core.takePostAckFailureDetails() {
                foregroundProgress.recordPostAckFailure(details)
            }
            throw error
        }
        let conversationsUnavailable = await core.conversationsUnavailable
        guard refreshGeneration == generation, self.context == context, self.core === core else {
            throw NativeRelayCoreError.inactive
        }
        conversationAvailability.confirm(for: context, conversationsUnavailable: conversationsUnavailable)
        snapshotState.failureContext = context
        snapshotState.failureMessage = nil
        confirmedRelayContext = context
    }

#if DEBUG
    /// Test-target entry into the same replay and confirmation path, without TLS
    /// enrollment or notification registration. It never forces send permission.
    func confirmInProcessSessionForTesting(store: ClientRepository, context: ProfileContext,
                                          session: any AuthenticatedInstallationSession,
                                          serverStateCache: any ServerStateCaching,
                                          pushRemovalSession: (any AuthenticatedPushRemovalSession)? = nil,
                                          enrollmentStore: NativeEnrollmentStore = NativeEnrollmentStore()) async throws -> NativeRelayRefreshResult {
        await deactivate()
        let generation = UUID()
        let attemptID = UUID()
        refreshGeneration = generation
        activeTransportAttemptID = attemptID
        self.context = context
        featureFlags.connect(context: context, connectionID: attemptID)
        let core = try NativeRelayCore(store: store, context: context, session: session,
                                       automaticallySendsPendingOperations: false,
                                       attemptID: attemptID, serverStateCache: serverStateCache,
                                       onFeatureFlags: featureFlagsHandler(connectionID: attemptID), errorLog: errorLog)
        self.core = core
        if let pushRemovalSession {
            try await refreshProjectionAfterPendingPushRemoval(core: core, context: context, generation: generation,
                                                              pushSession: pushRemovalSession, enrollment: enrollmentStore)
        } else {
            try await refreshConfirmedProjection(core: core, context: context, generation: generation)
        }
        try await resumeConfirmedDiscussions(core: core, context: context, generation: generation)
        return NativeRelayRefreshResult(relayConfirmed: true, pushRegistration: .notAttempted,
            confirmedContext: context, confirmedTransportAttemptID: attemptID)
    }
#endif

    private func resumeConfirmedDiscussions(core: NativeRelayCore, context: ProfileContext,
                                            generation: UUID) async throws {
        let files = try ConversationFileStorage(identity: context.identity)
        try await core.resumePendingDiscussions { file in try files.fileURL(for: file) }
        guard refreshGeneration == generation, self.context == context, self.core === core else {
            throw NativeRelayCoreError.inactive
        }
    }

    private func refreshProjectionAfterPendingPushRemoval(core: NativeRelayCore, context: ProfileContext,
                                                           generation: UUID,
                                                           pushSession: any AuthenticatedPushRemovalSession,
                                                           enrollment: NativeEnrollmentStore) async throws {
        try await refreshConfirmedProjection(core: core, context: context, generation: generation)
        do {
            try await enrollment.retryPendingPushRemoval(using: pushSession)
        } catch {
            // Notification setup cannot prevent the account from syncing. A
            // refused removal stays durable for another connection.
            recordDiagnostic(.notifications, .pushRegistration, .failed, error: error,
                             attemptID: activeTransportAttemptID)
        }
        guard refreshGeneration == generation, self.context == context else {
            throw NativeRelayCoreError.inactive
        }
    }

    private func refreshOnce(generation: UUID,
                             checkBlockedPush: Bool = false) async throws -> NativeRelayRefreshResult {
        guard refreshGeneration == generation else { throw NativeRelayCoreError.inactive }
        guard let core, let transport, let context else { throw NativeRelayCoreError.inactive }
        resumeSavedAnswers()
        resumeSavedDiscussions()
        try await refreshProjectionAfterPendingPushRemoval(core: core, context: context, generation: generation,
                                                          pushSession: transport, enrollment: enrollment)
        try enrollment.updateServerID(await transport.serverID, for: context.identity)
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
            if try enrollment.hasPushDeparture(for: context.identity) { return .notAttempted }
            let currentAddress = try DevelopmentPushRegistration.addressStore().load()
            if let currentAddress,
               let binding = try enrollment.pendingPushRegistration(address: currentAddress,
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
            guard let expected = try enrollment.load(),
                  expected.matchesNotificationIdentity(context.identity),
                  let binding = expected.pushBinding, binding.accepted else { return .notAttempted }

            if checkBlockedPush && PushRegistrationProfile.current == .production {
                guard let status = try await transport.currentPushBindingStatus(),
                      self.refreshGeneration == generation, self.context == context,
                      status.profile == .production, status.revision == binding.revision else {
                    return .notAttempted
                }
                let associations = (expected.notificationBindings ?? []).filter {
                    $0.operationID == binding.operationID && $0.revision == binding.revision
                }
                guard associations.count <= 1,
                      associations.first?.bindingID.rawValue == nil ||
                        associations.first?.bindingID.rawValue == status.bindingID else {
                    return .notAttempted
                }

                if status.isBlockedByConfiguration {
                    guard let replacement = try enrollment.pendingBlockedConfigurationRegistration(
                        address: binding.address,
                        for: context.identity.deviceID.rawValue,
                        status: status,
                        profile: .production),
                          let current = try enrollment.load(),
                          current.matchesNotificationIdentity(context.identity),
                          current.pushBinding == replacement else { return .notAttempted }
                    let bindingID = try await transport.registerPush(address: replacement.address,
                        operationID: replacement.operationID, revision: replacement.revision)
                    guard self.refreshGeneration == generation, self.context == context else {
                        throw NativeRelayCoreError.inactive
                    }
                    try enrollment.markPushAccepted(replacement, bindingID: bindingID, expected: current)
                    return .confirmed
                }

                if associations.isEmpty {
                    try enrollment.markPushAccepted(binding, bindingID: status.bindingID, expected: expected)
                    return .confirmed
                }
                return .notAttempted
            }

            if !(expected.notificationBindings ?? []).contains(where: {
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

    /// Replaces the live connection once per failure. Callers that saw the
    /// same failed connection share one replacement, and a caller whose failed
    /// connection was already replaced uses that replacement, so a reconnect
    /// admits exactly one new relay session.
    private func reconnect(replacing failed: URLSessionInstallationSession?, generation: UUID) async throws {
        if let flight = reconnectFlight {
            try await flight.task.value
            return
        }
        if let failed, let current = transport, current !== failed { return }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw NativeRelayCoreError.inactive }
            try await self.replaceLiveConnection(generation: generation)
        }
        reconnectFlight = (token, task)
        defer { if reconnectFlight?.token == token { reconnectFlight = nil } }
        try await task.value
    }

    private func replaceLiveConnection(generation: UUID) async throws {
        guard refreshGeneration == generation else { throw NativeRelayCoreError.inactive }
        guard let configuration else { throw NativeRelayCoreError.inactive }
        let transportAttemptID = UUID()
        let previousProgress = foregroundProgress.progress
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
        foregroundProgress.beginTransportAttempt(transportAttemptID)
        activeTransportAttemptID = transportAttemptID
        featureFlags.connect(context: configuration.context, connectionID: transportAttemptID)
        let priorCore = core
        let priorTransport = transport
        core = nil
        transport = nil
        focusTransportID = nil
        installFocusReportHandler(for: nil, transportID: nil)
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
                                                              serverMatchedPushRoutingEnabled: pushRoutingEnabledHandler(),
                                                              onProgress: progressHandler(generation: generation,
                                                                                          transportAttemptID: transportAttemptID),
                                                              onFocusReportingReady: focusReportingReadyHandler(
                                                                generation: generation,
                                                                transportID: transportAttemptID),
                                                              onFocusReportingUnsupported: focusReportingUnsupportedHandler(
                                                                generation: generation,
                                                                transportID: transportAttemptID),
                                                              onViewShow: viewShowHandler(
                                                                generation: generation,
                                                                transportID: transportAttemptID),
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
                                           automaticallySendsPendingOperations: false,
                                           attemptID: transportAttemptID,
                                           serverStateCache: configuration.serverStateCache,
                                           onProgress: progressHandler(generation: generation,
                                                                       transportAttemptID: transportAttemptID),
                                           onPriorityLevelsChanged: priorityLevelsChangeHandler(for: configuration.context),
                                           onPriorityLevelsConnectionLost: priorityLevelsConnectionLostHandler(
                                               for: configuration.context, transportAttemptID: transportAttemptID),
                                           onPriorityLevelsFeatureEnabled: priorityLevelsFeatureEnabledHandler(),
                                           onDiagnostic: diagnosticSink(),
                                           onFeatureFlags: featureFlagsHandler(connectionID: transportAttemptID), errorLog: errorLog)
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
        focusTransportID = transportAttemptID
        featureFlags.connect(context: configuration.context, connectionID: transportAttemptID)
        installFocusReportHandler(for: nextTransport, transportID: transportAttemptID)
    }

    private func pushRoutingEnabledHandler() -> @Sendable () async -> Bool {
        { [weak self] in
            await self?.featureFlags.isEnabled(.serverMatchedPushRouting) ?? false
        }
    }

    private func featureFlagsHandler(connectionID: UUID)
        -> @Sendable (RemoteFeatureFlagSnapshot) async -> Void {
        { [weak self] snapshot in
            await self?.featureFlags.replace(snapshot, connectionID: connectionID)
        }
    }

    private func progressHandler(generation: UUID,
                                 transportAttemptID: UUID) -> @Sendable (NativeRelayProgressEvent) -> Void {
        { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation,
                      self.activeTransportAttemptID == transportAttemptID else { return }
                self.foregroundProgress.observe(event, transportAttemptID: transportAttemptID)
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
                    // The session journals this admission itself, timed when it
                    // happened. A second record here, made only once the main
                    // actor ran this task, read as a second admission.
                    break
                case .nativeSyncReplayRequested, .nativeSyncResynced:
                    // The core journals the replay's start and end itself.
                    break
                case .nativeSyncAcknowledged:
                    // The core emits the correlated acknowledgement diagnostic
                    // at this same boundary. Keep progress without a second
                    // identical journal rewrite for every successful ACK.
                    break
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

}

/// Normal foreground/push wakes share a flight. A newly stored APNs address
/// or activation-specific check must run after the current flight if it arrives
/// during one.
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
        return await start(after: nil, operation: operation)
    }

    func afterCurrent(operation: (@MainActor () async -> Output)? = nil) async -> Output {
        await start(after: latest, operation: operation ?? self.operation)
    }

    func reset() {
        generation = UUID()
        latest = nil
        latestID = nil
    }

    private func start(after previous: Task<Output, Never>?,
                       operation: @escaping @MainActor () async -> Output) async -> Output {
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
