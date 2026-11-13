import AttentionDomain
import CryptoKit
import Foundation
import HarklightNativeRelay
import XCTest

final class ServerCacheReplacementTests: XCTestCase {
    func testSnapshotReplacesChangedPayloadAndAcceptanceOrderWithoutStoppingOtherRows() throws {
        let context = context()
        let first = key("first", context: context)
        let second = key("second", context: context)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        _ = try repository.apply(RelayEvent(sequence: 1,
            body: .delivery(request(first, title: "Cached"), .message)), context: context)
        _ = try repository.beginInboxCandidate(startupID: UUID().uuidString,
            since: 1, batches: [], context: context)

        try repository.saveInboxInitialPage(snapshotID: UUID().uuidString,
            highWater: 3, items: [
                InboxSnapshotItem(acceptance: RelayEvent(sequence: 2,
                    body: .delivery(request(first, title: "Server"), .message))),
                InboxSnapshotItem(acceptance: RelayEvent(sequence: 3,
                    body: .delivery(request(second, title: "Other request"), .message)))
            ], nextCursor: nil, receiptCursor: nil, context: context)

        let state = try repository.snapshot(context: context)
        XCTAssertEqual(state.requests[first]?.originalPayload, request(first, title: "Server").originalPayload)
        XCTAssertEqual(state.requests[first]?.acceptanceOrder, 2)
        XCTAssertEqual(state.requests[second]?.acceptanceOrder, 3)
        XCTAssertTrue(state.inboxCandidate?.hasInitialPage == true)
    }

    func testPendingActionPersistenceDoesNotRestoreServerRequests() throws {
        let context = context()
        let persistence = MemoryPendingActionPersistence()
        let repository = try ClientRepository(context: context, persistence: persistence)
        _ = try repository.apply(RelayEvent(sequence: 1,
            body: .delivery(request(key("one", context: context), title: "Server only"), .message)),
            context: context)

        let restarted = try ClientRepository(context: context, persistence: persistence)
        let state = try restarted.snapshot(context: context)
        XCTAssertTrue(state.requests.isEmpty)
        XCTAssertTrue(state.remoteStates.isEmpty)
        XCTAssertEqual(state.cursor, 0)
    }

    func testCacheFromAnotherServerPersonOrDeviceIsDiscarded() async throws {
        let original = context().identity
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.json")
        let snapshot = ServerStateCacheSnapshot(identity: original, cursor: 10, conversationCursor: 4,
            requests: [], conversations: [], inboxView: nil, currentRequestKeys: [])
        let identities = [
            ProfileIdentity(trustedRelayAuthority: ExactText("other.example"), personID: original.personID, deviceID: original.deviceID),
            ProfileIdentity(trustedRelayAuthority: original.trustedRelayAuthority, personID: ExactText("another-person"), deviceID: original.deviceID),
            ProfileIdentity(trustedRelayAuthority: original.trustedRelayAuthority, personID: original.personID, deviceID: ExactText("another-device"))
        ]
        for identity in identities {
            let writer = FileServerStateCache(identity: original, fileURL: file)
            try await writer.save(snapshot)
            let reader = FileServerStateCache(identity: identity, fileURL: file)
            let loaded = try await reader.load()
            XCTAssertNil(loaded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertThrowsError(try snapshot.attentionDomainState(for: identity))
        }
    }

    func testOldImmutableStoreFileIsDiscardedWithoutDecodingIt() throws {
        let context = context()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityBytes = JSONValue.array([
            .string(context.identity.trustedRelayAuthority),
            .string(context.identity.personID),
            .string(context.identity.deviceID)
        ]).canonicalJSON
        let hash = SHA256.hash(data: Data(identityBytes.utf8)).map { String(format: "%02x", $0) }.joined()
        let retired = directory.appendingPathComponent("\(hash).plist")
        try Data("retired server-owned state".utf8).write(to: retired)
        let persistence = FilePendingActionPersistence(directoryURL: directory)
        let repository = try ClientRepository(context: context, persistence: persistence)
        XCTAssertTrue(try repository.snapshot(context: context).requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
    }

    private func context() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
    }

    private func key(_ value: String, context: ProfileContext) -> RequestKey {
        RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText(value))
    }

    private func request(_ key: RequestKey, title: String) -> StoredRequest {
        StoredRequest(key: key, originalPayload: .object([JSONMember("title", .string(ExactText(title)))]))
    }
}
