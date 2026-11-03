import AttentionDomain
import Foundation
import XCTest
@testable import Harklight

@MainActor
final class NativeNotificationRoutingTests: XCTestCase {
    private let defaultsSuiteName = "Harklight.notification-routing.\(UUID().uuidString)"

    func testForegroundChatAlertStaysTransientUntilIndicatorIsTapped() throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let router = NativeNotificationRouter(defaults: defaults)
        let payload = try notificationPayload(target: "chat")
        let key = RequestKey(accountScope: ExactText("person"), senderID: ExactText("agent"),
                             messageID: ExactText("request"))

        XCTAssertTrue(router.receiveForegroundNotification(
            payload, title: "Agent reply", body: "A new response is ready."))

        let indicator = try XCTUnwrap(router.foregroundChatIndicator)
        XCTAssertEqual(indicator.request, key)
        XCTAssertEqual(indicator.title, "Agent reply")
        XCTAssertEqual(indicator.body, "A new response is ready.")
        XCTAssertNil(router.intent, "A foreground receipt is not an opened notification route.")
        XCTAssertNil(defaults.data(forKey: "harklight.notification.navigation"),
                      "The indicator stays transient until tapped.")

        let tapped = try XCTUnwrap(router.consumeForegroundChatIndicator(id: indicator.id))
        router.receive(tapped.payload, opened: true)
        XCTAssertEqual(router.intent?.locator?.request, key)
        XCTAssertEqual(router.intent?.locator?.target, "chat")
    }

    func testMatchingVisibleChatSuppressesIndicatorAndAnotherChatDoesNot() throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let router = NativeNotificationRouter(defaults: defaults)
        let payload = try notificationPayload(target: "chat")
        let key = RequestKey(accountScope: ExactText("person"), senderID: ExactText("agent"),
                             messageID: ExactText("request"))
        let otherKey = RequestKey(accountScope: ExactText("person"), senderID: ExactText("agent"),
                                  messageID: ExactText("other-request"))

        router.conversationBecameVisible(otherKey)
        XCTAssertTrue(router.receiveForegroundNotification(payload, title: "Agent reply", body: "Reply"))
        XCTAssertEqual(router.foregroundChatIndicator?.request, key,
                       "A different visible chat still gets a tappable indicator.")

        router.conversationBecameVisible(key)
        XCTAssertNil(router.foregroundChatIndicator,
                     "Opening the matching chat clears its pending indicator.")
        XCTAssertTrue(router.receiveForegroundNotification(payload, title: "Agent reply", body: "Reply"))
        XCTAssertNil(router.foregroundChatIndicator,
                     "A reply in the matching visible chat needs no separate indicator.")
    }

    func testLegacyRequestAndUnknownTargetsKeepTheRequestRoute() throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let router = NativeNotificationRouter(defaults: defaults)
        let legacy = try notificationPayload(target: nil)
        let unknown = try notificationPayload(target: "future-target")

        XCTAssertFalse(router.receiveForegroundNotification(legacy, title: "Request", body: "Open"))
        XCTAssertFalse(router.receiveForegroundNotification(unknown, title: "Request", body: "Open"))
        XCTAssertNil(router.foregroundChatIndicator)

        router.receive(legacy, opened: true)
        XCTAssertNil(router.intent?.locator?.target,
                     "A missing target remains the existing ordinary request notification route.")
    }

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
    }

    private func notificationPayload(target: String?) throws -> JSONValue {
        var locator: [String: Any] = [
            "v": 1,
            "binding_id": "11111111-2222-3333-4444-555555555555",
            "person_id": "person",
            "device_id": "device",
            "sender_id": "agent",
            "message_id": "request",
            "acceptance_seq": 1
        ]
        if let target { locator["target"] = target }
        let object: [String: Any] = [
            "attention": ["v": 1, "type": "sync", "locator": locator]
        ]
        return try JSONValue.parse(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}
