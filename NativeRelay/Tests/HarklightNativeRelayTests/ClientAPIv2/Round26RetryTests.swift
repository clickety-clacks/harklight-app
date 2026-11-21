import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

private actor Round26TestTransport: ClientAPITransport {
    nonisolated let base = FakeClientAPIServer()
    let putGate = AsyncGate()
    private(set) var meReads = 0
    private(set) var settingsReads = 0
    private(set) var puts = 0
    private var revision = 1
    private var name = "Old"
    private var failingMe = false
    private var failSettings = false

    func failEveryMe() { failingMe = true }
    func failNextSettings() { failSettings = true }

    func send(_ request: APIRequest) async throws -> APIResponse {
        switch (request.method, request.path) {
        case (.get, "/v2/me"):
            meReads += 1
            if failingMe { throw Self.failure("req-me-\(meReads)") }
            let body = #"{"account":{"state":"active"},"features":{"priority_level_editing":true},"limits":{}}"#
            return APIResponse(status: 200, requestID: "me", body: Data(body.utf8))
        case (.get, "/v2/settings"):
            settingsReads += 1
            if failSettings {
                failSettings = false
                throw Self.failure("req-settings-fault")
            }
            return settings(etag: "\"settings-\(revision)\"")
        case (.put, "/v2/settings/priority-levels"):
            puts += 1
            await putGate.wait()
            revision = 2
            name = "My edit"
            return settings(etag: nil)
        default:
            return try await base.send(request)
        }
    }

    static func failure(_ id: String) -> APIError {
        APIError(status: 500, body: Data(#"{"error":"internal_error","retryable":false,"message":"private probe text"}"#.utf8),
                 requestID: id, retryAfter: nil)
    }

    private func settings(etag: String?) -> APIResponse {
        let inner =
            #"{"rev":\#(revision),"priority_levels":[{"name":"\#(name)","lower_bound":0,"bounce_after_days":null}],"push":{"state":"unconfigured","revision":0}}"#
        let body = #"{"rev":\#(revision),"settings":\#(inner)}"#
        return APIResponse(status: 200, requestID: "settings", body: Data(body.utf8), etag: etag)
    }

    nonisolated func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        base.changeFeed(after: after)
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        try await base.changeBatch(after: after)
    }
}

