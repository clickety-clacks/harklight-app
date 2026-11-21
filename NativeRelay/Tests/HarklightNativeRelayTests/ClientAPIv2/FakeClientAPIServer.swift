import AttentionDomain
import Foundation
@testable import HarklightNativeRelay

/// An in-memory stand-in for the r2 client API: one person's change log,
/// idempotent writes and a feed that can be made to fail. It models the
/// contract, not the Server's implementation.
final class FakeClientAPIServer: ClientAPITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [FeedChange] = []
    private var retainedFrom: Rev = 0
    private var stored: [UUID: (digest: Data, response: APIResponse)] = [:]
    private var feeds: [UUID: (after: Rev, continuation: AsyncThrowingStream<FeedEvent, any Error>.Continuation)] = [:]
    private var requestCounter = 0

    /// Requests in arrival order, with whether the outbox had persisted each
    /// key before it was sent (filled by `persistedKeys`).
    private var _received: [APIRequest] = []
    var received: [APIRequest] { lock.withLock { _received } }
    var persistedKeys: (() -> Set<UUID>)?
    private var _keysPersistedAtSend: [Bool] = []
    var keysPersistedAtSend: [Bool] { lock.withLock { _keysPersistedAtSend } }

    /// Fails every feed open with this error (for example a cancelled or
    /// aborted connection).
    private var _feedFailure: (any Error)?
    var feedFailure: (any Error)? {
        get { lock.withLock { _feedFailure } }
        set { lock.withLock { _feedFailure = newValue } }
    }
    /// Queued answers for writes, consumed in order; nil means accept.
    private var _nextWriteFailures: [(any Error)?] = []
    var nextWriteFailures: [(any Error)?] {
        get { lock.withLock { _nextWriteFailures } }
        set { lock.withLock { _nextWriteFailures = newValue } }
    }
    /// Item JSON served by GET /v2/inbox.
    private var _inboxItems: [String] = []
    var inboxItems: [String] {
        get { lock.withLock { _inboxItems } }
        set { lock.withLock { _inboxItems = newValue } }
    }
    /// Suspends a write to `path` until released.
    private var _holdWrites: [String: AsyncGate] = [:]
    var holdWrites: [String: AsyncGate] {
        get { lock.withLock { _holdWrites } }
        set { lock.withLock { _holdWrites = newValue } }
    }

    var holdInbox: AsyncGate?
    var meBody: String?
    var replyEntry: (@Sendable (Rev) -> String)?

    var head: Rev { lock.withLock { log.last?.rev ?? retainedFrom } }
    var openFeedCount: Int { lock.withLock { feeds.count } }

    /// Appends a change and delivers it to every open feed.
    @discardableResult
    func commit(_ kind: String, _ json: String) -> Rev {
        let (change, open) = lock.withLock { () -> (FeedChange, [AsyncThrowingStream<FeedEvent, any Error>.Continuation]) in
            let change = FeedChange(rev: (log.last?.rev ?? retainedFrom) + 1, kind: FeedChange.Kind(kind),
                                    data: Data(json.utf8))
            log.append(change)
            return (change, feeds.values.map(\.continuation))
        }
        open.forEach { $0.yield(.change(change)) }
        return change.rev
    }

    /// Drops log entries at or below `rev`, as retention does.
    func prune(through rev: Rev) {
        lock.withLock {
            log.removeAll { $0.rev <= rev }
            retainedFrom = max(retainedFrom, rev)
        }
    }

    func heartbeat() {
        lock.withLock { feeds.values.map(\.continuation) }.forEach { $0.yield(.heartbeat) }
    }

    /// Writes an ephemeral `event: show` to every open feed; never logged.
    func show(_ json: String) {
        lock.withLock { feeds.values.map(\.continuation) }.forEach { $0.yield(.show(Data(json.utf8))) }
    }

    func closeFeeds(reason: String) {
        let open = lock.withLock { () -> [AsyncThrowingStream<FeedEvent, any Error>.Continuation] in
            defer { feeds.removeAll() }
            return feeds.values.map(\.continuation)
        }
        for continuation in open {
            continuation.yield(.closing(reason: reason))
            continuation.finish()
        }
    }

    func failFeeds(_ error: any Error) {
        let open = lock.withLock { () -> [AsyncThrowingStream<FeedEvent, any Error>.Continuation] in
            defer { feeds.removeAll() }
            return feeds.values.map(\.continuation)
        }
        open.forEach { $0.finish(throwing: error) }
    }

    private func nextRequestID() -> String {
        lock.withLock { requestCounter += 1; return "req-\(requestCounter)" }
    }

    // MARK: ClientAPITransport

    func send(_ request: APIRequest) async throws -> APIResponse {
        // Like URLSession, a cancelled task's request fails.
        try Task.checkCancellation()
        let persisted = request.idempotencyKey.map { persistedKeys?().contains($0) ?? true } ?? true
        lock.withLock {
            _received.append(request)
            if request.method != .get { _keysPersistedAtSend.append(persisted) }
        }
        if request.method == .get {
            if request.path == "/v2/me", let meBody {
                return APIResponse(status: 200, requestID: nextRequestID(), body: Data(meBody.utf8))
            }
            if request.path == "/v2/inbox", let holdInbox { await holdInbox.wait() }
            // The inbox as a snapshot: the items the fake serves, at its head.
            let items = lock.withLock { _inboxItems.joined(separator: ",") }
            return APIResponse(status: 200, requestID: nextRequestID(),
                               body: Data(#"{"rev":\#(head),"items":[\#(items)],"counts":{"unresolved":0}}"#.utf8))
        }
        if let gate = lock.withLock({ _holdWrites[request.path] }) { await gate.wait() }
        let digest = (request.path + request.method.rawValue).data(using: .utf8)! + (request.body ?? Data())
        if let key = request.idempotencyKey, let prior = lock.withLock({ stored[key] }) {
            guard prior.digest == digest else {
                throw APIError(status: 409, token: .idempotencyConflict, retryable: false, requestID: nextRequestID())
            }
            return APIResponse(status: prior.response.status, requestID: nextRequestID(),
                               body: prior.response.body, replayed: true)
        }
        let failure = lock.withLock { _nextWriteFailures.isEmpty ? nil : _nextWriteFailures.removeFirst() }
        if let failure {
            // An unknown outcome may still have committed on the server.
            if let committed = failure as? CommittedThenLost {
                _ = applyWrite(request, digest: digest)
                throw committed.error
            }
            throw failure
        }
        return applyWrite(request, digest: digest)
    }

    private func applyWrite(_ request: APIRequest, digest: Data) -> APIResponse {
        let body: String
        if request.path.hasSuffix("/replies"), let replyEntry {
            let entry = replyEntry(head + 1)
            let rev = commit("entry", entry)
            body = #"{"rev":\#(rev),"entry":\#(entry)}"#
        } else {
            let rev = commit("item", #"{"path":"\#(request.path)"}"#)
            body = #"{"rev":\#(rev)}"#
        }
        let response = APIResponse(status: 200, requestID: nextRequestID(), body: Data(body.utf8))
        if let key = request.idempotencyKey { lock.withLock { stored[key] = (digest, response) } }
        return response
    }

    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { continuation in
            if let feedFailure = lock.withLock({ self._feedFailure }) {
                continuation.finish(throwing: feedFailure)
                return
            }
            let id = UUID()
            let backlog = lock.withLock { () -> [FeedChange]? in
                guard after >= retainedFrom else { return nil }
                feeds[id] = (after, continuation)
                return log.filter { $0.rev > after }
            }
            guard let backlog else {
                continuation.finish(throwing: APIError(status: 410, token: .cursorExpired, retryable: false,
                                                       requestID: nextRequestID()))
                return
            }
            continuation.yield(.opened(requestID: nextRequestID()))
            backlog.forEach { continuation.yield(.change($0)) }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.feeds.removeValue(forKey: id) }
            }
        }
    }

    private var _batchPositions: [Rev] = []
    var batchPositions: [Rev] { lock.withLock { _batchPositions } }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        try lock.withLock {
            _batchPositions.append(after)
            guard after >= retainedFrom else {
                throw APIError(status: 410, token: .cursorExpired, retryable: false, requestID: "req-batch")
            }
            let pending = log.filter { $0.rev > after }
            let page = Array(pending.prefix(2))
            return FeedBatch(changes: page, rev: page.last?.rev ?? after, more: pending.count > page.count)
        }
    }

}

