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

}
