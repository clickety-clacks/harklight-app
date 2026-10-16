import XCTest
@testable import AttentionHostBoundary

private final class TestSources: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    private var sequence: UInt8 = 1

    func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return time
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        time += seconds
    }

    func bytes(_ count: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        let value = sequence
        sequence &+= 1
        return Data(repeating: value, count: count)
    }
}

final class HostBoundaryTests: XCTestCase {
    private let accountA = HostAccount(scope: "relay-A/person-1", deviceGeneration: "device-1")
    private let accountB = HostAccount(scope: "relay-B/person-1", deviceGeneration: "device-1")

    private func gate(_ sources: TestSources) throws -> HostSessionGate {
        try HostSessionGate(now: { sources.now() }, random: { sources.bytes($0) })
    }

    func testPairingSingleUseAttemptLimitExpiryAndSessionFences() throws {
        let sources = TestSources()
        let gate = try gate(sources)
        try gate.activate(accountA)
        let first = try gate.issuePairSecret(for: accountA)
        XCTAssertEqual(Data(base64Encoded: first.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "==")?.count, 16)
        let session = try gate.pair(secret: first, account: accountA)
        XCTAssertTrue(gate.authorize(token: session.token, account: accountA,
                                     hostGeneration: session.hostGeneration))
        XCTAssertFalse(gate.authorize(token: session.token, account: accountB,
                                      hostGeneration: session.hostGeneration))
        XCTAssertThrowsError(try gate.pair(secret: first, account: accountA))
        gate.logout(token: session.token)
        XCTAssertFalse(gate.authorize(token: session.token, account: accountA,
                                      hostGeneration: session.hostGeneration))

        let second = try gate.issuePairSecret(for: accountA)
        for _ in 0..<5 { XCTAssertThrowsError(try gate.pair(secret: "wrong", account: accountA)) }
        XCTAssertThrowsError(try gate.pair(secret: second, account: accountA))
        let third = try gate.issuePairSecret(for: accountA)
        sources.advance(300)
        XCTAssertThrowsError(try gate.pair(secret: third, account: accountA))
        let fourth = try gate.issuePairSecret(for: accountA)
        let expiring = try gate.pair(secret: fourth, account: accountA)
        sources.advance(12 * 60 * 60)
        XCTAssertFalse(gate.authorize(token: expiring.token, account: accountA,
                                      hostGeneration: expiring.hostGeneration))
    }

    func testAccountSwitchAndHostRestartFenceOldPages() throws {
        let sources = TestSources()
        let gate = try gate(sources)
        try gate.activate(accountA)
        let a = try gate.pair(secret: gate.issuePairSecret(for: accountA), account: accountA)
        try gate.activate(accountB)
        XCTAssertFalse(gate.authorize(token: a.token, account: accountA,
                                      hostGeneration: a.hostGeneration))
        XCTAssertThrowsError(try gate.issuePairSecret(for: accountA))
        let b = try gate.pair(secret: gate.issuePairSecret(for: accountB), account: accountB)
        try gate.restart()
        XCTAssertFalse(gate.authorize(token: b.token, account: accountB,
                                      hostGeneration: b.hostGeneration))
        let afterRestart = try gate.pair(secret: gate.issuePairSecret(for: accountB), account: accountB)
        XCTAssertNotEqual(b.hostGeneration, afterRestart.hostGeneration)
        try gate.removeAccess()
        XCTAssertFalse(gate.authorize(token: afterRestart.token, account: accountB,
                                      hostGeneration: afterRestart.hostGeneration))
    }

    func testExactPostOriginHostAndNoCredentialFallback() throws {
        let boundary = HostHTTPBoundary(port: 43123)
        let valid = HTTPRequestHead(method: "POST", path: "/api/inspect", headers: [
            "Host": ["127.0.0.1:43123"], "Origin": ["http://127.0.0.1:43123"],
            "Content-Type": ["application/json"], "Authorization": ["Bearer abc"]
        ])
        XCTAssertNoThrow(try boundary.validateAPI(valid))
        XCTAssertEqual(try boundary.bearerToken(valid), "abc")
        for headers in [
            ["Host": ["localhost:43123"], "Origin": [boundary.origin], "Content-Type": ["application/json"]],
            ["Host": [boundary.host], "Content-Type": ["application/json"]],
            ["Host": [boundary.host], "Origin": ["null"], "Content-Type": ["application/json"]],
            ["Host": [boundary.host], "Origin": [boundary.origin, boundary.origin], "Content-Type": ["application/json"]],
            ["Host": [boundary.host], "Origin": [boundary.origin], "Content-Type": ["text/plain"]]
        ] {
            XCTAssertThrowsError(try boundary.validateAPI(
                HTTPRequestHead(method: "POST", path: "/api/inspect", headers: headers)))
        }
        XCTAssertThrowsError(try boundary.validateAPI(
            HTTPRequestHead(method: "GET", path: "/api/inspect", headers: valid.headers)))
        XCTAssertThrowsError(try boundary.validateAPI(
            HTTPRequestHead(method: "POST", path: "/api/inspect?token=abc", headers: valid.headers)))
        XCTAssertNoThrow(try boundary.validateStatic(
            HTTPRequestHead(method: "GET", path: "/", headers: ["Host": [boundary.host]])))
        XCTAssertThrowsError(try boundary.validateStatic(
            HTTPRequestHead(method: "GET", path: "/api/inspect", headers: ["Host": [boundary.host]])))
    }

    func testSingleRequestFramingRejectsAmbiguousBodyAndDuplicateHeaders() throws {
        let origin = "http://127.0.0.1:43123"
        let valid = "POST /api/inspect HTTP/1.1\r\nHost: 127.0.0.1:43123\r\nOrigin: \(origin)\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        let parsed = try HTTPRequestParser.parse(Data(valid.utf8))
        XCTAssertEqual(parsed.body, Data("{}".utf8))
        XCTAssertNoThrow(try HostHTTPBoundary(port: 43123).validateAPI(parsed.head))
        for mutation in [
            valid.replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: 2\r\nContent-Length: 2"),
            valid.replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: 2\r\nTransfer-Encoding: chunked"),
            valid + "GET / HTTP/1.1\r\nHost: 127.0.0.1:43123\r\n\r\n",
            valid.replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: 3"),
            valid.replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: -1"),
            valid.replacingOccurrences(of: "Host: 127.0.0.1:43123", with: "Host : 127.0.0.1:43123")
        ] {
            XCTAssertThrowsError(try HTTPRequestParser.parse(Data(mutation.utf8)))
        }
        let doubleOrigin = valid.replacingOccurrences(of: "Origin: \(origin)",
            with: "Origin: \(origin)\r\nOrigin: \(origin)")
        XCTAssertThrowsError(try HostHTTPBoundary(port: 43123).validateAPI(
            HTTPRequestParser.parse(Data(doubleOrigin.utf8)).head))
    }
}
