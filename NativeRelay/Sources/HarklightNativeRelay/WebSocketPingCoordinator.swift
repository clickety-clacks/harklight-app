import Foundation

/// Bridges URLSession's delegate and pong callbacks to one completion per ping.
/// Opening and closing are transport events, never elapsed-time guesses.
final class WebSocketPingCoordinator: @unchecked Sendable {
    typealias Completion = @Sendable (Error?) -> Void
    typealias SendPing = @Sendable (@escaping Completion) -> Void

    private struct Pending {
        let send: SendPing
        let completion: Completion
    }

    private let lock = NSLock()
    private var isOpen = false
    private var closedError: Error?
    private var pending: [UUID: Pending] = [:]

    func ping(send: @escaping SendPing) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            register(send: send) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func register(send: @escaping SendPing, completion: @escaping Completion) {
        let id = UUID()
        lock.lock()
        if let error = closedError {
            lock.unlock()
            completion(error)
            return
        }
        pending[id] = Pending(send: send, completion: completion)
        let sendNow = isOpen
        lock.unlock()
        if sendNow { start(id) }
    }

    func opened() {
        lock.lock()
        guard closedError == nil, !isOpen else { lock.unlock(); return }
        isOpen = true
        let ids = Array(pending.keys)
        lock.unlock()
        for id in ids { start(id) }
    }

    func closed(_ error: Error) {
        lock.lock()
        guard closedError == nil else { lock.unlock(); return }
        closedError = error
        isOpen = false
        let completions = pending.values.map(\.completion)
        pending.removeAll()
        lock.unlock()
        for completion in completions { completion(error) }
    }

    private func start(_ id: UUID) {
        lock.lock()
        let send = isOpen && closedError == nil ? pending[id]?.send : nil
        lock.unlock()
        send? { [self] error in finish(id, error: error) }
    }

    private func finish(_ id: UUID, error: Error?) {
        lock.lock()
        // Removing under the lock makes pong, failure and close mutually exclusive
        // winners. A late or repeated callback cannot resume the continuation again.
        let completion = pending.removeValue(forKey: id)?.completion
        lock.unlock()
        completion?(error)
    }
}
