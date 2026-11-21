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
        let payload = JSONValue.null
        let locator = notificationLocator(target: "chat")
        let key = RequestKey(accountScope: ExactText("person"), senderID: ExactText("agent"),
                             messageID: ExactText("request"))

        XCTAssertTrue(router.receiveForegroundNotification(
            payload, locator: locator, title: "Agent reply", body: "A new response is ready."))

        let indicator = try XCTUnwrap(router.foregroundChatIndicator)
        XCTAssertEqual(indicator.request, key)
        XCTAssertEqual(indicator.title, "Agent reply")
        XCTAssertEqual(indicator.body, "A new response is ready.")
        XCTAssertNil(router.intent, "A foreground receipt is not an opened notification route.")
        XCTAssertNil(defaults.data(forKey: "harklight.notification.navigation"),
                      "The indicator stays transient until tapped.")

        let tapped = try XCTUnwrap(router.consumeForegroundChatIndicator(id: indicator.id))
        XCTAssertEqual(tapped.payload, payload)
        router.receive(locator: locator)
        XCTAssertEqual(router.intent?.locator?.request, key)
        XCTAssertEqual(router.intent?.locator?.target, "chat")
    }

    func testMatchingVisibleChatSuppressesIndicatorAndAnotherChatDoesNot() throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let router = NativeNotificationRouter(defaults: defaults)
        let payload = JSONValue.null
        let locator = notificationLocator(target: "chat")
        let key = RequestKey(accountScope: ExactText("person"), senderID: ExactText("agent"),
                             messageID: ExactText("request"))
        let otherKey = RequestKey(accountScope: ExactText("person"), senderID: ExactText("agent"),
                                  messageID: ExactText("other-request"))

        router.conversationBecameVisible(otherKey)
        XCTAssertTrue(router.receiveForegroundNotification(payload, locator: locator, title: "Agent reply", body: "Reply"))
        XCTAssertEqual(router.foregroundChatIndicator?.request, key,
                       "A different visible chat still gets a tappable indicator.")

        router.conversationBecameVisible(key)
        XCTAssertNil(router.foregroundChatIndicator,
                     "Opening the matching chat clears its pending indicator.")
        XCTAssertTrue(router.receiveForegroundNotification(payload, locator: locator, title: "Agent reply", body: "Reply"))
        XCTAssertNil(router.foregroundChatIndicator,
                     "A reply in the matching visible chat needs no separate indicator.")
    }


    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
    }

    private func notificationLocator(target: String?) -> NativeNotificationLocator {
        NativeNotificationLocator(v2Request: RequestKey(accountScope: ExactText("person"), senderID: ExactText("agent"),
            messageID: ExactText("request")), bindingID: ExactText("binding"), deviceID: ExactText("device"),
            serverID: String(repeating: "a", count: 32), target: target)
    }
}
