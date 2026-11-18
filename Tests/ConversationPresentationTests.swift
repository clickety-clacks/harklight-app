import AttentionDomain
import CryptoKit
import Foundation
import SwiftUI
import Observation
import UIKit
import XCTest
@testable import Harklight
import HarklightNativeRelay

@MainActor
final class ConversationPresentationTests: XCTestCase {
    func testPastedNewlineRemainsInTheComposerWithoutSending() {
        var text = "Before "
        var sendCount = 0
        let editor = ConversationReturnTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isEnabled: true, onReturn: { sendCount += 1 }, onFocusChange: { _ in })
        let coordinator = editor.makeCoordinator()
        let view = UITextView()
        view.text = text
        view.delegate = coordinator
        let end = view.endOfDocument
        let insertion = view.textRange(from: end, to: end)!

        _ = coordinator.textPasteConfigurationSupporting(
            view, performPasteOf: NSAttributedString(string: "pasted text\n"), to: insertion)
        XCTAssertEqual(text, "Before pasted text\n")
        XCTAssertEqual(sendCount, 0)

        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: view.text.utf16.count, length: 0),
                                            replacementText: "\n"))
        XCTAssertEqual(sendCount, 1)
    }

    func testFailedComposerSaveKeepsTheLatestTextAvailableForRetryInThisSession() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let persistence = MemoryPendingActionPersistence()
        let domain = try ClientRepository(context: context, persistence: persistence)
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: key, revision: 1)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        let model = try LivePresentationStore(localFixtureStore: domain, context: context)

        persistence.failNextCommit()
        XCTAssertFalse(model.updateConversation(for: key, revision: 1, text: "Latest unsent text"))
        XCTAssertEqual(model.unsavedConversationText(for: binding), "Latest unsent text")
        XCTAssertEqual(model.conversationDraft(for: key, revision: 1).text, ExactText(""))

        XCTAssertTrue(model.updateConversation(for: key, revision: 1, text: "Latest unsent text"))
        XCTAssertNil(model.unsavedConversationText(for: binding))
        XCTAssertEqual(model.conversationDraft(for: key, revision: 1).text,
                       ExactText("Latest unsent text"))
    }

    func testSubmittedChatRemainsVisibleAcrossRestartAndJoinsOneReplayedTurn() throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("chat"))
        let binding = ConversationBinding(request: key, revision: 1)
        let persistence = MemoryPendingActionPersistence()
        let first = try ClientRepository(context: context, persistence: persistence)
        let payload = try JSONValue.parse(Data(#"{"title":"Chat"}"#.utf8))
        _ = try first.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)
        try first.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: payload)), context: context)
        let cached = ServerStateCacheSnapshot.make(identity: context.identity,
            from: try first.serverCacheSnapshot(context: context),
            conversations: try first.conversationSnapshot(context: context))
        try first.saveConversationDraft(ConversationDraft(binding: binding,
            text: ExactText("Keep this chat visible")), context: context)
        let operation = try first.prepareDiscussion(binding, context: context)
        let beforeResponse = try XCTUnwrap(first.conversationSnapshot(context: context).threads[key])
        XCTAssertEqual(ConversationPendingSubmission.rows(in: beforeResponse).map(\.text),
                       [ExactText("Keep this chat visible")])
        try first.markDiscussionOutcome(binding, operation: operation, rejection: nil, context: context)
        let restarted = try ClientRepository(context: context, persistence: persistence)
        try restarted.restoreCachedServerState(try cached.attentionDomainState(for: context.identity), context: context)
        let restoredThread = try XCTUnwrap(restarted.conversationSnapshot(context: context).threads[key])
        let restored = try XCTUnwrap(ConversationPendingSubmission.rows(in: restoredThread).first)
        XCTAssertEqual(restored.id, operation)
        XCTAssertEqual(restored.text, ExactText("Keep this chat visible"))
        XCTAssertEqual(restored.disposition, .outcomeUnknown(operation))
        let turnID = ExactText("accepted-turn")
        try restarted.markDiscussionAccepted(binding, operation: operation, turn: turnID, context: context)
        let accepted = try XCTUnwrap(restarted.conversationSnapshot(context: context).threads[key])
        XCTAssertEqual(ConversationPendingSubmission.rows(in: accepted).count, 1,
                       "Clearing the composer after acceptance must not hide the saved message before replay.")
        let turn = ConversationTurn(id: turnID, binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: restored.text, operationID: operation, kind: .discussion)
        try restarted.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(turn)), context: context)
        let replayed = try XCTUnwrap(restarted.conversationSnapshot(context: context).threads[key])
        XCTAssertTrue(ConversationPendingSubmission.rows(in: replayed).isEmpty)
        XCTAssertEqual(replayed.turns.map(\.text), [restored.text])
        let agentReply = ConversationTurn(id: ExactText("agent-reply"), binding: binding,
            author: .origin, sessionHandle: ExactText("session"), text: ExactText("Agent reply"),
            inReplyTo: turnID, kind: .reply)
        try restarted.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .turn(agentReply)), context: context)
        let withReply = try XCTUnwrap(restarted.conversationSnapshot(context: context).threads[key])
        XCTAssertEqual(withReply.turns.map(\.text), [restored.text, agentReply.text])
    }

    func testOpenChatModelPublishesPendingAndLiveTurnsWithoutReopening() async throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("chat"))
        let binding = ConversationBinding(request: key, revision: 1)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let payload = try JSONValue.parse(Data(#"{"title":"Chat"}"#.utf8))
        _ = try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: payload)), context: context)
        let model = try LivePresentationStore(store: domain, context: context)
        model.startObserving()
        defer { model.stopObserving() }
        let pendingShown = expectation(description: "open model shows submitted text before Server response")
        var pendingObserved = false
        model.notificationProjectionDidChange = {
            guard !pendingObserved, let thread = model.conversation(for: key),
                  ConversationPendingSubmission.rows(in: thread).first?.text == ExactText("Own chat") else { return }
            pendingObserved = true
            pendingShown.fulfill()
        }
        try domain.saveConversationDraft(ConversationDraft(binding: binding,
            text: ExactText("Own chat")), context: context)
        let operation = try domain.prepareDiscussion(binding, context: context)
        await fulfillment(of: [pendingShown], timeout: 5)

        let turnID = ExactText("own-turn")
        try domain.markDiscussionAccepted(binding, operation: operation, turn: turnID, context: context)
        let replyShown = expectation(description: "same open model receives own turn and agent reply")
        var replyObserved = false
        model.notificationProjectionDidChange = {
            guard !replyObserved, let thread = model.conversation(for: key),
                  thread.turns.map(\.text) == [ExactText("Own chat"), ExactText("Live reply")] else { return }
            replyObserved = true
            replyShown.fulfill()
        }
        let own = ConversationTurn(id: turnID, binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Own chat"), operationID: operation,
            kind: .discussion)
        let reply = ConversationTurn(id: ExactText("reply-turn"), binding: binding, author: .agent,
            sessionHandle: ExactText("session"), text: ExactText("Live reply"), inReplyTo: turnID, kind: .reply)
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(own)), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .turn(reply)), context: context)
        await fulfillment(of: [replyShown], timeout: 5)
        let updated = try XCTUnwrap(model.conversation(for: key))
        XCTAssertTrue(ConversationPendingSubmission.rows(in: updated).isEmpty)
        XCTAssertEqual(updated.turns.map(\.id), [own.id, reply.id])
    }

    func testRejectedChatKeepsItsTextVisibleWithoutPublishingAnUnsentEditor() throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: key, revision: 1)
        try repository.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        var thread = try XCTUnwrap(repository.conversationSnapshot(context: context).threads[key])
        let operation = UUID()
        thread.drafts[binding.revision] = ConversationDraft(binding: binding,
            text: ExactText("Retained rejected text"), disposition: .rejected(ExactText("closed")),
            operationID: operation)
        XCTAssertEqual(ConversationPendingSubmission.rows(in: thread).map(\.text),
                       [ExactText("Retained rejected text")])
        thread.drafts[binding.revision] = ConversationDraft(binding: binding, text: ExactText("Unsent edit"))
        XCTAssertTrue(ConversationPendingSubmission.rows(in: thread).isEmpty)
    }

    func testChatTextHasOneHomeAndRejectedEditRestoresTheComposer() throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("chat"))
        let binding = ConversationBinding(request: key, revision: 1)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        try domain.saveConversationDraft(ConversationDraft(binding: binding,
            text: ExactText("Never discard this")), context: context)
        let model = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(ConversationSubmittedText.composerText(for: model.conversationDraft(for: key, revision: 1)),
                       "Never discard this")
        let operation = try domain.prepareDiscussion(binding, context: context)
        let frame = Data("saved operation bytes".utf8)
        try domain.freezeDiscussionFrame(frame, binding: binding, operation: operation, context: context)
        try model.refreshFromDurableStore()
        XCTAssertEqual(ConversationSubmittedText.composerText(for: model.conversationDraft(for: key, revision: 1)), "")
        XCTAssertEqual(ConversationPendingSubmission.rows(in: try XCTUnwrap(model.conversation(for: key))).count, 1)
        try domain.markDiscussionOutcome(binding, operation: operation,
            rejection: ExactText("storage_unavailable"), context: context)
        XCTAssertEqual(try domain.prepareDiscussion(binding, context: context), operation,
                       "Retry must keep the original operation.")
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[key]?.drafts[1]?.wireFrame, frame)
        try domain.markDiscussionOutcome(binding, operation: operation,
            rejection: ExactText("storage_unavailable"), context: context)
        try model.refreshFromDurableStore()
        XCTAssertEqual(ConversationSubmittedText.composerText(for: model.conversationDraft(for: key, revision: 1)), "")
        model.editRejectedDiscussion(for: key, revision: 1)
        let edited = model.conversationDraft(for: key, revision: 1)
        XCTAssertEqual(ConversationSubmittedText.composerText(for: edited), "Never discard this")
        XCTAssertNil(edited.operationID)
        XCTAssertNil(edited.wireFrame)
        XCTAssertTrue(ConversationPendingSubmission.rows(in: try XCTUnwrap(model.conversation(for: key))).isEmpty)
    }

    func testAcceptedDiscussionClearsOnlyTheSubmittedText() {
        XCTAssertEqual(ConversationSubmittedText.afterResult(
            accepted: true, submitted: "Sent", submittedEdit: 3,
            current: "Sent", currentEdit: 3), "")
        XCTAssertEqual(ConversationSubmittedText.afterResult(
            accepted: true, submitted: "Sent", submittedEdit: 3,
            current: "A later edit", currentEdit: 4), "A later edit")
        XCTAssertEqual(ConversationSubmittedText.afterResult(
            accepted: true, submitted: "Sent", submittedEdit: 3,
            current: "Sent", currentEdit: 5), "Sent",
            "Edits made after submission survive even if the text returns to its old value.")
        XCTAssertEqual(ConversationSubmittedText.afterResult(
            accepted: false, submitted: "Sent", submittedEdit: 3,
            current: "Sent", currentEdit: 3), "Sent")
        XCTAssertEqual(ConversationSubmittedText.afterResult(
            accepted: false, submitted: "Sent", submittedEdit: 3,
            current: "A later edit", currentEdit: 4), "A later edit")
    }

    func testSentChatDoesNotInferDeliveryFailureFromElapsedTime() {
        var facts = ConversationTurnFacts(acceptedAtMilliseconds: 40_000)
        let listening = ConversationAvailabilityObservation(
            state: .listening)

        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            hasReply: false, nowMilliseconds: 39_999), .sent,
            "A future local clock observation cannot age the message into a failure state.")
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            availability: listening, hasReply: false, nowMilliseconds: 159_999), .sent)
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            availability: listening, hasReply: false, nowMilliseconds: 160_000), .sent)
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            hasReply: false, nowMilliseconds: 160_000), .sent,
            "Elapsed time alone does not establish a delivery failure.")

        facts.acceptedAtMilliseconds = nil
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            hasReply: false, nowMilliseconds: 9_000_000), .sent,
            "Legacy history without an acceptance time does not receive a fabricated age.")
        facts.delivered = true
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            hasReply: false, nowMilliseconds: 9_000_000), .delivered,
            "A later delivery ACK replaces the waiting presentation.")
    }

    func testSentChatFoldsActionAndReplyIntoDeliveredWithoutChangingStoredFacts() {
        var facts = ConversationTurnFacts()
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            availability: ConversationAvailabilityObservation(state: .gone),
            hasReply: true, nowMilliseconds: 0), .delivered,
            "An actual reply is visible as the next turn and establishes delivery.")
        XCTAssertNil(facts.actedBy, "A reply does not manufacture an acted fact.")
        XCTAssertFalse(facts.delivered, "A reply does not manufacture a receipt ACK fact.")

        facts.actedBy = ExactText("action")
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            availability: ConversationAvailabilityObservation(
                state: .unsupported(reason: ExactText("retired route"))),
            hasReply: false, nowMilliseconds: 0), .delivered,
            "An acted event folds into Delivered without inventing a reply.")
        XCTAssertEqual(facts.actedBy, ExactText("action"))
        XCTAssertFalse(facts.delivered,
                       "The status label does not overwrite the independent receipt fact.")
    }

    func testUnreceivedSentChatUsesLatestAvailabilityAndReceiptStaysDelivered() {
        let facts = ConversationTurnFacts(acceptedAtMilliseconds: 40_000)
        let notListening = ConversationAvailabilityObservation(
            state: .notListening(lastDetachedAt: nil))
        let unsupported = ConversationAvailabilityObservation(
            state: .unsupported(reason: ExactText("unsupported")))
        let gone = ConversationAvailabilityObservation(
            state: .gone)

        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            availability: notListening, hasReply: false, nowMilliseconds: 40_001), .notDeliveredYet,
            "The latest not-listening report makes an unreceived message visibly delayed immediately.")
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            availability: unsupported, hasReply: false, nowMilliseconds: 40_001), .noOneWillGetThis)
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: facts,
            availability: gone, hasReply: false, nowMilliseconds: 40_001), .noOneWillGetThis)

        var received = facts
        received.delivered = true
        for availability in [notListening, unsupported, gone] {
            XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: received,
                availability: availability, hasReply: false, nowMilliseconds: 40_001), .delivered,
                "A receipt keeps its Delivered outcome when later availability changes.")
        }
    }

    func testTwoAckStatusUsesReportedStageAndRerouteFactsWithoutChangingLegacyOrAnswerCaptions() {
        let request = RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                                 messageID: ExactText("request"))
        let binding = ConversationBinding(request: request, revision: 1)
        let chat = ConversationTurn(id: ExactText("person-turn"), binding: binding,
            author: .person, sessionHandle: ExactText("conversation-agent"), text: ExactText("Question"),
            kind: .discussion, deliveryAcks: true)
        let listening = ConversationAvailabilityObservation(state: .listening)
        let notListening = ConversationAvailabilityObservation(state: .notListening(lastDetachedAt: nil))
        let gone = ConversationAvailabilityObservation(state: .gone)
        func status(_ facts: ConversationTurnFacts,
                    availability: ConversationAvailabilityObservation? = nil,
                    hasReply: Bool = false, now: UInt64) -> ConversationSentChatStatusPresentation.Delivery {
            ConversationSentChatStatusPresentation.delivery(for: chat, facts: facts,
                availability: availability, hasReply: hasReply, conversationAgentName: "Studio",
                nowMilliseconds: now)
        }

        let unacknowledged = ConversationTurnFacts(acceptedAtMilliseconds: 40_000)
        XCTAssertEqual(status(unacknowledged, availability: listening, now: 159_999), .sending)
        XCTAssertEqual(status(unacknowledged, availability: listening, now: 160_000), .sending)
        XCTAssertEqual(status(unacknowledged, availability: listening, now: 9_000_000), .sending,
                       "An unreported ACK1 stays Sending; elapsed time does not synthesize a stall.")
        XCTAssertEqual(status(unacknowledged, availability: notListening, now: 40_001), .noListenerPickedThisUp)
        XCTAssertEqual(status(unacknowledged, availability: notListening, now: 9_000_000),
                       .noListenerPickedThisUp,
                       "The first-stage caption comes from the latest Server availability, not age.")

        var waiting = unacknowledged
        waiting.deliveryAck1 = .listenerReceived(atMilliseconds: 40_000, ack2Expected: true,
            acknowledgerSystem: ExactText("Tightbeam"), acknowledgerAgent: nil)
        XCTAssertEqual(status(waiting, availability: notListening, now: 159_999), .sending)
        XCTAssertEqual(status(waiting, availability: notListening, now: 160_000), .sending,
                       "An ACK1-to-ACK2 wait stays quiet, even if availability is now not-listening.")
        XCTAssertEqual(status(waiting, availability: notListening, now: 9_000_000), .sending,
                       "A supported listener remains Sending until the Server reports ACK2.")
        XCTAssertEqual(status(waiting, availability: gone, now: 160_000), .noOneWillGetThis)

        var incapable = waiting
        incapable.deliveryAck1 = .listenerReceived(atMilliseconds: 40_000, ack2Expected: false,
            acknowledgerSystem: ExactText("Harklight Agent"), acknowledgerAgent: nil)
        XCTAssertEqual(status(incapable, availability: gone, now: 9_000_000), .deliveredAck,
                       "ACK1 is final when the listener declared that ACK2 is unsupported.")

        var handed = unacknowledged
        handed.deliveryAck2 = .handed(atMilliseconds: 50_000, rerouted: false,
            acknowledgerSystem: ExactText("Tightbeam"), acknowledgerAgent: ExactText("Release"))
        XCTAssertEqual(status(handed, availability: gone, now: 9_000_000), .deliveredAck,
                       "rerouted is authoritative; the Client never compares agent names.")
        handed.deliveryAck2 = .handed(atMilliseconds: 50_000, rerouted: true,
            acknowledgerSystem: ExactText("Tightbeam"), acknowledgerAgent: ExactText("Release"))
        XCTAssertEqual(status(handed, availability: gone, now: 9_000_000), .deliveredTo("Release"))
        handed.deliveryAck2 = .handed(atMilliseconds: 50_000, rerouted: true,
            acknowledgerSystem: ExactText("Tightbeam"), acknowledgerAgent: nil)
        XCTAssertEqual(status(handed, availability: listening, now: 9_000_000), .deliveredAck,
                       "A rerouted ACK without an agent name keeps the plain Delivered caption.")

        var notHanded = unacknowledged
        notHanded.deliveryAck2 = .notHanded(atMilliseconds: 50_000,
            reason: ExactText("Receiving system could not hand off the message."),
            acknowledgerSystem: ExactText("Harklight Agent"), acknowledgerAgent: nil)
        XCTAssertEqual(status(notHanded, availability: listening, now: 60_000),
                       .notDelivered("Receiving system could not hand off the message."))
        XCTAssertEqual(status(notHanded, availability: listening, now: 9_000_000),
                       .notDelivered("Receiving system could not hand off the message."),
                       "A reported negative ACK2 reason remains the source of the failure caption.")
        XCTAssertEqual(status(notHanded, availability: gone, now: 60_000), .noOneWillGetThis)
        notHanded.delivered = true
        XCTAssertEqual(status(notHanded, availability: gone, now: 60_000), .deliveredAck,
                       "A Seen receipt outranks the delivery-ack and availability captions.")
        notHanded.delivered = false
        notHanded.actedBy = ExactText("action")
        XCTAssertEqual(status(notHanded, availability: listening, now: 60_000), .deliveredAck)
        notHanded.actedBy = nil
        XCTAssertEqual(status(notHanded, availability: listening, hasReply: true, now: 60_000), .deliveredAck)

        let legacyTurn = ConversationTurn(id: chat.id, binding: binding, author: .person,
            sessionHandle: chat.sessionHandle, text: chat.text, kind: .discussion)
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: legacyTurn,
            facts: unacknowledged, availability: listening, hasReply: false,
            conversationAgentName: "Studio", nowMilliseconds: 160_000), .sent,
            "An older Server keeps its current caption instead of showing a missing-ACK1 stall.")
        var markerlessButAcknowledged = unacknowledged
        markerlessButAcknowledged.deliveryAck1 = .listenerReceived(atMilliseconds: 155_000,
            ack2Expected: true, acknowledgerSystem: ExactText("Tightbeam"), acknowledgerAgent: nil)
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: legacyTurn,
            facts: markerlessButAcknowledged, availability: listening, hasReply: false,
            conversationAgentName: "Studio", nowMilliseconds: 159_999), .sending,
            "An explicit ACK fact is usable even if a historical discussion lacks the marker.")
        let noComment = ConversationTurn(id: ExactText("no-comment"), binding: binding,
            author: .person, sessionHandle: chat.sessionHandle, text: ExactText("No comment"),
            kind: .terminal, deliveryAcks: true)
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: noComment,
            facts: unacknowledged, availability: listening, hasReply: false,
            conversationAgentName: "Studio", nowMilliseconds: 160_000), .sent,
            "Answers and No comment keep the existing presentation regardless of ack facts.")
    }

    func testComposerNoticeUsesOnlyActuallyReportedLatestAvailability() {
        XCTAssertEqual(ConversationAvailabilityNoticePresentation.notice(for: nil), .unconfirmed,
                       "Missing legacy availability stays unknown.")
        XCTAssertEqual(ConversationAvailabilityNoticePresentation.notice(for:
            ConversationAvailabilityObservation(state: .listening)), .connected)
        XCTAssertEqual(ConversationAvailabilityNoticePresentation.notice(for:
            ConversationAvailabilityObservation(state: .notListening(lastDetachedAt: nil))),
            .nothingListening)
        XCTAssertEqual(ConversationAvailabilityNoticePresentation.notice(for:
            ConversationAvailabilityObservation(state: .unsupported(reason: ExactText("Unsupported")))),
            .noOneWillGetThis)
        XCTAssertEqual(ConversationAvailabilityNoticePresentation.notice(for:
            ConversationAvailabilityObservation(state: .gone)), .noOneWillGetThis)
    }

    func testConversationAvailabilityMustBeConfirmedBeforeShowingNoChatState() {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("availability-person"),
            deviceID: ExactText("availability-device")), transportMode: .relay)
        let otherContext = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("other-person"),
            deviceID: ExactText("availability-device")), transportMode: .relay)
        let availability = NativeConversationAvailability()

        XCTAssertEqual(availability.state(for: context), .unconfirmed)
        availability.confirm(for: context, conversationsUnavailable: false)
        XCTAssertEqual(availability.state(for: context), .available)
        XCTAssertEqual(availability.state(for: otherContext), .unconfirmed,
                       "A successful refresh for another profile cannot confirm this profile's chat state.")

        availability.confirm(for: context, conversationsUnavailable: true)
        XCTAssertEqual(availability.state(for: context), .unavailable)
        XCTAssertNotNil(availability.message(for: context))

        availability.reset()
        XCTAssertEqual(availability.state(for: context), .unconfirmed)
        XCTAssertNil(availability.message(for: context))
    }

    func testCachedRelayConversationKeepsDraftButCannotSendBeforeCatchUp() async throws {
        await NativeRelayLifecycle.shared.deactivate()
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("cache-person"), deviceID: ExactText("cache-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: key, revision: 1)
        let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":{"ok":true}}]}}"#.utf8))
        let serverStore = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        _ = try serverStore.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)
        try serverStore.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: payload)), context: context)
        let reply = ConversationTurn(id: ExactText("reply"), binding: binding, author: .origin,
            sessionHandle: ExactText("session"), text: ExactText("Reply"), kind: .reply)
        try serverStore.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(reply)), context: context)

        try serverStore.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .availability(sessionHandle: ExactText("session"), .listening)), context: context)

        let serverSnapshot = ServerStateCacheSnapshot.make(identity: context.identity,
            from: try serverStore.snapshot(context: context),
            conversations: try serverStore.conversationSnapshot(context: context))
        let cacheBackedStore = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())

        try cacheBackedStore.restoreCachedServerState(
            try serverSnapshot.attentionDomainState(for: context.identity), context: context)
        let model = try LivePresentationStore(store: cacheBackedStore, context: context)

        XCTAssertTrue(model.conversation(for: key)?.allowsDiscussion == true)
        XCTAssertEqual(model.conversationAvailabilityState, .unconfirmed)
        model.beginRefresh()
        defer { model.endRefresh() }
        XCTAssertTrue(model.canEditDiscussionDraft(for: key))
        XCTAssertFalse(model.canSendDiscussion(for: key))
        XCTAssertTrue(model.updateConversation(for: key, revision: 1, text: "During catch-up"))
        model.sendDiscussion(for: key, revision: 1)
        let draft = try XCTUnwrap(cacheBackedStore.conversationSnapshot(context: context).threads[key]?.drafts[1])
        XCTAssertEqual(draft.text, ExactText("During catch-up"))
        XCTAssertNil(draft.operationID)
        XCTAssertEqual(draft.disposition, .saved)
    }

    func testDiscussionSendUsesOnlyCurrentRequestListeningAndPreservesDraftOnLoss() async throws {
        await NativeRelayLifecycle.shared.deactivate()
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request"))
        let sibling = RequestKey(accountScope: identity.personID,
            senderID: key.senderID, messageID: ExactText("sibling"))
        let binding = ConversationBinding(request: key, revision: 1)
        let payload = try JSONValue.parse(Data(#"{"title":"Question"}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("handle"))),
            context: context)
        try domain.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: sibling, revision: 1),
            fact: .request(sessionHandle: ExactText("other-handle"), payload: payload)), context: context)
        let model = try LivePresentationStore(store: domain, context: context)
        let bytes = Data("Retained attachment".utf8)
        let file = ConversationFile(id: ExactText("attachment"), name: ExactText("note.txt"),
            byteCount: UInt64(bytes.count),
            sha256: ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()),
            content: .inline(bytes))
        XCTAssertTrue(model.updateConversation(for: key, revision: 1,
            text: "Keep this draft", files: [file]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            await NativeRelayLifecycle.shared.deactivate()
            try? FileManager.default.removeItem(at: directory)
        }
        let result = try await NativeRelayLifecycle.shared.confirmInProcessSessionForTesting(
            store: domain, context: context,
            session: SendEligibilitySession(identity: identity, key: key, payload: payload),
            serverStateCache: FileServerStateCache(identity: identity,
                fileURL: directory.appendingPathComponent("server-cache.json")))
        XCTAssertTrue(result.relayConfirmed)
        try model.refreshFromDurableStore()
        XCTAssertFalse(model.canSendDiscussion(for: key),
                       "A confirmed connection without a listening report is insufficient.")

        let states: [ConversationAvailability] = [
            .listening, .notListening(lastDetachedAt: nil), .gone,
            .unsupported(reason: ExactText("Unsupported")), .listening
        ]
        for (index, state) in states.enumerated() {
            try domain.applyConversation(ConversationEvent(sequence: UInt64(index + 2), binding: binding,
                fact: .availability(sessionHandle: ExactText("handle"), state)), context: context)
            if case .notListening = state {
                XCTAssertTrue(model.canSendDiscussion(for: key),
                              "The presentation still holds the earlier listening report.")
                var queued = false
                model.sendDiscussion(for: key, revision: 1, onQueued: { queued = true })
                XCTAssertFalse(queued)
                XCTAssertNil(try domain.conversationSnapshot(context: context).threads[key]?.drafts[1]?.operationID,
                             "A newer repository refusal must stop a new send before presentation adoption.")
                XCTAssertNotNil(model.conversationError)
            }
            try model.refreshFromDurableStore()
            XCTAssertEqual(model.canSendDiscussion(for: key), state == .listening)
            XCTAssertFalse(model.canSendDiscussion(for: sibling),
                           "A request cannot borrow another request's listening report.")
            if state != .listening {
                model.sendDiscussion(for: key, revision: 1)
            }
            let draft = model.conversationDraft(for: key, revision: 1)
            XCTAssertEqual(draft.text, ExactText("Keep this draft"))
            XCTAssertEqual(draft.files, [file])
            XCTAssertNil(draft.operationID)
        }

        await NativeRelayLifecycle.shared.deactivate()
        XCTAssertFalse(model.canSendDiscussion(for: key),
                       "Losing the confirmed connection invalidates the retained listening report.")
        XCTAssertEqual(model.conversationDraft(for: key, revision: 1).text, ExactText("Keep this draft"))

        _ = try await NativeRelayLifecycle.shared.confirmInProcessSessionForTesting(
            store: domain, context: context,
            session: SendEligibilitySession(identity: identity, key: key, payload: payload),
            serverStateCache: FileServerStateCache(identity: identity,
                fileURL: directory.appendingPathComponent("server-cache.json")))
        try model.refreshFromDurableStore()
        XCTAssertTrue(model.canSendDiscussion(for: key))
        try domain.applyConversation(ConversationEvent(sequence: 7, binding: binding,
            fact: .terminal(turn: ExactText("answered"), author: .server, state: .answered)),
            context: context)
        XCTAssertTrue(model.canSendDiscussion(for: key), "The presentation has not adopted closure yet.")
        var queuedAfterClosure = false
        model.sendDiscussion(for: key, revision: 1, onQueued: { queuedAfterClosure = true })
        XCTAssertFalse(queuedAfterClosure)
        XCTAssertNil(try domain.conversationSnapshot(context: context).threads[key]?.drafts[1]?.operationID)
        XCTAssertNotNil(model.conversationError)
        try model.refreshFromDurableStore()
        XCTAssertFalse(model.canEditDiscussionDraft(for: key))
        XCTAssertFalse(model.canSendDiscussion(for: key))
        XCTAssertFalse(model.updateConversation(for: key, revision: 1, text: "Cannot edit"))
        XCTAssertEqual(model.conversationDraft(for: key, revision: 1).text, ExactText("Keep this draft"))

    }

    func testClosurePreservesUncertainDiscussionIdentityAndContent() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("uncertain"))
        let binding = ConversationBinding(request: key, revision: 1)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("handle"), payload: .null)), context: context)
        try domain.saveConversationDraft(ConversationDraft(binding: binding,
            text: ExactText("Already submitted")), context: context)
        let operation = try domain.prepareDiscussion(binding, context: context)
        try domain.markDiscussionOutcome(binding, operation: operation, rejection: nil, context: context)
        let before = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[key]?.drafts[1])
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .terminal(turn: ExactText("answer"), author: .server, state: .answered)),
            context: context)
        let model = try LivePresentationStore(store: domain, context: context)
        XCTAssertFalse(model.canEditDiscussionDraft(for: key))
        XCTAssertFalse(model.canSendDiscussion(for: key))
        XCTAssertEqual(model.conversationDraft(for: key, revision: 1), before,
                       "Closure cannot reclassify an earlier uncertain send or replace its operation.")
    }

    func testClosedRepositoryRejectsEditsBeforePresentationAdoption() throws {
        for terminal in [TerminalState.answered, .noComment] {
            let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                personID: ExactText("person"), deviceID: ExactText("device"))
            let context = ProfileContext(identity: identity, transportMode: .relay)
            let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
            let key = RequestKey(accountScope: identity.personID,
                senderID: ExactText("sender"), messageID: ExactText("request"))
            let binding = ConversationBinding(request: key, revision: 1)
            try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
                fact: .request(sessionHandle: ExactText("handle"), payload: .null)), context: context)
            try domain.saveConversationDraft(ConversationDraft(binding: binding,
                text: ExactText("Original submitted text")), context: context)
            let operation = try domain.prepareDiscussion(binding, context: context)
            try domain.markDiscussionOutcome(binding, operation: operation,
                rejection: ExactText("storage_unavailable"), context: context)
            let before = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[key]?.drafts[1])
            let directEdit = try LivePresentationStore(store: domain, context: context)
            let rejectedEdit = try LivePresentationStore(store: domain, context: context)
            try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
                fact: .terminal(turn: ExactText("answer"), author: .server, state: terminal)),
                context: context)

            XCTAssertTrue(directEdit.canEditDiscussionDraft(for: key))
            XCTAssertTrue(rejectedEdit.canEditDiscussionDraft(for: key))
            rejectedEdit.editRejectedDiscussion(for: key, revision: 1)
            XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[key]?.drafts[1], before)
            XCTAssertNotNil(rejectedEdit.conversationError)
            XCTAssertFalse(directEdit.updateConversation(for: key, revision: 1, text: "Stale edit"))
            XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[key]?.drafts[1], before,
                           "Neither a stale editor nor Edit can clear the saved operation on a closed request.")
            XCTAssertNotNil(directEdit.conversationError)
        }
    }

    func testComposerStagedTextSurvivesClosureBeforePendingSave() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryPendingActionPersistence()
        let domain = try ClientRepository(context: context, persistence: persistence)
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: key, revision: 1)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("handle"), payload: .null)), context: context)
        try domain.saveConversationDraft(ConversationDraft(binding: binding,
            text: ExactText("Before typing")), context: context)
        let model = try LivePresentationStore(store: domain, context: context)
        let editor = ConversationComposerTextSession()
        editor.stagedBinding = binding
        editor.savedText = "Before typing"
        editor.stagedText = "Before typing plus the unsaved editing burst"

        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .terminal(turn: ExactText("answer"), author: .server, state: .answered)),
            context: context)
        try model.refreshFromDurableStore()
        // This is the same persistence path used when removal cancels the
        // composer's pending save and onDisappear flushes the staged session.
        XCTAssertFalse(editor.persist(in: model))
        XCTAssertEqual(model.unsavedConversationText(for: binding), editor.stagedText)
        XCTAssertEqual(editor.savedText, "Before typing")
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[key]?.drafts[1]?.text,
                       ExactText("Before typing"))
        XCTAssertNotNil(model.conversationError)
        XCTAssertFalse(model.canEditDiscussionDraft(for: key))
        XCTAssertFalse(model.canSendDiscussion(for: key))
        XCTAssertEqual(model.retainedConversationText(for: key)[1], ExactText(editor.stagedText))

        // Later Server projection writes must not erase locally retained text.
        try domain.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .availability(sessionHandle: ExactText("handle"), .notListening(lastDetachedAt: nil))),
            context: context)
        let sibling = RequestKey(accountScope: identity.personID,
            senderID: key.senderID, messageID: ExactText("sibling"))
        let siblingBinding = ConversationBinding(request: sibling, revision: 1)
        try domain.applyConversation(ConversationEvent(sequence: 4, binding: siblingBinding,
            fact: .request(sessionHandle: ExactText("handle"), payload: .null)), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 5, binding: siblingBinding,
            fact: .terminal(turn: ExactText("sibling-answer"), author: .server, state: .noComment)),
            context: context)
        try domain.retainConversationText(ExactText("Sibling unsent text"), for: siblingBinding, context: context)
        let cache = ServerStateCacheSnapshot.make(identity: identity,
            from: try domain.serverCacheSnapshot(context: context),
            conversations: try domain.conversationSnapshot(context: context))
        let restored = try ClientRepository(context: context, persistence: persistence)
        try restored.restoreCachedServerState(try cache.attentionDomainState(for: identity), context: context)
        let reopened = try LivePresentationStore(store: restored, context: context)
        XCTAssertEqual(reopened.retainedConversationText(for: key), [1: ExactText(editor.stagedText)],
                       "The closed-history recovery surface restores the exact request/revision after relaunch.")
        XCTAssertEqual(reopened.conversationDraft(for: key, revision: 1).text, ExactText("Before typing"))
        XCTAssertFalse(reopened.canEditDiscussionDraft(for: key))
        XCTAssertFalse(reopened.canSendDiscussion(for: key))
        let priorClipboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = priorClipboard }
        reopened.copyRetainedConversationText(for: key, revision: 1)
        XCTAssertEqual(UIPasteboard.general.string, editor.stagedText)
        XCTAssertTrue(reopened.retainedConversationText(for: key).isEmpty)
        XCTAssertEqual(reopened.retainedConversationText(for: sibling), [1: ExactText("Sibling unsent text")])

        let afterCopy = try ClientRepository(context: context, persistence: persistence)
        try afterCopy.restoreCachedServerState(try cache.attentionDomainState(for: identity), context: context)
        let afterCopyModel = try LivePresentationStore(store: afterCopy, context: context)
        XCTAssertTrue(afterCopyModel.retainedConversationText(for: key).isEmpty,
                      "Copy dismisses only that request/revision durably.")
        XCTAssertEqual(afterCopyModel.retainedConversationText(for: sibling), [1: ExactText("Sibling unsent text")])
        afterCopyModel.dismissRetainedConversationText(for: sibling, revision: 1)
        let afterDismiss = try ClientRepository(context: context, persistence: persistence)
        XCTAssertTrue(try afterDismiss.retainedConversationText(for: sibling, context: context).isEmpty,
                      "Explicit Dismiss persists without sending or editing the saved draft.")
    }

    func testConversationPanelSeparatesNoChatFromLoadingAndUnavailableStates() {
        XCTAssertEqual(ConversationPanelEmptyState.resolve(availability: .available,
            isRefreshing: false, hasConnectionWarning: false, canCheckAvailability: true), .noChat)
        XCTAssertEqual(ConversationPanelEmptyState.resolve(availability: .unavailable,
            isRefreshing: false, hasConnectionWarning: false, canCheckAvailability: true), .chatUnavailable)
        XCTAssertEqual(ConversationPanelEmptyState.resolve(availability: .available,
            isRefreshing: true, hasConnectionWarning: false, canCheckAvailability: true), .historyPending)
        XCTAssertEqual(ConversationPanelEmptyState.resolve(availability: .available,
            isRefreshing: false, hasConnectionWarning: true, canCheckAvailability: true), .connectionUnavailable,
            "A later connection failure must not turn a missing thread into a sender-attributed no-chat claim.")
        XCTAssertEqual(ConversationPanelEmptyState.resolve(availability: .unconfirmed,
            isRefreshing: true, hasConnectionWarning: false, canCheckAvailability: true), .historyPending)
        XCTAssertEqual(ConversationPanelEmptyState.resolve(availability: .unconfirmed,
            isRefreshing: false, hasConnectionWarning: true, canCheckAvailability: true), .connectionUnavailable)
        XCTAssertEqual(ConversationPanelEmptyState.resolve(availability: .unavailable,
            isRefreshing: false, hasConnectionWarning: true, canCheckAvailability: true), .chatUnavailable,
            "An actual capability refusal remains specific to chat, regardless of catch-up.")
        XCTAssertEqual(ConversationPanelEmptyState.resolve(availability: .unavailable,
            isRefreshing: true, hasConnectionWarning: false, canCheckAvailability: true), .chatUnavailable)
        XCTAssertEqual(ConversationPanelEmptyState.resolve(availability: .unconfirmed,
            isRefreshing: false, hasConnectionWarning: false, canCheckAvailability: false), .offline)
        XCTAssertEqual(ConversationPanelEmptyState.resolve(availability: .unconfirmed,
            isRefreshing: false, hasConnectionWarning: false, canCheckAvailability: true), .historyPending)
    }

    func testCachedClosedChatRetainsDraftWithoutEditingOrSending() throws {
        for terminal in [TerminalState.answered, .noComment, .expired] {
            let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                personID: ExactText("person"), deviceID: ExactText("device"))
            let context = ProfileContext(identity: identity, transportMode: .relay)
            let key = RequestKey(accountScope: identity.personID,
                senderID: ExactText("sender"), messageID: ExactText("closed-cache"))
            let binding = ConversationBinding(request: key, revision: 1)
            let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":{"ok":true}}]}}"#.utf8))
            let persistence = MemoryPendingActionPersistence()
            let serverStore = try ClientRepository(context: context, persistence: persistence)
            _ = try serverStore.apply(RelayEvent(sequence: 1,
                body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
                conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
                context: context)
            try serverStore.applyConversation(ConversationEvent(sequence: 1, binding: binding,
                fact: .request(sessionHandle: ExactText("session"), payload: payload)), context: context)
            try serverStore.saveConversationDraft(ConversationDraft(binding: binding,
                text: ExactText("Retained before closure")), context: context)
            try serverStore.applyConversation(ConversationEvent(sequence: 2, binding: binding,
                fact: .terminal(turn: ExactText("expired"), author: .server, state: terminal)),
                context: context)

            let snapshot = ServerStateCacheSnapshot.make(identity: context.identity,
                from: try serverStore.snapshot(context: context),
                conversations: try serverStore.conversationSnapshot(context: context))
            let cacheBackedStore = try ClientRepository(context: context, persistence: persistence)

            try cacheBackedStore.restoreCachedServerState(
                try snapshot.attentionDomainState(for: context.identity), context: context)
            let model = try LivePresentationStore(store: cacheBackedStore, context: context)

            XCTAssertEqual(try XCTUnwrap(model.conversation(for: key)).terminal, terminal)
            XCTAssertFalse(model.canEditDiscussionDraft(for: key))
            XCTAssertFalse(model.canSendDiscussion(for: key))
            XCTAssertFalse(model.updateConversation(for: key, revision: 1, text: "Cannot edit closed history"))
            XCTAssertEqual(model.conversationDraft(for: key, revision: 1).text,
                           ExactText("Retained before closure"))
            XCTAssertFalse(model.canSendDiscussion(for: key))
        }
    }


    func testInlineTurnAndDraftBytesStayBehindReferencesAcrossTextOnlyComposerWrites() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = FilePendingActionPersistence(directoryURL: root.appendingPathComponent("State", isDirectory: true))
        let storage = try ConversationFileStorage(identity: identity, root: root.appendingPathComponent("Files", isDirectory: true))
        let domain = try ClientRepository(context: context, persistence: persistence,
            conversationFileReferences: storage)
        let request = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: request, revision: 1)
        let bytes = Data(repeating: 0xA7, count: 200_000)
        let digest = ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let inline = ConversationFile(id: ExactText("attachment"), name: ExactText("large-note.bin"),
            byteCount: UInt64(bytes.count), sha256: digest, content: .inline(bytes))
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Before edit"), files: [inline]),
            context: context)
        let turn = ConversationTurn(id: ExactText("turn-2"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Shared exact bytes"), files: [inline])
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(turn)), context: context)

        let saved = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[request]?.drafts[1])
        let savedFile = try XCTUnwrap(saved.files.first)
        guard case .localFile = savedFile.content else { return XCTFail("Inline bytes must become an account-owned file reference.") }
        let model = try LivePresentationStore(store: domain, context: context)
        model.updateConversation(for: request, revision: 1, text: "After composer edit")
        XCTAssertNil(model.conversationError)
        let firstEdit = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[request]?.drafts[1])
        XCTAssertEqual(firstEdit.files, saved.files, "A text-only edit preserves the original file identity and reference.")
        model.updateConversation(for: request, revision: 1, text: "After the next keystroke")
        XCTAssertNil(model.conversationError)
        let secondEdit = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[request]?.drafts[1])
        XCTAssertEqual(secondEdit.files, saved.files, "Later text edits keep the same normalized file references.")

        let persisted = try XCTUnwrap(persistence.load(identity: identity))
        XCTAssertLessThan(persisted.count, bytes.count / 2, "Whole-state persistence must contain references, not copied inline payloads.")
        XCTAssertNil(persisted.range(of: bytes), "Composer keystrokes must not rewrite attachment bytes into account state.")
        let storedURL = try storage.fileURL(for: savedFile)
        try storage.verify(storedURL, for: savedFile)
        XCTAssertEqual(try Data(contentsOf: storedURL), bytes)

        let cacheURL = root.appendingPathComponent("server-cache.json")
        let cache = FileServerStateCache(identity: identity, fileURL: cacheURL)
        try await cache.save(ServerStateCacheSnapshot.make(identity: identity,
            from: domain.snapshot(context: context), conversations: domain.conversationSnapshot(context: context)))
        let reopenedCache = FileServerStateCache(identity: identity, fileURL: cacheURL)
        let cached = try await reopenedCache.load()
        let restored = try ClientRepository(context: context, persistence: persistence,
            conversationFileReferences: storage)
        try restored.restoreCachedServerState(try XCTUnwrap(cached).attentionDomainState(for: identity), context: context)
        let thread = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[request])
        XCTAssertEqual(thread.currentRevision, 1)
        XCTAssertEqual(thread.turns.first?.id, turn.id)
        XCTAssertEqual(thread.turns.first?.conversationSequence, 2)
        XCTAssertEqual(thread.turns.first?.binding, binding)
        XCTAssertEqual(thread.turns.first?.files.first?.id, inline.id)
        XCTAssertEqual(thread.turns.first?.files.first?.content, savedFile.content)
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("After the next keystroke"))
        XCTAssertEqual(thread.drafts[1]?.files.first?.content, savedFile.content)
        try restored.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(turn)), context: context)
        XCTAssertEqual(try restored.conversationSnapshot(context: context).cursor, 2,
            "A duplicate inline replay normalizes to the same retained reference instead of conflicting.")
    }

    func testFailedTextWriteKeepsAttachmentReferencesForRetryAndDuplicateReplay() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("legacy-inline"))
        let binding = ConversationBinding(request: request, revision: 1)
        let bytes = Data(repeating: 0xB4, count: 200_000)
        let digest = ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let inline = ConversationFile(id: ExactText("legacy-attachment"), name: ExactText("legacy-note.bin"),
            byteCount: UInt64(bytes.count), sha256: digest, content: .inline(bytes))
        let requestEvent = ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null))
        let turn = ConversationTurn(id: ExactText("legacy-turn"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Retained exact bytes"), files: [inline])
        let turnEvent = ConversationEvent(sequence: 2, binding: binding, fact: .turn(turn))

        let backing = FilePendingActionPersistence(directoryURL: root.appendingPathComponent("State", isDirectory: true))
        let failingPersistence = FailOncePendingActionPersistence(backing: backing)
        let storage = try ConversationFileStorage(identity: identity, root: root.appendingPathComponent("Files", isDirectory: true))
        let store = try ClientRepository(context: context, persistence: failingPersistence,
            conversationFileReferences: storage)

        try store.applyConversation(requestEvent, context: context)
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Before retry"), files: [inline]),
            context: context)
        try store.applyConversation(turnEvent, context: context)
        let beforeWrite = try XCTUnwrap(failingPersistence.load(identity: identity))

        let initiallyNormalized = try XCTUnwrap(store.conversationSnapshot(context: context).threads[request])
        let retainedTurnFile = try XCTUnwrap(initiallyNormalized.turns.first?.files.first)
        let retainedDraftFile = try XCTUnwrap(initiallyNormalized.drafts[1]?.files.first)
        guard case .localFile = retainedTurnFile.content, case .localFile = retainedDraftFile.content else {
            return XCTFail("Incoming files must be externalized before a text-only edit.")
        }
        XCTAssertEqual(retainedTurnFile.id, inline.id)
        XCTAssertEqual(retainedDraftFile.id, inline.id)

        failingPersistence.failNextCommit()
        XCTAssertThrowsError(try store.updateConversationDraftText(ExactText("Failed attempt"), for: binding, context: context)) { error in
            guard let storeError = error as? AttentionStoreError, case .persistence = storeError else {
                return XCTFail("Expected the injected durable-write failure; received \(error).")
            }
        }
        let recovered = try XCTUnwrap(store.conversationSnapshot(context: context).threads[request])
        XCTAssertEqual(recovered.drafts[1]?.text, ExactText("Before retry"), "The failed edit is not reported as saved.")
        XCTAssertEqual(recovered.turns.first?.files.first, retainedTurnFile)
        XCTAssertEqual(recovered.drafts[1]?.files.first, retainedDraftFile)
        let unchangedDiskBytes = try XCTUnwrap(failingPersistence.load(identity: identity))
        XCTAssertEqual(unchangedDiskBytes, beforeWrite, "A failed text write leaves the prior pending inputs intact.")

        let retried = try store.updateConversationDraftText(ExactText("Saved retry"), for: binding, context: context)
        XCTAssertEqual(retried.text, ExactText("Saved retry"))
        XCTAssertEqual(retried.binding, binding)
        XCTAssertEqual(retried.files, [retainedDraftFile])
        let retriedDiskBytes = try XCTUnwrap(failingPersistence.load(identity: identity))
        XCTAssertNil(retriedDiskBytes.range(of: bytes), "The successful retry persists references instead of inline payload bytes.")
        let retainedURL = try storage.fileURL(for: retainedTurnFile)
        try storage.verify(retainedURL, for: retainedTurnFile)
        XCTAssertEqual(try Data(contentsOf: retainedURL), bytes)

        let cursorBeforeDuplicate = try store.conversationSnapshot(context: context).cursor
        try store.applyConversation(turnEvent, context: context)
        let afterDuplicate = try XCTUnwrap(store.conversationSnapshot(context: context).threads[request])
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, cursorBeforeDuplicate)
        XCTAssertEqual(afterDuplicate.turns.count, 1, "The original turn remains a single idempotently replayed fact.")
        XCTAssertEqual(afterDuplicate.turns.first?.id, turn.id)
        XCTAssertEqual(afterDuplicate.turns.first?.binding, binding)
        XCTAssertEqual(afterDuplicate.turns.first?.files.first, retainedTurnFile)
        let finalDiskBytes = try XCTUnwrap(failingPersistence.load(identity: identity))
        XCTAssertNil(finalDiskBytes.range(of: bytes), "Duplicate replay leaves the normalized persisted state unchanged.")
    }

    func testQuestionRevisionKeepsAnOldSelectorBoundToTheVersionThePersonSaw() async throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("fictional-relay"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        let first = try JSONValue.parse(Data(#"{"title":"First wording","by_when":1793200000000,"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Old choice","kind":"text"}]}}"#.utf8))
        let second = try JSONValue.parse(Data(#"{"title":"Revised wording","by_when":1793300000000,"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"new","label":"New choice","kind":"text"}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: first), .message)), context: context)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            await NativeRelayLifecycle.shared.deactivate()
            try? FileManager.default.removeItem(at: directory)
        }
        let confirmed = try await NativeRelayLifecycle.shared.confirmInProcessSessionForTesting(
            store: domain, context: context,
            session: ReplyCheckpointSession(identity: context.identity, key: key, payload: first),
            serverStateCache: FileServerStateCache(identity: context.identity,
                fileURL: directory.appendingPathComponent("server-cache.json")))
        XCTAssertTrue(confirmed.relayConfirmed)
        XCTAssertTrue(try domain.snapshot(context: context).inboxCheckpoint?.checkpointAccepted == true)
        let b1 = ConversationBinding(request: key, revision: 1)
        let b2 = ConversationBinding(request: key, revision: 2)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: b1,
            fact: .request(sessionHandle: ExactText("origin"), payload: first)), context: context)
        let port = AttentionDomainPort(store: domain)
        let oldSelector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let old = try port.submit(SubmitIntent(context: port.context, selector: oldSelector, intentID: UUID(),
            inputs: [.compatibilityText(action: ExactText("old"), text: ExactText("Old answer"))]))
        XCTAssertEqual(try domain.lookupIntent(old.intentID, context: context)?.requestRevision, 1)
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: b2,
            fact: .request(sessionHandle: ExactText("origin"), payload: second)), context: context)
        try domain.setInboxView(InboxView(revision: ExactText("view-1"), entries: [
            InboxViewEntry(key: key, priority: .high, thread: ExactText("release"))
        ]), context: context)
        let revised = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first)
        XCTAssertEqual(revised.title, ExactText("Revised wording"))
        XCTAssertNil(revised.intentReceipt, "The earlier answer must not become the new version's receipt")
        XCTAssertNil(revised.draft.compatibility.selectedActionID)
        let staleSubmission = try XCTUnwrap(domain.lookupIntent(old.intentID, context: context))
        XCTAssertEqual(staleSubmission.requestRevision, 1)
        XCTAssertEqual(staleSubmission.operation.uniqueValue(named: "request_revision")?.integerValue, 1)
        try domain.recordAnswerStaleRevision(old.intentID, operationID: old.opID,
            currentRevision: 2, context: context)
        let currentAfterDecline = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(currentAfterDecline.title, ExactText("Revised wording"))
        XCTAssertEqual(currentAfterDecline.staleAnswerRevision?.submittedRevision, 1)
        XCTAssertEqual(currentAfterDecline.staleAnswerRevision?.currentRevision, 2)
        let historical = try XCTUnwrap(port.inspectAnswerDraft(context: port.context,
                                                               request: key, revision: 1))
        XCTAssertEqual(historical.draft.compatibility.selectedActionID, ExactText("old"))
        XCTAssertEqual(historical.byWhenMilliseconds, 1_793_300_000_000,
                       "A historical answer draft keeps showing the current revision deadline.")
        XCTAssertEqual(historical.inboxPriority, .high)
        XCTAssertEqual(historical.inboxThread, ExactText("release"))
        let liveAfterDecline = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(liveAfterDecline.staleAnswerDialog?.currentRevision, 2)
        XCTAssertTrue(liveAfterDecline.staleAnswerDialog?.message.contains("Revised wording") == true)
        let latestRequest = try XCTUnwrap(liveAfterDecline.request(for: key))
        XCTAssertEqual(latestRequest.requestRevision, 2)
        XCTAssertTrue(LiveRequestDetail(request: latestRequest, store: liveAfterDecline).canAnswer,
                      "The changed request is available for another answer after the stale refusal.")
        liveAfterDecline.dismissStaleAnswerDialog()
        try liveAfterDecline.refreshFromDurableStore()
        XCTAssertNil(liveAfterDecline.staleAnswerDialog, "A dismissed stale-answer notice does not repeat in this session.")
        let thread = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[key])
        XCTAssertEqual(thread.answerDrafts?[1]?.compatibility.selectedActionID, ExactText("old"))
        XCTAssertEqual(thread.revisions[1], first)
        XCTAssertEqual(historical.title, ExactText("First wording"))
        XCTAssertNil(historical.selector, "Historical drafts cannot acquire a current answer selector")
        XCTAssertTrue(try domain.snapshot(context: context).outbox.isEmpty)
        let retained = try XCTUnwrap(domain.lookupIntent(old.intentID, context: context))
        XCTAssertEqual(retained.disposition, .staleRevision(currentRevision: 2))
        XCTAssertEqual(retained.answer, .string(ExactText("Old answer")))
        guard case let .compatibility(actions) = latestRequest.projection,
              let newAction = actions.first else {
            return XCTFail("The revised request should expose its new answer action.")
        }
        liveAfterDecline.selectAction(newAction.id, input: nil, for: key,
                                      requestRevision: latestRequest.requestRevision)
        liveAfterDecline.updateCompatibilityText("new answer", action: newAction.id, for: key,
                                                 requestRevision: latestRequest.requestRevision)
        XCTAssertTrue(liveAfterDecline.submitFromUser(key,
                                                      requestRevision: latestRequest.requestRevision))
        let current = try XCTUnwrap(domain.snapshot(context: context).intents.values.first {
            $0.requestKey == key && $0.requestRevision == 2
        })
        XCTAssertEqual(current.requestRevision, 2)
        XCTAssertTrue(String(decoding: current.wireFrame, as: UTF8.self).contains("\"request_revision\":2"))
        XCTAssertEqual(try domain.snapshot(context: context).intents.count, 2, "Both original facts remain inspectable")
    }

    func testPendingDraftBuffersStayBoundToTheirRequestRevision() throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("fictional-relay"),
            personID: ExactText("draft-revision-person"), deviceID: ExactText("device")), transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("draft-revision"))
        let first = try JSONValue.parse(Data(#"{"title":"First wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Old choice","kind":"text"}]}}"#.utf8))
        let second = try JSONValue.parse(Data(#"{"title":"Revised wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"new","label":"New choice","kind":"text"}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: first), .message)), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("origin"), payload: first)), context: context)
        let live = try LivePresentationStore(store: domain, context: context)
        let port = AttentionDomainPort(store: domain)
        live.selectAction(ExactText("old"), input: nil, for: key, requestRevision: 1)
        live.stageCompatibilityText("Old-version draft", action: ExactText("old"),
                                    for: key, requestRevision: 1)
        try domain.applyConversation(ConversationEvent(sequence: 2,
            binding: ConversationBinding(request: key, revision: 2),
            fact: .request(sessionHandle: ExactText("origin"), payload: second)), context: context)

        // A newer revision may reach the store before the displayed projection
        // catches up. Text staged against that old display must not be saved.
        live.stageCompatibilityText("Late old-version text", action: ExactText("old"),
                                    for: key, requestRevision: 1)
        XCTAssertFalse(live.flushPendingDraft(for: key, requestRevision: 1))
        try live.refreshFromDurableStore()

        let historical = try XCTUnwrap(port.inspectAnswerDraft(context: port.context, request: key, revision: 1))
        let current = try XCTUnwrap(port.inspect(context: port.context, request: key, revision: 2).requests.first)
        XCTAssertEqual(historical.draft.compatibility.selectedActionID, ExactText("old"))
        XCTAssertNil(current.draft.compatibility.selectedActionID,
                     "Editing the version on screen must not apply its answer to the newer version.")
        XCTAssertNil(live.draft(for: key, revision: 2)?.compatibility.textByActionID[ExactText("old")],
                     "Text staged for the old request version must not appear under the revised message.")
        XCTAssertNil(live.draft(for: key, revision: 2)?.compatibility.textByActionID[ExactText("new")])
        XCTAssertNil(historical.selector,
                     "A new request version cannot issue an answer selector for the archived version.")
        XCTAssertTrue(try domain.snapshot(context: context).outbox.isEmpty)
    }

    func testHistoricalRequestReturnsUnavailableForRedactedRevision() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fictional-relay"),
                                       personID: ExactText("historical-version-person"),
                                       deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let domain = try ClientRepository(context: context,
                                             persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("historical-version"))
        let original = try JSONValue.parse(Data(#"{"title":"Original question","body":"Original wording"}"#.utf8))
        try domain.registerFixtureRequests([
            StoredRequest(key: key, originalPayload: original)
        ], context: context)
        try domain.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("origin"), payload: original)), context: context)
        let redacted = ConversationTurn(id: ExactText("2"),
            binding: ConversationBinding(request: key, revision: 2),
            author: .origin, sessionHandle: ExactText("origin"), text: ExactText(""),
            contentRedacted: true, kind: .revision)
        try domain.applyConversation(ConversationEvent(sequence: 2,
            binding: redacted.binding, fact: .redactedRevision(redacted)), context: context)

        let store = try LivePresentationStore(localFixtureStore: domain, context: context)
        XCTAssertNil(store.historicalRequest(for: key, revision: 2))
    }

    func testShakeConversationUsesTheDomainAndOrdinaryViewModelAndCannotPrepareDelivery() throws {
        let library = SampleLibrary()
        library.populate()
        let fixture = try XCTUnwrap(library.fixture)
        let response = try XCTUnwrap(library.responses["sample-information-0"])
        let before = try XCTUnwrap(fixture.viewModel.conversation(for: response.key))
        response.chatDraft = "Inspect the exact local model"
        response.attachments = ["Local example"]
        response.sendLocalChat()
        let restored = try LivePresentationStore(localFixtureStore: fixture.domain, context: fixture.context)
        let thread = try XCTUnwrap(restored.conversation(for: response.key))
        XCTAssertEqual(thread.turns.count, before.turns.count + 1)
        let last = try XCTUnwrap(thread.turns.last)
        XCTAssertEqual(last.text, ExactText("Inspect the exact local model"))
        XCTAssertEqual(last.binding.request, response.key)
        XCTAssertEqual(last.files.first?.name, ExactText("Local example"))
        XCTAssertNil(last.operationID)
        XCTAssertEqual(thread.facts[last.id]?.delivered, false)
        XCTAssertNil(thread.facts[last.id]?.actedBy)
        XCTAssertTrue(try fixture.domain.snapshot(context: fixture.context).intents.isEmpty)
        XCTAssertTrue(try fixture.domain.snapshot(context: fixture.context).outbox.isEmpty)
        let state = try fixture.domain.conversationSnapshot(context: fixture.context)
        library.populate()
        XCTAssertEqual(try fixture.domain.conversationSnapshot(context: fixture.context).cursor, state.cursor)
        XCTAssertEqual(fixture.viewModel.conversation(for: response.key)?.turns, thread.turns)
    }

    func testRetainedFileUsesOriginalBytesAfterPickerSourceDisappearsAndRejectsAnIncompleteCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay"), personID: ExactText("person"), deviceID: ExactText("device"))
        let storage = try ConversationFileStorage(identity: identity, root: root)
        let source = root.appendingPathComponent("larger-than-inline.bin")
        let bytes = Data(repeating: 231, count: 3 * 1_048_576 + 17)
        try bytes.write(to: source)
        let file = try storage.retain(source)
        try FileManager.default.removeItem(at: source)
        let copy = try storage.fileURL(for: file)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(file.byteCount, UInt64(bytes.count))
        try storage.verify(copy, for: file)
        try Data(bytes.prefix(1024)).write(to: copy)
        XCTAssertThrowsError(try storage.verify(copy, for: file))
        let other = try ConversationFileStorage(identity: ProfileIdentity(trustedRelayAuthority: identity.trustedRelayAuthority,
            personID: ExactText("other-person"), deviceID: identity.deviceID), root: root)
        XCTAssertNotEqual(other.directory, storage.directory)
    }
    func testInlinePreviewRetainsExactBytesAndAccountRemovalLeavesAnotherAccountUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstIdentity = ProfileIdentity(trustedRelayAuthority: ExactText("relay"), personID: ExactText("first"), deviceID: ExactText("device"))
        let secondIdentity = ProfileIdentity(trustedRelayAuthority: ExactText("relay"), personID: ExactText("second"), deviceID: ExactText("device"))
        let first = try ConversationFileStorage(identity: firstIdentity, root: root)
        let second = try ConversationFileStorage(identity: secondIdentity, root: root)
        let bytes = Data("Exact original file text\n".utf8)
        let digest = ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let file = ConversationFile(id: ExactText("note"), name: ExactText("note.txt"), byteCount: UInt64(bytes.count), sha256: digest, content: .inline(bytes))
        let firstURL = try XCTUnwrap(first.cachedPreview(for: file))
        let secondURL = try XCTUnwrap(second.cachedPreview(for: file))
        XCTAssertEqual(firstURL.lastPathComponent, "note.txt")
        XCTAssertEqual(try Data(contentsOf: firstURL), bytes)
        XCTAssertEqual(try first.cachedPreview(for: file), firstURL)
        try first.removeAccountFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(try Data(contentsOf: secondURL), bytes)
    }

    func testRetainedCopiesKeepTheirBasenameAndOlderCopyReferencesRemainReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay"), personID: ExactText("person"), deviceID: ExactText("device"))
        let storage = try ConversationFileStorage(identity: identity, root: root)
        let source = root.appendingPathComponent("original.txt")
        let bytes = Data("Original picker bytes".utf8)
        try bytes.write(to: source)
        let retained = try storage.retain(source)
        let retainedURL = try XCTUnwrap(storage.cachedPreview(for: retained))
        XCTAssertEqual(retainedURL.lastPathComponent, "original.txt")
        let olderURL = storage.directory.appendingPathComponent("older-copy")
        try bytes.write(to: olderURL)
        let older = ConversationFile(id: ExactText("older"), name: ExactText("original.txt"), byteCount: retained.byteCount,
            sha256: retained.sha256, content: .localFile(ExactText("older-copy")))
        XCTAssertEqual(try storage.cachedPreview(for: older), olderURL)
        XCTAssertEqual(try Data(contentsOf: olderURL), bytes)
    }

    func testShakeExamplesIncludeRevisionArchiveDistinctFileFactsAndClosureWithoutOperations() throws {
        let library = SampleLibrary()
        library.populate()
        let fixture = try XCTUnwrap(library.fixture)
        let revised = try XCTUnwrap(library.responses["sample-approval-2"])
        let revision = try XCTUnwrap(fixture.viewModel.conversation(for: revised.key))
        XCTAssertEqual(revision.currentRevision, 2)
        XCTAssertNotNil(revision.answerDrafts?[1]?.inputs[ExactText("answer")]?.selectedActionID)
        XCTAssertTrue(fixture.viewModel.request(for: revised.key)?.body?.rawValue.contains("review before archiving") == true)
        let files = try XCTUnwrap(library.responses["sample-information-2"])
        let fileThread = try XCTUnwrap(fixture.viewModel.conversation(for: files.key))
        let turn = try XCTUnwrap(fileThread.turns.first { !$0.files.isEmpty })
        let file = try XCTUnwrap(turn.files.first)
        XCTAssertEqual(fileThread.facts[turn.id]?.fileTransfers[file.id], .transferred)
        XCTAssertEqual(fileThread.facts[turn.id]?.fileUses[file.id], .unusable(reason: ExactText("Fictional unsupported format")))
        let closed = try XCTUnwrap(library.responses["sample-completed-2"])
        XCTAssertEqual(fixture.viewModel.conversation(for: closed.key)?.terminal, .cleared)
        XCTAssertEqual(fixture.viewModel.conversation(for: closed.key)?.terminalAuthor, .origin)
        XCTAssertTrue(closed.isClosed)
        let before = try fixture.domain.conversationSnapshot(context: fixture.context)
        library.populate()
        XCTAssertEqual(try fixture.domain.conversationSnapshot(context: fixture.context).cursor, before.cursor)
        let state = try fixture.domain.snapshot(context: fixture.context)
        XCTAssertTrue(state.intents.isEmpty)
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertThrowsError(try fixture.domain.prepareDiscussion(ConversationBinding(request: revised.key, revision: 2), context: fixture.context))
    }

    func testServerReadPositionControlsUnreadAcrossForegroundAndCacheRelaunch() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = FilePendingActionPersistence(directoryURL: root)
        let domain = try ClientRepository(context: context, persistence: persistence)
        let request = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: request, revision: 1)
        let session = ExactText("session")
        func turn(_ id: String, _ author: ConversationAuthor, _ kind: ConversationTurn.Kind) -> ConversationTurn {
            ConversationTurn(id: ExactText(id), binding: binding, author: author, sessionHandle: session,
                text: ExactText("Turn \(id)"), inReplyTo: author == .person ? nil : ExactText("2"), kind: kind)
        }
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: session, payload: .null)), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(turn("2", .person, .discussion))), context: context)
        let model = try LivePresentationStore(store: domain, context: context)
        XCTAssertFalse(model.hasUnreadAgentReply(request), "The person's own turn does not light the marker.")

        // Foreground: the reply arrives while Chat is closed.
        try domain.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .turn(turn("3", .agent, .reply))), context: context)
        try model.refreshFromDurableStore()
        XCTAssertTrue(model.hasUnreadAgentReply(request))

        // Before the server reports read-position support, a view has no position to record.
        model.markConversationRead(request)
        XCTAssertTrue(model.hasUnreadAgentReply(request))
        try domain.applyConversation(ConversationEvent(sequence: 4,
            binding: ConversationBinding(request: request, revision: 0),
            fact: .readPosition(eventID: ExactText("read-3"), readThroughConversationSequence: 3)), context: context)
        try model.refreshFromDurableStore()
        XCTAssertFalse(model.hasUnreadAgentReply(request))

        func reopen(_ source: ClientRepository) async throws -> ClientRepository {
            let url = root.appendingPathComponent("server-cache.json")
            let cache = FileServerStateCache(identity: identity, fileURL: url)
            try await cache.save(ServerStateCacheSnapshot.make(identity: identity,
                from: source.snapshot(context: context), conversations: source.conversationSnapshot(context: context)))
            let reopenedCache = FileServerStateCache(identity: identity, fileURL: url)
            let cached = try await reopenedCache.load()
            let restored = try ClientRepository(context: context, persistence: persistence)
            try restored.restoreCachedServerState(try XCTUnwrap(cached).attentionDomainState(for: identity), context: context)
            return restored
        }
        let replayed = try await reopen(domain)
        let relaunched = try LivePresentationStore(store: replayed, context: context)
        XCTAssertFalse(relaunched.hasUnreadAgentReply(request))

        try replayed.applyConversation(ConversationEvent(sequence: 5, binding: binding,
            fact: .turn(turn("5", .origin, .reply))), context: context)
        let resumedStore = try await reopen(replayed)
        let resumed = try LivePresentationStore(store: resumedStore, context: context)
        XCTAssertTrue(resumed.hasUnreadAgentReply(request))
        // The relaunched store has not caught up with the server. Reading still shows at once.
        resumed.markConversationRead(request)
        await waitUntil { !resumed.hasUnreadAgentReply(request) }
        XCTAssertFalse(resumed.hasUnreadAgentReply(request),
                       "Reading during catch-up records the read immediately.")
        XCTAssertEqual(try resumedStore.conversationSnapshot(context: context)
            .pendingChatReadPositions.first?.readThroughConversationSequence, 5)
        try resumedStore.applyConversation(ConversationEvent(sequence: 6,
            binding: ConversationBinding(request: request, revision: 0),
            fact: .readPosition(eventID: ExactText("read-5"), readThroughConversationSequence: 5)), context: context)
        try resumed.refreshFromDurableStore()
        XCTAssertFalse(resumed.hasUnreadAgentReply(request))
    }

    func testOpeningAMessageDuringCatchUpQueuesItsReportAtOnce() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request"))
        let payload = try JSONValue.parse(Data(#"{"title":"A message"}"#.utf8))
        let previous = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        try previous.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1,
                sessionHandle: ExactText("session"))), context: context)
        let saved = try previous.snapshot(context: context)
        // A cold launch from the saved cache whose current inbox does not yet
        // include this request: catch-up has not confirmed it.
        let domain = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        try domain.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: saved.requests, remoteStates: [:], cursor: 1, conversationCursor: 0,
            conversations: [:], inboxView: nil, currentRequestKeys: []), context: context)
        let model = try LivePresentationStore(store: domain, context: context)
        let request = try XCTUnwrap(model.request(for: key))
        XCTAssertFalse(model.canUseCurrentServerState(for: key),
                       "The inbox has not caught up with the server yet.")

        model.reportMessageContentOpened(request)
        let opens = try domain.snapshot(context: context).pendingMessageOpens
        XCTAssertEqual(opens.map(\.requestKey), [key],
                       "Opening a message during catch-up queues its report at once.")
        XCTAssertEqual(opens.first?.requestRevision, request.requestRevision)
    }

    func testInboxChatMarkerNeedsAChatTurnAndKeepsClosedUnreadRepliesVisible() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let domain = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: key, revision: 1)
        let handle = ExactText("session")
        let payload = try JSONValue.parse(Data(#"{"title":"A message"}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: handle,
                eventID: ExactText("delivery-revision"),
                availability: .listening)), context: context)
        let emptyKey = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("empty-chat"))
        try domain.apply(RelayEvent(sequence: 2, body: .delivery(
            StoredRequest(key: emptyKey, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1,
                sessionHandle: ExactText("empty-session"))), context: context)
        let model = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(model.conversation(for: key)?.turns.first?.kind, .revision)
        XCTAssertNil(model.inboxRow(for: emptyKey)?.chatUnread,
                     "An opened session without turns does not display a Chat marker.")
        XCTAssertNil(model.inboxRow(for: key)?.chatUnread,
                     "A session with only request history does not display a Chat marker.")
        XCTAssertEqual(model.inboxRow(for: key)?.symbol, "envelope")

        let person = ConversationTurn(id: ExactText("person-turn"), binding: binding,
            author: .person, sessionHandle: handle, text: ExactText("Hello"), kind: .discussion)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .turn(person)), context: context)
        try model.refreshFromDurableStore()
        XCTAssertEqual(model.inboxRow(for: key)?.chatUnread, false)

        let agent = ConversationTurn(id: ExactText("agent-turn"), binding: binding,
            author: .agent, sessionHandle: handle, text: ExactText("Hi"),
            inReplyTo: person.id, kind: .reply)
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(agent)), context: context)
        try model.refreshFromDurableStore()
        XCTAssertEqual(model.inboxRow(for: key)?.chatUnread, true)
        model.markConversationRead(key)
        XCTAssertEqual(model.inboxRow(for: key)?.chatUnread, true,
                       "An unconfirmed tap cannot override server read state.")
        try domain.applyConversation(ConversationEvent(sequence: 3,
            binding: ConversationBinding(request: key, revision: 0),
            fact: .readPosition(eventID: ExactText("read-agent"), readThroughConversationSequence: 2)), context: context)
        try model.refreshFromDurableStore()
        XCTAssertEqual(model.inboxRow(for: key)?.chatUnread, false)

        let later = ConversationTurn(id: ExactText("later-agent-turn"), binding: binding,
            author: .agent, sessionHandle: handle, text: ExactText("One more thing"),
            inReplyTo: person.id, kind: .reply)
        try domain.applyConversation(ConversationEvent(sequence: 4, binding: binding,
            fact: .turn(later)), context: context)
        try domain.apply(RelayEvent(sequence: 3, body: .terminal(key, .answered, nil)), context: context)
        try model.refreshFromDurableStore()
        XCTAssertEqual(model.inboxRow(for: key)?.chatUnread, true,
                       "A closed request must still show an unseen agent reply.")
    }



    private struct FooterScenario {
        let context: ProfileContext
        let domain: ClientRepository
        let persistence: MemoryPendingActionPersistence
        let model: LivePresentationStore
        let binding: ConversationBinding
        let session: SendEligibilitySession
        let original: ConversationFile
    }

    private actor FooterGate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            released = true
            let pending = waiters
            waiters = []
            for continuation in pending { continuation.resume() }
        }
    }

    private func footerScenario(context supplied: ProfileContext? = nil) async throws -> FooterScenario {
        let context = supplied ?? ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("footer-person"),
            deviceID: ExactText("footer-device")), transportMode: .relay)
        let persistence = MemoryPendingActionPersistence()
        let domain = try ClientRepository(context: context, persistence: persistence)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"),
            messageID: ExactText("footer-chat"))
        let binding = ConversationBinding(request: key, revision: 1)
        let payload = try JSONValue.parse(Data(#"{"title":"Recovery chat"}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("handle"))), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .availability(sessionHandle: ExactText("handle"), .listening)), context: context)
        let session = SendEligibilitySession(identity: context.identity, key: key, payload: payload)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            await NativeRelayLifecycle.shared.deactivate()
            try? FileManager.default.removeItem(at: directory)
        }
        let confirmation = try await NativeRelayLifecycle.shared.confirmInProcessSessionForTesting(
            store: domain, context: context, session: session,
            serverStateCache: FileServerStateCache(identity: context.identity,
                fileURL: directory.appendingPathComponent("server-cache.json")))
        XCTAssertTrue(confirmation.relayConfirmed)
        let core = try NativeRelayCore(store: domain, context: context, session: session)
        let availability = NativeConversationAvailability()
        availability.confirm(for: context, conversationsUnavailable: false)
        let model = try LivePresentationStore(store: domain, context: context,
            conversationAvailability: availability, discussionSubmitter: { binding, expected, retained in
                XCTAssertEqual(expected, context)
                return try await core.submitDiscussion(binding, using: session,
                    originURL: URL(string: "https://relay.example:9443/origin/v1")!, retainedFile: retained)
            })
        XCTAssertTrue(model.canSendDiscussion(for: key), "Use actual confirmed/listening eligibility before submitting")
        let bytes = Data("Saved attachment".utf8)
        let original = ConversationFile(id: ExactText("footer-file"), name: ExactText("note.txt"),
            byteCount: UInt64(bytes.count),
            sha256: ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()),
            content: .inline(bytes))
        XCTAssertTrue(model.updateConversation(for: key, revision: 1, text: "Recover this message", files: [original]))
        return FooterScenario(context: context, domain: domain, persistence: persistence, model: model, binding: binding,
            session: session, original: original)
    }

    private func submitFooter(_ scenario: FooterScenario, key: RequestKey? = nil) async {
        let completed = expectation(description: "Actual discussion submit returned")
        scenario.model.sendDiscussion(for: key ?? scenario.binding.request, revision: 1,
            onResult: { _ in completed.fulfill() })
        await fulfillment(of: [completed], timeout: 5)
    }

    private func recoverFooter(_ scenario: FooterScenario) throws {
        let operation = try XCTUnwrap(scenario.session.discussionOperations.first)
        let turn = ConversationTurn(id: ExactText("recovered-turn"), binding: scenario.binding, author: .person,
            sessionHandle: ExactText("handle"), text: ExactText("Recover this message"),
            operationID: operation, files: [scenario.original], kind: .discussion)
        var sequence = try scenario.domain.conversationSnapshot(context: scenario.context).cursor
        sequence += 1
        try scenario.domain.applyConversation(ConversationEvent(sequence: sequence, binding: scenario.binding,
            fact: .turn(turn)), context: scenario.context)
        try scenario.domain.applyConversation(ConversationEvent(sequence: sequence + 1, binding: scenario.binding,
            fact: .delivered(turn: turn.id)), context: scenario.context)
    }

    private func assertRecoveredFooter(_ scenario: FooterScenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let thread = try XCTUnwrap(scenario.model.conversation(for: scenario.binding.request), file: file, line: line)
        let turn = try XCTUnwrap(thread.turns.first(where: { $0.operationID == scenario.session.discussionOperations.first }), file: file, line: line)
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: thread.facts[turn.id] ?? ConversationTurnFacts(),
            availability: thread.latestAvailabilityObservation, hasReply: false, nowMilliseconds: 0), .delivered, file: file, line: line)
        XCTAssertEqual(ConversationAvailabilityNoticePresentation.notice(for: thread.latestAvailabilityObservation), .connected, file: file, line: line)
        XCTAssertTrue(scenario.model.conversationDraft(for: scenario.binding.request, revision: 1).text.rawValue.isEmpty, file: file, line: line)
        XCTAssertTrue(scenario.model.conversationDraft(for: scenario.binding.request, revision: 1).files.isEmpty, file: file, line: line)
        XCTAssertEqual(turn.files.map(\.name), [scenario.original.name], file: file, line: line)
        XCTAssertNil(scenario.model.conversationError(for: scenario.binding.request, revision: 1), file: file, line: line)
        XCTAssertEqual(scenario.session.discussionOperations.count, 1, "Automatic recovery must not send again", file: file, line: line)
    }

    func testUnresolvedFooterClearsAfterSameOperationDeliveryThroughSynchronousRefresh() async throws {
        let scenario = try await footerScenario()
        await submitFooter(scenario)
        XCTAssertTrue(scenario.model.conversationError(for: scenario.binding.request, revision: 1)?.contains("Sending") == true)
        try recoverFooter(scenario)
        try scenario.model.refreshFromDurableStore()
        try assertRecoveredFooter(scenario)
    }

    func testUnresolvedFooterClearsWhenAutomaticPreparedAdoptionDeliversSameOperation() async throws {
        let scenario = try await footerScenario()
        await submitFooter(scenario)
        XCTAssertTrue(scenario.model.conversationError(for: scenario.binding.request, revision: 1)?.contains("Sending") == true)
        // Render the production panel with this real presentation store, using
        // only the synthetic authenticated transport and this test's window.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        let appeared = expectation(description: "Production chat panel appeared")
        let panel = ConversationPanel(store: scenario.model, key: scenario.binding.request,
            sender: "Example sender", title: "Recovery chat")
            .onAppear { appeared.fulfill() }
        window.rootViewController = UIHostingController(rootView: panel)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        await fulfillment(of: [appeared], timeout: 5)
        captureFooterPanel(window, name: "footer-before-automatic-recovery")
        let adopted = expectation(description: "Automatic live adoption received Delivered")
        var observed = false
        scenario.model.notificationProjectionDidChange = {
            guard !observed, let thread = scenario.model.conversation(for: scenario.binding.request),
                  thread.facts[ExactText("recovered-turn")]?.delivered == true else { return }
            observed = true
            adopted.fulfill()
        }
        scenario.model.startObserving()
        defer { scenario.model.stopObserving() }
        try recoverFooter(scenario)
        await fulfillment(of: [adopted], timeout: 5)
        await Task.yield() // Let the production panel process its observed update before capturing it.
        captureFooterPanel(window, name: "footer-after-automatic-recovery")
        try assertRecoveredFooter(scenario)
    }

    private func captureFooterPanel(_ window: UIWindow, name: String) {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testConnectedRefreshPreservesGenuinelyPendingFooterAndExactFrozenSend() async throws {
        let scenario = try await footerScenario()
        await submitFooter(scenario)
        let before = try XCTUnwrap(scenario.domain.conversationSnapshot(context: scenario.context).threads[scenario.binding.request]?.drafts[1])
        try scenario.model.refreshFromDurableStore()
        let port = AttentionDomainPort(store: scenario.domain)
        _ = try await scenario.model.adoptForLiveUpdates(port.observe(context: port.context))
        XCTAssertTrue(scenario.model.conversationError(for: scenario.binding.request, revision: 1)?.contains("Sending") == true)
        let after = try XCTUnwrap(scenario.domain.conversationSnapshot(context: scenario.context).threads[scenario.binding.request]?.drafts[1])
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.disposition, .outcomeUnknown(try XCTUnwrap(before.operationID)))
        XCTAssertNotNil(after.wireFrame)
    }

    func testDefiniteRejectionFooterAndDraftSurviveBothAdoptionPaths() async throws {
        let scenario = try await footerScenario()
        scenario.session.discussionResult = .rejected(reason: ExactText("temporarily refused"))
        await submitFooter(scenario)
        let reason = scenario.model.conversationError(for: scenario.binding.request, revision: 1)
        XCTAssertEqual(reason, "Message not sent. Your text and files are saved.")
        XCTAssertEqual(scenario.model.conversationDraft(for: scenario.binding.request, revision: 1).disposition,
                       .rejected(ExactText("temporarily refused")))
        try scenario.model.refreshFromDurableStore()
        let port = AttentionDomainPort(store: scenario.domain)
        _ = try await scenario.model.adoptForLiveUpdates(port.observe(context: port.context))
        XCTAssertEqual(scenario.model.conversationError(for: scenario.binding.request, revision: 1), reason)
        XCTAssertEqual(scenario.model.conversationDraft(for: scenario.binding.request, revision: 1).files.count, 1)
        XCTAssertEqual(scenario.model.conversationDraft(for: scenario.binding.request, revision: 1).text, ExactText("Recover this message"))
    }

    func testRecoveredOperationDoesNotClearAnotherChatNoticeOrFileError() async throws {
        let scenario = try await footerScenario()
        await submitFooter(scenario)
        let other = RequestKey(accountScope: scenario.context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("other"))
        let binding = ConversationBinding(request: other, revision: 1)
        try scenario.domain.apply(RelayEvent(sequence: 2,
            body: .delivery(StoredRequest(key: other, originalPayload: .null), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("other-handle"))), context: scenario.context)
        let sequence = try scenario.domain.conversationSnapshot(context: scenario.context).cursor + 1
        try scenario.domain.applyConversation(ConversationEvent(sequence: sequence, binding: binding,
            fact: .availability(sessionHandle: ExactText("other-handle"), .listening)), context: scenario.context)
        try scenario.model.refreshFromDurableStore()
        XCTAssertTrue(scenario.model.updateConversation(for: other, revision: 1, text: "Other pending send"))
        await submitFooter(scenario, key: other)
        let otherNotice = scenario.model.conversationError(for: other, revision: 1)
        XCTAssertTrue(otherNotice?.contains("Sending") == true)
        try recoverFooter(scenario)
        try scenario.model.refreshFromDurableStore()
        XCTAssertNil(scenario.model.conversationError(for: scenario.binding.request, revision: 1))
        XCTAssertEqual(scenario.model.conversationError(for: other, revision: 1), otherNotice)
        scenario.model.reportConversationImportError(NSError(domain: "FileImport", code: 1), for: other, revision: 1)
        let importError = scenario.model.conversationError
        try scenario.model.refreshFromDurableStore()
        XCTAssertEqual(scenario.model.conversationError, importError)
        XCTAssertNotNil(importError)
    }

    func testLateTransportCallbackCannotRestoreSendingAfterDeliveryOrClearNewContextNotice() async throws {
        let scenario = try await footerScenario()
        let entered = expectation(description: "Transport awaits its original response")
        let release = FooterGate()
        scenario.session.beforeDiscussionResult = { _ in entered.fulfill(); await release.wait() }
        scenario.model.sendDiscussion(for: scenario.binding.request, revision: 1)
        await fulfillment(of: [entered], timeout: 5)
        let newContext = ProfileContext(identity: scenario.context.identity, transportMode: .relay)
        let replacement = try await footerScenario(context: newContext)
        await submitFooter(replacement)
        let replacementNotice = replacement.model.conversationError(for: replacement.binding.request, revision: 1)
        try recoverFooter(scenario)
        try scenario.model.refreshFromDurableStore()
        let finished = expectation(description: "The original submit task ended")
        withObservationTracking {
            _ = scenario.model.isSendingDiscussion(for: scenario.binding.request, revision: 1)
        } onChange: { finished.fulfill() }
        await release.release()
        await fulfillment(of: [finished], timeout: 5)
        try assertRecoveredFooter(scenario)
        XCTAssertEqual(replacement.model.conversationError(for: replacement.binding.request, revision: 1), replacementNotice)
        XCTAssertTrue(replacementNotice?.contains("Sending") == true)
    }


    func testEditRejectedDiscussionRetiresOnlyItsNoticeAndRestoresOriginalDraft() async throws {
        let scenario = try await footerScenario()
        scenario.session.discussionResult = .rejected(reason: ExactText("temporarily refused"))
        await submitFooter(scenario)
        let failed = scenario.model.conversationDraft(for: scenario.binding.request, revision: 1)
        XCTAssertNotNil(failed.operationID)
        XCTAssertNotNil(failed.wireFrame)
        XCTAssertEqual(scenario.model.conversationError(for: scenario.binding.request, revision: 1),
                       "Message not sent. Your text and files are saved.")

        let other = RequestKey(accountScope: scenario.context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("edit-sibling"))
        let binding = ConversationBinding(request: other, revision: 1)
        try scenario.domain.apply(RelayEvent(sequence: 2,
            body: .delivery(StoredRequest(key: other, originalPayload: .null), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("other-handle"))), context: scenario.context)
        let sequence = try scenario.domain.conversationSnapshot(context: scenario.context).cursor + 1
        try scenario.domain.applyConversation(ConversationEvent(sequence: sequence, binding: binding,
            fact: .availability(sessionHandle: ExactText("other-handle"), .listening)), context: scenario.context)
        try scenario.model.refreshFromDurableStore()
        XCTAssertTrue(scenario.model.updateConversation(for: other, revision: 1, text: "Keep this other send pending"))
        scenario.session.discussionResult = .unresolved
        await submitFooter(scenario, key: other)
        let otherNotice = scenario.model.conversationError(for: other, revision: 1)
        let otherDraft = scenario.model.conversationDraft(for: other, revision: 1)
        XCTAssertTrue(otherNotice?.contains("Sending") == true)

        scenario.persistence.failNextCommit()
        scenario.model.editRejectedDiscussion(for: scenario.binding.request, revision: 1)
        XCTAssertEqual(scenario.model.conversationDraft(for: scenario.binding.request, revision: 1), failed,
                       "A failed Edit must keep the frozen rejection and original files")
        XCTAssertNotNil(scenario.model.conversationError)
        scenario.model.editRejectedDiscussion(for: scenario.binding.request, revision: 1)
        let restored = scenario.model.conversationDraft(for: scenario.binding.request, revision: 1)
        XCTAssertEqual(restored.disposition, .saved)
        XCTAssertEqual(restored.text, failed.text)
        XCTAssertEqual(restored.files, failed.files)
        XCTAssertNil(restored.operationID)
        XCTAssertNil(restored.wireFrame)
        XCTAssertNil(scenario.model.conversationError(for: scenario.binding.request, revision: 1))
        XCTAssertEqual(scenario.model.conversationError(for: other, revision: 1), otherNotice)
        try scenario.model.refreshFromDurableStore()
        let port = AttentionDomainPort(store: scenario.domain)
        _ = try await scenario.model.adoptForLiveUpdates(port.observe(context: port.context))
        XCTAssertNil(scenario.model.conversationError(for: scenario.binding.request, revision: 1))
        XCTAssertEqual(scenario.model.conversationError(for: other, revision: 1), otherNotice)
        XCTAssertEqual(scenario.session.discussionOperations.count, 2, "Edit never sends again")

        // A later successful Edit must also preserve an unrelated import error.
        scenario.session.discussionResult = .rejected(reason: ExactText("temporarily refused"))
        await submitFooter(scenario)
        scenario.model.reportConversationImportError(NSError(domain: "OtherFileImport", code: 1),
            for: other, revision: 1)
        let importError = scenario.model.conversationError
        XCTAssertNotNil(importError)
        scenario.model.editRejectedDiscussion(for: scenario.binding.request, revision: 1)
        XCTAssertEqual(scenario.model.conversationError, importError)
        XCTAssertEqual(scenario.model.conversationDraft(for: other, revision: 1), otherDraft)
        XCTAssertEqual(scenario.session.discussionOperations.count, 3)
        try scenario.model.refreshFromDurableStore()
        _ = try await scenario.model.adoptForLiveUpdates(port.observe(context: port.context))
        XCTAssertEqual(scenario.model.conversationError, importError)
        XCTAssertEqual(scenario.model.conversationDraft(for: scenario.binding.request, revision: 1).disposition, .saved)
    }


    func testAcceptedReceiptRetiresPendingNoticeBeforeTurnReplay() async throws {
        let scenario = try await footerScenario()
        await submitFooter(scenario)
        XCTAssertTrue(scenario.model.conversationError(for: scenario.binding.request, revision: 1)?.contains("Sending") == true)
        let operation = try XCTUnwrap(scenario.session.discussionOperations.first)
        let before = scenario.model.conversationDraft(for: scenario.binding.request, revision: 1)
        try scenario.domain.markDiscussionAccepted(scenario.binding, operation: operation,
            turn: ExactText("receipt-only"), context: scenario.context)
        try scenario.model.refreshFromDurableStore()
        XCTAssertNil(scenario.model.conversationError(for: scenario.binding.request, revision: 1))
        let accepted = scenario.model.conversationDraft(for: scenario.binding.request, revision: 1)
        XCTAssertEqual(accepted.disposition, .acceptedPendingReplay(operation, ExactText("receipt-only")))
        XCTAssertEqual(accepted.operationID, before.operationID)
        XCTAssertEqual(accepted.wireFrame, before.wireFrame)
        XCTAssertEqual(accepted.files, before.files)
        XCTAssertEqual(ConversationSubmittedText.composerText(for: accepted), "")
        XCTAssertFalse(scenario.model.conversation(for: scenario.binding.request)?.turns.contains(where: {
            $0.operationID == operation
        }) ?? true, "This exercises the receipt branch before the turn replays")
        let port = AttentionDomainPort(store: scenario.domain)
        _ = try await scenario.model.adoptForLiveUpdates(port.observe(context: port.context))
        XCTAssertNil(scenario.model.conversationError(for: scenario.binding.request, revision: 1))
        XCTAssertEqual(scenario.session.discussionOperations.count, 1)
    }

    func testImportErrorPresentBeforeAcceptanceSurvivesBothAdoptionPaths() async throws {
        let scenario = try await footerScenario()
        await submitFooter(scenario)
        scenario.model.reportConversationImportError(NSError(domain: "IndependentImport", code: 1),
            for: scenario.binding.request, revision: 1)
        let importError = scenario.model.conversationError
        XCTAssertNotNil(importError)
        try recoverFooter(scenario)
        try scenario.model.refreshFromDurableStore()
        XCTAssertEqual(scenario.model.conversationError, importError)
        XCTAssertEqual(scenario.model.conversationError(for: scenario.binding.request, revision: 1), importError)
        let port = AttentionDomainPort(store: scenario.domain)
        _ = try await scenario.model.adoptForLiveUpdates(port.observe(context: port.context))
        XCTAssertEqual(scenario.model.conversationError, importError)
        XCTAssertTrue(scenario.model.conversationDraft(for: scenario.binding.request, revision: 1).text.rawValue.isEmpty)
        XCTAssertEqual(scenario.session.discussionOperations.count, 1)
    }

    func testEarlierAcceptedTurnDoesNotClearNewerPendingOperationInSameChat() async throws {
        let scenario = try await footerScenario()
        await submitFooter(scenario)
        try recoverFooter(scenario)
        try scenario.model.refreshFromDurableStore()
        XCTAssertNil(scenario.model.conversationError(for: scenario.binding.request, revision: 1))
        XCTAssertTrue(scenario.model.updateConversation(for: scenario.binding.request, revision: 1,
            text: "A newer pending send", files: [scenario.original]))
        await submitFooter(scenario)
        let newer = scenario.model.conversationDraft(for: scenario.binding.request, revision: 1)
        XCTAssertNotEqual(newer.operationID, scenario.session.discussionOperations.first)
        XCTAssertEqual(newer.disposition, .outcomeUnknown(try XCTUnwrap(newer.operationID)))
        let pendingNotice = scenario.model.conversationError(for: scenario.binding.request, revision: 1)
        XCTAssertTrue(pendingNotice?.contains("Sending") == true)
        try scenario.model.refreshFromDurableStore()
        let port = AttentionDomainPort(store: scenario.domain)
        _ = try await scenario.model.adoptForLiveUpdates(port.observe(context: port.context))
        XCTAssertEqual(scenario.model.conversationError(for: scenario.binding.request, revision: 1), pendingNotice)
        XCTAssertEqual(scenario.model.conversationDraft(for: scenario.binding.request, revision: 1), newer)
        XCTAssertEqual(scenario.session.discussionOperations.count, 2)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The condition did not become true.")
    }
}

