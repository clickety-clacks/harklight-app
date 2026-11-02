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
    var conversationFrameBatches: [[Data]] = []
    var consumedConversationFrames: [Data] = []
    var ordinaryACKs: [Data] = []
    var conversationACKs: [Data] = []
    var rejectFirstConversationACK = false
    private var conversationOpenCount = 0

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
        let frames: [Data]
        if conversationFrameBatches.isEmpty {
            frames = conversationFrames
        } else {
            let index = min(conversationOpenCount, conversationFrameBatches.count - 1)
            frames = conversationFrameBatches[index]
        }
        conversationOpenCount += 1
        for frame in frames {
            consumedConversationFrames.append(frame)
            try await consume(frame)
        }
    }

    func acknowledgeConversation(_ request: Data) async throws {
        conversationACKs.append(request)
        if rejectFirstConversationACK {
            rejectFirstConversationACK = false
            throw InstallationTransportError.acknowledgementBehind
        }
    }
}

final class InboxFreshnessReplayTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    @MainActor
    func testConversationInvalidBindingDoesNotBlockFollowingRevisionFromRefreshingInbox() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("freshness-person"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))

        let session = InboxFreshnessRelaySession(identity: identity)
        session.rejectFirstConversationACK = true
        session.ordinaryFrames = [
            data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"author","message_id":"request","origin":"origin","as":"message","message":{"title":"First wording"},"session_handle":"handle","request_revision":1,"availability":"not_listening","last_detached_at":123}"#),
            data(#"{"v":1,"type":"resynced","seq":1}"#)
        ]
        session.conversationFrames = [
            data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            // This is a synthetic guard exercise, not a captured Server frame.
            // Deliberately malformed for a redacted revision: the Server .22
            // source emits author=origin for its revision entries. This frame
            // reaches the client's exact redactedRevisionBinding guard.
            data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"author","message_id":"request","origin":"reader","session_handle":"handle","request_revision":2,"kind":"revision","author":"person","event_id":"redacted-revision"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":2,"sender_id":"author","message_id":"request","origin":"origin","session_handle":"handle","request_revision":3,"kind":"revision","author":"origin","event_id":"valid-revision","message":{"title":"Third wording"}}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2}"#)
        ]

        let diagnostics = InboxFreshnessDiagnosticCollector()
        let core = try NativeRelayCore(store: store, context: context, session: session,
            onDiagnostic: { diagnostics.append($0) })
        _ = try await core.resyncAndDrainOutbox()

        let rejectedEventDiagnostic = try XCTUnwrap(diagnostics.events.first {
            $0.area == .conversation && $0.phase == .conversationReplay &&
                $0.transition == .observed && $0.conversationValidationRejection != nil
        })
        XCTAssertEqual(rejectedEventDiagnostic.causeCode, "conversation_invalid_binding")
        XCTAssertEqual(rejectedEventDiagnostic.conversationSequence, 1)
        XCTAssertNotNil(rejectedEventDiagnostic.requestTag)
        let rejection = try XCTUnwrap(rejectedEventDiagnostic.conversationValidationRejection)
        XCTAssertEqual(rejection.guardID, .redactedRevisionBinding)
        XCTAssertEqual(rejection.eventKind, .revision)
        XCTAssertEqual(rejection.facts.sessionHandlePresent, true)
        XCTAssertEqual(rejection.facts.sessionHandleMatchesThread, true)
        XCTAssertEqual(rejection.facts.contentRedactedPresent, true)
        XCTAssertEqual(rejection.facts.contentRedactedIsTrue, true)
        XCTAssertEqual(rejection.facts.authorIsOrigin, false)
        XCTAssertEqual(rejection.facts.revisionIsNext, true)
        let encodedDiagnostic = String(decoding: try JSONEncoder().encode(rejectedEventDiagnostic), as: UTF8.self)
        XCTAssertFalse(encodedDiagnostic.contains("redacted-revision"))
        XCTAssertFalse(encodedDiagnostic.contains("Third wording"))

        XCTAssertEqual(session.conversationFrames.count, 4,
                       "A valid revision follows the rejected event in the synthetic stream.")
        XCTAssertEqual(session.consumedConversationFrames.count, 8,
                       "Replay accounts for the rejected event, recovers after an ACK-behind response, then consumes the history again.")
        let snapshot = try store.conversationSnapshot(context: context)
        XCTAssertEqual(snapshot.cursor, 2)
        XCTAssertEqual(snapshot.threads[key]?.currentRevision, 3)
        XCTAssertEqual(snapshot.threads[key]?.revisionNumbers, [1, 3],
                       "The skipped revision remains absent while the complete later revision becomes current.")
        XCTAssertEqual(session.conversationACKs.map { String(decoding: $0, as: UTF8.self) },
            ["{\"v\":1,\"type\":\"conversation_ack\",\"conversation_seq\":2,\"ref\":\"native-conversation-ack\"}\n",
             "{\"v\":1,\"type\":\"conversation_ack\",\"conversation_seq\":2,\"ref\":\"native-conversation-ack\"}\n"],
            "Replay acknowledges only after the rejected sequence and later valid revision are accounted for, including recovery from an ACK-behind response.")

        let presentation = try LivePresentationStore(store: store, context: context)
        XCTAssertEqual(presentation.request(for: key)?.requestRevision, 3)
        XCTAssertEqual(presentation.inboxRow(for: key)?.requestRevision, 3,
                       "The Inbox projects the later valid revision after the rejected event is accounted for.")
        XCTAssertEqual(presentation.request(for: key)?.title, ExactText("Third wording"))

        let lowerPayload = try JSONValue.parse(data(#"{"title":"Older wording"}"#))
        let lowerBinding = ConversationBinding(request: key, revision: 2)
        let lowerRequest = ConversationEvent(sequence: 3, binding: lowerBinding,
            fact: .request(sessionHandle: ExactText("handle"), payload: lowerPayload))
        XCTAssertThrowsError(try store.applyConversation(lowerRequest, context: context)) {
            XCTAssertEqual($0 as? ConversationError, .staleRevision(current: 3))
        }
        let lowerTurn = ConversationTurn(id: ExactText("lower-revision"), binding: lowerBinding,
            author: .origin, sessionHandle: ExactText("handle"), text: ExactText("Older wording"),
            kind: .revision)
        let lowerRevision = ConversationEvent(sequence: 3, binding: lowerBinding,
            fact: .revision(lowerTurn, payload: lowerPayload))
        XCTAssertThrowsError(try store.applyConversation(lowerRevision, context: context)) {
            XCTAssertEqual($0 as? ConversationError, .staleRevision(current: 3))
        }
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 2)

        let restoredStore = try AttentionDomainStore(context: context, persistence: persistence)
        let restored = try restoredStore.conversationSnapshot(context: context)
        XCTAssertEqual(restored.cursor, 2)
        XCTAssertEqual(restored.threads[key]?.currentRevision, 3,
                       "The cursor and later revision survive reload without a stored rejection record.")
        await core.deactivate()
    }

    @MainActor
    func testAccountedRedeliveryWithoutMatchingConversationRemainsFatal() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("freshness-person"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        _ = try store.advanceConversationCursor(overIgnoredUpdateAt: 1, context: context)

        let session = InboxFreshnessRelaySession(identity: identity)
        session.rejectFirstConversationACK = true
        session.ordinaryFrames = [
            data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"resynced","seq":0}"#)
        ]
        session.conversationFrameBatches = [
            [
                data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
                data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)
            ],
            [
                data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
                data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"other-sender","message_id":"other-request","origin":"reader","session_handle":"handle","request_revision":2,"kind":"revision","author":"person","event_id":"unbound-revision"}"#),
                data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)
            ]
        ]

        let core = try NativeRelayCore(store: store, context: context, session: session)
        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("A redelivery without a matching request thread must not be treated as accounted.")
        } catch {
            XCTAssertEqual(error as? ConversationError, .conflict)
        }

        XCTAssertEqual(session.conversationACKs.count, 1,
                       "Only the first barrier ACK is attempted; the mismatched replay is not ACKed.")
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 1)
        await core.deactivate()
    }

    @MainActor
    func testRequestAndRedactedRevisionForwardJumpsPreserveRedactedProjection() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("freshness-advance"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
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
