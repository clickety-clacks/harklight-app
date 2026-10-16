import Darwin
import Dispatch
import Foundation

public struct HTTPReply: Sendable {
    public typealias StreamWriter = @Sendable (Data) -> Bool
    public let status: Int
    public let contentType: String
    public let body: Data
    public let staticAsset: Bool
    public let stream: (@Sendable (StreamWriter) -> Void)?

    public init(status: Int, contentType: String = "application/json", body: Data,
                staticAsset: Bool = false) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.staticAsset = staticAsset
        self.stream = nil
    }

    /// The producer runs on the connection worker. It must stop when `send`
    /// returns false and must recheck its scoped session before each snapshot.
    public init(status: Int, contentType: String = "application/x-ndjson",
                stream: @escaping @Sendable (StreamWriter) -> Void) {
        self.status = status
        self.contentType = contentType
        self.body = Data()
        self.staticAsset = false
        self.stream = stream
    }
}

/// A foreground-owned, one-request-per-connection HTTP/1.1 listener.
/// The semantic handler is supplied by the C native port adapter; this
/// transport has no replica, intent ledger, or relay credentials.
public final class LoopbackHTTPServer: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (ParsedHTTPRequest, HostHTTPBoundary) -> HTTPReply
    private var listener: Int32 = -1
    private var active = false
    private var selectedPort: UInt16 = 0

    public init(handler: @escaping @Sendable (ParsedHTTPRequest, HostHTTPBoundary) -> HTTPReply) {
        self.handler = handler
    }

    public var port: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return selectedPort
    }

    @discardableResult
    public func start(port requestedPort: UInt16 = 0) throws -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        guard !active else { throw HostBoundaryError.rejected }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostBoundaryError.rejected }
        do {
            var noSignal: Int32 = 1
            guard Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                                    socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw HostBoundaryError.rejected
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = requestedPort.bigEndian
            let parsed = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
            guard parsed == 1 else { throw HostBoundaryError.rejected }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 16) == 0 else {
                throw HostBoundaryError.rejected
            }
            var actual = sockaddr_in()
            var actualSize = socklen_t(MemoryLayout<sockaddr_in>.size)
            let found = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fd, $0, &actualSize)
                }
            }
            guard found == 0 else { throw HostBoundaryError.rejected }
            selectedPort = UInt16(bigEndian: actual.sin_port)
            listener = fd
            active = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.acceptLoop(fd)
            }
            return selectedPort
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        active = false
        let fd = listener
        listener = -1
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    deinit { stop() }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var noSignal: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                              socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        let reply: HTTPReply
        if let request = try? Self.readOne(fd) {
            reply = handler(request, HostHTTPBoundary(port: port))
        } else {
            reply = HTTPReply(status: 400, body: Data("{\"error\":\"invalid_request\"}".utf8))
        }
        let reason: String
        switch reply.status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(reply.status) \(reason)\r\n"
        head += "Content-Type: \(reply.contentType)\r\n"
        if reply.stream == nil { head += "Content-Length: \(reply.body.count)\r\n" }
        else { head += "Transfer-Encoding: chunked\r\n" }
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n"
        if reply.staticAsset {
            head += "Content-Security-Policy: default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n"
        }
        head += "\r\n"
        guard Self.writeAll(Data(head.utf8), to: fd) else { return }
        if let stream = reply.stream {
            stream { chunk in
                guard !chunk.isEmpty else { return true }
                let header = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
                return Self.writeAll(header, to: fd) &&
                    Self.writeAll(chunk, to: fd) &&
                    Self.writeAll(Data("\r\n".utf8), to: fd)
            }
            _ = Self.writeAll(Data("0\r\n\r\n".utf8), to: fd)
        } else {
            _ = Self.writeAll(reply.body, to: fd)
        }
    }

    private static func readOne(_ fd: Int32) throws -> ParsedHTTPRequest {
        var bytes = Data()
        let separator = Data("\r\n\r\n".utf8)
        while bytes.count <= HTTPRequestParser.maxHeaderBytes + HTTPRequestParser.maxBodyBytes {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { throw HostBoundaryError.rejected }
            bytes.append(contentsOf: chunk[..<count])
            guard let range = bytes.range(of: separator) else {
                if bytes.count > HTTPRequestParser.maxHeaderBytes { throw HostBoundaryError.rejected }
                continue
            }
            guard range.lowerBound <= HTTPRequestParser.maxHeaderBytes,
                  let text = String(data: bytes[..<range.lowerBound], encoding: .utf8) else {
                throw HostBoundaryError.rejected
            }
            let first = text.components(separatedBy: "\r\n").first ?? ""
            let isPost = first.hasPrefix("POST ")
            let length: Int
            if isPost {
                let lines = text.components(separatedBy: "\r\n").dropFirst()
                let values = lines.compactMap { line -> Int? in
                    guard let colon = line.firstIndex(of: ":"),
                          line[..<colon].caseInsensitiveCompare("Content-Length") == .orderedSame else {
                        return nil
                    }
                    return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }
                guard values.count == 1, values[0] >= 0,
                      values[0] <= HTTPRequestParser.maxBodyBytes else {
                    throw HostBoundaryError.rejected
                }
                length = values[0]
            } else {
                length = 0
            }
            let expected = range.upperBound + length
            if bytes.count < expected { continue }
            guard bytes.count == expected else { throw HostBoundaryError.rejected }
            return try HTTPRequestParser.parse(bytes)
        }
        throw HostBoundaryError.rejected
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var written = 0
            while written < raw.count {
                let count = Darwin.send(fd, base.advanced(by: written), raw.count - written, 0)
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
    }
}
