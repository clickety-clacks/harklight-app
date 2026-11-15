import AttentionDomain
import Foundation
@testable import Harklight
import HarklightNativeRelay
import Observation
import XCTest

private final class FlagErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class FlagRelaySession: AuthenticatedInboxPagingSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    let frame: Data

    init(context: ProfileContext, frame: String) {
        authenticatedIdentity = context.identity
        self.frame = Data(frame.utf8)
    }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        try await consume(frame)
    }
    func acknowledge(_ request: Data) async throws {}
    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        .unresolved
    }
}

@MainActor
final class RemoteFeatureFlagsTests: XCTestCase {
    private let off = RemoteFeatureFlag(name: "test_off", defaultValue: false)
    private let on = RemoteFeatureFlag(name: "test_on", defaultValue: true)

    private func context(_ authority: String = "relay.example") -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText(authority),
            personID: ExactText("test-person"), deviceID: ExactText("test-device")),
            transportMode: .relay)
    }

    private func snapshot(_ field: String?) throws -> RemoteFeatureFlagSnapshot {
        let member = field.map { ",\"feature_flags\":\($0)" } ?? ""
        return try RelayWire(profile: context()).decodeFeatureFlags(
            Data("{\"v\":1,\"type\":\"resynced\",\"seq\":0\(member)}".utf8))
    }

    func testPresentBooleansOverrideBothDefaultsAndUnknownNamesAreHarmless() throws {
        let flags = RemoteFeatureFlags()
        let id = UUID()
        flags.connect(context: context(), connectionID: id)
        flags.replace(try snapshot(#"{"test_off":true,"test_on":false,"future_flag":true}"#), connectionID: id)
        XCTAssertTrue(flags.isEnabled(off))
        XCTAssertFalse(flags.isEnabled(on))
    }

    func testAbsentNullAndEmptyReplacePriorValuesWithDefaults() throws {
        for field in [nil, "null", "{}"] as [String?] {
            let flags = RemoteFeatureFlags()
            let id = UUID()
            flags.connect(context: context(), connectionID: id)
            flags.replace(try snapshot(#"{"test_off":true,"test_on":false}"#), connectionID: id)
            flags.replace(try snapshot(field), connectionID: id)
            XCTAssertFalse(flags.isEnabled(off))
            XCTAssertTrue(flags.isEnabled(on))
        }
    }

    func testNonObjectLogsErrorAndUsesDefaults() throws {
        for field in ["[]", "true", "1", #""bad""#] {
            let errors = FlagErrorCounter()
            let flags = RemoteFeatureFlags(reportError: { errors.record() })
            let id = UUID()
            flags.connect(context: context(), connectionID: id)
            flags.replace(try snapshot(#"{"test_off":true,"test_on":false}"#), connectionID: id)
            flags.replace(try snapshot(field), connectionID: id)
            XCTAssertFalse(flags.isEnabled(off))
            XCTAssertTrue(flags.isEnabled(on))
            XCTAssertEqual(errors.value, 1)
        }
    }

    func testMalformedEntryUsesItsDefaultAndRetainsValidSibling() throws {
        for bad in ["1", "0", "null", "[]", "{}", #""true""#] {
            let errors = FlagErrorCounter()
            let flags = RemoteFeatureFlags(reportError: { errors.record() })
            let id = UUID()
            flags.connect(context: context(), connectionID: id)
            flags.replace(try snapshot("{\"test_off\":true,\"test_on\":\(bad)}"), connectionID: id)
            XCTAssertTrue(flags.isEnabled(off))
            XCTAssertTrue(flags.isEnabled(on))
            XCTAssertEqual(errors.value, 1)
        }
    }

    func testServerSwitchAndDepartureClearCacheAndRejectPriorConnection() throws {
        let flags = RemoteFeatureFlags()
        let first = UUID(), second = UUID()
        flags.connect(context: context(), connectionID: first)
        flags.replace(try snapshot(#"{"test_off":true}"#), connectionID: first)
        flags.connect(context: context("other.example"), connectionID: second)
        XCTAssertFalse(flags.isEnabled(off))
        flags.replace(try snapshot(#"{"test_off":true}"#), connectionID: first)
        XCTAssertFalse(flags.isEnabled(off))
        flags.replace(try snapshot(#"{"test_off":true}"#), connectionID: second)
        flags.reset()
        flags.replace(try snapshot(#"{"test_off":true}"#), connectionID: second)
        XCTAssertFalse(flags.isEnabled(off))
    }

    func testAcceptedReplayChangesFlagsBetweenConnectionsWithoutRelaunch() async throws {
        let flags = RemoteFeatureFlags()
        let ctx = context()
        let repository = try ClientRepository(context: ctx, persistence: MemoryPendingActionPersistence())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for enabled in [true, false] {
            let id = UUID()
            flags.connect(context: ctx, connectionID: id)
            let session = FlagRelaySession(context: ctx,
                frame: "{\"v\":1,\"type\":\"resynced\",\"seq\":0,\"feature_flags\":{\"test_off\":\(enabled)}}")
            let core = try NativeRelayCore(store: repository, context: ctx, session: session,
                serverStateCache: FileServerStateCache(identity: ctx.identity,
                    fileURL: root.appendingPathComponent("cache.json")),
                onFeatureFlags: { snapshot in
                    await flags.replace(snapshot, connectionID: id)
                })
            _ = try await core.resyncAndDrainOutbox()
            XCTAssertEqual(flags.isEnabled(off), enabled)
            await core.deactivate()
        }
    }

    func testReconnectKeepsCacheUntilSnapshotThenReplacesRatherThanMerges() throws {
        let flags = RemoteFeatureFlags()
        let first = UUID(), second = UUID()
        flags.connect(context: context(), connectionID: first)
        flags.replace(try snapshot(#"{"test_off":true,"test_on":false}"#), connectionID: first)
        flags.connect(context: context(), connectionID: second)
        XCTAssertTrue(flags.isEnabled(off))
        flags.replace(try snapshot(#"{"test_on":true}"#), connectionID: second)
        flags.replace(try snapshot(#"{"test_off":true,"test_on":false}"#), connectionID: first)
        XCTAssertFalse(flags.isEnabled(off))
        XCTAssertTrue(flags.isEnabled(on))
    }

    func testRejectedReplayCannotChangeFlags() async throws {
        let flags = RemoteFeatureFlags()
        let ctx = context(), id = UUID()
        flags.connect(context: ctx, connectionID: id)
        let repository = try ClientRepository(context: ctx, persistence: MemoryPendingActionPersistence())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = FlagRelaySession(context: ctx,
            frame: #"{"v":1,"type":"resynced","seq":1,"feature_flags":{"test_off":true}}"#)
        let core = try NativeRelayCore(store: repository, context: ctx, session: session,
            serverStateCache: FileServerStateCache(identity: ctx.identity,
                fileURL: root.appendingPathComponent("cache.json")),
            onFeatureFlags: { snapshot in await flags.replace(snapshot, connectionID: id) })
        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("Invalid replay must be refused")
        } catch {
            XCTAssertFalse(flags.isEnabled(off))
        }
        await core.deactivate()
    }

    func testAccessorIsObservedForLiveUIUpdates() throws {
        let flags = RemoteFeatureFlags()
        let id = UUID()
        let changes = FlagErrorCounter()
        flags.connect(context: context(), connectionID: id)
        withObservationTracking {
            _ = flags.isEnabled(off)
        } onChange: { changes.record() }
        flags.replace(try snapshot(#"{"test_off":true}"#), connectionID: id)
        XCTAssertEqual(changes.value, 1)
        XCTAssertTrue(flags.isEnabled(off))
    }
}
