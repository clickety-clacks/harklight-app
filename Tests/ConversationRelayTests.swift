import AttentionDomain
import CryptoKit
import HarklightNativeRelay
import XCTest

final class ConversationRelayTests: XCTestCase {
    private final class Session: AuthenticatedInboxPagingSession, AuthenticatedConversationEventSession, @unchecked Sendable {
        let authenticatedIdentity: ProfileIdentity
        var ordinary: [Data] = []
        var conversation: [Data] = []
        var ordinaryACKs: [Data] = []
        var conversationACKs: [Data] = []
        var onOrdinaryACK: (() throws -> Void)?
        var onConversationACK: (() throws -> Void)?
        var onConversationOpen: (() -> Void)?
        var conversationOpenError: InstallationTransportError?
        var rejectFirstConversationACK = false
        var onLiveConversationWait: (() -> Void)?
        private var liveConversation: CheckedContinuation<Void, any Error>?
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
    private func event(_ kind: String, sequence: Int, fields: String) -> Data {
        data("{\"v\":1,\"type\":\"conversation\",\"conversation_seq\":\(sequence),\"sender_id\":\"author\",\"message_id\":\"request\",\"origin\":\"origin\",\"session_handle\":\"handle\",\"request_revision\":1,\"kind\":\"\(kind)\",\(fields)}")
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
    func testUnknownConversationKindCannotAdvanceOrACKItsHighWater() async throws {
        let (context, _, store, session) = try setup()
        session.conversation = [data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#),
            event("future_fact", sequence: 1, fields: #""event_id":"2""#),
            data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#)]
        let core = try NativeRelayCore(store: store, context: context, session: session)
        do { _ = try await core.resyncAndDrainOutbox(); XCTFail("Unknown event must refuse replay") }
        catch { XCTAssertEqual(error as? RelayWireError, .unsupportedEvent) }
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, 0)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertTrue(session.conversationACKs.isEmpty)
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
