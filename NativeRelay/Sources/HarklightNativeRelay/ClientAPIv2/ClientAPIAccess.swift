import AttentionDomain
import Foundation

public enum ClientAPIAccessState: Equatable, Sendable {
    case available
    case paused
    case revoked
}

/// Keeps the cache usable after a pause or revocation while gating network work
/// from Sync, the outbox and the independent request channels.
public final class ClientAPIAccess: ClientAPITransport, @unchecked Sendable {
    private let transport: any ClientAPITransport
    private let onChanged: @Sendable (ClientAPIAccessState) -> Void
    private let lock = NSLock()
    private var current: ClientAPIAccessState = .available
    private var closed = false
    private var generation = 0
    private var nextMeCheck = 0
    private var latestMeCheck = 0
    private var model: ServerModelV2Store?
    private var errors: any ErrorLogging = NoopErrorLog()

    public init(transport: any ClientAPITransport,
                onChanged: @escaping @Sendable (ClientAPIAccessState) -> Void = { _ in }) {
        self.transport = transport
        self.onChanged = onChanged
    }

    public var state: ClientAPIAccessState { lock.withLock { current } }

    /// Local teardown is distinct from an authenticated revocation. It
    /// invalidates the transport without starting a re-enrolment flow.
    public func close() {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldClose { transport.close() }
    }
    struct MeCheck {
        let number: Int
        let generation: Int
    }

    func beginMeCheck() -> MeCheck {
        lock.withLock {
            nextMeCheck += 1
            return MeCheck(number: nextMeCheck, generation: generation)
        }
    }

    func restorePause(from model: ServerModelV2Store, savedMePaused: Bool, errors: any ErrorLogging) {
        lock.withLock {
            self.model = model
            self.errors = errors
        }
        if model.snapshot.accountPaused == true || savedMePaused { pause() }
    }

    func pause() { update(.paused) }
    func revoke() { update(.revoked) }
    func applyMeAccountState(_ value: String?, check: MeCheck) -> Bool {
        switch value {
        case "active": return update(.available, meCheck: check)
        case "paused": return update(.paused, meCheck: check)
        default: return update(nil, meCheck: check)
        }
    }

    @discardableResult
    private func update(_ next: ClientAPIAccessState?, meCheck: MeCheck? = nil) -> Bool {
        let result: (accepted: Bool, changed: Bool, saveError: (any Error)?, errors: any ErrorLogging) = lock.withLock {
            guard !closed, current != .revoked else { return (false, false, nil, errors) }
            if let meCheck {
                guard meCheck.generation == generation, meCheck.number > latestMeCheck else {
                    return (false, false, nil, errors)
                }
                latestMeCheck = meCheck.number
            }
            guard let next, current != next else { return (true, false, nil, errors) }
            current = next
            generation += 1
            do {
                if next != .revoked { try model?.saveAccountPause(next == .paused) }
                return (true, true, nil, errors)
            } catch {
                return (true, true, error, errors)
            }
        }
        if let error = result.saveError {
            result.errors.report(ErrorLogReport(concern: .snapshot, connectionRole: .request,
                operation: "account_pause_save", phase: "save", reason: .from(error: error), retryable: true))
        }
        if result.changed, let next { onChanged(next) }
        return result.accepted
    }

    private func check(allowPaused: Bool = false) throws {
        let access = try lock.withLock {
            if closed { throw CancellationError() }
            return current
        }
        switch access {
        case .available: return
        case .paused where allowPaused: return
        case .paused:
            throw APIError(status: 403, token: .accountPaused, retryable: false, requestID: nil)
        case .revoked:
            throw APIError(status: 401, token: .unauthorized, retryable: false, requestID: nil)
        }
    }

    private func observe(_ error: any Error) {
        if ChangeFeedSync.isRevocation(error) { revoke() }
        else if (error as? APIError)?.token == .accountPaused { pause() }
    }

    private var sharedScope: (enabled: Bool, continuation: String?) {
        let held = lock.withLock { model }?.snapshot
        return (held?.sharedServerID != nil, held?.sharedContinuation?.rawValue)
    }

    private func scoped(_ request: APIRequest) -> APIRequest {
        var request = request
        request.sharedMessages = sharedScope.enabled
        return request
    }

    private static var missingContinuation: APIError {
        APIError(status: 410, token: .cursorExpired, retryable: false, requestID: nil)
    }

    public func send(_ request: APIRequest) async throws -> APIResponse {
        let allowPaused = request.method == .get && request.path == "/v2/me"
        try check(allowPaused: allowPaused)
        do {
            let response = try await transport.send(scoped(request))
            // An accepted write still has a receipt even if access changed
            // while sending it. The caller must be able to settle its key.
            if request.method == .get { try check(allowPaused: allowPaused) }
            return response
        } catch {
            observe(error)
            throw error
        }
    }

    public func download(_ request: APIRequest, to destination: URL) async throws -> APIResponse {
        try check()
        do {
            let response = try await transport.download(scoped(request), to: destination)
            try check()
            return response
        } catch {
            observe(error)
            throw error
        }
    }

    public func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        do { try check() }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        let scope = sharedScope
        if scope.enabled {
            guard let continuation = scope.continuation else {
                return AsyncThrowingStream { $0.finish(throwing: Self.missingContinuation) }
            }
            return transport.changeFeed(after: after, continuation: continuation)
        }
        return transport.changeFeed(after: after)
    }

    public func changeBatch(after: Rev) async throws -> FeedBatch {
        try check()
        do {
            let scope = sharedScope
            let batch: FeedBatch
            if scope.enabled {
                guard let continuation = scope.continuation else { throw Self.missingContinuation }
                batch = try await transport.changeBatch(after: after, continuation: continuation)
            } else {
                batch = try await transport.changeBatch(after: after)
            }
            try check()
            return batch
        } catch {
            observe(error)
            throw error
        }
    }
}
