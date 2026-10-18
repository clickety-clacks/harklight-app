import AttentionDomain
import CryptoKit
import Foundation

public enum NativeDiagnosticArea: String, Codable, Sendable {
    case enrollment
    case connection
    case relay
    case answer
    case conversation
    case upload
    case fileAccess
    case localStore
    case notifications
}

public enum NativeDiagnosticPhase: String, Codable, Sendable {
    case invitationVerification
    case enrollmentSubmission
    case enrollmentCleanup
    case accountRemoval
    case approvalCheck
    case joinCancellation
    case approvedConnection
    case serverTrust
    case clientIdentity
    case webSocketOpen
    case relayAdmission
    case ordinaryReplay
    case conversationReplay
    case acknowledgement
    case pushRegistration
    case originalOperationDelivery
    case discussionPreparation
    case discussionSubmission
    case uploadTransfer
    case uploadCleanup
    case fileDownload
    case fileRetention
    case filePreview
    case draftSave
    case draftLoad
    case projectionRefresh
    case postAckDrain
    case foregroundGenerationValidation
    case foregroundProfileValidation
    case foregroundContextValidation
    case foregroundCompletion
}

public enum NativeDiagnosticTransition: String, Codable, Sendable {
    case began
    case observed
    case retrying
    case completed
    case failed
    case cancelled
    case timedOut
    case accepted
    case rejected
    case unresolved
}

/// A bounded terminal state for a connection attempt. Kept separate from
/// `causeCode`: a timeout or context invalidation is an observed outcome even
/// when no underlying transport cause was observed.
public enum NativeDiagnosticTerminalReason: String, Codable, Sendable {
    case confirmed = "foreground_confirmed"
    case connectionNotConfirmed = "connection_not_confirmed"
    case deadlineExceeded = "foreground_deadline"
    case cancelled
    case generationInvalidated = "generation_invalidated"
    case profileContextChanged = "profile_context_changed"
    case relayContextUnconfirmed = "relay_context_unconfirmed"
}

/// The furthest post-ACK foreground boundary that actually completed.
public enum NativeDiagnosticPostAckBoundary: String, Codable, Sendable {
    case none = "none_observed"
    case nativeCursorAcknowledged = "native_sync_acknowledged"
    case coreDrainCompleted = "post_ack_core_drain_completed"
    case relayRefreshReturned = "post_ack_relay_refresh_returned"
    case foregroundConfirmed = "foreground_confirmed"
}

public enum NativeDiagnosticReceiptState: String, Codable, Sendable {
    case pendingUnconfirmed
    case acceptedAwaitingReplay
    case locallyLostUnconfirmed
    case terminal
    case repairRequired
    case unknown
}

