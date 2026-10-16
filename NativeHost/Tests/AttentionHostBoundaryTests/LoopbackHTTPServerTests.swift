import Darwin
import Dispatch
import Foundation
import XCTest
@testable import AttentionHostBoundary

final class LoopbackHTTPServerTests: XCTestCase {
    func testClientInterruptsPostStreamAndReconnectsAfterLastSnapshot() async throws {
        let resume = DispatchSemaphore(value: 0)
        let server = LoopbackHTTPServer { request, boundary in
            guard request.head.path == "/api/stream",
                  (try? boundary.validateAPI(request.head)) != nil,
                  (try? boundary.bearerToken(request.head)) == "fixture-token" else {
                return HTTPReply(status: 403, body: Data("{}".utf8))
            }
            if request.body == Data("{\"after\":0}".utf8) {
                return HTTPReply(status: 200) { send in
                    guard send(Data("{\"snapshot\":1}\n".utf8)) else { return }
                    _ = resume.wait(timeout: .now() + 5)
                    _ = send(Data("{\"snapshot\":2}\n".utf8))
                }
            }
            return HTTPReply(status: 200) { send in
                _ = send(Data("{\"snapshot\":2}\n".utf8))
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let origin = "http://127.0.0.1:\(port)"
        let raw = "POST /api/stream HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: \(origin)\r\nContent-Type: application/json\r\nAuthorization: Bearer fixture-token\r\nContent-Length: 11\r\n\r\n{\"after\":0}"
        _ = raw.withCString { Darwin.send(socket, $0, raw.utf8.count, 0) }
        var received = Data()
        while !String(decoding: received, as: UTF8.self).contains("{\"snapshot\":1}\n") {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.recv(socket, &chunk, chunk.count, 0)
            XCTAssertGreaterThan(count, 0)
            if count <= 0 { break }
            received.append(contentsOf: chunk[..<count])
        }
        XCTAssertTrue(String(decoding: received, as: UTF8.self).contains("Transfer-Encoding: chunked"))
        Darwin.close(socket) // actual client interruption before the producer's second event
        resume.signal()
        let next = try await request(origin + "/api/stream", method: "POST", origin: origin,
                                     body: "{\"after\":1}", bearer: "fixture-token")
        XCTAssertEqual(next.0, 200)
        XCTAssertEqual(String(decoding: next.1, as: UTF8.self), "{\"snapshot\":2}\n")
    }

    func testBundledPageIsPublicButAPIHasNoStoreFallback() async throws {
        let page = BundledHostPage()
        let server = LoopbackHTTPServer { request, boundary in
            page.reply(request, boundary: boundary)
        }
        let port = try server.start()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(port)"
        let pageReply = try await request(origin + "/", method: "GET", origin: nil)
        XCTAssertEqual(pageReply.0, 200)
        XCTAssertTrue(String(decoding: pageReply.1, as: UTF8.self).contains("Connect this pane"))
        let script = try await request(origin + "/sender.js", method: "GET", origin: nil)
        XCTAssertEqual(script.0, 200)
        let unavailable = try await request(origin + "/api/pair", method: "POST", origin: origin)
        XCTAssertEqual(unavailable.0, 503)
        let forbidden = try await request(origin + "/api/pair", method: "POST", origin: nil)
        XCTAssertEqual(forbidden.0, 403)
        let hidden = try await request(origin + "/api/observe", method: "GET", origin: nil)
        XCTAssertEqual(hidden.0, 403)
    }

    func testRealLoopbackPostBoundaryAndStaticAsset() async throws {
        let server = LoopbackHTTPServer { request, boundary in
            if request.head.path == "/" {
                guard (try? boundary.validateStatic(request.head)) != nil else {
                    return HTTPReply(status: 403, body: Data("{}".utf8))
                }
                return HTTPReply(status: 200, contentType: "text/html; charset=utf-8",
                                 body: Data("<p>Public static page</p>".utf8), staticAsset: true)
            }
            guard (try? boundary.validateAPI(request.head)) != nil else {
                return HTTPReply(status: 403, body: Data("{}".utf8))
            }
            return HTTPReply(status: 200, body: Data("{\"ok\":true}".utf8))
        }
        let port = try server.start()
        defer { server.stop() }
        XCTAssertNotEqual(port, 0)
        let origin = "http://127.0.0.1:\(port)"
        let staticReply = try await request(origin + "/", method: "GET", origin: nil)
        XCTAssertEqual(staticReply.0, 200)
        XCTAssertEqual(String(data: staticReply.1, encoding: .utf8), "<p>Public static page</p>")
        let valid = try await request(origin + "/api/inspect", method: "POST", origin: origin)
        XCTAssertEqual(valid.0, 200)
        XCTAssertEqual(String(data: valid.1, encoding: .utf8), "{\"ok\":true}")
        let missing = try await request(origin + "/api/inspect", method: "POST", origin: nil)
        let null = try await request(origin + "/api/inspect", method: "POST", origin: "null")
        let foreign = try await request(origin + "/api/inspect", method: "POST",
                                        origin: "http://localhost:\(port)")
        let get = try await request(origin + "/api/inspect", method: "GET", origin: nil)
        XCTAssertEqual(missing.0, 403)
        XCTAssertEqual(null.0, 403)
        XCTAssertEqual(foreign.0, 403)
        XCTAssertEqual(get.0, 403)
    }

    private func request(_ address: String, method: String, origin: String?,
                         body: String = "{}", bearer: String? = nil) async throws -> (Int, Data) {
        var input = URLRequest(url: try XCTUnwrap(URL(string: address)))
        input.httpMethod = method
        input.timeoutInterval = 4
        if let origin { input.setValue(origin, forHTTPHeaderField: "Origin") }
        if let bearer { input.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if method == "POST" {
            input.setValue("application/json", forHTTPHeaderField: "Content-Type")
            input.httpBody = Data(body.utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: input)
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, data)
    }
}
