import Foundation
import Security

/// The r2 client API over HTTPS (HTTP/2 where the server offers it) with the
/// enrolled device certificate. One URLSession carries every request and the
/// feed; requests run in parallel and none waits on another.
public final class HTTPSClientAPITransport: ClientAPITransport, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let feedIdleInterval: Duration

    /// `baseURL` is the device listener, for example `https://host:port`.
    public convenience init(baseURL: URL, clientIdentity: TrustedKeychainIdentity, trustedRootDER: Data) throws {
        guard baseURL.scheme == "https", let host = baseURL.host?.lowercased(), !host.isEmpty else {
            throw ClientConnectionError.invalidEndpoint
        }
        guard let root = SecCertificateCreateWithData(nil, trustedRootDER as CFData) else {
            throw ClientConnectionError.invalidTrustAnchor
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = .infinity
        self.init(baseURL: baseURL, configuration: configuration,
                  delegate: DeviceCertificateDelegate(host: host, identity: clientIdentity.value, root: root))
    }

    /// Tests supply a configuration with a stub protocol and no delegate.
    init(baseURL: URL, configuration: URLSessionConfiguration, delegate: (any URLSessionDelegate)?,
         feedIdleInterval: Duration = .seconds(60)) {
        self.baseURL = baseURL
        self.feedIdleInterval = feedIdleInterval
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func close() { session.invalidateAndCancel() }

    // MARK: Requests

    public func send(_ request: APIRequest) async throws -> APIResponse {
        let urlRequest = urlRequest(for: request)
        let (data, response): (Data, URLResponse)
        if let file = request.fileBody {
            (data, response) = try await session.upload(for: urlRequest, fromFile: file.url)
        } else {
            (data, response) = try await session.data(for: urlRequest)
        }
        return try Self.response(response, body: data)
    }

    public func download(_ request: APIRequest, to destination: URL) async throws -> APIResponse {
        let (source, response) = try await session.download(for: urlRequest(for: request))
        defer { try? FileManager.default.removeItem(at: source) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let errorBody = try handle.read(upToCount: 4096) ?? Data()
            return try Self.response(response, body: errorBody)
        }
        let result = try Self.response(response, body: Data())
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: source, to: destination)
        return result
    }

    func urlRequest(for request: APIRequest, accept: String = "application/json") -> URLRequest {
        // The path is already percent-encoded (ids are encoded once, where the
        // request is built); appending it as a component would encode it again.
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.percentEncodedPath
        components.percentEncodedPath = (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)
            + request.path
        if !request.query.isEmpty {
            components.queryItems = request.query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.setValue(request.accept ?? accept, forHTTPHeaderField: "Accept")
        if let contentType = request.contentType { urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let disposition = request.contentDisposition {
            urlRequest.setValue(disposition, forHTTPHeaderField: "Content-Disposition")
            if let fileBody = request.fileBody {
                urlRequest.setValue(String(fileBody.byteCount), forHTTPHeaderField: "Content-Length")
            } else if let body = request.body {
                urlRequest.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
            }
        }
        if let key = request.idempotencyKey {
            urlRequest.setValue(key.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        }
        if let ifMatch = request.ifMatch { urlRequest.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        if request.sharedMessages { urlRequest.setValue("shared_messages", forHTTPHeaderField: "Harklight-Features") }
        if let continuation = request.continuation {
            urlRequest.setValue(continuation, forHTTPHeaderField: "Harklight-Continuation")
        }
        return urlRequest
    }

    static func response(_ response: URLResponse, body: Data) throws -> APIResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let requestID = http.value(forHTTPHeaderField: "Request-Id")
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, body: body, requestID: requestID,
                           retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        }
        return APIResponse(status: http.statusCode, requestID: requestID, body: body,
                           etag: http.value(forHTTPHeaderField: "ETag"),
                           replayed: http.value(forHTTPHeaderField: "Idempotent-Replayed")?.lowercased() == "true",
                           contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }

    // MARK: Change feed

    public func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        openFeed(after: after, continuation: nil)
    }

    public func changeFeed(after: Rev, continuation: String) -> AsyncThrowingStream<FeedEvent, any Error> {
        openFeed(after: after, continuation: continuation)
    }

    private func changesRequest(after: Rev, continuation: String?) -> APIRequest {
        var request = APIRequest.get("/v2/changes", query: ["after": String(after)])
        request.sharedMessages = continuation != nil
        request.continuation = continuation
        return request
    }

    private func openFeed(after: Rev, continuation: String?) -> AsyncThrowingStream<FeedEvent, any Error> {
        var feedRequest = urlRequest(for: changesRequest(after: after, continuation: continuation),
                                     accept: "text/event-stream")
        // Standard SSE resume; it takes precedence over `after` on the server.
        feedRequest.setValue(String(after), forHTTPHeaderField: "Last-Event-ID")
        // The client's 60-second idle deadline takes precedence over URLSession's timeout.
        feedRequest.timeoutInterval = 120
        let request = feedRequest
        return AsyncThrowingStream { continuation in
            let idle = FeedIdleDeadline(interval: feedIdleInterval)
            let reading = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await self.readFeed(request, idle: idle, continuation: continuation)
                    }
                    group.addTask {
                        do {
                            try await idle.wait()
                            continuation.finish(throwing: ChangeFeedIdleTimeout.expired)
                        } catch {
                            // The reader finished or the caller stopped the feed.
                        }
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
    }

    private func readFeed(_ request: URLRequest, idle: FeedIdleDeadline,
                          continuation: AsyncThrowingStream<FeedEvent, any Error>.Continuation) async {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            idle.receivedBytes()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                var body = Data()
                for try await byte in bytes {
                    idle.receivedBytes()
                    body.append(byte)
                    if body.count >= 4096 { break }
                }
                _ = try Self.response(response, body: body)
                throw URLError(.badServerResponse)
            }
            continuation.yield(.opened(requestID: http.value(forHTTPHeaderField: "Request-Id")))
            var parser = ServerSentEventParser()
            var lines = SSELineSplitter()
            for try await byte in bytes {
                idle.receivedBytes()
                guard let line = lines.append(byte) else { continue }
                guard let event = parser.feed(line: line) else { continue }
                let feedEvent = try FeedEvent(event)
                continuation.yield(feedEvent)
                if case .closing = feedEvent { break }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Pending the accepted schema: each change in a batch is taken to be
    /// `{rev, kind, data}`, the same three parts a feed event carries.
    public func changeBatch(after: Rev) async throws -> FeedBatch {
        try await readBatch(after: after, continuation: nil)
    }

    public func changeBatch(after: Rev, continuation: String) async throws -> FeedBatch {
        try await readBatch(after: after, continuation: continuation)
    }

    private func readBatch(after: Rev, continuation: String?) async throws -> FeedBatch {
        let response = try await send(changesRequest(after: after, continuation: continuation))
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let rev = object["rev"].flatMap(APIResponse.rev),
              let changes = object["changes"] as? [[String: Any]] else {
            throw FeedDecodingError.invalidBatch
        }
        let decoded = try changes.map { change -> FeedChange in
            guard let rev = change["rev"].flatMap(APIResponse.rev), let kind = change["kind"] as? String,
                  let data = change["data"], JSONSerialization.isValidJSONObject(data) || data is NSNull else {
                throw FeedDecodingError.invalidBatch
            }
            let bytes = (try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed])) ?? Data()
            return FeedChange(rev: rev, kind: FeedChange.Kind(kind), data: bytes)
        }
        guard zip(decoded, decoded.dropFirst()).allSatisfy({ $0.rev < $1.rev }) else {
            throw FeedDecodingError.outOfOrder
        }
        return FeedBatch(changes: decoded, rev: rev, more: (object["more"] as? Bool) ?? false)
    }
}

private final class FeedIdleDeadline: @unchecked Sendable {
    private let interval: Duration
    private let clock = ContinuousClock()
    private let lock = NSLock()
    private var deadline: ContinuousClock.Instant

    init(interval: Duration) {
        self.interval = interval
        deadline = ContinuousClock().now.advanced(by: interval)
    }

    func receivedBytes() {
        lock.withLock { deadline = clock.now.advanced(by: interval) }
    }

    func wait() async throws {
        while true {
            let next = lock.withLock { deadline }
            try await clock.sleep(until: next)
            try Task.checkCancellation()
            if lock.withLock({ clock.now >= deadline }) { return }
        }
    }
}

/// Splits an event stream into lines on LF, CRLF or CR, keeping empty lines
/// (they dispatch events), which `AsyncBytes.lines` would drop.
struct SSELineSplitter {
    private var buffer: [UInt8] = []
    private var lastWasCR = false

    mutating func append(_ byte: UInt8) -> String? {
        if byte == 0x0A, lastWasCR {
            lastWasCR = false
            return nil
        }
        lastWasCR = byte == 0x0D
        if byte == 0x0A || byte == 0x0D {
            defer { buffer.removeAll(keepingCapacity: true) }
            return String(decoding: buffer, as: UTF8.self)
        }
        buffer.append(byte)
        return nil
    }
}

/// Presents the enrolled device identity only to the configured host and
/// trusts only the enrollment-approved root.
private final class DeviceCertificateDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    private let identity: SecIdentity
    private let root: SecCertificate

    init(host: String, identity: SecIdentity, root: SecCertificate) {
        self.host = host
        self.identity = identity
        self.root = root
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host.lowercased() == host else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
                  SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
}
