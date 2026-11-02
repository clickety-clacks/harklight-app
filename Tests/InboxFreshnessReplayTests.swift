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

private final class InboxFreshnessRelaySession: AuthenticatedInboxPagingSession,
                                                AuthenticatedConversationSession,
                                                @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    var ordinaryFrames: [Data] = []
    var conversationFrames: [Data] = []
    var consumedConversationFrames: [Data] = []
    var ordinaryACKs: [Data] = []
    var conversationACKs: [Data] = []

    init(identity: ProfileIdentity) {
        authenticatedIdentity = identity
    }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        for frame in ordinaryFrames { try await consume(frame) }
    }

    func acknowledge(_ request: Data) async throws {
        ordinaryACKs.append(request)
    }

    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        .unresolved
    }

    func openConversation(_ request: Data,
                          consume: @Sendable (Data) async throws -> Void) async throws {
        for frame in conversationFrames {
            consumedConversationFrames.append(frame)
            try await consume(frame)
        }
    }

    func acknowledgeConversation(_ request: Data) async throws {
        conversationACKs.append(request)
    }
}

final class InboxFreshnessReplayTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    @MainActor
    func testRejectedConversationEventPreventsFollowingRevisionFromRefreshingInbox() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("freshness-person"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        let firstPayload = try JSONValue.parse(data(#"{"title":"First wording"}"#))
        try store.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("handle"), payload: firstPayload)), context: context)

        let session = InboxFreshnessRelaySession(identity: identity)
        session.ordinaryFrames = [
            data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"author","message_id":"request","origin":"origin","as":"message","message":{"title":"First wording"},"session_handle":"handle","request_revision":1,"availability":"not_listening","last_detached_at":123}"#),
            data(#"{"v":1,"type":"resynced","seq":1}"#)
        ]
        session.conversationFrames = [
            data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            // Deliberately malformed for a redacted revision: the Server .22
            // source emits author=origin for its revision entries. This frame
            // reaches the client's exact redactedRevisionBinding guard.
            data(#"{"v":1,"type":"conversation","conversation_seq":2,"sender_id":"author","message_id":"request","origin":"reader","session_handle":"handle","request_revision":2,"kind":"revision","author":"person","event_id":"redacted-revision"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":3,"sender_id":"author","message_id":"request","origin":"origin","session_handle":"handle","request_revision":2,"kind":"revision","author":"origin","event_id":"valid-revision","message":{"title":"Second wording"}}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":3}"#)
        ]

        let diagnostics = InboxFreshnessDiagnosticCollector()
        let core = try NativeRelayCore(store: store, context: context, session: session,
            onDiagnostic: { diagnostics.append($0) })
        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("The invalid redacted revision should stop the current replay.")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .invalidBinding)
        }

        let replayFailure = try XCTUnwrap(diagnostics.events.first {
            $0.area == .conversation && $0.phase == .conversationReplay && $0.transition == .failed
        })
        XCTAssertEqual(replayFailure.causeCode, "conversation_invalid_binding")
        let rejection = try XCTUnwrap(replayFailure.conversationValidationRejection)
        XCTAssertEqual(rejection.guardID, .redactedRevisionBinding)
        XCTAssertEqual(rejection.eventKind, .revision)
        XCTAssertEqual(rejection.facts.sessionHandlePresent, true)
        XCTAssertEqual(rejection.facts.sessionHandleMatchesThread, true)
        XCTAssertEqual(rejection.facts.contentRedactedPresent, true)
        XCTAssertEqual(rejection.facts.contentRedactedIsTrue, true)
        XCTAssertEqual(rejection.facts.authorIsOrigin, false)
        XCTAssertEqual(rejection.facts.revisionIsNext, true)

        XCTAssertEqual(session.conversationFrames.count, 4,
                       "A valid revision follows the rejected event in the synthetic stream.")
        XCTAssertEqual(session.consumedConversationFrames.count, 2,
                       "Replay stops before the later valid revision and barrier.")
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 1)
        XCTAssertEqual(try store.conversationSnapshot(context: context).threads[key]?.currentRevision, 1)
        XCTAssertTrue(session.conversationACKs.isEmpty,
                      "The rejected event leaves the replay cursor unacknowledged.")

        let presentation = try LivePresentationStore(store: store, context: context)
        XCTAssertEqual(presentation.request(for: key)?.requestRevision, 1)
        XCTAssertEqual(presentation.inboxRow(for: key)?.requestRevision, 1,
                       "The Inbox still projects the last accepted revision.")
        XCTAssertEqual(presentation.request(for: key)?.title, ExactText("First wording"))
        await core.deactivate()
    }

    @MainActor
    func testAsyncStoreObservationAdoptsNewRevisionForInboxAndDetailModel() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("freshness-\(UUID().uuidString)"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
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
