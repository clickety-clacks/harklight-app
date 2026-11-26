import AttentionDomain
import CryptoKit
import Foundation
import HarklightNativeRelay
import Security
import Observation
import UserNotifications
import enum SwiftUI.ScenePhase

/// Shareable error details deliberately exclude response bodies, decoder context,
/// persistence messages and NSError userInfo, all of which may contain message text.
struct NativeForegroundConnectErrorDetails: Equatable, Sendable {
    let type: String
    let cause: String
    let description: String

    init(_ error: Error) {
        type = String(reflecting: Swift.type(of: error))
        let code = NativeClientDiagnosticJournal.causeCode(for: error)
        cause = code == "unknown_error" ? type : code
        description = Self.describe(error, cause: code)
    }

    private static func describe(_ error: Error, cause: String) -> String {
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

    struct ConnectivityFailure: Equatable, Sendable {
        let context: ProfileContext
        let transportAttemptID: UUID
        let openingCount: Int
        let suppressedWhileOpen: Bool
    }

    let relayConfirmed: Bool
    let pushRegistration: PushRegistration
    let failureMessage: String?
    let connectivityFailure: ConnectivityFailure?
    // Confirmation belongs to the refresh that produced this result. A queued
    // refresh can start before its predecessor's foreground waiter resumes.
    let confirmedContext: ProfileContext?
    let confirmedTransportAttemptID: UUID?

    init(relayConfirmed: Bool,
         pushRegistration: PushRegistration,
         confirmedContext: ProfileContext?,
         confirmedTransportAttemptID: UUID?,
         failureMessage: String? = nil,
         connectivityFailure: ConnectivityFailure? = nil) {
        self.relayConfirmed = relayConfirmed
        self.pushRegistration = pushRegistration
        self.confirmedContext = confirmedContext
        self.confirmedTransportAttemptID = confirmedTransportAttemptID
        self.failureMessage = failureMessage
        self.connectivityFailure = connectivityFailure
    }

    static let unavailable = Self(relayConfirmed: false, pushRegistration: .notAttempted,
                                  confirmedContext: nil, confirmedTransportAttemptID: nil)

    static func failed(error: Error, connectivityFailure: ConnectivityFailure? = nil) -> Self {
        Self(relayConfirmed: false, pushRegistration: .notAttempted,
             confirmedContext: nil, confirmedTransportAttemptID: nil,
             failureMessage: "Couldn’t refresh from the server: \(error.localizedDescription). Saved requests and answers remain on this device.",
             connectivityFailure: connectivityFailure)
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
        case foregroundConfirmed

        var label: String { "Foreground connection is confirmed." }
        var diagnosticValue: String { "foreground_confirmed" }
    }

    enum Issue: Equatable, Sendable {
        case serverTrustRejected
        case clientIdentityChallengeRejected

        var message: String {
            switch self {
            case .serverTrustRejected:
                "The server certificate did not pass the saved host and CA check."
            case .clientIdentityChallengeRejected:
                "Harklight couldn’t present this device’s identity to the saved server."
            }
        }
    }

    enum Outcome: Equatable, Sendable { case connecting, incomplete, timedOut, confirmed }

    struct PreviousTransportAttempt: Equatable, Sendable {
        let id: UUID
        let lastConfirmedStage: Stage?
        let issue: Issue?
        let failureClass: FailureClass?
        let errorDetails: NativeForegroundConnectErrorDetails?
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
        case unknown

        var diagnosticValue: String {
            switch self {
            case .foregroundDeadline: "foreground_deadline"
            case .cancelled: "cancelled"
            case .serverTrustRejected: "server_trust_rejected"
            case .clientIdentityChallengeRejected: "client_identity_challenge_rejected"
            case let .urlSession(code): "url_session_error_code_\(code)"
            case .relayProtocol: "relay_protocol_error"
            case .unknown: "unknown_error_class"
            }
        }

        static func classify(_ error: Error) -> Self {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
            let value = error as NSError
            if value.domain == NSURLErrorDomain { return .urlSession(code: value.code) }
            if error is ClientConnectionError { return .relayProtocol }
            return .unknown
        }
    }

    var lastConfirmedStage: Stage?
    var issue: Issue?
    var outcome: Outcome
    var attemptID: UUID? = nil
    var failureClass: FailureClass? = nil
    var errorDetails: NativeForegroundConnectErrorDetails? = nil
    var observedErrorMessage: String? = nil
    var transportAttemptID: UUID? = nil
    var previousTransportAttempt: PreviousTransportAttempt? = nil
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

    /// Brief product status for the foreground connection.
    var userFacingMessage: String {
        switch outcome {
        case .confirmed: "Connected"
        case .connecting: "Connecting to the server… Your pending actions are saved."
        case .timedOut, .incomplete: "Can't reach the server. Your pending actions are saved."
        }
    }

    var message: String {
        let last = lastConfirmedStage?.label ?? "No connection milestone was confirmed."
        switch outcome {
        case .connecting:
            return issue?.message ?? last
        case .incomplete:
            let issueText = issue.map { "\($0.message) " } ?? ""
            return "The connection was not confirmed. \(issueText)\(observedCauseText)Last confirmed step: \(last) Try again with the same approved identity."
        case .timedOut:
            let issueText = issue.map { "\($0.message) " } ?? ""
            return "The connection timed out. \(issueText)\(observedCauseText)Last confirmed step: \(last) Try again with the same approved identity. Saved profile, local content and pending operation state were preserved; saved messages remain available."
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
        let failure = Self.failureValue(progress.failureClass, details: progress.errorDetails)
        var lines = [
            "Harklight connection diagnostics",
            "app_version=\(appVersion)",
            "app_build=\(buildNumber)",
            "app_executable_sha256=\(executableSHA256)",
            "attempt_id=\(progress.attemptID?.uuidString.lowercased() ?? "unavailable")",
            "outcome=\(outcome)",
            "last_confirmed_phase=\(stage)",
            "generation_validated=\(progress.generationValidation.rawValue)",
            "profile_context_validated=\(progress.profileContextValidation.rawValue)",
            "relay_context_validated=\(progress.relayContextValidation.rawValue)",
            "terminal_reason=\(terminal)",
            "transport_attempt_id=\(progress.transportAttemptID?.uuidString.lowercased() ?? "unavailable")",
            "issue=\(issue)",
            "error_class=\(failure)",
            "error_type=\(progress.errorDetails?.type ?? "none_observed")",
            "error_description=\(progress.errorDetails?.description ?? "none_observed")"
        ]
        if let previous = progress.previousTransportAttempt {
            lines.append("previous_transport_attempt_id=\(previous.id.uuidString.lowercased())")
            lines.append("previous_last_confirmed_phase=\(previous.lastConfirmedStage?.diagnosticValue ?? "none_confirmed")")
            lines.append("previous_issue=\(Self.issueValue(previous.issue))")
            lines.append("previous_error_class=\(Self.failureValue(previous.failureClass, details: previous.errorDetails))")
            lines.append("previous_error_type=\(previous.errorDetails?.type ?? "none_observed")")
            lines.append("previous_error_description=\(previous.errorDetails?.description ?? "none_observed")")
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
                                                                 issue: nil, outcome: .incomplete)

    func beginSession(transportAttemptID: UUID) {
        guard attempt == nil else { return }
        progress = NativeForegroundConnectProgress(lastConfirmedStage: nil,
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
                issue: progress.issue,
                failureClass: progress.failureClass,
                errorDetails: progress.errorDetails,
                generationValidation: progress.generationValidation,
                profileContextValidation: progress.profileContextValidation,
                relayContextValidation: progress.relayContextValidation,
                terminalReason: progress.terminalReason)
        }
        activeTransportAttemptID = transportAttemptID
        progress.transportAttemptID = transportAttemptID
        progress.lastConfirmedStage = nil
        progress.issue = nil
        progress.failureClass = nil
        progress.errorDetails = nil
        progress.observedErrorMessage = nil
        progress.outcome = .connecting
        progress.generationValidation = .notChecked
        progress.profileContextValidation = .notChecked
        progress.relayContextValidation = .notChecked
        progress.terminalReason = nil
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
        return progress
    }

    func recordSnapshotConfirmation(relayRefreshConfirmed: Bool,
                                    generationMatches: Bool,
                                    profileMatches: Bool,
                                    relayContextMatches: Bool) {
        guard acceptsEvents, attempt != nil else { return }
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
        publishProgress()
    }

    func recordFailure(_ error: Error) {
        guard acceptsEvents, attempt != nil else { return }
        progress.failureClass = NativeForegroundConnectProgress.FailureClass.classify(error)
        progress.errorDetails = NativeForegroundConnectErrorDetails(error)
        progress.observedErrorMessage = error.localizedDescription
        if progress.failureClass == .cancelled { progress.terminalReason = .cancelled }
        publishProgress()
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
    var failure: (context: ProfileContext, result: NativeRelayRefreshResult)?
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
    private var v2Connection: ClientAPIv2Connection?
    private var v2FocusChannel: ClientAPIFocusChannel?
    private var v2PushWaitsForInternalError = false
    private var v2ShowLookup: Task<Void, Never>?
    private var pendingV2Show: (show: ClientAPIShow, receivedAt: Date)?
    private let v2FocusReporter: NativeFocusReporter
    private let v2ShowCoordinator: NativePushedViewCoordinator
    private var v2ForegroundTask: Task<Void, Never>?
    private var v2PushRegistrationTask: Task<Bool, Never>?
    private var v2PushRegistrationRequested = false
    private var v2DepartureTask: Task<Void, Never>?
    private var v2PushRetryTask: Task<Void, Never>?
    private var v2PushRetryAttempt = 0
    private let v2NotificationPermission: NativeNotificationPermission
    var onV2FeedOpened: ((ProfileContext, UUID) -> Void)?
    var onV2AccountAccessChanged: ((ClientAPIAccessState, ProfileContext) -> Void)?
    var v2AccountAccess: ClientAPIAccessState? { v2Connection?.access.state }

    var shouldPollV2PausedAccount: Bool {
        v2Connection?.access.state == .paused && v2Connection?.canPollMe == true
    }
    private var sceneIsActive = false

    private var context: ProfileContext?
    private let snapshotState = NativeRelaySnapshotState()
    private var confirmedRelayContext: ProfileContext? {
        get { snapshotState.confirmedContext }
        set { snapshotState.confirmedContext = newValue }
    }
    private var activeTransportAttemptID: UUID?
    private let foregroundProgress: ForegroundConnectProgressTracker
    private var diagnosticJournal: NativeClientDiagnosticJournal?
    /// The app's Error Log, which the relay components report failures to.
    var errorLog: any ErrorLogging = NoopErrorLog()

    private var foregroundDiagnosticContext: ProfileContext?
    private var foregroundDiagnosticOperationsAtStart: [UUID: NativeForegroundOperationDiagnostic] = [:]
    private var foregroundDiagnosticIntentIDs: [UUID: UUID] = [:]
    private var foregroundDiagnosticSnapshotAvailable = false
    private var foregroundDiagnosticAttemptID = UUID()
    private var foregroundDiagnosticOperations = NativeForegroundOperationSnapshot.unavailable
    private var priorityLevelsObservers: [UUID: PriorityLevelsObserver] = [:]
    private var repository: ClientRepository?
    private var refreshGeneration = UUID()
    private lazy var refreshFlights = RelayRefreshFlights(inactive: NativeRelayRefreshResult.unavailable) { [weak self] in
        guard let self else { return .unavailable }
        return await self.refreshSnapshot()
    }
    private let enrollment: NativeEnrollmentStore

    init(v2FocusReporter: NativeFocusReporter = .shared,
         v2ShowCoordinator: NativePushedViewCoordinator = .shared,
         v2NotificationPermission: NativeNotificationPermission = .system,
         enrollment: NativeEnrollmentStore = NativeEnrollmentStore(),
         foregroundProgress: ForegroundConnectProgressTracker = ForegroundConnectProgressTracker()) {
        self.v2FocusReporter = v2FocusReporter
        self.v2ShowCoordinator = v2ShowCoordinator
        self.v2NotificationPermission = v2NotificationPermission
        self.enrollment = enrollment
        self.foregroundProgress = foregroundProgress
    }

    func v2FocusScenePhaseChanged(_ phase: ScenePhase) {
        v2FocusReporter.scenePhaseChanged(phase)
    }

    func sceneActivityChanged(isActive: Bool) {
        sceneIsActive = isActive
        if isActive {
            v2PushWaitsForInternalError = false
            startV2Foreground()
            _ = requestV2PushRegistration()
        } else {
            v2ForegroundTask?.cancel()
            v2PushRegistrationTask?.cancel()
            cancelV2PushRetry()
        }
    }

    private func startV2Foreground() {
        guard sceneIsActive, v2DepartureTask == nil, let connection = v2Connection, connection.access.state == .available,
              v2ForegroundTask == nil else { return }
        v2ForegroundTask = Task { [weak self] in
            await connection.runForeground()
            guard let self, self.v2Connection === connection else { return }
            self.v2ForegroundTask = nil
            // A foreground transition may arrive before the cancelled feed exits.
            if Task.isCancelled { self.startV2Foreground() }
        }
    }

    func retryV2InternalError(_ record: ErrorLogRecord) async {
        guard sceneIsActive, let connection = v2Connection, v2DepartureTask == nil else { return }
        if ["push_registration", "register_push", "remove_push"].contains(record.operation) {
            v2PushWaitsForInternalError = false
            _ = requestV2PushRegistration()
            return
        }
        if record.operation == "focus" {
            await v2FocusChannel?.retryInternalError()
            return
        }
        do { try await connection.retryInternalError(record) }
        catch { return }
        guard record.concern == .sync, v2Connection === connection else { return }
        startV2Foreground()
    }

    static func v2Directory(for identity: ProfileIdentity) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let key = [identity.trustedRelayAuthority.rawValue, identity.personID.rawValue, identity.deviceID.rawValue]
            .joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("ClientAPIv2", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    static func clearV2Storage(for record: NativeEnrollmentRecord) throws {
        guard let person = record.personID else { throw NativeEnrollmentError.invalidIdentity }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText(record.profileAuthority),
                                       personID: ExactText(person), deviceID: ExactText(record.deviceID))
        let directory = try v2Directory(for: identity)
        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // A confirmed departure is also finished on relaunch.
        }
    }



    func activate(store: ClientRepository, context: ProfileContext, deviceURL: URL,
                  clientIdentity: SecIdentity, trustedRootDER: Data,
                  diagnostics: NativeClientDiagnosticJournal? = nil) throws {
        let transport = try HTTPSClientAPITransport(baseURL: deviceURL,
            clientIdentity: TrustedKeychainIdentity(clientIdentity), trustedRootDER: trustedRootDER)
        try activate(store: store, context: context, transport: transport, diagnostics: diagnostics)
    }

    func activate(store: ClientRepository, context: ProfileContext, transport: HTTPSClientAPITransport,
                  legacyReceiptCutoff: Date? = nil, diagnostics: NativeClientDiagnosticJournal? = nil) throws {
        let retainedFiles = try ConversationFileStorage(identity: context.identity)
        let attempt = UUID()
        let access = ClientAPIAccess(transport: transport) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeTransportAttemptID == attempt, self.v2DepartureTask == nil,
                      let state = self.v2AccountAccess else {
                    return
                }
                if state == .available {
                    self.startV2Foreground()
                    self.requestV2PushRegistration()
                } else {
                    self.v2ForegroundTask?.cancel()
                    self.v2PushRegistrationTask?.cancel()
                    self.cancelV2PushRetry()
                    self.confirmedRelayContext = nil
                }
                self.onV2AccountAccessChanged?(state, context)
            }
        }
        let focus = ClientAPIFocusChannel(transport: access, errors: errorLog) { [weak self] show, receivedAt in
            await self?.receiveV2Show(show, receivedAt: receivedAt, attempt: attempt)
        }
        let connection = try ClientAPIv2Connection(transport: access, repository: store, context: context,
            directory: Self.v2Directory(for: context.identity), errors: errorLog, foregroundOnlyWrites: true,
            legacyReceiptCutoff: legacyReceiptCutoff,
            retainedUploadURL: { try retainedFiles.verifiedUploadURL(for: $0) },
            onLiveState: { [weak self] state in
                guard state == .live else { return }
                Task { @MainActor [weak self] in
                    await self?.v2FeedStateChanged(state, context: context, attempt: attempt)
                }
            }, onShow: { data in
                await focus.received(feedShow: data)
            }, onMe: { [weak self] me in
                Task { @MainActor [weak self] in
                    guard let self, self.context == context, self.activeTransportAttemptID == attempt else { return }
                    let feature = RemoteFeatureFlag.priorityLevelEditing.name
                    let fields = me.features[feature].map { [JSONMember(feature, .bool($0))] } ?? []
                    self.featureFlags.replace(RemoteFeatureFlagSnapshot(field: .object(fields)), connectionID: attempt)
                    self.requestV2PushRegistration()
                }
            }, onPriorityLevelsChanged: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.activeTransportAttemptID == attempt else { return }
                    self.publishPriorityLevelsUpdate(for: context)
                }
            }, onPublished: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.activeTransportAttemptID == attempt else { return }
                    self.deliverV2ShowIfHydrated(attempt: attempt)
                    self.publishPriorityLevelsUpdate(for: context)
                }
            })
        repository = store
        diagnosticJournal = diagnostics
        foregroundProgress.beginSession(transportAttemptID: attempt)
        installV2Connection(connection, context: context, attempt: attempt)
        installV2FocusChannel(focus, attempt: attempt)
    }

    func v2FeedStateChanged(_ state: ChangeFeedSync.LiveState, context: ProfileContext, attempt: UUID) async {
        guard state == .live, activeTransportAttemptID == attempt else { return }
        confirmedRelayContext = context
        conversationAvailability.confirm(for: context, conversationsUnavailable: false)
        Task { @MainActor [weak self] in
            await self?.settleV2FeedRecovery(for: context, attempt: attempt)
        }
        if let connection = v2Connection, connection.priorityLevelsEditorWasOpened {
            await connection.refreshPriorityLevels(userInitiated: false)
            guard activeTransportAttemptID == attempt else { return }
            publishPriorityLevelsUpdate(for: context)
        }
    }

    private func settleV2FeedRecovery(for expected: ProfileContext, attempt: UUID) async {
        guard let sync = v2Connection?.sync, await sync.liveState == .live,
              hasOpenFeed(for: expected, attempt: attempt) else { return }
        if let failure = snapshotState.failure, didRecover(failure.result, for: expected) {
            snapshotState.failure = nil
        }
        onV2FeedOpened?(expected, attempt)
    }

    func installV2Connection(_ connection: ClientAPIv2Connection, context: ProfileContext, attempt: UUID = UUID()) {
        guard v2Connection == nil else { return }
        self.context = context
        activeTransportAttemptID = attempt
        v2Connection = connection
        featureFlags.connect(context: context, connectionID: attempt)
        startV2Foreground()
        _ = requestV2PushRegistration()
    }

    func installV2FocusChannel(_ focus: ClientAPIFocusChannel, attempt: UUID) {
        guard activeTransportAttemptID == attempt, v2Connection != nil else { return }
        v2FocusChannel = focus
        v2FocusReporter.installReportHandler(for: attempt) { report in
            // The channel may return the last drained reply, so this sender
            // does not treat a reply as acknowledgement of an individual write.
            guard let report else {
                await focus.pauseReporting(sendNotInFront: true)
                return
            }
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
        // The item lookup is an independent request; a slow read must not
        // block a focus PUT or consumption of the change feed.
        v2ShowLookup = Task { [weak self] in
            let unavailable: ViewShowFrame.Unavailable
            do {
                let item = try await connection.resolveShowItem(itemID: ExactText(show.itemID))
                unavailable = item == nil ? .notSent : .notHere
            } catch let error as APIError where error.token == .forbidden || error.status == 404 {
                unavailable = .notSent
            } catch {
                unavailable = .notHere
            }
            guard let self, !Task.isCancelled, self.activeTransportAttemptID == attempt,
                  self.pendingV2Show?.show.showID == show.showID else { return }
            self.v2ShowLookup = nil
            if unavailable == .notSent {
                self.pendingV2Show = nil
            } else if connection.model.snapshot.items[ExactText(show.itemID)] != nil {
                self.deliverV2ShowIfHydrated(attempt: attempt)
                return
            }
            self.v2ShowCoordinator.receiveV2(.clientAPIUnavailable(show, reason: unavailable),
                elapsedSinceReceipt: max(0, Date().timeIntervalSince(receivedAt)))
        }
    }

    func deliverV2ShowIfHydrated(attempt: UUID) {
        guard activeTransportAttemptID == attempt, v2ShowLookup == nil, let pending = pendingV2Show,
              let item = v2Connection?.model.snapshot.items[ExactText(pending.show.itemID)] else { return }
        pendingV2Show = nil
        let frame: ViewShowFrame = if item.shared != nil {
            .clientAPIUnavailable(pending.show, reason: .notSent)
        } else if item.terminal?.state == "retracted" {
            .clientAPIUnavailable(pending.show, reason: .retracted)
        } else {
            .clientAPI(pending.show, senderID: item.sender.rawValue)
        }
        v2ShowCoordinator.receiveV2(frame,
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
        guard let connection = v2Connection, context == expected else { throw ClientConnectionError.inactive }
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
            return false
        }
    }

    func refreshV2ForPush(_ payload: JSONValue) async -> Bool {
        guard let connection = v2Connection, let hint = connection.matchPush(payload),
              await allowsV2PushRouting(connection), connection.matchPush(payload) == hint else { return false }
        do {
            let changed = try await connection.catchUp(forPushRevision: hint.revision)
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
        await v2DestinationForPush(payload)?.locator
    }

    func v2DestinationForPush(_ payload: JSONValue) async -> NativePushDestination? {
        guard let connection = v2Connection, let context,
              await allowsV2PushRouting(connection),
              let match = connection.matchPush(payload) else { return nil }
        _ = try? await connection.catchUp(forPushRevision: match.revision)
        guard v2Connection === connection, connection.matchPush(payload) == match else { return nil }
        switch match {
        case .syncOnly:
            return .inbox
        case let .located(hint):
            guard let item = connection.model.snapshot.items[hint.itemID] else { return nil }
            let request = ServerModelV2Projection.key(for: hint.itemID, sender: item.sender, identity: context.identity)
            return .item(NativeNotificationLocator(v2Request: request, bindingID: hint.bindingID,
                deviceID: hint.deviceID, serverID: hint.serverID.rawValue, target: hint.target))
        }
    }

    private func allowsV2PushRouting(_ connection: ClientAPIv2Connection) async -> Bool {
        let permission = await v2NotificationPermission.status()
        guard !Task.isCancelled, v2Connection === connection, connection.access.state == .available else { return false }
        guard NativeNotificationPermission.allowed(permission) else {
            try? connection.model.setPushRoutingEnabled(false)
            requestV2PushRegistration()
            return false
        }
        return true
    }

    func refreshForRemotePush(_ payload: JSONValue?) async -> Bool {
        guard let payload else { return false }
        return await refreshV2ForPush(payload)
    }

    @discardableResult
    private func requestV2PushRegistration() -> Task<Bool, Never>? {
        guard sceneIsActive, !v2PushWaitsForInternalError, v2DepartureTask == nil, let connection = v2Connection,
              connection.access.state == .available, let context else { return nil }
        v2PushRegistrationRequested = true
        v2PushRetryTask?.cancel()
        v2PushRetryTask = nil
        if let current = v2PushRegistrationTask { return current }
        let task = Task { [weak self] in
            guard let self else { return false }
            var registered = false
            while self.v2PushRegistrationRequested, !Task.isCancelled, self.v2Connection === connection {
                self.v2PushRegistrationRequested = false
                registered = await self.registerV2Push(connection: connection, context: context)
            }
            if self.v2Connection === connection {
                self.v2PushRegistrationTask = nil
                if self.v2PushRegistrationRequested { self.requestV2PushRegistration() }
            }
            return registered
        }
        v2PushRegistrationTask = task
        return task
    }

    private func registerV2Push(connection: ClientAPIv2Connection, context: ProfileContext) async -> Bool {
        do {
            let permission = await v2NotificationPermission.status()
            guard !Task.isCancelled, v2Connection === connection else { return false }
            let allowed = NativeNotificationPermission.allowed(permission)
            if !allowed { try connection.model.setPushRoutingEnabled(false) }
            guard let record = try enrollment.load(), record.matchesNotificationIdentity(context.identity),
                  record.v2PushRegistration?.removalID == nil else { return false }
            let held = connection.model.snapshot.settings?.push
            var hasBinding = held?.bindingID != nil
            if !allowed, held == nil, record.v2PushRegistration?.registration == nil,
               record.v2PushRegistration?.permissionRemovalID == nil {
                // The server can already hold a binding before the local model
                // or registration journal has loaded one.
                do {
                    hasBinding = try await connection.push.status().bindingID != nil
                } catch {
                    if (error as? APIError)?.token != .internalError,
                       !Task.isCancelled, v2Connection === connection { scheduleV2PushRetry(connection: connection) }
                    throw error
                }
                let latestPermission = await v2NotificationPermission.status()
                guard !Task.isCancelled, v2Connection === connection else { return false }
                if NativeNotificationPermission.allowed(latestPermission) {
                    v2PushRegistrationRequested = true
                    return false
                }
            }
            let removal: UUID?
            if !allowed, permission == .denied || hasBinding {
                removal = try enrollment.updateV2PushRegistration(for: record) {
                    $0.preparePermissionRemoval(hasBinding: hasBinding)
                }
            } else {
                removal = record.v2PushRegistration?.permissionRemovalID
            }
            if let removal {
                do {
                    let response = try await connection.push.remove(idempotencyKey: removal)
                    try enrollment.updateV2PushRegistration(for: record) {
                        $0.confirmPermissionRemoval(removal, serverRevision: response.revision)
                    }
                    cancelV2PushRetry()
                } catch {
                    if (error as? APIError)?.token != .internalError,
                       !Task.isCancelled, v2Connection === connection { scheduleV2PushRetry(connection: connection) }
                    throw error
                }
                // Permission may have changed while the DELETE was in flight.
                if allowed { v2PushRegistrationRequested = true }
                return false
            }
            guard allowed else { return false }
            guard let address = try enrollment.v2APNsAddress() else {
                v2NotificationPermission.register()
                return false
            }
            let environment: APIPushEnvironment = PushRegistrationProfile.current == .sandbox ? .sandbox : .production
            let saved = try enrollment.updateV2PushRegistration(for: record) {
                try $0.prepareRegistration(token: ExactText(address), environment: environment,
                                           sharedMessages: connection.model.snapshot.sharedServerID != nil)
            }
            guard let saved else {
                if connection.model.snapshot.settings?.push == nil {
                    _ = try await connection.push.status()
                }
                try connection.model.setPushRoutingEnabled(true)
                return false
            }
            let accepted = try await connection.push.reconcileRegistration(saved) { revision in
                let permission = await self.v2NotificationPermission.status()
                guard !Task.isCancelled, self.v2Connection === connection else { return nil }
                guard NativeNotificationPermission.allowed(permission) else {
                    try connection.model.setPushRoutingEnabled(false)
                    self.v2PushRegistrationRequested = true
                    return nil
                }
                return try self.enrollment.updateV2PushRegistration(for: record) {
                    try $0.replaceStaleRegistration(saved, serverRevision: revision)
                }
            }
            guard let accepted, !Task.isCancelled, v2Connection === connection else { return false }
            try enrollment.updateV2PushRegistration(for: record) { $0.confirmRegistration(accepted) }
            let latestPermission = await v2NotificationPermission.status()
            guard !Task.isCancelled, v2Connection === connection else { return false }
            let stillAllowed = NativeNotificationPermission.allowed(latestPermission)
            try connection.model.setPushRoutingEnabled(stillAllowed)
            if !stillAllowed { v2PushRegistrationRequested = true }
            return stillAllowed
        } catch {
            if !Task.isCancelled, v2Connection === connection {
                if (error as? APIError)?.token == .internalError {
                    v2PushWaitsForInternalError = true
                    v2PushRegistrationRequested = false
                    cancelV2PushRetry()
                }
                recordPushRegistrationFailure(error)
            }
            return false
        }
    }

    private func cancelV2PushRetry() {
        v2PushRetryTask?.cancel()
        v2PushRetryTask = nil
        v2PushRetryAttempt = 0
    }

    private func scheduleV2PushRetry(connection: ClientAPIv2Connection) {
        guard sceneIsActive, v2PushRetryTask == nil, v2DepartureTask == nil else { return }
        v2PushRetryAttempt = min(v2PushRetryAttempt + 1, 6)
        let attempt = v2PushRetryAttempt
        v2PushRetryTask = Task { [weak self] in
            do { try await ActionOutbox.backoff(attempt, nil) } catch { return }
            guard !Task.isCancelled, let self, self.v2Connection === connection else { return }
            self.v2PushRetryTask = nil
            self.requestV2PushRegistration()
        }
    }

    func prepareV2SignOut(for record: NativeEnrollmentRecord) async {
        guard let connection = v2Connection, let context, record.matchesNotificationIdentity(context.identity) else {
            return
        }
        let task: Task<Void, Never>
        if let existing = v2DepartureTask {
            task = existing
        } else {
            let focus = v2FocusChannel
            task = Task { [weak self] in
                guard let self, self.v2Connection === connection else { return }
                self.v2ForegroundTask?.cancel()
                self.v2PushRegistrationTask?.cancel()
                self.cancelV2PushRetry()
                await self.v2FocusReporter.accountConnectionWillBeRemoved(sendSignedOut: false)
                await focus?.reportSignedOutBeforeClosing()
                connection.access.close()
            }
            v2DepartureTask = task
        }
        await task.value
    }

    var migrationCursor: Rev? { v2Connection?.model.heldCursor }

    func isPreparingV2SignOut(for expected: ProfileContext) -> Bool {
        context == expected && v2DepartureTask != nil
    }

    func deactivate() async {
        let v2Task = v2ForegroundTask
        let pushRegistration = v2PushRegistrationTask
        let priorV2 = v2Connection
        priorV2?.access.close()
        priorV2?.model.seal()
        cancelV2PushRetry()
        v2PushRegistrationTask = nil
        v2PushRegistrationRequested = false
        v2DepartureTask = nil
        pushRegistration?.cancel()
        let focus = v2FocusChannel
        v2FocusChannel = nil
        v2PushWaitsForInternalError = false
        v2ShowLookup?.cancel()
        v2ShowLookup = nil
        pendingV2Show = nil
        v2ForegroundTask = nil
        onV2AccountAccessChanged = nil
        onV2FeedOpened = nil
        v2Connection = nil
        v2Task?.cancel()
        featureFlags.reset()
        refreshGeneration = UUID()
        refreshFlights.reset()
        await v2FocusReporter.accountConnectionWillBeRemoved(sendSignedOut: false)
        await focus?.stop()
        context = nil
        repository = nil
        conversationAvailability.reset()
        snapshotState.failure = nil
        confirmedRelayContext = nil
        activeTransportAttemptID = nil
        foregroundDiagnosticContext = nil
        foregroundDiagnosticOperationsAtStart = [:]
        foregroundDiagnosticIntentIDs = [:]
        foregroundDiagnosticSnapshotAvailable = false
        foregroundDiagnosticAttemptID = UUID()
        foregroundDiagnosticOperations = .unavailable
        diagnosticJournal = nil
        await priorV2?.outbox.close()
        await v2Task?.value
        _ = await pushRegistration?.value
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
        if checkBlockedPush {
            return await refreshFlights.afterCurrent { [weak self] in
                guard let self else { return .unavailable }
                return await self.refreshSnapshot(userInitiated: true)
            }
        }
        return await refreshFlights.coalesced()
    }

    private func refreshSnapshot(userInitiated: Bool = false) async -> NativeRelayRefreshResult {
        if let connection = v2Connection, let context {
            let attempt = activeTransportAttemptID
            let openingCount = connection.sync.feedStatus.openingCount
            do {
                if connection.access.state == .paused {
                    try await connection.refreshMe(userInitiated: userInitiated)
                }
                guard v2Connection === connection, connection.access.state == .available else { return .unavailable }
                try await connection.catchUp(userInitiated: userInitiated)
                guard v2Connection === connection else { return .unavailable }
                confirmedRelayContext = context
                conversationAvailability.confirm(for: context, conversationsUnavailable: false)
                snapshotState.failure = nil
                return NativeRelayRefreshResult(relayConfirmed: true, pushRegistration: .notAttempted,
                    confirmedContext: context, confirmedTransportAttemptID: attempt)
            } catch {
                guard v2Connection === connection else { return .unavailable }
                let reason = ErrorLogReason.from(error: error)
                let connectivityFailure = attempt.flatMap { attempt in
                    reason.isConnectivityFailure
                        ? NativeRelayRefreshResult.ConnectivityFailure(
                            context: context, transportAttemptID: attempt, openingCount: openingCount,
                            suppressedWhileOpen: connection.sync.hasOpenFeed)
                        : nil
                }
                let result = NativeRelayRefreshResult.failed(error: error, connectivityFailure: connectivityFailure)
                if !didRecover(result, for: context) { snapshotState.failure = (context, result) }
                return result
            }
        }
        return .unavailable
    }
    /// Attempts durable message-open reports on the current authenticated
    /// relay session. With no active session, the store keeps them for the
    /// ordinary reconnect drain.
    func sendPendingMessageOpens(expected: ProfileContext) async {
        guard context == expected else { return }
        await v2Connection?.sendSavedContentOpens()
    }

    func hasConfirmedPriorityLevelsRelay(for expected: ProfileContext) -> Bool {
        guard let connection = v2Connection else { return false }
        return context == expected && sceneIsActive && connection.priorityLevelsCanSave
    }

    func refreshPriorityLevels(expected: ProfileContext) async {
        guard context == expected, sceneIsActive, priorityLevelsFeatureEnabled else { return }
        await v2Connection?.refreshPriorityLevels(userInitiated: true)
    }

    func saveV2PriorityLevels(_ levels: [PriorityLevel], expected: ProfileContext) async throws {
        guard let connection = v2Connection, context == expected, sceneIsActive,
              priorityLevelsFeatureEnabled else { throw ClientConnectionError.inactive }
        try await connection.savePriorityLevels(levels)
    }

    func alertsState(for expected: ProfileContext) async -> ClientAPIv2Connection.AlertsState? {
        guard context == expected, let connection = v2Connection else { return nil }
        let state = await connection.alertsState()
        guard context == expected, v2Connection === connection else { return nil }
        return state
    }

    func refreshAlerts(expected: ProfileContext) async {
        guard context == expected, sceneIsActive else { return }
        await v2Connection?.refreshSettings(userInitiated: true)
    }

    func saveAlerts(_ choice: APIAlerts, expected: ProfileContext) async throws {
        guard let connection = v2Connection, context == expected, sceneIsActive else {
            throw ClientConnectionError.inactive
        }
        try await connection.saveAlerts(choice)
    }

    func acknowledgeAlertsRefusal(_ id: UUID, expected: ProfileContext) async {
        guard context == expected else { return }
        await v2Connection?.acknowledgeAlertsRefusal(id)
    }
    private var priorityLevelsFeatureEnabled: Bool {
        featureFlags.isEnabled(.priorityLevelEditing)
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
                attemptID: attemptID, transportAttemptID: transportAttemptID)
        ]
    }

    /// Enrollment readiness requires an authenticated client API snapshot. A later
    /// push-register failure must not hide a working foreground connection.
    func confirmForegroundProgress(for expected: ProfileContext,
                                   checkBlockedPush: Bool = false,
                                   onProgress: @escaping @MainActor (NativeForegroundConnectProgress) -> Void = { _ in })
        async -> (progress: NativeForegroundConnectProgress, refresh: NativeRelayRefreshResult?) {
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
            return (failed, nil)
        }
        foregroundDiagnosticContext = expected
        let diagnosticAttemptID = UUID()
        foregroundDiagnosticAttemptID = diagnosticAttemptID
        foregroundDiagnosticOperations = .unavailable
        if let repository {
            do {
                let snapshot = try repository.snapshot(context: expected)
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
        var refreshResult: NativeRelayRefreshResult?
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
                if let refreshResult, self.didRecover(refreshResult, for: expected) { return }
                onProgress(progress)
            }
        }
        let result = await foregroundProgress.run(operation: { [weak self] in
            guard let self else { return false }
            let refresh = await self.refreshResultFromTrustedRelay(
                checkBlockedPush: checkBlockedPush)
            refreshResult = refresh
            let relayConfirmed = refresh.relayConfirmed
            let generationMatches = self.refreshGeneration == epoch
            let profileMatches = self.context == expected
            let relayContextMatches = refresh.confirms(expected, transportAttemptID: self.activeTransportAttemptID)
            guard self.foregroundProgress.progress.outcome == .connecting else { return false }
            self.foregroundProgress.recordSnapshotConfirmation(
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
                         receipt: nil)
        await progressDelivery?.value
        return (result, refreshResult)
    }

    func foregroundOperationDiagnostics(for expected: ProfileContext) -> NativeForegroundOperationSnapshot {
        guard foregroundDiagnosticContext == expected, context == expected else { return .unavailable }
        return foregroundDiagnosticOperations
    }

    private func prepareForegroundOperationDiagnostics(for expected: ProfileContext) async -> NativeForegroundOperationSnapshot {
        guard foregroundDiagnosticContext == expected, context == expected,
              foregroundDiagnosticSnapshotAvailable,
              let store = repository else {
            return .unavailable
        }
        guard !foregroundDiagnosticOperationsAtStart.isEmpty else {
            return NativeForegroundOperationSnapshot(available: true, operations: [])
        }
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

    /// A token callback can arrive after an in-flight registration has already read
    /// the protected address. Queue one more authenticated pass in that case.
    @discardableResult
    func refreshAfterPushAddressStored() async -> Bool {
        await requestV2PushRegistration()?.value ?? false
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

    func didRecover(_ result: NativeRelayRefreshResult, for expected: ProfileContext) -> Bool {
        guard let failure = result.connectivityFailure, failure.context == expected, context == expected,
              activeTransportAttemptID == failure.transportAttemptID, let connection = v2Connection else { return false }
        // A later feed drop cannot undo recovery of an earlier failure.
        return failure.suppressedWhileOpen || connection.sync.feedStatus.openingCount > failure.openingCount
    }

    private func hasOpenFeed(for expected: ProfileContext, attempt: UUID) -> Bool {
        context == expected && activeTransportAttemptID == attempt && sceneIsActive &&
            v2DepartureTask == nil && v2Connection?.access.state == .available &&
            v2Connection?.sync.hasOpenFeed == true
    }

    func refreshFailureMessage(for expected: ProfileContext) -> String? {
        guard snapshotState.failure?.context == expected, context == expected else { return nil }
        return snapshotState.failure?.result.failureMessage
    }

    /// A send joins only the same saved intent's flight, never the catch-up flight.
    func sendOriginalOperationForUserTap(_ intentID: UUID,
                                         expected: ProfileContext,
                                         onSendCallStateChange: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
                                         onSendCallCompleted: @MainActor () -> Void = {}) async throws {
        guard context == expected, let v2Connection else { throw ClientConnectionError.inactive }
        onSendCallStateChange(true)
        defer {
            onSendCallStateChange(false)
            onSendCallCompleted()
        }
        try await v2Connection.sendSavedAnswer(intentID)
    }
    func recordPushRegistrationFailure(_ error: Error? = nil,
                                      causeCode: String? = nil,
                                      area: NativeDiagnosticArea = .notifications) {
        recordDiagnostic(area, .pushRegistration, .failed,
                         error: error, causeCode: causeCode,
                         attemptID: activeTransportAttemptID)
    }

    func sendPendingConversationReadPositions(expected: ProfileContext) async {
        guard context == expected else { return }
        await v2Connection?.sendSavedConversationReads()
    }

    func fetchConversationFile(_ file: ConversationFile, to destination: URL, expected: ProfileContext) async throws {
        guard context == expected, let connection = v2Connection else { throw ClientConnectionError.inactive }
        guard case let .v2Download(id, contentType) = file.content else { throw CocoaError(.fileReadUnsupportedScheme) }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await connection.files.download(id, to: staged, expectedContentType: contentType)
        try await Task.detached { try ConversationFileStorage.verify(file, at: staged) }.value
        try Task.checkCancellation()
        guard context == expected, v2Connection === connection else { throw ClientConnectionError.inactive }
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    private func recordDiagnostic(_ area: NativeDiagnosticArea,
                                  _ phase: NativeDiagnosticPhase,
                                  _ transition: NativeDiagnosticTransition,
                                  error: Error? = nil,
                                  causeCode: String? = nil,
                                  terminalReason: NativeDiagnosticTerminalReason? = nil,
                                  attemptID: UUID? = nil,
                                  transportAttemptID: UUID? = nil,
                                  operationID: UUID? = nil,
                                  request: RequestKey? = nil,
                                  revision: UInt64? = nil,
                                  receipt: NativeDiagnosticReceiptState? = nil) {
        let associatedTransport = transportAttemptID ?? (attemptID == activeTransportAttemptID ? attemptID : nil)
        diagnosticJournal?.record(area: area, phase: phase, transition: transition,
            error: error, causeCode: causeCode, terminalReason: terminalReason,
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
