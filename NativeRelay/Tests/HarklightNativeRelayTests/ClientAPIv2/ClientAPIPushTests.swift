import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

final class ClientAPIPushTests: XCTestCase {
    func testStaleRegistrationKeepsItsRefusalAndRemovalReturnsTheUpdatedSettings() async throws {
        let transport = PushSettingsTransport()
        let push = ClientAPIPush(transport: transport)
        let token = ExactText(String(repeating: "a", count: 64))
        let staleKey = UUID()
        do {
            _ = try await push.register(token: token, environment: .sandbox, revision: 4, idempotencyKey: staleKey)
            XCTFail("The current revision cannot be reused for a different registration.")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 412)
            XCTAssertEqual(error.token, .preconditionFailed)
            XCTAssertEqual(error.requestID, "stale-push")
        }
        let afterRefusal = await transport.requests
        XCTAssertEqual(afterRefusal.map(\.method), [.put], "The transport does not change the saved intent on 412.")

        let current = try await push.status()
        XCTAssertEqual(current.revision, 4)
        XCTAssertEqual(current.environment, .production)
        let registrationKey = UUID()
        let registered = try await push.register(token: token, environment: .sandbox,
            revision: current.revision + 1, idempotencyKey: registrationKey)
        XCTAssertEqual(registered.state, "ready")
        XCTAssertEqual(registered.revision, 5)
        XCTAssertEqual(registered.environment, .sandbox)

        let removalKey = UUID()
        let removed = try await push.remove(idempotencyKey: removalKey)
        XCTAssertEqual(removed.state, "canceled")
        XCTAssertEqual(removed.revision, 6)
        XCTAssertNil(removed.environment)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.path), ["/v2/devices/me/push", "/v2/settings",
                                                "/v2/devices/me/push", "/v2/devices/me/push"])
        XCTAssertEqual(requests.map(\.method), [.put, .get, .put, .delete])
        XCTAssertEqual(requests.map(\.idempotencyKey), [staleKey, nil, registrationKey, removalKey])
        XCTAssertNil(requests.last?.body, "DELETE carries no registration revision or token.")
        let body = try JSONValue.parse(XCTUnwrap(requests[2].body))
        XCTAssertEqual(body.uniqueValue(named: "token")?.stringValue, token)
        XCTAssertEqual(body.uniqueValue(named: "environment")?.stringValue?.rawValue, "sandbox")
        XCTAssertEqual(body.uniqueValue(named: "revision")?.integerValue, 5)
    }
}

private actor PushSettingsTransport: ClientAPITransport {
    private(set) var requests: [APIRequest] = []
    private var revision = 4
    private var environment: String? = "production"

    func send(_ request: APIRequest) async throws -> APIResponse {
        requests.append(request)
        switch (request.method, request.path) {
        case (.get, "/v2/settings"): break
        case (.put, "/v2/devices/me/push"):
            let body = try JSONValue.parse(XCTUnwrap(request.body))
            let upcoming = try XCTUnwrap(body.uniqueValue(named: "revision")?.integerValue)
            guard upcoming > revision else {
                throw APIError(status: 412, token: .preconditionFailed, retryable: false, requestID: "stale-push")
            }
            revision = upcoming
            environment = try XCTUnwrap(body.uniqueValue(named: "environment")?.stringValue?.rawValue)
        case (.delete, "/v2/devices/me/push"):
            revision += 1
            environment = nil
        default:
            throw URLError(.unsupportedURL)
        }
        let push = environment.map { #"{"state":"ready","revision":\#(revision),"environment":"\#($0)"}"# }
            ?? #"{"state":"canceled","revision":\#(revision)}"#
        let body = #"{"rev":20,"settings":{"rev":19,"priority_levels":[],"push":\#(push)}}"#
        return APIResponse(status: 200, requestID: "push", body: Data(body.utf8))
    }

    nonisolated func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        FeedBatch(changes: [], rev: after, more: false)
    }
}
