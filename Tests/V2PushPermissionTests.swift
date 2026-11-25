import AttentionDomain
import Foundation
import HarklightNativeRelay
import Security
import UserNotifications
import XCTest
@testable import Harklight

final class V2PushPermissionTests: XCTestCase {
    @MainActor
    func testV2RegistrationStoresTheCurrentTokenAndClearsItIfEmpty() throws {
        let enrollment = NativeEnrollmentStore(service: "push-token-test-" + UUID().uuidString)
        defer { try? enrollment.clearV2APNsToken() }

        try enrollment.storeV2APNsToken(Data(repeating: 0x2a, count: 32))
        XCTAssertEqual(try enrollment.v2APNsAddress(), String(repeating: "2a", count: 32))

        XCTAssertThrowsError(try enrollment.storeV2APNsToken(Data()))
        XCTAssertNil(try enrollment.v2APNsAddress())
    }

    private func saveEnrollment() throws
        -> (NativeEnrollmentStore, NativeEnrollmentRecord, () -> Void) {
        let service = "v2-push-permission-test-" + UUID().uuidString
        let enrollment = NativeEnrollmentStore(service: service)
        let record = NativeEnrollmentRecord(host: "relay.example", enrollmentPort: 18444, relayPort: 18443,
            trustedRootDER: Data([1]), identityLabel: "test", deviceID: "device",
            approvalCode: "TEST", statusSecret: "test", expiresAt: nil, statusExpiresAt: nil, personID: "person")
        let keychainKey: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: service,
                                         kSecAttrAccount as String: "current-installation"]
        let cleanup: () -> Void = {
            try? enrollment.clearV2APNsToken()
            _ = SecItemDelete(keychainKey as CFDictionary)
        }
        var entry = keychainKey
        entry[kSecValueData as String] = try JSONEncoder().encode(record)
        XCTAssertEqual(SecItemAdd(entry as CFDictionary, nil), errSecSuccess)
        return (enrollment, record, cleanup)
    }

    @MainActor
    func testFirstDeniedForegroundLooksUpAndRemovesAnUncachedBinding() async throws {
        let (enrollment, record, cleanup) = try saveEnrollment()
        defer { cleanup() }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText(record.profileAuthority),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = V2PermissionTransport(hasServerBinding: true, holdFirstDelete: true)
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository, context: context,
                                                    directory: nil, errors: NoopErrorLog(), foregroundOnlyWrites: true)
        // Keep the initial inbox baseline from superseding the settings read.
        // The push settings and the registration journal are still both empty.
        try connection.model.rebaseline(items: [], counts: APICounts(unresolved: 0), position: 0)
        let lifecycle = NativeRelayLifecycle(
            v2NotificationPermission: NativeNotificationPermission(status: { .denied },
                                                                   request: { false }, register: {}),
            enrollment: enrollment)
        XCTAssertNil(connection.model.snapshot.settings)
        XCTAssertNil(try enrollment.load()?.v2PushRegistration)
        lifecycle.installV2Connection(connection, context: context)
        lifecycle.sceneActivityChanged(isActive: true)
        let firstPass = Task { await lifecycle.refreshAfterPushAddressStored() }
        let firstDeleteStarted = await transport.waitForFirstDelete()
        XCTAssertTrue(firstDeleteStarted, "The denied first foreground must look up and remove the server binding.")
        let persistedRemoval = Result { try enrollment.load()?.v2PushRegistration?.permissionRemovalID }
        let firstDeleteKey = await transport.writes.first(where: { $0.method == .delete })?.idempotencyKey
        XCTAssertNotNil(connection.model.snapshot.settings?.push?.bindingID)
        XCTAssertNil(connection.model.snapshot.routablePushBindingID)
        await transport.releaseFirstDelete()
        _ = await firstPass.value
        _ = await lifecycle.refreshAfterPushAddressStored()
        let readCount = await transport.settingsReads
        let writes = await transport.writes
        await lifecycle.deactivate()
        let savedRemoval = try XCTUnwrap(persistedRemoval.get(),
                                         "The removal key must be durably saved while the first DELETE is held.")
        XCTAssertEqual(firstDeleteKey, savedRemoval)
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(writes.map(\.method), [.delete, .delete])
        XCTAssertEqual(writes.map(\.idempotencyKey), [savedRemoval, savedRemoval])
        XCTAssertNil(connection.model.snapshot.settings?.push?.bindingID)
        XCTAssertNil(try enrollment.load()?.v2PushRegistration?.permissionRemovalID)
    }

    @MainActor
    func testPermissionBlocksSavedPUTAndDisablesRoutingUntilRemovalAndRegistration() async throws {
        let (enrollment, record, cleanup) = try saveEnrollment()
        defer { cleanup() }
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
        let lifecycle = NativeRelayLifecycle(
            v2NotificationPermission: NativeNotificationPermission(status: { permission },
                                                                   request: { false }, register: {}),
            enrollment: enrollment)
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
    private(set) var settingsReads = 0
    private var revision: Int
    private var environment: String?
    private var failFirstDelete = true
    private var holdFirstDelete: Bool
    private var firstDeleteRelease: CheckedContinuation<Void, Never>?

    init(hasServerBinding: Bool = false, holdFirstDelete: Bool = false) {
        revision = hasServerBinding ? 7 : 0
        self.holdFirstDelete = holdFirstDelete
        environment = hasServerBinding ? "sandbox" : nil
    }

    func send(_ request: APIRequest) async throws -> APIResponse {
        if request.path == "/v2/me" {
            return reply(#"{"account":{"state":"active"},"features":{},"limits":{},"server":{"id":"server"},"principal":{"person_id":"person","device_id":"device"}}"#)
        }
        if request.path == "/v2/inbox" { return reply(#"{"rev":0,"items":[],"counts":{"unresolved":0}}"#) }
        if request.path == "/v2/settings" { settingsReads += 1 }
        if request.path == "/v2/devices/me/push" {
            writes.append(request)
            if request.method == .delete {
                if failFirstDelete {
                    failFirstDelete = false
                    if holdFirstDelete {
                        await withCheckedContinuation { firstDeleteRelease = $0 }
                    }
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

    func waitForFirstDelete() async -> Bool {
        for _ in 0..<200 {
            if writes.contains(where: { $0.method == .delete }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func releaseFirstDelete() {
        holdFirstDelete = false
        firstDeleteRelease?.resume()
        firstDeleteRelease = nil
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