/// A payload-free event emitted at native-client operation boundaries. Request
/// keys are represented by a stable SHA-256 tag; user text, URLs and file names
/// have no fields in this type.
public struct NativeClientDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let occurredAtMilliseconds: Int64
    public let area: NativeDiagnosticArea
    public let phase: NativeDiagnosticPhase
    public let transition: NativeDiagnosticTransition
    public let causeCode: String?
    public let terminalReason: NativeDiagnosticTerminalReason?
    public let postAckBoundary: NativeDiagnosticPostAckBoundary?
    public let postAckDrainTransition: NativeDiagnosticTransition?
    public let attemptID: UUID?
    public let transportAttemptID: UUID?
    public let operationID: UUID?
    public let requestTag: String?
    public let requestRevision: UInt64?
    public let receiptState: NativeDiagnosticReceiptState?

    private enum CodingKeys: String, CodingKey {
        case id, occurredAtMilliseconds, area, phase, transition, causeCode, terminalReason
        case postAckBoundary, postAckDrainTransition
        case attemptID, transportAttemptID, operationID, requestTag, requestRevision, receiptState
    }

    public init(area: NativeDiagnosticArea,
                phase: NativeDiagnosticPhase,
                transition: NativeDiagnosticTransition,
                causeCode: String? = nil,
                terminalReason: NativeDiagnosticTerminalReason? = nil,
                postAckBoundary: NativeDiagnosticPostAckBoundary? = nil,
                postAckDrainTransition: NativeDiagnosticTransition? = nil,
                attemptID: UUID? = nil,
                transportAttemptID: UUID? = nil,
                operationID: UUID? = nil,
                request: RequestKey? = nil,
                requestRevision: UInt64? = nil,
                receiptState: NativeDiagnosticReceiptState? = nil,
                id: UUID = UUID(),
                occurredAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) {
        self.id = id
        self.occurredAtMilliseconds = occurredAtMilliseconds
        self.area = area
        self.phase = phase
        self.transition = transition
        self.causeCode = Self.safeCauseCode(causeCode)
        self.terminalReason = terminalReason
        self.postAckBoundary = postAckBoundary
        self.postAckDrainTransition = postAckDrainTransition
        self.attemptID = attemptID
        self.transportAttemptID = transportAttemptID
        self.operationID = operationID
        requestTag = request.map(Self.requestTag(for:))
        self.requestRevision = requestRevision
        self.receiptState = receiptState
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        occurredAtMilliseconds = try values.decode(Int64.self, forKey: .occurredAtMilliseconds)
        area = try values.decode(NativeDiagnosticArea.self, forKey: .area)
        phase = try values.decode(NativeDiagnosticPhase.self, forKey: .phase)
        transition = try values.decode(NativeDiagnosticTransition.self, forKey: .transition)
        causeCode = Self.safeCauseCode(try values.decodeIfPresent(String.self, forKey: .causeCode))
        terminalReason = try values.decodeIfPresent(NativeDiagnosticTerminalReason.self, forKey: .terminalReason)
        postAckBoundary = try values.decodeIfPresent(NativeDiagnosticPostAckBoundary.self, forKey: .postAckBoundary)
        postAckDrainTransition = try values.decodeIfPresent(NativeDiagnosticTransition.self, forKey: .postAckDrainTransition)
        attemptID = try values.decodeIfPresent(UUID.self, forKey: .attemptID)
        transportAttemptID = try values.decodeIfPresent(UUID.self, forKey: .transportAttemptID)
        operationID = try values.decodeIfPresent(UUID.self, forKey: .operationID)
        requestTag = Self.safeRequestTag(try values.decodeIfPresent(String.self, forKey: .requestTag))
        requestRevision = try values.decodeIfPresent(UInt64.self, forKey: .requestRevision)
        receiptState = try values.decodeIfPresent(NativeDiagnosticReceiptState.self, forKey: .receiptState)
    }

    private static func requestTag(for request: RequestKey) -> String {
        let value = [request.accountScope.rawValue, request.senderID.rawValue, request.messageID.rawValue]
            .joined(separator: "\u{0}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func safeRequestTag(_ value: String?) -> String? {
        guard let value, value.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }

    private static func safeCauseCode(_ value: String?) -> String? {
        NativeDiagnosticCauseCode.safeCode(value)
    }
}

/// A nonblocking callback keeps transport and domain code independent of the
/// app's local persistence and presentation layers.
public typealias NativeClientDiagnosticSink = @Sendable (NativeClientDiagnosticEvent) -> Void

