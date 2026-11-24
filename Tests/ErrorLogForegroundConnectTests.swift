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
        let attempt = UUID()
        let tracker = ForegroundConnectProgressTracker()
        tracker.beginSession(transportAttemptID: attempt)
        let lifecycle = NativeRelayLifecycle(foregroundProgress: tracker)
        lifecycle.errorLog = log
        let launch = NativeAppLaunch(arguments: ["Harklight"], initialState: .live(store),
            initialEnrollmentRecord: record, errorLog: log)
        let inbox = LiveContentView(store: store, samples: SampleLibrary(), launch: launch)
        let transport = ReconnectingFeedTransport()
        let (retries, retry) = AsyncStream<Void>.makeStream()
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
            directory: nil, errors: log, foregroundOnlyWrites: true, waitBeforeRetry: { _ in
                var iterator = retries.makeAsyncIterator()
                _ = await iterator.next()
            }, onLiveState: { state in
                Task { @MainActor in await lifecycle.v2FeedStateChanged(state, context: context, attempt: attempt) }
            })
        launch.observeV2Connection(lifecycle)
        lifecycle.installV2Connection(connection, context: context, attempt: attempt)
        defer {
            lifecycle.sceneActivityChanged(isActive: false)
            transport.feedEvents.finish()
            transport.reopenedFeedEvents.finish()
            retry.finish()
        }
        try connection.model.apply([], cursor: 1)
        lifecycle.sceneActivityChanged(isActive: true)
        let (_, failedRefresh) = await lifecycle.confirmForegroundProgress(for: context) { progress in
            launch.recordForegroundConnectProgress(progress, operationSnapshot: .unavailable)
            store.connectionWarning = progress.outcome == .confirmed ? nil : progress.userFacingMessage
        }
        let oldRefresh = try XCTUnwrap(failedRefresh)
        try await waitUntil { self.unresolvedSync(in: log).contains("change_feed") }

        XCTAssertTrue(inbox.presentsConnectionFailure)
        XCTAssertEqual(inbox.connectionWarning, "Can't reach the server. Your pending actions are saved.")
        XCTAssertTrue(showsLiveUpdatesPaused(log))
        XCTAssertEqual(unresolvedSync(in: log), ["catch_up", "change_feed", "foreground_connect"])
        XCTAssertEqual(log.records.first { $0.operation == "foreground_connect" }?.code,
                       "relay_context_unconfirmed")

        _ = await lifecycle.refreshResultFromTrustedRelay()
        let coalesced = try XCTUnwrap(log.records.first { $0.operation == "catch_up" })
        let foreground = try XCTUnwrap(log.records.first { $0.operation == "foreground_connect" })
        XCTAssertEqual(coalesced.count, 2)
        XCTAssertLessThan(coalesced.occurredAt, foreground.occurredAt)
        XCTAssertGreaterThan(coalesced.lastAt, foreground.occurredAt)

        transport.restoreRequests()
        _ = try await connection.outbox.submit(target: "item:one", operation: "mark_seen",
            write: FrozenWrite(method: .put, path: "/v2/items/one/seen"))
        try await waitUntil { await connection.outbox.pending.isEmpty }
        XCTAssertEqual(transport.successfulWrites, 1)
        XCTAssertTrue(inbox.presentsConnectionFailure, "A successful write does not reopen the feed.")
        XCTAssertTrue(showsLiveUpdatesPaused(log))

        let dismissed = try XCTUnwrap(launch.foregroundConnectFailureKey)
        launch.dismissForegroundConnectFailure(dismissed)
        await lifecycle.v2FeedStateChanged(.live, context: context, attempt: UUID())
        XCTAssertFalse(inbox.presentsConnectionFailure)
        XCTAssertEqual(launch.foregroundConnectFailureKey, dismissed)
        XCTAssertTrue(showsLiveUpdatesPaused(log))

        let (releaseBatch, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        transport.holdNextBatch(until: releaseBatch)
        let lateRefresh = Task { await lifecycle.refreshResultFromTrustedRelay() }
        try await waitUntil { transport.heldBatchStarted }

        retry.yield(())
        transport.feedEvents.yield(.opened(requestID: "feed-opened"))
        try await waitUntil { self.unresolvedSync(in: log).isEmpty }
        XCTAssertTrue(lifecycle.hasConfirmedServerSnapshot(for: context))

        XCTAssertFalse(inbox.presentsConnectionFailure)
        XCTAssertNil(launch.foregroundConnectFailureKey)
        XCTAssertNil(inbox.connectionWarning)
        XCTAssertNil(lifecycle.refreshFailureMessage(for: context))
        XCTAssertTrue(lifecycle.didRecover(oldRefresh, for: context))
        XCTAssertFalse(showsLiveUpdatesPaused(log))
        XCTAssertEqual(unresolvedSync(in: log), [])
        XCTAssertEqual(Set(log.records.filter(\.isResolved).map(\.operation)),
                       ["catch_up", "change_feed", "foreground_connect"])

        transport.feedEvents.finish(throwing: URLError(.networkConnectionLost))
        try await waitUntil { !connection.sync.hasOpenFeed && self.showsLiveUpdatesPaused(log) }
        XCTAssertEqual(unresolvedSync(in: log), ["change_feed"])
        XCTAssertTrue(lifecycle.didRecover(oldRefresh, for: context))
        release.finish()
        let delayedFailure = await lateRefresh.value
        XCTAssertFalse(delayedFailure.relayConfirmed)
        XCTAssertTrue(lifecycle.didRecover(delayedFailure, for: context))
        XCTAssertEqual(unresolvedSync(in: log), ["change_feed"])
        XCTAssertNil(lifecycle.refreshFailureMessage(for: context))
        XCTAssertNil(inbox.connectionWarning)
        XCTAssertFalse(inbox.presentsConnectionFailure)
        XCTAssertNil(launch.foregroundConnectFailureKey)

        transport.failNextBatch()
        let failedAfterDrop = await lifecycle.refreshResultFromTrustedRelay()
        XCTAssertFalse(lifecycle.didRecover(failedAfterDrop, for: context))
        XCTAssertNotNil(lifecycle.refreshFailureMessage(for: context))
        XCTAssertEqual(unresolvedSync(in: log), ["catch_up", "change_feed"])

        retry.yield(())
        transport.reopenedFeedEvents.yield(.opened(requestID: "feed-reopened"))
        try await waitUntil { self.unresolvedSync(in: log).isEmpty }
        XCTAssertTrue(lifecycle.didRecover(failedAfterDrop, for: context))
        XCTAssertNil(lifecycle.refreshFailureMessage(for: context))
        XCTAssertNil(inbox.connectionWarning)
        XCTAssertFalse(inbox.presentsConnectionFailure)
        XCTAssertNil(launch.foregroundConnectFailureKey)

        // A stale .live from a replaced transport cannot clear even when the
        // current transport really is live.
        let replacementFailure = cancelledReplay(attempt: UUID(), transport: attempt)
        launch.recordForegroundConnectProgress(replacementFailure, operationSnapshot: .unavailable)
        let replacementKey = try XCTUnwrap(launch.foregroundConnectFailureKey)
        launch.dismissForegroundConnectFailure(replacementKey)
        await lifecycle.v2FeedStateChanged(.live, context: context, attempt: UUID())
        XCTAssertEqual(launch.foregroundConnectFailureKey, replacementKey)
        XCTAssertFalse(inbox.presentsConnectionFailure)
        XCTAssertEqual(unresolvedSync(in: log), ["foreground_connect"])
        await lifecycle.deactivate()
    }

    func testFeedOpeningPreservesAccountAndActionFailures() async throws {
        let log = makeLog()
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let store = try LivePresentationStore(store: repository, context: context)
        let launch = NativeAppLaunch(arguments: ["Harklight"], initialState: .live(store), errorLog: log)
        let lifecycle = NativeRelayLifecycle()
        launch.observeV2Connection(lifecycle)
        let attempt = UUID()
        let transport = ReconnectingFeedTransport()
        defer { transport.feedEvents.finish() }
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
            directory: nil, errors: log, foregroundOnlyWrites: true, onLiveState: { state in
                Task { @MainActor in await lifecycle.v2FeedStateChanged(state, context: context, attempt: attempt) }
            })
        lifecycle.installV2Connection(connection, context: context, attempt: attempt)
        try connection.model.apply([], cursor: 1)
        transport.restoreRequests()
        log.report(ErrorLogReport(concern: .sync, connectionRole: .stream,
            operation: "catch_up", phase: "batch", reason: .urlError(NSURLErrorSecureConnectionFailed),
            initiator: .unknown, retryable: true))
        log.report(ErrorLogReport(concern: .sync, connectionRole: .stream,
            operation: "foreground_connect", phase: "none_confirmed", reason: .app("relay_context_unconfirmed"),
            retryable: true, correlation: .init(attemptID: UUID(), transportAttemptID: UUID())))
        lifecycle.sceneActivityChanged(isActive: true)

        _ = try await connection.outbox.submit(target: "item:refused", operation: "mark_seen",
            write: FrozenWrite(method: .put, path: "/v2/items/refused/seen"))
        try await waitUntil { await connection.outbox.failedWrites.count == 1 }
        let failedBefore = await connection.outbox.failedWrites
        XCTAssertEqual(failedBefore.count, 1)
        for reason in ["internal_error", "account_paused", "revoked", "apply_failed"] {
            log.report(ErrorLogReport(concern: .sync, connectionRole: .stream,
                operation: "catch_up", phase: "batch", reason: .serverReason(reason),
                initiator: .serverClosed, retryable: true))
        }
        try await waitUntil { transport.feedRequested }
        transport.failNextBatch()
        let newerRefresh = await lifecycle.refreshResultFromTrustedRelay()
        transport.feedEvents.yield(.opened(requestID: "feed-opened"))
        try await waitUntil {
            log.records.contains {
                $0.operation == "foreground_connect" && $0.isResolved
            }
        }
        XCTAssertTrue(lifecycle.hasConfirmedServerSnapshot(for: context))

        let active = log.records.filter { !$0.isResolved }
        XCTAssertEqual(Set(active.filter { $0.concern == .sync }.map(\.code)),
                       ["internal_error", "account_paused", "revoked", "apply_failed"])
        XCTAssertTrue(showsLiveUpdatesPaused(log))
        XCTAssertTrue(lifecycle.didRecover(newerRefresh, for: context))
        XCTAssertNil(lifecycle.refreshFailureMessage(for: context))

        transport.failNextBatch()
        let whileOpen = await lifecycle.refreshResultFromTrustedRelay()
        XCTAssertTrue(lifecycle.didRecover(whileOpen, for: context))
        XCTAssertNil(lifecycle.refreshFailureMessage(for: context))
        XCTAssertEqual(Set(log.records.filter { $0.concern == .sync && !$0.isResolved }.map(\.code)),
                       ["internal_error", "account_paused", "revoked", "apply_failed"])
        XCTAssertEqual(active.filter { $0.concern == .actions }.map(\.operation), ["mark_seen"])
        let failedAfter = await connection.outbox.failedWrites
        XCTAssertEqual(failedAfter, failedBefore)
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

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the condition.", file: file, line: line)
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class ReconnectingFeedTransport: ClientAPITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var online = false
    private var writes = 0
    private var requestedFeed = false
    private var failBatch = false
    private var heldBatch: AsyncStream<Void>?
    private var startedHeldBatch = false
    private let feed: AsyncThrowingStream<FeedEvent, any Error>
    let feedEvents: AsyncThrowingStream<FeedEvent, any Error>.Continuation
    private let reopenedFeed: AsyncThrowingStream<FeedEvent, any Error>
    let reopenedFeedEvents: AsyncThrowingStream<FeedEvent, any Error>.Continuation

    init() {
        (feed, feedEvents) = AsyncThrowingStream.makeStream()
        (reopenedFeed, reopenedFeedEvents) = AsyncThrowingStream.makeStream()
    }

    func restoreRequests() { lock.withLock { online = true } }
    var successfulWrites: Int { lock.withLock { writes } }
    var feedRequested: Bool { lock.withLock { requestedFeed } }
    func failNextBatch() { lock.withLock { failBatch = true } }
    func holdNextBatch(until release: AsyncStream<Void>) { lock.withLock { heldBatch = release } }
    var heldBatchStarted: Bool { lock.withLock { startedHeldBatch } }

    func send(_ request: APIRequest) async throws -> APIResponse {
        if request.method == .put, request.path == "/v2/items/refused/seen" {
            throw APIError(status: 422, token: .invalidField, retryable: false, requestID: "refused")
        }
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
        let release = lock.withLock {
            let release = heldBatch
            heldBatch = nil
            if release != nil { startedHeldBatch = true }
            return release
        }
        if let release {
            for await _ in release {}
            throw URLError(.cannotConnectToHost)
        }
        return try lock.withLock {
            guard online else { throw URLError(.notConnectedToInternet) }
            if failBatch {
                failBatch = false
                throw URLError(.cannotConnectToHost)
            }
            return FeedBatch(changes: [], rev: after, more: false)
        }
    }

    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        lock.withLock {
            if requestedFeed { return reopenedFeed }
            requestedFeed = true
            return feed
        }
    }
}
