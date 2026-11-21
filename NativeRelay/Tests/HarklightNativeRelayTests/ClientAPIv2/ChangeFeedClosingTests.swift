import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

private func until(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @escaping () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out: \(message)", file: file, line: line)
}

private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var all: [Int] { lock.withLock { values } }
    func add(_ attempt: Int) { lock.withLock { values.append(attempt) } }
}

/// Contract round 17: the change feed's closing reasons are exactly revoked,
/// account_paused, server_shutdown, cursor_expired and storage_unavailable,
/// each handled one way; a drop without one is the network's or unknown.
final class ChangeFeedClosingTests: XCTestCase {
    private func start(_ server: FakeClientAPIServer, _ model: RecordingSyncModel, _ errors: RecordingErrorLogV2,
                       _ attempts: Attempts) -> (ChangeFeedSync, Task<Void, Never>) {
        let sync = ChangeFeedSync(transport: server, model: model.using(MemoryRevCursor(0)), errors: errors,
                                  waitBeforeRetry: { attempts.add($0); await Task.yield() })
        return (sync, Task { await sync.runForeground() })
    }

    func testCursorExpiredRebaselinesAtOnceAndReopens() async throws {
        let server = FakeClientAPIServer()
        let model = RecordingSyncModel(snapshotRev: { server.head })
        let errors = RecordingErrorLogV2()
        let (_, run) = start(server, model, errors, Attempts())
        await until("open") { server.openFeedCount == 1 }
        XCTAssertEqual(model.rebaselines, 0)
        server.closeFeeds(reason: "cursor_expired")
        await until("rebaselined and reopened") { model.rebaselines == 1 && server.openFeedCount == 1 }
        XCTAssertEqual(errors.reports.first?.reason, .serverReason("cursor_expired"))
        XCTAssertEqual(errors.reports.first?.initiator, .serverClosed)
        run.cancel()
    }

    func testShutdownAndStorageUnavailableReconnectAfterABoundedBackoff() async throws {
        for reason in ["server_shutdown", "storage_unavailable"] {
            let server = FakeClientAPIServer()
            let model = RecordingSyncModel(snapshotRev: { 0 })
            let errors = RecordingErrorLogV2()
            let attempts = Attempts()
            let (sync, run) = start(server, model, errors, attempts)
            await until("open") { server.openFeedCount == 1 }
            server.closeFeeds(reason: reason)
            await until("reconnected") { attempts.all.count == 1 && server.openFeedCount == 1 }
            XCTAssertEqual(attempts.all, [1], "\(reason): a backoff, not an immediate retry.")
            server.closeFeeds(reason: reason)
            await until("reconnected again") { attempts.all.count == 2 && server.openFeedCount == 1 }
            XCTAssertEqual(attempts.all, [1, 1], "\(reason): a feed that opened starts the backoff over.")
            server.commit("item", "{}")
            await until("still applying") { model.applied == [1] }
            XCTAssertEqual(errors.reports.map(\.reason), [.serverReason(reason), .serverReason(reason)])
            XCTAssertTrue(errors.reports.allSatisfy { $0.retryable && $0.initiator == .serverClosed })
            let state = await sync.liveState
            XCTAssertEqual(state, .live)
            run.cancel()
        }
    }

    func testRepeatedFailuresToReopenBackOffFurtherUpToTheCap() async throws {
        let server = FakeClientAPIServer()
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let attempts = Attempts()
        let (_, run) = start(server, model, RecordingErrorLogV2(), attempts)
        await until("open") { server.openFeedCount == 1 }
        server.feedFailure = URLError(.cannotConnectToHost)
        server.closeFeeds(reason: "server_shutdown")
        await until("several retries") { attempts.all.count >= 4 }
        XCTAssertEqual(Array(attempts.all.prefix(4)), [1, 2, 3, 4], "It keeps trying, waiting longer each time.")
        run.cancel()
    }

