import AttentionDomain
import CryptoKit
import Foundation
import HarklightNativeRelay
import Observation

@MainActor
@Observable
final class NativeClientDiagnosticJournal {
    enum PersistenceStatus: String {
        case new
        case saved
        case readFailed
        case writeFailed
        case unavailable
        case unsupportedVersion
    }

    private struct JournalFile: Codable {
        let version: Int
        let events: [NativeClientDiagnosticEvent]
    }

    static let retainedEventLimit = 256

    private(set) var events: [NativeClientDiagnosticEvent] = []
    private(set) var persistenceStatus: PersistenceStatus = .new
    private(set) var persistenceCauseCode: String?
    private let fileURL: URL?

    init(fileURL: URL? = Self.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    var hasEvents: Bool { !events.isEmpty || persistenceStatus != .new }

    func record(_ event: NativeClientDiagnosticEvent) {
        // URLSession and actor callbacks may reach the main-actor journal in a
        // different order than they occurred. Keep the exported history in
        // event-time order while preserving arrival order for equal timestamps.
        let insertionIndex = events.firstIndex {
            $0.occurredAtMilliseconds > event.occurredAtMilliseconds
        } ?? events.endIndex
        events.insert(event, at: insertionIndex)
        if events.count > Self.retainedEventLimit {
            events.removeFirst(events.count - Self.retainedEventLimit)
        }
        persist()
    }

    func record(area: NativeDiagnosticArea,
                phase: NativeDiagnosticPhase,
                transition: NativeDiagnosticTransition,
                error: Error? = nil,
                causeCode: String? = nil,
                attemptID: UUID? = nil,
                transportAttemptID: UUID? = nil,
                operationID: UUID? = nil,
                request: RequestKey? = nil,
                requestRevision: UInt64? = nil,
                receiptState: NativeDiagnosticReceiptState? = nil) {
        record(NativeClientDiagnosticEvent(area: area, phase: phase, transition: transition,
            causeCode: causeCode ?? error.map(Self.causeCode(for:)), attemptID: attemptID,
            transportAttemptID: transportAttemptID,
            operationID: operationID, request: request, requestRevision: requestRevision,
            receiptState: receiptState))
    }

    var shareText: String {
        var lines = [
            "Harklight client diagnostics",
            "format_version=1",
            "app_version=\(bundleValue("CFBundleShortVersionString"))",
            "app_build=\(bundleValue("CFBundleVersion"))",
            "app_executable_sha256=\(NativeForegroundConnectDiagnostic.executableSHA256(for: Bundle.main.executableURL))",
            "journal_status=\(persistenceStatus.rawValue)",
            "journal_cause=\(persistenceCauseCode ?? "none_observed")",
            "retained_event_count=\(events.count)",
            "retained_event_limit=\(Self.retainedEventLimit)",
            "older_events_may_be_omitted=yes"
        ]
        for event in events {
            var fields = [
                "event_id=\(event.id.uuidString.lowercased())",
                "time_ms=\(event.occurredAtMilliseconds)",
                "area=\(event.area.rawValue)",
                "phase=\(event.phase.rawValue)",
                "transition=\(event.transition.rawValue)",
                "cause=\(event.causeCode ?? "none_observed")"
            ]
            if let id = event.attemptID { fields.append("attempt_id=\(id.uuidString.lowercased())") }
            if let id = event.transportAttemptID { fields.append("transport_attempt_id=\(id.uuidString.lowercased())") }
            if let id = event.operationID { fields.append("operation_id=\(id.uuidString.lowercased())") }
            if let tag = event.requestTag { fields.append("request_tag_sha256=\(tag)") }
            if let revision = event.requestRevision { fields.append("request_revision=\(revision)") }
            if let receipt = event.receiptState { fields.append("receipt_state=\(receipt.rawValue)") }
            lines.append(fields.joined(separator: " "))
        }
        if events.isEmpty { lines.append("events=none_retained") }
        lines.append("payloads_urls_file_names_credentials_and_keys=excluded")
        return lines.joined(separator: "\n")
    }

    private func load() {
        guard let fileURL else {
            persistenceStatus = .unavailable
            return
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let saved = try JSONDecoder().decode(JournalFile.self, from: data)
            guard saved.version == 1 else {
                persistenceStatus = .unsupportedVersion
                persistenceCauseCode = "unsupported_journal_version"
                return
            }
            let ordered = saved.events.enumerated().sorted { lhs, rhs in
                if lhs.element.occurredAtMilliseconds == rhs.element.occurredAtMilliseconds {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.occurredAtMilliseconds < rhs.element.occurredAtMilliseconds
            }.map(\.element)
            events = Array(ordered.suffix(Self.retainedEventLimit))
            persistenceStatus = .saved
        } catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain && value.code == CocoaError.fileReadNoSuchFile.rawValue {
                persistenceStatus = .new
            } else {
                persistenceStatus = .readFailed
                persistenceCauseCode = Self.causeCode(for: error)
            }
        }
    }

    private func persist() {
        guard let fileURL else {
            persistenceStatus = .unavailable
            persistenceCauseCode = "application_support_unavailable"
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.sorted.encode(JournalFile(version: 1, events: events))
            try data.write(to: fileURL, options: .atomic)
            persistenceStatus = .saved
            persistenceCauseCode = nil
        } catch {
            persistenceStatus = .writeFailed
            persistenceCauseCode = Self.causeCode(for: error)
        }
    }

    private static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Harklight", isDirectory: true)
            .appendingPathComponent("native-client-diagnostics-v1.json", isDirectory: false)
    }

