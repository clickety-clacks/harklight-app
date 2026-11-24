import Foundation
import HarklightNativeRelay
import XCTest
@testable import Harklight

@MainActor
final class ErrorLogForegroundConnectTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("error-log-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func makeLog() -> ErrorLogStore {
        let store = ErrorLogStore(fileURL: fileURL,
                                  build: ErrorLogBuild(version: "1.0", build: "1", commit: "abcdef0"))
        addTeardownBlock { store.flush() }
        return store
    }

    private func cancelledReplay(attempt: UUID, transport: UUID) -> NativeForegroundConnectProgress {
        var progress = NativeForegroundConnectProgress(lastConfirmedStage: .nativeSyncResynced,
            webSocketOpenObserved: true, issue: nil, outcome: .incomplete,
            attemptID: attempt, transportAttemptID: transport)
        progress.postAckFailureStep = .replayConversationsAndAcknowledge
        progress.postAckFailureErrorCode = "posix_error_code_89"
        progress.terminalReason = .cancelled
        return progress
    }

    func testCancelledReplayIsRecordedWithPhaseCodeAndSafeIDsAndNoInvention() throws {
        let log = makeLog()
        let attempt = UUID()
        let transport = UUID()
        let record = try XCTUnwrap(ErrorLogForegroundConnectBridge.report(
            for: cancelledReplay(attempt: attempt, transport: transport)))
        log.report(record)

        let stored = try XCTUnwrap(log.records.first)
        XCTAssertEqual(stored.concern, .sync)
        XCTAssertEqual(stored.operation, "foreground_connect")
        XCTAssertEqual(stored.phase, "replay_conversations_and_acknowledge")
        XCTAssertEqual(stored.domain, "POSIX")
        XCTAssertEqual(stored.code, "89")
        XCTAssertEqual(stored.initiator, .unknown, "a bare cancel has no observed initiator")
        XCTAssertEqual(stored.correlation.attemptID, attempt)
        XCTAssertEqual(stored.correlation.transportAttemptID, transport)
    }

    func testOnlyObservedInitiatorsAreAttributed() {
        var progress = cancelledReplay(attempt: UUID(), transport: UUID())
        progress.terminalReason = .generationInvalidated
        XCTAssertEqual(ErrorLogForegroundConnectBridge.initiator(for: progress), .appLifecycle)
        progress.terminalReason = .deadlineExceeded
        XCTAssertEqual(ErrorLogForegroundConnectBridge.initiator(for: progress), .timeout)
        progress.terminalReason = .connectionNotConfirmed
        XCTAssertEqual(ErrorLogForegroundConnectBridge.initiator(for: progress), .unknown)
    }

    func testConnectingAttemptReportsNothing() {
        let progress = NativeForegroundConnectProgress(lastConfirmedStage: nil,
            webSocketOpenObserved: false, issue: nil, outcome: .connecting, attemptID: UUID())
        XCTAssertNil(ErrorLogForegroundConnectBridge.report(for: progress))
    }

    func testRecoveryResolvesButNeverErasesTheFailure() throws {
        let log = makeLog()
        let failed = cancelledReplay(attempt: UUID(), transport: UUID())
        ErrorLogForegroundConnectBridge.record(failed, in: log)
        let before = try XCTUnwrap(log.records.first)

        let confirmed = NativeForegroundConnectProgress(lastConfirmedStage: .foregroundConfirmed,
            webSocketOpenObserved: true, issue: nil, outcome: .confirmed, attemptID: UUID())
        ErrorLogForegroundConnectBridge.record(confirmed, in: log)

        let after = try XCTUnwrap(log.records.first)
        XCTAssertEqual(log.records.count, 1)
        XCTAssertNotNil(after.resolvedAt)
        XCTAssertEqual(after.phase, before.phase)
        XCTAssertEqual(after.code, before.code)
        XCTAssertEqual(after.correlation, before.correlation)
        XCTAssertTrue(ErrorLogDetails.text(for: after).contains("code: 89"))
    }

    func testLaunchKeepsFailureAfterTheNextAttemptReplacesLiveProgress() throws {
        let log = makeLog()
        let launch = NativeAppLaunch(arguments: ["Harklight"], errorLog: log)
        let failed = cancelledReplay(attempt: UUID(), transport: UUID())
        launch.recordForegroundConnectProgress(failed, operationSnapshot: .unavailable)
        let next = NativeForegroundConnectProgress(lastConfirmedStage: nil,
            webSocketOpenObserved: false, issue: nil, outcome: .connecting, attemptID: UUID())
        launch.recordForegroundConnectProgress(next, operationSnapshot: .unavailable)
        let confirmed = NativeForegroundConnectProgress(lastConfirmedStage: .foregroundConfirmed,
            webSocketOpenObserved: true, issue: nil, outcome: .confirmed, attemptID: next.attemptID)
        launch.recordForegroundConnectProgress(confirmed, operationSnapshot: .unavailable)

        launch.errorLogModel.refresh()
        XCTAssertNotEqual(launch.foregroundConnectProgress, failed, "live progress moved on")
        let kept = try XCTUnwrap(launch.errorLogModel.records.first)
        XCTAssertEqual(kept.code, "89")
        XCTAssertTrue(kept.isResolved)
    }
}
