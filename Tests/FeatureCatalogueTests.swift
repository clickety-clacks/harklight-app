import AttentionDomain
import HarklightNativeRelay
import Observation
import XCTest
@testable import Harklight

@MainActor
final class FeatureCatalogueTests: XCTestCase {
    private func context() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("catalogue-person"), deviceID: ExactText("catalogue-device")),
            transportMode: .relay)
    }

    private func snapshot(_ text: String?) throws -> RemoteFeatureFlagSnapshot {
        RemoteFeatureFlagSnapshot(field: try text.map { try JSONValue.parse(Data($0.utf8)) })
    }

    func testCatalogueIncludesAllRegisteredFeaturesWithDistinctMaturityAndLimits() {
        XCTAssertEqual(Set(AppFeature.allCases.map { $0.flag.name }),
            ["progress_inbox", "server_matched_push_routing", "priority_level_editing"])
        XCTAssertEqual(AppFeature.progressMessages.maturity, .beta)
        XCTAssertEqual(AppFeature.accountAwareNotifications.maturity, .alpha)
        XCTAssertEqual(AppFeature.priorityLevels.maturity, .alpha)
        XCTAssertTrue(FeatureMaturity.alpha.explanation.contains("may or may not work"))
        for feature in AppFeature.allCases {
            XCTAssertFalse(feature.description.isEmpty)
            XCTAssertFalse(feature.limitation.isEmpty)
            XCTAssertFalse(feature.requirements.isEmpty)
        }
    }

    func testWelcomeUsesAppDefaultsWithoutClaimingServerOrAccountAccess() {
        for feature in AppFeature.allCases {
            let setting = FeatureFlagEvaluation.appDefault(for: feature)
            XCTAssertEqual(setting.isEnabled, feature.flag.defaultValue)
            XCTAssertEqual(setting.freshness, .appDefaultsOnly)
            XCTAssertNil(FeatureCatalogueAvailability.evaluate(feature, setting: setting,
                access: FeatureCatalogueAccess()).route)
        }
    }

    func testEnrolledStoreWithoutFlagContextAsksToConnectInsteadOfJoinAgain() throws {
        let ctx = context()
        let repository = try ClientRepository(context: ctx, persistence: MemoryPendingActionPersistence())
        let flags = RemoteFeatureFlags()
        let store = try LivePresentationStore(store: repository, context: ctx, featureFlags: flags)
        let catalogue = FeatureCatalogueView(store: store, flags: flags)
        // Activation resets flags before transport is established. A failed
        // connection must not make a cached enrolled account look unenrolled.
        for feature in AppFeature.allCases {
            let setting = flags.evaluation(for: feature, expected: ctx)
            XCTAssertEqual(setting.freshness, .appDefaultsOnly)
            let access = catalogue.access(for: setting)
            XCTAssertTrue(access.hasCurrentAccount)
            XCTAssertTrue(setting.settingExplanation(hasCurrentAccount: access.hasCurrentAccount)
                .contains("Connect this account"))
            let availability = FeatureCatalogueAvailability.evaluate(feature, setting: setting, access: access)
            XCTAssertFalse(availability.explanation.contains("Join"))
            XCTAssertNil(availability.route)
        }
        let welcome = FeatureCatalogueView(flags: flags)
        XCTAssertFalse(welcome.access(for: .appDefault(for: .progressMessages)).hasCurrentAccount)
        XCTAssertFalse(FeatureFlagEvaluation.appDefault(for: .progressMessages)
            .settingExplanation(hasCurrentAccount: false).contains("this account"))
    }

    func testCurrentAndRetainedSettingsHaveDifferentProvenanceWithoutChangingResolution() throws {
        let flags = RemoteFeatureFlags(), ctx = context(), first = UUID(), second = UUID()
        flags.connect(context: ctx, connectionID: first)
        XCTAssertEqual(flags.evaluation(for: .progressMessages, expected: ctx).freshness, .awaitingSnapshot)
        flags.replace(try snapshot(#"{"progress_inbox":false}"#), connectionID: first)
        let current = flags.evaluation(for: .progressMessages, expected: ctx)
        XCTAssertEqual(current.source, .server)
        XCTAssertEqual(current.freshness, .latestSnapshot)
        XCTAssertFalse(current.isEnabled)
        flags.connect(context: ctx, connectionID: second)
        let retained = flags.evaluation(for: .progressMessages, expected: ctx)
        XCTAssertEqual(retained.freshness, .awaitingSnapshot)
        XCTAssertTrue(retained.hasPreviousSnapshot)
        XCTAssertFalse(flags.isEnabled(.progressInbox))
        flags.replace(try snapshot(#"{"progress_inbox":true}"#), connectionID: first)
        XCTAssertEqual(flags.evaluation(for: .progressMessages, expected: ctx), retained)
        flags.replace(try snapshot("{}"), connectionID: second)
        XCTAssertEqual(flags.evaluation(for: .progressMessages, expected: ctx).fallbackReason, .missingValue)
        XCTAssertTrue(flags.isEnabled(.progressInbox))
    }

    func testAbsentNullEmptyAndMalformedFallbacksRemainDistinctFromServerValues() throws {
        let flags = RemoteFeatureFlags(reportError: {}), ctx = context(), id = UUID()
        flags.connect(context: ctx, connectionID: id)
        for raw in [nil, "null", "{}"] as [String?] {
            flags.replace(try snapshot(raw), connectionID: id)
            XCTAssertEqual(flags.evaluation(for: .progressMessages, expected: ctx).fallbackReason, .missingValue)
        }
        flags.replace(try snapshot("[]"), connectionID: id)
        XCTAssertEqual(flags.evaluation(for: .progressMessages, expected: ctx).fallbackReason, .malformedObject)
        flags.replace(try snapshot(#"{"progress_inbox":1,"priority_level_editing":true}"#), connectionID: id)
        XCTAssertEqual(flags.evaluation(for: .progressMessages, expected: ctx).fallbackReason, .malformedValue)
        XCTAssertEqual(flags.evaluation(for: .accountAwareNotifications, expected: ctx).fallbackReason, .missingValue)
        XCTAssertEqual(flags.evaluation(for: .priorityLevels, expected: ctx).source, .server)
        XCTAssertTrue(flags.isEnabled(.priorityLevelEditing))
    }

    func testResetProfileChangeAndRecreatedStoreDoNotExposePriorAccountSettings() throws {
        let flags = RemoteFeatureFlags(), ctx = context(), id = UUID(), other = context()
        flags.connect(context: ctx, connectionID: id)
        flags.replace(try snapshot(#"{"priority_level_editing":true}"#), connectionID: id)
        XCTAssertEqual(flags.evaluation(for: .priorityLevels, expected: other), .appDefault(for: .priorityLevels))
        flags.connect(context: other, connectionID: UUID())
        XCTAssertFalse(flags.isEnabled(.priorityLevelEditing))
        XCTAssertFalse(flags.evaluation(for: .priorityLevels, expected: other).hasPreviousSnapshot)
        flags.reset()
        XCTAssertEqual(flags.evaluation(for: .priorityLevels, expected: other), .appDefault(for: .priorityLevels))
        XCTAssertEqual(RemoteFeatureFlags().evaluation(for: .priorityLevels, expected: ctx), .appDefault(for: .priorityLevels))
    }

    func testProvenanceIsObservableWithoutRelaunch() throws {
        let flags = RemoteFeatureFlags(), ctx = context(), id = UUID()
        flags.connect(context: ctx, connectionID: id)
        let changed = expectation(description: "Catalogue observes a server update")
        withObservationTracking {
            _ = flags.evaluation(for: .priorityLevels, expected: ctx)
        } onChange: {
            changed.fulfill()
        }
        flags.replace(try snapshot(#"{"priority_level_editing":true}"#), connectionID: id)
        wait(for: [changed], timeout: 1)
        XCTAssertTrue(flags.evaluation(for: .priorityLevels, expected: ctx).isEnabled)
    }

    func testRoutesRequireFlagAccountDataAndExistingPriorityGuards() {
        let key = RequestKey(accountScope: ExactText("catalogue-person"),
            senderID: ExactText("sender"), messageID: ExactText("progress"))
        var access = FeatureCatalogueAccess(hasCurrentAccount: true, isWritableAccount: true,
            progressMessage: key, priorityRelayConfirmed: true)
        let on = FeatureFlagEvaluation(isEnabled: true, builtInDefault: false, source: .server,
            freshness: .latestSnapshot, fallbackReason: nil, hasPreviousSnapshot: true)
        XCTAssertEqual(FeatureCatalogueAvailability.evaluate(.progressMessages, setting: on, access: access).route,
                       .progressMessage(key))
        XCTAssertEqual(FeatureCatalogueAvailability.evaluate(.priorityLevels, setting: on, access: access).route,
                       .priorityLevels)
        // Notification instructions never manufacture a push or permission action.
        XCTAssertNil(FeatureCatalogueAvailability.evaluate(.accountAwareNotifications, setting: on, access: access).route)
        access.priorityForbidden = true
        XCTAssertNil(FeatureCatalogueAvailability.evaluate(.priorityLevels, setting: on, access: access).route)
        access.priorityForbidden = false
        access.priorityUnsupported = true
        XCTAssertNil(FeatureCatalogueAvailability.evaluate(.priorityLevels, setting: on, access: access).route)
        access.priorityUnsupported = false
        access.priorityRelayConfirmed = false
        XCTAssertNil(FeatureCatalogueAvailability.evaluate(.priorityLevels, setting: on, access: access).route)
        access.priorityRelayConfirmed = true
        access.isWritableAccount = false
        XCTAssertNil(FeatureCatalogueAvailability.evaluate(.priorityLevels, setting: on, access: access).route)
        access.progressMessage = nil
        XCTAssertNil(FeatureCatalogueAvailability.evaluate(.progressMessages, setting: on, access: access).route)
        for feature in [AppFeature.accountAwareNotifications, .priorityLevels] {
            XCTAssertNil(FeatureCatalogueAvailability.evaluate(feature,
                setting: .appDefault(for: feature), access: access).route)
        }
    }
}
