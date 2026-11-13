import Foundation
import Security
import XCTest
@testable import Harklight

final class BoundedNativeJoinExchangeTests: XCTestCase {
    func testFollowsRedirectAndAcceptsResponseLargerThanFormerLimit() async throws {
        let url = try XCTUnwrap(URL(string: "http://native-join-response.test/redirect"))
        let exchange = BoundedNativeJoinExchange(url: url, rootDER: Data(), identity: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeJoinExchangeTestURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: exchange, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let response = try await exchange.run(session: session, request: URLRequest(url: url))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.data.count, 64 * 1024 + 1)
    }
}

private final class NativeJoinExchangeTestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "native-join-response.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        if url.path == "/redirect" {
            let destination = url.deletingLastPathComponent().appendingPathComponent("final")
            guard let response = HTTPURLResponse(url: url,
                                                 statusCode: 302,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: ["Location": destination.absoluteString,
                                                                "Content-Length": "0"]) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client.urlProtocol(self,
                               wasRedirectedTo: URLRequest(url: destination),
                               redirectResponse: response)
            return
        }

        let body = Data(repeating: 0x61, count: 64 * 1024 + 1)
        guard let response = HTTPURLResponse(url: url,
                                             statusCode: 200,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": String(body.count)]) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
