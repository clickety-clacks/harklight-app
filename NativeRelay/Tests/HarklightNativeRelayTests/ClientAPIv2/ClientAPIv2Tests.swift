import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

/// Waits for `condition` without a fixed sleep; fails after `timeout`.
private func eventually(_ message: String, timeout: Duration = .seconds(2),
                        file: StaticString = #filePath, line: UInt = #line,
                        _ condition: @escaping () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out: \(message)", file: file, line: line)
}

private let noWait: @Sendable (Int) async throws -> Void = { _ in await Task.yield() }
private let noOutboxWait: @Sendable (Int, TimeInterval?) async throws -> Void = { _, _ in
    try await Task.sleep(for: .seconds(3600))
}

final class ClientAPIAccessTests: XCTestCase {
    private func connection(_ server: any ClientAPITransport, directory: URL) throws -> ClientAPIv2Connection {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        return try ClientAPIv2Connection(transport: server, repository: repository, context: context,
            directory: directory, errors: RecordingErrorLogV2(), foregroundOnlyWrites: true)
    }

    func testInternalErrorOnSnapshotReadRequiresActionAndKeepsCopyableDetails() async throws {
        let server = FakeClientAPIServer()
        server.meBody = #"{"account":{"state":"active"},"features":{},"limits":{}}"#
        let body = Data(#"{"error":"internal_error","retryable":false,"message":"do not copy me"}"#.utf8)
        let failure = APIError(status: 500, body: body, requestID: "req-render-me", retryAfter: 4)
        XCTAssertEqual(failure.token, .internalError)
        XCTAssertFalse(failure.retryable)
        XCTAssertFalse(failure.isPermanent)
        XCTAssertNil(failure.retryAfter)
        server.nextMeFailure = failure

        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("error-log.json")
        let build = ErrorLogBuild(version: "0.2.0", build: "1", commit: "f536273")
        let errors = ErrorLogStore(fileURL: logURL, build: build)
        let connection = try ClientAPIv2Connection(transport: server, repository: repository, context: context,
            directory: nil, errors: errors, meWaitBeforeRetry: { _ in XCTFail("Automatic retry scheduled") })

        await connection.readMeUntilRead()
        XCTAssertEqual(server.received.map(\.path), ["/v2/me"])
        let failureRecord = try XCTUnwrap(errors.records.first)
        XCTAssertEqual(failureRecord.code, "internal_error")
        XCTAssertFalse(failureRecord.retryable)
        XCTAssertEqual(failureRecord.httpStatus, 500)
        let details = ErrorLogDetails.text(for: failureRecord)
        XCTAssertTrue(details.contains("request_id: req-render-me"))
        XCTAssertTrue(details.contains("operation: me"))
        XCTAssertFalse(details.contains("do not copy me"))

        try await connection.retryInternalError(failureRecord)
        XCTAssertEqual(server.received.map(\.path), ["/v2/me", "/v2/me"])
        errors.flush()
        let reopened = ErrorLogStore(fileURL: logURL, build: build)
        XCTAssertEqual(reopened.records.first?.correlation.requestID, "req-render-me")
        XCTAssertEqual(reopened.records.first?.isResolved, true)
    }

    func testPushSettingsAndWritesUseTheAccountAccessGate() async throws {
        let server = FakeClientAPIServer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = try connection(server, directory: directory)
        connection.access.pause()
        do {
            _ = try await connection.push.status()
            XCTFail("A paused account must not fetch push settings.")
        } catch let error as APIError {
            XCTAssertEqual(error.token, .accountPaused)
        }
        connection.access.revoke()
        do {
            _ = try await connection.push.remove(idempotencyKey: UUID())
            XCTFail("A revoked device must not send a push DELETE.")
        } catch let error as APIError {
            XCTAssertEqual(error.token, .unauthorized)
        }
        XCTAssertTrue(server.received.isEmpty)
    }

    func testAnOlderPausedMeCannotUndoANewerActiveMeOrItsSavedState() async throws {
        let server = HeldMeTransport()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = try connection(server, directory: directory)
        connection.access.pause()
        let older = Task { try await connection.refreshMe() }
        defer { server.releaseOldResponse.release() }
        await eventually("the old request is held") { await server.meReads == 1 }
        _ = try await connection.refreshMe()
        XCTAssertEqual(connection.access.state, .available)
        server.releaseOldResponse.release()
        _ = try await older.value
        XCTAssertEqual(connection.access.state, .available)
        XCTAssertNil(connection.model.snapshot.accountPaused)
        let reopened = try self.connection(server, directory: directory)
        XCTAssertEqual(reopened.access.state, .available)
    }

    func testPausedFeedKeepsTheCacheAndSavedWritesUntilMeConfirmsRecovery() async throws {
        let server = FakeClientAPIServer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        server.inboxItems = [V2Fixture.item("i", rev: 1, rankKey: "a")]
        server.meBody = #"{"account":{"state":"active"},"features":{},"limits":{}}"#
        let connection = try connection(server, directory: directory)
        let initial = Task { await connection.runForeground() }
        defer { initial.cancel() }
        await eventually("the held inbox and feed") {
            server.openFeedCount == 1 && connection.model.snapshot.items[ExactText("i")] != nil &&
                server.received.contains { $0.path == "/v2/me" }
        }
        let held = connection.model.heldCursor
        server.closeFeeds(reason: "account_paused")
        await initial.value
        XCTAssertEqual(connection.access.state, .paused)
        XCTAssertEqual(connection.model.persistedCursor(), held)
        XCTAssertNotNil(connection.model.snapshot.items[ExactText("i")])

        let write = ClientAPIWrites.reply(itemID: ExactText("i"), text: ExactText("saved while paused"))
        let key = UUID()
        try await connection.outbox.submit(target: write.target, operation: write.operation, write: write.write,
                                           idempotencyKey: key)
        let reopened = try self.connection(server, directory: directory)
        XCTAssertEqual(reopened.access.state, .paused, "A feed pause survives relaunch before another /me read.")
        XCTAssertEqual(reopened.model.persistedCursor(), held)
        XCTAssertNotNil(reopened.model.snapshot.items[ExactText("i")])
        let before = server.received.count
        server.meBody = #"{"account":{"state":"paused"},"features":{},"limits":{}}"#
        await reopened.runForeground()
        XCTAssertEqual(Array(server.received.dropFirst(before)).map(\.path), ["/v2/me"])
        let pending = await reopened.outbox.pending
        XCTAssertEqual(pending.map(\.id), [key])

        server.meBody = #"{"account":{"state":"active"},"features":{},"limits":{}}"#
        let resumed = Task { await reopened.runForeground() }
        defer { resumed.cancel() }
        await eventually("recovery sends the saved operation under its original key") {
            server.received.contains { $0.idempotencyKey == key }
        }
        XCTAssertEqual(reopened.access.state, .available)
        XCTAssertNil(reopened.model.snapshot.accountPaused)
        XCTAssertEqual(server.received.filter { $0.idempotencyKey == key }.count, 1)
    }

    func testRevokedFeedBlocksSubsequentConnectionAndIndependentRequests() async throws {
        let server = FakeClientAPIServer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = try connection(server, directory: directory)
        let initial = Task { await connection.runForeground() }
        defer { initial.cancel() }
        await eventually("the stream is open") { server.openFeedCount == 1 }
        server.closeFeeds(reason: "revoked")
        await initial.value
        XCTAssertEqual(connection.access.state, .revoked)
        let before = server.received.count
        await connection.runForeground()
        do {
            _ = try await connection.access.send(.get("/v2/me"))
            XCTFail("The revoked connection must not make another request.")
        } catch let error as APIError {
            XCTAssertEqual(error.token, .unauthorized)
        }
        XCTAssertEqual(server.received.count, before)
        XCTAssertEqual(server.openFeedCount, 0)
    }
}

private actor HeldMeTransport: ClientAPITransport {
    private(set) var meReads = 0
    nonisolated let releaseOldResponse = AsyncGate()

    func send(_ request: APIRequest) async throws -> APIResponse {
        guard request.path == "/v2/me" else { throw URLError(.unsupportedURL) }
        meReads += 1
        let first = meReads == 1
        if first { await releaseOldResponse.wait() }
        let state = first ? "paused" : "active"
        let body = #"{"account":{"state":"\#(state)"},"features":{},"limits":{}}"#
        return APIResponse(status: 200, requestID: "me", body: Data(body.utf8))
    }

    nonisolated func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        FeedBatch(changes: [], rev: after, more: false)
    }
}

