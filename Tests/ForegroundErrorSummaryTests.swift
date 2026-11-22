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

    func testUserStatusKeepsReplayDetailsInDiagnosticCopyOnly() {
        let outcomes: [NativeForegroundConnectProgress.Outcome] = [.connecting, .incomplete, .confirmed]
        for outcome in outcomes {
            let progress = NativeForegroundConnectProgress(lastConfirmedStage: .nativeSyncResynced,
                webSocketOpenObserved: true, issue: nil, outcome: outcome)
            for technical in ["replay high-water", "relay acknowledgement", "foreground completion"] {
                XCTAssertFalse(progress.userFacingMessage.contains(technical))
            }
            if outcome != .confirmed {
                XCTAssertTrue(progress.userFacingMessage.contains("pending actions are saved"))
                XCTAssertTrue(progress.message.contains("relay acknowledgement"))
                XCTAssertTrue(summary(progress).contains("last_confirmed_phase=native_sync_resynced"))
                XCTAssertTrue(summary(progress).contains("post_ack_drain=not_started"))
            }
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


}