private final class FailOncePendingActionPersistence: PendingActionPersistence, @unchecked Sendable {
    private let backing: FilePendingActionPersistence
    private let lock = NSLock()
    private var failNextWrite = false

    init(backing: FilePendingActionPersistence) {
        self.backing = backing
    }

    func failNextCommit() {
        lock.lock()
        failNextWrite = true
        lock.unlock()
    }

    func load(identity: ProfileIdentity) throws -> Data? {
        try backing.load(identity: identity)
    }

    func commit(_ data: Data, identity: ProfileIdentity) throws {
        lock.lock()
        let shouldFail = failNextWrite
        failNextWrite = false
        lock.unlock()
        if shouldFail {
            throw AttentionStoreError.persistence("Injected pre-replacement test write failure.")
        }
        try backing.commit(data, identity: identity)
    }
}


// Uses the ordinary inbox and conversation checkpoint path to establish a
// current authenticated projection; it never supplies a profile-wide listener.
private final class SendEligibilitySession: AuthenticatedInboxPagingSession,
    AuthenticatedConversationFileSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    var discussionResult: DiscussionOperationResult = .unresolved
    var discussionOperations: [UUID] = []
    var beforeDiscussionResult: (@Sendable (UUID) async -> Void)?
    private let inbox: ReplyCheckpointSession

    init(identity: ProfileIdentity, key: RequestKey, payload: JSONValue) {
        authenticatedIdentity = identity
        inbox = ReplyCheckpointSession(identity: identity, key: key, payload: payload)
    }

    func inboxRequest(_ request: Data, ref: String) async throws -> Data {
        try await inbox.inboxRequest(request, ref: ref)
    }
    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        try await inbox.resync(request, consume: consume)
    }
    func acknowledge(_ request: Data) async throws {}
    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        .unresolved
    }
    func openConversation(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        let since = try JSONValue.parse(request).uniqueValue(named: "since")?.integerValue ?? 0
        try await consume(Data(#"{"v":1,"type":"ok","ref":"native-conversation-sync","origin_https_port":9443}"#.utf8))
        try await consume(Data("{\"v\":1,\"type\":\"conversation_resynced\",\"conversation_seq\":\(since)}".utf8))
    }
    func acknowledgeConversation(_ request: Data) async throws {}
    func conversationFileLimits(originURL: URL) async throws -> ConversationFileLimits {
        ConversationFileLimits(inlineDecodedBytes: 1_048_576, uploadCap: nil)
    }
    func uploadConversationFile(_ file: ConversationFile, from source: URL, binding: ConversationBinding,
        operationID: UUID, limits: ConversationFileLimits, originURL: URL) async throws -> ConversationFile {
        throw ConversationError.fileMismatch // These notice tests send small inline files.
    }
    func sendDiscussion(_ frame: Data, operationID: UUID) async -> DiscussionOperationResult {
        discussionOperations.append(operationID)
        await beforeDiscussionResult?(operationID)
        return discussionResult
    }
}
