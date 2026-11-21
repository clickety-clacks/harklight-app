import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

final class ClientAPIPushTests: XCTestCase {
    func testSavedRegistrationReplaysAndOnlyARefusalReplacesItsKeyAndRevision() throws {
        let token = ExactText(String(repeating: "a", count: 64))
        var state = ClientAPIPushRegistrationState()
        let original = try XCTUnwrap(state.prepareRegistration(token: token, environment: .sandbox))
        state = try JSONDecoder().decode(ClientAPIPushRegistrationState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try state.prepareRegistration(token: token, environment: .sandbox), original)

        let corrected = try XCTUnwrap(state.replaceStaleRegistration(original, serverRevision: 12))
        XCTAssertEqual(corrected.revision, 13)
        XCTAssertNotEqual(corrected.operationID, original.operationID)
        XCTAssertEqual(corrected.token, token)
        XCTAssertEqual(corrected.environment, .sandbox)
        state.confirmRegistration(original)
        XCTAssertEqual(try state.prepareRegistration(token: token, environment: .sandbox), corrected)
        state.confirmRegistration(corrected)
        XCTAssertNil(try state.prepareRegistration(token: token, environment: .sandbox))
        let production = try XCTUnwrap(state.prepareRegistration(token: token, environment: .production))
        XCTAssertEqual(production.revision, 14)
    }

    func testSavedRemovalBlocksRegistrationUntilTheAccountIsKept() throws {
        let token = ExactText(String(repeating: "a", count: 64))
        var state = ClientAPIPushRegistrationState()
        let original = try XCTUnwrap(state.prepareRegistration(token: token, environment: .production))
        let removal = try XCTUnwrap(state.prepareRemoval())
        state = try JSONDecoder().decode(ClientAPIPushRegistrationState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.prepareRemoval(), removal)
        XCTAssertNil(try state.prepareRegistration(token: token, environment: .production))
        XCTAssertNil(try state.replaceStaleRegistration(original, serverRevision: 12))
        state.confirmRemoval(UUID(), serverRevision: 100)
        XCTAssertEqual(state.prepareRemoval(), removal)
        state.confirmRemoval(removal, serverRevision: 12)
        XCTAssertNil(state.prepareRemoval())
        XCTAssertNil(try state.prepareRegistration(token: token, environment: .production))

        state.keepAccount()
        let replacement = try XCTUnwrap(state.prepareRegistration(token: token, environment: .production))
        XCTAssertEqual(replacement.revision, 13)
        XCTAssertNotEqual(replacement.operationID, original.operationID)
    }

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

    func testOnlyThePersistedAuthenticatedAuthorityCanUseTheCursorGate() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = PushSettingsTransport()
        let errors = RecordingErrorLogV2()
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository,
            context: context, directory: directory, errors: errors, foregroundOnlyWrites: true)
        try connection.model.rebaseline(items: [], counts: APICounts(unresolved: 0), position: 3)
        try await connection.refreshMe()
        let configured = try await connection.push.status()
        let old = try XCTUnwrap(configured.bindingID)

        let reopened = try ClientAPIv2Connection(transport: transport, repository: repository,
            context: context, directory: directory, errors: errors, foregroundOnlyWrites: true)
        let baseRequests = await transport.requests.count
        for mismatch in [
            payload(server: "other-server", binding: old),
            payload(person: "other-person", binding: old),
            payload(device: "other-device", binding: old),
            payload(binding: ExactText("old-binding"))
        ] {
            let changed = try await reopened.catchUp(forPush: mismatch)
            XCTAssertFalse(changed)
        }
        let batchesAfterMismatches = await transport.batches
        let requestsAfterMismatches = await transport.requests.count
        XCTAssertTrue(batchesAfterMismatches.isEmpty)
        XCTAssertEqual(requestsAfterMismatches, baseRequests)
        XCTAssertEqual(reopened.model.persistedCursor(), 3)
        let unmatched = errors.reports.filter { $0.operation == "push_wake" }
        XCTAssertEqual(unmatched.count, 4)
        XCTAssertTrue(unmatched.allSatisfy {
            $0.reason == .app("push_identity_mismatch") && $0.correlation.resourceID == "device"
        })

        _ = try await reopened.catchUp(forPush: payload(binding: old, revision: 3))
        let covered = await transport.batches
        XCTAssertTrue(covered.isEmpty)
        _ = try await reopened.push.remove(idempotencyKey: UUID())
        _ = try await reopened.catchUp(forPush: payload(binding: old))
        let afterDelete = await transport.batches
        XCTAssertTrue(afterDelete.isEmpty)
        XCTAssertNil(reopened.model.snapshot.settings?.push?.bindingID)

        let new = try await reopened.push.register(token: ExactText(String(repeating: "b", count: 64)),
            environment: .sandbox, revision: 6, idempotencyKey: UUID())
        let binding = try XCTUnwrap(new.bindingID)
        XCTAssertNotEqual(binding, old)
        _ = try await reopened.catchUp(forPush: payload(binding: old))
        _ = try await reopened.catchUp(forPush: payload(binding: binding))
        let from = await transport.batches
        XCTAssertEqual(from, [3])
        XCTAssertEqual(reopened.model.persistedCursor(), 3, "Push revision is never taken as the cursor.")
        XCTAssertEqual(errors.reports.filter { $0.operation == "push_wake" }.count, 6)
    }

    private func payload(server: String = "server", person: String = "person", device: String = "device",
                         binding: ExactText, revision: UInt64 = 10) -> JSONValue {
        let locator = JSONValue.object([
            JSONMember("v", .number(JSONNumber(lexeme: "2"))),
            JSONMember("person_id", .string(ExactText(person))),
            JSONMember("device_id", .string(ExactText(device))),
            JSONMember("binding_id", .string(binding)),
            JSONMember("item_id", .string(ExactText("item"))),
            JSONMember("rev", .number(JSONNumber(lexeme: String(revision))))
        ])
        return .object([JSONMember("attention", .object([
            JSONMember("v", .number(JSONNumber(lexeme: "2"))),
            JSONMember("type", .string(ExactText("sync"))),
            JSONMember("server", .string(ExactText(server))),
            JSONMember("locator", locator)
        ]))])
    }
}

private actor PushSettingsTransport: ClientAPITransport {
    private(set) var requests: [APIRequest] = []
    private(set) var batches: [Rev] = []
    private var revision = 4
    private var environment: String? = "production"

    func send(_ request: APIRequest) async throws -> APIResponse {
        requests.append(request)
        switch (request.method, request.path) {
        case (.get, "/v2/me"):
            let body = #"{"account":{"state":"active"},"features":{},"limits":{},"server":{"id":"server"},"principal":{"person_id":"person","device_id":"device"}}"#
            return APIResponse(status: 200, requestID: "me", body: Data(body.utf8))
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
        let push = environment.map { #"{"state":"ready","revision":\#(revision),"environment":"\#($0)","binding_id":"binding-\#(revision)"}"# }
            ?? #"{"state":"canceled","revision":\#(revision)}"#
        let body = #"{"rev":\#(revision),"settings":{"rev":\#(revision),"priority_levels":[],"push":\#(push)}}"#
        return APIResponse(status: 200, requestID: "push", body: Data(body.utf8))
    }

    nonisolated func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        batches.append(after)
        return FeedBatch(changes: [], rev: after, more: false)
    }
}
