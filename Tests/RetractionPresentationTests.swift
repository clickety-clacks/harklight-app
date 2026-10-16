import AttentionDomain
import HarklightNativeRelay
import XCTest
@testable import AttentionClientDuoPrototype

@MainActor
final class RetractionPresentationTests: XCTestCase {
    private let ordinary = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"request","origin":"origin","state":"cleared","terminal_reason":"retracted","by":"origin_withdrawal","author":"origin","event_id":"3","request_revision":1}"#.utf8)
    private let projected = Data(#"{"v":1,"type":"conversation","conversation_seq":1,"kind":"retraction","sender_id":"sender","message_id":"request","origin":"origin","author":"origin","session_handle":"handle","event_id":"3","request_revision":1,"terminal_seq":2,"terminal_state":"retracted"}"#.utf8)

    func testInstalledDecoderAcceptsTheSameAdditiveLifecycleWithoutChangingItsLegacyMeaning() throws {
        let context = profile()
        let decoded = try InstalledRelayDecoder.RelayWire(profile: context).decodeEvent(ordinary)
        XCTAssertEqual(decoded.sequence, 2)
        guard case let .terminal(_, state, answer) = decoded.body else { return XCTFail("Expected the installed terminal path") }
        XCTAssertEqual(state, .cleared)
        XCTAssertNil(answer)
        let literal = Data(String(decoding: ordinary, as: UTF8.self).replacingOccurrences(of: #""state":"cleared""#, with: #""state":"retracted""#).utf8)
        XCTAssertThrowsError(try InstalledRelayDecoder.RelayWire(profile: context).decodeEvent(literal))
    }

    func testRetractionJoinsBothDurableOrdersWithoutRewritingQueuedBindingsOrReopening() throws {
        for conversationFirst in [false, true] {
            let context = profile()
            let persistence = MemoryAttentionStatePersistence()
            let domain = try AttentionDomainStore(context: context, persistence: persistence)
            let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
            let payload = try JSONValue.parse(Data(#"{"title":"Original wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"keep","label":"Keep original choice","kind":"value","value":"keep"}]}}"#.utf8))
            try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
                conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("handle"), eventID: ExactText("1"))), context: context)
            let port = AttentionDomainPort(store: domain)
            let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
            var draft = try XCTUnwrap(domain.snapshot(context: context).drafts[key])
            draft.compatibility.selectedActionID = ExactText("keep")
            try domain.saveDraft(draft, selector: selector, context: context)
            let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                inputs: [.compatibilityValue(action: ExactText("keep"))]))
            let original = try XCTUnwrap(domain.lookupIntent(receipt.intentID, context: context))
            let binding = ConversationBinding(request: key, revision: 1)
            try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Unsent original note")), context: context)
            let lifecycle = try RelayWire(profile: context).decodeEvent(ordinary)
            let fact = try ConversationWire(profile: context).decodeEvent(projected)
            if conversationFirst {
                try domain.applyConversation(fact, context: context)
                XCTAssertEqual(try domain.snapshot(context: context).cursor, 1, "Referenced terminal sequence must not advance ordinary cursor")
            } else {
                try domain.apply(lifecycle, context: context)
                XCTAssertEqual(try domain.conversationSnapshot(context: context).cursor, 0)
            }
            let midway = try AttentionDomainStore(context: context, persistence: persistence)
            XCTAssertTrue(try midway.conversationSnapshot(context: context).threads[key]?.isRetracted == true)
            XCTAssertTrue(try midway.snapshot(context: context).outbox.isEmpty)
            let closedSelector = try midway.selector(for: key, context: context)
            XCTAssertThrowsError(try port.submit(SubmitIntent(context: port.context, selector: closedSelector,
                intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("keep"))])))
            if conversationFirst { try domain.apply(lifecycle, context: context) }
            else { try domain.applyConversation(fact, context: context) }
            try domain.apply(lifecycle, context: context)
            try domain.applyConversation(fact, context: context)
            let thread = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[key])
            XCTAssertEqual(thread.turns.filter { $0.kind == .terminal }.count, 1)
            XCTAssertEqual(thread.terminalTurn, ExactText("3"))
            XCTAssertEqual(thread.retraction?.terminalSequence, 2)
            XCTAssertEqual(thread.drafts[1]?.text, ExactText("Unsent original note"))
            XCTAssertEqual(thread.drafts[1]?.disposition, .rejected(ExactText("Not delivered: request retracted")))
            let retained = try XCTUnwrap(domain.lookupIntent(receipt.intentID, context: context))
            XCTAssertEqual(retained.operation, original.operation)
            XCTAssertEqual(retained.operationID, original.operationID)
            XCTAssertEqual(retained.requestRevision, 1)
            XCTAssertEqual(retained.disposition, .terminal(state: .cleared, sequence: 2, authorizedAnswer: nil))
            let later = ConversationTurn(id: ExactText("2"), binding: ConversationBinding(request: key, revision: 2),
                author: .origin, sessionHandle: ExactText("handle"), text: ExactText("Earlier accepted history"), kind: .revision)
            try domain.applyConversation(ConversationEvent(sequence: 2, binding: later.binding, fact: .revision(later, payload: payload)), context: context)
            let laterSelector = try domain.selector(for: key, context: context)
            XCTAssertThrowsError(try port.submit(SubmitIntent(context: port.context, selector: laterSelector,
                intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("keep"))])))
            XCTAssertEqual(try domain.lookupIntent(receipt.intentID, context: context), retained)
            let model = try LivePresentationStore(store: domain, context: context)
            XCTAssertTrue(model.isRetracted(key))
            XCTAssertTrue(model.inboxRows.first?.status.contains("Retracted") == true)
            XCTAssertEqual(model.request(for: key)?.lifecycleStatus, .cleared)
            XCTAssertEqual(try domain.snapshot(context: context).requests.count, 1)
        }
    }

    func testPlainOriginClearHasNoRetractionMeaning() throws {
        let context = profile()
        let plain = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"request","origin":"origin","state":"cleared","by":"origin_withdrawal","author":"origin","event_id":"3","request_revision":1}"#.utf8)
        let event = try RelayWire(profile: context).decodeEvent(plain)
        XCTAssertNil(event.conversation?.terminalReason)
    }

    func testEachCursorAcknowledgesOnlyItsDurableRetractionCopy() async throws {
        for failConversationCommit in [false, true] {
            let context = profile()
            let persistence = MemoryAttentionStatePersistence()
            let domain = try AttentionDomainStore(context: context, persistence: persistence)
            let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
            try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key,
                originalPayload: .object([JSONMember("title", .string(ExactText("Retained question")))])), .message),
                conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("handle"), eventID: ExactText("1"))), context: context)
            let session = RetractionSession(domain: domain, context: context, persistence: persistence,
                ordinary: ordinary, projected: projected, failConversationCommit: failConversationCommit)
            let core = try NativeRelayCore(store: domain, context: context, session: session)
            do {
                _ = try await core.resyncAndDrainOutbox()
                XCTAssertFalse(failConversationCommit)
            } catch { XCTAssertTrue(failConversationCommit, "Unexpected replay failure: \(error)") }
            XCTAssertTrue(session.ordinaryAcknowledged)
            XCTAssertEqual(session.conversationAcknowledged, !failConversationCommit)
            let restored = try AttentionDomainStore(context: context, persistence: persistence)
            XCTAssertEqual(try restored.snapshot(context: context).cursor, 2)
            XCTAssertEqual(try restored.conversationSnapshot(context: context).cursor, failConversationCommit ? 0 : 1)
            XCTAssertTrue(try restored.conversationSnapshot(context: context).threads[key]?.isRetracted == true)
        }
    }

    private func profile() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("reader")), transportMode: .relay)
    }
}

