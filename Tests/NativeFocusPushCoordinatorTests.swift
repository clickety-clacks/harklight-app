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

    func testPassiveChatKeepsThreeRepliesUnreadUntilContentIsTouched() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("agent"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: key, revision: 1)
        let handle = ExactText("session")
        let store = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
        let payload = try JSONValue.parse(Data(#"{"title":"Question"}"#.utf8))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: handle)),
            context: context)

        let question = ConversationTurn(id: ExactText("question"), binding: binding,
            author: .person, sessionHandle: handle, text: ExactText("Question"), kind: .discussion)
        try store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .turn(question)), context: context)
        let replies = (1...3).map { sequence in
            ConversationTurn(id: ExactText("reply-\(sequence)"), binding: binding,
                author: .origin, sessionHandle: handle, text: ExactText("Reply \(sequence)"),
                inReplyTo: question.id, kind: .reply)
        }
        for (index, reply) in replies.enumerated() {
            try store.applyConversation(ConversationEvent(sequence: UInt64(index + 2),
                binding: binding, fact: .turn(reply)), context: context)
        }

        let coordinator = NativePushedViewCoordinator()
        coordinator.setApplyHandler { _ in }
        coordinator.receive(try viewShow(messageID: "request", target: "chat"))
        coordinator.scenePhaseChanged(.active)
        XCTAssertTrue(coordinator.isPassive(key))

        for reply in replies {
            coordinator.performReadIfContentIsActive(for: key) {
                do { try store.markConversationRead(key, through: reply.id, context: context) }
                catch { XCTFail("Unexpected read update failure: \(error)") }
            }
        }
        let untouched = try XCTUnwrap(store.conversationSnapshot(context: context).threads[key])
        XCTAssertTrue(untouched.hasUnreadAgentReply, "All three replies remain unread while the pushed chat is untouched.")
        XCTAssertNil(untouched.readThroughTurn)
        XCTAssertEqual(untouched.turns.filter {
            $0.kind == .reply && $0.author == .origin
        }.count, 3)
        XCTAssertTrue(try store.snapshot(context: context).pendingMessageOpens.isEmpty)

        XCTAssertTrue(coordinator.contentWasTouched(key) {
            do { try store.enqueueMessageOpen(key, requestRevision: 1, context: context) }
            catch { XCTFail("Unexpected message-open update failure: \(error)") }
        })
        XCTAssertEqual(try store.snapshot(context: context).pendingMessageOpens.count, 1)
        let newest = try XCTUnwrap(replies.last)
        let readResumed = coordinator.performReadIfContentIsActive(for: key) {
            do { try store.markConversationRead(key, through: newest.id, context: context) }
            catch { XCTFail("Unexpected read update failure: \(error)") }
        }
        XCTAssertTrue(readResumed, "The first scroll after the touch resumes normal chat read handling.")
        let touched = try XCTUnwrap(store.conversationSnapshot(context: context).threads[key])
        XCTAssertFalse(touched.hasUnreadAgentReply)
        XCTAssertEqual(touched.readThroughTurn, newest.id)
        coordinator.accountConnectionWillBeRemoved()
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
