import Foundation
import XCTest
@testable import HarklightNativeRelay

final class WebSocketPingTests: XCTestCase {
    func testRepeatedPongCompletesCheckedContinuationOnlyOnce() async throws {
        let health = WebSocketPingCoordinator()
        health.opened()
        try await health.ping { completion in
            completion(nil)
            completion(nil)
            completion(URLError(.networkConnectionLost))
        }
    }

    func testRepeatedFailureKeepsOriginalTransportError() async {
        let health = WebSocketPingCoordinator()
        health.opened()
        do {
            try await health.ping { completion in
                completion(URLError(.networkConnectionLost))
                completion(nil)
            }
            XCTFail("A failed ping must remain a transport failure for reconnect.")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
    }

    func testPingWaitsForActualOpenAndDuplicateOpenDoesNotSendAgain() {
        let health = WebSocketPingCoordinator()
        let result = PingObservations()
        health.register(send: { completion in
            result.sent(completion)
        }, completion: { result.completed($0) })
        XCTAssertEqual(result.sendCount, 0)
        health.opened()
        XCTAssertEqual(result.sendCount, 1)
        health.opened()
        XCTAssertEqual(result.sendCount, 1)
        result.pong?(nil)
        XCTAssertEqual(result.completionCount, 1)
    }

    func testCloseBeforeOpenFailsWaiterWithoutSendingAndCannotReopen() {
        let health = WebSocketPingCoordinator()
        let result = PingObservations()
        health.register(send: { result.sent($0) }, completion: { result.completed($0) })
        health.closed(URLError(.cannotConnectToHost))
        health.opened()
        health.closed(CancellationError())
        XCTAssertEqual(result.sendCount, 0)
        XCTAssertEqual(result.completionCount, 1)
        XCTAssertEqual(result.errorCode, .cannotConnectToHost)
    }

    func testCloseCompletesPendingPingAndIgnoresLatePong() async {
        let health = WebSocketPingCoordinator()
        health.opened()
        do {
            try await health.ping { completion in
                health.closed(URLError(.networkConnectionLost))
                completion(nil)
                completion(URLError(.cancelled))
            }
            XCTFail("Closing a connection must release its pending health check.")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
    }

    func testConcurrentPongAndCloseCompleteOnceAndNewPingOnClosedConnectionDoesNotSend() {
        let health = WebSocketPingCoordinator()
        let result = PingObservations()
        health.opened()
        health.register(send: { result.sent($0) }, completion: { result.completed($0) })
        let pong = result.pong
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            if index.isMultiple(of: 2) { pong?(nil) }
            else { health.closed(URLError(.networkConnectionLost)) }
        }
        XCTAssertEqual(result.completionCount, 1)
        let later = PingObservations()
        health.register(send: { later.sent($0) }, completion: { later.completed($0) })
        XCTAssertEqual(later.sendCount, 0)
        XCTAssertEqual(later.completionCount, 1)
        XCTAssertEqual(later.errorCode, .networkConnectionLost)
    }
}

private final class PingObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var sends = 0
    private var completions = 0
    private var error: URLError.Code?
    private var callback: WebSocketPingCoordinator.Completion?

    var sendCount: Int { lock.withLock { sends } }
    var completionCount: Int { lock.withLock { completions } }
    var errorCode: URLError.Code? { lock.withLock { error } }
    var pong: WebSocketPingCoordinator.Completion? { lock.withLock { callback } }

    func sent(_ completion: @escaping WebSocketPingCoordinator.Completion) {
        lock.withLock { sends += 1; callback = completion }
    }

    func completed(_ value: Error?) {
        lock.withLock { completions += 1; error = (value as? URLError)?.code }
    }
}
