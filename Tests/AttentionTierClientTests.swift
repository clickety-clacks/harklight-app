import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest

final class AttentionTierClientTests: XCTestCase {
    private func context() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("reader-account"), deviceID: ExactText("reader")), transportMode: .relay)
    }

    private func data(_ value: String) -> Data { Data(value.utf8) }

    func testInboxPageTierIsDecodedFromWrapperAndMissingValueDefaultsToMiddle() throws {
        let frame = #"{"v":1,"type":"ok","ref":"start","paging_version":1,"snapshot_id":"snapshot","high_water":2,"items":[{"acceptance":{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"top-row","origin":"source","as":"message","message":{"title":"Top"}},"attention_tier":"top"},{"acceptance":{"v":1,"type":"delivery","seq":2,"sender_id":"sender","message_id":"legacy-row","origin":"source","as":"message","message":{"title":"Legacy"}}}],"next_cursor":null,"receipt_cursor":null}"#
        let wire = try InboxPagingWire(profile: context())
        let page = try wire.decodeStart(data(frame), ref: "start")

        XCTAssertEqual(page.items.map(\.attentionTier), [.top, .middle])
        if case let .delivery(request, _) = page.items[0].acceptance.body {
            XCTAssertNil(request.originalPayload.uniqueValue(named: "attention_tier"),
                         "The wrapper tier must not be inserted into the original message.")
        } else {
            XCTFail("Expected a delivery acceptance")
        }

        let invalid = data(frame.replacingOccurrences(of: #""attention_tier":"top""#,
                                                      with: #""attention_tier":"urgent""#))
        XCTAssertThrowsError(try wire.decodeStart(invalid, ref: "start"))
    }

    func testLiveDeliveryTierIsAValidatedSiblingAndDefaultsToMiddle() throws {
        let wire = try RelayWire(profile: context())
        let high = data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"request","origin":"source","as":"knock","message":{"title":"Question"},"attention_tier":"low"}"#)
        let decoded = try wire.decodeEvent(high)
        XCTAssertEqual(decoded.attentionTier, .low)
        guard case let .delivery(request, classification) = decoded.body else {
            return XCTFail("Expected a delivery")
        }
        XCTAssertEqual(classification, .knock)
        XCTAssertEqual(request.originalPayload.uniqueValue(named: "title"), .string(ExactText("Question")))
        XCTAssertNil(request.originalPayload.uniqueValue(named: "attention_tier"))

        let legacy = try wire.decodeEvent(data(#"{"v":1,"type":"delivery","seq":2,"sender_id":"sender","message_id":"legacy","origin":"source","as":"message","message":{"title":"Legacy"}}"#))
        XCTAssertEqual(legacy.attentionTier, .middle)

        let invalid = data(String(decoding: high, as: UTF8.self)
            .replacingOccurrences(of: #""attention_tier":"low""#,
                                  with: #""attention_tier":"urgent""#))
        XCTAssertThrowsError(try wire.decodeEvent(invalid))

        let originReference = try wire.decodeEvent(data(#"{"v":1,"type":"delivery","seq":3,"sender_id":"sender","message_id":"origin-row","origin":"reader","attention_tier":"top"}"#))
        XCTAssertEqual(originReference.attentionTier, .top)
        guard case .originReference = originReference.body else {
            return XCTFail("The origin delivery must remain a content-free reference")
        }
    }

    func testNoCommentTerminalIsDistinctAndHasNoAnswerPayload() throws {
        let wire = try RelayWire(profile: context())
        let frame = #"{"v":1,"type":"lifecycle","seq":4,"sender_id":"sender","message_id":"request","origin":"other-installation","state":"no_comment","at":4}"#
        let event = try wire.decodeEvent(data(frame))
        guard case let .terminal(key, state, answer) = event.body else {
            return XCTFail("Expected a final lifecycle event")
        }
        XCTAssertEqual(key.messageID, ExactText("request"))
        XCTAssertEqual(state, .noComment)
        XCTAssertNil(answer)

        let invalid = data(frame.replacingOccurrences(of: #""at":4"#,
                                                       with: #""at":4,"answer":null"#))
        XCTAssertThrowsError(try wire.decodeEvent(invalid),
                             "No comment is not an empty answer payload.")
    }

    func testPreviouslyStoredDeliveryCanGainItsFirstExplicitTierOnReplay() throws {
        let profile = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: profile, persistence: persistence)
        let key = RequestKey(accountScope: profile.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("legacy"))
        let payload = try JSONValue.parse(data(#"{"title":"Legacy"}"#))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: profile)

        let restored = try AttentionDomainStore(context: profile, persistence: persistence)
        try restored.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            origin: ExactText("source"), attentionTier: .top), context: profile)

        let state = try restored.snapshot(context: profile)
        XCTAssertEqual(state.cursor, 1)
        XCTAssertEqual(state.remoteStates[key]?.attentionTier, .top)
        XCTAssertEqual(state.remoteStates[key]?.attentionTierOrigin, ExactText("source"))
        XCTAssertThrowsError(try restored.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            origin: ExactText("source"), attentionTier: .low), context: profile))
    }

    func testExistingSchemaTwoStateAndCheckpointDecodeWithoutTierFields() throws {
        let savedAnswer = JSONValue.object([JSONMember("accepted", .bool(true))])
        let remoteState = RemoteRequestState(state: .answered,
            authorizedOriginAnswer: savedAnswer, classification: .message, eventSequence: 7)
        let encodedRemoteState = try PropertyListEncoder().encode(remoteState)
        var oldRemoteState = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: encodedRemoteState, options: [], format: nil) as? [String: Any])
        for field in ["attentionTier", "attentionTierSequence", "attentionTierFeed", "attentionTierOrigin"] {
            oldRemoteState.removeValue(forKey: field)
        }
        let oldRemoteStateData = try PropertyListSerialization.data(
            fromPropertyList: oldRemoteState, format: .binary, options: 0)
        let restoredRemoteState = try PropertyListDecoder().decode(
            RemoteRequestState.self, from: oldRemoteStateData)
        XCTAssertEqual(restoredRemoteState.state, .answered)
        XCTAssertEqual(restoredRemoteState.authorizedOriginAnswer, savedAnswer)
        XCTAssertEqual(restoredRemoteState.classification, .message)
        XCTAssertEqual(restoredRemoteState.eventSequence, 7)
        XCTAssertNil(restoredRemoteState.attentionTier)

        let key = RequestKey(accountScope: ExactText("reader-account"),
            senderID: ExactText("sender"), messageID: ExactText("saved"))
        let checkpoint = InboxPagingCheckpoint(startupID: "startup", since: 4,
            snapshotID: "snapshot", highWater: 7, nextCursor: "older",
            hasInitialPage: true, loadedKeys: [key], freshKeys: [key],
            checkpointAccepted: true)
        let encodedCheckpoint = try PropertyListEncoder().encode(checkpoint)
        var oldCheckpoint = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: encodedCheckpoint, options: [], format: nil) as? [String: Any])
        oldCheckpoint.removeValue(forKey: "sourceOrder")
        let oldCheckpointData = try PropertyListSerialization.data(
            fromPropertyList: oldCheckpoint, format: .binary, options: 0)
        let restoredCheckpoint = try PropertyListDecoder().decode(
            InboxPagingCheckpoint.self, from: oldCheckpointData)
        XCTAssertEqual(restoredCheckpoint.loadedKeys, [key])
        XCTAssertEqual(restoredCheckpoint.currentKeys, [key])
        XCTAssertEqual(restoredCheckpoint.nextCursor, "older")
        XCTAssertNil(restoredCheckpoint.sourceOrder)
    }

    func testRelayTierChangeUsesExistingIdentityAndRequiresAValidTier() throws {
        let profile = context()
        let wire = try RelayWire(profile: profile)
        let frame = #"{"v":1,"type":"attention_tier","seq":3,"sender_id":"sender","message_id":"request","origin":"source","attention_tier":"top"}"#
        let decoded = try wire.decodeEvent(data(frame))
        XCTAssertEqual(decoded.sequence, 3)
        XCTAssertEqual(decoded.attentionTier, .top)
        XCTAssertEqual(decoded.origin, ExactText("source"))
        XCTAssertEqual(decoded.body, .attentionTierChange(RequestKey(accountScope: profile.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request"))))

        let missing = data(#"{"v":1,"type":"attention_tier","seq":3,"sender_id":"sender","message_id":"request","origin":"source"}"#)
        XCTAssertThrowsError(try wire.decodeEvent(missing))
    }

    func testRelayTierChangeUpdatesTheExistingRequestWithoutAnotherDelivery() throws {
        let profile = context()
        let store = try AttentionDomainStore(context: profile, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: profile.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request"))
        let payload = try JSONValue.parse(data(#"{"title":"Question"}"#))
        try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            origin: ExactText("source")), context: profile)

        let result = store.applyRelayEvent(RelayEvent(sequence: 2,
            body: .attentionTierChange(key), origin: ExactText("source"), attentionTier: .low),
            context: profile)
        guard case .committed(let cursor, _) = result else {
            return XCTFail("Expected the contiguous tier fact to commit")
        }
        XCTAssertEqual(cursor, 2)
        let snapshot = try store.snapshot(context: profile)
        XCTAssertEqual(snapshot.cursor, 2)
        XCTAssertEqual(snapshot.requests.count, 1)
        XCTAssertEqual(snapshot.remoteStates[key]?.attentionTier, .low)
        let port = AttentionDomainPort(store: store)
        XCTAssertEqual(try port.observe(context: port.context).requests.first?.attentionTier, .low)
    }

    func testConversationTierChangeAllowsUnboundMessageWithoutInventingHandle() throws {
        let wire = try ConversationWire(profile: context())
        let frame = data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"sender","message_id":"request","origin":"source","request_revision":1,"kind":"attention_tier","event_id":"tier-change","attention_tier":"low"}"#)
        let event = try wire.decodeEvent(frame)

        guard case let .attentionTier(eventID, origin, tier, sessionHandle) = event.fact else {
            return XCTFail("Expected a conversation tier-change fact")
        }
        XCTAssertEqual(eventID, ExactText("tier-change"))
        XCTAssertEqual(origin, ExactText("source"))
        XCTAssertEqual(tier, .low)
        XCTAssertNil(sessionHandle)

        let invalid = data(#"{"v":1,"type":"conversation","conversation_seq":1,"sender_id":"sender","message_id":"request","origin":"source","request_revision":1,"kind":"attention_tier","event_id":"tier-change","attention_tier":"urgent"}"#)
        XCTAssertThrowsError(try wire.decodeEvent(invalid))
    }

    func testInboxPlacementKeepsExistingRulesRegardlessOfTier() throws {
        let profile = context()
        let store = try AttentionDomainStore(context: profile, persistence: MemoryAttentionStatePersistence())
        let rows: [(String, AttentionTier)] = [
            ("first", .top), ("second", .top), ("third", .middle), ("fourth", .low)
        ]
        for (index, row) in rows.enumerated() {
            let key = RequestKey(accountScope: profile.identity.personID,
                senderID: ExactText("sender"), messageID: ExactText(row.0))
            let payload = try JSONValue.parse(data("{\"title\":\"\(row.0)\"}"))
            try store.apply(RelayEvent(sequence: UInt64(index + 1),
                body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
                origin: ExactText("source-\(row.0)"), attentionTier: row.1), context: profile)
        }

        let port = AttentionDomainPort(store: store)
        let presentation = try port.observe(context: port.context)
        XCTAssertEqual(presentation.requests.map { $0.key.messageID.rawValue },
                       ["fourth", "third", "second", "first"])
        XCTAssertEqual(presentation.requests.map(\.attentionTier), [.low, .middle, .top, .top])
    }

    func testLiveTierChangeRedrawsPagedRowWithoutMovingIt() throws {
        let profile = context()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: profile, persistence: persistence)
        func item(_ messageID: String,
                  sequence: UInt64,
                  tier: AttentionTier) throws -> InboxSnapshotItem {
            let key = RequestKey(accountScope: profile.identity.personID,
                senderID: ExactText("sender"), messageID: ExactText(messageID))
            let payload = try JSONValue.parse(Data("{\"title\":\"\(messageID)\"}".utf8))
            let acceptance = RelayEvent(sequence: sequence,
                body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
                origin: ExactText("source-\(messageID)"))
            return InboxSnapshotItem(acceptance: acceptance, attentionTier: tier)
        }
        let first = try item("first", sequence: 1, tier: .low)
        let second = try item("second", sequence: 2, tier: .top)
        _ = try store.beginInboxCandidate(startupID: "startup", since: 0, batches: [], context: profile)
        try store.saveInboxInitialPage(snapshotID: "snapshot", highWater: 2,
            items: [first, second], nextCursor: nil, receiptCursor: nil, context: profile)
        _ = try store.prepareInboxCheckpointAcknowledgement(context: profile)
        _ = try store.acceptInboxCheckpoint(snapshotID: "snapshot", highWater: 2, context: profile)

        let restored = try AttentionDomainStore(context: profile, persistence: persistence)
        let port = AttentionDomainPort(store: restored)
        let initial = try port.observe(context: port.context)
        XCTAssertEqual(initial.requests.map { $0.key.messageID.rawValue }, ["first", "second"])
        XCTAssertEqual(initial.requests.map(\.attentionTier), [.low, .top])

        let firstKey = first.key
        _ = restored.applyRelayEvent(RelayEvent(sequence: 3,
            body: .attentionTierChange(firstKey), origin: ExactText("source-first"), attentionTier: .middle),
            context: profile)
        let changed = try port.observe(context: port.context)
        XCTAssertEqual(changed.requests.map { $0.key.messageID.rawValue }, ["first", "second"])
        XCTAssertEqual(changed.requests.map(\.attentionTier), [.middle, .top])
        let checkpoint = try restored.snapshot(context: profile).inboxCheckpoint
        XCTAssertEqual(checkpoint?.highWater, 2, "The live tier fact must not move the frozen page high water.")
        XCTAssertEqual(try restored.snapshot(context: profile).cursor, 3)
    }

    func testPendingInboxRefreshKeepsLastAcceptedRowsCurrentAndAnswerable() throws {
        let profile = context()
        let store = try AttentionDomainStore(context: profile, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: profile.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request"))
        let payload = try JSONValue.parse(data(#"{"title":"Prompt","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":true}]}}"#))
        let acceptance = RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            origin: ExactText("origin"))
        _ = try store.beginInboxCandidate(startupID: "first", since: 0, batches: [], context: profile)
        try store.saveInboxInitialPage(snapshotID: "first-snapshot", highWater: 1,
            items: [InboxSnapshotItem(acceptance: acceptance)], nextCursor: nil,
            receiptCursor: nil, context: profile)
        _ = try store.prepareInboxCheckpointAcknowledgement(context: profile)
        _ = try store.acceptInboxCheckpoint(snapshotID: "first-snapshot", highWater: 1, context: profile)

        _ = try store.beginInboxCandidate(startupID: "retry", since: 1, batches: [], context: profile)
        XCTAssertEqual(try XCTUnwrap(store.snapshot(context: profile).inboxCurrentKeys), Set([key]))
        let port = AttentionDomainPort(store: store)
        let request = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first)
        XCTAssertTrue(request.inboxStateIsCurrent,
                      "A pending refresh keeps the last accepted message set active.")
        let selector = try XCTUnwrap(request.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        XCTAssertEqual(receipt.selector.requestRevision, 1)
        XCTAssertEqual(try store.snapshot(context: profile).outbox.first?.requestRevision, 1)
    }
}
