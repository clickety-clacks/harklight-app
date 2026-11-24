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
    func testHandoffCaptionContractRequiresSameTurnEvidenceAndConfirmedIncapableReceipt() throws {
        let binding = ConversationBinding(request: RequestKey(accountScope: ExactText("person"),
            senderID: ExactText("Studio"), messageID: ExactText("item")), revision: 1)
        let turn = ConversationTurn(id: ExactText("sent"), binding: binding, author: .person,
            sessionHandle: ExactText("item"), text: ExactText("Hello"), kind: .discussion)
        let cases: [(String, ConversationSentChatStatusPresentation.Delivery)] = [
            (#"{"delivered":true,"acted":true}"#, .sending),
            (#"{"delivered":true,"ack2_expected":null}"#, .sending),
            (#"{"delivered":true,"ack2_expected":true}"#, .sending),
            (#"{"delivered":true,"ack2_expected":false}"#, .sending),
            (#"{"delivered":true,"ack2_expected":false,"listener_received":false}"#, .sending),
            (#"{"delivered":true,"ack2_expected":false,"listener_received":true}"#, .deliveredAck),
            (#"{"delivered":true,"listener_received":true}"#, .sending),
            (#"{"delivered":true,"legacy_caption":true}"#, .delivered),
            (#"{"delivered":true,"legacy_caption":false}"#, .sending),
            (#"{"delivered":true,"legacy_caption":null}"#, .sending),
            (#"{"delivered":false,"acted":true}"#, .sent),
            (#"{"delivered":true,"outcome":"not_handed","acted":true,"agent_seen":true}"#, .deliveredAck),
            (#"{"delivered":true,"outcome":"not_handed","acted":true,"agent_acted":true}"#, .deliveredAck),
            (#"{"delivered":true,"outcome":"not_handed","acted":true,"legacy_caption":true}"#, .notDelivered("")),
            (#"{"delivered":true,"outcome":"not_handed","reason":"Try later"}"#, .notDelivered("Try later")),
            (#"{"delivered":true,"outcome":"handed","rerouted":true,"agent":"Release"}"#, .deliveredTo("Release"))
        ]
        for (wire, expected) in cases {
            let delivery = try XCTUnwrap(APIEntry(json: receiptJSON(wire)).delivery)
            var facts = ConversationTurnFacts(acceptedAtMilliseconds: 10)
            facts.personDelivery = delivery
            facts.delivered = delivery.delivered ?? false
            // The ordinary projection supplies the existing ack2 fact.
            switch delivery.outcome {
            case "handed": facts.deliveryAck2 = .handed(atMilliseconds: 10,
                rerouted: delivery.rerouted ?? false, acknowledgerSystem: nil, acknowledgerAgent: delivery.agent)
            case "not_handed": facts.deliveryAck2 = .notHanded(atMilliseconds: 10,
                reason: delivery.reason ?? ExactText(""), acknowledgerSystem: nil, acknowledgerAgent: delivery.agent)
            default: break
            }
            let status = ConversationSentChatStatusPresentation.delivery(for: turn, facts: facts,
                hasReply: false, conversationAgentName: "Studio", nowMilliseconds: 9_000_000,
                personFeed: true, handoffCaptions: true)
            XCTAssertEqual(status, expected, wire)
            if delivery.outcome == "not_handed" {
                XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: turn, facts: facts,
                    hasReply: true, conversationAgentName: "Studio", nowMilliseconds: 9_000_000,
                    personFeed: true, handoffCaptions: true), .deliveredAck)
                XCTAssertEqual(facts.personDelivery?.outcome, "not_handed", "A reply never rewrites the receipt.")
            }
        }
        var state = ConversationState()
        try state.apply(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: turn.sessionHandle, payload: .null)))
        var thread = try XCTUnwrap(state.threads[binding.request])
        thread.chatNeverCloses = true
        func reply(_ author: ConversationAuthor, to target: String) -> ConversationTurn {
            ConversationTurn(id: ExactText("reply"), binding: binding, author: author,
                sessionHandle: turn.sessionHandle, text: ExactText("Reply"),
                inReplyTo: ExactText(target), kind: .reply)
        }
        thread.turns = [turn, reply(.origin, to: "other"), reply(.server, to: "sent")]
        XCTAssertFalse(ConversationSentChatStatusPresentation.replyTargets(in: thread).contains(turn.id))
        thread.turns.append(reply(.origin, to: "sent"))
        XCTAssertTrue(ConversationSentChatStatusPresentation.replyTargets(in: thread).contains(turn.id))
        var served = ConversationTurnFacts()
        served.delivered = true
        for state: ConversationAvailability in [.listening, .notListening(lastDetachedAt: nil), .gone,
                                               .unsupported(reason: ExactText("old"))] {
            let availability = ConversationAvailabilityObservation(state: state)
            XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: turn, facts: served,
                availability: availability, hasReply: false, conversationAgentName: "Studio",
                nowMilliseconds: 9_000_000, personFeed: true, handoffCaptions: true),
                state == .gone || state == .unsupported(reason: ExactText("old")) ? .noOneWillGetThis : .sending)
        }
    }

    func testHandoffFeatureRefreshIsConnectionScopedAndPreservesOlderServerHistory() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let model = ServerModelV2Store(fileURL: nil)
        let item = try JSONValue.parse(Data(#"{"item_id":"item","rev":1,"sender":"Studio","request_revision":1,"message":{"title":"Hello","body":"Message"},"files":[],"seen":false,"chat":{"available":true,"started":true},"rank":{"key":"a","section":"current"}}"#.utf8))
        try model.apply([.init(rev: 1, kind: "item", data: Data(item.jsonString.utf8))], cursor: 1)
        try model.apply(APIEntriesPage(json: JSONValue.parse(Data(#"{"rev":1,"entries":[],"older":false}"#.utf8))), of: ExactText("item"))
        let entry = try receiptJSON(#"{"delivered":true,"acted":true}"#)
        try model.apply([.init(rev: 2, kind: "entry", data: Data(entry.jsonString.utf8))], cursor: 2)
        func me(_ features: String) throws -> APIMe {
            try APIMe(json: JSONValue.parse(Data(features.utf8)))
        }
        let older = try me(#"{}"#) // Server 0.2.5 has no feature signal.
        let supporting = try me(#"{"features":{"handoff_captions":true}}"#)
        let presentation = ServerModelV2Presentation(savedMe: older)
        func projected(_ presentation: ServerModelV2Presentation) throws -> ConversationThread {
            try XCTUnwrap(presentation.cachedState(model.snapshot, identity: identity).conversations.values.first)
        }
        func caption(_ thread: ConversationThread) throws -> ConversationSentChatStatusPresentation.Delivery {
            let turn = try XCTUnwrap(thread.turns.first)
            return ConversationSentChatStatusPresentation.delivery(for: turn,
                facts: try XCTUnwrap(thread.facts[turn.id]), hasReply: false,
                conversationAgentName: "Studio", nowMilliseconds: 10,
                personFeed: thread.chatNeverCloses == true, handoffCaptions: thread.handoffCaptions == true)
        }
        XCTAssertEqual(try caption(projected(presentation)), .delivered)
        presentation.apply(supporting)
        XCTAssertEqual(try caption(projected(presentation)), .sending)
        let saved = ServerModelV2Presentation(savedMe: supporting)
        XCTAssertEqual(try caption(projected(saved)), .sending)
        let oldEntry = try receiptJSON(#"{"delivered":true,"legacy_caption":true}"#, rev: 3)
        try model.apply([.init(rev: 3, kind: "entry", data: Data(oldEntry.jsonString.utf8))], cursor: 3)
        let history = try projected(saved)
        XCTAssertEqual(try caption(history), .delivered)
        let historyTurn = try XCTUnwrap(history.turns.first)
        XCTAssertEqual(ConversationSentChatStatusPresentation.delivery(for: historyTurn,
            facts: try XCTUnwrap(history.facts[historyTurn.id]),
            availability: .init(state: .gone), hasReply: false, conversationAgentName: "Studio",
            nowMilliseconds: 10, personFeed: true, handoffCaptions: true), .delivered)
        // A second account/Server connection gets only its own /me, not a global switch.
        let other = ServerModelV2Presentation(savedMe: older)
        XCTAssertFalse(try XCTUnwrap(projected(other).handoffCaptions))
        presentation.apply(try me(#"{"features":{"handoff_captions":false}}"#))
        XCTAssertFalse(try XCTUnwrap(projected(presentation).handoffCaptions))
    }


    private func receiptJSON(_ delivery: String, rev: UInt64 = 2) throws -> JSONValue {
        try JSONValue.parse(Data("""
        {"entry_id":"sent","item_id":"item","rev":\(rev),"position":1,
         "kind":"reply","author":"person","at_ms":10,"request_revision":1,
         "text":"Hello","files":[],"delivery":\(delivery)}
        """.utf8))
    }

    private func receiptStatus(_ thread: ConversationThread, hasReply: Bool = false,
                               availability: ConversationAvailabilityObservation? = nil)
        throws -> ConversationSentChatStatusPresentation.Delivery {
        let turn = try XCTUnwrap(thread.turns.first)
        return ConversationSentChatStatusPresentation.delivery(for: turn,
            facts: try XCTUnwrap(thread.facts[turn.id]), availability: availability,
            hasReply: hasReply, conversationAgentName: "Studio", nowMilliseconds: 9_000_000,
            personFeed: thread.chatNeverCloses == true)
    }

    func testPersonFeedDeliveryDecodesOptionalAndFutureOutcomes() throws {
        for fields in ["", #", "outcome":null"#, #", "outcome":"future""#] {
            let entry = try APIEntry(json: receiptJSON(#"{"delivered":true,"acted":true\#(fields)}"#))
            XCTAssertEqual(entry.entryID, ExactText("sent"))
            XCTAssertEqual(entry.delivery?.delivered, true)
            let restored = try JSONDecoder().decode(APIEntry.self, from: JSONEncoder().encode(entry))
            XCTAssertEqual(restored, entry)
        }
        let entry = try APIEntry(json: receiptJSON(
            #"{"outcome":"not_handed","reason":"Try later","agent":"Release","rerouted":true}"#))
        XCTAssertEqual(entry.delivery?.outcome, "not_handed")
        XCTAssertEqual(entry.delivery?.reason, ExactText("Try later"))
        XCTAssertEqual(entry.delivery?.agent, ExactText("Release"))
        XCTAssertEqual(entry.delivery?.rerouted, true)
    }

    func testPersonFeedHandoffUpdatesLiveAndAfterReopeningOldCache() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let store = ServerModelV2Store(fileURL: url)
        let item = try JSONValue.parse(Data(#"{"item_id":"item","rev":1,"sender":"Studio","request_revision":1,"message":{"title":"Hello","body":"Message"},"files":[],"seen":false,"chat":{"available":true,"started":true},"rank":{"key":"a","score":1,"section":"current"}}"#.utf8))
        try store.apply([.init(rev: 1, kind: "item", data: Data(item.jsonString.utf8))], cursor: 1)
        let page = try APIEntriesPage(json: JSONValue.parse(Data(#"{"rev":1,"entries":[],"older":false}"#.utf8)))
        try store.apply(page, of: ExactText("item"))
        func apply(_ delivery: String, rev: UInt64, to target: ServerModelV2Store) throws {
            let json = try receiptJSON(delivery, rev: rev)
            try target.apply([.init(rev: rev, kind: "entry", data: Data(json.jsonString.utf8))], cursor: rev)
        }
        func thread(_ target: ServerModelV2Store) throws -> ConversationThread {
            try XCTUnwrap(ServerModelV2Projection.cachedState(target.snapshot, identity: identity).conversations.values.first)
        }
        // This saves exactly the delivery fields written before handoff outcomes existed.
        try apply(#"{"delivered":true,"acted":true}"#, rev: 2, to: store)
        let old = ServerModelV2Store(fileURL: url)
        XCTAssertEqual(old.snapshot.orderedEntries(of: ExactText("item")).count, 1)
        XCTAssertEqual(try receiptStatus(thread(old)), .delivered)
        try apply(#"{"delivered":true,"acted":true,"outcome":"not_handed","reason":"Agent unavailable","agent":"Studio"}"#, rev: 3, to: old)
        let negative = try thread(old)
        XCTAssertEqual(negative.facts[ExactText("sent")]?.deliveryAck2,
            .notHanded(atMilliseconds: 10, reason: ExactText("Agent unavailable"),
                       acknowledgerSystem: nil, acknowledgerAgent: ExactText("Studio")))
        XCTAssertNil(negative.facts[ExactText("sent")]?.actedBy)
        XCTAssertEqual(try receiptStatus(negative), .notDelivered("Agent unavailable"))
        let reopened = ServerModelV2Store(fileURL: url)
        XCTAssertEqual(try receiptStatus(thread(reopened)), .notDelivered("Agent unavailable"))
        try apply(#"{"delivered":true,"outcome":"handed","agent":"Release","rerouted":true}"#, rev: 4, to: reopened)
        XCTAssertEqual(try receiptStatus(thread(reopened)), .deliveredTo("Release"))
        XCTAssertEqual(try receiptStatus(thread(ServerModelV2Store(fileURL: url))), .deliveredTo("Release"))
        XCTAssertEqual(reopened.snapshot.orderedEntries(of: ExactText("item")).count, 1)
        let rows = ServerModelV2Projection.cachedState(reopened.snapshot, identity: identity).inboxView?.listItems
        XCTAssertEqual(rows?.map(\.kind), [.message], "Handoff changes do not manufacture an inbox reply row.")
    }

    func testPersonFeedCaptionPrecedenceKeepsLegacyReceiptRules() throws {
        let binding = ConversationBinding(request: RequestKey(accountScope: ExactText("person"),
            senderID: ExactText("Studio"), messageID: ExactText("item")), revision: 1)
        let turn = ConversationTurn(id: ExactText("sent"), binding: binding, author: .person,
            sessionHandle: ExactText("item"), text: ExactText("Hello"), kind: .discussion)
        var facts = ConversationTurnFacts()
        facts.delivered = true
        facts.deliveryAck2 = .notHanded(atMilliseconds: 10, reason: ExactText("Try later"),
            acknowledgerSystem: nil, acknowledgerAgent: nil)
        func status(_ availability: ConversationAvailabilityObservation? = nil, reply: Bool = false,
                    personFeed: Bool = true) -> ConversationSentChatStatusPresentation.Delivery {
            ConversationSentChatStatusPresentation.delivery(for: turn, facts: facts,
                availability: availability, hasReply: reply, conversationAgentName: "Studio",
                nowMilliseconds: 10, personFeed: personFeed)
        }
        XCTAssertEqual(status(), .notDelivered("Try later"))
        for state: ConversationAvailability in [.gone, .unsupported(reason: ExactText("old"))] {
            let availability = ConversationAvailabilityObservation(state: state)
            XCTAssertEqual(status(availability), .noOneWillGetThis)
            XCTAssertEqual(status(availability, reply: true), .deliveredAck)
        }
        XCTAssertEqual(status(personFeed: false), .deliveredAck)
        facts.deliveryAck2 = .notHanded(atMilliseconds: 10, reason: ExactText(""),
            acknowledgerSystem: nil, acknowledgerAgent: nil)
        XCTAssertEqual(status(), .notDelivered(""))
        XCTAssertEqual(ConversationSentChatStatusPresentation.failureCaption(""), "Not delivered")
        let reason = "**bold** [link](https://example.test) _text_ <tag>"
        XCTAssertEqual(ConversationSentChatStatusPresentation.failureCaption(reason), "Not delivered: " + reason)
        for rerouted in [false, true] {
            facts.deliveryAck2 = .handed(atMilliseconds: 10, rerouted: rerouted,
                acknowledgerSystem: nil, acknowledgerAgent: ExactText("Release"))
            XCTAssertEqual(status(), rerouted ? .deliveredTo("Release") : .deliveredAck)
        }
        facts.deliveryAck2 = nil
        facts.delivered = false
        facts.actedBy = ExactText("action")
        XCTAssertEqual(status(), .sent, "Acted is never evidence of handoff on the person feed.")
    }


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

    func testRetainedOriginalSurvivesPickerReplacementAndMissingCopyRemainsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay"), personID: ExactText("person"), deviceID: ExactText("device"))
        let storage = try ConversationFileStorage(identity: identity, root: root)
        let source = root.appendingPathComponent("larger-than-inline.bin")
        let bytes = Data(repeating: 231, count: 3 * 1_048_576 + 17)
        try bytes.write(to: source)
        let file = try storage.retain(source)
        try Data("Replacement picker contents".utf8).write(to: source)
        let copy = try storage.fileURL(for: file)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(file.byteCount, UInt64(bytes.count))
        XCTAssertEqual(file.sha256.rawValue, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try storage.cachedPreview(for: file), copy)
        XCTAssertEqual(try storage.cachedPreview(for: file), copy)
        try FileManager.default.removeItem(at: copy)
        XCTAssertThrowsError(try storage.cachedPreview(for: file))
        let other = try ConversationFileStorage(identity: ProfileIdentity(trustedRelayAuthority: identity.trustedRelayAuthority,
            personID: ExactText("other-person"), deviceID: identity.deviceID), root: root)
        XCTAssertNotEqual(other.directory, storage.directory)
    }

    func testInlineRetentionAndPreviewPreserveReportedMetadataAndOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try ConversationFileStorage(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay"),
            personID: ExactText("inline-person"), deviceID: ExactText("device")), root: root)
        let bytes = Data([0, 255, 2])
        let file = ConversationFile(id: ExactText("note"), name: ExactText("note.bin"), byteCount: 99,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .inline(bytes))
        let retained = try storage.retainInlineContent(of: file)
        XCTAssertEqual(retained.id, file.id)
        XCTAssertEqual(retained.name, file.name)
        XCTAssertEqual(retained.byteCount, file.byteCount)
        XCTAssertEqual(retained.sha256, file.sha256)
        let url = try XCTUnwrap(storage.cachedPreview(for: retained))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try storage.cachedPreview(for: retained), url)
        let inlinePreview = try XCTUnwrap(storage.cachedPreview(for: file))
        XCTAssertEqual(try Data(contentsOf: inlinePreview), bytes)
        let malformed = ConversationFile(id: file.id, name: file.name, byteCount: file.byteCount,
            sha256: ExactText("not-a-digest"), content: .inline(bytes))
        XCTAssertThrowsError(try storage.retainInlineContent(of: malformed))
        XCTAssertThrowsError(try storage.cachedPreview(for: malformed))
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


extension ConversationPresentationTests {
    /// #377 review B-3: a v2 unread-reply row resolves to its reply text and
    /// an open target, instead of a permanent loading row.
    func testV2ReplyRowShowsItsReplyAndOpensAtTheFirstUnread() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let chat = #"{"started":true,"read_position":"r1","last_origin_reply":"r3","unread_replies":2,"reply_group":"earlier_chat_replies","reply_rank_key":"a5"}"#
        let item = #"{"item_id":"v2","rev":1,"sender":"agent-app","request_revision":1,"message":{"title":"Q"},"files":[],"seen":true,"chat":\#(chat),"rank":{"key":"a","section":"current"},"created_at_ms":1}"#
        var model = ServerModelV2()
        _ = model.putForTesting(try APIItem(json: JSONValue.parse(Data(item.utf8))))
        for (id, position, text) in [("r1", 1, "first"), ("r2", 2, "second"), ("r3", 3, "third")] {
            let entry = #"{"entry_id":"\#(id)","item_id":"v2","rev":\#(position + 1),"position":\#(position),"kind":"reply","author":"origin","request_revision":1,"text":"\#(text)"}"#
            _ = model.putForTesting(try APIEntry(json: JSONValue.parse(Data(entry.utf8))))
        }
        let cached = ServerModelV2Projection.cachedState(model, identity: identity)
        let reference = try XCTUnwrap(cached.inboxView?.listItems?.first { $0.kind == .reply })
        let thread = try XCTUnwrap(cached.conversations[reference.key])
        let row = try XCTUnwrap(ReplyItemNormalRowProjection.resolve(reference, in: thread))
        XCTAssertEqual(row.quotedReply.text, ExactText("third"))
        XCTAssertEqual(row.openTargetTurnID, ExactText("r2"))
    }
}

extension ConversationPresentationTests {
    /// APP-06/APP-05 through the presentation store: a v2 item that has
    /// expired, whose agent is not listening, still offers its chat draft.
    func testV2ChatOffersTheComposerWhenExpiredAndTheAgentIsNotListening() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let item = #"{"item_id":"v2-item","rev":3,"sender":"agent-app","request_revision":1,"message":{"title":"Question"},"files":[],"seen":false,"chat":{"available":true,"started":true},"availability":{"state":"not_listening"},"terminal":{"state":"expired","at_ms":9},"rank":{"key":"a","section":"resolved"}}"#
        var model = ServerModelV2()
        _ = model.putForTesting(try APIItem(json: JSONValue.parse(Data(item.utf8))))
        try domain.restoreCachedServerState(ServerModelV2Projection.cachedState(model, identity: identity),
                                            context: context)
        let presentation = try LivePresentationStore(store: domain, context: context)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"),
                             messageID: ExactText("v2-item"))
        XCTAssertTrue(presentation.canEditDiscussionDraft(for: key),
                      "Chat is never closed by the item's state under the v2 rules.")
        XCTAssertTrue(presentation.updateConversation(for: key, revision: 1, text: "Still here", files: []))
    }
}

extension ConversationPresentationTests {
    /// APP-07 through the presentation store: several messages in flight at
    /// once, each its own pending row, with the composer enabled throughout.
    func testV2ChatKeepsTheComposerEnabledWithManyMessagesInFlight() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let item = #"{"item_id":"v2","rev":1,"sender":"agent-app","request_revision":1,"message":{"title":"Q"},"files":[],"seen":false,"chat":{"started":true},"rank":{"key":"a","section":"current"}}"#
        var model = ServerModelV2()
        _ = model.putForTesting(try APIItem(json: JSONValue.parse(Data(item.utf8))))
        try domain.restoreCachedServerState(ServerModelV2Projection.cachedState(model, identity: identity),
                                            context: context)
        let presentation = try LivePresentationStore(store: domain, context: context)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"),
                             messageID: ExactText("v2"))
        let binding = ConversationBinding(request: key, revision: 1)
        for text in ["one", "two", "three"] {
            XCTAssertTrue(presentation.updateConversation(for: key, revision: 1, text: text, files: []))
            try domain.queueChatMessage(binding, context: context)
            try presentation.refreshFromDurableStore()
            XCTAssertTrue(presentation.canEditDiscussionDraft(for: key), "The composer never freezes.")
            XCTAssertFalse(presentation.isSendingDiscussion(for: key, revision: 1))
        }
        let thread = try XCTUnwrap(presentation.conversation(for: key))
        XCTAssertEqual(ConversationPendingSubmission.rows(in: thread).map(\.text.rawValue), ["one", "two", "three"])
    }

    /// #384 review B-7: a refused queued message's row acts on that message
    /// by its id, never on the composer.
    func testV2PendingRowEditActsOnTheQueuedMessageNotTheComposer() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let item = #"{"item_id":"v2","rev":1,"sender":"agent-app","request_revision":1,"message":{"title":"Q"},"files":[],"seen":false,"chat":{"started":true},"rank":{"key":"a","section":"current"}}"#
        var model = ServerModelV2()
        _ = model.putForTesting(try APIItem(json: JSONValue.parse(Data(item.utf8))))
        try domain.restoreCachedServerState(ServerModelV2Projection.cachedState(model, identity: identity),
                                            context: context)
        let presentation = try LivePresentationStore(store: domain, context: context)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"),
                             messageID: ExactText("v2"))
        let binding = ConversationBinding(request: key, revision: 1)
        XCTAssertTrue(presentation.updateConversation(for: key, revision: 1, text: "first", files: []))
        let operation = try XCTUnwrap(domain.queueChatMessage(binding, context: context).operationID)
        try domain.recordQueuedChatMessage(operation, in: key, disposition: .rejected(ExactText("unavailable")),
                                           context: context)
        try presentation.refreshFromDurableStore()
        XCTAssertTrue(presentation.updateConversation(for: key, revision: 1, text: "typing", files: []))

        let thread = try XCTUnwrap(presentation.conversation(for: key))
        let row = try XCTUnwrap(ConversationPendingSubmission.rows(in: thread).first)
        XCTAssertTrue(row.isQueued)
        XCTAssertEqual(row.id, operation, "The row is the queued message, by its operation id.")

        presentation.editQueuedChatMessage(row.id, for: key)
        let edited = try XCTUnwrap(presentation.conversation(for: key))
        XCTAssertEqual(edited.drafts[1]?.text, ExactText("first\n\ntyping"), "Nothing typed is lost.")
        XCTAssertTrue(ConversationPendingSubmission.rows(in: edited).isEmpty)
    }
}
