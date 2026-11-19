import Foundation
@testable import HarklightNativeRelay
import XCTest

/// Answers requests from a per-test script, delivering bodies in chunks the
/// way a network does.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var chunks: [Data]
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: Reply? = Self.lock.withLock {
            Self.seen.append(request)
            return Self.handler?(request)
        }
        guard let reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/2",
                                             headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HTTPSClientAPITransportTests: XCTestCase {
    private func transport(_ handler: @escaping (URLRequest) -> StubURLProtocol.Reply) -> HTTPSClientAPITransport {
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = handler
            StubURLProtocol.seen = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HTTPSClientAPITransport(baseURL: URL(string: "https://server.example:8443")!,
                                       configuration: configuration, delegate: nil)
    }

    func testAWriteCarriesItsKeyAndPreconditionAndAReplayedAnswerIsMarked() async throws {
        let key = UUID()
        let api = transport { _ in
            StubURLProtocol.Reply(status: 200, headers: ["Request-Id": "req-7", "Idempotent-Replayed": "true"],
                                  chunks: [Data(#"{"rev":42}"#.utf8)])
        }
        let response = try await api.send(APIRequest(method: .put, path: "/v2/settings/priority-levels",
                                                     body: Data("{}".utf8), idempotencyKey: key, ifMatch: "\"e1\""))
        let sent = try XCTUnwrap(StubURLProtocol.lock.withLock { StubURLProtocol.seen.first })
        XCTAssertEqual(sent.httpMethod, "PUT")
        XCTAssertEqual(sent.url?.absoluteString, "https://server.example:8443/v2/settings/priority-levels")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Idempotency-Key"), key.uuidString.lowercased())
        XCTAssertEqual(sent.value(forHTTPHeaderField: "If-Match"), "\"e1\"")
        XCTAssertEqual(response.requestID, "req-7")
        XCTAssertTrue(response.replayed)
        XCTAssertEqual(response.rev, 42)
    }

    func testARefusalBecomesAnAPIErrorWithTokenRequestIdAndRetryAfter() async throws {
        let api = transport { _ in
            StubURLProtocol.Reply(status: 503, headers: ["Request-Id": "req-9", "Retry-After": "7"],
                                  chunks: [Data(#"{"error":"retry_later","retryable":true}"#.utf8)])
        }
        do {
            _ = try await api.send(.get("/v2/inbox", query: ["limit": "50"]))
            XCTFail("A 503 is an error.")
        } catch let error as APIError {
            XCTAssertEqual(error, APIError(status: 503, token: .retryLater, retryable: true,
                                           requestID: "req-9", retryAfter: 7))
        }
        XCTAssertEqual(StubURLProtocol.lock.withLock { StubURLProtocol.seen.first?.url?.query }, "limit=50")
    }

    func testTheFeedSplitsChunkedEventsAcrossLineEndingsAndIgnoresHeartbeats() async throws {
        let stream = ": heartbeat\r\n\r\nid: 5\r\nevent: item\r\ndata: {\"a\"\r\n:x\r\ndata: :1}\r\n\r\nid: 6\nevent: closing\ndata: {\"reason\":\"idle_timeout\"}\n\n"
        let bytes = Array(stream.utf8)
        let chunks = stride(from: 0, to: bytes.count, by: 7).map { Data(bytes[$0..<min($0 + 7, bytes.count)]) }
        let api = transport { _ in
            StubURLProtocol.Reply(status: 200, headers: ["Request-Id": "feed-1", "Content-Type": "text/event-stream"],
                                  chunks: chunks)
        }
        var events: [FeedEvent] = []
        for try await event in api.changeFeed(after: 4) { events.append(event) }
        XCTAssertEqual(events, [
            .opened(requestID: "feed-1"),
            .change(FeedChange(rev: 5, kind: .item, data: Data("{\"a\"\n:1}".utf8))),
            .closing(reason: "idle_timeout")
        ])
        let sent = StubURLProtocol.lock.withLock { StubURLProtocol.seen.first }
        XCTAssertEqual(sent?.url?.query, "after=4")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Last-Event-ID"), "4", "The feed resumes by the standard header.")
    }

    func testAnExpiredFeedCursorIsReportedAsCursorExpired() async throws {
        let api = transport { _ in
            StubURLProtocol.Reply(status: 410, headers: ["Request-Id": "feed-2"],
                                  chunks: [Data(#"{"error":"cursor_expired","retryable":false}"#.utf8)])
        }
        do {
            for try await _ in api.changeFeed(after: 1) {}
            XCTFail("A 410 ends the feed with an error.")
        } catch let error as APIError {
            XCTAssertEqual(error.token, .cursorExpired)
            XCTAssertEqual(error.requestID, "feed-2")
        }
    }
}
