@testable import AttentionDomain
import CryptoKit
import Foundation
import HarklightNativeRelay
import XCTest
@testable import Harklight

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
        var consumedConversationFrames: [Data] = []
        var inboxStartItemsJSON: String?
        var ordinaryACKs: [Data] = []
        var conversationACKs: [Data] = []
        var conversationReadPositionRequests: [Data] = []
        var conversationReadPositionResults: [ConversationReadPositionResult] = []
        var supportsPostCheckpointInboxEvents = false
        var onOrdinaryACK: (() async throws -> Void)?
        var onConversationACK: (() async throws -> Void)?
        var onConversationOpen: (() async -> Void)?
        var conversationOpenError: InstallationTransportError?
        var rejectFirstConversationACK = false
        var onLiveConversationWait: (() -> Void)?
        private var liveConversation: CheckedContinuation<LiveConversationSignal, any Error>?
        private let postCheckpointLock = NSLock()
        private var postCheckpointEvents: [Data] = []
        private var postCheckpointWaiters: [CheckedContinuation<Data, any Error>] = []
        private var postCheckpointEventsEnded = false
        init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }
        func nextLiveConversationSignal() async throws -> LiveConversationSignal {
            return try await withCheckedThrowingContinuation { continuation in
                liveConversation = continuation
                onLiveConversationWait?()
            }
        }
        func pushLiveConversation(replyEvent: ConversationEvent? = nil,
                                 receivedAtMilliseconds: UInt64 = 0) {
            let replyArrivals = replyEvent
                .flatMap { LiveConversationReplyArrival(event: $0,
                    receivedAtMilliseconds: receivedAtMilliseconds) }
                .map { [$0] } ?? []
            liveConversation?.resume(returning: LiveConversationSignal(
                replyArrivals: replyArrivals))
            liveConversation = nil
        }
        func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
            for frame in ordinary { try await consume(frame) }
        }
        func correlatedRequest(_ request: Data, ref: String) async throws -> Data {
            try await inboxRequest(request, ref: ref)
        }
        func acknowledge(_ request: Data) async throws {
            try await onOrdinaryACK?()
            ordinaryACKs.append(request)
        }
        func inboxRequest(_ request: Data, ref: String) async throws -> Data {
            let value = try JSONValue.parse(request)
            if value.uniqueValue(named: "type")?.stringValue?.rawValue == "inbox_start",
               let items = inboxStartItemsJSON {
                let response = #"{"v":1,"type":"ok","ref":"\#(ref)","paging_version":1,"snapshot_id":"held-fact-snapshot","high_water":1,"items":\#(items),"next_cursor":null,"receipt_cursor":null}"#
                return Data(response.utf8)
            }
            return try await emptyInboxReply(request, ref: ref)
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
            await onConversationOpen?()
            if let conversationOpenError { throw conversationOpenError }
            for frame in conversation {
                consumedConversationFrames.append(frame)
                try await consume(frame)
            }
        }
        func acknowledgeConversation(_ request: Data) async throws {
            try await onConversationACK?()
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
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        let firstHigh = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(firstHigh, 1)
        let unavailable = await core.conversationsUnavailable
        XCTAssertTrue(unavailable)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        XCTAssertTrue(session.conversationACKs.isEmpty)
        let assertionSnapshot166_165 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot166_165.requests.count, 1)

        // A later inbox delivery uses the same connection after chat refusal.
        session.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"author","message_id":"later","origin":"origin","as":"message","message":{"title":"Still receiving"}}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        let secondHigh = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(secondHigh, 2)
        let assertionSnapshot174_174 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot174_174.requests.count, 2)
        XCTAssertEqual(session.ordinaryACKs.count, 2)
        XCTAssertEqual(opens, 1)
        await core.deactivate()

        let supported = Session(context.identity)
        supported.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        supported.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":0}"#)]
        let replacement = try await NativeRelayCore(store: store, context: context, session: supported)
        _ = try await replacement.resyncAndDrainOutbox()
        let stillUnavailable = await replacement.conversationsUnavailable
        XCTAssertFalse(stillUnavailable)
        XCTAssertEqual(supported.conversationACKs.count, 1)
        await replacement.deactivate()
    }

    func testRejectedConversationCursorWriteFailureDoesNotAdvanceOrAcknowledge() async throws {
        let (context, persistence, store, session) = try setup()
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        try await store.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("handle"), payload: .object([
                JSONMember("title", .string(ExactText("Question")))
            ]))), context: context)

        session.conversation = [
            data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":2,"sender_id":"author","message_id":"request","origin":"reader","session_handle":"handle","request_revision":2,"kind":"revision","author":"person","event_id":"private-event-marker"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":3,"sender_id":"author","message_id":"request","origin":"origin","session_handle":"handle","request_revision":2,"kind":"revision","author":"origin","event_id":"valid-event","message":{"title":"Later wording"}}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":3}"#)
        ]
        session.onConversationOpen = { persistence.failNextCommit() }
        let core = try await NativeRelayCore(store: store, context: context, session: session)

        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("A rejected sequence must remain fatal when its cursor commit fails.")
        } catch let error as AttentionStoreError {
            guard case .persistence = error else { return XCTFail("Unexpected store error: \(error)") }
        }

        let snapshot = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(snapshot.cursor, 1,
            "A failed cursor commit must leave the prior durable cursor unchanged.")
        XCTAssertEqual(session.consumedConversationFrames.count, 2,
            "Replay stops at the failed rejected-sequence cursor commit.")
        XCTAssertTrue(session.conversationACKs.isEmpty,
            "A rejected sequence is not acknowledged unless its cursor is durable.")
        await core.deactivate()
    }

    func testUnusableConversationHandleIsSkippedAndAcknowledged() async throws {
        let (context, _, store, session) = try setup()
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        try await store.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("handle"), payload: .object([
                JSONMember("title", .string(ExactText("Question")))
            ]))), context: context)

        session.conversation = [
            data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":2,"sender_id":"author","message_id":"request","origin":"origin","session_handle":"","request_revision":2,"kind":"revision","author":"origin","event_id":"invalid-revision","message":{"title":"Later wording"}}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2}"#)
        ]
        let diagnostics = DiagnosticCollector()
        let core = try await NativeRelayCore(store: store, context: context, session: session,
            onDiagnostic: diagnostics.append)

        _ = try await core.resyncAndDrainOutbox()
        let assertionSnapshot248_249 = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot248_249.cursor, 2)
        XCTAssertEqual(session.conversationACKs.count, 1)
        XCTAssertNotNil(diagnostics.events.first {
            $0.area == .conversation && $0.phase == .conversationReplay &&
                $0.transition == .observed && $0.conversationSequence == 2
        })
        await core.deactivate()
    }

    func testStaleContextBeforeConversationReplayRemainsFatal() async throws {
        let (context, _, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("discussion", sequence: 1, fields: #""author":"person","event_id":"turn","text":"Question""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        session.onConversationOpen = { await store.invalidate() }
        let core = try await NativeRelayCore(store: store, context: context, session: session)

        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("A stale store context must not be converted into a skipped event.")
        } catch let error as AttentionStoreError {
            XCTAssertEqual(error, .staleProfile)
        }

        XCTAssertTrue(session.conversationACKs.isEmpty)
        await core.deactivate()
    }

    func testSnapshotValidationFailureStopsOnlyItsPassAfterDurableEvents() async throws {
        let (context, _, store, session) = try setup()
        // The barrier claims an event that was never delivered. Invalid optional
        // read-position metadata is tolerated separately and is not a gap.
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("discussion", sequence: 1, fields: #""author":"person","event_id":"turn","text":"Question""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2}"#)]
        let core = try await NativeRelayCore(store: store, context: context, session: session)

        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("A rejected snapshot must not be treated as an accounted event.")
        } catch let error as NativeRelayCoreError {
            XCTAssertEqual(error, .invalidReplay)
        }

        let snapshot = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(snapshot.cursor, 1,
            "The already committed event remains the last durable cursor.")
        XCTAssertTrue(session.conversationACKs.isEmpty,
            "A rejected resync snapshot cannot cross the barrier ACK.")
        session.ordinary = [data(#"{"v":1,"type":"resynced","seq":1}"#)]
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.conversationACKs.count, 1,
            "The next valid pass can acknowledge the unchanged durable cursor")
        await core.deactivate()
    }

    func testInboxPageOpeningThreadSkipsUnresolvedHeldFactAndKeepsDiagnostics() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("local-person"), deviceID: ExactText("reader"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        try await store.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .delivered(turn: ExactText("missing-turn"))), context: context)

        let session = Session(identity)
        session.inboxStartItemsJSON = #"[{"acceptance":{"v":1,"type":"delivery","seq":1,"sender_id":"author","message_id":"request","origin":"origin","as":"message","message":{"title":"Question"},"session_handle":"handle","request_revision":1}}]"#
        session.conversationOpenError = .conversationsUnavailable
        session.ordinary = [data(#"{"v":1,"type":"resynced","seq":1}"#)]
        let diagnostics = DiagnosticCollector()
        let core = try await NativeRelayCore(store: store, context: context, session: session,
            onDiagnostic: { diagnostics.append($0) })

        _ = try await core.resyncAndDrainOutbox()

        let event = try XCTUnwrap(diagnostics.events.first { $0.phase == .inboxPage })
        XCTAssertEqual(event.transition, .observed)
        XCTAssertEqual(event.causeCode, "conversation_invalid_binding")
        XCTAssertEqual(event.conversationValidationRejection?.guardID, .referencedTurnExists)
        XCTAssertEqual(event.conversationValidationRejection?.eventKind, .receipt)
        let assertionSnapshot333_335 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot333_335.cursor, 1)
        let conversationSnapshot = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(conversationSnapshot.cursor, 1)
        XCTAssertNotNil(conversationSnapshot.threads[key])
        XCTAssertNotNil(diagnostics.events.first { $0.causeCode == "conversation_message_skipped" })
        XCTAssertTrue(session.ordinaryACKs.isEmpty)
        await core.deactivate()
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
            let snapshot = try await store.conversationSnapshot(context: context)
            XCTAssertFalse(snapshot.threads[first]?.hasUnreadAgentReply ?? true)
            XCTAssertTrue(snapshot.threads[second]?.hasUnreadAgentReply ?? false)
            appliedBeforeACK.fulfill()
        }
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        let initialConversation = try await store.conversationSnapshot(context: context)
        XCTAssertTrue(try XCTUnwrap(initialConversation.threads[first]).hasUnreadAgentReply)
        XCTAssertTrue(try XCTUnwrap(initialConversation.threads[second]).hasUnreadAgentReply)
        await fulfillment(of: [liveSignal], timeout: 2)

        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","event_id":"read-3","conversation_seq":3,"sender_id":"author","message_id":"request","origin":"origin","kind":"read_position","read_through_conversation_seq":1}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":3,"chat_read_positions":[{"sender_id":"author","message_id":"request","read_through_conversation_seq":1}]}"#)]
        await session.pushLiveConversation()
        await fulfillment(of: [appliedBeforeACK], timeout: 2)
        let assertionSnapshot382_385 = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot382_385.cursor, 3)
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
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()

        let localReadResult = try await store.markConversationRead(first, context: context)
        XCTAssertNil(localReadResult,
                     "An older server keeps the existing local read marker and receives no read-position write.")
        XCTAssertTrue(session.conversationReadPositionRequests.isEmpty)
        let localConversation = try await store.conversationSnapshot(context: context)
        let locallyRead = try XCTUnwrap(localConversation.threads[first])
        XCTAssertEqual(locallyRead.latestAgentReply?.id, ExactText("reply-1"))
        XCTAssertEqual(locallyRead.readThroughTurn, ExactText("reply-1"))
        XCTAssertFalse(locallyRead.hasUnreadAgentReply)
        XCTAssertTrue(try XCTUnwrap(localConversation.threads[second]).hasUnreadAgentReply)

        // The inbox replay is already at high water 2; this subsequent open
        // returns only the accepted frame and its matching checkpoint.
        session.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":2,"chat_read_positions":[]}"#)]
        session.conversationReadPositionResults = [.unresolved,
            .accepted(position: 1, eventSequence: 3, eventID: ExactText("read-3"), duplicate: false)]
        _ = try await core.resyncAndDrainOutbox()

        let migrated = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(migrated.chatReadPositionSupport, true)
        XCTAssertEqual(migrated.chatReadPositions?[first], 1)
        XCTAssertEqual(migrated.pendingChatReadPositions.first?.readThroughConversationSequence, 1)
        let firstAttempt = try XCTUnwrap(session.conversationReadPositionRequests.first)
        let firstFrame = try JSONValue.parse(firstAttempt)
        XCTAssertEqual(firstFrame.uniqueValue(named: "type")?.stringValue?.rawValue, "conversation_read")
        XCTAssertEqual(firstFrame.uniqueValue(named: "sender_id")?.stringValue, first.senderID)
        XCTAssertEqual(firstFrame.uniqueValue(named: "message_id")?.stringValue, first.messageID)
        XCTAssertEqual(firstFrame.uniqueValue(named: "read_through_conversation_seq")?.integerValue, 1)
        XCTAssertNil(firstFrame.uniqueValue(named: "request_revision"))
        XCTAssertNil(firstFrame.uniqueValue(named: "person_id"))
        XCTAssertNil(firstFrame.uniqueValue(named: "device_id"))

        let beforeRelaunchConversation = try await store.conversationSnapshot(context: context)
        let pendingBeforeRelaunch = try XCTUnwrap(
            beforeRelaunchConversation.pendingChatReadPositions.first)
        let relaunchedStore = try AttentionDomainStore(context: context, persistence: persistence)
        let relaunchedConversation = try await relaunchedStore.conversationSnapshot(context: context)
        let persistedPending = try XCTUnwrap(
            relaunchedConversation.pendingChatReadPositions.first)
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
            retrySession.conversation = [self.data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
                self.data(#"{"v":1,"type":"conversation","event_id":"read-3","conversation_seq":3,"sender_id":"author","message_id":"request","origin":"origin","kind":"read_position","read_through_conversation_seq":1}"#),
                self.data(#"{"v":1,"type":"conversation_resynced","conversation_seq":3,"chat_read_positions":[{"sender_id":"author","message_id":"request","read_through_conversation_seq":1}]}"#)]
        }
        let retryCore = try await NativeRelayCore(store: relaunchedStore, context: context, session: retrySession)
        _ = try await retryCore.resyncAndDrainOutbox()

        XCTAssertEqual(retrySession.conversationReadPositionRequests.count, 1)
        let retryFrame = try JSONValue.parse(retrySession.conversationReadPositionRequests[0])
        XCTAssertEqual(retryFrame.uniqueValue(named: "op_id")?.stringValue,
                       firstFrame.uniqueValue(named: "op_id")?.stringValue,
                       "A retry of the same logical read reuses its durable operation identity.")
        let snapshot = try await relaunchedStore.conversationSnapshot(context: context)
        XCTAssertTrue(snapshot.pendingChatReadPositions.isEmpty)
        XCTAssertEqual(snapshot.chatReadPositions?[first], 1)
        XCTAssertFalse(try XCTUnwrap(snapshot.threads[first]).hasUnreadAgentReply)
        XCTAssertTrue(try XCTUnwrap(snapshot.threads[second]).hasUnreadAgentReply)
        await retryCore.deactivate()
    }

    func testReadPositionWireDoesNotRequireRevisionOrSessionHandle() async throws {
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

    func testOlderSavedConversationTurnSequenceIsRecoveredForDuplicateReplay() async throws {
        let request = RequestKey(accountScope: ExactText("person"),
            senderID: ExactText("author"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: request, revision: 1)
        let handle = ExactText("handle")
        let oldTurn = ConversationTurn(id: ExactText("reply-1"), binding: binding,
            author: .origin, sessionHandle: handle, text: ExactText("Reply"), kind: .reply)
        var thread = ConversationThread(request: request, sessionHandle: handle,
            revision: 1, payload: .null)
        let oldTurnEvent = ConversationEvent(sequence: 1, binding: binding, fact: .turn(oldTurn))
        try thread.merge(oldTurn, event: oldTurnEvent)
        var state = ConversationState()
        state.cursor = 1
        state.events[1] = oldTurnEvent
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

    func testResyncSnapshotDistinguishesOldServerFromEmptyReadMap() async throws {
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
        let core = try await NativeRelayCore(store: store, context: context, session: session,
                                       onDiagnostic: diagnostics.append)
        _ = try await core.resyncAndDrainOutbox()

        let snapshot = try await store.conversationSnapshot(context: context)
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
        let core = try await NativeRelayCore(store: store, context: context, session: session)
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
            let assertionSnapshot575_580 = try await store.conversationSnapshot(context: context)
            XCTAssertEqual(assertionSnapshot575_580.cursor, 2)
            let assertionSnapshot576_582 = try await store.snapshot(context: context)
            XCTAssertEqual(assertionSnapshot576_582.cursor, 1)
        }
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 1)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        XCTAssertEqual(session.conversationACKs.count, 1)
        let assertionSnapshot583_590 = try await store.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(assertionSnapshot583_590.threads.values.first)
        XCTAssertEqual(thread.turns.first?.id, ExactText("2"))
        XCTAssertEqual(thread.facts[ExactText("2")]?.delivered, true)
        XCTAssertNil(thread.facts[ExactText("2")]?.actedBy)
    }
    func testLiveAgentReplyAfterOpenIsCommittedThenACKedWithoutReconnect() async throws {
        let (context, persistence, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("discussion", sequence: 1, fields: #""author":"person","event_id":"2","text":"Explain""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        let listening = expectation(description: "listening for live conversation entries")
        listening.assertForOverFulfill = false
        session.onLiveConversationWait = { listening.fulfill() }
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        await fulfillment(of: [listening], timeout: 5)
        XCTAssertEqual(session.conversationACKs.count, 1)

        // The relay pushed the agent's receipt and reply on the open connection.
        let replyFrame = event("reply", sequence: 3,
            fields: #""author":"origin","event_id":"4","in_reply_to":"2","text":"Here is why""#)
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("receipt", sequence: 2, fields: #""author":"origin","event_id":"2","delivered":true"#),
            replyFrame,
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":3}"#)]
        let replyEvent = try ConversationWire(profile: context).decodeEvent(replyFrame)
        let receivedAtMilliseconds: UInt64 = 1_800_000_456_000
        let acknowledged = expectation(description: "live entries acknowledged")
        session.onConversationACK = {
            let assertionSnapshot612_620 = try await store.conversationSnapshot(context: context)
            XCTAssertEqual(assertionSnapshot612_620.cursor, 3)
            acknowledged.fulfill()
        }
        session.pushLiveConversation(replyEvent: replyEvent,
                                    receivedAtMilliseconds: receivedAtMilliseconds)
        await fulfillment(of: [acknowledged], timeout: 5)

        XCTAssertEqual(session.conversationACKs.count, 2)
        let assertionSnapshot620_629 = try await store.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(assertionSnapshot620_629.threads.values.first)
        let reply = try XCTUnwrap(thread.turns.first { $0.id == ExactText("4") })
        XCTAssertEqual(reply.author, .origin)
        XCTAssertEqual(reply.text, ExactText("Here is why"))
        XCTAssertEqual(reply.inReplyTo, ExactText("2"))
        let liveReceiptTime = try XCTUnwrap(thread.facts[reply.id]?.localLiveArrivalAtMilliseconds)
        XCTAssertEqual(liveReceiptTime, receivedAtMilliseconds,
                       "The reply keeps the receive time of its own live frame.")
        XCTAssertEqual(thread.facts[ExactText("2")]?.delivered, true)
        let assertionSnapshot629_639 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot629_639.cursor, 1)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        await core.deactivate()

        let restarted = try AttentionDomainStore(context: context, persistence: persistence)
        let assertionSnapshot634_645 = try await restarted.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot634_645
            .threads.values.first?.facts[reply.id]?.localLiveArrivalAtMilliseconds,
            liveReceiptTime, "The genuinely live receipt time survives store restart.")
    }

    func testFailedLiveReplayDoesNotTimestampOlderReplyFromLaterSignal() async throws {
        let (context, _, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("discussion", sequence: 1,
                  fields: #""author":"person","event_id":"2","text":"Explain""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]

        let listening = expectation(description: "listening after initial replay")
        session.onLiveConversationWait = { listening.fulfill() }
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        await fulfillment(of: [listening], timeout: 5)

        session.conversationOpenError = .serverRejected
        let rearmedAfterFailure = expectation(description: "listener rearmed after failed live replay")
        session.onLiveConversationWait = { rearmedAfterFailure.fulfill() }
        session.pushLiveConversation()
        await fulfillment(of: [rearmedAfterFailure], timeout: 5)

        let olderReplyFrame = event("reply", sequence: 2,
            fields: #""author":"origin","event_id":"reply-2","in_reply_to":"2","text":"Earlier reply""#)
        let newerReplyFrame = event("reply", sequence: 3,
            fields: #""author":"origin","event_id":"reply-3","in_reply_to":"2","text":"Later reply""#)
        let newerReply = try ConversationWire(profile: context).decodeEvent(newerReplyFrame)
        let newerArrival: UInt64 = 1_800_000_789_000
        session.conversationOpenError = nil
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            olderReplyFrame, newerReplyFrame,
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":3}"#)]
        let acknowledged = expectation(description: "later live replay committed and acknowledged")
        session.onConversationACK = {
            let assertionSnapshot670_682 = try await store.conversationSnapshot(context: context)
            XCTAssertEqual(assertionSnapshot670_682.cursor, 3)
            acknowledged.fulfill()
        }
        session.pushLiveConversation(replyEvent: newerReply,
                                    receivedAtMilliseconds: newerArrival)
        await fulfillment(of: [acknowledged], timeout: 5)

        let assertionSnapshot677_690 = try await store.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(assertionSnapshot677_690.threads.values.first)
        XCTAssertNil(thread.facts[ExactText("reply-2")]?.localLiveArrivalAtMilliseconds,
                     "An older replayed reply has no later reply's live receive time.")
        XCTAssertEqual(thread.facts[ExactText("reply-3")]?.localLiveArrivalAtMilliseconds,
                       newerArrival)
        await core.deactivate()
    }

    func testStartupReplayOmitsHistoricalReplyReceiptTimeFromBothRows() async throws {
        let (context, _, store, session) = try setup()
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("reply", sequence: 1,
                fields: #""author":"origin","event_id":"historical-reply","text":"An older reply""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]

        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()

        let assertionSnapshot697_711 = try await store.conversationSnapshot(context: context)
        let thread = try XCTUnwrap(assertionSnapshot697_711.threads[key])
        let reply = try XCTUnwrap(thread.turns.first { $0.id == ExactText("historical-reply") })
        let replySequence = try XCTUnwrap(reply.conversationSequence)
        XCTAssertNil(thread.facts[reply.id]?.localLiveArrivalAtMilliseconds,
                     "Startup/catch-up replay cannot invent a local live-arrival receipt.")
        XCTAssertNil(ReplyItemLocalReceiptTime.resolve(reply.id, in: thread),
                     "The compact New row's receipt-time source remains absent for history.")

        let item = InboxViewListItem(kind: .reply, key: key,
            conversationSequence: replySequence,
            openAtConversationSequence: replySequence,
            unseenCount: 1, score: 0.8, scoreKind: .current)
        XCTAssertNil(ReplyItemNormalRowProjection.resolve(item, in: thread)?.receivedAt,
                     "The normal reply row also omits a history/replay timestamp.")
        await core.deactivate()
    }

    func testMarkingAVisibleReplyDoesNotAdvanceThroughLaterReplies() async throws {
        let (context, _, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":0,"chat_read_positions":[]}"#)]
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()

        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: key, revision: 1)
        let handle = ExactText("handle")
        let discussion = ConversationTurn(id: ExactText("question"), binding: binding,
            author: .person, sessionHandle: handle, text: ExactText("Question"), kind: .discussion)
        let earliest = ConversationTurn(id: ExactText("reply-812"), binding: binding,
            author: .origin, sessionHandle: handle, text: ExactText("First unseen reply"),
            inReplyTo: discussion.id, kind: .reply)
        let later = ConversationTurn(id: ExactText("reply-819"), binding: binding,
            author: .origin, sessionHandle: handle, text: ExactText("Later offscreen reply"),
            inReplyTo: discussion.id, kind: .reply)
        for (sequence, turn) in [(1, discussion), (2, earliest), (3, later)] {
            try await store.applyConversation(ConversationEvent(sequence: UInt64(sequence),
                binding: binding, fact: .turn(turn)), context: context)
        }
        try await store.finishConversationReplay(at: 3, chatReadPositions: [], context: context)

        let firstReadResult = try await store.markConversationRead(key, through: earliest.id,
            context: context)
        let firstPending = try XCTUnwrap(firstReadResult)
        XCTAssertEqual(firstPending.readThroughConversationSequence, 2)
        let assertionSnapshot742_757 = try await store.conversationSnapshot(context: context)
        var thread = try XCTUnwrap(assertionSnapshot742_757.threads[key])
        XCTAssertEqual(thread.accountReadThroughConversationSequence, 2)
        XCTAssertEqual(thread.readThroughTurn, earliest.id)
        XCTAssertTrue(thread.hasUnreadAgentReply,
                      "The later reply remains unread until its own row is shown.")

        let laterReadResult = try await store.markConversationRead(key, through: later.id,
            context: context)
        let laterPending = try XCTUnwrap(laterReadResult)
        XCTAssertEqual(laterPending.readThroughConversationSequence, 3)
        let assertionSnapshot751_767 = try await store.conversationSnapshot(context: context)
        thread = try XCTUnwrap(assertionSnapshot751_767.threads[key])
        XCTAssertEqual(thread.accountReadThroughConversationSequence, 3)
        XCTAssertFalse(thread.hasUnreadAgentReply)
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
            let assertionSnapshot779_796 = try await store.conversationSnapshot(context: context)
            XCTAssertEqual(assertionSnapshot779_796.cursor, 7)
        }
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()

        XCTAssertEqual(session.conversationACKs, [data(#"{"v":1,"type":"conversation_ack","conversation_seq":7,"ref":"native-conversation-ack"}"# + "\n")])
        let threads = try await store.conversationSnapshot(context: context).threads
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
        let assertionSnapshot796_814 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot796_814.cursor, 2)
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
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()

        XCTAssertEqual(session.conversationACKs, [data(#"{"v":1,"type":"conversation_ack","conversation_seq":4,"ref":"native-conversation-ack"}"# + "\n")])
        var threads = try await store.conversationSnapshot(context: context).threads
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

        threads = try await store.conversationSnapshot(context: context).threads
        XCTAssertEqual(threads[earlier]?.isRetracted, true)
        XCTAssertEqual(threads[earlier]?.retraction?.retractedAtMilliseconds, 1792643952343)
        let assertionSnapshot835_854 = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot835_854.cursor, 4)
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
            event("acted", sequence: 5,
                fields: #""author":"origin","event_id":"5","acting_event_id":"6""#,
                messageID: "earlier", sessionHandle: "earlier-handle"),
            event("discussion", sequence: 6,
                fields: #""author":"person","event_id":"7","text":"Current request still works""#),
            event("receipt", sequence: 7, fields: #""author":"origin","event_id":"7","delivered":true"#),
            event("reply", sequence: 8,
                fields: #""author":"origin","event_id":"8","in_reply_to":"7","text":"Current reply""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":8}"#)]
        session.onConversationACK = {
            let assertionSnapshot864_884 = try await store.conversationSnapshot(context: context)
            XCTAssertEqual(assertionSnapshot864_884.cursor, 8)
            let assertionSnapshot865_886 = try await store.conversationSnapshot(context: context)
            XCTAssertNil(assertionSnapshot865_886.threads[earlier])
            let assertionSnapshot866_888 = try await store.conversationSnapshot(context: context)
            let current = try XCTUnwrap(assertionSnapshot866_888.threads.values.first)
            XCTAssertEqual(current.facts[ExactText("7")]?.delivered, true)
            XCTAssertEqual(current.turns.first { $0.id == ExactText("8") }?.text, ExactText("Current reply"))
        }

        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.conversationACKs, [data(#"{"v":1,"type":"conversation_ack","conversation_seq":8,"ref":"native-conversation-ack"}"# + "\n")])
        await core.deactivate()

        // The held events survive a store restart, then apply when inbox paging
        // eventually loads their request.
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let later = Session(context.identity)
        later.ordinary = [data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
            data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"author","message_id":"earlier","origin":"origin","as":"message","message":{"title":"Earlier request"},"session_handle":"earlier-handle","request_revision":1,"availability":"not_listening","last_detached_at":null}"#),
            data(#"{"v":1,"type":"resynced","seq":2}"#)]
        later.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":8}"#)]
        let resumed = try await NativeRelayCore(store: restored, context: context, session: later)
        _ = try await resumed.resyncAndDrainOutbox()

        let threads = try await restored.conversationSnapshot(context: context).threads
        let thread = try XCTUnwrap(threads[earlier])
        XCTAssertEqual(thread.availability, .listening)
        XCTAssertEqual(thread.latestAvailabilityObservation,
            ConversationAvailabilityObservation(state: .listening),
            "The replayed current availability remains after the duplicate delivery is ignored.")
        XCTAssertEqual(thread.turns.first { $0.id == ExactText("5") }?.text, ExactText("Hi there"))
        XCTAssertEqual(thread.facts[ExactText("5")]?.delivered, true)
        XCTAssertEqual(thread.facts[ExactText("5")]?.actedBy, ExactText("6"))
        XCTAssertEqual(thread.turns.first { $0.id == ExactText("6") }?.text, ExactText("Hello"))
        let assertionSnapshot898_921 = try await restored.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot898_921.cursor, 8)
        XCTAssertEqual(later.conversationACKs, [data(#"{"v":1,"type":"conversation_ack","conversation_seq":8,"ref":"native-conversation-ack"}"# + "\n")])
        await resumed.deactivate()
    }
    func testUnboundTierFactStaysInternalAndIsNotPresentedWhenDeliveryArrives() async throws {
        let (context, persistence, store, session) = try setup()
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("future"))
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"author","message_id":"future","origin":"future-origin","request_revision":1,"kind":"attention_tier","event_id":"tier-change","attention_tier":"low"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        session.onConversationACK = {
            let assertionSnapshot910_934 = try await store.conversationSnapshot(context: context)
            XCTAssertEqual(assertionSnapshot910_934.cursor, 1)
            let assertionSnapshot911_936 = try await store.snapshot(context: context)
            XCTAssertEqual(assertionSnapshot911_936.cursor, 1,
                           "Conversation replay must not advance the ordinary cursor.")
            let snapshot = try await store.snapshot(context: context)
            XCTAssertNil(snapshot.requests[key], "A tier fact must not create a duplicate message row.")
            XCTAssertNil(snapshot.remoteStates[key])
            XCTAssertEqual(snapshot.inboxReferences[key]?.attentionTier, .low,
                           "The tier fact must be durable before the conversation cursor is acknowledged.")
            XCTAssertEqual(snapshot.inboxReferences[key]?.attentionTierFeed, .conversation)
            let restored = try AttentionDomainStore(context: context, persistence: persistence)
            let assertionSnapshot920_946 = try await restored.snapshot(context: context)
            XCTAssertEqual(assertionSnapshot920_946.inboxReferences[key]?.attentionTier, .low)
        }

        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.conversationACKs.count, 1)

        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let payload = try JSONValue.parse(data(#"{"title":"Arrived later"}"#))
        try await restored.apply(RelayEvent(sequence: 2,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            origin: ExactText("future-origin"), attentionTier: .top), context: context)
        let port = AttentionDomainPort(store: restored)
        let rows = try await port.observe(context: port.context).requests.filter { $0.key == key }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.attentionTier, .middle,
                       "A stored attention tier is not presented by the client.")
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
            let assertionSnapshot947_974 = try await store.conversationSnapshot(context: context)
            let thread = try XCTUnwrap(assertionSnapshot947_974.threads.values.first)
            XCTAssertEqual(thread.terminal, .answered)
            XCTAssertEqual(thread.terminalTurn, ExactText("answer-2"))
            XCTAssertEqual(thread.terminalAuthor, .agent)
            XCTAssertEqual(thread.turns.count, 1)
            XCTAssertEqual(thread.turns.first?.kind, .terminal, "The ordinary lifecycle is durably committed before its ACK.")
        }
        session.onConversationACK = {
            let snapshot = try await store.conversationSnapshot(context: context)
            let thread = try XCTUnwrap(snapshot.threads.values.first)
            XCTAssertEqual(snapshot.cursor, 1)
            let assertionSnapshot958_986 = try await store.snapshot(context: context)
            XCTAssertEqual(assertionSnapshot958_986.cursor, 2)
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

        let core = try await NativeRelayCore(store: store, context: context, session: session)
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
            let snapshot = try await store.conversationSnapshot(context: context)
            let thread = try XCTUnwrap(snapshot.threads.values.first)
            let assertionSnapshot993_1022 = try await store.snapshot(context: context)
            XCTAssertEqual(assertionSnapshot993_1022.cursor, ordinaryACKCount == 1 ? 1 : 2)
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
            let assertionSnapshot1010_1040 = try await store.conversationSnapshot(context: context)
            let thread = try XCTUnwrap(assertionSnapshot1010_1040.threads.values.first)
            let assertionSnapshot1011_1042 = try await store.conversationSnapshot(context: context)
            XCTAssertEqual(assertionSnapshot1011_1042.cursor, 1)
            XCTAssertEqual(thread.terminal, conversationACKCount == 1 ? nil : .answered)
            XCTAssertEqual(thread.turns.count, conversationACKCount == 1 ? 1 : 2)
            let result = try XCTUnwrap(thread.turns.first { $0.id == ExactText("source-result-3") })
            XCTAssertEqual(result.author, .origin)
            XCTAssertEqual(result.text, ExactText(""))
            XCTAssertEqual(result.operationID, operationID)
            XCTAssertEqual(result.inReplyTo, ExactText("answer-2"))
            XCTAssertEqual(result.resultStatus, ExactText("received"))
            let assertionSnapshot1020_1052 = try await store.snapshot(context: context)
            XCTAssertEqual(assertionSnapshot1020_1052.cursor, UInt64(ordinaryACKCount))
        }

        let core = try await NativeRelayCore(store: store, context: context, session: session)
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
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 1)
        let assertionSnapshot1046_1079 = try await store.conversationSnapshot(context: context)
        XCTAssertTrue(assertionSnapshot1046_1079.threads.isEmpty)
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
        let core = try await NativeRelayCore(store: store, context: context, session: session,
                                       onDiagnostic: diagnostics.append)
        _ = try await core.resyncAndDrainOutbox()
        let snapshot = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(snapshot.cursor, 2)
        XCTAssertTrue(snapshot.threads.values.contains { $0.turns.contains { $0.id == ExactText("2") } })
        XCTAssertTrue(diagnostics.events.contains { $0.causeCode == "unknown_update_kind" })
        let assertionSnapshot1070_1104 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot1070_1104.cursor, 1)
        XCTAssertEqual(session.conversationACKs.count, 1)

        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","conversation_seq":3,"kind":"future_fact"}"#),
            event("reply", sequence: 4, fields: #""author":"agent","event_id":"4","text":"Next reply""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":4}"#)]
        await session.pushLiveConversation()
        await fulfillment(of: [liveACK], timeout: 2)
        let assertionSnapshot1079_1114 = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot1079_1114.cursor, 4)
        let assertionSnapshot1080_1116 = try await store.conversationSnapshot(context: context)
        XCTAssertTrue(assertionSnapshot1080_1116.threads.values
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
        let core = try await NativeRelayCore(store: store, context: context, session: session,
                                       onDiagnostic: diagnostics.append)
        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 2)
        let assertionSnapshot1096_1133 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot1096_1133.cursor, 2)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        XCTAssertTrue(diagnostics.events.contains { $0.causeCode == "unknown_update_kind" })
        await core.deactivate()
    }

    func testMalformedUnknownConversationFrameStillStopsItsReplay() async throws {
        let (context, _, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            data(#"{"v":1,"type":"conversation","kind":"future_fact"}"#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("An unknown update without a usable sequence cannot advance replay")
        } catch {
            XCTAssertEqual(error as? RelayWireError, .invalidFrame)
        }
        let assertionSnapshot1114_1152 = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot1114_1152.cursor, 0)
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
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.ordinaryACKs.count, 1)
        session.pushPostCheckpointInboxEvent(data(#"{"v":1,"type":"future_relay_update","seq":2}"#))
        await fulfillment(of: [postCheckpointACK], timeout: 2)
        let assertionSnapshot1135_1174 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot1135_1174.cursor, 2)
        XCTAssertEqual(session.ordinaryACKs.count, 2)
        await core.deactivate()
        session.finishPostCheckpointInboxEvents()
    }
    func testConversationGapAndWrongHighWaterCannotBeAcknowledged() async throws {
        for failure in ["gap", "wrong-high-water", "wrong-high-water-after-rejection"] {
            let (context, _, store, session) = try setup()
            let events: [Data]
            let barrierHighWater: Int
            if failure == "wrong-high-water-after-rejection" {
                events = [
                    data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"author","message_id":"request","origin":"reader","session_handle":"handle","request_revision":2,"kind":"revision","author":"person","event_id":"private-event-marker"}"#),
                    data(#"{"v":1,"type":"conversation","conversation_seq":2,"sender_id":"author","message_id":"request","origin":"origin","session_handle":"handle","request_revision":2,"kind":"revision","author":"origin","event_id":"valid-event","message":{"title":"Later wording"}}"#)
                ]
                barrierHighWater = 1
            } else {
                events = [event("discussion", sequence: failure == "gap" ? 2 : 1,
                    fields: #""author":"person","event_id":"2","text":"Explain""#)]
                barrierHighWater = 2
            }
            session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#)] + events +
                [data(#"{"v":1,"type":"conversation_resynced","conversation_seq":\#(barrierHighWater)}"#)]
            let core = try await NativeRelayCore(store: store, context: context, session: session)
            do { _ = try await core.resyncAndDrainOutbox(); XCTFail("Noncontiguous replay must fail") }
            catch { XCTAssertEqual(error as? NativeRelayCoreError, .invalidReplay) }
            let snapshot = try await store.conversationSnapshot(context: context)
            if failure == "gap" {
                XCTAssertEqual(snapshot.cursor, 0)
            } else if failure == "wrong-high-water-after-rejection" {
                XCTAssertEqual(snapshot.cursor, 2,
                    "The rejected sequence advances the cursor by one and the later valid event commits before the bad barrier.")
            } else {
                XCTAssertEqual(snapshot.cursor, 1)
            }
            XCTAssertTrue(session.conversationACKs.isEmpty)
            await core.deactivate()
        }
    }
    func testFailedConversationPersistenceLeavesItsCursorUnacknowledged() async throws {
        let (context, persistence, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("discussion", sequence: 1, fields: #""author":"person","event_id":"2","text":"Explain""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        session.onConversationOpen = { persistence.failNextCommit() }
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        do { _ = try await core.resyncAndDrainOutbox(); XCTFail("Failed durability must stop ACK") }
        catch {}
        let assertionSnapshot1183_1223 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot1183_1223.cursor, 1)
        let assertionSnapshot1184_1225 = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot1184_1225.cursor, 0)
        XCTAssertTrue(session.conversationACKs.isEmpty)
    }
    func testLostConversationACKReplaysExactHistoryWithoutChangingOrdinaryCursor() async throws {
        let (context, _, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("discussion", sequence: 1, fields: #""author":"person","event_id":"2","text":"Explain""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        session.rejectFirstConversationACK = true
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.conversationACKs.count, 2)
        let assertionSnapshot1196_1238 = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot1196_1238.cursor, 1)
        let assertionSnapshot1197_1240 = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot1197_1240.threads.values.first?.turns.count, 1)
        let assertionSnapshot1198_1242 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot1198_1242.cursor, 1)
        XCTAssertEqual(session.ordinaryACKs.count, 1)
    }
    func testInlineOriginalBytesAndIndependentFileFactsDecodeWithoutInferringUse() async throws {
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

    func testDeliveryAckFramesDecodeTheContractMarkerStagesAndRerouteBit() async throws {
        let (context, _, _, _) = try setup()
        let wire = try ConversationWire(profile: context)
        let discussion = try wire.decodeEvent(event("discussion", sequence: 1,
            fields: #""author":"person","event_id":"812","text":"Check the build","delivery_acks":true"#))
        guard case let .turn(turn) = discussion.fact else { return XCTFail("Expected discussion turn") }
        XCTAssertEqual(turn.deliveryAcks, true)

        let legacy = try wire.decodeEvent(event("discussion", sequence: 2,
            fields: #""author":"person","event_id":"813","text":"Older Server message""#))
        guard case let .turn(legacyTurn) = legacy.fact else { return XCTFail("Expected legacy discussion turn") }
        XCTAssertNil(legacyTurn.deliveryAcks)

        let ack1 = try wire.decodeEvent(event("delivery_ack", sequence: 3,
            fields: #""stage":"ack1","event_id":"812","at_ms":40000,"acknowledger":{},"ack2_expected":true"#))
        guard case let .deliveryAck(ack1Turn, .listenerReceived(at, expected, system, agent)) = ack1.fact else {
            return XCTFail("Expected ACK1 fact")
        }
        XCTAssertEqual(ack1Turn, turn.id)
        XCTAssertEqual(at, 40_000)
        XCTAssertTrue(expected)
        XCTAssertNil(system, "r5 permits the receiving system name to be absent.")
        XCTAssertNil(agent)

        let incapableAck1 = try wire.decodeEvent(event("delivery_ack", sequence: 4,
            fields: #""stage":"ack1","event_id":"812","at_ms":45000,"acknowledger":{},"ack2_expected":false"#))
        guard case let .deliveryAck(_, .listenerReceived(_, ack2Expected, _, _)) = incapableAck1.fact else {
            return XCTFail("Expected ACK1 final for an incapable listener")
        }
        XCTAssertFalse(ack2Expected)

        let ack2 = try wire.decodeEvent(event("delivery_ack", sequence: 5,
            fields: #""stage":"ack2","event_id":"812","at_ms":50000,"acknowledger":{"system":"Tightbeam","agent":"Release orchestrator"},"outcome":"handed","rerouted":true"#))
        guard case let .deliveryAck(_, .handed(ack2At, rerouted, _, routedAgent)) = ack2.fact else {
            return XCTFail("Expected handed ACK2 fact")
        }
        XCTAssertEqual(ack2At, 50_000)
        XCTAssertTrue(rerouted)
        XCTAssertEqual(routedAgent, ExactText("Release orchestrator"))

        let negative = try wire.decodeEvent(event("delivery_ack", sequence: 6,
            fields: #""stage":"ack2","event_id":"812","at_ms":60000,"acknowledger":{},"outcome":"not_handed","reason":"The receiving system could not hand it off.""#))
        guard case let .deliveryAck(_, .notHanded(negativeAt, reason, system, agent)) = negative.fact else {
            return XCTFail("Expected negative ACK2 fact")
        }
        XCTAssertEqual(negativeAt, 60_000)
        XCTAssertEqual(reason, ExactText("The receiving system could not hand it off."))
        XCTAssertNil(system)
        XCTAssertNil(agent)
    }

    func testSupportProvenanceAndOriginRedactionAreExplicitAndClosureIsNotConversation() async throws {
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
