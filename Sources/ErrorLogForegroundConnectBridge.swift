import HarklightNativeRelay

/// Reports the foreground connection attempt (today's single connection) to the
/// Error Log, so a failure outlives the next attempt and the next recovery.
///
/// TEMPORARY: when the live-connection re-architecture lands, Sync and the
/// other concerns report directly and this adapter should be deleted.
enum ErrorLogForegroundConnectBridge {
    static let operation = "foreground_connect"

    /// The report for an attempt that did not confirm; nil while it is still
    /// connecting or after it confirmed.
    static func report(for progress: NativeForegroundConnectProgress) -> ErrorLogReport? {
        guard progress.outcome == .incomplete || progress.outcome == .timedOut else { return nil }
        return ErrorLogReport(
            concern: .sync,
            connectionRole: .stream,
            operation: operation,
            phase: progress.postAckFailureStep?.rawValue
                ?? progress.lastConfirmedStage?.diagnosticValue ?? "none_confirmed",
            reason: reason(for: progress),
            initiator: initiator(for: progress),
            retryable: true,
            correlation: ErrorLogCorrelation(attemptID: progress.attemptID,
                                             transportAttemptID: progress.transportAttemptID))
    }

    static func isConfirmed(_ progress: NativeForegroundConnectProgress) -> Bool {
        progress.outcome == .confirmed
    }

    static func record(_ progress: NativeForegroundConnectProgress, in log: any ErrorLogging) {
        if let report = report(for: progress) {
            log.report(report)
        } else if isConfirmed(progress) {
            log.resolve(concern: .sync, operation: operation,
                        resolvedBy: progress.attemptID?.uuidString.lowercased())
        }
    }

    static func reason(for progress: NativeForegroundConnectProgress) -> ErrorLogReason {
        // The post-ACK code and the observed error's cause are already
        // allowlisted tokens such as `posix_error_code_89`.
        let token = progress.postAckFailureErrorCode ?? progress.errorDetails?.cause
        if let token, let parsed = numericReason(from: token) { return parsed }
        if let token { return .app(token) }
        if let failure = progress.failureClass { return .app(failure.diagnosticValue) }
        return .app(progress.terminalReason?.rawValue ?? "connection_not_confirmed")
    }

    /// Only the app's own lifecycle decisions and the deadline are attributed.
    /// A bare cancel stays `unknown`: nothing observed says who cancelled it.
    static func initiator(for progress: NativeForegroundConnectProgress) -> ErrorLogInitiator {
        switch progress.terminalReason {
        case .generationInvalidated, .profileContextChanged: .appLifecycle
        case .deadlineExceeded: .timeout
        default: .unknown
        }
    }

    private static func numericReason(from token: String) -> ErrorLogReason? {
        let prefixes: [(String, (Int) -> ErrorLogReason)] = [
            ("url_session_error_code_", { .urlError($0) }),
            ("posix_error_code_", { .posix($0) }),
            ("cocoa_error_code_", { .cocoa($0) }),
            ("security_status_code_", { .osStatus($0) })
        ]
        for (prefix, make) in prefixes where token.hasPrefix(prefix) {
            if let code = Int(token.dropFirst(prefix.count)) { return make(code) }
        }
        return nil
    }
}