    private func bundleValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "unavailable" }
        return value
    }

    private static func causeCode(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let value = error as? DevelopmentAPNsAddressStore.AddressError {
            switch value {
            case .emptyToken: return "notification_empty_token"
            case .invalidStoredToken: return "notification_stored_token_invalid"
            }
        }
        if let value = error as? NativeEnrollmentError {
            switch value {
            case .invalidSettings: return "enrollment_invalid_settings"
            case .invalidIdentity: return "enrollment_invalid_identity"
            case .identityStorage: return "enrollment_identity_storage"
            case .invalidServerResponse: return "enrollment_invalid_response"
            case .serverRejected: return "enrollment_server_rejected"
            case .approvalPending: return "enrollment_approval_pending"
            case .approvalExpired: return "enrollment_approval_expired"
            case .noPendingEnrollment: return "enrollment_no_pending_request"
            case .wrongApprovedDevice: return "enrollment_wrong_approved_device"
            case .keyPending: return "enrollment_key_pending"
            case .keyInUse: return "enrollment_key_in_use"
            case .preparedIdentityMismatch: return "enrollment_identity_mismatch"
            }
        }
        if let value = error as? NativeJoinInvitationError {
            switch value {
            case .invalid: return "invitation_invalid"
            case .expired: return "invitation_expired"
            }
        }
        if let value = error as? NativeJoinError {
            switch value {
            case .existingAccount: return "join_existing_account"
            case .savedRequest: return "join_saved_request_exists"
            case .superseded: return "join_attempt_superseded"
            case .expired: return "join_request_expired"
            case .used: return "join_invitation_used"
            case .refused: return "join_transport_refused"
            case .notFound: return "join_request_not_found"
            case .unavailable: return "join_service_unavailable"
            case .invalidResponse: return "join_response_invalid"
            case .wrongApproval: return "join_approval_identity_mismatch"
            }
        }
        if let value = error as? LiveReplyError {
            switch value {
            case .localExample: return "local_example_operation_refused"
            case .notOpen: return "answer_request_not_open"
            case .incomplete: return "answer_input_incomplete"
            case .unsupported: return "answer_projection_unsupported"
            }
        }
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
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