/// The server applied the write but the client never saw the answer.
struct CommittedThenLost: Error { let error: any Error }

final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if open { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock(); open = true; let pending = waiters; waiters.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// A local model that records what Sync applied, through the version gate.
/// A local model that records what Sync applied, through the version gate,
/// and holds Sync's cursor with it.
final class RecordingSyncModel: SyncModelWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var gate = RevGate()
    private var _applied: [Rev] = []
    var applied: [Rev] { lock.withLock { _applied } }
    private var _rebaselines: Int = 0
    var rebaselines: Int { lock.withLock { _rebaselines } }
    private var _batches: [[Rev]] = []
    var batches: [[Rev]] { lock.withLock { _batches } }
    var cursor = MemoryRevCursor()
    var snapshotRev: () -> Rev
    private var _failApplyAt: Rev?
    var failApplyAt: Rev? {
        get { lock.withLock { _failApplyAt } }
        set { lock.withLock { _failApplyAt = newValue } }
    }
    var onApply: ((FeedChange) -> Void)?

    init(snapshotRev: @escaping () -> Rev) { self.snapshotRev = snapshotRev }

    /// Starts from a held cursor (nil means first run).
    func using(_ cursor: MemoryRevCursor) -> Self {
        self.cursor = cursor
        return self
    }

    func syncPosition() throws -> (revision: Rev?, generation: UInt64) { (try heldCursor(), 0) }
    func heldCursor() throws -> Rev? { try cursor.load() }

    func apply(_ changes: [FeedChange], cursor rev: Rev, generation: UInt64) async throws {
        for change in changes { onApply?(change) }
        let admitted = try lock.withLock { () -> [Rev] in
            if let failApplyAt = _failApplyAt, changes.contains(where: { $0.rev == failApplyAt }) {
                self._failApplyAt = nil
                throw CocoaError(.fileWriteUnknown)
            }
            return changes.filter { gate.admit("log", rev: $0.rev) }.map(\.rev)
        }
        // Like the real store, the changes and the cursor become visible
        // together: a test that sees a change applied also sees its cursor.
        try cursor.save(max((try cursor.load()) ?? 0, rev))
        lock.withLock {
            _batches.append(changes.map(\.rev))
            _applied += admitted
        }
    }

    func rebaseline() async throws -> Rev {
        let rev = lock.withLock { () -> Rev in
            _rebaselines += 1
            let rev = snapshotRev()
            _ = gate.admit("log", rev: rev)
            return rev
        }
        try cursor.save(rev)
        return rev
    }
}

