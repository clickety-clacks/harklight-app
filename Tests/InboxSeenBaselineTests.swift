import XCTest
@testable import Harklight
import AttentionDomain

final class InboxSeenBaselineTests: XCTestCase {
    func testBaselineCapturesExactSavedMessagesOnce() {
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = profileIdentity(person: "person-A", device: "device-A")

        let firstRun = InboxSeenBaseline.capture(identity: identity,
                                                 acceptanceOrders: [12, 40, 42],
                                                 defaults: defaults)
        XCTAssertTrue(infoRow(order: 40, baseline: firstRun).belongsToSeenTab)
        XCTAssertTrue(openRequestRow(order: 12, baseline: firstRun).belongsToSeenTab)
        XCTAssertFalse(infoRow(order: 43, baseline: firstRun).belongsToSeenTab)
        XCTAssertFalse(infoRow(order: 11, baseline: firstRun).belongsToSeenTab,
                       "An older acceptance order loaded after the first run was not in the saved snapshot.")

        let laterRun = InboxSeenBaseline.capture(identity: identity,
                                                 acceptanceOrders: [11, 12, 40, 42, 43],
                                                 defaults: defaults)
        XCTAssertTrue(infoRow(order: 40, baseline: laterRun).belongsToSeenTab)
        XCTAssertFalse(infoRow(order: 11, baseline: laterRun).belongsToSeenTab)
        XCTAssertFalse(infoRow(order: 43, baseline: laterRun).belongsToSeenTab)
    }

    func testBaselineIsScopedToTheSavedProfileAndDevice() {
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = profileIdentity(person: "person-A", device: "device-A")

        let baseline = InboxSeenBaseline.capture(identity: identity,
                                                 acceptanceOrders: [8, 11],
                                                 defaults: defaults)
        XCTAssertTrue(infoRow(order: 11, baseline: baseline).belongsToSeenTab)
        XCTAssertTrue(openRequestRow(order: 8, baseline: baseline).belongsToSeenTab)

        let anotherDevice = profileIdentity(person: "person-A", device: "device-B")
        let separateBaseline = InboxSeenBaseline.capture(identity: anotherDevice,
                                                         acceptanceOrders: [11],
                                                         defaults: defaults)
        XCTAssertTrue(infoRow(order: 11, baseline: separateBaseline).belongsToSeenTab)
        XCTAssertFalse(openRequestRow(order: 8, baseline: separateBaseline).belongsToSeenTab)
    }

    private func infoRow(order: UInt64, baseline: InboxSeenBaseline) -> InboxRequestRow {
        InboxRequestRow(key: requestKey("message-\(order)"),
                        title: "Information",
                        sender: "agent",
                        status: "",
                        informationalSeenStatus: .available,
                        canMarkSeen: true,
                        localSeenSelected: baseline.selects(acceptanceOrder: order))
    }

    private func openRequestRow(order: UInt64, baseline: InboxSeenBaseline) -> InboxRequestRow {
        InboxRequestRow(key: requestKey("request-\(order)"),
                        title: "Answer needed",
                        sender: "agent",
                        status: "Open",
                        localSeenSelected: baseline.selects(acceptanceOrder: order))
    }

    private func requestKey(_ messageID: String) -> RequestKey {
        RequestKey(accountScope: ExactText("person-A"),
                   senderID: ExactText("agent"),
                   messageID: ExactText(messageID))
    }

    private func profileIdentity(person: String, device: String) -> ProfileIdentity {
        ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                        personID: ExactText(person),
                        deviceID: ExactText(device))
    }

    private func isolatedDefaults() -> (String, UserDefaults) {
        let suiteName = "InboxSeenBaselineTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
