import AttentionDomain
import HarklightNativeRelay
import XCTest


@MainActor
private func assertThrowsAsync<T>(
    _ expression: @MainActor () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}

@MainActor
final class ConversationSubmissionTests: XCTestCase {
    private final class Session: AuthenticatedInboxPagingSession, AuthenticatedConversationFileSession, @unchecked Sendable {
        let authenticatedIdentity: ProfileIdentity
        var result: DiscussionOperationResult = .unresolved
        var sent: [(Data, UUID)] = []
        var turn: Data?
        var failReplay = false
        var failLimits = false
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
        func correlatedRequest(_ request: Data, ref: String) async throws -> Data {
            try await inboxRequest(request, ref: ref)
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
            if failLimits { throw InstallationTransportError.unexpectedServerFrame }
            return ConversationFileLimits(inlineDecodedBytes: 262_144, uploadCap: cap)
        }
        func uploadConversationFile(_ file: ConversationFile, from source: URL, binding: ConversationBinding,
                                    operationID: UUID, limits: ConversationFileLimits, originURL: URL) async throws -> ConversationFile {
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
    private func submitDiscussion(_ binding: ConversationBinding, using core: NativeRelayCore) async throws -> DiscussionOperationResult {
        try await core.submitDiscussion(binding,
            retainedFile: { _ in URL(fileURLWithPath: "/unused") },
            persistDraft: { _ in })
    }

    private func setup(files: [ConversationFile] = []) async throws -> (ProfileContext, MemoryAttentionStatePersistence, AttentionDomainStore, ConversationBinding, Session, NativeRelayCore) {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence(), session = Session(context.identity)
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = ConversationBinding(request: RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request")), revision: 1)
        let core = try await NativeRelayCore(store: domain, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try await domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("handle"), payload: .object([
                JSONMember("title", .string(ExactText("Question")))
            ]))), context: context)
        try await domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Exact original text"), files: files), context: context)
        return (context, persistence, domain, binding, session, core)
    }
    func testEditingAnUncertainDraftUsesANewOperationAndKeepsTheEarlierVersionMark() async throws {
        let (context, _, domain, binding, session, core) = try await setup()
        let wire = try ConversationWire(profile: context)
        let storageUnavailableJSON =
            #"{"v":1,"type":"error","ref":"native-discussion","reason":"storage_unavailable"}"# + "\n"
        let storageUnavailableReply = Data(storageUnavailableJSON.utf8)
        session.result = try wire.decodeDiscussionResult(storageUnavailableReply)
        XCTAssertEqual(session.result, .unresolved,
                       "A server-classified unknown outcome must not become a definite refusal.")
        _ = try await submitDiscussion(binding, using: core)
        let operation = try XCTUnwrap(session.sent.first?.1)
        let pendingSnapshot = try await domain.conversationSnapshot(context: context)
        let pending = try XCTUnwrap(pendingSnapshot.threads[binding.request]?.drafts[1])
        XCTAssertEqual(pending.text, ExactText("Exact original text"))
        XCTAssertEqual(pending.disposition, .outcomeUnknown(operation))
        XCTAssertTrue(pending.currentAttemptUnsettled)

        let edited = try await domain.updateConversationDraftText(ExactText("Changed"), for: binding,
                                                                  context: context)
        XCTAssertNil(edited.operationID, "Changed content receives a fresh operation id on the next Send.")
        XCTAssertFalse(edited.currentAttemptUnsettled)
        XCTAssertTrue(edited.earlierVersionMayHaveBeenSent)
        XCTAssertEqual(edited.text, ExactText("Changed"))

        _ = try await submitDiscussion(binding, using: core)
        XCTAssertEqual(session.sent.count, 2)
        XCTAssertEqual(session.sent[0].1, operation)
        XCTAssertNotEqual(session.sent[1].1, operation,
                          "An explicit send of edited content uses a new operation id.")
        let updatedSnapshot = try await domain.conversationSnapshot(context: context)
        let current = try XCTUnwrap(updatedSnapshot.threads[binding.request]?.drafts[1])
        XCTAssertEqual(current.text, ExactText("Changed"))
        XCTAssertTrue(current.currentAttemptUnsettled)
        XCTAssertTrue(current.earlierVersionMayHaveBeenSent)
        let attentionSnapshot = try await domain.snapshot(context: context)
        let conversationSnapshot = try await domain.conversationSnapshot(context: context)
        XCTAssertTrue(attentionSnapshot.intents.isEmpty)
        XCTAssertTrue(attentionSnapshot.outbox.isEmpty)
        XCTAssertEqual(attentionSnapshot.cursor, 1)
        XCTAssertEqual(conversationSnapshot.cursor, 1)
    }
    func testClosedDiscussionReplyRemainsADefiniteRejection() async throws {
        let (context, _, domain, binding, session, core) = try await setup()
        let wire = try ConversationWire(profile: context)
        let closedJSON = #"{"v":1,"type":"error","ref":"native-discussion","reason":"closed"}"# + "\n"
        let closedReply = Data(closedJSON.utf8)
        session.result = try wire.decodeDiscussionResult(closedReply)
        XCTAssertEqual(session.result, .rejected(reason: ExactText("closed")))

        _ = try await submitDiscussion(binding, using: core)

        let rejectedSnapshot = try await domain.conversationSnapshot(context: context)
        let rejected = try XCTUnwrap(rejectedSnapshot.threads[binding.request]?.drafts[1])
        guard case let .rejected(reason) = rejected.disposition else {
            return XCTFail("A definite server refusal must remain a rejected draft.")
        }
        XCTAssertEqual(reason, ExactText("closed"))
        XCTAssertEqual(rejected.text, ExactText("Exact original text"))
        XCTAssertEqual(session.sent.count, 1)
    }
    func testAcceptedResponseSurvivesFailedReplayAndRestartWithoutResubmitting() async throws {
        let (context, persistence, domain, binding, session, core) = try await setup()
        session.result = .accepted(turnID: ExactText("2"))
        session.failReplay = true
        _ = try await submitDiscussion(binding, using: core)
        let operation = try XCTUnwrap(session.sent.first?.1)
        let acceptedSnapshot = try await domain.conversationSnapshot(context: context)
        let acceptedAt = try XCTUnwrap(acceptedSnapshot.threads[binding.request]?.facts[ExactText("2")]?.acceptedAtMilliseconds)
        try await domain.markDiscussionAccepted(binding, operation: operation, turn: ExactText("2"),
            context: context, acceptanceObservedAtMilliseconds: acceptedAt + 60_000)
        let acceptedAgain = try await domain.conversationSnapshot(context: context)
        XCTAssertEqual(acceptedAgain.threads[binding.request]?.facts[ExactText("2")]?.acceptedAtMilliseconds, acceptedAt,
            "A repeated acceptance readback must not reset the age of the unpicked message.")
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let restoredBeforeReplay = try await restored.conversationSnapshot(context: context)
        XCTAssertEqual(restoredBeforeReplay.threads[binding.request]?.facts[ExactText("2")]?.acceptedAtMilliseconds, acceptedAt)
        XCTAssertEqual(restoredBeforeReplay.threads[binding.request]?.drafts[1]?.disposition,
            .acceptedPendingReplay(operation: operation, turn: ExactText("2")))
        XCTAssertEqual(restoredBeforeReplay.cursor, 0)
        session.failReplay = false
        try session.acceptedTurn(operation: operation, text: "Exact original text")
        let restartedCore = try await NativeRelayCore(store: restored, context: context, session: session)
        _ = try await restartedCore.resyncAndDrainOutbox()
        let restoredAfterReplay = try await restored.conversationSnapshot(context: context)
        XCTAssertNil(restoredAfterReplay.threads[binding.request]?.drafts[1])
        XCTAssertEqual(session.sent.count, 1)
        let originalAfterReplay = try await domain.snapshot(context: context)
        XCTAssertEqual(originalAfterReplay.cursor, 1)
    }
    func testUploadCapRefusesTheWholeEntryAndRetainsNamedFileAndText() async throws {
        let file = ConversationFile(id: ExactText("retained"), name: ExactText("large.bin"), byteCount: 300_000,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .localFile(ExactText("retained")))
        let (context, _, domain, binding, session, core) = try await setup(files: [file])
        session.cap = 1024 // Deliberate test deployment, never a product default.
        do { _ = try await submitDiscussion(binding, using: core); XCTFail("Over-cap entry must not send") }
        catch { XCTAssertEqual(error as? ConversationError, .uploadCapExceeded(file: file.name, cap: 1024)) }
        XCTAssertTrue(session.sent.isEmpty)
        let uploadCapSnapshot = try await domain.conversationSnapshot(context: context)
        let draft = try XCTUnwrap(uploadCapSnapshot.threads[binding.request]?.drafts[1])
        XCTAssertEqual(draft.text, ExactText("Exact original text"))
        XCTAssertEqual(draft.files, [file])
        guard case let .rejected(reason) = draft.disposition else { return XCTFail("Known not-sent entry remains editable") }
        XCTAssertTrue(reason.rawValue.contains("large.bin"))
    }
    func testLocalPreparationFailureAfterEditingUncertainDraftKeepsItsNewOperationReusable() async throws {
        let file = ConversationFile(id: ExactText("retained"), name: ExactText("large.bin"), byteCount: 300_000,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .localFile(ExactText("retained")))
        let (context, _, domain, binding, session, core) = try await setup(files: [file])
        _ = try await submitDiscussion(binding, using: core)
        let originalOperation = try XCTUnwrap(session.sent.first?.1)
        let edited = try await domain.updateConversationDraftText(ExactText("Replacement"), for: binding,
                                                                  context: context)
        XCTAssertTrue(edited.earlierVersionMayHaveBeenSent)
        XCTAssertFalse(edited.currentAttemptUnsettled)
        session.failLimits = true
        do { _ = try await submitDiscussion(binding, using: core); XCTFail("Preparation failure must stop this send") }
        catch {}
        let retainedSnapshot = try await domain.conversationSnapshot(context: context)
        let retained = try XCTUnwrap(retainedSnapshot.threads[binding.request]?.drafts[1])
        let editedOperation = try XCTUnwrap(retained.operationID)
        XCTAssertNotEqual(editedOperation, originalOperation)
        XCTAssertEqual(retained.files, [ConversationFile(id: file.id, name: file.name,
            byteCount: file.byteCount, sha256: file.sha256,
            content: .uploaded(ExactText(session.uploadID)))])
        XCTAssertEqual(retained.text, ExactText("Replacement"))
        XCTAssertFalse(retained.currentAttemptUnsettled,
                       "A failure before transmission cannot mark the edited operation as uncertain.")
        XCTAssertTrue(retained.earlierVersionMayHaveBeenSent)
        XCTAssertEqual(retained.failure?.outcome, .notSent)
        XCTAssertEqual(retained.failure?.summary, "The message, or an earlier version, may have been sent.")
        XCTAssertEqual(session.sent.count, 1)
        session.failLimits = false
        _ = try await submitDiscussion(binding, using: core)
        XCTAssertEqual(session.sent.count, 2)
        XCTAssertEqual(session.sent[1].1, editedOperation,
                       "Manual retry after a definite local failure reuses the new draft's operation id.")
    }
}
