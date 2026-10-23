import AttentionDomain
import HarklightNativeRelay
import XCTest
@testable import Harklight

@MainActor
final class RetractionPresentationTests: XCTestCase {
    private static let retractedAt: UInt64 = 1_760_000_000_123
    private static let retractedAtSeconds: TimeInterval = 1_760_000_000.123
    private let ordinary = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"request","origin":"origin","state":"cleared","terminal_reason":"retracted","by":"origin_withdrawal","author":"origin","event_id":"3","request_revision":1,"at":1760000000123,"retracted_at":1760000000123}"#.utf8)
    private let projected = Data(#"{"v":1,"type":"conversation","conversation_seq":1,"kind":"retraction","sender_id":"sender","message_id":"request","origin":"origin","author":"origin","session_handle":"handle","event_id":"3","request_revision":1,"terminal_seq":2,"terminal_state":"retracted","retracted_at":1760000000123}"#.utf8)
    /// Inbox page and reconcile terminals keep the legacy lifecycle field set.
    private let snapshotTerminal = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"request","origin":"origin","state":"cleared","terminal_reason":"retracted","by":"origin_withdrawal","at":1760000000123,"retracted_at":1760000000123}"#.utf8)
    private let refusal = Data(#"{"v":1,"type":"error","reason":"retracted","terminal":{"state":"retracted","retracted_at":1760000000123}}"#.utf8)

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
            XCTAssertEqual(try midway.conversationSnapshot(context: context).threads[key]?.retraction?.retractedAtMilliseconds,
                           Self.retractedAt, "Either durable copy alone carries the retraction time")
            XCTAssertTrue(try midway.snapshot(context: context).outbox.isEmpty)
            let closedSelector = try midway.selector(for: key, context: context)
            XCTAssertThrowsError(try port.submit(SubmitIntent(context: port.context, selector: closedSelector,
                intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("keep"))])))
            if conversationFirst { try domain.apply(lifecycle, context: context) }
            else { try domain.applyConversation(fact, context: context) }
            try domain.apply(lifecycle, context: context)
            try domain.applyConversation(fact, context: context)
            let thread = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[key])
            let savedAnswer = try XCTUnwrap(port.inspectAnswerDraft(context: port.context, request: key, revision: 1))
            XCTAssertEqual(savedAnswer.title, ExactText("Original wording"))
            XCTAssertEqual(savedAnswer.draft.compatibility.selectedActionID, ExactText("keep"))
            XCTAssertNil(savedAnswer.selector)
            XCTAssertEqual(thread.turns.filter { $0.kind == .terminal }.count, 1)
            XCTAssertEqual(thread.terminalTurn, ExactText("3"))
            XCTAssertEqual(thread.retraction?.terminalSequence, 2)
            XCTAssertEqual(thread.retraction?.retractedAtMilliseconds, Self.retractedAt)
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
            XCTAssertEqual(model.retractionDate(key)?.timeIntervalSince1970 ?? 0, Self.retractedAtSeconds, accuracy: 0.000_5)
            XCTAssertTrue(model.inboxRows.first?.status.contains(model.retractionLabel(key)) == true)
            XCTAssertNotEqual(model.retractionLabel(key), "Retracted", "The shown retraction carries its time")
            XCTAssertEqual(model.request(for: key)?.lifecycleStatus, .cleared)
            XCTAssertEqual(try domain.snapshot(context: context).requests.count, 1)
        }
    }

    func testEveryRetractionWireShapeRequiresItsRetractionTime() throws {
        let context = profile()
        let relay = try RelayWire(profile: context)
        let conversation = try ConversationWire(profile: context)
        XCTAssertEqual(try relay.decodeEvent(ordinary).conversation?.retractedAtMilliseconds, Self.retractedAt)
        XCTAssertEqual(try conversation.decodeEvent(projected).retractedAtMilliseconds, Self.retractedAt)
        XCTAssertThrowsError(try relay.decodeEvent(edited(ordinary, #","retracted_at":1760000000123"#, "")))
        XCTAssertThrowsError(try relay.decodeEvent(edited(ordinary, #""at":1760000000123"#, #""at":1760000000124"#)),
                             "The lifecycle time and the retraction time are one fact")
        XCTAssertThrowsError(try conversation.decodeEvent(edited(projected, #","retracted_at":1760000000123"#, "")))
        let snapshot = try relay.decodeEvent(snapshotTerminal)
        XCTAssertEqual(snapshot.conversation?.terminalReason, ExactText("retracted"))
        XCTAssertEqual(snapshot.conversation?.retractedAtMilliseconds, Self.retractedAt)
        XCTAssertNil(snapshot.conversation?.revision)
        XCTAssertThrowsError(try relay.decodeEvent(edited(snapshotTerminal, #","retracted_at":1760000000123"#, "")))
        XCTAssertThrowsError(try relay.decodeEvent(edited(snapshotTerminal, #""at":1760000000123"#, #""at":1760000000124"#)))
        XCTAssertNil(try relay.decodeEvent(edited(snapshotTerminal, #""terminal_reason":"retracted","#, "")).conversation,
                     "A plain legacy terminal still carries no conversation meaning")
    }

    func testFreshInboxPageKeepsTheRetractionTimeOfItsTerminal() throws {
        let context = profile()
        let persistence = MemoryAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        let delivery = #"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"request","origin":"origin","as":"message","message":{"title":"Retained question"},"request_revision":1,"session_handle":"handle","event_id":"1"}"#
        let frame = Data((#"{"v":1,"type":"ok","ref":"native-inbox","paging_version":1,"snapshot_id":"snapshot","high_water":2,"items":[{"acceptance":"#
            + delivery + #","terminal":"# + String(decoding: snapshotTerminal, as: UTF8.self)
            + #"}],"next_cursor":null,"receipt_cursor":null}"#).utf8)
        let page = try InboxPagingWire(profile: context).decodeStart(frame, ref: "native-inbox")
        XCTAssertEqual(page.items.first?.terminal?.conversation?.retractedAtMilliseconds, Self.retractedAt)
        _ = try domain.beginInboxCandidate(startupID: "startup", since: 0, batches: [], context: context)
        try domain.saveInboxInitialPage(snapshotID: page.snapshotID, highWater: page.highWater, items: page.items,
                                        nextCursor: page.nextCursor, receiptCursor: page.receiptCursor, context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let thread = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[key])
        XCTAssertTrue(thread.isRetracted)
        XCTAssertEqual(thread.terminal, .cleared)
        XCTAssertEqual(thread.reportedRetractedAtMilliseconds, Self.retractedAt)
        try restored.applyConversation(ConversationWire(profile: context).decodeEvent(projected), context: context)
        XCTAssertEqual(try restored.conversationSnapshot(context: context).threads[key]?.retraction?.retractedAtMilliseconds,
                       Self.retractedAt, "The conversation stream adds the retraction turn at the same time")
    }

    func testDefinitiveAnswerRefusalRequiresTheRetractedTerminalSnapshot() throws {
        let wire = try RelayWire(profile: profile())
        let operationID = UUID()
        XCTAssertEqual(try wire.decodeAnswerRefusal(refusal, operationID: operationID),
                       .refusedByRetraction(operationID: operationID, retractedAtMilliseconds: Self.retractedAt))
        XCTAssertNil(try wire.decodeAnswerRefusal(Data(#"{"v":1,"type":"error","reason":"closed"}"#.utf8), operationID: operationID),
                     "Other refusals keep their existing unresolved meaning")
        XCTAssertThrowsError(try wire.decodeAnswerRefusal(Data(#"{"v":1,"type":"error","reason":"retracted"}"#.utf8),
                                                          operationID: operationID))
        XCTAssertThrowsError(try wire.decodeAnswerRefusal(edited(refusal, #""state":"retracted""#, #""state":"cleared""#),
                                                          operationID: operationID))
        XCTAssertThrowsError(try wire.decodeAnswerRefusal(edited(refusal, #","retracted_at":1760000000123"#, ""),
                                                          operationID: operationID))
    }

    func testRefusedQueuedAnswerIsKeptAsRefusedAndShownRetracted() async throws {
        let context = profile()
        let persistence = MemoryAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        let payload = try JSONValue.parse(Data(#"{"title":"Original wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"keep","label":"Keep original choice","kind":"value","value":"keep"}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("handle"), eventID: ExactText("1"))), context: context)
        let port = AttentionDomainPort(store: domain)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
            inputs: [.compatibilityValue(action: ExactText("keep"))]))
        let refused = IntentDisposition.refusedByRetraction(retractedAtMilliseconds: Self.retractedAt)
        let session = RefusalSession(context.identity, refusal: refusal, profile: context)
        let core = try NativeRelayCore(store: domain, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])

        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        XCTAssertEqual(try restored.lookupIntent(receipt.intentID, context: context)?.disposition, refused)
        XCTAssertTrue(try restored.snapshot(context: context).outbox.isEmpty)
        let live = try LivePresentationStore(store: restored, context: context)
        let shown = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(shown.lifecycleStatus, .cleared)
        XCTAssertEqual(shown.receiptFacts?.ownOutcome, .refused)
        XCTAssertTrue(live.isRetracted(key))
        XCTAssertEqual(live.retractionDate(key)?.timeIntervalSince1970 ?? 0, Self.retractedAtSeconds, accuracy: 0.000_5)
        XCTAssertFalse(live.openRequests.contains { $0.key == key }, "A refused answer no longer needs attention")
        XCTAssertThrowsError(try port.submit(SubmitIntent(context: port.context, selector: try domain.selector(for: key, context: context),
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("keep"))])))

        _ = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID], "A definite refusal is never resent")

        let otherTime = try RelayWire(profile: context).decodeEvent(edited(ordinary, "1760000000123", "1760000000999"))
        XCTAssertThrowsError(try domain.apply(otherTime, context: context))
        XCTAssertEqual(try domain.lookupIntent(receipt.intentID, context: context)?.disposition, refused)

        try domain.apply(RelayWire(profile: context).decodeEvent(ordinary), context: context)
        try domain.applyConversation(ConversationWire(profile: context).decodeEvent(projected), context: context)
        XCTAssertEqual(try domain.lookupIntent(receipt.intentID, context: context)?.disposition, refused,
                       "The later retraction copies keep the exact refusal")
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[key]?.retraction?.retractedAtMilliseconds,
                       Self.retractedAt)
        let settled = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(settled.request(for: key)?.lifecycleStatus, .cleared)
        XCTAssertEqual(settled.request(for: key)?.receiptFacts?.ownOutcome, .refused)
        XCTAssertTrue(settled.isRetracted(key))
    }

    func testDeliveryReadAfterRetractionShowsItRetractedUntilItsLifecycleAgrees() throws {
        let delivery = Data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"request","origin":"origin","as":"message","message":{"title":"Retained question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"keep","label":"Keep","kind":"value","value":"keep"}]}},"request_revision":1,"session_handle":"handle","event_id":"1","state":"retracted","retracted_at":1760000000123}"#.utf8)
        let wire = try RelayWire(profile: profile())
        XCTAssertEqual(try wire.decodeEvent(delivery).conversation?.retractedAtMilliseconds, Self.retractedAt)
        XCTAssertThrowsError(try wire.decodeEvent(edited(delivery, #","retracted_at":1760000000123"#, "")))
        for lifecycleAgrees in [true, false] {
            let context = profile()
            let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
            let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
            try domain.apply(try RelayWire(profile: context).decodeEvent(delivery), context: context)
            let port = AttentionDomainPort(store: domain)
            let selector = try domain.selector(for: key, context: context)
            XCTAssertThrowsError(try port.submit(SubmitIntent(context: port.context, selector: selector,
                intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("keep"))])), "A retracted message takes no new answer")
            let model = try LivePresentationStore(store: domain, context: context)
            XCTAssertTrue(model.isRetracted(key))
            XCTAssertEqual(model.retractionDate(key)?.timeIntervalSince1970 ?? 0, Self.retractedAtSeconds, accuracy: 0.000_5)
            XCTAssertEqual(model.request(for: key)?.lifecycleStatus, .cleared)
            XCTAssertEqual(model.request(for: key)?.title, ExactText("Retained question"))
            XCTAssertFalse(model.openRequests.contains { $0.key == key }, "A retracted message no longer needs attention")
            let lifecycle = try RelayWire(profile: context).decodeEvent(
                lifecycleAgrees ? ordinary : edited(ordinary, "1760000000123", "1760000000124"))
            if lifecycleAgrees {
                try domain.apply(lifecycle, context: context)
                XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[key]?.retraction?.retractedAtMilliseconds,
                               Self.retractedAt)
            } else {
                XCTAssertThrowsError(try domain.apply(lifecycle, context: context), "One retraction has one time")
            }
        }
    }

    func testClearingARetractedRowIsDeviceLocalListStateOnly() throws {
        let namespace = "Harklight.cleared-retractions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let context = profile()
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let retractedKey = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        let staleKey = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("stale"))
        let openKey = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("open"))
        let retractedDelivery = Data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"request","origin":"origin","as":"message","message":{"title":"Retained question"},"request_revision":1,"session_handle":"handle","event_id":"1","state":"retracted","retracted_at":1760000000123}"#.utf8)
        try domain.apply(try RelayWire(profile: context).decodeEvent(retractedDelivery), context: context)
        for (sequence, key) in [(UInt64(2), staleKey), (UInt64(3), openKey)] {
            try domain.apply(RelayEvent(sequence: sequence, body: .delivery(StoredRequest(key: key,
                originalPayload: .object([JSONMember("title", .string(ExactText("Open question")))])), .message),
                conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("handle"),
                                                        eventID: ExactText("\(sequence)"))), context: context)
        }
        defaults.set(try JSONEncoder().encode(Set([staleKey])), forKey: "harklight.cleared-retracted-requests")
        let model = try LivePresentationStore(store: domain, context: context, clearedRetractionDefaults: defaults)
        XCTAssertEqual(model.inboxRows.count, 3, "A stale cleared entry hides nothing unless its request is retracted")
        XCTAssertTrue(try XCTUnwrap(model.inboxRows.first { $0.key == retractedKey }).isRetracted)
        XCTAssertFalse(try XCTUnwrap(model.inboxRows.first { $0.key == staleKey }).isRetracted)
        model.clearRetracted(openKey)
        XCTAssertFalse(model.isRetractionCleared(openKey), "Only a retracted row can be cleared")
        model.clearRetracted(retractedKey)
        XCTAssertEqual(Set(model.inboxRows.map(\.key)), [staleKey, openKey])
        XCTAssertNil(model.inboxRow(for: retractedKey), "A direct detail lookup must not reintroduce a cleared row")
        XCTAssertEqual(model.inboxRow(for: openKey)?.status,
                       try XCTUnwrap(model.inboxRows.first { $0.key == openKey }).status)
        XCTAssertTrue(model.isRetracted(retractedKey), "Clearing hides the row; the retracted record stays")
        XCTAssertTrue(try domain.snapshot(context: context).outbox.isEmpty, "Clearing sends no frame")
        XCTAssertEqual(try domain.snapshot(context: context).requests.count, 3)
        let restarted = try LivePresentationStore(store: domain, context: context, clearedRetractionDefaults: defaults)
        XCTAssertEqual(Set(restarted.inboxRows.map(\.key)), [staleKey, openKey], "The cleared row stays hidden after relaunch")
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

    private func edited(_ frame: Data, _ target: String, _ replacement: String) -> Data {
        let text = String(decoding: frame, as: UTF8.self)
        precondition(text.contains(target))
        return Data(text.replacingOccurrences(of: target, with: replacement).utf8)
    }

    private func profile() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("reader")), transportMode: .relay)
    }
}

private final class RetractionSession: AuthenticatedInboxPagingSession, AuthenticatedConversationSession, @unchecked Sendable {
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

private final class RefusalSession: AuthenticatedInboxPagingSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    let refusal: Data
    let profile: ProfileContext
    private(set) var sentOperationIDs: [UUID] = []
    init(_ identity: ProfileIdentity, refusal: Data, profile: ProfileContext) {
        authenticatedIdentity = identity; self.refusal = refusal; self.profile = profile
    }
    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        try await consume(Data(#"{"v":1,"type":"ok","ref":"native-sync"}"#.utf8))
        try await consume(Data(#"{"v":1,"type":"resynced","seq":1}"#.utf8))
    }
    func acknowledge(_ request: Data) async throws {}
    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        sentOperationIDs.append(operationID)
        return try RelayWire(profile: profile).decodeAnswerRefusal(refusal, operationID: operationID) ?? .unresolved
    }
}