    func testRevokedStopsAndAccountPausedHolds() async throws {
        for (reason, expected) in [("revoked", ChangeFeedSync.LiveState.stopped),
                                   ("account_paused", .accountPaused)] {
            let server = FakeClientAPIServer()
            let errors = RecordingErrorLogV2()
            let (sync, run) = start(server, RecordingSyncModel(snapshotRev: { 0 }), errors, Attempts())
            await until("open") { server.openFeedCount == 1 }
            server.closeFeeds(reason: reason)
            _ = await run.value
            let state = await sync.liveState
            XCTAssertEqual(state, expected, reason)
            XCTAssertEqual(errors.reports.first?.initiator, reason == "revoked" ? .deviceRevoked : .serverClosed)
        }
    }

    func testInternalErrorBatchAndClosingPauseAtTheCursorUntilUserRetry() async throws {
        for framed in [false, true] {
            let server = FakeClientAPIServer()
            let cursor = MemoryRevCursor(0)
            let model = RecordingSyncModel(snapshotRev: { 0 })
            let errors = RecordingErrorLogV2()
            let sync = ChangeFeedSync(transport: server, model: model.using(cursor), errors: errors,
                                      waitBeforeRetry: { _ in
                XCTFail("Internal error must not reconnect automatically")
                throw CancellationError()
            })
            if !framed {
                server.commit("item", "{}")
                server.nextBatchFailure = APIError(status: 500, token: .internalError,
                                                    retryable: false, requestID: "req-render-batch")
            }
            let run = Task { await sync.runForeground() }
            defer { run.cancel() }
            if framed {
                await until("feed opened") { server.openFeedCount == 1 }
                server.closeFeeds(reason: "internal_error")
                await until("paused") { await sync.liveState == .paused(.serverClosed) }
                server.commit("item", "{}")
            }
            await run.value
            let state = await sync.liveState
            XCTAssertEqual(state, .paused(.serverClosed))
            XCTAssertEqual(try cursor.load(), 0)
            XCTAssertTrue(model.applied.isEmpty)
            XCTAssertEqual(errors.reports.first?.reason, .serverReason("internal_error"))
            XCTAssertEqual(errors.reports.first?.retryable, false)
            XCTAssertEqual(errors.reports.first?.phase, framed ? "closing" : "batch")
            if framed {
                XCTAssertNotNil(errors.reports.first?.correlation.requestID)
            } else {
                XCTAssertEqual(errors.reports.first?.correlation.requestID, "req-render-batch")
            }
            do {
                try await sync.catchUp()
                XCTFail("An automatic catch-up must leave the pause in place.")
            } catch let api as APIError {
                XCTAssertEqual(api.token, .internalError)
            }
            XCTAssertEqual(server.batchPositions, [0])

            try await sync.catchUp(userInitiated: true)
            XCTAssertEqual(server.batchPositions, [0, 0])
            XCTAssertEqual(try cursor.load(), 1)
            XCTAssertEqual(model.applied, [1])
        }
    }

    func testTransientBatch503StillBacksOffAndAppliesTheMissingEntry() async throws {
        let server = FakeClientAPIServer()
        server.commit("item", "{}")
        server.nextBatchFailure = APIError(status: 503, token: .retryLater, retryable: true, requestID: "req-busy")
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let errors = RecordingErrorLogV2()
        let attempts = Attempts()
        let (_, run) = start(server, model, errors, attempts)
        defer { run.cancel() }
        await until("the recovered batch applied") { model.applied == [1] && server.openFeedCount == 1 }
        XCTAssertEqual(attempts.all, [1])
        XCTAssertEqual(server.batchPositions, [0, 0])
        XCTAssertEqual(errors.reports.first?.reason, .serverReason("retry_later"))
        XCTAssertEqual(errors.reports.first?.retryable, true)
    }

    func testADropWithoutAClosingEventIsTheNetworksOrUnknown() async throws {
        let server = FakeClientAPIServer()
        let errors = RecordingErrorLogV2()
        let (_, run) = start(server, RecordingSyncModel(snapshotRev: { 0 }), errors, Attempts())
        await until("open") { server.openFeedCount == 1 }
        server.failFeeds(URLError(.networkConnectionLost))
        await until("reported") { !errors.reports.isEmpty }
        XCTAssertEqual(errors.reports.first?.initiator, .osNetwork)
        run.cancel()
        XCTAssertEqual(ErrorLogInitiator.forFailure(CocoaError(.fileReadUnknown)), .unknown)
        XCTAssertEqual(ErrorLogInitiator.forFailure(URLError(.timedOut)), .timeout)
    }
}
