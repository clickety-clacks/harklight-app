import AttentionDomain
import CryptoKit
import HarklightNativeRelay
import XCTest

final class ConversationFileWireTests: XCTestCase {
    private func context() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
    }
    private func file(_ name: String, bytes: Data) -> ConversationFile {
        ConversationFile(id: ExactText(UUID().uuidString.lowercased()), name: ExactText(name), byteCount: UInt64(bytes.count),
            sha256: ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()), content: .inline(bytes))
    }
    private func wire(_ context: ProfileContext) throws -> ConversationFileWire {
        try ConversationFileWire(profile: context, originURL: URL(string: "https://relay.example:9443/origin/v1")!)
    }
    func testPublishedLimitsHaveNoInventedUploadDefaultOrEndpoint() throws {
        let context = context(), wire = try wire(context)
        let unlimited = try wire.decodeLimits(Data(#"{"v":1,"type":"ok","inline_decoded_bytes_per_entry":262144,"upload_cap_bytes_per_file":"none"}"#.utf8), status: 200)
        XCTAssertEqual(unlimited.inlineDecodedBytes, 262_144)
        XCTAssertNil(unlimited.uploadCap)
        let finite = try wire.decodeLimits(Data(#"{"v":1,"type":"ok","inline_decoded_bytes_per_entry":262144,"upload_cap_bytes_per_file":1024}"#.utf8), status: 200)
        XCTAssertEqual(finite.uploadCap, 1024, "Test-only deployment cap is read, never a product default")
        XCTAssertThrowsError(try wire.decodeLimits(Data(#"{"v":1,"type":"ok","inline_decoded_bytes_per_entry":262144}"#.utf8), status: 200))
        XCTAssertThrowsError(try ConversationFileWire(profile: context, originURL: URL(string: "https://relay.example/origin/v1")!))
        XCTAssertThrowsError(try ConversationFileWire(profile: context, originURL: URL(string: "https://other.example:9443/origin/v1")!))
    }
    func testUploadAndFetchRemainBoundToTheOriginalRequestOperationNameAndBytes() throws {
        let context = context(), wire = try wire(context)
        let original = file("résumé.bin", bytes: Data([0, 255, 0, 2]))
        let operation = UUID(), uploadID = UUID().uuidString.lowercased()
        let binding = ConversationBinding(request: RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request")), revision: 3)
        let request = try wire.uploadRequest(file: original, binding: binding, operationID: operation)
        XCTAssertEqual(request.url?.path, "/origin/v1/upload")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "4")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Harklight-Op-Id"), operation.uuidString.lowercased())
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Harklight-Request-Revision"), "3")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Harklight-Sender-Id"), "author")
        XCTAssertFalse(try XCTUnwrap(request.value(forHTTPHeaderField: "X-Harklight-File-Name")).contains("="))
        let response = Data("{\"v\":1,\"type\":\"ok\",\"upload_id\":\"\(uploadID)\",\"name\":\"résumé.bin\",\"size\":4,\"sha256\":\"\(original.sha256.rawValue)\",\"duplicate\":true}".utf8)
        let uploaded = try wire.decodeUpload(response, status: 200, original: original)
        XCTAssertEqual(uploaded.content, .uploaded(ExactText(uploadID)))
        XCTAssertEqual(uploaded.id, original.id)
        XCTAssertEqual(try wire.fetchRequest(uploaded).url?.path, "/origin/v1/files/" + uploadID)
        XCTAssertThrowsError(try wire.decodeUpload(Data(String(decoding: response, as: UTF8.self).replacingOccurrences(of: "\"size\":4", with: "\"size\":3").utf8), status: 200, original: original))
    }
    func testFrozenUnknownDiscussionRetriesItsExactOperationAndMixedFileFrame() throws {
        let context = context(), persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = ConversationBinding(request: RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("author"), messageID: ExactText("request")), revision: 1)
        try store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        let inline = file("small.bin", bytes: Data([0, 255]))
        let large = ConversationFile(id: ExactText("local-large"), name: ExactText("large.bin"), byteCount: 3_000_000,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .localFile(ExactText("retained-large")))
        let uploaded = ConversationFile(id: large.id, name: large.name, byteCount: large.byteCount,
            sha256: large.sha256, content: .uploaded(ExactText(UUID().uuidString.lowercased())))
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Explain exactly\nthis"), files: [inline, large]), context: context)
        let operation = try store.prepareDiscussion(binding, context: context)
        let frozen = try XCTUnwrap(store.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
        let wire = try ConversationWire(profile: context), limits = ConversationFileLimits(inlineDecodedBytes: 262_144, uploadCap: nil)
        let originalFrame = try wire.discussion(frozen, operationID: operation, preparedFiles: [inline, uploaded], limits: limits)
        try store.markDiscussionOutcome(binding, operation: operation, rejection: nil, context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        XCTAssertEqual(try restored.prepareDiscussion(binding, context: context), operation)
        let retained = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
        XCTAssertEqual(try wire.discussion(retained, operationID: operation, preparedFiles: [inline, uploaded], limits: limits), originalFrame)
        let parsed = try JSONValue.parse(originalFrame)
        XCTAssertEqual(parsed.uniqueValue(named: "text"), .string(ExactText("Explain exactly\nthis")))
        XCTAssertEqual(parsed.uniqueValue(named: "files")?.arrayValues?.last?.uniqueValue(named: "upload_id"),
                       .string({ if case let .uploaded(id) = uploaded.content { return id }; return ExactText("") }()))
        XCTAssertThrowsError(try wire.discussion(retained, operationID: UUID(), preparedFiles: [inline, uploaded], limits: limits))
        XCTAssertThrowsError(try wire.discussion(retained, operationID: operation, preparedFiles: [inline, large], limits: limits))
        XCTAssertEqual(try restored.conversationSnapshot(context: context).threads[binding.request]?.drafts[1], retained)
        XCTAssertTrue(try restored.snapshot(context: context).outbox.isEmpty, "Discussion must not become an answer operation")
    }
    func testDownloadedOriginalBytesAreMeasuredBeyondTheJSONCeiling() throws {
        let wire = try wire(context())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(repeating: 231, count: 3 * 1_048_576 + 17)
        let file = file("large.bin", bytes: bytes), url = directory.appendingPathComponent("copy")
        try bytes.write(to: url)
        try wire.verify(url, file: file)
        try bytes.dropLast().write(to: url)
        XCTAssertThrowsError(try wire.verify(url, file: file))
    }
    func testDefiniteRefusalAndUnknownSubmissionRemainDifferentFromAcceptedTurn() throws {
        let wire = try ConversationWire(profile: context())
        XCTAssertEqual(try wire.decodeDiscussionResult(Data(#"{"v":1,"type":"error","ref":"native-discussion","reason":"closed"}"#.utf8)), .rejected(reason: ExactText("closed")))
        XCTAssertEqual(try wire.decodeDiscussionResult(Data(#"{"v":1,"type":"ok","ref":"native-discussion","seq":7,"event_id":"12"}"#.utf8)), .accepted(turnID: ExactText("12")))
        XCTAssertThrowsError(try wire.decodeDiscussionResult(Data(#"{"v":1,"type":"ok","ref":"native-ack","seq":7}"#.utf8)))
        let fileWire = try self.wire(context())
        XCTAssertThrowsError(try fileWire.decodeLimits(Data(#"{"v":1,"type":"error","reason":"storage_unavailable"}"#.utf8), status: 503)) { error in
            XCTAssertEqual(error as? ConversationFileTransportError, .server(status: 503, reason: ExactText("storage_unavailable")))
        }
    }
}
