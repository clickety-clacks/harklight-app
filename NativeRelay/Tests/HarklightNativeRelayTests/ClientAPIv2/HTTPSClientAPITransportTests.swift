import AttentionDomain
import CryptoKit
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
        var staysOpen = false
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
        if !reply.staysOpen { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}

final class HTTPSClientAPITransportTests: XCTestCase {
    private func transport(feedIdleInterval: Duration = .seconds(60), bearer: String? = nil,
                           _ handler: @escaping (URLRequest) -> StubURLProtocol.Reply) -> HTTPSClientAPITransport {
        StubURLProtocol.lock.withLock {
            StubURLProtocol.handler = handler
            StubURLProtocol.seen = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HTTPSClientAPITransport(baseURL: URL(string: "https://server.example:8443")!,
                                       configuration: configuration, delegate: nil, feedIdleInterval: feedIdleInterval, bearer: bearer)
    }

    func testSharedRequestsAndBothFeedTransportsCarryTheirScope() async throws {
        let api = transport { request in
            if request.value(forHTTPHeaderField: "Accept") == "text/event-stream" {
                return .init(status: 410, chunks: [Data(#"{"error":"cursor_expired","retryable":false}"#.utf8)])
            }
            return .init(status: 200, chunks: [Data(#"{"rev":41,"changes":[]}"#.utf8)])
        }
        let model = ServerModelV2Store(fileURL: nil)
        let access = ClientAPIAccess(transport: api)
        access.restorePause(from: model, savedMePaused: false, errors: NoopErrorLog())
        _ = try model.configureSharedMessages(serverID: ExactText("server"))
        try model.rebaseline(items: [], counts: APICounts(unresolved: 0),
                             position: 40, continuation: ExactText("feed_scope"))

        _ = try await access.send(.get("/v2/items/local"))
        _ = try await access.changeBatch(after: 40)
        do {
            for try await _ in access.changeFeed(after: 40) {
                XCTFail("A rejected continuation delivers no feed events.")
            }
            XCTFail("Expected cursor expiry.")
        } catch let error as APIError {
            XCTAssertEqual(error.token, .cursorExpired)
        }
        _ = try model.configureSharedMessages(serverID: nil)
        _ = try await access.send(.get("/v2/inbox"))
        let requests = StubURLProtocol.lock.withLock { StubURLProtocol.seen }
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Harklight-Features") },
                       ["shared_messages", "shared_messages", "shared_messages", nil])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Harklight-Continuation") },
                       [nil, "feed_scope", "feed_scope", nil])
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Last-Event-ID"), "40")
        XCTAssertNil(model.heldCursor)
    }

    func testSharedDiscoveryCanReadMeAfterTheServerWithdrawsOptIn() async throws {
        let api = transport { request in
            if request.value(forHTTPHeaderField: "Harklight-Features") != nil {
                return .init(status: 400, chunks: [Data(#"{"error":"unsupported","retryable":false}"#.utf8)])
            }
            return .init(status: 200, chunks: [Data(#"{"server":{"id":"server"},"principal":{"person_id":"person"}}"#.utf8)])
        }
        let model = ServerModelV2Store(fileURL: nil)
        let access = ClientAPIAccess(transport: api)
        access.restorePause(from: model, savedMePaused: false, errors: NoopErrorLog())
        _ = try model.configureSharedMessages(serverID: ExactText("server"))
        let response = try await access.send(.get("/v2/me"))
        let me = try APIMe(json: JSONValue.parse(response.body))
        XCTAssertNil(me.sharedMessagesServerID)
        let requests = StubURLProtocol.lock.withLock { StubURLProtocol.seen }
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Harklight-Features") }, ["shared_messages", nil])
    }

    func testSharedDiscoveryRequiresAnAdvertisedCapabilityAndAffiliation() throws {
        func discovered(_ capability: Bool, affiliations: String) throws -> ExactText? {
            let wire = #"{"features":{"shared_messages":\#(capability)},"server":{"id":"server"},"principal":{"person_id":"person","organization_ids":\#(affiliations)}}"#
            return try APIMe(json: JSONValue.parse(Data(wire.utf8))).sharedMessagesServerID
        }
        XCTAssertEqual(try discovered(true, affiliations: #"["org"]"#), ExactText("server"))
        XCTAssertNil(try discovered(true, affiliations: "[]"))
        XCTAssertNil(try discovered(false, affiliations: #"["org"]"#))
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

    func testBearerCutoverPreservesFrozenWriteAndFeedCursor() async throws {
        let key = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let body = Data(#"{"request_rev":12,"comment":null}"#.utf8)
        let request = APIRequest(method: .post, path: "/v2/items/item%2F1/answer",
                                 body: body, idempotencyKey: key)
        let legacy = transport { _ in .init(status: 204, chunks: []) }
        _ = try await legacy.send(request)
        let original = try XCTUnwrap(StubURLProtocol.lock.withLock { StubURLProtocol.seen.first })

        let session = transport(bearer: "fixture-bearer") { request in
            if request.value(forHTTPHeaderField: "Accept") == "text/event-stream" {
                return .init(status: 200, headers: ["Content-Type": "text/event-stream"],
                             chunks: [Data("event: heartbeat\ndata: {}\n\n".utf8)])
            }
            return .init(status: 204, headers: ["Idempotent-Replayed": "true"], chunks: [])
        }
        let reply = try await session.send(request)
        XCTAssertTrue(reply.replayed)
        for try await _ in session.changeFeed(after: 12) {}
        let sent = StubURLProtocol.lock.withLock { StubURLProtocol.seen }
        XCTAssertEqual(sent.count, 2)
        let write = try XCTUnwrap(sent.first)
        let feed = try XCTUnwrap(sent.last)
        XCTAssertEqual(write.url?.path, original.url?.path)
        XCTAssertEqual(write.httpMethod, original.httpMethod)
        XCTAssertEqual(write.httpBody, original.httpBody)
        XCTAssertEqual(write.value(forHTTPHeaderField: "Idempotency-Key"),
                       original.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(write.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-bearer")
        XCTAssertEqual(feed.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-bearer")
        XCTAssertEqual(feed.value(forHTTPHeaderField: "Last-Event-ID"), "12")
        XCTAssertNil(write.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(feed.value(forHTTPHeaderField: "Cookie"))
    }

    func testSignInProofUsesSPKIAndSignsTheExactTransactionAndSessionHash() throws {
        let pending = try NativeSessionProof()
        let encoded = try pending.signIn(reference: "fixture-transaction")
        let expectedHash = SHA256.hash(data: Data(pending.bearer.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(encoded.sessionHash, expectedHash)
        XCTAssertEqual(pending.bearer.count, 43)
        let publicDER = try decodeBase64URL(encoded.publicKey)
        let key = try P256.Signing.PublicKey(derRepresentation: publicDER)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: decodeBase64URL(encoded.signature))
        XCTAssertTrue(key.isValidSignature(signature, for: Data(
            "harklight-v2:sign-in\nfixture-transaction\n\(expectedHash)".utf8
        )))
        let restored = try JSONDecoder().decode(NativeSessionProof.self, from: JSONEncoder().encode(pending))
        let activation = try P256.Signing.ECDSASignature(
            derRepresentation: decodeBase64URL(restored.activationSignature())
        )
        XCTAssertEqual(restored.bearer, pending.bearer)
        XCTAssertTrue(key.isValidSignature(activation, for: Data(
            "harklight-v2:migration-complete\n\(expectedHash)".utf8
        )))
    }

    private func decodeBase64URL(_ string: String) throws -> Data {
        XCTAssertFalse(string.contains("="))
        let base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return try XCTUnwrap(Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)))
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
        let stream = "event: heartbeat\r\ndata: {}\r\n\r\nid: 5\r\nevent: item\r\ndata: {\"a\"\r\n:x\r\ndata: :1}\r\n\r\nevent: closing\ndata: {\"reason\":\"storage_unavailable\"}\n\n"
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
            .heartbeat,
            .change(FeedChange(rev: 5, kind: .item, data: Data("{\"a\"\n:1}".utf8))),
            .closing(reason: "storage_unavailable")
        ])
        let sent = StubURLProtocol.lock.withLock { StubURLProtocol.seen.first }
        XCTAssertEqual(sent?.url?.query, "after=4")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Last-Event-ID"), "4", "The feed resumes by the standard header.")
    }

    func testAGenuinelyIdleFeedEndsWithTheClientDeadlineError() async throws {
        let api = transport(feedIdleInterval: .milliseconds(250)) { _ in
            StubURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/event-stream"],
                                  chunks: [], staysOpen: true)
        }
        var feed = api.changeFeed(after: 4).makeAsyncIterator()
        let first = try await feed.next()
        XCTAssertEqual(first, .opened(requestID: nil))
        do {
            _ = try await feed.next()
            XCTFail("Expected the client's own idle timeout.")
        } catch ChangeFeedIdleTimeout.expired {
            // The response stayed open and sent no bytes.
        }
    }

    func testRevokedClosingWithAnExplicitIDKeepsSyncRetryable() async throws {
        for frame in ["id: 8\nevent: closing\ndata: {\"reason\":\"revoked\"}\n\n",
                      "id:\nevent: closing\ndata: {\"reason\":\"revoked\"}\n\n"] {
            let api = transport { request in
                if request.value(forHTTPHeaderField: "Accept") != "text/event-stream" {
                    return StubURLProtocol.Reply(status: 200,
                        chunks: [Data(#"{"changes":[],"rev":7,"more":false}"#.utf8)])
                }
                return StubURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/event-stream",
                    "Request-Id": "feed-7"], chunks: [Data(frame.utf8)])
            }
            defer { api.close() }
            let cursor = MemoryRevCursor(7)
            let model = RecordingSyncModel(snapshotRev: { 3 })
            let errors = RecordingErrorLogV2()
            let sync = ChangeFeedSync(transport: api, model: model.using(cursor), errors: errors,
                waitBeforeRetry: { _ in throw CancellationError() })
            await sync.runForeground()
            let report = try XCTUnwrap(errors.reports.first)
            XCTAssertEqual(report.phase, "stream")
            XCTAssertEqual(report.correlation.requestID, "feed-7")
            XCTAssertEqual(report.initiator, .unknown)
            XCTAssertTrue(report.retryable)
            XCTAssertNotEqual(report.reason, .serverReason("revoked"))
            let liveState = await sync.liveState
            XCTAssertEqual(liveState, .paused(.unknown))
            XCTAssertEqual(try cursor.load(), 7)
            XCTAssertEqual(model.rebaselines, 0)
            XCTAssertTrue(model.applied.isEmpty)
        }
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

    func testUploadHandleAttachesOnceAndOnlyTheReturnedFileRefDownloads() async throws {
        let server = StagedFileFixture()
        let api = transport(server.respond)
        let files = ClientAPIFiles(transport: api)
        let uploadKey = UUID()
        let name = ExactText("café 100%.bin")
        let upload = try await files.upload(server.bytes, name: name, contentType: "application/octet-stream",
                                            idempotencyKey: uploadKey)
        XCTAssertEqual(upload.name, name)
        XCTAssertEqual(upload.size, UInt64(server.bytes.count))
        let sent = try XCTUnwrap(StubURLProtocol.lock.withLock { StubURLProtocol.seen.first })
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Idempotency-Key"), uploadKey.uuidString.lowercased())
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Length"), String(server.bytes.count))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Disposition"),
                       "attachment; filename*=UTF-8''caf%C3%A9%20100%25.bin")

        let write = ClientAPIWrites.reply(itemID: ExactText("i"), text: ExactText("See file"), fileIDs: [upload.handle])
        let reply = try await api.send(APIRequest(method: write.write.method, path: write.write.path,
            body: write.write.body, idempotencyKey: UUID()))
        let entryJSON = try XCTUnwrap(JSONValue.parse(reply.body).uniqueValue(named: "entry"))
        let entry = try APIEntry(json: entryJSON)
        let ref = try XCTUnwrap(entry.files.first)
        XCTAssertNotEqual(ref.fileID.value, upload.handle.value)
        let downloaded = try await files.download(ref.fileID)
        XCTAssertEqual(downloaded, server.bytes)
        let downloadRequest = StubURLProtocol.lock.withLock { StubURLProtocol.seen.last }
        XCTAssertEqual(downloadRequest?.value(forHTTPHeaderField: "Accept"), "*/*")

        do {
            // Deliberately bypass the typed file client to probe the wire contract.
            _ = try await api.send(.get("/v2/files/staged%2F1"))
            XCTFail("An upload handle cannot download bytes.")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 404)
            XCTAssertEqual(error.token, .notFound)
        }
        do {
            try await files.discard(upload.handle)
            XCTFail("An attached upload cannot be discarded.")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.token, .alreadyClosed)
            XCTAssertEqual(ErrorLogReason.api(error).code, "already_closed")
        }
        do {
            _ = try await api.send(APIRequest(method: write.write.method, path: write.write.path,
                body: write.write.body, idempotencyKey: UUID()))
            XCTFail("An attached upload cannot be used in a second write.")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.token, .invalidField)
        }
    }

    func testDiscardRemovesAnAbandonedUpload() async throws {
        let server = StagedFileFixture()
        let api = transport(server.respond)
        let files = ClientAPIFiles(transport: api)
        let upload = try await files.upload(server.bytes, name: ExactText("café 100%.bin"),
            contentType: "application/octet-stream", idempotencyKey: UUID())
        try await files.discard(upload.handle)
        let sent = try XCTUnwrap(StubURLProtocol.lock.withLock { StubURLProtocol.seen.last })
        XCTAssertEqual(sent.httpMethod, "DELETE")
        XCTAssertEqual(sent.url?.absoluteString, "https://server.example:8443/v2/files/staged%2F1")

        let write = ClientAPIWrites.reply(itemID: ExactText("i"), text: ExactText("See file"), fileIDs: [upload.handle])
        do {
            _ = try await api.send(APIRequest(method: write.write.method, path: write.write.path,
                body: write.write.body, idempotencyKey: UUID()))
            XCTFail("A discarded upload cannot be attached.")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.token, .invalidField)
        }
    }

    func testAFileUploadSendsTheRetainedBytesDirectlyFromDisk() async throws {
        let server = StagedFileFixture()
        let api = transport(server.respond)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try server.bytes.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        let upload = try await ClientAPIFiles(transport: api).upload(from: source,
            byteCount: UInt64(server.bytes.count), name: ExactText("café 100%.bin"),
            contentType: "application/octet-stream", idempotencyKey: UUID())
        XCTAssertEqual(upload.handle.value, ExactText("staged/1"))
        let sent = try XCTUnwrap(StubURLProtocol.lock.withLock { StubURLProtocol.seen.first })
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Length"), String(server.bytes.count))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Disposition"),
                       "attachment; filename*=UTF-8''caf%C3%A9%20100%25.bin")
    }

    func testDiskDownloadReturnsTheContentTypeAndWritesTheBytesWithoutABufferedBody() async throws {
        let first = Data([0x89, 0x50, 0x4e, 0x47])
        let second = Data([0x0d, 0x0a, 0x1a, 0x0a])
        let api = transport { _ in
            StubURLProtocol.Reply(status: 200, headers: ["Content-Type": "image/png", "Request-Id": "download"],
                                  chunks: [first, second])
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let result = try await ClientAPIFiles(transport: api).download(FileDownloadID(ExactText("download/1")),
                                                                     to: destination)
        XCTAssertEqual(result.contentType, "image/png")
        XCTAssertEqual(result.requestID, "download")
        XCTAssertTrue(result.body.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), first + second)
    }

    func testDiskDownloadRejectsTheWrongContentTypeAndRemovesTheFile() async throws {
        let api = transport { _ in
            StubURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"],
                                  chunks: [Data("abc".utf8)])
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            _ = try await ClientAPIFiles(transport: api).download(FileDownloadID(ExactText("download/1")),
                to: destination, expectedContentType: "image/png")
            XCTFail("The attachment and HTTP media types must agree.")
        } catch ConversationError.fileMediaTypeMismatch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testPreviouslySavedFileRefStillDecodesWithATypedDownloadID() throws {
        let legacy = Data(#"{"fileID":{"rawValue":"download/1"},"name":{"rawValue":"file.bin"},"size":3,"sha256":"hash"}"#.utf8)
        let ref = try JSONDecoder().decode(APIFileRef.self, from: legacy)
        XCTAssertEqual(ref.fileID, FileDownloadID(ExactText("download/1")))
        let saved = try JSONEncoder().encode(ref)
        XCTAssertEqual(try JSONDecoder().decode(APIFileRef.self, from: saved), ref)
    }
}

/// One staged file under the URL protocol's lock. The attachment consumes the
/// staging handle and gives the entry a different ID for its download.
private final class StagedFileFixture {
    private enum State { case absent, staged, attached }

    private var state = State.absent
    let bytes = Data([0, 255, 7])
    private let digest = String(repeating: "a", count: 64)

    func respond(_ request: URLRequest) -> StubURLProtocol.Reply {
        let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath
        switch (request.httpMethod, path) {
        case ("POST", "/v2/files"):
            guard body(of: request) == bytes else {
                return json(400, #"{"error":"invalid_field","retryable":false}"#)
            }
            state = .staged
            return json(201, #"{"file_id":"staged/1","name":"café 100%.bin","size":3,"sha256":"\#(digest)"}"#)
        case ("POST", "/v2/items/i/replies"):
            guard state == .staged, let body = body(of: request),
                  let decoded = try? JSONValue.parse(body),
                  decoded.uniqueValue(named: "file_ids")?.arrayValues == [.string(ExactText("staged/1"))] else {
                return json(400, #"{"error":"invalid_field","field":"file_ids","retryable":false}"#)
            }
            state = .attached
            return json(200, #"{"rev":2,"entry":{"entry_id":"reply","item_id":"i","rev":2,"position":1,"kind":"reply","author":"person","request_revision":1,"files":[{"file_id":"download/1","name":"café 100%.bin","size":3,"sha256":"\#(digest)"}]}}"#)
        case ("GET", "/v2/files/download%2F1") where state == .attached:
            return .init(status: 200, headers: ["Content-Type": "application/octet-stream"], chunks: [bytes])
        case ("DELETE", "/v2/files/staged%2F1") where state == .staged:
            state = .absent
            return .init(status: 204, chunks: [])
        case ("DELETE", "/v2/files/staged%2F1") where state == .attached:
            return json(409, #"{"error":"already_closed","retryable":false}"#)
        default:
            return json(404, #"{"error":"not_found","retryable":false}"#)
        }
    }

    private func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        let capacity = 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        while true {
            let count = stream.read(&buffer, maxLength: capacity)
            if count < 0 { return nil }
            if count == 0 { return bytes }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }

    private func json(_ status: Int, _ value: String) -> StubURLProtocol.Reply {
        .init(status: status, headers: ["Content-Type": "application/json"], chunks: [Data(value.utf8)])
    }
}