public enum NativeDiagnosticCauseCode {
    private static let knownCodes: Set<String> = [
        "cancelled", "unknown_error", "unknown_error_class", "unknown_server_reason",
        "foreground_deadline", "foreground_connection_confirmed", "foreground_connection_not_confirmed", "foreground_generation_invalidated",
        "foreground_profile_context_changed", "foreground_relay_context_unconfirmed", "approved_profile_not_active",
        "server_trust_rejected", "client_identity_challenge_rejected", "relay_protocol_error",
        "native_sync_error", "relay_redirect_refused", "notification_permission_not_granted", "application_support_unavailable",
        "unsupported_journal_version", "invalid_acceptance_sequence", "unexpected_relay_frame",
        "saved_operation_frame_mismatch", "relay_server_rejected", "relay_acknowledgement_behind",
        "invalid_relay_endpoint", "invalid_trust_anchor", "wrong_device_identity",
        "relay_fixture_profile", "relay_wrong_installation", "relay_inactive", "relay_invalid_replay",
        "relay_origin_content_missing", "relay_event_rejected", "relay_operation_result_mismatch",
        "conversation_invalid_binding", "conversation_request_missing", "conversation_conflict",
        "conversation_event_gap", "conversation_closed", "conversation_stale_revision",
        "conversation_submission_pending", "conversation_empty_draft", "conversation_file_mismatch",
        "conversation_upload_required", "conversation_upload_cap_exceeded",
        "store_stale_profile", "store_wrong_account", "store_request_missing", "store_request_conflict",
        "store_selector_expired", "store_invalid_draft", "store_invalid_submission",
        "store_unsupported_interface", "store_answer_too_large", "store_request_closed",
        "store_competing_intent", "store_intent_conflict", "store_intent_missing", "store_event_gap",
        "store_event_conflict", "store_origin_content_missing", "store_replay_already_active",
        "store_replay_not_active", "store_replay_incomplete", "store_fixture_operation",
        "store_acceptance_order_missing", "store_acceptance_order_duplicate", "store_invalid_projection",
        "store_persistence_failure", "enrollment_invalid_settings", "enrollment_invalid_identity",
        "enrollment_identity_storage", "enrollment_invalid_response", "enrollment_server_rejected",
        "enrollment_approval_pending", "enrollment_approval_expired", "enrollment_no_pending_request",
        "enrollment_wrong_approved_device", "enrollment_key_pending", "enrollment_key_in_use",
        "enrollment_identity_mismatch", "invitation_invalid", "invitation_expired", "join_existing_account",
        "join_saved_request_exists", "join_attempt_superseded", "join_request_expired", "join_invitation_used",
        "join_transport_refused", "join_request_not_found", "join_service_unavailable", "join_response_invalid",
        "join_approval_identity_mismatch", "local_example_operation_refused", "answer_request_not_open", "answer_input_incomplete",
        "answer_projection_unsupported", "file_access_error", "file_retention_error", "file_preview_error",
        "local_store_error", "local_projection_error", "notification_bundle_mismatch",
        "notification_empty_token", "notification_stored_token_invalid", "server_trust_validated", "client_identity_offered",
        "websocket_opened", "relay_admitted", "replay_requested_locally", "relay_resynced",
        "relay_acknowledged", "follow_on_replay_not_reached", "original_operation_terminal_not_observed",
        "original_operation_state_unavailable"
    ]

    private static let serverReasons: Set<String> = [
        "invalid_request", "invalid_cursor", "unauthorized", "forbidden", "not_found",
        "unsupported_version", "request_closed", "revision_mismatch", "upload_discarded",
        "op_id_mismatch", "conflict", "expired", "used", "too_large"
    ]

    /// Accepts only codes produced by this client. Sanitizing arbitrary text
    /// into a code-shaped string can still disclose an error message or token.
    public static func safeCode(_ value: String?) -> String? {
        guard let value else { return nil }
        if knownCodes.contains(value) { return value }
        for prefix in ["url_session_error_code_", "cocoa_error_code_", "posix_error_code_",
                       "security_status_code_", "file_http_status_"] where value.hasPrefix(prefix) {
            let suffix = value.dropFirst(prefix.count)
            let digits = suffix.first == "-" ? suffix.dropFirst() : suffix[...]
            if suffix.count <= 20, !digits.isEmpty,
               digits.utf8.allSatisfy({ (48...57).contains($0) }), Int(suffix) != nil {
                return value
            }
        }
        if let reason = serverReasons.first(where: { value == "server_\($0)" }) { return "server_\(reason)" }
        return "unknown_error"
    }

    public static func failureTransition(for error: Error) -> NativeDiagnosticTransition {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        if (error as? URLError)?.code == .timedOut { return .timedOut }
        return .failed
    }

    public static func unresolvedTransition(for error: Error) -> NativeDiagnosticTransition {
        switch failureTransition(for: error) {
        case .cancelled, .timedOut: failureTransition(for: error)
        default: .unresolved
        }
    }

