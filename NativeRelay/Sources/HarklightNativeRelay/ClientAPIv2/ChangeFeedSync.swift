import Foundation

/// The local model as Sync writes it. The model holds Sync's one cursor (the
/// last applied `rev`) with its data, so the two are saved together and a
/// model that is discarded takes its cursor with it.
///
/// Every write goes through the version gate (a change or snapshot older
/// than what is held is a no-op), so order relative to reads and writes
/// never matters.
public protocol SyncModelWriting: Sendable {
    /// The cursor saved with the model; nil before the first snapshot or
    /// after the model was discarded, which makes Sync take a snapshot.
    func heldCursor() throws -> Rev?
    /// Applies `changes` (in `rev` order) and records `cursor`, in one
    /// durable write. A change the writer cannot read is reported and skipped
    /// by the writer, never retried; a failed save throws and applies nothing.
    func apply(_ changes: [FeedChange], cursor: Rev) async throws
    /// Takes one inbox snapshot and records its position as the cursor.
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
        /// The account is paused; Sync stops and the held model stays readable.
        case accountPaused
    }

    static let feedOperation = "change_feed"
    static let catchUpOperation = "catch_up"

    private let transport: any ClientAPITransport
    private let model: any SyncModelWriting
    private let errors: any ErrorLogging
    private let waitBeforeRetry: @Sendable (_ attempt: Int) async throws -> Void
    private let onLiveState: @Sendable (LiveState) -> Void
    public private(set) var liveState: LiveState = .catchingUp {
        didSet { if liveState != oldValue { onLiveState(liveState) } }
    }

    public init(transport: any ClientAPITransport, model: any SyncModelWriting,
                errors: any ErrorLogging,
                waitBeforeRetry: @escaping @Sendable (_ attempt: Int) async throws -> Void = ChangeFeedSync.backoff,
                onLiveState: @escaping @Sendable (LiveState) -> Void = { _ in }) {
        self.transport = transport
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
            case .accountPaused:
                liveState = .accountPaused
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
            _ = try await drainBatches(from: startingRev())
            errors.resolve(concern: .sync, operation: Self.catchUpOperation)
        } catch {
            let cause = (error as? ApplyFailure)?.underlying ?? error
            report(Self.catchUpOperation, phase: error is ApplyFailure ? "apply" : "batch", error: cause,
                   initiator: .forFailure(cause))
            throw cause
        }
    }

    /// Applies JSON batches from `after` until none is left, one durable
    /// write per batch, and returns the new cursor. Rebaselines at most once.
    private func drainBatches(from start: Rev) async throws -> Rev {
        var after = start
        var rebaselined = false
        while true {
            let batch: FeedBatch
            do {
                batch = try await transport.changeBatch(after: after)
            } catch let error as APIError where error.token == .cursorExpired && !rebaselined {
                // One rebaseline per drain; a second 410 is reported.
                rebaselined = true
                after = try await rebaseline()
                continue
            }
            let fresh = batch.changes.filter { $0.rev > after }
            // Every batch is gap-free and reflects the log through its `rev`.
            let through = max(batch.rev, fresh.last?.rev ?? after)
            if through > after {
                try await apply(fresh, cursor: through)
            }
            guard batch.more else { return max(after, through) }
            // `more` without progress would loop; stop and report it.
            guard through > after else { throw FeedDecodingError.outOfOrder }
            after = through
        }
    }

    // MARK: One feed connection

    private enum FeedEnd {
        case dropped(ErrorLogInitiator, retryPromptly: Bool)
        case revoked
        case accountPaused
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
        feedRequestID = nil
        do {
            // The backlog comes by batch (one write per batch); the stream
            // then carries only live changes.
            let caughtUp = try await drainBatches(from: after)
            var last = caughtUp
            for try await event in transport.changeFeed(after: caughtUp) {
                switch event {
                case let .opened(requestID):
                    feedRequestID = requestID
                    liveState = .live
                    errors.resolve(concern: .sync, operation: Self.feedOperation)
                case .heartbeat:
                    // The transport's 60 s no-bytes timeout is reset by it.
                    continue
                case let .change(change):
                    guard change.rev > last else { continue }
                    try await apply([change], cursor: change.rev)
                    last = change.rev
                case let .closing(reason):
                    let initiator = Self.initiator(forClosingReason: reason)
                    errors.report(ErrorLogReport(concern: .sync, connectionRole: .stream,
                        operation: Self.feedOperation, phase: "closing", reason: .serverReason(reason),
                        initiator: initiator, retryable: initiator != .deviceRevoked,
                        correlation: .request(feedRequestID)))
                    if initiator == .deviceRevoked { return .revoked }
                    if reason == "account_paused" { return .accountPaused }
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
        } catch let error as APIError where error.token == .accountPaused {
            report(Self.feedOperation, phase: "open", error: error, initiator: .serverClosed)
            return .accountPaused
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
        if let held = try model.heldCursor() { return held }
        return try await rebaseline()
    }

    /// A rebaseline replaces the cursor, even with a lower value: the
    /// server's log may have started over.
    private func rebaseline() async throws -> Rev {
        try await model.rebaseline()
    }

    /// The cursor moves only with the changes, in the same durable write.
    private func apply(_ changes: [FeedChange], cursor: Rev) async throws {
        do {
            try await model.apply(changes, cursor: cursor)
        } catch {
            throw ApplyFailure(underlying: error)
        }
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

    /// The server never ends a feed for idleness; it closes only on revoke,
    /// a paused account or shutdown, with a `closing` event first.
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
