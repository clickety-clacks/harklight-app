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

    // MARK: #384 review B-6 and B-7, L-28 and L-30

    private func restoreProjection(_ repository: ClientRepository, _ context: ProfileContext,
                                   entries: [String] = []) throws {
        let store = ServerModelV2Store(fileURL: nil)
        try store.apply(kind: "item", rev: 1, data: V2Fixture.json(V2Fixture.item("i", rev: 1, rankKey: "a")))
        if !entries.isEmpty { try store.open("i") }
        for (index, entry) in entries.enumerated() {
            try store.apply(kind: "entry", rev: UInt64(index + 2), data: V2Fixture.json(entry))
        }
        try repository.restoreCachedServerState(ServerModelV2Projection.cachedState(store.snapshot, identity: identity),
                                                context: context)
    }

    private func queue(_ repository: ClientRepository, _ context: ProfileContext) throws -> [ConversationDraft] {
        try repository.conversationSnapshot(context: context).threads[
            RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"), messageID: ExactText("i"))
        ]?.queuedMessages ?? []
    }

    func testQueuedMessagesSurviveTheNextProjectionRestoreAndARelaunch() throws {
        let persistence = MemoryPendingActionPersistence()
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: persistence)
        try restoreProjection(repository, context)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"), messageID: ExactText("i"))
        let binding = ConversationBinding(request: key, revision: 1)
        try type("one", repository, binding, context)
        let message = try repository.queueChatMessage(binding, context: context)
        try repository.recordQueuedChatMessage(try XCTUnwrap(message.operationID), in: key,
                                               disposition: .rejected(ExactText("too_large")), context: context)

        try restoreProjection(repository, context)
        XCTAssertEqual(try queue(repository, context).map(\.text.rawValue), ["one"],
                       "The next projection restore keeps the queue.")

        let relaunched = try ClientRepository(context: context, persistence: persistence)
        try restoreProjection(relaunched, context)
        let kept = try queue(relaunched, context)
        XCTAssertEqual(kept.map(\.text.rawValue), ["one"], "A relaunch keeps the queue.")
        XCTAssertEqual(kept.first?.operationID, message.operationID, "With the id it was saved under.")
        XCTAssertEqual(kept.first?.disposition, .rejected(ExactText("too_large")), "And the refusal.")
    }

    func testAQueuedMessageLeavesTheQueueOnceItsEntryIsHeld() throws {
        let (repository, context, binding) = try repository(v2: true)
        try type("one", repository, binding, context)
        let operation = try XCTUnwrap(repository.queueChatMessage(binding, context: context).operationID)
        try repository.recordQueuedChatMessage(operation, in: binding.request,
            disposition: .acceptedPendingReplay(operation: operation, turn: ExactText("e1")), context: context)
        try restoreProjection(repository, context,
                              entries: [V2Fixture.entry("e1", item: "i", rev: 2, position: 1, author: "person", text: "one")])
        XCTAssertTrue(try queue(repository, context).isEmpty)
    }

    func testRetryActsOnTheRefusedMessageByItsIdAndLeavesTheComposerAlone() throws {
        let (repository, context, binding) = try repository(v2: true)
        var ids: [UUID] = []
        for text in ["one", "two"] {
            try type(text, repository, binding, context)
            ids.append(try XCTUnwrap(repository.queueChatMessage(binding, context: context).operationID))
        }
        try repository.recordQueuedChatMessage(ids[0], in: binding.request,
                                               disposition: .rejected(ExactText("unavailable")), context: context)
        try type("still typing", repository, binding, context)

        let retried = try repository.retryQueuedChatMessage(ids[0], in: binding.request, context: context)
        XCTAssertEqual(retried.operationID, ids[0], "Retry keeps the message's id.")
        XCTAssertEqual(retried.text, ExactText("one"))
        let thread = try XCTUnwrap(repository.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(thread.queuedMessages?.map(\.disposition), [.submitting(ids[0]), .submitting(ids[1])])
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("still typing"), "The composer is not sent.")
    }

    func testEditReturnsTheRefusedMessageToTheComposerWithoutLosingTypedText() throws {
        let (repository, context, binding) = try repository(v2: true)
        try type("one", repository, binding, context)
        let operation = try XCTUnwrap(repository.queueChatMessage(binding, context: context).operationID)
        XCTAssertThrowsError(try repository.editQueuedChatMessage(operation, in: binding.request, context: context),
                             "Only a refused message can be edited.")
        try repository.recordQueuedChatMessage(operation, in: binding.request,
                                               disposition: .rejected(ExactText("too_large")), context: context)
        try type("and more", repository, binding, context)

        try repository.editQueuedChatMessage(operation, in: binding.request, context: context)
        let thread = try XCTUnwrap(repository.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("one\n\nand more"))
        XCTAssertNil(thread.queuedMessages)
    }

    func testQueuedTextStaysOutOfTheServerCache() throws {
        let (repository, context, binding) = try repository(v2: true)
        try type("private words", repository, binding, context)
        try repository.queueChatMessage(binding, context: context)
        let snapshot = ServerStateCacheSnapshot.make(identity: identity,
                                                     from: try repository.snapshot(context: context),
                                                     conversations: try repository.conversationSnapshot(context: context))
        XCTAssertTrue(snapshot.conversations.allSatisfy { $0.thread.queuedMessages == nil })
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private words"))
    }

    func testTheOutboxResendsARefusedWriteHandedOverAgainUnderItsKey() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [APIError(status: 413, token: .payloadTooLarge, retryable: false, requestID: "r")]
        let persistence = MemoryOutboxPersistence()
        server.persistedKeys = { persistence.keys }
        let outcomes = RecordingOutcomes()
        let box = try ActionOutbox(persistence: persistence, transport: server, outcomes: outcomes,
                                   errors: RecordingErrorLogV2(), waitBeforeRetry: { _, _ in try await Task.sleep(for: .seconds(3600)) })
        let id = UUID()
        let write = FrozenWrite(method: .post, path: "/v2/items/i/replies", body: Data(#"{"text":"one"}"#.utf8))
        try await box.submit(target: "item:i", operation: "reply", write: write, idempotencyKey: id)
        var deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, outcomes.rejected.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let again = try await box.submit(target: "item:i", operation: "reply", write: write, idempotencyKey: id)
        XCTAssertNil(again.failure)
        deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, outcomes.accepted.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(server.received.map(\.idempotencyKey), [id, id], "Retry resends under the same key.")
        let failed = await box.failedWrites
        XCTAssertTrue(failed.isEmpty)
    }
}
