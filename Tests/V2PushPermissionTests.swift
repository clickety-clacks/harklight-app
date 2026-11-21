import AttentionDomain
import Foundation
import HarklightNativeRelay
import Security
import UserNotifications
import XCTest
@testable import Harklight

final class V2PushPermissionTests: XCTestCase {
    @MainActor
    func testPermissionBlocksSavedPUTAndDisablesRoutingUntilRemovalAndRegistration() async throws {
        let service = "v2-push-permission-test-" + UUID().uuidString
        let enrollment = NativeEnrollmentStore(service: service)
        let record = NativeEnrollmentRecord(host: "relay.example", enrollmentPort: 18444, relayPort: 18443,
            trustedRootDER: Data([1]), identityLabel: "test", deviceID: "device",
            approvalCode: "TEST", statusSecret: "test", expiresAt: nil, statusExpiresAt: nil, personID: "person")
        let keychainKey: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: service,
                                         kSecAttrAccount as String: "current-installation"]
        defer {
            try? enrollment.clearV2APNsToken()
            SecItemDelete(keychainKey as CFDictionary)
        }
        var entry = keychainKey
        entry[kSecValueData as String] = try JSONEncoder().encode(record)
        XCTAssertEqual(SecItemAdd(entry as CFDictionary, nil), errSecSuccess)
        try enrollment.storeV2APNsToken(Data(repeating: 0x2a, count: 32))
        let token = ExactText(try XCTUnwrap(enrollment.v2APNsAddress()))
        let environment: APIPushEnvironment = PushRegistrationProfile.current == .sandbox ? .sandbox : .production
        let saved = try XCTUnwrap(enrollment.updateV2PushRegistration(for: record) {
            try $0.prepareRegistration(token: token, environment: environment)
        })
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText(record.profileAuthority),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = V2PermissionTransport()
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
                                                    directory: nil, errors: NoopErrorLog(), foregroundOnlyWrites: true)
        var permission = UNAuthorizationStatus.notDetermined
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lifecycle = NativeRelayLifecycle(clientAPIV2Enabled: true,
            v2NotificationPermission: NativeNotificationPermission(status: { permission },
                                                                   request: { false }, register: {}),
            enrollment: enrollment, v2LegacyAddressStore: { DevelopmentAPNsAddressStore(directory: folder) })
        lifecycle.installV2Connection(connection, context: context)
        lifecycle.sceneActivityChanged(isActive: true)
        _ = await lifecycle.refreshAfterPushAddressStored()
        let whileUndetermined = await transport.writes
        XCTAssertTrue(whileUndetermined.isEmpty)

        permission = .authorized
        _ = await lifecycle.refreshAfterPushAddressStored()
        let firstBinding = try XCTUnwrap(connection.model.snapshot.routablePushBindingID)
        let registered = await transport.writes
        XCTAssertEqual(registered.map(\.idempotencyKey), [saved.operationID])

        permission = .denied
        _ = await lifecycle.refreshAfterPushAddressStored()
        XCTAssertNil(connection.model.snapshot.routablePushBindingID, "Routing stops even before DELETE succeeds.")
        XCTAssertEqual(connection.model.snapshot.settings?.push?.bindingID, firstBinding)
        let firstRemoval = try XCTUnwrap(enrollment.load()?.v2PushRegistration?.permissionRemovalID)
        _ = await lifecycle.refreshAfterPushAddressStored()
        XCTAssertNil(connection.model.snapshot.settings?.push?.bindingID)
        let removed = await transport.writes
        XCTAssertEqual(removed.map(\.method), [.put, .delete, .delete])
        XCTAssertEqual(removed.dropFirst().map(\.idempotencyKey), [firstRemoval, firstRemoval])

        permission = .authorized
        _ = await lifecycle.refreshAfterPushAddressStored()
        XCTAssertNotEqual(try XCTUnwrap(connection.model.snapshot.routablePushBindingID), firstBinding)
        let final = await transport.writes
        XCTAssertEqual(final.map(\.method), [.put, .delete, .delete, .put])
        XCTAssertNotEqual(final.last?.idempotencyKey, saved.operationID)
        await lifecycle.deactivate()
    }
}

private actor V2PermissionTransport: ClientAPITransport {
    private(set) var writes: [APIRequest] = []
    private var revision = 0
    private var environment: String?
    private var failFirstDelete = true

    func send(_ request: APIRequest) async throws -> APIResponse {
        if request.path == "/v2/me" {
            return reply(#"{"account":{"state":"active"},"features":{},"limits":{},"server":{"id":"server"},"principal":{"person_id":"person","device_id":"device"}}"#)
        }
        if request.path == "/v2/inbox" { return reply(#"{"rev":0,"items":[],"counts":{"unresolved":0}}"#) }
        if request.path == "/v2/devices/me/push" {
            writes.append(request)
            if request.method == .delete {
                if failFirstDelete {
                    failFirstDelete = false
                    throw URLError(.networkConnectionLost)
                }
                revision += 1
                environment = nil
            } else {
                let body = try JSONValue.parse(XCTUnwrap(request.body))
                revision = try XCTUnwrap(body.uniqueValue(named: "revision")?.integerValue)
                environment = body.uniqueValue(named: "environment")?.stringValue?.rawValue
            }
        }
        let push = environment.map { #"{"state":"ready","revision":\#(revision),"environment":"\#($0)","binding_id":"binding-\#(revision)"}"# }
            ?? #"{"state":"canceled","revision":\#(revision)}"#
        return reply(#"{"rev":\#(revision),"settings":{"rev":\#(revision),"priority_levels":[],"push":\#(push)}}"#)
    }

    private func reply(_ body: String) -> APIResponse {
        APIResponse(status: 200, requestID: "test", body: Data(body.utf8))
    }

    nonisolated func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { $0.yield(.opened(requestID: "test")) }
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        FeedBatch(changes: [], rev: after, more: false)
    }
}