final class SavedV2ItemActionTests: XCTestCase {
    func testTransportReplacementKeepsTheLiveRepositoryGenerationAndSendsSavedWrites() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let retained = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: retained, persistence: MemoryPendingActionPersistence())
        let original = try ClientAPIv2Connection(transport: FakeClientAPIServer(), repository: repository,
            context: retained, directory: nil, errors: RecordingErrorLogV2(), foregroundOnlyWrites: true)
        let item = V2Fixture.item("i", rev: 1, rankKey: "a")
        let model = ServerModelV2Store(fileURL: nil)
        try model.apply(kind: "item", rev: 1, data: V2Fixture.json(item))
        try model.open("i")
        try model.apply(kind: "entry", rev: 2,
                        data: V2Fixture.json(V2Fixture.entry("agent-reply", item: "i", rev: 2, position: 4)))
        try repository.restoreCachedServerState(ServerModelV2Projection.cachedState(model.snapshot, identity: identity),
                                                context: retained)

        // An offline enrollment removal closes the transport. The app keeps this
        // repository and its generation, even though loading enrollment remints one.
        original.access.close()
        await original.outbox.close()
        let replacement = FakeClientAPIServer()
        replacement.inboxItems = [item]
        replacement.meBody = #"{"account":{"state":"active"},"features":{},"limits":{}}"#
        replacement.replyEntry = { revision in
            #"{"entry_id":"accepted","item_id":"i","rev":\#(revision),"position":5,"kind":"reply","author":"person","request_revision":1,"text":"back online","files":[]}"#
        }
        let reminted = ProfileContext(identity: identity, transportMode: .relay)
        XCTAssertThrowsError(try ClientAPIv2Connection(transport: replacement, repository: repository,
            context: reminted, directory: nil, errors: RecordingErrorLogV2())) {
            XCTAssertEqual($0 as? AttentionStoreError, .staleProfile)
        }
        let restored = try ClientAPIv2Connection(transport: replacement, repository: repository,
            context: retained, directory: nil, errors: RecordingErrorLogV2(), foregroundOnlyWrites: true)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"), messageID: ExactText("i"))
        let seen = try repository.enqueueMessageOpen(key, requestRevision: 1, context: retained)
        let read = try XCTUnwrap(repository.markConversationRead(key, through: ExactText("agent-reply"), context: retained))
        let binding = ConversationBinding(request: key, revision: 1)
        try repository.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("back online")),
                                             context: retained)
        let reply = try repository.queueChatMessage(binding, context: retained)
        let replyKey = try XCTUnwrap(reply.operationID)
        let expected = [
            seen.operationID: "/v2/items/i/seen",
            read.operationID: "/v2/items/i/read-position",
            replyKey: "/v2/items/i/replies"
        ]
        let foreground = Task { await restored.runForeground() }
        defer { foreground.cancel() }
        await eventually("the restored generation settles all three saved writes") {
            (try? repository.snapshot(context: retained).pendingMessageOpens.isEmpty) == true &&
                (try? repository.savedV2ReadPositions(context: retained).isEmpty) == true &&
                (try? repository.queuedChatMessages(context: retained).isEmpty) == true
        }
        foreground.cancel()
        await foreground.value
        let writes = replacement.received.filter { $0.method != .get }
        XCTAssertEqual(Set(writes.compactMap(\.idempotencyKey)), Set(expected.keys))
        for (key, path) in expected {
            let attempts = writes.filter { $0.idempotencyKey == key }
            XCTAssertEqual(Set(attempts.map(\.path)), [path])
            let body = try XCTUnwrap(attempts.first?.body)
            XCTAssertTrue(attempts.allSatisfy { $0.body == body })
        }
        // Reply recovery can race settlement. A same-key replay must not
        // create a second server entry.
        var batch = try await replacement.changeBatch(after: 0)
        var changes = batch.changes
        while batch.more {
            batch = try await replacement.changeBatch(after: batch.rev)
            changes += batch.changes
        }
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(changes.filter { $0.kind == .entry }.count, 1)
    }

    func testAnOlderVisibleEntryCannotReplaceAHigherPendingReadAcrossRelaunch() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FilePendingActionPersistence(directoryURL: directory)
        let first = try ClientRepository(context: context, persistence: persistence)
        let model = ServerModelV2Store(fileURL: nil)
        let item = try APIItem(json: V2Fixture.json(V2Fixture.item("i", rev: 1, rankKey: "a")))
        try model.rebaseline(items: [item], counts: APICounts(unresolved: 1), position: 1)
        try model.open("i")
        try model.apply(kind: "entry", rev: 2,
                        data: V2Fixture.json(V2Fixture.entry("at-four", item: "i", rev: 2, position: 4)))
        try model.apply(kind: "entry", rev: 3,
                        data: V2Fixture.json(V2Fixture.entry("at-nine", item: "i", rev: 3, position: 9)))
        try first.restoreCachedServerState(ServerModelV2Projection.cachedState(model.snapshot, identity: identity),
                                           context: context)
        let key = ServerModelV2Projection.key(for: item.itemID, sender: item.sender, identity: identity)
        let higher = try XCTUnwrap(first.markConversationRead(key, through: ExactText("at-nine"), context: context))
        let olderCallback = try first.markConversationRead(key, through: ExactText("at-four"), context: context)
        XCTAssertEqual(olderCallback, higher)
        XCTAssertEqual(higher.readThroughConversationSequence, 9)

        let reopened = try ClientRepository(context: context, persistence: persistence)
        XCTAssertEqual(try reopened.savedV2ReadPositions(context: context), [higher])
        let server = FakeClientAPIServer()
        let connection = try ClientAPIv2Connection(transport: server, repository: reopened, context: context,
            directory: nil, errors: RecordingErrorLogV2())
        await connection.sendSavedConversationReads()
        await eventually("position nine settles under its original key") {
            (try? reopened.savedV2ReadPositions(context: context).isEmpty) == true
        }
        let sent = try XCTUnwrap(server.received.first)
        XCTAssertEqual(server.received.count, 1)
        XCTAssertEqual(sent.idempotencyKey, higher.operationID)
        XCTAssertEqual(sent.path, "/v2/items/i/read-position")
        XCTAssertEqual(String(decoding: sent.body ?? Data(), as: UTF8.self), #"{"entry_id":"at-nine"}"#)
    }

    func testRejectedSeenRemainsVisibleAfterReopen() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryPendingActionPersistence()
        let repository = try ClientRepository(context: context, persistence: persistence)
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [APIError(status: 404, token: .notFound, retryable: false, requestID: "refused")]
        let connection = try ClientAPIv2Connection(transport: server, repository: repository, context: context,
            directory: nil, errors: RecordingErrorLogV2())
        let message = #"{"message_type":"fyi","title":"Fictional bulletin"}"#
        let item = try APIItem(json: V2Fixture.json(V2Fixture.item("i", rev: 1, rankKey: "a", message: message)))
        try connection.model.rebaseline(items: [item], counts: APICounts(unresolved: 1), position: 1)
        let cached = ServerModelV2Projection.cachedState(connection.model.snapshot, identity: identity)
        try repository.restoreCachedServerState(cached, context: context)
        let key = ServerModelV2Projection.key(for: item.itemID, sender: item.sender, identity: identity)
        let original = try repository.enqueueMessageOpen(key, requestRevision: 1, context: context)
        await connection.sendSavedContentOpens()
        await eventually("the refused operation leaves the automatic outbox") {
            (try? repository.snapshot(context: context).pendingMessageOpens.isEmpty) == true
        }

        let reopened = try ClientRepository(context: context, persistence: persistence)
        try reopened.restoreCachedServerState(cached, context: context)
        let port = AttentionDomainPort(store: reopened)
        let request = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first)
        XCTAssertTrue(request.itemOpenFailed)
        XCTAssertFalse(request.itemOpenPending)
        let retry = try reopened.enqueueMessageOpen(key, requestRevision: 1, context: context)
        XCTAssertNotEqual(retry.operationID, original.operationID)
        XCTAssertTrue(try port.inspect(context: port.context, request: key).requests.first?.itemOpenFailed == true)

        let revised = V2Fixture.item("i", rev: 2, rankKey: "a", message: message)
            .replacingOccurrences(of: #""request_revision":1"#, with: #""request_revision":2"#)
        let current = try APIItem(json: V2Fixture.json(revised))
        try connection.model.rebaseline(items: [current], counts: APICounts(unresolved: 1), position: 2)
        try reopened.restoreCachedServerState(
            ServerModelV2Projection.cachedState(connection.model.snapshot, identity: identity), context: context)
        XCTAssertTrue(try reopened.snapshot(context: context).failedMessageOpens.isEmpty)
    }

    func testTerminalAnswerRefusalsCloseTheRowWithoutAFeedUpdate() async throws {
        let scenarios: [(APIErrorToken, AppLifecycleStatus, String)] = [
            (.alreadyRetracted, .cleared, "The sender retracted this message."),
            (.alreadyAnswered, .answered, "This request was already answered.")
        ]
        for (token, status, evidence) in scenarios {
            let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                personID: ExactText("person"), deviceID: ExactText("device"))
            let context = ProfileContext(identity: identity, transportMode: .relay)
            let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
            let server = FakeClientAPIServer()
            server.nextWriteFailures = [APIError(status: 409, token: token, retryable: false, requestID: "closed")]
            let connection = try ClientAPIv2Connection(transport: server, repository: repository, context: context,
                directory: nil, errors: RecordingErrorLogV2())
            let message = #"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"ok","label":"OK","kind":"value","value":true}]}}"#
            let item = try APIItem(json: V2Fixture.json(V2Fixture.item("i", rev: 1, rankKey: "a", message: message)))
            try connection.model.rebaseline(items: [item], counts: APICounts(unresolved: 1), position: 1)
            let cached = ServerModelV2Projection.cachedState(connection.model.snapshot, identity: identity)
            try repository.restoreCachedServerState(cached, context: context)
            let key = ServerModelV2Projection.key(for: item.itemID, sender: item.sender, identity: identity)
            let port = AttentionDomainPort(store: repository)
            let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
            let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                inputs: [.compatibilityValue(action: ExactText("ok"))]))
            try await connection.sendSavedAnswer(receipt.intentID)
            await eventually("the refusal projects a terminal row") {
                (try? port.inspect(context: port.context, request: key).requests.first?.lifecycleStatus) == status
            }
            try repository.restoreCachedServerState(cached, context: context)
            let shown = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first)
            XCTAssertEqual(shown.lifecycleStatus, status)
            XCTAssertEqual(shown.receiptFacts?.evidenceLabel, evidence)
            XCTAssertEqual(shown.receiptFacts?.ownOutcome, .refused)
            XCTAssertEqual(shown.ownAnswerWasRefusedByRetraction, token == .alreadyRetracted)
            XCTAssertEqual(connection.model.heldCursor, 1)
            XCTAssertEqual(server.received.map(\.path), ["/v2/items/i/answer"])
        }
    }

    func testUpgradeHoldsAllAmbiguousTargetsEvenWhenTheirIDAndSenderMatchAnotherItem() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FilePendingActionPersistence(directoryURL: directory)
        let first = try ClientRepository(context: context, persistence: persistence)
        let model = ServerModelV2Store(fileURL: nil)
        let message = #"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"ok","label":"OK","kind":"value","value":true}]}}"#
        let item = V2Fixture.item("i42", rev: 1, rankKey: "a", message: message)
        try model.apply(kind: "item", rev: 1, data: V2Fixture.json(item))
        try model.open("i42")
        try model.apply(kind: "entry", rev: 2,
                        data: V2Fixture.json(V2Fixture.entry("entry-first", item: "i42", rev: 2, position: 4)))
        try first.restoreCachedServerState(ServerModelV2Projection.cachedState(model.snapshot, identity: identity),
                                           context: context)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"), messageID: ExactText("i42"))
        let seen = try first.enqueueMessageOpen(key, requestRevision: 1, context: context)
        let read = try XCTUnwrap(first.markConversationRead(key, through: ExactText("entry-first"), context: context))
        let port = AttentionDomainPort(store: first)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
            inputs: [.compatibilityValue(action: ExactText("ok"))]))
        let answer = try XCTUnwrap(first.lookupIntent(receipt.intentID, context: context))


        let heldIDs: Set<UUID> = [seen.operationID, read.operationID, answer.operationID]
        let newContext = ProfileContext(identity: identity, transportMode: .relay)
        let migration = try ClientRepository(context: newContext, persistence: persistence)
        try migration.migratePendingItemActionsToClientAPI(context: newContext)
        let reopened = try ClientRepository(context: newContext, persistence: persistence)
        XCTAssertEqual(try reopened.heldPreviousProtocolOperations(context: newContext), heldIDs)
        XCTAssertTrue(try reopened.snapshot(context: newContext).pendingMessageOpens.isEmpty)
        XCTAssertTrue(try reopened.savedV2ReadPositions(context: newContext).isEmpty)
        XCTAssertTrue(try reopened.inboxOperationInventory(context: newContext).isEmpty)

        // A pre-release installation may also have handed a held key to the
        // v2 outbox before upgrading. It must be excluded there as well.
        let v2Directory = directory.appendingPathComponent("v2")
        let persistedOutbox = FileOutboxPersistence(url: v2Directory.appendingPathComponent("outbox-v2.json"))
        let oldWrite = ClientAPIWrites.seen(itemID: key.messageID)
        try persistedOutbox.save([OutboxEntry(idempotencyKey: seen.operationID, target: oldWrite.target,
            operation: oldWrite.operation, write: oldWrite.write, createdAt: Date(), outcomeUnknown: true, attempts: 1)])

        // The v2 authority assigned the original message i77. Another item
        // has the same spelling, sender and revision as the saved 0.1 target.
        let server = FakeClientAPIServer()
        server.inboxItems = [item, V2Fixture.item("i77", rev: 2, rankKey: "b", message: message)]
        server.meBody = #"{"account":{"state":"active"},"features":{},"limits":{}}"#
        let connection = try ClientAPIv2Connection(transport: server, repository: reopened, context: newContext,
            directory: v2Directory, errors: RecordingErrorLogV2(), foregroundOnlyWrites: true)
        XCTAssertTrue(try persistedOutbox.load().isEmpty)
        let run = Task { await connection.runForeground() }
        defer { run.cancel() }
        await eventually("the new items are published") {
            (try? reopened.conversationSnapshot(context: newContext).threads.count) == 2
        }
        do {
            try await connection.sendSavedAnswer(answer.intentID)
            XCTFail("The held answer must not be callable through Retry.")
        } catch AttentionStoreError.intentMissing {}
        await connection.sendSavedContentOpens()
        await connection.sendSavedConversationReads()
        await connection.outbox.flush()
        XCTAssertTrue(server.received.allSatisfy { $0.method == .get })

        // A deliberate new open can still target the colliding ID, with a
        // fresh key which survives the next process restart.
        let freshOpen = try reopened.enqueueMessageOpen(key, requestRevision: 1, context: newContext)
        XCTAssertNotEqual(freshOpen.operationID, seen.operationID)
        run.cancel()
        await run.value
        let secondContext = ProfileContext(identity: identity, transportMode: .relay)
        let second = try ClientRepository(context: secondContext, persistence: persistence)
        try second.migratePendingItemActionsToClientAPI(context: secondContext)
        let nextConnection = try ClientAPIv2Connection(transport: server, repository: second,
            context: secondContext, directory: nil, errors: RecordingErrorLogV2())
        await nextConnection.sendSavedContentOpens()
        await eventually("the fresh v2 open settles under its saved key") {
            (try? second.snapshot(context: secondContext).pendingMessageOpens.isEmpty) == true
        }
        let writes = server.received.filter { $0.method != .get }
        XCTAssertEqual(writes.map(\.idempotencyKey), [freshOpen.operationID])
        XCTAssertEqual(writes.map(\.path), ["/v2/items/i42/seen"])
    }

    func testForegroundRecoversSavedSeenReadAndAnswerAndSettlesTheirKeys() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryPendingActionPersistence()
        let first = try ClientRepository(context: context, persistence: persistence)
        let model = ServerModelV2Store(fileURL: nil)
        let message = #"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"ok","label":"OK","kind":"value","value":true}]}}"#
        let item = V2Fixture.item("i", rev: 1, rankKey: "a", message: message)
        try model.apply(kind: "item", rev: 1, data: V2Fixture.json(item))
        try model.open("i")
        try model.apply(kind: "entry", rev: 2,
                        data: V2Fixture.json(V2Fixture.entry("entry-first", item: "i", rev: 2, position: 4)))
        try first.restoreCachedServerState(ServerModelV2Projection.cachedState(model.snapshot, identity: identity),
                                           context: context)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"), messageID: ExactText("i"))
        let seen = try first.enqueueMessageOpen(key, requestRevision: 1, context: context)
        let read = try XCTUnwrap(first.markConversationRead(key, through: ExactText("entry-first"), context: context))
        let port = AttentionDomainPort(store: first)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
            inputs: [.compatibilityValue(action: ExactText("ok"))]))
        let answer = try XCTUnwrap(first.lookupIntent(receipt.intentID, context: context))

        let reopened = try ClientRepository(context: context, persistence: persistence)
        XCTAssertEqual(try reopened.savedV2ReadPositions(context: context).first?.entryID,
                       ExactText("entry-first"))
        let server = FakeClientAPIServer()
        server.inboxItems = [V2Fixture.item("i", rev: 3, rankKey: "a")
            .replacingOccurrences(of: #""request_revision":1"#, with: #""request_revision":2"#)]
        server.meBody = #"{"account":{"state":"active"},"features":{},"limits":{}}"#
        let connection = try ClientAPIv2Connection(transport: server, repository: reopened, context: context,
            directory: nil, errors: RecordingErrorLogV2(), foregroundOnlyWrites: true)
        let run = Task { await connection.runForeground() }
        defer { run.cancel() }
        let keys = [seen.operationID, read.operationID, answer.operationID]
        await eventually("each operation settles in the repository") {
            guard let live = try? reopened.lookupIntent(answer.intentID, context: context),
                  case .accepted = live.disposition else { return false }
            return (try? reopened.snapshot(context: context).pendingMessageOpens.isEmpty) == true &&
                (try? reopened.savedV2ReadPositions(context: context).isEmpty) == true
        }
        let writes = server.received.filter { $0.idempotencyKey != nil }
        XCTAssertEqual(writes.count, keys.count)
        XCTAssertEqual(Set(writes.compactMap(\.idempotencyKey)), Set(keys))
        let expected = [
            (seen.operationID, "/v2/items/i/seen", "{}"),
            (read.operationID, "/v2/items/i/read-position", #"{"entry_id":"entry-first"}"#),
            (answer.operationID, "/v2/items/i/answer", #"{"request_revision":1,"choice":"ok"}"#)
        ]
        for (key, path, body) in expected {
            let write = try XCTUnwrap(writes.first { $0.idempotencyKey == key })
            XCTAssertEqual(write.path, path)
            XCTAssertEqual(String(decoding: write.body ?? Data(), as: UTF8.self), body)
        }
        run.cancel()
        await run.value
    }
}

final class ServerSentEventParserTests: XCTestCase {
    private func events(_ lines: [String]) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        return lines.compactMap { parser.feed(line: $0) }
    }

    func testEventsCarryIdKindAndMultiLineDataAndHeartbeatsAreIgnored() {
        let parsed = events([": heartbeat", "", "id: 7", "event: item", "data: {\"a\":", "data: 1}", "",
                             ": heartbeat", "", "id: 8", "event: entry", "data:{}", ""])
        XCTAssertEqual(parsed, [
            ServerSentEvent(id: "7", event: "item", data: "{\"a\":\n1}", hasExplicitID: true),
            ServerSentEvent(id: "8", event: "entry", data: "{}", hasExplicitID: true)
        ])
    }

    func testAnEventWithoutDataIsNotDispatchedAndTheLastIdCarriesOver() {
        var parser = ServerSentEventParser()
        XCTAssertNil(parser.feed(line: "id: 3"))
        XCTAssertNil(parser.feed(line: ""), "No data, no event.")
        XCTAssertNil(parser.feed(line: "data: x"))
        XCTAssertEqual(parser.feed(line: ""), ServerSentEvent(id: "3", event: "message", data: "x",
                                                              hasExplicitID: false))
        XCTAssertEqual(parser.lastEventID, "3", "A reconnect resumes from the last id.")
    }

    func testFeedEventsMapRevKindAndClosingReason() throws {
        XCTAssertEqual(try FeedEvent(ServerSentEvent(id: "12", event: "item", data: "{}", hasExplicitID: true)),
                       .change(FeedChange(rev: 12, kind: .item, data: Data("{}".utf8))))
        XCTAssertEqual(try FeedEvent(ServerSentEvent(id: nil, event: "closing", data: #"{"reason":"revoked"}"#,
                                                   hasExplicitID: false)),
                       .closing(reason: "revoked"))
        XCTAssertThrowsError(try FeedEvent(ServerSentEvent(id: "x", event: "item", data: "{}", hasExplicitID: true)))
        XCTAssertEqual(try FeedEvent(ServerSentEvent(id: nil, event: "heartbeat", data: "{}", hasExplicitID: false)), .heartbeat,
                       "A heartbeat has no id and is not a change.")
    }

    func testErrorBodiesKeepOnlyTheClosedTokenList() {
        let known = APIError(status: 409, body: Data(#"{"error":"stale_request","retryable":false,"request_id":"r1"}"#.utf8),
                             requestID: nil, retryAfter: nil)
        XCTAssertEqual(known.token, .staleRequest)
        XCTAssertEqual(known.requestID, "r1")
        XCTAssertTrue(known.isPermanent)
        let unknown = APIError(status: 503, body: Data(#"{"error":"something the server made up"}"#.utf8),
                               requestID: "r2", retryAfter: 5)
        XCTAssertEqual(unknown.token, .other, "Free-form server text never becomes a token.")
        XCTAssertTrue(unknown.retryable)
        XCTAssertFalse(unknown.isPermanent)
    }
}

final class ChangeFeedSyncTests: XCTestCase {
    func testFirstRunRebaselinesFromASnapshotThenFollowsTheFeedFromItsRev() async throws {
        let server = FakeClientAPIServer()
        server.commit("item", "{}")
        server.commit("item", "{}")
        let model = RecordingSyncModel(snapshotRev: { server.head })
        let cursor = MemoryRevCursor()
        let sync = ChangeFeedSync(transport: server, model: model.using(cursor),
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        let run = Task { await sync.runForeground() }
        await eventually("the feed is open") { server.openFeedCount == 1 }
        XCTAssertEqual(model.rebaselines, 1)
        XCTAssertEqual(try cursor.load(), 2, "The snapshot's rev is the starting cursor.")

        server.commit("entry", "{}")
        await eventually("the live change is applied") { model.applied == [3] }
        XCTAssertEqual(try cursor.load(), 3)
        let state = await sync.liveState
        XCTAssertEqual(state, .live)
        run.cancel()
    }

    func testTheCursorAdvancesOnlyAfterTheChangeIsPersistedAndAFailedApplyIsRedelivered() async throws {
        let server = FakeClientAPIServer()
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let cursor = MemoryRevCursor(0)
        model.onApply = { change in
            // At apply time the cursor has not yet moved past the change.
            XCTAssertLessThan((try? cursor.load()) ?? 0, change.rev)
        }
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, model: model.using(cursor), errors: errors,
                                  waitBeforeRetry: noWait)
        server.commit("item", "{}")
        server.commit("item", "{}")
        model.failApplyAt = 2
        let run = Task { await sync.runForeground() }
        await eventually("both changes applied after the retry") { model.applied == [1, 2] }
        XCTAssertEqual(try cursor.load(), 2)
        XCTAssertEqual(errors.reports.first?.phase, "apply", "The failed apply is in the Error Log.")
        run.cancel()
    }

    func testUnframedFeedDropAndClientIdleDeadlineHaveDistinctAttribution() async throws {
        let cases: [(any Error, ErrorLogInitiator)] = [
            (NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ETIMEDOUT.rawValue)), .unknown),
            (URLError(.timedOut), .unknown),
            (URLError(.networkConnectionLost), .osNetwork),
            (ChangeFeedIdleTimeout.expired, .timeout)
        ]
        for (error, expected) in cases {
            let server = FakeClientAPIServer()
            let cursor = MemoryRevCursor(0)
            let model = RecordingSyncModel(snapshotRev: { 0 })
            let errors = RecordingErrorLogV2()
            let sync = ChangeFeedSync(transport: server, model: model.using(cursor), errors: errors,
                                      waitBeforeRetry: { _ in throw CancellationError() })
            let run = Task { await sync.runForeground() }
            defer { run.cancel() }
            await eventually("the feed is open") { server.openFeedCount == 1 }
            guard server.openFeedCount == 1 else { return }
            server.failFeeds(error)
            await run.value
            let report = try XCTUnwrap(errors.reports.first)
            XCTAssertEqual(report.phase, "stream")
            XCTAssertEqual(report.initiator, expected)
            XCTAssertTrue(report.retryable)
            XCTAssertEqual(try cursor.load(), 0)
        }
    }

    func testAnExpiredCursorRebaselinesAndResumesWithoutMissingLaterChanges() async throws {
        let server = FakeClientAPIServer()
        for _ in 0..<5 { server.commit("item", "{}") }
        server.prune(through: 4)
        let model = RecordingSyncModel(snapshotRev: { server.head })
        let cursor = MemoryRevCursor(1)
        let sync = ChangeFeedSync(transport: server, model: model.using(cursor),
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        let run = Task { await sync.runForeground() }
        await eventually("the feed reopens from the snapshot") { server.openFeedCount == 1 }
        XCTAssertEqual(model.rebaselines, 1)
        XCTAssertEqual(try cursor.load(), 5)
        server.commit("item", "{}")
        await eventually("the next change arrives") { model.applied == [6] }
        run.cancel()
    }

    func testAServerShutdownReconnectsFromTheCursorAndARevokeStopsSync() async throws {
        let server = FakeClientAPIServer()
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, model: model.using(MemoryRevCursor(0)), errors: errors,
                                  waitBeforeRetry: noWait)
        let run = Task { await sync.runForeground() }
        await eventually("open") { server.openFeedCount == 1 }
        server.closeFeeds(reason: "server_shutdown")
        server.commit("item", "{}")
        await eventually("reopened and caught up") { model.applied == [1] }

        server.closeFeeds(reason: "revoked")
        _ = await run.value
        let state = await sync.liveState
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(errors.reports.map(\.initiator), [.serverClosed, .deviceRevoked],
                       "Each server-initiated end names its initiator.")
        XCTAssertTrue(errors.reports.allSatisfy { $0.correlation.requestID?.hasPrefix("req-") == true },
                      "Each report carries the feed's Request-Id.")
    }

    func testCatchUpAdvancesPerBatchSoAFailureResumesFromTheLastFullBatch() async throws {
        let server = FakeClientAPIServer()
        for _ in 0..<5 { server.commit("item", "{}") }
        let model = RecordingSyncModel(snapshotRev: { 0 })
        model.failApplyAt = 4
        let cursor = MemoryRevCursor(1)
        let sync = ChangeFeedSync(transport: server, model: model.using(cursor),
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        do { try await sync.catchUp(); XCTFail("The failed apply ends the catch-up.") } catch {}
        XCTAssertEqual(try cursor.load(), 3, "The first batch (2, 3) is kept; the failed change is not.")
        try await sync.catchUp()
        XCTAssertEqual(model.applied, [2, 3, 4, 5])
        XCTAssertEqual(try cursor.load(), 5)
    }

    func testASeededPersonsZeroCursorRebaselinesInsteadOfReadingFromTheStart() async throws {
        let server = FakeClientAPIServer()
        // Seeded at cut-over: position 1, log retained only from rev 2.
        server.prune(through: 1)
        server.commit("item", "{}")
        let model = RecordingSyncModel(snapshotRev: { server.head })
        let cursor = MemoryRevCursor(0)
        let sync = ChangeFeedSync(transport: server, model: model.using(cursor),
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        try await sync.catchUp()
        XCTAssertEqual(model.rebaselines, 1)
        XCTAssertEqual(try cursor.load(), 2)
    }

    func testARejectedDeviceCertificateStopsSync() async throws {
        let server = FakeClientAPIServer()
        server.feedFailure = URLError(.clientCertificateRejected)
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, model: RecordingSyncModel(snapshotRev: { 0 }).using(MemoryRevCursor(0)), errors: errors,
                                  waitBeforeRetry: noWait)
        await sync.runForeground()
        let state = await sync.liveState
        XCTAssertEqual(state, .stopped, "A revoked device fails at TLS; Sync stops rather than retrying.")
        XCTAssertEqual(errors.reports.map(\.initiator), [.deviceRevoked])
    }

    func testHeartbeatsKeepTheFeedLiveWithoutMovingTheCursorAndAPauseStopsSync() async throws {
        let server = FakeClientAPIServer()
        let cursor = MemoryRevCursor(0)
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let sync = ChangeFeedSync(transport: server, model: model.using(cursor),
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        let run = Task { await sync.runForeground() }
        await eventually("open") { server.openFeedCount == 1 }
        server.heartbeat()
        server.commit("item", "{}")
        await eventually("applied") { model.applied == [1] }
        XCTAssertEqual(cursor.saves, [1], "Only the change moved the cursor.")
        server.closeFeeds(reason: "account_paused")
        _ = await run.value
        let state = await sync.liveState
        XCTAssertEqual(state, .accountPaused)
    }

    func testCatchUpRebaselinesOnceAndReportsASecondExpiry() async throws {
        let server = FakeClientAPIServer()
        for _ in 0..<3 { server.commit("item", "{}") }
        server.prune(through: 3)
        // A snapshot that is itself already too old to resume from.
        let model = RecordingSyncModel(snapshotRev: { 1 })
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, model: model.using(MemoryRevCursor(1)), errors: errors,
                                  waitBeforeRetry: noWait)
        do { try await sync.catchUp(); XCTFail("A second 410 ends the catch-up.") } catch {}
        XCTAssertEqual(model.rebaselines, 1, "No rebaseline loop.")
        XCTAssertEqual(errors.reports.first?.operation, "catch_up")
    }

    func testA401OnTheFeedStopsSyncLikeATLSRefusal() async throws {
        let server = FakeClientAPIServer()
        server.feedFailure = APIError(status: 401, token: .unauthorized, retryable: false, requestID: "r")
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, model: RecordingSyncModel(snapshotRev: { 0 }).using(MemoryRevCursor(0)),
                                  errors: errors, waitBeforeRetry: noWait)
        await sync.runForeground()
        let state = await sync.liveState
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(errors.reports.map(\.initiator), [.deviceRevoked])
    }

    func testPushCatchUpAppliesEveryBatchFromTheCursor() async throws {
        let server = FakeClientAPIServer()
        for _ in 0..<5 { server.commit("item", "{}") }
        let model = RecordingSyncModel(snapshotRev: { 0 })
        let cursor = MemoryRevCursor(1)
        let sync = ChangeFeedSync(transport: server, model: model.using(cursor),
                                  errors: RecordingErrorLogV2(), waitBeforeRetry: noWait)
        try await sync.catchUp()
        XCTAssertEqual(model.applied, [2, 3, 4, 5])
        XCTAssertEqual(try cursor.load(), 5)
    }
}

final class ActionOutboxTests: XCTestCase {
    private func outbox(_ server: FakeClientAPIServer, _ persistence: MemoryOutboxPersistence,
                        _ outcomes: RecordingOutcomes, errors: RecordingErrorLogV2 = RecordingErrorLogV2(),
                        wait: @escaping @Sendable (Int, TimeInterval?) async throws -> Void = noOutboxWait)
        throws -> ActionOutbox {
        server.persistedKeys = { persistence.keys }
        return try ActionOutbox(persistence: persistence, transport: server, outcomes: outcomes, errors: errors,
                                waitBeforeRetry: wait)
    }

    private let seen = FrozenWrite(method: .post, path: "/v2/items/a/seen", body: Data("{}".utf8))

    func testSameItemSeenAndReadPositionProceedWhileAReplyIsHeld() async throws {
        let server = FakeClientAPIServer()
        let held = AsyncGate()
        defer { held.release() }
        let item = ExactText("a")
        let reply = ClientAPIWrites.reply(itemID: item, text: ExactText("Held"))
        server.holdWrites[reply.write.path] = held
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes)
        let waiting = try await box.submit(target: reply.target, operation: reply.operation, write: reply.write)
        await eventually("the reply is in flight") { server.received.contains { $0.idempotencyKey == waiting.id } }
        let seen = ClientAPIWrites.seen(itemID: item)
        let read = ClientAPIWrites.readPosition(itemID: item, entryID: ExactText("first"))
        let seenEntry = try await box.submit(target: seen.target, operation: seen.operation, write: seen.write)
        let readEntry = try await box.submit(target: read.target, operation: read.operation, write: read.write)
        await eventually("both independent reports are accepted while the reply is still held") {
            Set(outcomes.accepted.map(\.0)) == [seenEntry.id, readEntry.id]
        }
        held.release()
        await eventually("the held reply finishes last") { outcomes.accepted.last?.0 == waiting.id }
    }

    func testTheKeyIsPersistedBeforeTheFirstSendAndTheResponseIsApplied() async throws {
        let server = FakeClientAPIServer()
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, persistence, outcomes)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("accepted") { outcomes.accepted.count == 1 }
        XCTAssertEqual(server.keysPersistedAtSend, [true])
        XCTAssertEqual(server.received.first?.idempotencyKey, entry.idempotencyKey)
        XCTAssertEqual(outcomes.accepted.first?.1.rev, 1, "The write's own rev reaches the model at once.")
        let pending = await box.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func testAnUnsavedIntentIsNeverSent() async throws {
        let server = FakeClientAPIServer()
        let persistence = MemoryOutboxPersistence()
        persistence.failNextSave = true
        let box = try outbox(server, persistence, RecordingOutcomes())
        do {
            try await box.submit(target: "a", operation: "mark_seen", write: seen)
            XCTFail("The save failure is reported to the caller.")
        } catch {}
        await box.flush()
        XCTAssertTrue(server.received.isEmpty)
    }

    func testInternalErrorAfterACommittedReplyRetainsTextAndReplaysOnlyOnAction() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [CommittedThenLost(error: APIError(status: 500, token: .internalError,
            retryable: false, requestID: "req-render-reply"))]
        let sent = ClientAPIWrites.reply(itemID: ExactText("a"), text: ExactText("Preserved reply"))
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let errors = RecordingErrorLogV2()
        let box = try outbox(server, persistence, outcomes, errors: errors, wait: { _, _ in
            XCTFail("Automatic write retry scheduled")
        })
        let entry = try await box.submit(target: sent.target, operation: sent.operation, write: sent.write)
        await eventually("the 500 is recorded") { errors.reports.first?.httpStatus == 500 }
        let saved = try XCTUnwrap(try persistence.load().first)
        XCTAssertTrue(saved.outcomeUnknown)
        XCTAssertEqual(saved.waitsForInternalErrorRetry, true)
        XCTAssertEqual(saved.write.body, sent.write.body)
        XCTAssertEqual(saved.id, entry.id)
        XCTAssertEqual(errors.reports.first?.correlation.requestID, "req-render-reply")
        XCTAssertEqual(errors.reports.first?.retryable, false)
        XCTAssertTrue(outcomes.rejected.isEmpty)

        let reopened = try outbox(server, persistence, outcomes, errors: errors)
        await reopened.flush()
        XCTAssertEqual(server.received.count, 1)
        await reopened.retryInternalErrors(operation: "reply")
        XCTAssertEqual(server.received.map(\.idempotencyKey), [entry.id, entry.id])
        XCTAssertEqual(outcomes.accepted.first?.1.replayed, true)
        XCTAssertEqual(server.head, 1)
        XCTAssertTrue(persistence.keys.isEmpty)
    }

    func testAnUnknownOutcomeIsResentWithTheSameKeyAndTheReplayCountsAsTheOriginal() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [CommittedThenLost(error: URLError(.networkConnectionLost))]
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let errors = RecordingErrorLogV2()
        let box = try outbox(server, persistence, outcomes, errors: errors)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("first send ended unknown") { errors.reports.count == 1 }
        XCTAssertEqual(persistence.keys, [entry.idempotencyKey], "Kept, with its key, after an unknown outcome.")

        // Relaunch: a new outbox from the same durable record resends it.
        let relaunched = try outbox(server, persistence, outcomes, errors: errors)
        await relaunched.flush()
        XCTAssertEqual(server.received.map(\.idempotencyKey), [entry.idempotencyKey, entry.idempotencyKey])
        XCTAssertEqual(outcomes.accepted.count, 1)
        XCTAssertEqual(outcomes.accepted.first?.1.replayed, true)
        XCTAssertEqual(server.head, 1, "The server applied the mutation once.")
        XCTAssertTrue(persistence.keys.isEmpty)
        XCTAssertEqual(errors.resolutions, ["actions.mark_seen"])
    }

    func testAnAutomaticRetryResendsAfterAnUnknownOutcome() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [URLError(.timedOut)]
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes,
                             wait: { _, _ in try await Task.sleep(for: .milliseconds(20)) })
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("the retry delivered it") { outcomes.accepted.count == 1 }
        XCTAssertEqual(server.received.map(\.idempotencyKey), [entry.idempotencyKey, entry.idempotencyKey],
                       "The retry is not cancelled by its own send and reuses the key.")
    }

    func testAnUnknownServerErrorWithoutAContractBodyNeverDropsTheWrite() async throws {
        let unknown = APIError(status: 502, body: Data("<html>bad gateway</html>".utf8), requestID: nil, retryAfter: nil)
        XCTAssertTrue(unknown.retryable)
        XCTAssertFalse(unknown.isPermanent)
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [unknown]
        let responseGate = AsyncGate()
        let retryGate = AsyncGate()
        defer { responseGate.release(); retryGate.release() }
        server.holdWrites[seen.path] = responseGate
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let errors = RecordingErrorLogV2()
        let box = try outbox(server, persistence, outcomes, errors: errors, wait: { _, _ in
            await retryGate.wait()
        })
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("the first request is held") { server.received.count == 1 }
        XCTAssertTrue(outcomes.accepted.isEmpty)
        XCTAssertEqual(persistence.keys, [entry.idempotencyKey])

        responseGate.release()
        await eventually("the 502 is recorded before retry") { errors.reports.first?.httpStatus == 502 }
        XCTAssertEqual(persistence.keys, [entry.idempotencyKey])
        XCTAssertTrue(outcomes.rejected.isEmpty)

        retryGate.release()
        await eventually("the retry is accepted and the record settles") {
            outcomes.accepted.count == 1 && persistence.keys.isEmpty
        }
        XCTAssertEqual(server.received.map(\.idempotencyKey), [entry.idempotencyKey, entry.idempotencyKey])
        XCTAssertEqual(outcomes.accepted.map(\.0), [entry.idempotencyKey])
    }

    func testOperationsOnOneItemGoInOrderWhileOtherItemsProceed() async throws {
        let server = FakeClientAPIServer()
        let held = AsyncGate()
        server.holdWrites["/v2/items/a/answer"] = held
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes)
        let answer = try await box.submit(target: "a", operation: "answer",
            write: FrozenWrite(method: .post, path: "/v2/items/a/answer", body: Data(#"{"request_revision":1}"#.utf8)))
        let reply = try await box.submit(target: "a", operation: "reply",
            write: FrozenWrite(method: .post, path: "/v2/items/a/replies", body: Data(#"{"text":"t"}"#.utf8)))
        let other = try await box.submit(target: "b", operation: "mark_seen",
            write: FrozenWrite(method: .post, path: "/v2/items/b/seen", body: Data("{}".utf8)))
        await eventually("the other item is accepted") { outcomes.accepted.map(\.0) == [other.idempotencyKey] }
        XCTAssertFalse(server.received.contains { $0.path == "/v2/items/a/replies" },
                       "The later operation on the same item waits for the earlier one.")
        held.release()
        await eventually("both in order") { outcomes.accepted.count == 3 }
        XCTAssertEqual(outcomes.accepted.map(\.0), [other.idempotencyKey, answer.idempotencyKey, reply.idempotencyKey])
    }

    func testARevokedDeviceHoldsTheOutboxForReviewAfterReenrolment() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [URLError(.clientCertificateRejected)]
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, persistence, outcomes)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("held") { await box.unauthorized }
        XCTAssertEqual(persistence.keys, [entry.idempotencyKey], "Kept, with its key.")
        await box.resumeAfterReenrolment()
        XCTAssertEqual(outcomes.accepted.map(\.0), [entry.idempotencyKey])
    }

    func testAPausedAccountKeepsWritesUntilThePauseEnds() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [APIError(status: 403, body: Data(#"{"error":"account_paused","retryable":false,"request_id":"r"}"#.utf8),
                                             requestID: nil, retryAfter: nil)]
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, persistence, outcomes)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("held") { await box.unauthorized }
        XCTAssertTrue(outcomes.rejected.isEmpty, "A pause never refuses the person's write.")
        XCTAssertEqual(persistence.keys, [entry.idempotencyKey])
        await box.resumeAfterReenrolment()
        XCTAssertEqual(outcomes.accepted.map(\.0), [entry.idempotencyKey])
    }

    func testA401OnAnOpenConnectionHoldsTheOutboxLikeATLSRefusal() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [APIError(status: 401, token: .unauthorized, retryable: false, requestID: "r")]
        let persistence = MemoryOutboxPersistence()
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, persistence, outcomes)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("held") { await box.unauthorized }
        XCTAssertTrue(outcomes.rejected.isEmpty)
        XCTAssertEqual(persistence.keys, [entry.idempotencyKey], "Kept for review after re-enrolment.")
    }

    func testA4xxOutsideTheContractIsGivenUpAfterAFewTries() async throws {
        let outside = APIError(status: 404, body: Data("<html>not here</html>".utf8), requestID: nil, retryAfter: nil)
        XCTAssertTrue(outside.isOutsideContractClientError)
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [outside, outside, outside]
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes)
        try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("first try") { server.received.count == 1 }
        await box.flush()
        await box.flush()
        XCTAssertEqual(server.received.count, 3)
        XCTAssertEqual(outcomes.rejected.count, 1, "It no longer blocks the item's later writes.")
    }

    func testOnlyAnswersOutsideTheContractCountAndARefusedWriteStaysVisibleAsFailed() async throws {
        let outside = APIError(status: 404, body: Data("<html>not here</html>".utf8), requestID: nil, retryAfter: nil)
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [URLError(.timedOut), outside, URLError(.timedOut), outside, outside]
        let errors = RecordingErrorLogV2()
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes, errors: errors)
        let entry = try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("first try") { server.received.count == 1 }
        for _ in 0..<3 { await box.flush() }
        XCTAssertTrue(outcomes.rejected.isEmpty, "Transient failures do not count toward the limit.")
        await box.flush()
        XCTAssertEqual(server.received.count, 5)
        XCTAssertEqual(outcomes.rejected.map(\.0), [entry.idempotencyKey])
        let failed = await box.failedWrites
        XCTAssertEqual(failed.map(\.idempotencyKey), [entry.idempotencyKey], "Kept as failed, not dropped.")
        XCTAssertEqual(failed.first?.failure, OutboxFailure(status: 404, token: "other"))
        let pending = await box.pending
        XCTAssertTrue(pending.isEmpty, "A failed write no longer blocks the item's later writes.")
        XCTAssertEqual(errors.reports.last?.retryable, false)
        await box.discardFailed(entry.idempotencyKey)
        let afterDiscard = await box.failedWrites
        XCTAssertTrue(afterDiscard.isEmpty)
    }

    func testAForbiddenWriteIsADefinitiveRefusal() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [APIError(status: 403, body: Data(#"{"error":"forbidden","retryable":false,"request_id":"r"}"#.utf8),
                                             requestID: nil, retryAfter: nil)]
        let outcomes = RecordingOutcomes()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes)
        try await box.submit(target: "a", operation: "mark_seen", write: seen)
        await eventually("refused") { outcomes.rejected.count == 1 }
        XCTAssertEqual(outcomes.rejected.first?.1.token, .forbidden)
    }

    func testADefinitiveRefusalLeavesTheOutboxAndIsShownWithItsToken() async throws {
        let server = FakeClientAPIServer()
        server.nextWriteFailures = [APIError(status: 409, token: .staleRequest, retryable: false, requestID: "req-x")]
        let outcomes = RecordingOutcomes()
        let errors = RecordingErrorLogV2()
        let box = try outbox(server, MemoryOutboxPersistence(), outcomes, errors: errors)
        try await box.submit(target: "a", operation: "answer",
            write: FrozenWrite(method: .post, path: "/v2/items/a/answer", body: Data("{}".utf8)))
        await eventually("refused") { outcomes.rejected.count == 1 }
        XCTAssertEqual(outcomes.rejected.first?.1.token, .staleRequest)
        XCTAssertEqual(errors.reports.first?.correlation.requestID, "req-x",
                       "The Request-Id is kept for correlation.")
        XCTAssertEqual(errors.reports.first?.httpStatus, 409)
        XCTAssertEqual(errors.reports.first?.retryable, false)
        let pending = await box.pending
        XCTAssertTrue(pending.isEmpty)
    }
}

