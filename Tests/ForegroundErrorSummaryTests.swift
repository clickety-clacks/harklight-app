import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest
@testable import Harklight

@MainActor
final class ForegroundErrorSummaryTests: XCTestCase {
    private struct UnrecognizedFailure: LocalizedError {
        var errorDescription: String? { "private-message-content" }
    }

    private func summary(_ progress: NativeForegroundConnectProgress) -> String {
        NativeForegroundConnectDiagnostic(progress: progress, operationSnapshot: .unavailable,
            appVersion: "test", buildNumber: "test", executableSHA256: "unavailable").shareText
    }

    func testActualResetAndClosureReconnectButRefusalAndCancellationDoNot() {
        for error in [POSIXErrorCode.ECONNRESET, .ECONNABORTED, .ENOTCONN, .EPIPE] {
            XCTAssertTrue(NativeRelayLifecycle.isInterruptedConnection(
                NSError(domain: NSPOSIXErrorDomain, code: Int(error.rawValue))))
        }
        XCTAssertTrue(NativeRelayLifecycle.isInterruptedConnection(URLError(.networkConnectionLost)))
        XCTAssertFalse(NativeRelayLifecycle.isInterruptedConnection(CancellationError()))
        XCTAssertFalse(NativeRelayLifecycle.isInterruptedConnection(InstallationTransportError.serverRejected))
        XCTAssertFalse(NativeRelayLifecycle.isInterruptedConnection(AttentionStoreError.persistence("Cannot save")))
    }

    func testCaughtErrorsExposeTypeAndCauseWithoutMessageContent() async {
        let cases: [(Error, String, String)] = [
            (InboxPagingWireError.invalidFrame, "InboxPagingWireError", "inbox paging response was invalid"),
            (InboxPagingWireError.serverRefused("private-message-content"),
             "InboxPagingWireError", "server refused inbox paging"),
            (AttentionStoreError.inboxPageConflict, "AttentionStoreError", "conflicts with the saved message history"),
            (AttentionStoreError.persistence("private-message-content"),
             "AttentionStoreError", "Durable state could not be committed"),
            (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "private-message-content")),
             "DecodingError", "data was corrupted"),
            (UnrecognizedFailure(), "UnrecognizedFailure", "unrecognized error description omitted"),
            (NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue,
                     userInfo: [NSLocalizedDescriptionKey: "private-message-content",
                                NSURLErrorFailingURLStringErrorKey: "https://example.test/private-message-content"]),
             "NSError", "NSURLErrorDomain code -1005")
        ]
        for (error, type, description) in cases {
            let deadline = ForegroundConnectProgressTracker()
            deadline.beginSession(transportAttemptID: UUID())
            let result = await deadline.run(operation: {
                deadline.recordFailure(error)
                return false
            }, onProgress: { _ in })
            let text = summary(result)
            XCTAssertEqual(result.outcome, .incomplete)
            XCTAssertTrue(text.contains(type), text)
            XCTAssertTrue(text.contains(description), text)
            XCTAssertFalse(text.contains("unknown_error_class"), text)
            XCTAssertFalse(text.contains("private-message-content"), text)
        }
    }

    func testReconnectKeepsPriorErrorDetailsAndClearsCurrentCause() async {
        let deadline = ForegroundConnectProgressTracker()
        deadline.beginSession(transportAttemptID: UUID())
        let result = await deadline.run(operation: {
            deadline.recordFailure(AttentionStoreError.inboxCheckpointIncomplete)
            deadline.beginTransportAttempt(UUID())
            return false
        }, onProgress: { _ in })
        let text = summary(result)
        XCTAssertTrue(text.contains("\nerror_class=none_observed\n"))
        XCTAssertTrue(text.contains("\nerror_type=none_observed\n"))
        XCTAssertTrue(text.contains("previous_error_class=store_inbox_checkpoint_incomplete"))
        XCTAssertTrue(text.contains("previous_error_type=AttentionDomain.AttentionStoreError"))
        XCTAssertTrue(text.contains("previous_error_description=The bounded inbox checkpoint is missing durable page or receipt evidence."))
    }

    func testConfirmedAttemptDoesNotReportRecoveredErrorAsCurrentFailure() async {
        let deadline = ForegroundConnectProgressTracker()
        deadline.beginSession(transportAttemptID: UUID())
        let result = await deadline.run(operation: {
            deadline.recordFailure(InboxPagingWireError.invalidFrame)
            return true
        }, onProgress: { _ in })
        let text = summary(result)
        XCTAssertEqual(result.outcome, .confirmed)
        XCTAssertTrue(text.contains("\nerror_class=none_observed\n"))
        XCTAssertTrue(text.contains("\nerror_type=none_observed\n"))
        XCTAssertTrue(text.contains("\nerror_description=none_observed\n"))
    }
}
