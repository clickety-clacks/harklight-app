import Foundation

/// Keeps request/reply exchanges on the relay socket exclusive because its
/// response reader assigns replies to waiters in arrival order.
actor RelaySocketExchangeGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let onWaiterQueued: @Sendable () -> Void

    init(onWaiterQueued: @escaping @Sendable () -> Void = {}) {
        self.onWaiterQueued = onWaiterQueued
    }

    func enter() async {
        if occupied {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                onWaiterQueued()
            }
        } else {
            occupied = true
        }
    }

    func leave() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
