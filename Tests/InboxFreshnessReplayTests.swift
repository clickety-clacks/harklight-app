import AttentionDomain
import Foundation
@testable import Harklight
@testable import HarklightNativeRelay
import XCTest

private final class InboxFreshnessDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NativeClientDiagnosticEvent] = []

    func append(_ event: NativeClientDiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        storage.append(event)
    }

    var events: [NativeClientDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}


final class InboxFreshnessReplayTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testSkippedMessageDiagnosticRetainsCauseAndItemAssociationThroughCoding() throws {
        let request = RequestKey(accountScope: ExactText("diagnostic-account"),
            senderID: ExactText("diagnostic-sender"), messageID: ExactText("diagnostic-request"))
        let event = NativeClientDiagnosticEvent(area: .conversation, phase: .conversationReplay,
            transition: .observed, causeCode: "conversation_message_skipped",
            conversationSequence: 12, request: request, requestRevision: 3)
        XCTAssertEqual(event.causeCode, "conversation_message_skipped")
        let restored = try JSONDecoder().decode(NativeClientDiagnosticEvent.self,
            from: JSONEncoder().encode(event))
        XCTAssertEqual(restored, event)
        XCTAssertEqual(restored.causeCode, "conversation_message_skipped")
        XCTAssertEqual(restored.requestTag, event.requestTag)
        XCTAssertEqual(restored.requestTag?.count, 64)
        XCTAssertEqual(restored.requestRevision, 3)
        XCTAssertEqual(restored.conversationSequence, 12)
    }












    @MainActor
    func testMissingContentRedactedBitIsRecognizedForAccountedRedelivery() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("freshness-missing-redaction"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        let firstPayload = try JSONValue.parse(data(#"{"title":"First wording"}"#))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: firstPayload), .message)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("handle"), payload: firstPayload)), context: context)

        let binding = ConversationBinding(request: key, revision: 2)
        let turn = ConversationTurn(id: ExactText("missing-content-redacted"),
            binding: binding, author: .origin, sessionHandle: ExactText("handle"),
            text: ExactText(""), contentRedacted: nil, kind: .revision)
        let event = ConversationEvent(sequence: 2, binding: binding, fact: .redactedRevision(turn))
        var firstPassRejection: ConversationValidationRejection?
        XCTAssertThrowsError(try store.applyConversation(event, context: context,
            validationRejection: &firstPassRejection)) {
            XCTAssertEqual($0 as? ConversationError, .invalidBinding)
        }
        let firstRejection = try XCTUnwrap(firstPassRejection)
        XCTAssertEqual(firstRejection.guardID, .redactedRevisionBinding)
        XCTAssertEqual(firstRejection.facts.sessionHandleMatchesThread, true)
        XCTAssertEqual(firstRejection.facts.contentRedactedPresent, false)
        XCTAssertEqual(firstRejection.facts.contentRedactedIsTrue, false)
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 1)

        // Cursor advancement is the durable accounting for the rejected sequence.
        _ = try store.advanceConversationCursor(overIgnoredUpdateAt: 2, context: context)
        let replayRejection = try XCTUnwrap(
            try store.redactedRevisionRejectionForAccountedRedelivery(event, context: context))
        XCTAssertEqual(replayRejection, firstRejection,
                       "ACK-behind replay recognizes the same guard without requiring contentRedacted==true.")
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 2)
    }


    @MainActor
    func testRequestAndRedactedRevisionForwardJumpsPreserveRedactedProjection() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("freshness-advance"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        let first = try JSONValue.parse(data(#"{"title":"First wording"}"#))
        let third = try JSONValue.parse(data(#"{"title":"Third wording"}"#))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: first), .message)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("handle"), payload: first)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 2,
            binding: ConversationBinding(request: key, revision: 3),
            fact: .request(sessionHandle: ExactText("handle"), payload: third)), context: context)

        let redactedBinding = ConversationBinding(request: key, revision: 5)
        let redacted = ConversationTurn(id: ExactText("redacted-revision-five"),
            binding: redactedBinding, author: .origin, sessionHandle: ExactText("handle"),
            text: ExactText(""), contentRedacted: true, kind: .revision)
        try store.applyConversation(ConversationEvent(sequence: 3, binding: redactedBinding,
            fact: .redactedRevision(redacted)), context: context)

        let thread = try XCTUnwrap(store.conversationSnapshot(context: context).threads[key])
        XCTAssertEqual(thread.currentRevision, 5)
        XCTAssertEqual(thread.revisionNumbers, [1, 3, 5])
        XCTAssertTrue(thread.currentContentRedacted)
        XCTAssertNil(thread.revisions[2])
        XCTAssertNil(thread.revisions[4])

        let presentation = try LivePresentationStore(store: store, context: context)
        let presented = try XCTUnwrap(presentation.request(for: key))
        XCTAssertEqual(presented.requestRevision, 5)
        XCTAssertEqual(presentation.inboxRow(for: key)?.requestRevision, 5)
        XCTAssertEqual(presented.title, ExactText("Question content unavailable on this device"))
        XCTAssertNil(presented.selector,
                     "A redacted current revision must not expose an answer selector.")
        XCTAssertThrowsError(try store.selector(for: key, requestRevision: 5, context: context),
                             "Revision-bound actions remain unavailable for redacted content.")
    }

    @MainActor
    func testAsyncStoreObservationAdoptsNewRevisionForInboxAndDetailModel() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("freshness-\(UUID().uuidString)"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        let firstPayload = try JSONValue.parse(data(#"{"title":"First wording"}"#))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: firstPayload), .message)), context: context)
        try store.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("handle"), payload: firstPayload)), context: context)

        let presentation = try LivePresentationStore(store: store, context: context)
        XCTAssertEqual(presentation.request(for: key)?.requestRevision, 1)
        XCTAssertEqual(presentation.inboxRow(for: key)?.requestRevision, 1)

        let adoptedCurrentRevision = expectation(description: "the selected request projection adopts revision two")
        presentation.notificationProjectionDidChange = {
            if presentation.request(for: key)?.requestRevision == 2 {
                adoptedCurrentRevision.fulfill()
            }
        }
        presentation.startObserving()
        defer { presentation.stopObserving() }

        let secondPayload = try JSONValue.parse(data(#"{"title":"Second wording"}"#))
        let binding = ConversationBinding(request: key, revision: 2)
        let revision = ConversationTurn(id: ExactText("revision-two"), binding: binding,
            author: .origin, sessionHandle: ExactText("handle"),
            text: ExactText("Second wording"), kind: .revision)
        try store.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .revision(revision, payload: secondPayload)), context: context)

        XCTAssertEqual(presentation.request(for: key)?.requestRevision, 1,
                       "The live model can briefly remain on its prior snapshot before the async refresh is consumed.")
        await fulfillment(of: [adoptedCurrentRevision], timeout: 2)
        XCTAssertEqual(presentation.request(for: key)?.requestRevision, 2)
        XCTAssertEqual(presentation.request(for: key)?.title, ExactText("Second wording"))
        XCTAssertEqual(presentation.inboxRow(for: key)?.requestRevision, 2)
    }
}
