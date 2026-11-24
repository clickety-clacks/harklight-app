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

    /// A long write delay keeps writes out of the test until `flush()`.
    private func makeStore(file: URL? = nil, clock: Clock) -> ErrorLogStore {
        let store = ErrorLogStore(fileURL: file ?? fileURL, build: build, writeDelay: 3600, now: { clock.now })
        addTeardownBlock { store.flush() }
        return store
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
        store.flush()
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

        store.flush()
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
        XCTAssertNil(ErrorLogCorrelation(serverConnectionID: String(repeating: "a", count: 129)).serverConnectionID)
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
        first.flush()
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
        store.flush()

        XCTAssertEqual(store.records.count, 2, "records stay available in memory")
        guard case .memoryFallback = store.persistenceStatus else {
            return XCTFail("expected the memory fallback, got \(store.persistenceStatus)")
        }

        try FileManager.default.removeItem(at: blocker)
        store.report(report(.sync, operation: "subscribe_conversation"))
        store.flush()
        XCTAssertEqual(store.persistenceStatus, .saved)
        XCTAssertEqual(makeStore(file: blocker.appendingPathComponent("error-log.json"), clock: clock).records.count, 3)
    }

    func testCorruptFileIsMovedAsideNotOverwritten() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore(clock: clock)
        XCTAssertEqual(store.records, [])
        XCTAssertEqual(store.persistenceStatus, .memoryFallback(cause: "unreadable_format"))
        store.report(report())
        store.flush()
        XCTAssertEqual(store.persistenceStatus, .saved)

        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("unreadable") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(aside[0]), encoding: .utf8), "not json")
        XCTAssertEqual(makeStore(clock: clock).records.count, 1)
    }

    func testOnlyTheNewestFewMovedAsideFilesAreKept() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        for round in 0..<6 {
            try Data("bad \(round)".utf8).write(to: fileURL)
            let store = makeStore(clock: clock)
            store.report(report(operation: "op_\(round)"))
            store.flush()
            try FileManager.default.removeItem(at: fileURL)
            clock.advance(10)
        }
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("unreadable") }.sorted()
        XCTAssertEqual(aside.count, ErrorLogStore.movedAsideFilesKept)
        let contents = try aside.map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
        XCTAssertEqual(Set(contents), ["bad 3", "bad 4", "bad 5"], "the newest files are the ones kept")
    }

    func testFutureVersionFileIsMovedAsideNotOverwritten() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let future = #"{"version":99,"records":[]}"#
        try Data(future.utf8).write(to: fileURL)
        let store = makeStore(clock: clock)
        XCTAssertEqual(store.persistenceStatus, .memoryFallback(cause: "unsupported_version"))
        store.report(report())
        store.flush()
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("unreadable") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(aside[0]), encoding: .utf8), future)
    }

    func testTemporarilyUnreadableFileIsNeverOverwrittenAndIsMergedWhenReadable() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let first = makeStore(clock: clock)
        first.report(report(operation: "old_failure"))
        first.flush()
        let original = try Data(contentsOf: fileURL)

        // Unreadable for now, like a launch before first unlock.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }
        let second = makeStore(clock: clock)
        XCTAssertEqual(second.records, [])
        XCTAssertEqual(second.persistenceStatus, .memoryFallback(cause: "read_failed"))
        second.report(report(operation: "new_failure"))
        second.flush()
        XCTAssertEqual(second.records.count, 1, "new failures are kept in memory")
        XCTAssertEqual(second.persistenceStatus, .memoryFallback(cause: "read_failed"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        XCTAssertEqual(try Data(contentsOf: fileURL), original, "the unreadable file was not overwritten")

        second.report(report(operation: "later_failure"))
        second.flush()
        XCTAssertEqual(second.persistenceStatus, .saved)
        let operations = Set(makeStore(clock: clock).records.map(\.operation))
        XCTAssertEqual(operations, ["old_failure", "new_failure", "later_failure"])
    }

    // MARK: Writes happen off the caller

    func testReportDoesNotWriteOnTheCallersThreadAndFlushDoes() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        // Occupy the first immediate write so the next change is held back.
        let store = makeStore(clock: clock)
        store.report(report(operation: "first"))
        store.flush()
        try FileManager.default.removeItem(at: fileURL)
        store.report(report(operation: "second"))
        store.report(report(operation: "third"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "changes within the write delay are batched, not written by the caller")
        store.flush()
        XCTAssertEqual(makeStore(clock: clock).records.count, 3)
    }

    func testFlappingFailureIsBoundedAndKeepsUnresolvedRecords() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(report(.sync, operation: "keep_failing"))
        for _ in 0..<(ErrorLogStore.maximumRetainedCount + 100) {
            store.report(report())
            clock.advance(1)
            store.resolve(concern: .snapshot, operation: "read_inbox")
            clock.advance(1)
        }
        XCTAssertLessThanOrEqual(store.records.count, ErrorLogStore.maximumRetainedCount)
        XCTAssertTrue(store.records.contains { $0.operation == "keep_failing" && !$0.isResolved })
    }

    func testCoalescingKeyIncludesTheClientOperationAndDomain() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        let first = UUID()
        let second = UUID()
        store.report(report(.actions, operation: "send_reply", reason: .serverReason("rejected"),
                            correlation: ErrorLogCorrelation(clientOperationID: first)))
        store.report(report(.actions, operation: "send_reply", reason: .serverReason("rejected"),
                            correlation: ErrorLogCorrelation(clientOperationID: second)))
        XCTAssertEqual(store.records.count, 2, "two different replies fail separately")
        store.report(report(.actions, operation: "send_reply", reason: .serverReason("rejected"),
                            correlation: ErrorLogCorrelation(clientOperationID: first)))
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.records.first { $0.correlation.clientOperationID == first }?.count, 2)
        store.report(report(.actions, operation: "send_reply", reason: .app("rejected"),
                            correlation: ErrorLogCorrelation(clientOperationID: first)))
        XCTAssertEqual(store.records.count, 3, "same code in another domain is another failure")
    }

    func testBuildFieldsAreRedactedWhenDecoded() throws {
        let json = #"{"version":"Bearer abc def","build":"293","commit":"https://x.invalid/?t=1"}"#
        let decoded = try JSONDecoder().decode(ErrorLogBuild.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, "unavailable")
        XCTAssertEqual(decoded.build, "293")
        XCTAssertEqual(decoded.commit, "unavailable")
        XCTAssertEqual(ErrorLogBuild.unavailable.commit, "unavailable")
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

    private func showsLiveFailure(_ store: ErrorLogStore, at now: Date) -> Bool {
        if case .failing? = ErrorLogDisplay.inContext(records: store.records, surface: .liveIndicator, now: now) {
            return true
        }
        return false
    }

    func testMinuteIdleDropAndReopenNeverShowsLiveFailureAndKeepsDiagnostics() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        for cycle in 0..<3 {
            XCTAssertFalse(showsLiveFailure(store, at: clock.now))
            clock.advance(60)
            store.report(report(.sync, operation: "change_feed", phase: "stream",
                reason: .app("ended_without_closing"), initiator: .unknown,
                correlation: .request("opened-\(cycle)")))
            let held = store.records
            XCTAssertEqual(held.filter { !$0.isResolved }.first?.count, 1)
            XCTAssertFalse(showsLiveFailure(store, at: clock.now), "The first drop stays quiet in the shared live surface.")
            XCTAssertNil(ErrorLogDisplay.inContext(records: held, surface: .inbox, now: clock.now))
            XCTAssertNil(ErrorLogDisplay.inContext(records: held, surface: .thread, now: clock.now))
            XCTAssertEqual(ErrorLogDisplay.inContext(records: held, concern: .sync, now: clock.now)?.record.operation,
                           "change_feed", "Settings and diagnostics still see the failure.")
            XCTAssertEqual(store.records, held, "Choosing a caption never edits the Error Log.")
            clock.advance(2)
            store.resolve(concern: .sync, operation: "change_feed") // The reopened feed reports success.
            XCTAssertFalse(showsLiveFailure(store, at: clock.now))
        }
        XCTAssertEqual(store.records.count, 3, "Each resolved/drop cycle starts a new count-one record.")
        XCTAssertTrue(store.records.allSatisfy(\.isResolved))
    }

    func testFailedReconnectShowsForBatchOrOpenWithMergedOrDifferentError() {
        for (phase, code) in [("batch", -1005), ("stream", -1005), ("stream", -1004)] {
            let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
            let store = makeStore(clock: clock)
            store.report(report(.sync, operation: "change_feed", phase: "stream", reason: .urlError(-1005),
                                correlation: .request("opened-feed")))
            XCTAssertFalse(showsLiveFailure(store, at: clock.now))
            clock.advance(1)
            // A failed stream open also uses phase stream, but has no opened-feed Request-Id.
            store.report(report(.sync, operation: "change_feed", phase: phase, reason: .urlError(code)))
            XCTAssertTrue(showsLiveFailure(store, at: clock.now), "Reconnect \(phase)/\(code) fails immediately visibly.")
            if code == -1005 {
                XCTAssertEqual(store.records.count, 1)
                XCTAssertEqual(store.records[0].count, 2)
                XCTAssertEqual(store.records[0].phase, phase, "Coalescing replaces the phase with the latest failure.")
            } else {
                XCTAssertEqual(store.records.filter { !$0.isResolved }.count, 2,
                               "A new error code must not look like a fresh first drop.")
            }
        }
    }

    func testOutageRemainsVisibleAcrossRetriesAndReopenClearsWithoutErasure() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(report(.sync, operation: "change_feed", phase: "stream",
                            reason: .app("idle_timeout"), correlation: .request("opened-feed")))
        XCTAssertFalse(showsLiveFailure(store, at: clock.now))
        for (phase, code) in [("batch", -1009), ("stream", -1004), ("stream", -1004), ("batch", -1009)] {
            clock.advance(2)
            store.report(report(.sync, operation: "change_feed", phase: phase, reason: .urlError(code)))
            XCTAssertTrue(showsLiveFailure(store, at: clock.now))
        }
        let count = store.records.count
        store.resolve(concern: .sync, operation: "change_feed")
        XCTAssertFalse(showsLiveFailure(store, at: clock.now))
        XCTAssertEqual(store.records.count, count)
        clock.advance(60)
        store.report(report(.sync, operation: "change_feed", phase: "stream",
                            reason: .app("idle_timeout"), correlation: .request("reopened-feed")))
        XCTAssertFalse(showsLiveFailure(store, at: clock.now), "A later healthy-open/drop cycle is again only a first drop.")
    }

    func testAttentionAndOtherSyncFailuresAreNeverHiddenAsAFirstDrop() {
        let cases: [(String, String, ErrorLogReason, ErrorLogCorrelation)] = [
            ("change_feed", "stream", .serverReason("internal_error"), .request("opened")),
            ("change_feed", "open", .serverReason("account_paused"), .none),
            ("change_feed", "open", .serverReason("revoked"), .none),
            ("change_feed", "closing", .serverReason("server_shutdown"), .request("opened")),
            ("change_feed", "closing", .serverReason("storage_unavailable"), .request("opened")),
            ("change_feed", "closing", .serverReason("cursor_expired"), .request("opened")),
            ("change_feed", "stream", .app("decode_failed"), .request("opened")),
            ("change_feed", "apply", .app("decode_failed"), .request("opened")),
            ("change_feed", "stream", .urlError(-1004), .none),
            ("subscribe_conversation", "stream", .urlError(-1005), .request("opened")),
            ("catch_up", "batch", .urlError(-1009), .none)
        ]
        for (operation, phase, reason, correlation) in cases {
            let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
            let store = makeStore(clock: clock)
            store.report(report(.sync, operation: operation, phase: phase, reason: reason, correlation: correlation))
            XCTAssertTrue(showsLiveFailure(store, at: clock.now), "\(operation)/\(phase)/\(reason.code) needs attention.")
        }
    }


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

    // MARK: Client API response fields

    func testApiErrorFieldsAreRecordedAndCopied() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(ErrorLogReport(
            concern: .actions, connectionRole: .request, operation: "send_reply", phase: "response",
            reason: .serverReason("idempotency_conflict"), initiator: .unknown, retryable: false,
            correlation: ErrorLogCorrelation(clientOperationID: UUID(), requestID: "req-01HZX9K2"),
            httpStatus: 409))
        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.code, "idempotency_conflict")
        XCTAssertEqual(record.httpStatus, 409)
        XCTAssertEqual(record.correlation.requestID, "req-01HZX9K2")
        let lines = ErrorLogDetails.text(for: record).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("http_status: 409"))
        XCTAssertTrue(lines.contains("request_id: req-01HZX9K2"))
        store.flush()
        XCTAssertEqual(ErrorLogStore(fileURL: fileURL, build: build).records, store.records)
    }

    func testEveryDocumentedApiErrorTokenIsKeptAndOthersAreNot() {
        for token in ["not_found", "invalid_field", "stale_request", "already_answered", "already_retracted",
                      "already_closed", "idempotency_conflict", "precondition_failed", "cursor_expired", "unauthorized",
                      "retry_later", "storage_unavailable", "payload_too_large", "unsupported", "forbidden", "account_paused"] {
            XCTAssertEqual(ErrorLogReason.serverReason(token).code, token)
        }
        XCTAssertEqual(ErrorLogReason.serverReason("please_contact_dana@example.invalid").code, "other")
    }

    func testRequestIDUpToTheContractMaximumIsKept() {
        let longest = String(repeating: "a", count: 100) + "-_.:~=+/" + String(repeating: "Z9", count: 10)
        XCTAssertEqual(longest.count, 128)
        XCTAssertEqual(ErrorLogCorrelation(requestID: longest).requestID, longest)
        XCTAssertNil(ErrorLogCorrelation(requestID: longest + "a").requestID)
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(ErrorLogReport(concern: .snapshot, connectionRole: .request, operation: "read_inbox",
                                    phase: "response", reason: .urlError(-1001), retryable: true,
                                    correlation: ErrorLogCorrelation(requestID: longest)))
        store.flush()
        XCTAssertEqual(ErrorLogStore(fileURL: fileURL, build: build).records[0].correlation.requestID, longest)
        XCTAssertTrue(ErrorLogDetails.text(for: store.records).contains("request_id: \(longest)"))
    }

    /// A skipped v2 change is recorded with the item and change-log position
    /// it is about; failures about different items stay separate records.
    func testResourceAndRevAreRecordedCopiedAndKeepRecordsApart() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        func skipped(_ item: String, rev: UInt64) -> ErrorLogReport {
            ErrorLogReport(concern: .sync, connectionRole: .stream, operation: "apply_change", phase: "entry",
                           reason: .app("decode_failed"), retryable: false,
                           correlation: ErrorLogCorrelation(resourceID: item, rev: rev))
        }
        store.report(skipped("itm_01HZX9", rev: 41))
        store.report(skipped("itm_01HZX9", rev: 44))
        store.report(skipped("itm_02ABCD", rev: 45))
        XCTAssertEqual(store.records.count, 2, "One record per item; repeats for the same item coalesce.")
        let first = try XCTUnwrap(store.records.first { $0.correlation.resourceID == "itm_01HZX9" })
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.correlation.rev, 44, "The newest occurrence's position is kept.")
        let lines = ErrorLogDetails.text(for: first).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("resource_id: itm_01HZX9"))
        XCTAssertTrue(lines.contains("rev: 44"))
        store.flush()
        XCTAssertEqual(ErrorLogStore(fileURL: fileURL, build: build).records, store.records)
        XCTAssertNil(ErrorLogCorrelation(resourceID: "has space").resourceID, "Unsafe ids are dropped.")
    }

    func testUnsafeRequestIDAndImpossibleStatusAreDropped() {
        XCTAssertNil(ErrorLogCorrelation(requestID: "a@b.invalid").requestID)
        XCTAssertNil(ErrorLogCorrelation(requestID: "id#frag").requestID)
        XCTAssertNil(ErrorLogCorrelation(requestID: "https://x.invalid/?t=1").requestID)
        XCTAssertNil(ErrorLogCorrelation(requestID: "Bearer abc").requestID)
        let report = ErrorLogReport(concern: .snapshot, connectionRole: .request, operation: "read_inbox",
                                    phase: "response", reason: .urlError(-1), retryable: true, httpStatus: 99_999)
        XCTAssertNil(report.httpStatus)
    }

    func testFeedClosingReasonsBecomeInitiatorsAndStayRecordedAsReasons() throws {
        XCTAssertEqual(ErrorLogInitiator(serverCloseReason: "revoked"), .deviceRevoked)
        XCTAssertEqual(ErrorLogInitiator(serverCloseReason: "server_shutdown"), .serverClosed)
        XCTAssertEqual(ErrorLogInitiator(serverCloseReason: "idle_timeout"), .serverClosed)
        XCTAssertEqual(ErrorLogInitiator(serverCloseReason: "account_paused"), .serverClosed)
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let store = makeStore(clock: clock)
        store.report(ErrorLogReport(concern: .sync, connectionRole: .stream, operation: "change_feed",
                                    phase: "closing", reason: .serverReason("idle_timeout"),
                                    initiator: ErrorLogInitiator(serverCloseReason: "idle_timeout"),
                                    retryable: true))
        XCTAssertEqual(store.records[0].code, "idle_timeout")
        XCTAssertEqual(store.records[0].initiator, .serverClosed)
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