    public static func forError(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let value = error as? URLError { return "url_session_error_code_\(value.errorCode)" }
        if let value = error as? InstallationTransportError {
            switch value {
            case .invalidEndpoint: return "invalid_relay_endpoint"
            case .invalidTrustAnchor: return "invalid_trust_anchor"
            case .wrongDeviceIdentity: return "wrong_device_identity"
            case .invalidServerTrust: return "server_trust_rejected"
            case .unexpectedServerFrame: return "unexpected_relay_frame"
            case .serverRejected: return "relay_server_rejected"
            case .acknowledgementBehind: return "relay_acknowledgement_behind"
            }
        }
        if let value = error as? ConversationFileTransportError {
            switch value {
            case let .server(status, _): return "file_http_status_\(status)"
            }
        }
        if let value = error as? NativeRelayCoreError {
            switch value {
            case .fixtureProfile: return "relay_fixture_profile"
            case .wrongInstallation: return "relay_wrong_installation"
            case .inactive: return "relay_inactive"
            case .invalidReplay: return "relay_invalid_replay"
            case .missingOriginContent: return "relay_origin_content_missing"
            case .eventRejected: return "relay_event_rejected"
            case .mismatchedOperationResult: return "relay_operation_result_mismatch"
            case .inboxPagingUnavailable: return "relay_inbox_paging_unavailable"
            case .inboxPagingBusy: return "relay_inbox_paging_busy"
            }
        }
        if let value = error as? ConversationError {
            switch value {
            case .invalidBinding: return "conversation_invalid_binding"
            case .missingRequest: return "conversation_request_missing"
            case .conflict: return "conversation_conflict"
            case .gap: return "conversation_event_gap"
            case .closed: return "conversation_closed"
            case .staleRevision: return "conversation_stale_revision"
            case .pendingSubmission: return "conversation_submission_pending"
            case .emptyDraft: return "conversation_empty_draft"
            case .fileMismatch: return "conversation_file_mismatch"
            case .uploadRequired: return "conversation_upload_required"
            case .uploadCapExceeded: return "conversation_upload_cap_exceeded"
            }
        }
        if let value = error as? AttentionStoreError {
            switch value {
            case .staleProfile: return "store_stale_profile"
            case .wrongAccount: return "store_wrong_account"
            case .requestMissing: return "store_request_missing"
            case .requestConflict: return "store_request_conflict"
            case .selectorExpired: return "store_selector_expired"
            case .invalidDraft: return "store_invalid_draft"
            case .invalidSubmission: return "store_invalid_submission"
            case .unsupportedInterface: return "store_unsupported_interface"
            case .answerTooLarge: return "store_answer_too_large"
            case .requestClosed: return "store_request_closed"
            case .competingIntent: return "store_competing_intent"
            case .intentConflict: return "store_intent_conflict"
            case .intentMissing: return "store_intent_missing"
            case .eventGap: return "store_event_gap"
            case .eventConflict: return "store_event_conflict"
            case .missingOriginContent: return "store_origin_content_missing"
            case .replayAlreadyActive: return "store_replay_already_active"
            case .replayNotActive: return "store_replay_not_active"
            case .replayIncomplete: return "store_replay_incomplete"
            case .fixtureOnlyOperation: return "store_fixture_operation"
            case .missingAcceptanceOrder: return "store_acceptance_order_missing"
            case .duplicateAcceptanceOrder: return "store_acceptance_order_duplicate"
            case .invalidProjection: return "store_invalid_projection"
            case .inboxCheckpointPending: return "store_inbox_checkpoint_pending"
            case .inboxCheckpointIncomplete: return "store_inbox_checkpoint_incomplete"
            case .inboxPageConflict: return "store_inbox_page_conflict"
            case .inboxStateUnrefreshed: return "store_inbox_state_unrefreshed"
            case .persistence: return "store_persistence_failure"
            }
        }
        let value = error as NSError
        switch value.domain {
        case NSURLErrorDomain: return "url_session_error_code_\(value.code)"
        case NSCocoaErrorDomain: return "cocoa_error_code_\(value.code)"
        case NSPOSIXErrorDomain: return "posix_error_code_\(value.code)"
        case "NSOSStatusErrorDomain": return "security_status_code_\(value.code)"
        default: return "unknown_error"
        }
    }

    /// Only known protocol tokens are copied into a diagnostic. Arbitrary
    /// server strings are omitted because an error frame is not a trusted log.
    public static func serverReason(_ value: String?) -> String {
        guard let value else { return "relay_server_rejected" }
        guard serverReasons.contains(value) else { return "unknown_server_reason" }
        return "server_\(value)"
    }
}
