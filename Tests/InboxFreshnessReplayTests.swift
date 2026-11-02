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
    var inboxStartItemsJSON: String?
    var inboxStartHighWater: UInt64 = 0
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

    func inboxRequest(_ request: Data, ref: String) async throws -> Data {
        let value = try JSONValue.parse(request)
        if value.uniqueValue(named: "type")?.stringValue?.rawValue == "inbox_start",
           let items = inboxStartItemsJSON {
            let reply = #"{"v":1,"type":"ok","ref":"\#(ref)","paging_version":1,"snapshot_id":"receipt-snapshot-h\#(inboxStartHighWater)","high_water":\#(inboxStartHighWater),"items":\#(items),"next_cursor":null,"receipt_cursor":null}"#
            return Data(reply.utf8)
        }
        return try await emptyInboxReply(request, ref: ref)
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
    func testTerminalReceiptWireReplayNeedsAuthoritativePagingIdentity() async throws {
        for terminalIdentityIncluded in [false, true] {
            let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                personID: ExactText("receipt-person"), deviceID: ExactText("reader"))
            let context = ProfileContext(identity: identity, transportMode: .relay)
            let persistence = MemoryAttentionStatePersistence()
            let store = try AttentionDomainStore(context: context, persistence: persistence)
            let session = InboxFreshnessRelaySession(identity: identity)
            session.inboxStartHighWater = 3
            let terminalIdentity = terminalIdentityIncluded
                ? #", "event_id":"2", "request_revision":1"# : ""
            session.inboxStartItemsJSON = #"""
                [{"acceptance":{"v":1,"type":"delivery","seq":1,"sender_id":"author","message_id":"answered","origin":"origin","as":"message","message":{"title":"Answered question"},"session_handle":"closed-handle","request_revision":1,"event_id":"1"},
                  "terminal":{"v":1,"type":"lifecycle","seq":2,"sender_id":"author","message_id":"answered","origin":"origin","state":"answered","author":"person","terminal_kind":"no_comment","answer_outcome":{"kind":"no_comment"}\#(terminalIdentity)}},
                 {"acceptance":{"v":1,"type":"delivery","seq":3,"sender_id":"author","message_id":"open","origin":"origin","as":"message","message":{"title":"Original open question"},"session_handle":"open-handle","request_revision":1,"event_id":"3"}}]
                """#
            session.ordinaryFrames = [
                data(#"{"v":1,"type":"delivery","seq":4,"sender_id":"author","message_id":"after-snapshot","origin":"origin","as":"message","message":{"title":"Arrived after snapshot"}}"#),
                data(#"{"v":1,"type":"resynced","seq":4}"#)
            ]
            // Feed entry 2 is the person-authored terminal acknowledged by the
            // origin. It never has its own conversation-stream turn event.
            session.conversationFrames = [
                data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
                data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"author","message_id":"answered","origin":"origin","session_handle":"closed-handle","request_revision":1,"kind":"receipt","author":"origin","event_id":"2","delivered":true}"#),
                data(#"{"v":1,"type":"conversation","conversation_seq":2,"sender_id":"author","message_id":"open","origin":"origin","session_handle":"open-handle","request_revision":2,"kind":"revision","author":"origin","event_id":"4","message":{"title":"Current open question"}}"#),
                data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2}"#)
            ]
            session.rejectFirstConversationACK = terminalIdentityIncluded
            let diagnostics = InboxFreshnessDiagnosticCollector()
            let core = try NativeRelayCore(store: store, context: context, session: session,
                onDiagnostic: { diagnostics.append($0) })
            if terminalIdentityIncluded {
                _ = try await core.resyncAndDrainOutbox()
                XCTAssertEqual(session.conversationACKs.count, 2)
                XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 2)
            } else {
                do {
                    _ = try await core.resyncAndDrainOutbox()
                    XCTFail("A terminal without its authoritative identity cannot satisfy a receipt.")
                } catch let error as ConversationError {
                    XCTAssertEqual(error, .invalidBinding)
                }
                XCTAssertTrue(session.conversationACKs.isEmpty)
                XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 0)
                XCTAssertEqual(diagnostics.events.last { $0.conversationValidationRejection != nil }?
                    .conversationValidationRejection?.guardID, .referencedTurnExists)
            }
            let restored = try AttentionDomainStore(context: context, persistence: persistence)
            XCTAssertEqual(try restored.snapshot(context: context).cursor, 4)
            let presentation = try LivePresentationStore(store: restored, context: context)
            func key(_ message: String) -> RequestKey {
                RequestKey(accountScope: identity.personID, senderID: ExactText("author"), messageID: ExactText(message))
            }
            XCTAssertTrue(try XCTUnwrap(presentation.inboxRow(for: key("answered"))).belongsToReplied)
            XCTAssertFalse(try XCTUnwrap(presentation.inboxRow(for: key("open"))).belongsToReplied)
            XCTAssertNotNil(presentation.request(for: key("after-snapshot")))
            if terminalIdentityIncluded {
                XCTAssertEqual(presentation.request(for: key("open"))?.title, ExactText("Current open question"))
                XCTAssertEqual(presentation.inboxRow(for: key("open"))?.requestRevision, 2)
                XCTAssertEqual(try restored.conversationSnapshot(context: context).threads[key("answered")]?
                    .facts[ExactText("2")]?.delivered, true)
            }
            await core.deactivate()
        }
    }

    @MainActor
    func testMissingDiscussionRestorationPreservesAnsweredRowAndDurableCursor() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("recovery-person"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("author"), messageID: ExactText("answered-request"))
        let binding = ConversationBinding(request: key, revision: 1)
        let handle = ExactText("session")
        _ = store.applyRelayEvent(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: .null), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: handle,
                eventID: ExactText("initial-question"))), context: context)
        // Synthetic recovery precondition, not a claimed normal loss path:
        // the local cursor passed a discussion whose turn and event are absent.
        _ = try store.advanceConversationCursor(overIgnoredUpdateAt: 1, context: context)
        let discussion = ConversationTurn(id: ExactText("discussion"), binding: binding,
            author: .person, sessionHandle: handle, text: ExactText("Before answering"),
            kind: .discussion, conversationSequence: 1)
        let historical = ConversationEvent(sequence: 1, binding: binding, fact: .turn(discussion))
        let receipt = ConversationEvent(sequence: 2, binding: binding,
            fact: .delivered(turn: discussion.id))
        _ = store.applyRelayEvent(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil),
            conversation: RelayConversationMetadata(revision: 1,
                eventID: ExactText("terminal"), author: .person),
            accountAnswerOutcome: .noComment), context: context)
        let draft = ConversationDraft(binding: binding, text: ExactText("Keep this draft"))
        try store.saveConversationDraft(draft, context: context)
        var rejection: ConversationValidationRejection?
        XCTAssertThrowsError(try store.applyConversation(receipt, context: context,
            validationRejection: &rejection))
        XCTAssertEqual(rejection?.guardID, .referencedTurnExists)
        let beforeRecovery = try persistence.load(identity: identity)
        let otherRequest = RequestKey(accountScope: identity.personID,
            senderID: key.senderID, messageID: ExactText("different-request"))
        for (target, request, session) in [
            (ExactText("different-turn"), key, handle),
            (discussion.id, otherRequest, handle),
            (discussion.id, key, ExactText("different-session"))
        ] {
            let wrongBinding = ConversationBinding(request: request, revision: 1)
            let wrongTurn = ConversationTurn(id: target, binding: wrongBinding,
                author: .person, sessionHandle: session, text: discussion.text,
                kind: .discussion, conversationSequence: 1)
            XCTAssertThrowsError(try store.restoreReferencedConversationTurn(
                ConversationEvent(sequence: 1, binding: wrongBinding, fact: .turn(wrongTurn)),
                for: receipt, context: context))
            XCTAssertEqual(try persistence.load(identity: identity), beforeRecovery)
        }
        persistence.failNextCommit()
        XCTAssertThrowsError(try store.restoreReferencedConversationTurn(historical,
            for: receipt, context: context))
        XCTAssertFalse(try XCTUnwrap(store.conversationSnapshot(context: context).threads[key])
            .turns.contains { $0.id == discussion.id })
        try store.restoreReferencedConversationTurn(historical, for: receipt, context: context)
        let repaired = try AttentionDomainStore(context: context, persistence: persistence)
        XCTAssertEqual(try repaired.conversationSnapshot(context: context).cursor, 1)
        // Restoration stores the target, not a new historical journal entry.
        XCTAssertThrowsError(try repaired.applyConversation(historical, context: context))
        try repaired.applyConversation(receipt, context: context)
        let reloaded = try AttentionDomainStore(context: context, persistence: persistence)
        let snapshot = try reloaded.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(snapshot.threads[key])
        XCTAssertEqual(snapshot.cursor, 2)
        XCTAssertEqual(thread.facts[discussion.id]?.delivered, true)
        XCTAssertEqual(thread.drafts[1], draft)
        XCTAssertEqual(thread.terminal, .answered)
        XCTAssertEqual(try reloaded.snapshot(context: context).cursor, 2)
        let presentation = try LivePresentationStore(store: reloaded, context: context)
        XCTAssertTrue(try XCTUnwrap(presentation.inboxRow(for: key)).belongsToReplied)
        XCTAssertEqual(presentation.inboxRow(for: key)?.requestRevision, 1)
    }

    @MainActor
    func testPagedTerminalRecoversLiveAndHeldReceiptsWithCurrentRevision() throws {
        for receiptHeld in [false, true] {
            let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                personID: ExactText("receipt-person"), deviceID: ExactText("reader"))
            let context = ProfileContext(identity: identity, transportMode: .relay)
            let persistence = MemoryAttentionStatePersistence()
            let store = try AttentionDomainStore(context: context, persistence: persistence)
            let key = RequestKey(accountScope: identity.personID,
                senderID: ExactText("author"), messageID: ExactText("answered-request"))
            let handle = ExactText("session")
            let terminalID = ExactText("answer-terminal")
            for revision in UInt64(2)...3 {
                let binding = ConversationBinding(request: key, revision: revision)
                let turn = ConversationTurn(id: ExactText("revision-\(revision)"), binding: binding,
                    author: .origin, sessionHandle: handle, text: ExactText(""), kind: .revision)
                try store.applyConversation(ConversationEvent(sequence: revision - 1, binding: binding,
                    fact: .revision(turn, payload: try JSONValue.parse(data("{\"title\":\"Revision \(revision)\"}")))),
                    context: context)
            }
            let discussionID = ExactText("discussion-before-answer")
            let currentBinding = ConversationBinding(request: key, revision: 3)
            let discussion = ConversationTurn(id: discussionID, binding: currentBinding,
                author: .person, sessionHandle: handle, text: ExactText("Before answering"), kind: .discussion)
            try store.applyConversation(ConversationEvent(sequence: 3, binding: currentBinding,
                fact: .turn(discussion)), context: context)
            // The origin acknowledges the person-authored terminal, not revision 1.
            let receipt = ConversationEvent(sequence: 4,
                binding: ConversationBinding(request: key, revision: 3),
                fact: .delivered(turn: terminalID))
            if receiptHeld { try store.applyConversation(receipt, context: context) }
            _ = try store.beginInboxCandidate(startupID: "startup", since: 0, batches: [], context: context)
            let acceptance = RelayEvent(sequence: 1,
                body: .delivery(StoredRequest(key: key,
                    originalPayload: try JSONValue.parse(data(#"{"title":"Original question"}"#))), .message),
                conversation: RelayConversationMetadata(revision: 1, sessionHandle: handle,
                    eventID: ExactText("initial-question")))
            // These are the same join fields used by ordinary lifecycle replay.
            let terminal = RelayEvent(sequence: 2, body: .terminal(key, .answered, nil),
                conversation: RelayConversationMetadata(revision: 3, eventID: terminalID, author: .person),
                accountAnswerOutcome: .noComment)
            let item = InboxSnapshotItem(acceptance: acceptance, terminal: terminal)
            persistence.failNextCommit()
            XCTAssertThrowsError(try store.saveInboxInitialPage(snapshotID: "snapshot", highWater: 2,
                items: [item], nextCursor: nil, receiptCursor: nil, context: context))
            let restored = try AttentionDomainStore(context: context, persistence: persistence)
            XCTAssertNil(try restored.conversationSnapshot(context: context).threads[key])
            XCTAssertEqual(try restored.conversationSnapshot(context: context).cursor, receiptHeld ? 4 : 3)
            XCTAssertNil(try restored.snapshot(context: context).requests[key])
            XCTAssertFalse(try XCTUnwrap(restored.snapshot(context: context).inboxCandidate).hasInitialPage)

            try restored.saveInboxInitialPage(snapshotID: "snapshot", highWater: 2,
                items: [item], nextCursor: nil, receiptCursor: nil, context: context)
            _ = try restored.prepareInboxCheckpointAcknowledgement(context: context)
            _ = try restored.acceptInboxCheckpoint(snapshotID: "snapshot", highWater: 2, context: context)
            if !receiptHeld { try restored.applyConversation(receipt, context: context) }
            let reloaded = try AttentionDomainStore(context: context, persistence: persistence)
            let thread = try XCTUnwrap(reloaded.conversationSnapshot(context: context).threads[key])
            XCTAssertEqual(thread.terminalTurn, terminalID)
            XCTAssertEqual(thread.facts[terminalID]?.delivered, true)
            XCTAssertEqual(thread.currentRevision, 3)
            let terminalIndex = try XCTUnwrap(thread.turns.firstIndex { $0.id == terminalID })
            for revision in UInt64(2)...3 {
                let revisionIndex = try XCTUnwrap(thread.turns.firstIndex { $0.id == ExactText("revision-\(revision)") })
                XCTAssertLessThan(revisionIndex, terminalIndex,
                                  "The terminal follows the earlier revisions it answered.")
            }
            let discussionIndex = try XCTUnwrap(thread.turns.firstIndex { $0.id == discussionID })
            XCTAssertLessThan(discussionIndex, terminalIndex)
            XCTAssertEqual(try reloaded.snapshot(context: context).cursor, 2)
            XCTAssertEqual(try reloaded.conversationSnapshot(context: context).cursor, 4)
            let presentation = try LivePresentationStore(store: reloaded, context: context)
            let row = try XCTUnwrap(presentation.inboxRow(for: key))
            XCTAssertEqual(row.requestRevision, 3)
            XCTAssertTrue(row.belongsToReplied)
            XCTAssertEqual(presentation.request(for: key)?.title, ExactText("Revision 3"))
        }
    }

    func testPagedTerminalWithoutMatchingReceiptIdentityRemainsFatal() throws {
        for suppliedID in [nil, ExactText("different-terminal")] as [ExactText?] {
            let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                personID: ExactText("receipt-person"), deviceID: ExactText("reader"))
            let context = ProfileContext(identity: identity, transportMode: .relay)
            let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
            let key = RequestKey(accountScope: identity.personID,
                senderID: ExactText("author"), messageID: ExactText("answered-request"))
            try store.applyConversation(ConversationEvent(sequence: 1,
                binding: ConversationBinding(request: key, revision: 1),
                fact: .delivered(turn: ExactText("answer-terminal"))), context: context)
            _ = try store.beginInboxCandidate(startupID: "startup", since: 0, batches: [], context: context)
            let item = InboxSnapshotItem(acceptance: RelayEvent(sequence: 1,
                body: .delivery(StoredRequest(key: key, originalPayload: .null), .message),
                conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"),
                    eventID: ExactText("initial-question"))),
                terminal: RelayEvent(sequence: 2, body: .terminal(key, .answered, nil),
                    conversation: suppliedID.map { RelayConversationMetadata(revision: 1, eventID: $0, author: .person) }))
            var rejection: ConversationValidationRejection?
            XCTAssertThrowsError(try store.saveInboxInitialPage(snapshotID: "snapshot", highWater: 2,
                items: [item], nextCursor: nil, receiptCursor: nil, context: context,
                validationRejection: &rejection)) {
                XCTAssertEqual($0 as? ConversationError, .invalidBinding)
            }
            XCTAssertEqual(rejection?.guardID, .referencedTurnExists)
            XCTAssertEqual(try store.snapshot(context: context).cursor, 0)
            XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 1)
            XCTAssertNil(try store.conversationSnapshot(context: context).threads[key])
        }
    }

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
    func testMissingContentRedactedBitIsRecognizedForAccountedRedelivery() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("freshness-missing-redaction"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
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
    func testRedactedRevisionSessionHandleMismatchIsFatalBeforeCursorAccounting() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("freshness-handle-mismatch"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))

        let session = InboxFreshnessRelaySession(identity: identity)
        session.ordinaryFrames = [
            data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"author","message_id":"request","origin":"origin","as":"message","message":{"title":"First wording"},"session_handle":"handle","request_revision":1,"availability":"not_listening","last_detached_at":123}"#),
            data(#"{"v":1,"type":"resynced","seq":1}"#)
        ]
        session.conversationFrames = [
            data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"author","message_id":"request","origin":"reader","session_handle":"other-handle","request_revision":2,"kind":"revision","author":"origin","event_id":"wrong-session-handle"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)
        ]

        let diagnostics = InboxFreshnessDiagnosticCollector()
        let core = try NativeRelayCore(store: store, context: context, session: session,
            onDiagnostic: { diagnostics.append($0) })
        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("A redacted revision with a mismatched session handle must remain fatal.")
        } catch {
            let failure = try XCTUnwrap(diagnostics.events.first {
                $0.area == .conversation && $0.phase == .conversationReplay &&
                    $0.transition == .failed && $0.conversationValidationRejection != nil
            })
            let rejection = try XCTUnwrap(failure.conversationValidationRejection)
            XCTAssertEqual(rejection.guardID, .redactedRevisionBinding)
            XCTAssertEqual(rejection.facts.sessionHandleMatchesThread, false)
        }

        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 0,
                       "A handle association mismatch is not accounted by cursor advancement.")
        XCTAssertTrue(session.conversationACKs.isEmpty,
                      "A failed fresh association check cannot ACK the replay barrier.")
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
