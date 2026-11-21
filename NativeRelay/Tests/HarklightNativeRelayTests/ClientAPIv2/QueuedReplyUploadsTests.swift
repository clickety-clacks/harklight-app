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
