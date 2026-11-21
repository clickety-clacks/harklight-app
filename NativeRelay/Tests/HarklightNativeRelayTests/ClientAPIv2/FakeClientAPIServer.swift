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
    private(set) var received: [APIRequest] = []
    var persistedKeys: (() -> Set<UUID>)?
    private(set) var keysPersistedAtSend: [Bool] = []

    /// Fails every feed open with this error (for example a cancelled or
    /// aborted connection).
    var feedFailure: (any Error)?
    /// Queued answers for writes, consumed in order; nil means accept.
    var nextWriteFailures: [(any Error)?] = []
    /// Suspends a write to `path` until released.
    var holdWrites: [String: AsyncGate] = [:]

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
            received.append(request)
            if request.method != .get { keysPersistedAtSend.append(persisted) }
        }
        if request.method == .get {
            return APIResponse(status: 200, requestID: nextRequestID(), body: Data(#"{"rev":\#(head)}"#.utf8))
        }
        if let gate = lock.withLock({ holdWrites[request.path] }) { await gate.wait() }
        let digest = (request.path + request.method.rawValue).data(using: .utf8)! + (request.body ?? Data())
        if let key = request.idempotencyKey, let prior = lock.withLock({ stored[key] }) {
            guard prior.digest == digest else {
                throw APIError(status: 409, token: .idempotencyConflict, retryable: false, requestID: nextRequestID())
            }
            return APIResponse(status: prior.response.status, requestID: nextRequestID(),
                               body: prior.response.body, replayed: true)
        }
        let failure = lock.withLock { nextWriteFailures.isEmpty ? nil : nextWriteFailures.removeFirst() }
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
        let rev = commit("item", #"{"path":"\#(request.path)"}"#)
        let response = APIResponse(status: 200, requestID: nextRequestID(), body: Data(#"{"rev":\#(rev)}"#.utf8))
        if let key = request.idempotencyKey { lock.withLock { stored[key] = (digest, response) } }
        return response
    }

    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { continuation in
            if let feedFailure = lock.withLock({ self.feedFailure }) {
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

    func changeBatch(after: Rev) async throws -> FeedBatch {
        try lock.withLock {
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
final class RecordingSyncModel: SyncModelWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var gate = RevGate()
    private(set) var applied: [Rev] = []
    private(set) var rebaselines = 0
    var snapshotRev: () -> Rev
    var failApplyAt: Rev?
    var onApply: ((FeedChange) -> Void)?

    init(snapshotRev: @escaping () -> Rev) { self.snapshotRev = snapshotRev }

    func apply(_ change: FeedChange) async throws {
        try lock.withLock {
            if failApplyAt == change.rev {
                failApplyAt = nil
                throw CocoaError(.fileWriteUnknown)
            }
            if gate.admit("log", rev: change.rev) { applied.append(change.rev) }
        }
        onApply?(change)
    }

    func rebaseline() async throws -> Rev {
        lock.withLock {
            rebaselines += 1
            let rev = snapshotRev()
            _ = gate.admit("log", rev: rev)
            return rev
        }
    }
}

final class MemoryRevCursor: RevCursorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Rev?
    private(set) var saves: [Rev] = []
    init(_ value: Rev? = nil) { self.value = value }
    func load() throws -> Rev? { lock.withLock { value } }
    func save(_ rev: Rev) throws { lock.withLock { value = rev; saves.append(rev) } }
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
    private(set) var accepted: [(UUID, APIResponse)] = []
    private(set) var rejected: [(UUID, APIError)] = []
    func accepted(_ entry: OutboxEntry, response: APIResponse) async {
        lock.withLock { accepted.append((entry.idempotencyKey, response)) }
    }
    func rejected(_ entry: OutboxEntry, error: APIError) async {
        lock.withLock { rejected.append((entry.idempotencyKey, error)) }
    }
}

final class RecordingErrorLogV2: ErrorLogging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reports: [ErrorLogReport] = []
    private(set) var resolutions: [String] = []
    func report(_ report: ErrorLogReport) { lock.withLock { reports.append(report) } }
    func resolve(concern: ErrorLogConcern, operation: String, resolvedBy: String?) {
        lock.withLock { resolutions.append("\(concern.rawValue).\(operation)") }
    }
}