/// Design section 8 on the r2 API: a failing change feed cannot stop reads
/// or actions.
final class ClientAPIIsolationTests: XCTestCase {
    private func assertReadsAndActionsSurviveAFailingFeed(_ failure: any Error) async throws {
        let server = FakeClientAPIServer()
        server.feedFailure = failure
        let errors = RecordingErrorLogV2()
        let sync = ChangeFeedSync(transport: server, model: RecordingSyncModel(snapshotRev: { 0 }).using(MemoryRevCursor(0)), errors: errors,
                                  waitBeforeRetry: noWait)
        let run = Task { await sync.runForeground() }
        await eventually("the feed failure was reported") { errors.reports.contains { $0.concern == .sync } }

        let read = try await server.send(.get("/v2/inbox"))
        XCTAssertEqual(read.status, 200, "The inbox read succeeds while the feed is failing.")
        let outcomes = RecordingOutcomes()
        let box = try ActionOutbox(persistence: MemoryOutboxPersistence(), transport: server, outcomes: outcomes,
                                   errors: errors, waitBeforeRetry: noOutboxWait)
        try await box.submit(target: "a", operation: "mark_seen",
                             write: FrozenWrite(method: .post, path: "/v2/items/a/seen", body: Data("{}".utf8)))
        await eventually("Mark Seen is confirmed") { outcomes.accepted.count == 1 }
        XCTAssertFalse(errors.reports.contains { $0.concern != .sync },
                       "Only Sync reports the feed failure.")
        run.cancel()
    }

