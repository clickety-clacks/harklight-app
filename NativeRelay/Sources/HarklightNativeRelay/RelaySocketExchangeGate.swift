import Foundation

/// Keeps request/reply exchanges on the relay socket exclusive because its
/// response reader assigns replies to waiters in arrival order.
final class RelaySocketExchangeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let onWaiterQueued: @Sendable () -> Void

    init(onWaiterQueued: @escaping @Sendable () -> Void = {}) {
        self.onWaiterQueued = onWaiterQueued
    }

    func enter() async {
        await withCheckedContinuation { continuation in
            var enterImmediately = false
            lock.lock()
            if occupied {
                waiters.append(continuation)
            } else {
                occupied = true
                enterImmediately = true
            }
            lock.unlock()

            if enterImmediately {
                continuation.resume()
            } else {
                onWaiterQueued()
            }
        }
    }

    func leave() {
        let next: CheckedContinuation<Void, Never>?
        lock.lock()
        if waiters.isEmpty {
            occupied = false
            next = nil
        } else {
            next = waiters.removeFirst()
        }
        lock.unlock()
        next?.resume()
    }
}
