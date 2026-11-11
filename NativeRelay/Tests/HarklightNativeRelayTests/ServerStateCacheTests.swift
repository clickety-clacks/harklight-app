import AttentionDomain
import Foundation
import XCTest
@testable import HarklightNativeRelay

final class ServerStateCacheTests: XCTestCase {
    func testFileCacheRoundTripsServerRowsAndCursors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harklight-server-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("cache.json")
        let cache = FileServerStateCache(fileURL: cacheURL)
        let key = RequestKey(accountScope: ExactText("person"),
                             senderID: ExactText("sender"),
                             messageID: ExactText("message"))
        let request = StoredRequest(key: key, originalPayload: .object([]))
        let row = CachedServerRequest(request: request, remoteState: nil)
        let inbox = AttentionStoreSnapshot(
            requests: [key: request],
            drafts: [key: RequestDraft(inputs: [:])],
            intents: [:],
            outbox: [],
            remoteStates: [:],
            fixtureSessions: [:],
            revision: 3,
            cursor: 14,
            replayBarrier: nil,
            repairIssues: [],
            inboxCurrentKeys: [key])
        let conversations = ConversationSnapshot(cursor: 9, threads: [:])
        let snapshot = ServerStateCacheSnapshot.make(from: inbox, conversations: conversations)

        try await cache.save(snapshot)
        let loaded = try await cache.load()

        XCTAssertEqual(loaded?.cursor, 14)
        XCTAssertEqual(loaded?.conversationCursor, 9)
        XCTAssertEqual(loaded?.requests, [row])
        XCTAssertEqual(loaded?.currentRequestKeys, [key])
        XCTAssertEqual(loaded?.conversations, [])
    }

    func testCorruptCacheIsDiscardedAndCanBeReplaced() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harklight-server-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("cache.json")
        let cache = FileServerStateCache(fileURL: cacheURL)
        let key = RequestKey(accountScope: ExactText("person"),
                             senderID: ExactText("sender"),
                             messageID: ExactText("message"))
        let request = StoredRequest(key: key, originalPayload: .object([]))
        let snapshot = ServerStateCacheSnapshot(cursor: 4, conversationCursor: 2,
            requests: [CachedServerRequest(request: request, remoteState: nil)],
            conversations: [], inboxView: nil, currentRequestKeys: [key])
        try await cache.save(snapshot)

        try Data([0xFF, 0x00, 0x7F]).write(to: cacheURL, options: .atomic)

        let afterCorruption = try await cache.load()
        XCTAssertNil(afterCorruption,
                     "Malformed cached data is discarded so the caller can sync from zero.")
        try await cache.save(snapshot)
        let afterReplacement = try await cache.load()
        XCTAssertEqual(afterReplacement, snapshot,
                       "The cache remains writable after corrupt contents are removed.")
    }

    func testNewServerSnapshotRemovesRowsThatAreNoLongerCurrent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harklight-server-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileServerStateCache(fileURL: directory.appendingPathComponent("cache.json"))
        let key = RequestKey(accountScope: ExactText("person"),
                             senderID: ExactText("sender"),
                             messageID: ExactText("old"))
        let request = StoredRequest(key: key, originalPayload: .object([]))
        let old = ServerStateCacheSnapshot(cursor: 1,
                                           conversationCursor: 0,
                                           requests: [CachedServerRequest(request: request,
                                                                          remoteState: nil)],
                                           conversations: [],
                                           inboxView: nil,
                                           currentRequestKeys: [key])
        let replacement = ServerStateCacheSnapshot(cursor: 2,
                                                   conversationCursor: 0,
                                                   requests: [],
                                                   conversations: [],
                                                   inboxView: nil,
                                                   currentRequestKeys: [])

        try await cache.save(old)
        try await cache.save(replacement)
        let loaded = try await cache.load()

        XCTAssertEqual(loaded?.cursor, 2)
        XCTAssertEqual(loaded?.requests, [])
        XCTAssertEqual(loaded?.currentRequestKeys, [])
    }

    func testCacheSnapshotExcludesAnswerDraftsAndOutbox() throws {
        let key = RequestKey(accountScope: ExactText("person"),
                             senderID: ExactText("sender"),
                             messageID: ExactText("message"))
        let request = StoredRequest(key: key, originalPayload: .object([]))
        let inbox = AttentionStoreSnapshot(
            requests: [key: request],
            drafts: [key: RequestDraft(inputs: [:])],
            intents: [:],
            outbox: [],
            remoteStates: [:],
            fixtureSessions: [:],
            revision: 1,
            cursor: 1,
            replayBarrier: nil,
            repairIssues: [])
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: key.accountScope, deviceID: ExactText("device")), transportMode: .relay)
        let domain = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
        _ = try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(request, .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)
        let binding = ConversationBinding(request: key, revision: 1)
        var thread = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[key])
        thread.drafts[1] = ConversationDraft(binding: binding, text: ExactText("chat draft"))
        thread.answerDrafts = [1: RequestDraft(inputs: [:],
            compatibility: CompatibilityDraft(selectedActionID: ExactText("yes")))]
        thread.readThroughTurn = ExactText("turn-1")
        thread.accountReadThroughConversationSequence = 7
        let conversations = ConversationSnapshot(cursor: 9, threads: [key: thread],
            chatReadPositions: [key: 7], chatReadPositionSupport: true)

        let cached = ServerStateCacheSnapshot.make(from: inbox, conversations: conversations)

        XCTAssertEqual(cached.requests.map { $0.request.key }, [key])
        XCTAssertNil(cached.currentRequestKeys)
        XCTAssertEqual(cached.cursor, 1)
        let cachedThread = try XCTUnwrap(cached.conversations.first?.thread)
        XCTAssertTrue(cachedThread.drafts.isEmpty)
        XCTAssertNil(cachedThread.answerDrafts)
        XCTAssertNil(cachedThread.readThroughTurn)
        XCTAssertNil(cachedThread.accountReadThroughConversationSequence)
    }
}