private final class RetractionSession: AuthenticatedConversationSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    let domain: AttentionDomainStore
    let context: ProfileContext
    let persistence: MemoryAttentionStatePersistence
    let ordinary: Data
    let projected: Data
    let failConversationCommit: Bool
    private(set) var ordinaryAcknowledged = false
    private(set) var conversationAcknowledged = false
    init(domain: AttentionDomainStore, context: ProfileContext, persistence: MemoryAttentionStatePersistence,
         ordinary: Data, projected: Data, failConversationCommit: Bool) {
        self.authenticatedIdentity = context.identity
        self.domain = domain; self.context = context; self.persistence = persistence
        self.ordinary = ordinary; self.projected = projected; self.failConversationCommit = failConversationCommit
    }
    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        try await consume(Data(#"{"v":1,"type":"ok","ref":"native-sync"}"#.utf8))
        try await consume(ordinary)
        try await consume(Data(#"{"v":1,"type":"resynced","seq":2}"#.utf8))
    }
    func acknowledge(_ request: Data) async throws {
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        guard try restored.snapshot(context: context).cursor == 2,
              try restored.conversationSnapshot(context: context).threads.values.first?.isRetracted == true else {
            throw NativeRelayCoreError.eventRejected
        }
        ordinaryAcknowledged = true
    }
    func openConversation(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        try await consume(Data(#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#.utf8))
        if failConversationCommit { persistence.failNextCommit() }
        try await consume(projected)
        try await consume(Data(#"{"v":1,"type":"conversation_resynced","conversation_seq":1}"#.utf8))
    }
    func acknowledgeConversation(_ request: Data) async throws {
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        guard try restored.conversationSnapshot(context: context).cursor == 1 else { throw NativeRelayCoreError.eventRejected }
        conversationAcknowledged = true
    }
    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult { .unresolved }
}
