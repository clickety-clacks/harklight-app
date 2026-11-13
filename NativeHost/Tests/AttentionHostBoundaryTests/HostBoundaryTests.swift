import XCTest
@testable import AttentionHostBoundary

private final class TestSources: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt8 = 1

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
        try HostSessionGate(random: { sources.bytes($0) })
    }

    func testPairingSingleUseAndSessionFences() throws {
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
        let afterWrongAttempts = try gate.pair(secret: second, account: accountA)
        XCTAssertTrue(gate.authorize(token: afterWrongAttempts.token, account: accountA,
                                     hostGeneration: afterWrongAttempts.hostGeneration))
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

    func testAPIRequestShapeAndBearerAuthenticationDoNotDependOnHostOrOrigin() throws {
        let boundary = HostHTTPBoundary(port: 43123)
        let acceptedHeaders = [
            ["Content-Type": ["application/json"], "Authorization": ["Bearer abc"]],
            ["Host": ["localhost:43123"], "Origin": ["http://example.invalid"],
             "Content-Type": ["application/json"], "Authorization": ["Bearer abc"]],
            ["Host": ["localhost:43123", boundary.host], "Origin": ["null", "http://example.invalid"],
             "Content-Type": ["application/json"], "Authorization": ["Bearer abc"]]
        ]
        for headers in acceptedHeaders {
            let request = HTTPRequestHead(method: "POST", path: "/api/inspect", headers: headers)
            XCTAssertNoThrow(try boundary.validateAPI(request))
            XCTAssertEqual(try boundary.bearerToken(request), "abc")
        }
        XCTAssertThrowsError(try boundary.validateAPI(
            HTTPRequestHead(method: "GET", path: "/api/inspect", headers: acceptedHeaders[0])))
        XCTAssertThrowsError(try boundary.validateAPI(
            HTTPRequestHead(method: "POST", path: "/api/inspect?token=abc", headers: acceptedHeaders[0])))
        let unauthenticated = HTTPRequestHead(method: "POST", path: "/api/inspect",
                                              headers: ["Content-Type": ["application/json"]])
        XCTAssertNoThrow(try boundary.validateAPI(unauthenticated))
        XCTAssertThrowsError(try boundary.bearerToken(unauthenticated))
        XCTAssertNoThrow(try boundary.validateStatic(
            HTTPRequestHead(method: "GET", path: "/", headers: ["Host": ["localhost:43123"]])))
        XCTAssertNoThrow(try boundary.validateStatic(
            HTTPRequestHead(method: "GET", path: "/", headers: [:])))
        XCTAssertThrowsError(try boundary.validateStatic(
            HTTPRequestHead(method: "GET", path: "/api/inspect", headers: [:])))
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
        XCTAssertNoThrow(try HostHTTPBoundary(port: 43123).validateAPI(
            HTTPRequestParser.parse(Data(doubleOrigin.utf8)).head))
    }
}
