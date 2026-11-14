import AttentionDomain
import Foundation
import XCTest
@testable import Harklight

@MainActor
final class InboxLaunchSelectionTests: XCTestCase {
    func testPopulatedCacheLaunchAndCatchUpLeaveInboxUnselected() async throws {
        let (repository, context, keys) = try populatedCache()
        let live = try LivePresentationStore(store: repository, context: context)
        XCTAssertEqual(Set(live.presentation.requests.map(\.key)), Set(keys))
        XCTAssertNil(live.selectedRequestKey)

        live.beginRefresh()
        defer { live.endRefresh() }
        try live.refreshFromDurableStore()
        XCTAssertNil(live.selectedRequestKey, "Sync publication cannot select the first cached row.")
        _ = try await live.adoptForLiveUpdates(snapshot(repository))
        XCTAssertNil(live.selectedRequestKey, "Live catch-up publication cannot open detail.")
        XCTAssertTrue(live.isRefreshing)
    }

    func testExplicitSelectionSurvivesUpdatesButBackAndRelaunchDoNotRestoreIt() async throws {
        let (repository, context, keys) = try populatedCache()
        let live = try LivePresentationStore(store: repository, context: context)
        live.selectRequest(keys[1])
        try live.refreshFromDurableStore()
        _ = try await live.adoptForLiveUpdates(snapshot(repository))
        XCTAssertEqual(live.selectedRequestKey, keys[1])

        live.selectRequest(nil)
        try live.refreshFromDurableStore()
        _ = try await live.adoptForLiveUpdates(snapshot(repository))
        XCTAssertNil(live.selectedRequestKey, "Updates after Back cannot reopen a row.")

        live.selectRequest(keys[1])
        let relaunched = try LivePresentationStore(store: repository, context: context)
        XCTAssertNil(relaunched.selectedRequestKey, "Last-open detail is not a launch destination.")
    }

    func testRemovedSelectionClearsInsteadOfSelectingAnotherRow() async throws {
        let (repository, context, keys) = try populatedCache()
        let synchronous = try LivePresentationStore(store: repository, context: context)
        let asynchronous = try LivePresentationStore(store: repository, context: context)
        synchronous.selectRequest(keys[0])
        asynchronous.selectRequest(keys[0])
        let remaining = try XCTUnwrap(repository.snapshot(context: context).requests[keys[1]])
        _ = try repository.beginInboxCandidate(startupID: "replacement", since: 2,
                                              batches: [], context: context)
        try repository.saveInboxInitialPage(snapshotID: "replacement", highWater: 2,
            items: [InboxSnapshotItem(acceptance: RelayEvent(sequence: 2,
                body: .delivery(remaining, .message)))],
            nextCursor: nil, receiptCursor: nil, context: context)
        _ = try repository.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try repository.acceptInboxCheckpoint(snapshotID: "replacement", highWater: 2,
                                                  context: context)
        try synchronous.refreshFromDurableStore()
        _ = try await asynchronous.adoptForLiveUpdates(snapshot(repository))
        XCTAssertEqual(synchronous.presentation.requests.map(\.key), [keys[1]])
        XCTAssertNil(synchronous.selectedRequestKey)
        XCTAssertNil(asynchronous.selectedRequestKey)
    }

    private func snapshot(_ repository: ClientRepository) throws -> PresentationSnapshot {
        let port = AttentionDomainPort(store: repository)
        return try port.observe(context: port.context)
    }

    private func populatedCache() throws -> (ClientRepository, ProfileContext, [RequestKey]) {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("launch-selection"), deviceID: ExactText("test-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let original = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let keys = ["first", "last-open"].map {
            RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText($0))
        }
        for (index, key) in keys.enumerated() {
            let payload = try JSONValue.parse(Data(#"{"title":"Cached request"}"#.utf8))
            _ = try original.apply(RelayEvent(sequence: UInt64(index + 1),
                body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        }
        let saved = try original.snapshot(context: context)
        let restored = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try restored.restoreCachedServerState(CachedAttentionServerState(identity: identity,
            requests: saved.requests, remoteStates: [:], cursor: 2, conversationCursor: 0,
            conversations: [:], inboxView: nil, currentRequestKeys: Set(keys)), context: context)
        return (restored, context, keys)
    }
}
