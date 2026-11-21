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
    private var generation = 0

    public init(transport: any ClientAPITransport,
                onChanged: @escaping @Sendable (ClientAPIAccessState) -> Void = { _ in }) {
        self.transport = transport
        self.onChanged = onChanged
    }

    public var state: ClientAPIAccessState { lock.withLock { current } }
    var checkGeneration: Int { lock.withLock { generation } }

    func pause() { update(.paused) }
    func revoke() { update(.revoked) }
    func confirmAvailable(checkedAt generation: Int) { update(.available, checkedAt: generation) }

    private func update(_ next: ClientAPIAccessState, checkedAt expected: Int? = nil) {
        let changed = lock.withLock {
            guard current != .revoked, current != next,
                  expected == nil || expected == generation else { return false }
            current = next
            generation += 1
            return true
        }
        if changed { onChanged(next) }
    }

    private func check(allowPaused: Bool = false) throws {
        switch state {
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

    public func send(_ request: APIRequest) async throws -> APIResponse {
        let allowPaused = request.method == .get && request.path == "/v2/me"
        try check(allowPaused: allowPaused)
        do {
            let response = try await transport.send(request)
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
            let response = try await transport.download(request, to: destination)
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
        return transport.changeFeed(after: after)
    }

    public func changeBatch(after: Rev) async throws -> FeedBatch {
        try check()
        do {
            let batch = try await transport.changeBatch(after: after)
            try check()
            return batch
        } catch {
            observe(error)
            throw error
        }
    }
}
