import Foundation
import XCTest
@testable import HarklightNativeRelay

final class ErrorLogTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
    }

    private let build = ErrorLogBuild(version: "1.4", build: "293", commit: "eba4697abcdef")
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("error-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("error-log.json") }

    private func makeStore(file: URL? = nil, clock: Clock) -> ErrorLogStore {
        ErrorLogStore(fileURL: file ?? fileURL, build: build, now: { clock.now })
    }

    private func report(_ concern: ErrorLogConcern = .snapshot, operation: String = "read_inbox",
                        phase: String = "fetch", reason: ErrorLogReason = .urlError(-1001),
                        initiator: ErrorLogInitiator = .timeout,
                        correlation: ErrorLogCorrelation = .none) -> ErrorLogReport {
        ErrorLogReport(concern: concern, connectionRole: concern == .sync ? .stream : .request,
                       operation: operation, phase: phase, reason: reason, initiator: initiator,
                       retryable: true, correlation: correlation)
    }

    // MARK: Coalescing

    func testRepeatsOfSameConcernOperationAndCodeCoalesce() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(report())
        clock.advance(30)
        store.report(report())
        clock.advance(30)
        store.report(report())

        XCTAssertEqual(store.records.count, 1)
        let record = store.records[0]
        XCTAssertEqual(record.count, 3)
        XCTAssertEqual(record.occurredAt, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(record.lastAt, Date(timeIntervalSince1970: 1_000_060))
    }

    func testDifferentCodeOperationOrConcernDoNotCoalesce() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(report())
        store.report(report(reason: .urlError(-1009)))
        store.report(report(operation: "read_inbox_page"))
        store.report(report(.actions))
        XCTAssertEqual(store.records.count, 4)
    }

    func testFailureAfterResolutionIsANewRecordAndKeepsTheResolvedOne() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(report())
        clock.advance(10)
        store.resolve(concern: .snapshot, operation: "read_inbox")
        clock.advance(10)
        store.report(report())

        let records = store.records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.filter(\.isResolved).count, 1)
        XCTAssertEqual(records.filter { !$0.isResolved }.count, 1)
    }

    // MARK: Resolve without erasure

    func testResolveSetsResolvedFieldsAndKeepsEveryOtherField() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        let attempt = UUID()
        store.report(report(.sync, operation: "subscribe_conversation", phase: "apply",
                            reason: .posix(89), initiator: .appLifecycle,
                            correlation: ErrorLogCorrelation(attemptID: attempt, serverConnectionID: "conn-7f3a")))
        let before = store.records[0]
        clock.advance(5)
        store.resolve(concern: .sync, operation: "subscribe_conversation")

        let after = store.records[0]
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(after.resolvedAt, Date(timeIntervalSince1970: 1_000_005))
        XCTAssertEqual(after.resolvedBy, "success")
        var unresolvedView = after
        unresolvedView.resolvedAt = nil
        unresolvedView.resolvedBy = nil
        XCTAssertEqual(unresolvedView, before, "resolve must change only resolvedAt and resolvedBy")
        XCTAssertEqual(after.correlation.attemptID, attempt)
        XCTAssertEqual(after.domain, "POSIX")
        XCTAssertEqual(after.code, "89")
    }

    func testResolveOnlyTouchesTheSameConcernAndOperation() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(report(.snapshot, operation: "read_inbox"))
        store.report(report(.snapshot, operation: "read_entries"))
        store.report(report(.actions, operation: "read_inbox"))
        store.resolve(concern: .snapshot, operation: "read_inbox")

        let resolved = store.records.filter(\.isResolved)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].concern, .snapshot)
        XCTAssertEqual(resolved[0].operation, "read_inbox")
    }

    func testResolveCanBeAttributedToASafeIdentifier() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(report())
        let attempt = UUID().uuidString.lowercased()
        store.resolve(concern: .snapshot, operation: "read_inbox", resolvedBy: attempt)
        XCTAssertEqual(store.records[0].resolvedBy, attempt)
        store.report(report())
        store.resolve(concern: .snapshot, operation: "read_inbox", resolvedBy: "Bearer abc def")
        XCTAssertEqual(store.records.first { $0.resolvedBy != attempt }?.resolvedBy, "success")
    }

    func testReadingAndCopyingNeverConsumeRecords() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(report())
        store.report(report(.actions, operation: "mark_seen"))
        let first = store.records
        _ = ErrorLogDetails.text(for: first[0])
        _ = ErrorLogDetails.text(for: first)
        _ = ErrorLogDisplay.inContext(records: first, concern: .snapshot, now: clock.now)
        XCTAssertEqual(store.records, first)
        XCTAssertEqual(ErrorLogStore(fileURL: fileURL, build: build).records, first)
    }

    // MARK: Redaction

    func testLeakFixtureNeverReachesAnyRecordFileOrCopiedText() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        let secretToken = "eyJhbGciOiJIUzI1NiJ9.sk_live_9f8e7d6c5b4a"
        let messageText = "Hi Dana, the launch password is hunter2, call me"
        let url = "https://example.invalid/inbox?access_token=\(secretToken)"
        let file = "Quarterly salary review.pdf"
        let display = "Dana Whitfield"

        let leak = ErrorLogReport(
            concern: .actions, connectionRole: .request,
            operation: "reply \(messageText)", phase: "Bearer \(secretToken)",
            reason: .serverReason("storage failed for \(file) sent by \(display): \(messageText)"),
            initiator: .unknown, retryable: false,
            correlation: ErrorLogCorrelation(serverConnectionID: url))
        store.report(leak)
        store.report(ErrorLogReport(concern: .actions, connectionRole: .request, operation: url,
                                    phase: file, reason: .app(display), retryable: false,
                                    correlation: ErrorLogCorrelation(serverConnectionID: secretToken + "?x=1")))
        store.report(ErrorLogReport(concern: .snapshot, connectionRole: .request, operation: "read_inbox",
                                    phase: "fetch", reason: .app(messageText), retryable: true))
        store.resolve(concern: .actions, operation: "read_inbox", resolvedBy: "token=\(secretToken)")

        let file_bytes = try String(contentsOf: fileURL, encoding: .utf8)
        let everything = file_bytes + ErrorLogDetails.text(for: store.records) +
            String(describing: store.records)
        for forbidden in ["eyJ", "sk_live", "Bearer", "access_token", "hunter2", "password", "Dana",
                          "Whitfield", "launch", "https", "example.invalid", "Quarterly", "salary",
                          ".pdf", "?", "token=", "Hi "] {
            XCTAssertFalse(everything.contains(forbidden), "leaked \(forbidden)")
        }
        let leaked = store.records.filter { $0.concern == .actions }
        XCTAssertFalse(leaked.isEmpty)
        for record in leaked {
            XCTAssertEqual(record.operation, "other")
            XCTAssertEqual(record.code, "other")
            XCTAssertNil(record.correlation.serverConnectionID)
        }
        XCTAssertEqual(store.records.first { $0.concern == .snapshot }?.code, "other")
    }

    func testOnlyAllowlistedServerReasonsAreKept() {
        XCTAssertEqual(ErrorLogReason.serverReason("storage_unavailable").code, "storage_unavailable")
        XCTAssertEqual(ErrorLogReason.serverReason("wrong_connection_role").code, "wrong_connection_role")
        XCTAssertEqual(ErrorLogReason.serverReason("some new reason text").code, "other")
        XCTAssertEqual(ErrorLogReason.serverReason("secret_reason_not_on_the_list").code, "other")
        XCTAssertEqual(ErrorLogReason.serverReason("").code, "other")
    }

    func testSafeServerConnectionIDIsKeptAndUnsafeOneIsDropped() {
        XCTAssertEqual(ErrorLogCorrelation(serverConnectionID: "conn-7f3a_9").serverConnectionID, "conn-7f3a_9")
        XCTAssertNil(ErrorLogCorrelation(serverConnectionID: "has space").serverConnectionID)
        XCTAssertNil(ErrorLogCorrelation(serverConnectionID: String(repeating: "a", count: 65)).serverConnectionID)
    }

    func testErrorClassificationUsesDomainAndCodeOnly() {
        let url = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "secret message body",
                                                 NSURLErrorFailingURLStringErrorKey: "https://x.invalid/?t=1"])
        XCTAssertEqual(ErrorLogReason.from(error: url), .urlError(-1001))
        XCTAssertEqual(ErrorLogReason.from(error: NSError(domain: NSPOSIXErrorDomain, code: 89)), .posix(89))
        XCTAssertEqual(ErrorLogReason.from(error: CancellationError()), .app("cancelled"))
        XCTAssertEqual(ErrorLogReason.from(error: NSError(domain: "Custom text domain", code: 5)).code, "other")
    }

    func testRecordedFieldsAreTheSpecifiedShape() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        let ids = ErrorLogCorrelation(attemptID: UUID(), transportAttemptID: UUID(),
                                      serverConnectionID: "conn-1", clientOperationID: UUID())
        store.report(report(.sync, operation: "subscribe_conversation", phase: "apply",
                            reason: .serverReason("storage_unavailable"), initiator: .serverClosed,
                            correlation: ids))
        let record = store.records[0]
        XCTAssertEqual(record.build, ErrorLogBuild(version: "1.4", build: "293", commit: "eba4697"))
        XCTAssertEqual(record.concern, .sync)
        XCTAssertEqual(record.connectionRole, .stream)
        XCTAssertEqual(record.operation, "subscribe_conversation")
        XCTAssertEqual(record.phase, "apply")
        XCTAssertEqual(record.domain, "server_reason")
        XCTAssertEqual(record.code, "storage_unavailable")
        XCTAssertEqual(record.initiator, .serverClosed)
        XCTAssertTrue(record.retryable)
        XCTAssertEqual(record.correlation, ids)
        XCTAssertEqual(record.count, 1)
        XCTAssertNil(record.resolvedAt)
    }

    func testServerCloseReasonMapsToInitiator() {
        XCTAssertEqual(ErrorLogInitiator(serverCloseReason: "superseded_by_new_stream"), .supersededByNewStream)
        XCTAssertEqual(ErrorLogInitiator(serverCloseReason: "device_revoked"), .deviceRevoked)
        XCTAssertEqual(ErrorLogInitiator(serverCloseReason: "anything else the server writes"), .serverClosed)
    }

    // MARK: Persistence and fallback

    func testRecordsPersistAcrossLaunchesIncludingResolution() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let first = makeStore(clock: clock)
        first.report(report())
        first.report(report(.actions, operation: "mark_seen", reason: .serverReason("retry_later")))
        clock.advance(60)
        first.resolve(concern: .actions, operation: "mark_seen")
        XCTAssertEqual(first.persistenceStatus, .saved)

        let second = makeStore(clock: clock)
        XCTAssertEqual(second.records, first.records)
        XCTAssertEqual(second.persistenceStatus, .saved)
        XCTAssertEqual(second.records.filter(\.isResolved).count, 1)
    }

    func testFailedWriteFallsBackToMemoryAndRecoversWhenWritesWork() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        // A regular file where the log's folder should be makes every write fail.
        let blocker = directory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let store = makeStore(file: blocker.appendingPathComponent("error-log.json"), clock: clock)
        store.report(report())
        store.report(report(.actions, operation: "mark_seen"))

        XCTAssertEqual(store.records.count, 2, "records stay available in memory")
        XCTAssertEqual(store.persistenceStatus, .memoryFallback(cause: "write_failed"))

        try FileManager.default.removeItem(at: blocker)
        store.report(report(.sync, operation: "subscribe_conversation"))
        XCTAssertEqual(store.persistenceStatus, .saved)
        XCTAssertEqual(makeStore(file: blocker.appendingPathComponent("error-log.json"), clock: clock).records.count, 3)
    }

    func testUnreadableOrFutureVersionFileFallsBackToMemory() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        try Data("not json".utf8).write(to: fileURL)
        let corrupt = makeStore(clock: clock)
        XCTAssertEqual(corrupt.records, [])
        XCTAssertEqual(corrupt.persistenceStatus, .memoryFallback(cause: "read_failed"))
        corrupt.report(report())
        XCTAssertEqual(corrupt.records.count, 1)
        XCTAssertEqual(corrupt.persistenceStatus, .saved)

        try Data(#"{"version":99,"records":[]}"#.utf8).write(to: fileURL)
        XCTAssertEqual(makeStore(clock: clock).persistenceStatus, .memoryFallback(cause: "unsupported_version"))
    }

    // MARK: Retention

    func testMoreThanOneHundredRecordsAreKeptWhileTheyAreWithinFourteenDays() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        for index in 0..<150 {
            store.report(report(operation: "op_\(index)"))
            clock.advance(60)
        }
        XCTAssertEqual(store.records.count, 150)
    }

    func testOldRecordsBeyondOneHundredAreEvictedResolvedFirst() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        for index in 0..<60 {
            store.report(report(operation: "keep_\(index)"))
            clock.advance(1)
        }
        for index in 0..<60 {
            store.report(report(.actions, operation: "done_\(index)"))
            clock.advance(1)
        }
        for index in 0..<60 {
            store.resolve(concern: .actions, operation: "done_\(index)")
        }
        clock.advance(ErrorLogStore.retentionInterval + 3600)
        store.report(report(.sync, operation: "fresh"))

        let records = store.records
        XCTAssertEqual(records.count, ErrorLogStore.minimumRetainedCount)
        XCTAssertEqual(records.filter { $0.operation.hasPrefix("keep_") }.count, 60,
                       "unresolved records outlive resolved ones")
        XCTAssertEqual(records.filter { $0.operation.hasPrefix("done_") }.count, 39)
        XCTAssertTrue(records.contains { $0.operation == "fresh" })
    }

    func testRecentRecordsAreNeverEvictedEvenWhenResolved() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        for index in 0..<120 {
            store.report(report(operation: "op_\(index)"))
            store.resolve(concern: .snapshot, operation: "op_\(index)")
            clock.advance(10)
        }
        XCTAssertEqual(store.records.count, 120)
    }

    // MARK: In-context display

    func testInContextShowsNewestUnresolvedRecordOfItsOwnConcernOnly() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(report(.snapshot, operation: "read_inbox", reason: .urlError(-1001)))
        clock.advance(10)
        store.report(report(.snapshot, operation: "read_entries", reason: .urlError(-1009)))
        clock.advance(10)
        store.report(report(.sync, operation: "subscribe_conversation", reason: .posix(89)))

        let records = store.records
        guard case let .failing(snapshot)? = ErrorLogDisplay.inContext(
            records: records, concern: .snapshot, now: clock.now) else { return XCTFail("expected a failure") }
        XCTAssertEqual(snapshot.operation, "read_entries")
        guard case let .failing(sync)? = ErrorLogDisplay.inContext(
            records: records, concern: .sync, now: clock.now) else { return XCTFail("expected a failure") }
        XCTAssertEqual(sync.code, "89")
        XCTAssertNil(ErrorLogDisplay.inContext(records: records, concern: .actions, now: clock.now))
    }

    func testResolvedFailureStaysVisibleFor24HoursThenLeavesOnlyTheDiagnosticsList() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(report())
        clock.advance(100)
        store.resolve(concern: .snapshot, operation: "read_inbox")

        clock.advance(24 * 3600 - 1)
        guard case let .resolved(record)? = ErrorLogDisplay.inContext(
            records: store.records, concern: .snapshot, now: clock.now) else { return XCTFail("expected resolved") }
        XCTAssertTrue(record.isResolved)

        clock.advance(2)
        XCTAssertNil(ErrorLogDisplay.inContext(records: store.records, concern: .snapshot, now: clock.now))
        XCTAssertEqual(store.records.count, 1, "the record is still in the log")
    }

    func testActionsSurfaceCanBeNarrowedToOneOperation() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        let first = UUID()
        let second = UUID()
        store.report(report(.actions, operation: "send_reply", reason: .serverReason("rejected"),
                            correlation: ErrorLogCorrelation(clientOperationID: first)))
        clock.advance(5)
        store.report(report(.actions, operation: "send_reply", reason: .serverReason("unavailable"),
                            correlation: ErrorLogCorrelation(clientOperationID: second)))
        let shown = ErrorLogDisplay.inContext(records: store.records, concern: .actions,
                                              clientOperationID: first, now: clock.now)
        XCTAssertEqual(shown?.record.correlation.clientOperationID, first)
    }

    func testSurfacesSelectTheirOwnRecords() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        let operationID = UUID()
        store.report(report(.snapshot, operation: "read_inbox"))
        store.report(report(.snapshot, operation: ErrorLogOperation.readEntries, reason: .urlError(-1009)))
        store.report(report(.sync, operation: "subscribe_conversation"))
        store.report(report(.actions, operation: "send_reply",
                            correlation: ErrorLogCorrelation(clientOperationID: operationID)))
        let records = store.records

        XCTAssertEqual(ErrorLogDisplay.inContext(records: records, surface: .inbox, now: clock.now)?.record.operation,
                       "read_inbox")
        XCTAssertEqual(ErrorLogDisplay.inContext(records: records, surface: .thread, now: clock.now)?.record.operation,
                       ErrorLogOperation.readEntries)
        XCTAssertEqual(ErrorLogDisplay.inContext(records: records, surface: .liveIndicator, now: clock.now)?.record.concern,
                       .sync)
        XCTAssertEqual(ErrorLogDisplay.inContext(records: records, surface: .item(clientOperationID: operationID),
                                                 now: clock.now)?.record.operation, "send_reply")
        XCTAssertNil(ErrorLogDisplay.inContext(records: records, surface: .item(clientOperationID: UUID()),
                                               now: clock.now))
    }

    // MARK: Copy format

    func testCopiedDetailsArePlainKeyValueLines() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        let attempt = UUID()
        store.report(report(.sync, operation: "subscribe_conversation", phase: "apply",
                            reason: .posix(89), initiator: .supersededByNewStream,
                            correlation: ErrorLogCorrelation(attemptID: attempt, serverConnectionID: "conn-1")))
        let text = ErrorLogDetails.text(for: store.records[0])
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.allSatisfy { $0.contains(": ") }, "every line is key: value")
        XCTAssertTrue(lines.contains("app_build: 293"))
        XCTAssertTrue(lines.contains("app_commit: eba4697"))
        XCTAssertTrue(lines.contains("concern: sync"))
        XCTAssertTrue(lines.contains("connection_role: stream"))
        XCTAssertTrue(lines.contains("operation: subscribe_conversation"))
        XCTAssertTrue(lines.contains("phase: apply"))
        XCTAssertTrue(lines.contains("domain: POSIX"))
        XCTAssertTrue(lines.contains("code: 89"))
        XCTAssertTrue(lines.contains("initiator: superseded_by_new_stream"))
        XCTAssertTrue(lines.contains("attempt_id: \(attempt.uuidString.lowercased())"))
        XCTAssertTrue(lines.contains("server_connection_id: conn-1"))
        XCTAssertTrue(lines.contains("resolved: no"))
    }
}
