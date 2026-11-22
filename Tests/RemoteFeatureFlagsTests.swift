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
        try RemoteFeatureFlagSnapshot(field: field.map { try JSONValue.parse(Data($0.utf8)) })
    }

    func testApprovedProductionDefaultsAndRemoteProgressOverride() throws {
        let flags = RemoteFeatureFlags()
        XCTAssertTrue(flags.isEnabled(.progressInbox))
        XCTAssertTrue(flags.isEnabled(.serverMatchedPushRouting))
        XCTAssertFalse(flags.isEnabled(.priorityLevelEditing))
        let id = UUID()
        flags.connect(context: context(), connectionID: id)
        let field = try JSONValue.parse(Data(#"{"progress_inbox":false,"server_matched_push_routing":true,"priority_level_editing":true}"#.utf8))
        flags.replace(RemoteFeatureFlagSnapshot(field: field), connectionID: id)
        XCTAssertFalse(flags.isEnabled(.progressInbox))
        XCTAssertTrue(flags.isEnabled(.serverMatchedPushRouting))
        XCTAssertTrue(flags.isEnabled(.priorityLevelEditing))
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


    func testReconnectKeepsCacheUntilSnapshotThenReplacesRatherThanMerges() throws {
        let flags = RemoteFeatureFlags()
        let first = UUID(), second = UUID()
        let ctx = context()
        flags.connect(context: ctx, connectionID: first)
        flags.replace(try snapshot(#"{"test_off":true,"test_on":false}"#), connectionID: first)
        flags.connect(context: ctx, connectionID: second)
        XCTAssertTrue(flags.isEnabled(off))
        flags.replace(try snapshot(#"{"test_on":true}"#), connectionID: second)
        flags.replace(try snapshot(#"{"test_off":true,"test_on":false}"#), connectionID: first)
        XCTAssertFalse(flags.isEnabled(off))
        XCTAssertTrue(flags.isEnabled(on))
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
