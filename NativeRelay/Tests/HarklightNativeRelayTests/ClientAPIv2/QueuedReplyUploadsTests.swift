import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

final class QueuedReplyUploadsTests: XCTestCase {
    private func fixture() throws -> (URL, URL, ConversationDraft) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sample.txt")
        try Data("abc".utf8).write(to: fileURL)
        let file = ConversationFile(id: ExactText("local"), name: ExactText("sample.txt"), byteCount: 3,
            sha256: ExactText("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            content: .localFile(ExactText("sample.txt")))
        let request = RequestKey(accountScope: ExactText("person"), senderID: ExactText("origin"),
                                 messageID: ExactText("item"))
        let draft = ConversationDraft(binding: ConversationBinding(request: request, revision: 1),
                                      text: ExactText("See file"), files: [file])
        return (directory, fileURL, draft)
    }

    func testRelaunchReplaysAnUnknownUploadWithTheSavedKeyAndBytesOnlyOnce() async throws {
        let (directory, fileURL, draft) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UploadReplayTransport()
        let files = ClientAPIFiles(transport: server)
        let operation = UUID()
        let first = try QueuedReplyUploads(directory: directory, files: files, source: { _ in fileURL })
        do {
            _ = try await first.prepare(draft, operation: operation, cap: .unlimited)
            XCTFail("The first response should be lost.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }

        let relaunched = try QueuedReplyUploads(directory: directory, files: files, source: { _ in fileURL })
        let handles = try await relaunched.prepare(draft, operation: operation, cap: .unlimited)
        XCTAssertEqual(handles.map(\.value), [ExactText("stage-1")])
        let savedHandles = try await relaunched.prepare(draft, operation: operation, cap: .unlimited)
        XCTAssertEqual(savedHandles, handles)
        let report = await server.report
        XCTAssertEqual(report.requests.count, 2)
        XCTAssertEqual(report.requests.first, report.requests.last)
        XCTAssertEqual(report.created, 1)
    }

    func testAbandonedUnknownUploadIsRecoveredAndDiscardedWithoutStagingUntouchedFiles() async throws {
        let (directory, fileURL, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var draft = initial
        draft.files.append(ConversationFile(id: ExactText("never-started"), name: ExactText("other.txt"),
            byteCount: 3, sha256: initial.files[0].sha256, content: initial.files[0].content))
        let server = UploadReplayTransport()
        let files = ClientAPIFiles(transport: server)
        let operation = UUID()
        let first = try QueuedReplyUploads(directory: directory, files: files, source: { _ in fileURL })
        do {
            _ = try await first.prepare(draft, operation: operation, cap: .unlimited)
            XCTFail("The first response should be lost.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }

        let relaunched = try QueuedReplyUploads(directory: directory, files: files, source: { _ in fileURL })
        let failures = await relaunched.discardAbandoned(keeping: [])
        XCTAssertTrue(failures.isEmpty)
        _ = await relaunched.discardAbandoned(keeping: [])
        let report = await server.report
        XCTAssertEqual(report.requests.count, 2)
        XCTAssertEqual(report.created, 1)
        XCTAssertEqual(report.discarded, ["/v2/files/stage-1"])
    }

    func testHeldUploadKeepsItsItemsReplyOrderWithoutBlockingAnotherItem() async throws {
        let (directory, fileURL, draft) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = HeldUploadTransport()
        let (repository, context) = try seededRepository(server.base)
        let first = try queue(draft.text, files: draft.files, item: "item", in: repository, context: context)
        let second = try queue(ExactText("next on same item"), item: "item", in: repository, context: context)
        let v2 = try ClientAPIv2Connection(transport: server, repository: repository, context: context,
            directory: directory, errors: NoopErrorLog(), foregroundOnlyWrites: true,
            retainedUploadURL: { _ in fileURL })
        let run = Task { await v2.runForeground() }
        defer { server.gate.release(); run.cancel() }

        try await waitFor { await server.uploadCount == 1 }
        let independent = try queue(ExactText("other item"), item: "other", in: repository, context: context)
        try await v2.queuedReplyWasSaved(independent)
        try await waitFor {
            server.base.received.contains { $0.idempotencyKey == independent.operationID }
        }
        XCTAssertFalse(server.base.received.contains { $0.path == "/v2/items/item/replies" })
        server.gate.release()
        try await waitFor { server.base.received.contains { $0.idempotencyKey == second.operationID } }
        let requests = server.base.received.filter { $0.path == "/v2/items/item/replies" }
        XCTAssertEqual(Array(requests.prefix(2)).map(\.idempotencyKey), [first.operationID, second.operationID])
        let attached = try XCTUnwrap(requests.first?.body)
        XCTAssertEqual(try JSONValue.parse(attached).uniqueValue(named: "file_ids")?.arrayValues,
                       [.string(ExactText("stage-1"))])
    }

    func testCancelDuringUploadRestoresDraftAndDeletesStagingWithoutAReply() async throws {
        let (directory, fileURL, draft) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = HeldUploadTransport()
        let (repository, context) = try seededRepository(server.base)
        let reply = try queue(draft.text, files: draft.files, item: "item", in: repository, context: context)
        let operation = try XCTUnwrap(reply.operationID)
        let v2 = try ClientAPIv2Connection(transport: server, repository: repository, context: context,
            directory: directory, errors: NoopErrorLog(), foregroundOnlyWrites: true,
            retainedUploadURL: { _ in fileURL })
        let run = Task { await v2.runForeground() }
        defer { server.gate.release(); run.cancel() }

        try await waitFor { await server.uploadCount == 1 }
        try await v2.cancelQueuedAttachmentReply(operation, request: reply.binding.request)
        let saved = try repository.conversationSnapshot(context: context).threads[reply.binding.request]?.drafts[1]
        XCTAssertEqual(saved?.text, draft.text)
        XCTAssertEqual(saved?.files, draft.files)
        XCTAssertTrue(try repository.queuedChatMessages(context: context).isEmpty)
        server.gate.release()
        try await waitFor { await server.discarded == ["/v2/files/stage-1"] }
        XCTAssertFalse(server.base.received.contains { $0.idempotencyKey == operation })
    }

    func testAdvertisedCapPreservesTheFilesForEditWithoutStartingAnUpload() async throws {
        let (directory, fileURL, draft) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = HeldUploadTransport()
        let (repository, context) = try seededRepository(server.base, limit: "2")
        let reply = try queue(draft.text, files: draft.files, item: "item", in: repository, context: context)
        let v2 = try ClientAPIv2Connection(transport: server, repository: repository, context: context,
            directory: directory, errors: NoopErrorLog(), foregroundOnlyWrites: true,
            retainedUploadURL: { _ in fileURL })
        let run = Task { await v2.runForeground() }
        defer { server.gate.release(); run.cancel() }

        try await waitFor {
            try repository.queuedChatMessages(context: context).first?.disposition ==
                .rejected(ExactText("payload_too_large"))
        }
        let uploadCount = await server.uploadCount
        XCTAssertEqual(uploadCount, 0)
        let held = try repository.queuedChatMessages(context: context).first
        XCTAssertEqual(held?.text, reply.text)
        XCTAssertEqual(held?.files, reply.files)
    }

    private func seededRepository(_ server: FakeClientAPIServer, limit: String = #""none""#)
        throws -> (ClientRepository, ProfileContext) {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let model = ServerModelV2Store(fileURL: nil)
        let items = ["item", "other"].map { V2Fixture.item($0, rev: 1, rankKey: $0) }
        for item in items { try model.apply(kind: "item", rev: 1, data: V2Fixture.json(item)) }
        try repository.restoreCachedServerState(ServerModelV2Projection.cachedState(model.snapshot, identity: identity),
                                                 context: context)
        server.inboxItems = items
        server.meBody = #"{"account":{"state":"active"},"features":{},"limits":{"upload_cap_bytes_per_file":\#(limit)}}"#
        return (repository, context)
    }

    private func queue(_ text: ExactText, files: [ConversationFile] = [], item: String,
                       in repository: ClientRepository, context: ProfileContext) throws -> ConversationDraft {
        let key = ServerModelV2Projection.key(for: ExactText(item), sender: ExactText("agent-app"),
                                             identity: context.identity)
        let binding = ConversationBinding(request: key, revision: 1)
        try repository.saveConversationDraft(ConversationDraft(binding: binding, text: text, files: files),
                                              context: context)
        return try repository.queueChatMessage(binding, context: context)
    }

    private func waitFor(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor HeldUploadTransport: ClientAPITransport {
    nonisolated let base = FakeClientAPIServer()
    nonisolated let gate = AsyncGate()
    private(set) var uploadCount = 0
    private(set) var discarded: [String] = []

    func send(_ request: APIRequest) async throws -> APIResponse {
        if request.path == "/v2/files", request.method == .post {
            uploadCount += 1
            await gate.wait()
            try Task.checkCancellation()
            return APIResponse(status: 201, requestID: "upload",
                body: Data(#"{"file_id":"stage-1","name":"sample.txt","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","size":3}"#.utf8))
        }
        if request.method == .delete, request.path == "/v2/files/stage-1" {
            discarded.append(request.path)
            return APIResponse(status: 204, requestID: "discard", body: Data())
        }
        return try await base.send(request)
    }

    nonisolated func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        base.changeFeed(after: after)
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        try await base.changeBatch(after: after)
    }
}

private actor UploadReplayTransport: ClientAPITransport {
    private var requests: [APIRequest] = []
    private var created: [UUID: APIResponse] = [:]
    private var discarded: [String] = []

    var report: (requests: [APIRequest], created: Int, discarded: [String]) {
        (requests, created.count, discarded)
    }

    func send(_ request: APIRequest) async throws -> APIResponse {
        if request.method == .delete {
            discarded.append(request.path)
            return APIResponse(status: 204, requestID: nil, body: Data())
        }
        let key = try XCTUnwrap(request.idempotencyKey)
        let file = try XCTUnwrap(request.fileBody)
        XCTAssertEqual(try Data(contentsOf: file.url), Data("abc".utf8))
        XCTAssertEqual(request.contentType, "text/plain")
        XCTAssertEqual(request.contentDisposition, "attachment; filename*=UTF-8''sample.txt")
        requests.append(request)
        if let reply = created[key] { return reply }
        let reply = APIResponse(status: 201, requestID: nil,
            body: Data(#"{"file_id":"stage-1","name":"sample.txt","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","size":3}"#.utf8))
        created[key] = reply
        throw URLError(.networkConnectionLost)
    }

    nonisolated func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        FeedBatch(changes: [], rev: after, more: false)
    }
}