/// Sync's cursor as the test model holds it.
final class MemoryRevCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Rev?
    private var _saves: [Rev] = []
    var saves: [Rev] { lock.withLock { _saves } }
    init(_ value: Rev? = nil) { self.value = value }
    func load() throws -> Rev? { lock.withLock { value } }
    func save(_ rev: Rev) throws { lock.withLock { value = rev; _saves.append(rev) } }
}

final class MemoryOutboxPersistence: OutboxPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [OutboxEntry] = []
    var failNextSave = false
    func load() throws -> [OutboxEntry] { lock.withLock { entries } }
    func save(_ next: [OutboxEntry]) throws {
        try lock.withLock {
            if failNextSave { failNextSave = false; throw CocoaError(.fileWriteOutOfSpace) }
            entries = next
        }
    }
    var keys: Set<UUID> { lock.withLock { Set(entries.map(\.idempotencyKey)) } }
}

final class RecordingOutcomes: OutboxOutcomeHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _accepted: [(UUID, APIResponse)] = []
    var accepted: [(UUID, APIResponse)] { lock.withLock { _accepted } }
    private var _rejected: [(UUID, APIError)] = []
    var rejected: [(UUID, APIError)] { lock.withLock { _rejected } }
    let modelGeneration: UInt64 = 0

    func accepted(_ entry: OutboxEntry, response: APIResponse, generation: UInt64) async {
        lock.withLock { _accepted.append((entry.idempotencyKey, response)) }
    }
    func rejected(_ entry: OutboxEntry, error: APIError) async {
        lock.withLock { _rejected.append((entry.idempotencyKey, error)) }
    }
}

final class RecordingErrorLogV2: ErrorLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var _reports: [ErrorLogReport] = []
    var reports: [ErrorLogReport] { lock.withLock { _reports } }
    private var _resolutions: [String] = []
    var resolutions: [String] { lock.withLock { _resolutions } }
    func report(_ report: ErrorLogReport) { lock.withLock { _reports.append(report) } }
    func resolve(concern: ErrorLogConcern, operation: String, resolvedBy: String?) {
        lock.withLock { _resolutions.append("\(concern.rawValue).\(operation)") }
    }
}
