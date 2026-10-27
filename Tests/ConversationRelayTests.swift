@testable import AttentionDomain
import CryptoKit
import Foundation
import HarklightNativeRelay
import XCTest

final class ConversationRelayTests: XCTestCase {
    private final class DiagnosticCollector: @unchecked Sendable {
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

    private final class Session: AuthenticatedInboxEventStreamSession, AuthenticatedConversationEventSession, @unchecked Sendable {
        let authenticatedIdentity: ProfileIdentity
        var ordinary: [Data] = []
        var conversation: [Data] = []
        var ordinaryACKs: [Data] = []
        var conversationACKs: [Data] = []
        var conversationReadPositionRequests: [Data] = []
        var conversationReadPositionResults: [ConversationReadPositionResult] = []
        var supportsPostCheckpointInboxEvents = false
        var onOrdinaryACK: (() throws -> Void)?
        var onConversationACK: (() throws -> Void)?
        var onConversationOpen: (() -> Void)?
        var conversationOpenError: InstallationTransportError?
        var rejectFirstConversationACK = false
        var onLiveConversationWait: (() -> Void)?
        private var liveConversation: CheckedContinuation<Void, any Error>?
        private let postCheckpointLock = NSLock()
        private var postCheckpointEvents: [Data] = []
        private var postCheckpointWaiters: [CheckedContinuation<Data, any Error>] = []
        private var postCheckpointEventsEnded = false
        init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }
        func nextLiveConversationSignal() async throws {
            try await withCheckedThrowingContinuation { continuation in
                liveConversation = continuation
                onLiveConversationWait?()
            }
        }
        func pushLiveConversation() {
            liveConversation?.resume()
            liveConversation = nil
        }
        func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
            for frame in ordinary { try await consume(frame) }
        }
        func acknowledge(_ request: Data) async throws {
            try onOrdinaryACK?()
            ordinaryACKs.append(request)
        }
        func nextPostCheckpointInboxEvent() async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                postCheckpointLock.lock()
                if !postCheckpointEvents.isEmpty {
                    let frame = postCheckpointEvents.removeFirst()
                    postCheckpointLock.unlock()
                    continuation.resume(returning: frame)
                } else if postCheckpointEventsEnded {
                    postCheckpointLock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    postCheckpointWaiters.append(continuation)
                    postCheckpointLock.unlock()
                }
            }
        }
        func pushPostCheckpointInboxEvent(_ frame: Data) {
            postCheckpointLock.lock()
            if postCheckpointWaiters.isEmpty {
                postCheckpointEvents.append(frame)
                postCheckpointLock.unlock()
            } else {
                let waiter = postCheckpointWaiters.removeFirst()
                postCheckpointLock.unlock()
                waiter.resume(returning: frame)
            }
        }
        func finishPostCheckpointInboxEvents() {
            postCheckpointLock.lock()
            postCheckpointEventsEnded = true
            let waiters = postCheckpointWaiters
            postCheckpointWaiters.removeAll()
            postCheckpointLock.unlock()
            waiters.forEach { $0.resume(throwing: CancellationError()) }
        }
        func openConversation(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
            onConversationOpen?()
            if let conversationOpenError { throw conversationOpenError }
            for frame in conversation { try await consume(frame) }
        }
        func acknowledgeConversation(_ request: Data) async throws {
            try onConversationACK?()
            conversationACKs.append(request)
            if rejectFirstConversationACK {
                rejectFirstConversationACK = false
                throw InstallationTransportError.acknowledgementBehind
            }
        }
        func sendConversationReadPosition(_ frame: Data, operationID: UUID) async -> ConversationReadPositionResult {
            conversationReadPositionRequests.append(frame)
            guard !conversationReadPositionResults.isEmpty else { return .unresolved }
            return conversationReadPositionResults.removeFirst()
        }
        func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult { .unresolved }
    }
    private func data(_ string: String) -> Data { Data(string.utf8) }
    private func setup() throws -> (ProfileContext, MemoryAttentionStatePersistence, AttentionDomainStore, Session) {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("local-person"), deviceID: ExactText("reader")), transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let session = Session(context.identity)
        session.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"author","message_id":"request","origin":"origin","as":"message","message":{"title":"Question"},"session_handle":"handle","request_revision":1,"availability":"not_listening","last_detached_at":123}"#),
            data(#"{"v":1,"type":"resynced","seq":1}"#)]
        return (context, persistence, store, session)
    }
    private func event(_ kind: String, sequence: Int, fields: String,
                       messageID: String = "request", sessionHandle: String = "handle") -> Data {
        data("{\"v\":1,\"type\":\"conversation\",\"conversation_seq\":\(sequence),\"sender_id\":\"author\",\"message_id\":\"\(messageID)\",\"origin\":\"origin\",\"session_handle\":\"\(sessionHandle)\",\"request_revision\":1,\"kind\":\"\(kind)\",\(fields)}")
    }
    func testUnavailableChatDoesNotFailInboxDrainOrProbeAgainUntilNewConnection() async throws {
        let (context, _, store, session) = try setup()
        session.conversationOpenError = .conversationsUnavailable
        var opens = 0
        session.onConversationOpen = { opens += 1 }
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let firstHigh = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(firstHigh, 1)
        let unavailable = await core.conversationsUnavailable
        XCTAssertTrue(unavailable)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        XCTAssertTrue(session.conversationACKs.isEmpty)
        XCTAssertEqual(try store.snapshot(context: context).requests.count, 1)

        // A later inbox delivery uses the same connection after chat refusal.
        session.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"author","message_id":"later","origin":"origin","as":"message","message":{"title":"Still receiving"}}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        let secondHigh = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(secondHigh, 2)
        XCTAssertEqual(try store.snapshot(context: context).requests.count, 2)
        XCTAssertEqual(session.ordinaryACKs.count, 2)
        XCTAssertEqual(opens, 1)
        await core.deactivate()

        let supported = Session(context.identity)
        supported.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        supported.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":0}"#)]
        let replacement = try NativeRelayCore(store: store, context: context, session: supported)
        _ = try await replacement.resyncAndDrainOutbox()
        let stillUnavailable = await replacement.conversationsUnavailable
        XCTAssertFalse(stillUnavailable)
        XCTAssertEqual(supported.conversationACKs.count, 1)
        await replacement.deactivate()
    }

    func testReadPositionUpdateClearsOnlyItsRequestBeforeConversationACK() async throws {
        let (context, _, store, session) = try setup()
        let first = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        let second = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("second"))
        session.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"author","message_id":"request","origin":"origin","as":"message","message":{"title":"First question"},"session_handle":"handle","request_revision":1,"availability":"not_listening","last_detached_at":123}"#),
            data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"author","message_id":"second","origin":"origin","as":"message","message":{"title":"Second question"},"session_handle":"second-handle","request_revision":1,"availability":"not_listening","last_detached_at":123}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("reply", sequence: 1, fields: #""author":"origin","event_id":"reply-1","text":"First reply""#),
            event("reply", sequence: 2, fields: #""author":"origin","event_id":"reply-2","text":"Second reply""#,
                messageID: "second", sessionHandle: "second-handle"),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2,"chat_read_positions":[]}"#)]

        let liveSignal = expectation(description: "The account conversation feed remains open for live updates")
        let appliedBeforeACK = expectation(description: "The read update is durable before its transport ACK")
        liveSignal.assertForOverFulfill = false
        session.onLiveConversationWait = { liveSignal.fulfill() }
        var conversationACKCount = 0
        session.onConversationACK = {
            conversationACKCount += 1
            guard conversationACKCount == 2 else { return }
            let snapshot = try store.conversationSnapshot(context: context)
            XCTAssertFalse(snapshot.threads[first]?.hasUnreadAgentReply ?? true)
            XCTAssertTrue(snapshot.threads[second]?.hasUnreadAgentReply ?? false)
            appliedBeforeACK.fulfill()
        }
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertTrue(try XCTUnwrap(store.conversationSnapshot(context: context).threads[first]).hasUnreadAgentReply)
        XCTAssertTrue(try XCTUnwrap(store.conversationSnapshot(context: context).threads[second]).hasUnreadAgentReply)
        await fulfillment(of: [liveSignal], timeout: 2)

        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","event_id":"read-3","conversation_seq":3,"sender_id":"author","message_id":"request","origin":"origin","kind":"read_position","read_through_conversation_seq":1}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":3,"chat_read_positions":[{"sender_id":"author","message_id":"request","read_through_conversation_seq":1}]}"#)]
        await session.pushLiveConversation()
        await fulfillment(of: [appliedBeforeACK], timeout: 2)
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 3)
        XCTAssertEqual(session.conversationACKs.count, 2)
        await core.deactivate()
    }

    func testLocalReadBeforeServerSupportMigratesAndRetriesWithSameOperationID() async throws {
        let (context, persistence, store, session) = try setup()
        let first = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        let second = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("second"))
        session.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"author","message_id":"request","origin":"origin","as":"message","message":{"title":"First question"},"session_handle":"handle","request_revision":1,"availability":"not_listening","last_detached_at":123}"#),
            data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"author","message_id":"second","origin":"origin","as":"message","message":{"title":"Second question"},"session_handle":"second-handle","request_revision":1,"availability":"not_listening","last_detached_at":123}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("reply", sequence: 1, fields: #""author":"origin","event_id":"reply-1","text":"First reply""#),
            event("reply", sequence: 2, fields: #""author":"origin","event_id":"reply-2","text":"Second reply""#,
                messageID: "second", sessionHandle: "second-handle"),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2}"#)]
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()

        XCTAssertNil(try store.markConversationRead(first, context: context),
                     "An older server keeps the existing local read marker and receives no read-position write.")
        XCTAssertTrue(session.conversationReadPositionRequests.isEmpty)
        XCTAssertFalse(try XCTUnwrap(store.conversationSnapshot(context: context).threads[first]).hasUnreadAgentReply)
        XCTAssertTrue(try XCTUnwrap(store.conversationSnapshot(context: context).threads[second]).hasUnreadAgentReply)

        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2,"chat_read_positions":[]}"#)]
        session.conversationReadPositionResults = [.unresolved,
            .accepted(position: 1, eventSequence: 3, eventID: ExactText("read-3"), duplicate: false)]
        _ = try await core.resyncAndDrainOutbox()

        let firstAttempt = try XCTUnwrap(session.conversationReadPositionRequests.first)
        let firstFrame = try JSONValue.parse(firstAttempt)
        XCTAssertEqual(firstFrame.uniqueValue(named: "type")?.stringValue?.rawValue, "conversation_read")
        XCTAssertEqual(firstFrame.uniqueValue(named: "sender_id")?.stringValue, first.senderID)
        XCTAssertEqual(firstFrame.uniqueValue(named: "message_id")?.stringValue, first.messageID)
        XCTAssertEqual(firstFrame.uniqueValue(named: "read_through_conversation_seq")?.integerValue, 1)
        XCTAssertNil(firstFrame.uniqueValue(named: "request_revision"))
        XCTAssertNil(firstFrame.uniqueValue(named: "person_id"))
        XCTAssertNil(firstFrame.uniqueValue(named: "device_id"))

        let pendingBeforeRelaunch = try XCTUnwrap(
            store.conversationSnapshot(context: context).pendingChatReadPositions.first)
        let relaunchedStore = try AttentionDomainStore(context: context, persistence: persistence)
        let persistedPending = try XCTUnwrap(
            relaunchedStore.conversationSnapshot(context: context).pendingChatReadPositions.first)
        XCTAssertEqual(persistedPending.operationID, pendingBeforeRelaunch.operationID,
                       "The unresolved read operation and its identity survive a relaunch.")
        await core.deactivate()

        let retrySession = Session(context.identity)
        retrySession.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        retrySession.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2,"chat_read_positions":[]}"#)]
        retrySession.conversationReadPositionResults = [
            .accepted(position: 1, eventSequence: 3, eventID: ExactText("read-3"), duplicate: false)
        ]
        var conversationOpenCount = 0
        retrySession.onConversationOpen = {
            conversationOpenCount += 1
            guard conversationOpenCount == 2 else { return }
            retrySession.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
                data(#"{"v":1,"type":"conversation","event_id":"read-3","conversation_seq":3,"sender_id":"author","message_id":"request","origin":"origin","kind":"read_position","read_through_conversation_seq":1}"#),
                data(#"{"v":1,"type":"conversation_resynced","conversation_seq":3,"chat_read_positions":[{"sender_id":"author","message_id":"request","read_through_conversation_seq":1}]}"#)]
        }
        let retryCore = try NativeRelayCore(store: relaunchedStore, context: context, session: retrySession)
        _ = try await retryCore.resyncAndDrainOutbox()

        XCTAssertEqual(retrySession.conversationReadPositionRequests.count, 1)
        let retryFrame = try JSONValue.parse(retrySession.conversationReadPositionRequests[0])
        XCTAssertEqual(retryFrame.uniqueValue(named: "op_id")?.stringValue,
                       firstFrame.uniqueValue(named: "op_id")?.stringValue,
                       "A retry of the same logical read reuses its durable operation identity.")
        let snapshot = try relaunchedStore.conversationSnapshot(context: context)
        XCTAssertTrue(snapshot.pendingChatReadPositions.isEmpty)
        XCTAssertEqual(snapshot.chatReadPositions?[first], 1)
        XCTAssertFalse(try XCTUnwrap(snapshot.threads[first]).hasUnreadAgentReply)
        XCTAssertTrue(try XCTUnwrap(snapshot.threads[second]).hasUnreadAgentReply)
        await retryCore.deactivate()
    }

    func testReadPositionWireDoesNotRequireRevisionOrSessionHandle() throws {
        let (context, _, _, _) = try setup()
        let wire = try ConversationWire(profile: context)
        let valid = try wire.decodeUpdate(data(#"{"v":1,"type":"conversation","event_id":"read-7","conversation_seq":7,"sender_id":"author","message_id":"request","origin":"origin","kind":"read_position","read_through_conversation_seq":4}"#))
        guard case let .event(event) = valid,
              case let .readPosition(eventID, position) = event.fact else {
            return XCTFail("The valid account read-position update should be applied.")
        }
        XCTAssertEqual(event.sequence, 7)
        XCTAssertEqual(event.binding.revision, 0)
        XCTAssertEqual(event.binding.request.accountScope, context.identity.personID)
        XCTAssertEqual(eventID, ExactText("read-7"))
        XCTAssertEqual(position, 4)

        XCTAssertThrowsError(try wire.decodeUpdate(data(#"{"v":1,"type":"conversation","event_id":"read-7","conversation_seq":7,"sender_id":"author","message_id":"request","kind":"read_position"}"#)))
        XCTAssertThrowsError(try wire.decodeUpdate(data(#"{"v":1,"type":"conversation","event_id":"","conversation_seq":7,"sender_id":"author","message_id":"request","kind":"read_position","read_through_conversation_seq":4}"#)))
    }

    func testOlderSavedConversationTurnSequenceIsRecoveredForDuplicateReplay() throws {
        let request = RequestKey(accountScope: ExactText("person"),
            senderID: ExactText("author"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: request, revision: 1)
        let handle = ExactText("handle")
        let oldTurn = ConversationTurn(id: ExactText("reply-1"), binding: binding,
            author: .origin, sessionHandle: handle, text: ExactText("Reply"), kind: .reply)
        var thread = ConversationThread(request: request, sessionHandle: handle,
            revision: 1, payload: .null)
        try thread.merge(oldTurn)
        var state = ConversationState()
        state.cursor = 1
        state.events[1] = ConversationEvent(sequence: 1, binding: binding, fact: .turn(oldTurn))
        state.threads[request] = thread

        state.orderTurnsFromProjectionEvents()
        var replayedTurn = oldTurn
        replayedTurn.conversationSequence = 1
        try state.apply(ConversationEvent(sequence: 1, binding: binding, fact: .turn(replayedTurn)))

        XCTAssertEqual(state.threads[request]?.latestAgentReply?.conversationSequence, 1)
        guard case let .turn(savedTurn)? = state.events[1]?.fact else {
            return XCTFail("The old saved conversation event should remain available.")
        }
        XCTAssertEqual(savedTurn.conversationSequence, 1)
    }

    func testResyncSnapshotDistinguishesOldServerFromEmptyReadMap() throws {
        let (context, _, _, _) = try setup()
        let wire = try ConversationWire(profile: context)
        let oldServer = try wire.decodeResyncedSnapshot(
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":0}"#))
        let supportedServer = try wire.decodeResyncedSnapshot(
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":0,"chat_read_positions":[]}"#))
        XCTAssertNil(oldServer.chatReadPositions)
        XCTAssertEqual(supportedServer.chatReadPositions, [])
    }

    func testInvalidOptionalReadMapDoesNotStopConversationReplay() async throws {
        let (context, _, store, session) = try setup()
        let diagnostics = DiagnosticCollector()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("reply", sequence: 1, fields: #""author":"origin","event_id":"reply-1","text":"Reply""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1,"chat_read_positions":[{"sender_id":"author","message_id":"request","read_through_conversation_seq":2}]}"#)]
        let core = try NativeRelayCore(store: store, context: context, session: session,
                                       onDiagnostic: diagnostics.append)
        _ = try await core.resyncAndDrainOutbox()

        let snapshot = try store.conversationSnapshot(context: context)
        XCTAssertEqual(snapshot.cursor, 1)
        XCTAssertEqual(snapshot.chatReadPositionSupport, false)
        XCTAssertTrue(snapshot.threads.values.contains { $0.latestAgentReply?.id == ExactText("reply-1") })
        XCTAssertEqual(session.conversationACKs.count, 1)
        XCTAssertTrue(diagnostics.events.contains { $0.causeCode == "invalid_chat_read_positions" })
        await core.deactivate()
    }

    func testOtherConversationRefusalsStillFailTheDrain() async throws {
        let (context, _, store, session) = try setup()
        session.conversationOpenError = .serverRejected
        let core = try NativeRelayCore(store: store, context: context, session: session)
        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("An ordinary rejection must not be treated as missing chat support.")
        } catch InstallationTransportError.serverRejected { }
        let unavailable = await core.conversationsUnavailable
        XCTAssertFalse(unavailable)
        await core.deactivate()
    }

    func testIndependentReplayCommitsBeforeItsACKAndNeverAdvancesOrdinaryCursor() async throws {
        let (context, _, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("discussion", sequence: 1, fields: #""author":"person","event_id":"2","text":"Explain""#),
            event("receipt", sequence: 2, fields: #""event_id":"2","delivered":true"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2}"#)]
        session.onConversationACK = {
            XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 2)
            XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        }
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 1)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        XCTAssertEqual(session.conversationACKs.count, 1)
        let thread = try XCTUnwrap(try store.conversationSnapshot(context: context).threads.values.first)
        XCTAssertEqual(thread.turns.first?.id, ExactText("2"))
        XCTAssertEqual(thread.facts[ExactText("2")]?.delivered, true)
        XCTAssertNil(thread.facts[ExactText("2")]?.actedBy)
    }
    func testLiveAgentReplyAfterOpenIsCommittedThenACKedWithoutReconnect() async throws {
        let (context, _, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("discussion", sequence: 1, fields: #""author":"person","event_id":"2","text":"Explain""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        let listening = expectation(description: "listening for live conversation entries")
        listening.assertForOverFulfill = false
        session.onLiveConversationWait = { listening.fulfill() }
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        await fulfillment(of: [listening], timeout: 5)
        XCTAssertEqual(session.conversationACKs.count, 1)

        // The relay pushed the agent's receipt and reply on the open connection.
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("receipt", sequence: 2, fields: #""author":"origin","event_id":"2","delivered":true"#),
            event("reply", sequence: 3, fields: #""author":"origin","event_id":"4","in_reply_to":"2","text":"Here is why""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":3}"#)]
        let acknowledged = expectation(description: "live entries acknowledged")
        session.onConversationACK = {
            XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 3)
            acknowledged.fulfill()
        }
        session.pushLiveConversation()
        await fulfillment(of: [acknowledged], timeout: 5)

        XCTAssertEqual(session.conversationACKs.count, 2)
        let thread = try XCTUnwrap(try store.conversationSnapshot(context: context).threads.values.first)
        let reply = try XCTUnwrap(thread.turns.first { $0.id == ExactText("4") })
        XCTAssertEqual(reply.author, .origin)
        XCTAssertEqual(reply.text, ExactText("Here is why"))
        XCTAssertEqual(reply.inReplyTo, ExactText("2"))
        XCTAssertEqual(thread.facts[ExactText("2")]?.delivered, true)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        await core.deactivate()
    }
    func testRelayRetractionWithoutSessionHandleDoesNotBlockLaterChat() async throws {
        let (context, _, store, session) = try setup()
        let earlier = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("earlier"))
        let request = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        session.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"author","message_id":"earlier","origin":"origin","as":"message","message":{"title":"Withdrawn"},"session_handle":"earlier-handle","request_revision":1,"availability":"not_listening","last_detached_at":null}"#),
            data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"author","message_id":"request","origin":"origin","as":"message","message":{"title":"Question"},"session_handle":"handle","request_revision":1,"availability":"not_listening","last_detached_at":123}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        let support = #""listening_support":{"route":"claude-code","cli_version":"1","origin":"origin","reported_at":5,"unsupported_reason":null},"unsupported_reason":null"#
        // The relay sends a retraction without a session handle. Every later
        // presence, receipt and reply depends on the replay getting past it.
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"author","message_id":"earlier","origin":"origin","request_revision":1,"kind":"retraction","author":"origin","event_id":"2","terminal_seq":7,"terminal_state":"retracted","retracted_at":1792643952343}"#),
            event("availability", sequence: 2, fields: #""author":"server","availability":"not_listening","last_detached_at":null,"# + support),
            event("availability", sequence: 3, fields: #""author":"server","availability":"listening","last_detached_at":null,"# + support),
            event("discussion", sequence: 4, fields: #""author":"person","event_id":"5","op_id":"7eaac5c0-02a6-43a7-9934-8bbde62d7bde","text":"Hi there""#),
            event("receipt", sequence: 5, fields: #""author":"origin","event_id":"5","delivered":true"#),
            event("reply", sequence: 6, fields: #""author":"origin","event_id":"6","in_reply_to":"5","op_id":"7d76be3a-c45d-4cef-87c7-248982fe3b0d","text":"Hello""#),
            event("acted", sequence: 7, fields: #""author":"origin","event_id":"5","acting_event_id":"6""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":7}"#)]
        session.onConversationACK = {
            XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 7)
        }
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()

        XCTAssertEqual(session.conversationACKs, [data(#"{"v":1,"type":"conversation_ack","conversation_seq":7,"ref":"native-conversation-ack"}"# + "\n")])
        let threads = try store.conversationSnapshot(context: context).threads
        XCTAssertEqual(threads[earlier]?.isRetracted, true)
        XCTAssertEqual(threads[earlier]?.retraction?.retractedAtMilliseconds, 1792643952343)
        let thread = try XCTUnwrap(threads[request])
        XCTAssertEqual(thread.availability, .listening)
        let reply = try XCTUnwrap(thread.turns.first { $0.id == ExactText("6") })
        XCTAssertEqual(reply.author, .origin)
        XCTAssertEqual(reply.text, ExactText("Hello"))
        XCTAssertEqual(reply.inReplyTo, ExactText("5"))
        XCTAssertEqual(thread.facts[ExactText("5")]?.delivered, true)
        XCTAssertEqual(thread.facts[ExactText("5")]?.actedBy, ExactText("6"))
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
        await core.deactivate()
    }
    func testRetractionForAnUnloadedRequestDoesNotBlockLaterChatAndAppliesWhenItsDeliveryArrives() async throws {
        let (context, _, store, session) = try setup()
        let earlier = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("earlier"))
        let request = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        // The retracted request is older than the loaded inbox page, so this
        // device holds no thread for it when the replay reaches its retraction.
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"author","message_id":"earlier","origin":"origin","request_revision":1,"kind":"retraction","author":"origin","event_id":"2","terminal_seq":7,"terminal_state":"retracted","retracted_at":1792643952343}"#),
            event("discussion", sequence: 2, fields: #""author":"person","event_id":"5","op_id":"7eaac5c0-02a6-43a7-9934-8bbde62d7bde","text":"Hi there""#),
            event("receipt", sequence: 3, fields: #""author":"origin","event_id":"5","delivered":true"#),
            event("reply", sequence: 4, fields: #""author":"origin","event_id":"6","in_reply_to":"5","op_id":"7d76be3a-c45d-4cef-87c7-248982fe3b0d","text":"Hello""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":4}"#)]
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()

        XCTAssertEqual(session.conversationACKs, [data(#"{"v":1,"type":"conversation_ack","conversation_seq":4,"ref":"native-conversation-ack"}"# + "\n")])
        var threads = try store.conversationSnapshot(context: context).threads
        XCTAssertNil(threads[earlier])
        let thread = try XCTUnwrap(threads[request])
        let reply = try XCTUnwrap(thread.turns.first { $0.id == ExactText("6") })
        XCTAssertEqual(reply.text, ExactText("Hello"))
        XCTAssertEqual(thread.facts[ExactText("5")]?.delivered, true)

        // The earlier request loads afterwards and shows its held retraction.
        session.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"author","message_id":"earlier","origin":"origin","as":"message","message":{"title":"Withdrawn"},"session_handle":"earlier-handle","request_revision":1,"availability":"not_listening","last_detached_at":null}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":4}"#)]
        _ = try await core.resyncAndDrainOutbox()

        threads = try store.conversationSnapshot(context: context).threads
        XCTAssertEqual(threads[earlier]?.isRetracted, true)
        XCTAssertEqual(threads[earlier]?.retraction?.retractedAtMilliseconds, 1792643952343)
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 4)
        await core.deactivate()
    }
    func testThreadFactsForAnUnloadedRequestAreHeldWhileLaterChatIsAppliedAndACKed() async throws {
        let (context, persistence, store, session) = try setup()
        let earlier = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("earlier"))
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("availability", sequence: 1,
                fields: #""author":"server","availability":"listening","last_detached_at":null"#,
                messageID: "earlier", sessionHandle: "earlier-handle"),
            event("discussion", sequence: 2,
                fields: #""author":"person","event_id":"5","op_id":"7eaac5c0-02a6-43a7-9934-8bbde62d7bde","text":"Hi there""#,
                messageID: "earlier", sessionHandle: "earlier-handle"),
            event("receipt", sequence: 3, fields: #""author":"origin","event_id":"5","delivered":true"#,
                messageID: "earlier", sessionHandle: "earlier-handle"),
            event("reply", sequence: 4,
                fields: #""author":"origin","event_id":"6","in_reply_to":"5","op_id":"7d76be3a-c45d-4cef-87c7-248982fe3b0d","text":"Hello""#,
                messageID: "earlier", sessionHandle: "earlier-handle"),
            event("discussion", sequence: 5,
                fields: #""author":"person","event_id":"7","text":"Current request still works""#),
            event("receipt", sequence: 6, fields: #""author":"origin","event_id":"7","delivered":true"#),
            event("reply", sequence: 7,
                fields: #""author":"origin","event_id":"8","in_reply_to":"7","text":"Current reply""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":7}"#)]
        session.onConversationACK = {
            XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 7)
            XCTAssertNil(try store.conversationSnapshot(context: context).threads[earlier])
            let current = try XCTUnwrap(try store.conversationSnapshot(context: context).threads.values.first)
            XCTAssertEqual(current.facts[ExactText("7")]?.delivered, true)
            XCTAssertEqual(current.turns.first { $0.id == ExactText("8") }?.text, ExactText("Current reply"))
        }

        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.conversationACKs, [data(#"{"v":1,"type":"conversation_ack","conversation_seq":7,"ref":"native-conversation-ack"}"# + "\n")])
        await core.deactivate()

        // The held events survive a store restart, then apply when inbox paging
        // eventually loads their request.
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let later = Session(context.identity)
        later.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"author","message_id":"earlier","origin":"origin","as":"message","message":{"title":"Earlier request"},"session_handle":"earlier-handle","request_revision":1,"availability":"not_listening","last_detached_at":null}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        later.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":7}"#)]
        let resumed = try NativeRelayCore(store: restored, context: context, session: later)
        _ = try await resumed.resyncAndDrainOutbox()

        let threads = try restored.conversationSnapshot(context: context).threads
        let thread = try XCTUnwrap(threads[earlier])
        XCTAssertEqual(thread.availability, .listening)
        XCTAssertEqual(thread.turns.first { $0.id == ExactText("5") }?.text, ExactText("Hi there"))
        XCTAssertEqual(thread.facts[ExactText("5")]?.delivered, true)
        XCTAssertEqual(thread.turns.first { $0.id == ExactText("6") }?.text, ExactText("Hello"))
        XCTAssertEqual(try restored.conversationSnapshot(context: context).cursor, 7)
        XCTAssertEqual(later.conversationACKs, [data(#"{"v":1,"type":"conversation_ack","conversation_seq":7,"ref":"native-conversation-ack"}"# + "\n")])
        await resumed.deactivate()
    }
    func testUnboundTierFactIsDurableBeforeACKAndAppliesWhenDeliveryArrives() async throws {
        let (context, persistence, store, session) = try setup()
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("future"))
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"author","message_id":"future","origin":"future-origin","request_revision":1,"kind":"attention_tier","event_id":"tier-change","attention_tier":"low"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        session.onConversationACK = {
            XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 1)
            XCTAssertEqual(try store.snapshot(context: context).cursor, 1,
                           "Conversation replay must not advance the ordinary cursor.")
            let snapshot = try store.snapshot(context: context)
            XCTAssertNil(snapshot.requests[key], "A tier fact must not create a duplicate message row.")
            XCTAssertNil(snapshot.remoteStates[key])
            XCTAssertEqual(snapshot.inboxReferences[key]?.attentionTier, .low,
                           "The tier fact must be durable before the conversation cursor is acknowledged.")
            XCTAssertEqual(snapshot.inboxReferences[key]?.attentionTierFeed, .conversation)
            let restored = try AttentionDomainStore(context: context, persistence: persistence)
            XCTAssertEqual(try restored.snapshot(context: context).inboxReferences[key]?.attentionTier, .low)
        }

        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.conversationACKs.count, 1)

        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let payload = try JSONValue.parse(data(#"{"title":"Arrived later"}"#))
        try restored.apply(RelayEvent(sequence: 2,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            origin: ExactText("future-origin"), attentionTier: .top), context: context)
        let port = AttentionDomainPort(store: restored)
        let rows = try port.observe(context: port.context).requests.filter { $0.key == key }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.attentionTier, .low,
                       "The later ordinary delivery must retain the conversation-feed tier.")
    }
    func testOriginSourceResultCommitsBeforeItsACKAndKeepsAgentTerminalAsTheOnlyClosure() async throws {
        let (context, _, store, session) = try setup()
        let operationID = UUID(uuidString: "83b3fc92-6f10-4d94-9fd5-62f9572e4f1a")!
        session.ordinary[2] = data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"author","message_id":"request","origin":"origin","state":"answered","by":"agent_answer","request_revision":1,"event_id":"answer-2","author":"agent"}"#)
        session.ordinary.append(data(#"{"v":1,"type":"resynced","seq":2}"#))
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("result", sequence: 1, fields: #""author":"origin","event_id":"source-result-3","in_reply_to":"answer-2","op_id":"83b3fc92-6f10-4d94-9fd5-62f9572e4f1a","status":"applied""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        session.onOrdinaryACK = {
            let thread = try XCTUnwrap(try store.conversationSnapshot(context: context).threads.values.first)
            XCTAssertEqual(thread.terminal, .answered)
            XCTAssertEqual(thread.terminalTurn, ExactText("answer-2"))
            XCTAssertEqual(thread.terminalAuthor, .agent)
            XCTAssertEqual(thread.turns.count, 1)
            XCTAssertEqual(thread.turns.first?.kind, .terminal, "The ordinary lifecycle is durably committed before its ACK.")
        }
        session.onConversationACK = {
            let snapshot = try store.conversationSnapshot(context: context)
            let thread = try XCTUnwrap(snapshot.threads.values.first)
            XCTAssertEqual(snapshot.cursor, 1)
            XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
            XCTAssertEqual(thread.terminal, .answered, "The conversation result must not create another closure.")
            XCTAssertEqual(thread.terminalAuthor, .agent)
            XCTAssertEqual(thread.turns.filter { $0.kind == .terminal }.count, 1)
            XCTAssertEqual(thread.turns.count, 2)
            let result = try XCTUnwrap(thread.turns.first { $0.id == ExactText("source-result-3") })
            XCTAssertEqual(result.kind, .result)
            XCTAssertEqual(result.author, .origin)
            XCTAssertEqual(result.text, ExactText(""))
            XCTAssertEqual(result.inReplyTo, ExactText("answer-2"))
            XCTAssertEqual(result.operationID, operationID)
            XCTAssertEqual(result.resultStatus, ExactText("applied"))
        }

        let core = try NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 2)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        XCTAssertEqual(session.conversationACKs.count, 1)
    }

    func testStatusOnlyOriginResultReplaysBeforeLaterOrdinaryAnswerAndBothCursorsAdvance() async throws {
        let (context, _, store, session) = try setup()
        let operationID = UUID(uuidString: "a60e2170-cc04-4577-999a-8d0a8cf1bbf8")!
        let terminal = data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"author","message_id":"request","origin":"origin","state":"answered","by":"agent_answer","request_revision":1,"event_id":"answer-2","author":"agent"}"#)
        let result = event("result", sequence: 1, fields:
            #""author":"origin","event_id":"source-result-3","in_reply_to":"answer-2","op_id":"a60e2170-cc04-4577-999a-8d0a8cf1bbf8","status":"received""#)
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#), result,
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        var ordinaryACKCount = 0
        var conversationACKCount = 0
        session.onOrdinaryACK = {
            ordinaryACKCount += 1
            let snapshot = try store.conversationSnapshot(context: context)
            let thread = try XCTUnwrap(snapshot.threads.values.first)
            XCTAssertEqual(try store.snapshot(context: context).cursor, ordinaryACKCount == 1 ? 1 : 2)
            if ordinaryACKCount == 1 {
                XCTAssertNil(thread.terminal)
            } else {
                XCTAssertEqual(thread.terminal, .answered)
                XCTAssertEqual(thread.terminalTurn, ExactText("answer-2"))
                XCTAssertEqual(thread.terminalAuthor, .agent)
                XCTAssertEqual(thread.turns.filter { $0.kind == .terminal }.count, 1)
                XCTAssertEqual(thread.turns.count, 2)
                let result = try XCTUnwrap(thread.turns.first { $0.id == ExactText("source-result-3") })
                XCTAssertEqual(result.operationID, operationID)
                XCTAssertEqual(result.inReplyTo, ExactText("answer-2"))
                XCTAssertEqual(result.resultStatus, ExactText("received"))
            }
        }
        session.onConversationACK = {
            conversationACKCount += 1
            let thread = try XCTUnwrap(try store.conversationSnapshot(context: context).threads.values.first)
            XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 1)
            XCTAssertEqual(thread.terminal, conversationACKCount == 1 ? nil : .answered)
            XCTAssertEqual(thread.turns.count, conversationACKCount == 1 ? 1 : 2)
            let result = try XCTUnwrap(thread.turns.first { $0.id == ExactText("source-result-3") })
            XCTAssertEqual(result.author, .origin)
            XCTAssertEqual(result.text, ExactText(""))
            XCTAssertEqual(result.operationID, operationID)
            XCTAssertEqual(result.inReplyTo, ExactText("answer-2"))
            XCTAssertEqual(result.resultStatus, ExactText("received"))
            XCTAssertEqual(try store.snapshot(context: context).cursor, UInt64(ordinaryACKCount))
        }

        let core = try NativeRelayCore(store: store, context: context, session: session)
        let firstHigh = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(firstHigh, 1)
        XCTAssertEqual(ordinaryACKCount, 1)
        XCTAssertEqual(conversationACKCount, 1)

        session.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync","seq":1}"#), terminal,
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        let secondHigh = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(secondHigh, 2)
        XCTAssertEqual(ordinaryACKCount, 2)
        XCTAssertEqual(conversationACKCount, 2)
        XCTAssertEqual(session.ordinaryACKs.count, 2)
        XCTAssertEqual(session.conversationACKs.count, 2)
    }
    func testLegacyDeliveryNeedsNoConversationProjection() async throws {
        let (context, _, store, session) = try setup()
        session.ordinary[1] = data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"author","message_id":"request","origin":"origin","as":"message","message":{"title":"Legacy question"}}"#)
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 1)
        XCTAssertTrue(try store.conversationSnapshot(context: context).threads.isEmpty)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        XCTAssertTrue(session.conversationACKs.isEmpty)
    }
    func testUnknownConversationKindIsNotedSkippedAndReplayContinues() async throws {
        let (context, _, store, session) = try setup()
        let diagnostics = DiagnosticCollector()
        let liveACK = expectation(description: "The live replay is acknowledged through its later known event")
        var conversationACKCount = 0
        session.onConversationACK = {
            conversationACKCount += 1
            if conversationACKCount == 2 { liveACK.fulfill() }
        }
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":1,"kind":"future_fact"}"#),
            event("discussion", sequence: 2, fields: #""author":"agent","event_id":"2","text":"Reply""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2}"#)]
        let core = try NativeRelayCore(store: store, context: context, session: session,
                                       onDiagnostic: diagnostics.append)
        _ = try await core.resyncAndDrainOutbox()
        let snapshot = try store.conversationSnapshot(context: context)
        XCTAssertEqual(snapshot.cursor, 2)
        XCTAssertTrue(snapshot.threads.values.contains { $0.turns.contains { $0.id == ExactText("2") } })
        XCTAssertTrue(diagnostics.events.contains { $0.causeCode == "unknown_update_kind" })
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertEqual(session.conversationACKs.count, 1)

        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":3,"kind":"future_fact"}"#),
            event("reply", sequence: 4, fields: #""author":"agent","event_id":"4","text":"Next reply""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":4}"#)]
        await session.pushLiveConversation()
        await fulfillment(of: [liveACK], timeout: 2)
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 4)
        XCTAssertTrue(try store.conversationSnapshot(context: context).threads.values
            .contains { $0.turns.contains { $0.id == ExactText("4") } })
        await core.deactivate()
    }

    func testUnknownRelayUpdateIsNotedSkippedAndAcknowledged() async throws {
        let (context, _, store, session) = try setup()
        let diagnostics = DiagnosticCollector()
        session.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"future_relay_update","seq":1}"#),
            data(#"{"v":1,"type":"lifecycle","seq":2,"state":"future_terminal"}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        let core = try NativeRelayCore(store: store, context: context, session: session,
                                       onDiagnostic: diagnostics.append)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 2)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        XCTAssertTrue(diagnostics.events.contains { $0.causeCode == "unknown_update_kind" })
        await core.deactivate()
    }

    func testMalformedUnknownConversationFrameStillStopsItsReplay() async throws {
        let (context, _, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","kind":"future_fact"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        let core = try NativeRelayCore(store: store, context: context, session: session)
        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("An unknown update without a usable sequence cannot advance replay")
        } catch {
            XCTAssertEqual(error as? RelayWireError, .invalidFrame)
        }
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 0)
        XCTAssertTrue(session.conversationACKs.isEmpty)
        await core.deactivate()
    }

    func testUnknownPostCheckpointRelayUpdateAdvancesCursorAndACKs() async throws {
        let (context, _, store, session) = try setup()
        session.supportsPostCheckpointInboxEvents = true
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":0}"#)]
        let postCheckpointACK = expectation(description: "The unknown live update is acknowledged")
        var ordinaryACKCount = 0
        session.onOrdinaryACK = {
            ordinaryACKCount += 1
            if ordinaryACKCount == 2 { postCheckpointACK.fulfill() }
        }
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        session.pushPostCheckpointInboxEvent(data(#"{"v":1,"type":"future_relay_update","seq":2}"#))
        await fulfillment(of: [postCheckpointACK], timeout: 2)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
        XCTAssertEqual(session.ordinaryACKs.count, 2)
        await core.deactivate()
        session.finishPostCheckpointInboxEvents()
    }
    func testConversationGapAndWrongHighWaterCannotBeAcknowledged() async throws {
        for gap in [true, false] {
            let (context, _, store, session) = try setup()
            session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
                event("discussion", sequence: gap ? 2 : 1, fields: #""author":"person","event_id":"2","text":"Explain""#),
                data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2}"#)]
            let core = try NativeRelayCore(store: store, context: context, session: session)
            do { _ = try await core.resyncAndDrainOutbox(); XCTFail("Noncontiguous replay must fail") }
            catch { XCTAssertEqual(error as? NativeRelayCoreError, .invalidReplay) }
            XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, gap ? 0 : 1)
            XCTAssertTrue(session.conversationACKs.isEmpty)
        }
    }
    func testFailedConversationPersistenceLeavesItsCursorUnacknowledged() async throws {
        let (context, persistence, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("discussion", sequence: 1, fields: #""author":"person","event_id":"2","text":"Explain""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        session.onConversationOpen = { persistence.failNextCommit() }
        let core = try NativeRelayCore(store: store, context: context, session: session)
        do { _ = try await core.resyncAndDrainOutbox(); XCTFail("Failed durability must stop ACK") }
        catch {}
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 0)
        XCTAssertTrue(session.conversationACKs.isEmpty)
    }
    func testLostConversationACKReplaysExactHistoryWithoutChangingOrdinaryCursor() async throws {
        let (context, _, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("discussion", sequence: 1, fields: #""author":"person","event_id":"2","text":"Explain""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        session.rejectFirstConversationACK = true
        let core = try NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.conversationACKs.count, 2)
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 1)
        XCTAssertEqual(try store.conversationSnapshot(context: context).threads.values.first?.turns.count, 1)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
    }
    func testInlineOriginalBytesAndIndependentFileFactsDecodeWithoutInferringUse() throws {
        let (context, _, _, _) = try setup()
        let wire = try ConversationWire(profile: context)
        let bytes = Data([0, 255, 0, 2])
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fields = "\"author\":\"person\",\"event_id\":\"2\",\"text\":\"Explain\",\"files\":[{\"name\":\"original.bin\",\"tier\":\"inline\",\"size\":4,\"sha256\":\"\(digest)\",\"data_base64\":\"\(bytes.base64EncodedString())\"}]"
        let decoded = try wire.decodeEvent(event("discussion", sequence: 1, fields: fields))
        guard case let .turn(turn) = decoded.fact else { return XCTFail("Expected turn") }
        XCTAssertEqual(turn.files.first?.content, .inline(bytes))
        XCTAssertEqual(turn.files.first?.id, ExactText("original.bin"))
        let transfer = try wire.decodeEvent(event("file_transfer", sequence: 2,
            fields: #""event_id":"2","file":"original.bin","status":"transferred""#))
        guard case .fileTransfer = transfer.fact else { return XCTFail("Transfer must remain a distinct fact") }
        XCTAssertThrowsError(try wire.decodeEvent(event("discussion", sequence: 1,
            fields: fields.replacingOccurrences(of: digest, with: String(repeating: "0", count: 64)))))
    }
    func testSupportProvenanceAndOriginRedactionAreExplicitAndClosureIsNotConversation() throws {
        let (context, _, _, _) = try setup()
        let wire = try ConversationWire(profile: context)
        let status = try wire.decodeEvent(event("availability", sequence: 1,
            fields: #""availability":"unsupported","unsupported_reason":"Missing prerequisite","listening_support":{"route":"codex","cli_version":"1","origin":"origin","reported_at":5}"#))
        guard case let .availabilityRecord(_, state, support) = status.fact else { return XCTFail("Expected provenance") }
        XCTAssertEqual(state, .unsupported(reason: ExactText("Missing prerequisite")))
        XCTAssertEqual(support?.uniqueValue(named: "route"), .string(ExactText("codex")))
        let redacted = event("discussion", sequence: 2, fields: #""author":"person","event_id":"2""#)
        let originBytes = data(String(decoding: redacted, as: UTF8.self).replacingOccurrences(of: "\"origin\":\"origin\"", with: "\"origin\":\"reader\""))
        guard case let .turn(turn) = try wire.decodeEvent(originBytes).fact else { return XCTFail("Expected redacted turn") }
        XCTAssertEqual(turn.contentRedacted, true)
        XCTAssertEqual(turn.text, ExactText(""))
        XCTAssertThrowsError(try wire.decodeEvent(event("terminal", sequence: 3, fields: #""event_id":"4","state":"answered""#)))
    }
}
