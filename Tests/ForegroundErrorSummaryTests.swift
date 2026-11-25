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

    func testReconnectKeepsPriorErrorDetailsAndClearsCurrentCause() async {
        let deadline = ForegroundConnectProgressTracker()
        deadline.beginSession(transportAttemptID: UUID())
        let result = await deadline.run(operation: {
            deadline.recordFailure(AttentionStoreError.wrongAccount)
            deadline.beginTransportAttempt(UUID())
            return false
        }, onProgress: { _ in })
        let text = summary(result)
        XCTAssertTrue(text.contains("\nerror_class=none_observed\n"))
        XCTAssertTrue(text.contains("\nerror_type=none_observed\n"))
        XCTAssertTrue(text.contains("previous_error_class=store_wrong_account"))
        XCTAssertTrue(text.contains("previous_error_type=AttentionDomain.AttentionStoreError"))
        XCTAssertTrue(text.contains("previous_error_description=The request is outside the current account and device profile."))
    }


}