    func testReadsAndMarkSeenSurviveACancelledFeed() async throws {
        try await assertReadsAndActionsSurviveAFailingFeed(URLError(.cancelled))
    }

    func testReadsAndMarkSeenSurviveAnAbortedFeed() async throws {
        try await assertReadsAndActionsSurviveAFailingFeed(POSIXError(.ECONNABORTED))
    }
}

final class RevGateTests: XCTestCase {
    func testOnlyNewerRevsApplyAndARemovalCannotBeUndoneByAnOlderSnapshot() {
        var gate = RevGate()
        XCTAssertTrue(gate.admit("item-a", rev: 5))
        XCTAssertFalse(gate.admit("item-a", rev: 5), "A duplicate is a no-op.")
        XCTAssertFalse(gate.admit("item-a", rev: 4), "An older change is a no-op.")
        let removedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(gate.admitRemoval("item-a", rev: 7, at: removedAt))
        XCTAssertFalse(gate.admit("item-a", rev: 6), "An older snapshot cannot bring the item back.")
        XCTAssertTrue(gate.isRemoved("item-a"))
        XCTAssertTrue(gate.admit("item-a", rev: 8), "A newer write does.")
        XCTAssertFalse(gate.isRemoved("item-a"))
    }

    func testTombstonesAreKeptForTheRetentionWindowOnly() {
        var gate = RevGate()
        let removedAt = Date(timeIntervalSince1970: 1_000)
        _ = gate.admitRemoval("item-a", rev: 3, at: removedAt)
        gate.pruneTombstones(now: removedAt.addingTimeInterval(RevGate.tombstoneRetention - 1))
        XCTAssertTrue(gate.isRemoved("item-a"))
        gate.pruneTombstones(now: removedAt.addingTimeInterval(RevGate.tombstoneRetention + 1))
        XCTAssertFalse(gate.isRemoved("item-a"))
    }
}
