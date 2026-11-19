import Foundation

/// Durable home of Sync's one cursor: the last applied `rev`.
public protocol RevCursorStore: Sendable {
    func load() throws -> Rev?
    func save(_ rev: Rev) throws
}

/// Writes the local model for Sync. Both calls persist durably before they
/// return, and both go through the version gate (a change or snapshot older
/// than what is held is a no-op), so their order relative to reads and
/// writes never matters.
public protocol SyncModelWriting: Sendable {
    func apply(_ change: FeedChange) async throws
    /// Takes one inbox snapshot through the Snapshot Reader and returns the
    /// `rev` it reflects, the starting point for the feed.
    func rebaseline() async throws -> Rev
}

/// Sync (design section 3) over the r2 change feed. It owns the only feed
/// and the only cursor, and nothing else waits on it.
public actor ChangeFeedSync {
    public enum LiveState: Equatable, Sendable {
        case catchingUp
        case live
        case paused(ErrorLogInitiator)
        /// The device lost access; Sync stops until it is enrolled again.
        case stopped
    }

    static let feedOperation = "change_feed"
    static let catchUpOperation = "catch_up"

    private let transport: any ClientAPITransport
    private let cursor: any RevCursorStore
    private let model: any SyncModelWriting
    private let errors: any ErrorLogging
    private let waitBeforeRetry: @Sendable (_ attempt: Int) async throws -> Void
    private let onLiveState: @Sendable (LiveState) -> Void
    public private(set) var liveState: LiveState = .catchingUp {
        didSet { if liveState != oldValue { onLiveState(liveState) } }
    }

    public init(transport: any ClientAPITransport, cursor: any RevCursorStore, model: any SyncModelWriting,
                errors: any ErrorLogging,
                waitBeforeRetry: @escaping @Sendable (_ attempt: Int) async throws -> Void = ChangeFeedSync.backoff,
                onLiveState: @escaping @Sendable (LiveState) -> Void = { _ in }) {
        self.transport = transport
        self.cursor = cursor
        self.model = model
        self.errors = errors
        self.waitBeforeRetry = waitBeforeRetry
        self.onLiveState = onLiveState
    }

    /// 1, 2, 4 … 60 seconds between attempts.
    public static let backoff: @Sendable (Int) async throws -> Void = { attempt in
        let seconds = min(60, 1 << min(attempt, 6))
        try await Task.sleep(for: .seconds(seconds))
    }

    /// Holds the foreground feed open, resuming from the cursor after every
    /// drop, until the task is cancelled or the device loses access.
    public func runForeground() async {
        var attempt = 0
        while !Task.isCancelled {
            let end = await followFeedOnce()
            switch end {
            case .revoked:
                liveState = .stopped
                return
            case .cancelled:
                return
            case let .dropped(initiator, retryPromptly):
                liveState = .paused(initiator)
                if retryPromptly { attempt = 0 } else { attempt += 1 }
                do { try await waitBeforeRetry(attempt) } catch { return }
            }
        }
    }

    /// Push or background refresh: applies every batch from the cursor without
    /// holding a stream.
    public func catchUp() async throws {
        do {
            var after = try await startingRev()
            while true {
                let batch: FeedBatch
                do {
                    batch = try await transport.changeBatch(after: after)
                } catch let error as APIError where error.token == .cursorExpired {
                    after = try await rebaseline()
                    continue
                }
                for change in batch.changes where change.rev > after {
                    try await apply(change)
                    after = change.rev
                }
                // Every batch is gap-free and reflects the log through its
                // `rev`, so the cursor advances per batch.
                if batch.rev > after {
                    try advance(to: batch.rev)
                    after = batch.rev
                }
                guard batch.more else { break }
            }
            errors.resolve(concern: .sync, operation: Self.catchUpOperation)
        } catch {
            report(Self.catchUpOperation, phase: "batch", error: error, initiator: .forFailure(error))
            throw error
        }
    }

    // MARK: One feed connection

    private enum FeedEnd {
        case dropped(ErrorLogInitiator, retryPromptly: Bool)
        case revoked
        case cancelled
    }

    private func followFeedOnce() async -> FeedEnd {
        let after: Rev
        do {
            after = try await startingRev()
        } catch {
            report(Self.feedOperation, phase: "rebaseline", error: error, initiator: .forFailure(error))
            return .dropped(.forFailure(error), retryPromptly: false)
        }
        liveState = .catchingUp
        var last = after
        feedRequestID = nil
        do {
            for try await event in transport.changeFeed(after: after) {
                switch event {
                case let .opened(requestID):
                    feedRequestID = requestID
                    liveState = .live
                    errors.resolve(concern: .sync, operation: Self.feedOperation)
                case let .change(change):
                    guard change.rev > last else { continue }
                    try await apply(change)
                    last = change.rev
                case let .closing(reason):
                    let initiator = Self.initiator(forClosingReason: reason)
                    errors.report(ErrorLogReport(concern: .sync, connectionRole: .stream,
                        operation: Self.feedOperation, phase: "closing", reason: .serverReason(reason),
                        initiator: initiator, retryable: initiator != .deviceRevoked,
                        correlation: .request(feedRequestID)))
                    if initiator == .deviceRevoked { return .revoked }
                    return .dropped(initiator, retryPromptly: true)
                }
            }
            if Task.isCancelled { return .cancelled }
            // The server ended the stream without a closing event.
            report(Self.feedOperation, phase: "stream", reason: .app("ended_without_closing"),
                   initiator: .unknown, retryable: true)
            return .dropped(.unknown, retryPromptly: false)
        } catch let error as APIError where error.token == .cursorExpired {
            do {
                _ = try await rebaseline()
                return .dropped(.unknown, retryPromptly: true)
            } catch {
                report(Self.feedOperation, phase: "rebaseline", error: error, initiator: .forFailure(error))
                return .dropped(.forFailure(error), retryPromptly: false)
            }
        } catch let error where Self.isRevocation(error) {
            report(Self.feedOperation, phase: "open", error: error, initiator: .deviceRevoked)
            return .revoked
        } catch is CancellationError {
            return .cancelled
        } catch let error as ApplyFailure {
            report(Self.feedOperation, phase: "apply", error: error.underlying, initiator: .unknown)
            return .dropped(.unknown, retryPromptly: false)
        } catch {
            if Task.isCancelled { return .cancelled }
            report(Self.feedOperation, phase: "stream", error: error, initiator: .forFailure(error))
            return .dropped(.forFailure(error), retryPromptly: false)
        }
    }

    // MARK: Cursor

    private struct ApplyFailure: Error { let underlying: any Error }

    /// The cursor, or a fresh snapshot's `rev` on first run.
    private func startingRev() async throws -> Rev {
        if let held = try cursor.load() { return held }
        return try await rebaseline()
    }

    private func rebaseline() async throws -> Rev {
        let rev = try await model.rebaseline()
        // A rebaseline replaces the cursor, even with a lower value: the
        // server's log may have started over.
        try cursor.save(rev)
        return rev
    }

    /// The cursor moves to a change's `rev` only after the model holds it.
    private func apply(_ change: FeedChange) async throws {
        do {
            try await model.apply(change)
        } catch {
            throw ApplyFailure(underlying: error)
        }
        try advance(to: change.rev)
    }

    private func advance(to rev: Rev) throws {
        if let held = try cursor.load(), held >= rev { return }
        try cursor.save(rev)
    }

    /// The open feed's Request-Id, which correlates every report about it.
    private var feedRequestID: String?

    private func report(_ operation: String, phase: String, error: any Error, initiator: ErrorLogInitiator) {
        let apiError = error as? APIError
        errors.report(ErrorLogReport(concern: .sync, connectionRole: .stream, operation: operation,
            phase: phase, reason: .api(error), initiator: initiator, retryable: apiError?.retryable ?? true,
            correlation: .request(apiError?.requestID ?? feedRequestID), httpStatus: apiError?.status))
    }

    private func report(_ operation: String, phase: String, reason: ErrorLogReason,
                        initiator: ErrorLogInitiator, retryable: Bool) {
        errors.report(ErrorLogReport(concern: .sync, connectionRole: .stream, operation: operation,
            phase: phase, reason: reason, initiator: initiator, retryable: retryable,
            correlation: .request(feedRequestID)))
    }

    /// The server never ends a feed for idleness; it closes only on revoke or
    /// shutdown, with a `closing` event first.
    static func initiator(forClosingReason reason: String) -> ErrorLogInitiator {
        reason == "revoked" ? .deviceRevoked : .serverClosed
    }

    /// A revoked device fails the TLS handshake: the server rejects its
    /// certificate. A browser session gets 401 instead.
    static func isRevocation(_ error: any Error) -> Bool {
        if let error = error as? APIError { return error.status == 401 }
        let value = error as NSError
        return value.domain == NSURLErrorDomain &&
            (value.code == NSURLErrorClientCertificateRejected || value.code == NSURLErrorClientCertificateRequired)
    }
}

/// The durable cursor in a small file of its own, written atomically.
public final class FileRevCursorStore: RevCursorStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func load() throws -> Rev? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8), let rev = Rev(text) else {
            throw FeedDecodingError.missingRev
        }
        return rev
    }

    public func save(_ rev: Rev) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(String(rev).utf8).write(to: url, options: [.atomic])
    }
}
