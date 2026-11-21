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









    func testStoredInboxViewWithoutListItemsRemainsDecodable() throws {
        let legacy = try JSONEncoder().encode(InboxView(
            revision: ExactText("legacy"), entries: []))
        let legacyView = try JSONDecoder().decode(InboxView.self, from: legacy)
        XCTAssertNil(legacyView.listItems)

        let current = InboxView(revision: ExactText("current"), entries: [],
            listItems: [InboxViewListItem(kind: .message,
                key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("agent"),
                               messageID: ExactText("message")))])
        let roundTrip = try JSONDecoder().decode(InboxView.self,
            from: JSONEncoder().encode(current))
        XCTAssertEqual(roundTrip, current)
    }

    func testRelayTierChangeUpdatesTheExistingRequestWithoutAnotherDelivery() throws {
        let profile = context()
        let store = try ClientRepository(context: profile, persistence: MemoryPendingActionPersistence())
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
        XCTAssertEqual(try port.observe(context: port.context).requests.first?.attentionTier, .middle)
    }


    func testInboxPlacementKeepsExistingRulesRegardlessOfTier() throws {
        let profile = context()
        let store = try ClientRepository(context: profile, persistence: MemoryPendingActionPersistence())
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
        XCTAssertEqual(presentation.requests.map(\.attentionTier), [.middle, .middle, .middle, .middle])
    }

    func testLiveTierChangeRedrawsPagedRowWithoutMovingIt() throws {
        let profile = context()
        let persistence = MemoryPendingActionPersistence()
        let store = try ClientRepository(context: profile, persistence: persistence)
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

        // This checks a live update against the accepted page. Relaunch cache
        // restoration is covered independently by ServerStateCacheTests.
        let restored = store
        let port = AttentionDomainPort(store: restored)
        let initial = try port.observe(context: port.context)
        XCTAssertEqual(initial.requests.map { $0.key.messageID.rawValue }, ["first", "second"])
        XCTAssertEqual(initial.requests.map(\.attentionTier), [.middle, .middle])

        let firstKey = first.key
        _ = restored.applyRelayEvent(RelayEvent(sequence: 3,
            body: .attentionTierChange(firstKey), origin: ExactText("source-first"), attentionTier: .middle),
            context: profile)
        let changed = try port.observe(context: port.context)
        XCTAssertEqual(changed.requests.map { $0.key.messageID.rawValue }, ["first", "second"])
        XCTAssertEqual(changed.requests.map(\.attentionTier), [.middle, .middle])
        let checkpoint = try restored.snapshot(context: profile).inboxCheckpoint
        XCTAssertEqual(checkpoint?.highWater, 2, "The live tier fact must not move the frozen page high water.")
        XCTAssertEqual(try restored.snapshot(context: profile).cursor, 3)
    }

    func testPendingInboxRefreshKeepsLastAcceptedRowsCurrentAndAnswerable() throws {
        let profile = context()
        let store = try ClientRepository(context: profile, persistence: MemoryPendingActionPersistence())
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
        let queued = try XCTUnwrap(store.snapshot(context: profile).intents[receipt.intentID])
        XCTAssertEqual(queued.requestRevision, 1)
        XCTAssertEqual(queued.disposition, .pending)
        XCTAssertTrue(try store.snapshot(context: profile).outbox.isEmpty,
                      "Committing an intent does not bypass the explicit currentness-checked send path.")

        try store.beginReplay(through: 1, context: profile)
        XCTAssertEqual(try XCTUnwrap(store.snapshot(context: profile).inboxCurrentKeys), Set([key]),
                       "The replay barrier must publish the same accepted rows while the candidate recovers.")
    }
}
