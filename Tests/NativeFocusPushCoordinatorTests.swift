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
        coordinator.receiveV2(viewShow(messageID: "first", target: "message"), elapsedSinceReceipt: 0)
        coordinator.receiveV2(viewShow(messageID: "latest", target: "chat"), elapsedSinceReceipt: 0)
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


    func testPassiveChatKeepsThreeRepliesUnreadUntilContentIsTouched() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("agent"), messageID: ExactText("request"))
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let model = ServerModelV2Store(fileURL: nil)
        let item = #"{"item_id":"request","sender":"agent","rev":1,"request_revision":1,"message":{"title":"Question"},"files":[],"seen":false,"chat":{"available":true,"started":true},"rank":{"key":"a","section":"current"}}"#
        try model.apply([.init(rev: 1, kind: "item", data: Data(item.utf8))], cursor: 1)
        let page = try APIEntriesPage(json: JSONValue.parse(Data(#"{"rev":1,"entries":[],"older":false}"#.utf8)))
        try model.apply(page, of: key.messageID)
        let replyIDs = (1...3).map { ExactText("reply-\($0)") }
        for (index, replyID) in replyIDs.enumerated() {
            let position = index + 1
            let revision = UInt64(position + 1)
            let entry = #"{"entry_id":"\#(replyID.rawValue)","item_id":"request","rev":\#(revision),"position":\#(position),"kind":"reply","author":"origin","request_revision":1,"text":"Reply","files":[]}"#
            try model.apply([.init(rev: revision, kind: "entry", data: Data(entry.utf8))], cursor: revision)
        }
        try store.restoreCachedServerState(ServerModelV2Projection.cachedState(model.snapshot, identity: identity),
                                           context: context)

        let coordinator = NativePushedViewCoordinator()
        let applied = expectation(description: "The held show opens chat")
        coordinator.setApplyHandler { _ in applied.fulfill() }
        coordinator.receiveV2(viewShow(messageID: "request", target: "chat"), elapsedSinceReceipt: 0)
        coordinator.scenePhaseChanged(.active)
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertTrue(coordinator.isPassive(key))

        for replyID in replyIDs {
            coordinator.performReadIfContentIsActive(for: key) {
                do { try store.markConversationRead(key, through: replyID, context: context) }
                catch { XCTFail("Unexpected read update failure: \(error)") }
            }
        }
        let untouched = try XCTUnwrap(store.conversationSnapshot(context: context).threads[key])
        XCTAssertTrue(untouched.hasUnreadAgentReply, "All three replies remain unread while the pushed chat is untouched.")
        XCTAssertEqual(untouched.accountReadThroughConversationSequence, 0)
        XCTAssertTrue(try store.savedV2ReadPositions(context: context).isEmpty)
        XCTAssertEqual(untouched.turns.filter {
            $0.kind == .reply && $0.author == .origin
        }.count, 3)
        XCTAssertTrue(try store.snapshot(context: context).pendingMessageOpens.isEmpty)

        XCTAssertTrue(coordinator.contentWasTouched(key) {
            do { try store.enqueueMessageOpen(key, requestRevision: 1, context: context) }
            catch { XCTFail("Unexpected message-open update failure: \(error)") }
        })
        XCTAssertEqual(try store.snapshot(context: context).pendingMessageOpens.count, 1)
        let newest = try XCTUnwrap(replyIDs.last)
        let readResumed = coordinator.performReadIfContentIsActive(for: key) {
            do { try store.markConversationRead(key, through: newest, context: context) }
            catch { XCTFail("Unexpected read update failure: \(error)") }
        }
        XCTAssertTrue(readResumed, "The first scroll after the touch resumes normal chat read handling.")
        let touched = try XCTUnwrap(store.conversationSnapshot(context: context).threads[key])
        XCTAssertTrue(touched.hasUnreadAgentReply,
                      "A visible read request cannot manufacture the server read position.")
        XCTAssertEqual(touched.accountReadThroughConversationSequence, 0)
        XCTAssertEqual(try store.savedV2ReadPositions(context: context).first?.entryID, newest)
        coordinator.accountConnectionWillBeRemoved()
    }

    func testHeldShowOlderThanOwnOpenIsDiscarded() async throws {
        var uptime: TimeInterval = 100
        let coordinator = NativePushedViewCoordinator(uptime: { uptime })
        var applied: [ViewShowFrame] = []
        coordinator.setApplyHandler { applied.append($0) }
        coordinator.receiveV2(viewShow(messageID: "older", target: "message", heldMilliseconds: 1_000), elapsedSinceReceipt: 0)
        coordinator.recordOwnOpen()
        coordinator.scenePhaseChanged(.active)
        await Task.yield()

        XCTAssertTrue(applied.isEmpty)
        uptime += 0.1
        coordinator.receiveV2(viewShow(messageID: "newer", target: "message"), elapsedSinceReceipt: 0)
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
        coordinator.receiveV2(viewShow(messageID: "deferred", target: "chat"), elapsedSinceReceipt: 0)

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
        let appliedAfterBlur = expectation(description: "Pushed view applies after focus leaves the text field")
        leavingField.setApplyHandler { _ in appliedAfterBlur.fulfill() }
        leavingField.scenePhaseChanged(.active)
        leavingField.conversationComposerFocusChanged(true)
        leavingField.receiveV2(viewShow(messageID: "after-blur", target: "message"), elapsedSinceReceipt: 0)
        leavingField.conversationComposerFocusChanged(false)
        await fulfillment(of: [appliedAfterBlur], timeout: 1)

        coordinator.accountConnectionWillBeRemoved()
        leavingField.accountConnectionWillBeRemoved()
    }

    private func viewShow(messageID: String, target: String,
                          heldMilliseconds: UInt64 = 0) -> ViewShowFrame {
        .clientAPI(ClientAPIShow(showID: messageID, deviceID: "device", itemID: messageID,
                                target: target == "chat" ? .chat : .message,
                                heldMilliseconds: heldMilliseconds), senderID: "agent")
    }
}
