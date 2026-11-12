import AttentionDomain
import Foundation
import SwiftUI
import XCTest
@testable import Harklight
import HarklightNativeRelay

@MainActor
final class NativeFocusPushCoordinatorTests: XCTestCase {
    func testOnlyLatestPendingShowAppliesAndFirstContentTouchActivatesOnce() async throws {
        let coordinator = NativePushedViewCoordinator()
        var applied: [ViewShowFrame] = []
        coordinator.setApplyHandler { applied.append($0) }
        coordinator.receive(try viewShow(messageID: "first", target: "message"))
        coordinator.receive(try viewShow(messageID: "latest", target: "chat"))
        coordinator.scenePhaseChanged(.active)
        await Task.yield()

        XCTAssertEqual(applied.map(\.messageID), ["latest"])
        let key = RequestKey(accountScope: ExactText("person"), senderID: ExactText("agent"),
                             messageID: ExactText("latest"))
        let otherKey = RequestKey(accountScope: ExactText("person"), senderID: ExactText("agent"),
                                  messageID: ExactText("other"))
        XCTAssertTrue(coordinator.isPassive(key))

        var openEffects = 0
        XCTAssertFalse(coordinator.contentWasTouched(otherKey) { openEffects += 1 })
        XCTAssertEqual(openEffects, 0)
        XCTAssertTrue(coordinator.contentWasTouched(key) { openEffects += 1 })
        XCTAssertEqual(openEffects, 1)
        XCTAssertFalse(coordinator.contentWasTouched(key) { openEffects += 1 })
        XCTAssertEqual(openEffects, 1)
        XCTAssertEqual(coordinator.contentTouchRevision, 1)
    }

    func testHeldShowOlderThanOwnOpenIsDiscarded() async throws {
        var uptime: TimeInterval = 100
        let coordinator = NativePushedViewCoordinator(uptime: { uptime })
        var applied: [ViewShowFrame] = []
        coordinator.setApplyHandler { applied.append($0) }
        coordinator.receive(try viewShow(messageID: "older", target: "message", heldMilliseconds: 1_000))
        coordinator.recordOwnOpen()
        coordinator.scenePhaseChanged(.active)
        await Task.yield()

        XCTAssertTrue(applied.isEmpty)
        uptime += 0.1
        coordinator.receive(try viewShow(messageID: "newer", target: "message"))
        await Task.yield()
        XCTAssertEqual(applied.map(\.messageID), ["newer"])
    }

    func testTypingQuietPeriodCountsOnlyActiveTimeAndLeavingFieldApplies() async throws {
        var uptime: TimeInterval = 1_000
        let coordinator = NativePushedViewCoordinator(uptime: { uptime })
        var applied: [ViewShowFrame] = []
        coordinator.setApplyHandler { applied.append($0) }
        coordinator.scenePhaseChanged(.active)
        coordinator.replyEditorFocusChanged(true)
        coordinator.receive(try viewShow(messageID: "deferred", target: "chat"))

        uptime += 2
        coordinator.scenePhaseChanged(.inactive)
        uptime += 100
        coordinator.scenePhaseChanged(.active)
        uptime += 2.9
        coordinator.attemptPendingShow()
        XCTAssertTrue(applied.isEmpty, "Inactive time does not count toward the five-second quiet period.")

        uptime += 0.1
        coordinator.attemptPendingShow()
        await Task.yield()
        XCTAssertEqual(applied.map(\.messageID), ["deferred"])

        let leavingField = NativePushedViewCoordinator(uptime: { uptime })
        var appliedAfterBlur = false
        leavingField.setApplyHandler { _ in appliedAfterBlur = true }
        leavingField.scenePhaseChanged(.active)
        leavingField.conversationComposerFocusChanged(true)
        leavingField.receive(try viewShow(messageID: "after-blur", target: "message"))
        leavingField.conversationComposerFocusChanged(false)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(appliedAfterBlur, "Leaving the focused text field ends the typing wait.")

        coordinator.accountConnectionWillBeRemoved()
        leavingField.accountConnectionWillBeRemoved()
    }

    private func viewShow(messageID: String, target: String,
                          heldMilliseconds: Int? = nil) throws -> Data {
        var frame: [String: Any] = [
            "v": 1, "type": "view_show", "sender_id": "agent",
            "message_id": messageID, "target": target
        ]
        if let heldMilliseconds { frame["held_ms"] = heldMilliseconds }
        return try JSONSerialization.data(withJSONObject: frame)
    }
}
