import AttentionDomain
import HarklightNativeRelay
import XCTest

final class ConversationSubmissionTests: XCTestCase {
    private final class Session: AuthenticatedConversationFileSession, @unchecked Sendable {
        let authenticatedIdentity: ProfileIdentity
        var result: DiscussionOperationResult = .unresolved
        var sent: [(Data, UUID)] = []
        var turn: Data?
        var failReplay = false
        var failUpload = false
        var cap: UInt64?
        let uploadID = UUID().uuidString.lowercased()
        init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }
        private func data(_ value: String) -> Data { Data(value.utf8) }
        func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
            let since = try JSONValue.parse(request).uniqueValue(named: "since")?.integerValue ?? 0
            try await consume(data(#"{"v":1,"type":"ok","ref":"native-sync"}"#))
            if since == 0 {
                try await consume(data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"request","origin":"origin","as":"message","message":{"title":"Question"},"request_revision":1,"session_handle":"handle","event_id":"1"}"#))
            }
            try await consume(data(#"{"v":1,"type":"resynced","seq":1}"#))
        }
        func acknowledge(_ request: Data) async throws {}
        func openConversation(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
            if failReplay { throw InstallationTransportError.unexpectedServerFrame }
            let since = try JSONValue.parse(request).uniqueValue(named: "since")?.integerValue ?? 0
            try await consume(data(#"{"v":1,"type":"ok","ref":"native-conversation-sync","origin_https_port":9443}"#))
            if since == 0, let turn { try await consume(turn) }
            try await consume(data("{\"v\":1,\"type\":\"conversation_resynced\",\"conversation_seq\":\(turn == nil ? 0 : 1)}"))
        }
        func acknowledgeConversation(_ request: Data) async throws {}
        func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult { .unresolved }
        func conversationFileLimits(originURL: URL) async throws -> ConversationFileLimits {
            ConversationFileLimits(inlineDecodedBytes: 262_144, uploadCap: cap)
        }
        func uploadConversationFile(_ file: ConversationFile, from source: URL, binding: ConversationBinding,
                                    operationID: UUID, limits: ConversationFileLimits, originURL: URL) async throws -> ConversationFile {
            if failUpload { throw ConversationFileTransportError.server(status: 503, reason: ExactText("Upload interrupted")) }
            return ConversationFile(id: file.id, name: file.name, byteCount: file.byteCount, sha256: file.sha256, content: .uploaded(ExactText(uploadID)))
        }
        func sendDiscussion(_ frame: Data, operationID: UUID) async -> DiscussionOperationResult {
            sent.append((frame, operationID))
            return result
        }
        func acceptedTurn(operation: UUID, text: String, id: String = "2") throws {
            turn = Data(JSONValue.object([
                JSONMember("v", .number(JSONNumber(lexeme: "1"))), JSONMember("type", .string(ExactText("conversation"))),
                JSONMember("conversation_seq", .number(JSONNumber(lexeme: "1"))),
                JSONMember("request_revision", .number(JSONNumber(lexeme: "1"))),
                JSONMember("sender_id", .string(ExactText("sender"))), JSONMember("message_id", .string(ExactText("request"))),
                JSONMember("origin", .string(ExactText("origin"))), JSONMember("session_handle", .string(ExactText("handle"))),
                JSONMember("kind", .string(ExactText("discussion"))), JSONMember("author", .string(ExactText("person"))),
                JSONMember("event_id", .string(ExactText(id))), JSONMember("op_id", .string(ExactText(operation.uuidString.lowercased()))),
                JSONMember("text", .string(ExactText(text)))
            ]).jsonString.utf8)
        }
    }
    private func setup(files: [ConversationFile] = []) async throws -> (ProfileContext, MemoryAttentionStatePersistence, AttentionDomainStore, ConversationBinding, Session, NativeRelayCore) {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence(), session = Session(context.identity)
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = ConversationBinding(request: RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request")), revision: 1)
        let core = try NativeRelayCore(store: domain, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Exact original text"), files: files), context: context)
        return (context, persistence, domain, binding, session, core)
    }
    func testUnknownRetryUsesTheExactFrozenOperationAndCannotEditOrCreateAnswerReceipt() async throws {
        let (context, _, domain, binding, session, core) = try await setup()
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        let operation = try XCTUnwrap(session.sent.first?.1)
        XCTAssertThrowsError(try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Changed")), context: context))
        try session.acceptedTurn(operation: operation, text: "Exact original text")
        session.result = .accepted(turnID: ExactText("2"))
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertEqual(session.sent.count, 2)
        XCTAssertEqual(session.sent[0].0, session.sent[1].0)
        XCTAssertEqual(session.sent[0].1, session.sent[1].1)
        let thread = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertNil(thread.drafts[1])
        XCTAssertEqual(thread.turns.last?.operationID, operation)
        XCTAssertTrue(try domain.snapshot(context: context).intents.isEmpty)
        XCTAssertTrue(try domain.snapshot(context: context).outbox.isEmpty)
        XCTAssertEqual(try domain.snapshot(context: context).cursor, 1)
        XCTAssertEqual(try domain.conversationSnapshot(context: context).cursor, 1)
    }
    func testAcceptedResponseSurvivesFailedReplayAndRestartWithoutResubmitting() async throws {
        let (context, persistence, domain, binding, session, core) = try await setup()
        session.result = .accepted(turnID: ExactText("2"))
        session.failReplay = true
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        let operation = try XCTUnwrap(session.sent.first?.1)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        XCTAssertEqual(try restored.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.disposition,
            .acceptedPendingReplay(operation: operation, turn: ExactText("2")))
        XCTAssertEqual(try restored.conversationSnapshot(context: context).cursor, 0)
        session.failReplay = false
        try session.acceptedTurn(operation: operation, text: "Exact original text")
        let restartedCore = try NativeRelayCore(store: restored, context: context, session: session)
        _ = try await restartedCore.resyncAndDrainOutbox()
        XCTAssertNil(try restored.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
        XCTAssertEqual(session.sent.count, 1)
        XCTAssertEqual(try domain.snapshot(context: context).cursor, 1)
    }
    func testUploadCapRefusesTheWholeEntryAndRetainsNamedFileAndText() async throws {
        let file = ConversationFile(id: ExactText("retained"), name: ExactText("large.bin"), byteCount: 300_000,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .localFile(ExactText("retained")))
        let (context, _, domain, binding, session, core) = try await setup(files: [file])
        session.cap = 1024 // Deliberate test deployment, never a product default.
        do { _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }; XCTFail("Over-cap entry must not send") }
        catch { XCTAssertEqual(error as? ConversationError, .uploadCapExceeded(file: file.name, cap: 1024)) }
        XCTAssertTrue(session.sent.isEmpty)
        let draft = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
        XCTAssertEqual(draft.text, ExactText("Exact original text"))
        XCTAssertEqual(draft.files, [file])
        guard case let .rejected(reason) = draft.disposition else { return XCTFail("Known not-sent entry remains editable") }
        XCTAssertTrue(reason.rawValue.contains("large.bin"))
    }
    func testPreparationFailureOnUnknownRetryCannotUnfreezeOrDiscardItsOriginalOperation() async throws {
        let file = ConversationFile(id: ExactText("retained"), name: ExactText("large.bin"), byteCount: 300_000,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .localFile(ExactText("retained")))
        let (context, _, domain, binding, session, core) = try await setup(files: [file])
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        let operation = try XCTUnwrap(session.sent.first?.1)
        session.failUpload = true
        do { _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }; XCTFail("Upload failure must stop this retry") }
        catch {}
        let retained = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
        XCTAssertEqual(retained.disposition, .outcomeUnknown(operation))
        XCTAssertEqual(retained.files, [file])
        XCTAssertThrowsError(try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Replacement")), context: context))
        XCTAssertEqual(session.sent.count, 1)
    }
}
