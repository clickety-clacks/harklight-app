import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

/// Product ruling APP-07: each chat message is its own operation with its own
/// id, and the composer never freezes while messages send.
final class ChatMessageQueueTests: XCTestCase {
    private let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                           personID: ExactText("person-A"), deviceID: ExactText("installation-A"))

    private func repository(v2: Bool) throws -> (ClientRepository, ProfileContext, ConversationBinding) {
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 1, data: V2Fixture.json(V2Fixture.item("i", rev: 1, rankKey: "a")))
        var cached = ServerModelV2Projection.cachedState(store.snapshot, identity: identity)
        if !v2 {
            var threads = cached.conversations
            for key in threads.keys { threads[key]?.chatNeverCloses = nil }
            cached = CachedAttentionServerState(identity: identity, requests: cached.requests,
                remoteStates: cached.remoteStates, cursor: 0, conversationCursor: 0, conversations: threads,
                inboxView: cached.inboxView, currentRequestKeys: cached.currentRequestKeys)
        }
        try repository.restoreCachedServerState(cached, context: context)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"), messageID: ExactText("i"))
        return (repository, context, ConversationBinding(request: key, revision: 1))
    }

    private func type(_ text: String, _ repository: ClientRepository, _ binding: ConversationBinding,
                      _ context: ProfileContext) throws {
        try repository.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText(text)), context: context)
    }

    func testEachMessageIsItsOwnSavedOperationAndTheComposerEmptiesForTheNext() throws {
        let (repository, context, binding) = try repository(v2: true)
        var ids: [UUID] = []
        for text in ["one", "two", "three"] {
            try type(text, repository, binding, context)
            let message = try repository.queueChatMessage(binding, context: context)
            ids.append(try XCTUnwrap(message.operationID))
            let thread = try XCTUnwrap(repository.conversationSnapshot(context: context).threads[binding.request])
            XCTAssertEqual(thread.drafts[1]?.text, ExactText(""), "The composer is free for the next message.")
        }
        XCTAssertEqual(Set(ids).count, 3, "Each message has its own operation id.")
        let thread = try XCTUnwrap(repository.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(thread.queuedMessages?.map(\.text.rawValue), ["one", "two", "three"], "Kept in send order.")
        XCTAssertEqual(thread.queuedMessages?.compactMap(\.operationID), ids, "Saved before anything is sent.")
    }

    func testOneMessagesOutcomeLeavesTheOthersAlone() throws {
        let (repository, context, binding) = try repository(v2: true)
        var ids: [UUID] = []
        for text in ["one", "two"] {
            try type(text, repository, binding, context)
            ids.append(try XCTUnwrap(repository.queueChatMessage(binding, context: context).operationID))
        }
        try repository.recordQueuedChatMessage(ids[0], in: binding.request,
                                               disposition: .rejected(ExactText("too_large")), context: context)
        let queue = try XCTUnwrap(repository.conversationSnapshot(context: context).threads[binding.request]?.queuedMessages)
        XCTAssertEqual(queue[0].disposition, .rejected(ExactText("too_large")))
        XCTAssertEqual(queue[0].text, ExactText("one"), "A refused message keeps its text.")
        XCTAssertEqual(queue[1].disposition, .submitting(ids[1]))
    }

    func testTodaysThreadsDoNotQueueAndAnEmptyComposerSendsNothing() throws {
        let (today, context, binding) = try repository(v2: false)
        try type("hello", today, binding, context)
        XCTAssertThrowsError(try today.queueChatMessage(binding, context: context),
                             "The current protocol keeps one send per revision.")
        let (v2, v2Context, v2Binding) = try repository(v2: true)
        XCTAssertThrowsError(try v2.queueChatMessage(v2Binding, context: v2Context))
    }

    func testTheOutboxSendsAQueuedMessageUnderItsOwnId() async throws {
        let server = FakeClientAPIServer()
        let persistence = MemoryOutboxPersistence()
        server.persistedKeys = { persistence.keys }
        let box = try ActionOutbox(persistence: persistence, transport: server, outcomes: RecordingOutcomes(),
                                   errors: RecordingErrorLogV2(), waitBeforeRetry: { _, _ in try await Task.sleep(for: .seconds(3600)) })
        let id = UUID()
        let write = FrozenWrite(method: .post, path: "/v2/items/i/replies", body: Data(#"{"text":"one"}"#.utf8))
        let entry = try await box.submit(target: "i", operation: "reply", write: write, idempotencyKey: id)
        let again = try await box.submit(target: "i", operation: "reply", write: write, idempotencyKey: id)
        XCTAssertEqual(entry.idempotencyKey, id)
        XCTAssertEqual(again.idempotencyKey, id, "Handing the same message over twice queues it once.")
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, server.received.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(server.received.map(\.idempotencyKey), [id])
    }
}