final class Round26RetryTests: XCTestCase {
    private let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
        personID: ExactText("person"), deviceID: ExactText("device"))

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testSceneTimerDoesNotRetryMeAfterA500OnAnAccountAlreadyPaused() async throws {
        let server = Round26TestTransport()
        await server.failEveryMe()
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let errors = RecordingErrorLogV2()
        let connection = try ClientAPIv2Connection(transport: server, repository: repository,
            context: context, directory: nil, errors: errors, meWaitBeforeRetry: { _ in
                XCTFail("The /me backoff loop must stop on internal_error.")
            })
        connection.access.pause()
        await connection.runForeground()
        let initialReads = await server.meReads
        XCTAssertEqual(initialReads, 1)
        XCTAssertEqual(connection.access.state, .paused)
        XCTAssertFalse(connection.canPollMe)

        // The timer will abstain, and independent automatic callers still cannot bypass the pause.
        for _ in 0..<2 {
            _ = try? await connection.refreshMe()
        }
        let finalReads = await server.meReads
        XCTAssertEqual(finalReads, 1)
        XCTAssertEqual(errors.reports.map(\.correlation.requestID), ["req-me-1"])

        _ = try? await connection.refreshMe(userInitiated: true)
        let deliberateReads = await server.meReads
        XCTAssertEqual(deliberateReads, 2)
        XCTAssertEqual(errors.reports.last?.correlation.requestID, "req-me-2")

        await connection.runForeground()
        let foregroundReads = await server.meReads
        XCTAssertEqual(foregroundReads, 3)
        XCTAssertEqual(errors.reports.last?.correlation.requestID, "req-me-3")
    }

    func testSaveCompletionCannotAutomaticallyRetryAPausedSettingsRead() async throws {
        let server = Round26TestTransport()
        defer { server.putGate.release() }
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let errors = RecordingErrorLogV2()
        let connection = try ClientAPIv2Connection(transport: server, repository: repository,
            context: context, directory: nil, errors: errors)
        try await connection.refreshMe()
        await connection.refreshPriorityLevels()
        let draft = [PriorityLevelDraftRow(name: "My edit", lowerBound: "0")]
        try repository.savePriorityLevelsDraft(draft, context: context)
        let levels = try XCTUnwrap(PriorityLevelsTableValidation.levels(from: draft))
        try await connection.savePriorityLevels(levels)
        try await waitFor { await server.puts == 1 }

        await server.failNextSettings()
        await connection.refreshPriorityLevels(userInitiated: false)
        XCTAssertEqual(errors.reports.first?.correlation.requestID, "req-settings-fault")
        await connection.refreshPriorityLevels(userInitiated: false)
        let held = await server.settingsReads
        XCTAssertEqual(held, 2)

        server.putGate.release()
        try await waitFor { await connection.outbox.pending.isEmpty }
        let afterAccept = await server.settingsReads
        XCTAssertEqual(afterAccept, 2, "Settling an earlier PUT is not a user action or foreground transition.")
        XCTAssertEqual(try repository.snapshot(context: context).priorityLevels.confirmedLevels, levels)
    }

    func testExplicitEntriesRetryRecordsTheRequestIDOfItsOwn500() async throws {
        let server = FakeClientAPIServer()
        server.replyEntry = { _ in "{}" }
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let logs = ErrorLogStore(fileURL: nil, build: ErrorLogBuild(version: "0.2", build: "1", commit: "0d63aab"))
        let connection = try ClientAPIv2Connection(transport: server, repository: repository,
            context: context, directory: nil, errors: logs)
        let item = try APIItem(json: V2Fixture.json(V2Fixture.item("i", rev: 1, rankKey: "a")))
        try connection.model.rebaseline(items: [item], counts: APICounts(unresolved: 1), position: 1)
        server.nextEntriesFailure = Round26TestTransport.failure("req-entries-original")
        _ = try? await connection.loadEntriesIfNeeded(itemID: ExactText("i"))
        XCTAssertEqual(logs.records.first?.correlation.requestID, "req-entries-original")
        server.nextEntriesFailure = Round26TestTransport.failure("req-entries-later")
        let record = try XCTUnwrap(logs.records.first)

        do { try await connection.retryInternalError(record) }
        catch let error as APIError { XCTAssertEqual(error.requestID, "req-entries-later") }
        XCTAssertEqual(logs.records.first?.correlation.requestID, "req-entries-later")
        XCTAssertEqual(logs.records.first?.isResolved, false)
        XCTAssertFalse(connection.model.snapshot.loadedEntryItems.contains(ExactText("i")))
        XCTAssertEqual(connection.model.heldCursor, 1)
    }

    func testCommitted500PreservesDiskBackedReplyAndDraftUntilSameKeyRetry() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pendingURL = root.appendingPathComponent("pending")
        let profileURL = root.appendingPathComponent("profile")
        let logsURL = root.appendingPathComponent("errors")
        let build = ErrorLogBuild(version: "0.2", build: "1", commit: "0d63aab")
        let repository = try ClientRepository(context: context, persistence: FilePendingActionPersistence(directoryURL: pendingURL))
        let logs = ErrorLogStore(fileURL: logsURL, build: build)
        let server = FakeClientAPIServer()
        let item = V2Fixture.item("i", rev: 1, rankKey: "a")
        server.commit("item", item)
        server.inboxItems = [item]
        server.meBody = #"{"account":{"state":"active"},"features":{},"limits":{}}"#
        server.replyEntry = { revision in
            #"{"entry_id":"accepted","item_id":"i","rev":\#(revision),"position":1,"kind":"reply","author":"person","request_revision":1,"text":"retained reply","files":[]}"#
        }
        server.nextWriteFailures = [CommittedThenLost(error: APIError(status: 500, token: .internalError,
            retryable: false, requestID: "req-reply-render"))]
        let connection = try ClientAPIv2Connection(transport: server, repository: repository,
            context: context, directory: profileURL, errors: logs, foregroundOnlyWrites: true,
            outboxWaitBeforeRetry: { _, _ in XCTFail("500 must never schedule an outbox retry.") })
        try connection.model.rebaseline(items: [APIItem(json: V2Fixture.json(item))],
                                        counts: APICounts(unresolved: 1), position: 1)
        try connection.model.open("i")
        try await connection.refreshMe()
        let foreground = Task { await connection.runForeground() }
        defer { foreground.cancel() }
        try await waitFor { server.openFeedCount == 1 }

        let request = RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"), messageID: ExactText("i"))
        let binding = ConversationBinding(request: request, revision: 1)
        try repository.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("retained reply")), context: context)
        let message = try repository.queueChatMessage(binding, context: context)
        let key = try XCTUnwrap(message.operationID)
        try repository.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("separate draft")), context: context)
        try await connection.queuedReplyWasSaved(message)
        try await waitFor {
            (try? repository.queuedChatMessages(context: context).first?.disposition) == .outcomeUnknown(key)
        }
        let failed = try XCTUnwrap(logs.records.first { $0.operation == "reply" })
        XCTAssertEqual(failed.correlation.requestID, "req-reply-render")
        XCTAssertEqual(failed.correlation.clientOperationID, key)
        XCTAssertFalse(ErrorLogDetails.text(for: failed).contains("retained reply"))
        let pausedReply = try XCTUnwrap(repository.queuedChatMessages(context: context).first)
        XCTAssertEqual(pausedReply.disposition, .outcomeUnknown(key),
                       "The thread renders submitting as Sending, even though a 500 holds the reply until action.")
        try await connection.catchUp()
        await connection.outbox.flush()
        XCTAssertEqual(server.received.compactMap(\.idempotencyKey), [key])
        XCTAssertEqual(server.head, 2)
        let stored = try FileOutboxPersistence(url: profileURL.appendingPathComponent("outbox-v2.json")).load()
        XCTAssertEqual(stored.map(\.id), [key])
        XCTAssertEqual(stored.first?.waitsForInternalErrorRetry, true)
        XCTAssertEqual(stored.first?.write.body, Data(#"{"text":"retained reply"}"#.utf8))
        foreground.cancel()
        await foreground.value
        logs.close()

        let newContext = ProfileContext(identity: identity, transportMode: .relay)
        let restored = try ClientRepository(context: newContext, persistence: FilePendingActionPersistence(directoryURL: pendingURL))
        let restoredLogs = ErrorLogStore(fileURL: logsURL, build: build)
        let reopened = try ClientAPIv2Connection(transport: server, repository: restored,
            context: newContext, directory: profileURL, errors: restoredLogs, foregroundOnlyWrites: true)
        let queuedBeforeRetry = try restored.queuedChatMessages(context: newContext)
        XCTAssertEqual(queuedBeforeRetry.map(\.text.rawValue), ["retained reply"])
        XCTAssertEqual(queuedBeforeRetry.compactMap(\.operationID), [key])
        await reopened.outbox.resumeSending()
        await reopened.outbox.flush()
        XCTAssertEqual(server.received.compactMap(\.idempotencyKey), [key])

        let pausedMessage = try XCTUnwrap(queuedBeforeRetry.first)
        XCTAssertEqual(pausedMessage.disposition, .outcomeUnknown(key))
        let banner = ErrorLogDisplay.inContext(records: restoredLogs.records,
            surface: .item(clientOperationID: key), now: Date())
        guard case let .failing(persistedFailure) = banner else {
            return XCTFail("The parked reply should expose its own copyable error details.")
        }
        XCTAssertEqual(persistedFailure.id, failed.id)
        try await reopened.queuedReplyWasSaved(pausedMessage)
        XCTAssertEqual(server.received.compactMap(\.idempotencyKey), [key, key])
        XCTAssertEqual(server.head, 2, "There was one committed reply.")
        let thread = try XCTUnwrap(restored.conversationSnapshot(context: newContext).threads[request])
        XCTAssertEqual(thread.turns.filter { $0.id == ExactText("accepted") }.count, 1)
        XCTAssertEqual(thread.drafts[1]?.text.rawValue, "separate draft")
        XCTAssertTrue(try restored.queuedChatMessages(context: newContext).isEmpty)
        XCTAssertTrue(try XCTUnwrap(restoredLogs.records.first { $0.id == failed.id }).isResolved)
    }
}
