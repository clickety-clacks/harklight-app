import AttentionDomain
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

extension ErrorLogForegroundConnectTests {
    func testOfflineForegroundConnectRecoversWhenTheFeedOpensByItself() async throws {
        let log = makeLog()
        let record = NativeEnrollmentRecord(host: "relay.example", enrollmentPort: 18444, relayPort: 18443,
            trustedRootDER: Data([1]), identityLabel: "test", deviceID: "device",
            approvalCode: "TEST", statusSecret: "test", expiresAt: nil, statusExpiresAt: nil, personID: "person")
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText(record.profileAuthority),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let store = try LivePresentationStore(store: repository, context: context)
        let lifecycle = NativeRelayLifecycle()
        lifecycle.errorLog = log
        let launch = NativeAppLaunch(arguments: ["Harklight"], initialState: .live(store),
            initialEnrollmentRecord: record, errorLog: log)
        let inbox = LiveContentView(store: store, samples: SampleLibrary(), launch: launch)
        let attempt = UUID()
        let transport = ReconnectingFeedTransport()
        let (retries, retry) = AsyncStream<Void>.makeStream()
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
            directory: nil, errors: log, foregroundOnlyWrites: true, waitBeforeRetry: { _ in
                var iterator = retries.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            }, onLiveState: { state in
                Task { @MainActor in await lifecycle.v2FeedStateChanged(state, context: context, attempt: attempt) }
            })
        lifecycle.installV2Connection(connection, context: context, attempt: attempt)
        defer {
            transport.feedEvents.finish()
            retry.finish()
        }
        try connection.model.apply([], cursor: 1)
        lifecycle.sceneActivityChanged(isActive: true)
        _ = await lifecycle.confirmForegroundProgress(for: context) { progress in
            launch.recordForegroundConnectProgress(progress, operationSnapshot: .unavailable)
            store.connectionWarning = progress.outcome == .confirmed ? nil : progress.userFacingMessage
        }
        try await waitUntil { self.unresolvedSync(in: log).contains("change_feed") }

        XCTAssertTrue(inbox.presentsConnectionFailure)
        XCTAssertEqual(inbox.connectionWarning, "Can't reach the server. Your pending actions are saved.")
        XCTAssertTrue(showsLiveUpdatesPaused(log))
        XCTAssertEqual(unresolvedSync(in: log), ["catch_up", "change_feed", "foreground_connect"])

        transport.restoreRequests()
        _ = try await connection.outbox.submit(target: "item:one", operation: "mark_seen",
            write: FrozenWrite(method: .put, path: "/v2/items/one/seen"))
        await connection.outbox.flush()
        let pending = await connection.outbox.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(transport.successfulWrites, 1)
        XCTAssertTrue(inbox.presentsConnectionFailure, "A successful write does not reopen the feed.")
        XCTAssertTrue(showsLiveUpdatesPaused(log))

        retry.yield(())
        transport.feedEvents.yield(.opened(requestID: "feed-opened"))
        try await waitUntil { lifecycle.hasConfirmedServerSnapshot(for: context) }

        XCTAssertFalse(inbox.presentsConnectionFailure)
        XCTAssertNil(inbox.connectionWarning)
        XCTAssertFalse(showsLiveUpdatesPaused(log))
        XCTAssertEqual(unresolvedSync(in: log), [])
        XCTAssertEqual(Set(log.records.filter(\.isResolved).map(\.operation)),
                       ["catch_up", "change_feed", "foreground_connect"])

        transport.feedEvents.finish(throwing: URLError(.networkConnectionLost))
        try await waitUntil { self.showsLiveUpdatesPaused(log) }
        XCTAssertEqual(unresolvedSync(in: log), ["change_feed"])
        await lifecycle.deactivate()
    }

    private func unresolvedSync(in log: ErrorLogStore) -> Set<String> {
        Set(log.records.filter { $0.concern == .sync && !$0.isResolved }.map(\.operation))
    }

    private func showsLiveUpdatesPaused(_ log: ErrorLogStore) -> Bool {
        if case .failing? = ErrorLogDisplay.inContext(records: log.records, surface: .liveIndicator, now: Date()) {
            return true
        }
        return false
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class ReconnectingFeedTransport: ClientAPITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var online = false
    private var writes = 0
    private let feed: AsyncThrowingStream<FeedEvent, any Error>
    let feedEvents: AsyncThrowingStream<FeedEvent, any Error>.Continuation

    init() { (feed, feedEvents) = AsyncThrowingStream.makeStream() }

    func restoreRequests() { lock.withLock { online = true } }
    var successfulWrites: Int { lock.withLock { writes } }

    func send(_ request: APIRequest) async throws -> APIResponse {
        guard request.method == .put, request.path == "/v2/items/one/seen" else {
            throw URLError(.notConnectedToInternet)
        }
        return try lock.withLock {
            guard online else { throw URLError(.notConnectedToInternet) }
            writes += 1
            return APIResponse(status: 200, requestID: "write", body: Data(#"{"rev":1}"#.utf8))
        }
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        guard lock.withLock({ online }) else { throw URLError(.notConnectedToInternet) }
        return FeedBatch(changes: [], rev: after, more: false)
    }

    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> { feed }
}
