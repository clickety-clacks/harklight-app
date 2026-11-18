import AttentionDomain
import HarklightNativeRelay
import XCTest
@testable import Harklight

final class ConversationSubmissionTests: XCTestCase {
    private final class Session: AuthenticatedInboxPagingSession, AuthenticatedConversationCleanupSession, @unchecked Sendable {
        let authenticatedIdentity: ProfileIdentity
        var result: DiscussionOperationResult = .unresolved
        var sent: [(Data, UUID)] = []
        var turn: Data?
        var failReplay = false
        var failUpload = false
        var uploadAttempts = 0
        var uploadHook: (@Sendable () async throws -> Void)?
        var cleanupRequests: [ConversationUploadCleanup] = []
        var failCleanup = false
        var inlineBudget: UInt64 = 262_144
        var limitsHook: (@Sendable () async throws -> Void)?
        var cleanupHook: (@Sendable () async throws -> Void)?
        var sendHook: (@Sendable () async -> Void)?
        var uploadError: ConversationFileTransportError?
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
            try await limitsHook?()
            return ConversationFileLimits(inlineDecodedBytes: inlineBudget, uploadCap: cap)
        }
        func uploadConversationFile(_ file: ConversationFile, from source: URL, binding: ConversationBinding,
                                    operationID: UUID, limits: ConversationFileLimits, originURL: URL) async throws -> ConversationFile {
            uploadAttempts += 1
            try await uploadHook?()
            if let uploadError { throw uploadError }
            if failUpload { throw ConversationFileTransportError.server(status: 503, reason: ExactText("Upload interrupted")) }
            return ConversationFile(id: file.id, name: file.name, byteCount: file.byteCount, sha256: file.sha256, content: .uploaded(ExactText(uploadID)))
        }
        func discardConversationUploads(_ cleanup: ConversationUploadCleanup, originURL: URL) async throws -> ConversationUploadDiscardResult {
            cleanupRequests.append(cleanup)
            try await cleanupHook?()
            if failCleanup { throw InstallationTransportError.unexpectedServerFrame }
            return ConversationUploadDiscardResult(state: .discarded, discarded: 1)
        }
        func sendDiscussion(_ frame: Data, operationID: UUID) async -> DiscussionOperationResult {
            sent.append((frame, operationID))
            await sendHook?()
            return result
        }
        func acceptedTurn(operation: UUID, text: String, id: String = "2", files: [JSONValue] = []) throws {
            turn = Data(JSONValue.object([
                JSONMember("v", .number(JSONNumber(lexeme: "1"))), JSONMember("type", .string(ExactText("conversation"))),
                JSONMember("conversation_seq", .number(JSONNumber(lexeme: "1"))),
                JSONMember("request_revision", .number(JSONNumber(lexeme: "1"))),
                JSONMember("sender_id", .string(ExactText("sender"))), JSONMember("message_id", .string(ExactText("request"))),
                JSONMember("origin", .string(ExactText("origin"))), JSONMember("session_handle", .string(ExactText("handle"))),
                JSONMember("kind", .string(ExactText("discussion"))), JSONMember("author", .string(ExactText("person"))),
                JSONMember("event_id", .string(ExactText(id))), JSONMember("op_id", .string(ExactText(operation.uuidString.lowercased()))),
                JSONMember("text", .string(ExactText(text))), JSONMember("files", .array(files))
            ]).jsonString.utf8)
        }
    }
    private func reopenWithServerCache(_ domain: ClientRepository, context: ProfileContext,
                                       persistence: MemoryPendingActionPersistence) async throws -> ClientRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("server-cache.json")
        let cache = FileServerStateCache(identity: context.identity, fileURL: url)
        try await cache.save(ServerStateCacheSnapshot.make(identity: context.identity,
            from: domain.snapshot(context: context), conversations: domain.conversationSnapshot(context: context)))
        let cached = try await FileServerStateCache(identity: context.identity, fileURL: url).load()
        let restored = try ClientRepository(context: context, persistence: persistence)
        XCTAssertTrue(try restored.conversationSnapshot(context: context).threads.isEmpty)
        try restored.restoreCachedServerState(try XCTUnwrap(cached).attentionDomainState(for: context.identity),
                                              context: context)
        return restored
    }
    private func setup(files: [ConversationFile] = []) async throws -> (ProfileContext, MemoryPendingActionPersistence, ClientRepository, ConversationBinding, Session, NativeRelayCore) {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let persistence = MemoryPendingActionPersistence(), session = Session(context.identity)
        let domain = try ClientRepository(context: context, persistence: persistence)
        let binding = ConversationBinding(request: RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request")), revision: 1)
        let core = try NativeRelayCore(store: domain, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Exact original text"), files: files), context: context)
        return (context, persistence, domain, binding, session, core)
    }
    func testStorageUnavailableReplyKeepsUnknownOperationFrozenForExactRetry() async throws {
        let (context, _, domain, binding, session, core) = try await setup()
        let wire = try ConversationWire(profile: context)
        let storageUnavailableJSON =
            #"{"v":1,"type":"error","ref":"native-discussion","reason":"storage_unavailable"}"# + "\n"
        let storageUnavailableReply = Data(storageUnavailableJSON.utf8)
        session.result = try wire.decodeDiscussionResult(storageUnavailableReply)
        XCTAssertEqual(session.result, .unresolved,
                       "A server-classified unknown outcome must not become a definite refusal.")
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        let operation = try XCTUnwrap(session.sent.first?.1)
        let pending = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
        XCTAssertEqual(pending.text, ExactText("Exact original text"))
        XCTAssertEqual(pending.disposition, .outcomeUnknown(operation))
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
    func testClosedDiscussionReplyRemainsADefiniteRejection() async throws {
        let (context, _, domain, binding, session, core) = try await setup()
        let wire = try ConversationWire(profile: context)
        let closedJSON = #"{"v":1,"type":"error","ref":"native-discussion","reason":"closed"}"# + "\n"
        let closedReply = Data(closedJSON.utf8)
        session.result = try wire.decodeDiscussionResult(closedReply)
        XCTAssertEqual(session.result, .rejected(reason: ExactText("closed")))

        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }

        let rejected = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
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
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        let operation = try XCTUnwrap(session.sent.first?.1)
        let acceptedAt = try XCTUnwrap(domain.conversationSnapshot(context: context)
            .threads[binding.request]?.facts[ExactText("2")]?.acceptedAtMilliseconds)
        try domain.markDiscussionAccepted(binding, operation: operation, turn: ExactText("2"),
            context: context, acceptanceObservedAtMilliseconds: acceptedAt + 60_000)
        XCTAssertEqual(try domain.conversationSnapshot(context: context)
            .threads[binding.request]?.facts[ExactText("2")]?.acceptedAtMilliseconds, acceptedAt,
            "A repeated acceptance readback must not reset the age of the unpicked message.")
        let restored = try await reopenWithServerCache(domain, context: context, persistence: persistence)
        XCTAssertEqual(try restored.conversationSnapshot(context: context)
            .threads[binding.request]?.facts[ExactText("2")]?.acceptedAtMilliseconds, acceptedAt)
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
    func testUnknownUploadReplyRestartsWithSameFrameWithoutUploadingAgain() async throws {
        let file = ConversationFile(id: ExactText("retained"), name: ExactText("large.bin"), byteCount: 300_000,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .localFile(ExactText("retained")))
        let (context, persistence, domain, binding, session, core) = try await setup(files: [file])
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        let operation = try XCTUnwrap(session.sent.first?.1)
        let firstFrame = try XCTUnwrap(session.sent.first?.0)
        let restored = try await reopenWithServerCache(domain, context: context, persistence: persistence)
        let restartedCore = try NativeRelayCore(store: restored, context: context, session: session)
        _ = try await restartedCore.resyncAndDrainOutbox()
        session.failUpload = true // Recovery must reuse the prior upload reference.
        try await restartedCore.resumePendingDiscussions { _ in
            throw CocoaError(.fileNoSuchFile) // The already prepared frame needs no disk read.
        }
        let retained = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
        XCTAssertEqual(retained.disposition, .outcomeUnknown(operation))
        XCTAssertEqual(retained.files, [file])
        XCTAssertEqual(retained.wireFrame, firstFrame)
        XCTAssertThrowsError(try restored.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Replacement")), context: context))
        XCTAssertEqual(session.uploadAttempts, 1)
        XCTAssertEqual(session.sent.count, 2)
        XCTAssertEqual(session.sent.last?.0, firstFrame)
        XCTAssertEqual(session.sent.last?.1, operation)
    }

    func testLocallyAcceptedDiscussionResumesAfterRestartButEditorDraftDoesNot() async throws {
        let (context, persistence, domain, binding, session, _) = try await setup()
        let operation = try domain.prepareDiscussion(binding, context: context)
        let restored = try await reopenWithServerCache(domain, context: context, persistence: persistence)
        let restartedCore = try NativeRelayCore(store: restored, context: context, session: session)
        _ = try await restartedCore.resyncAndDrainOutbox()
        try await restartedCore.resumePendingDiscussions { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertEqual(session.sent.map(\.1), [operation])
        XCTAssertEqual(try restored.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.disposition,
                       .outcomeUnknown(operation))

        let (_, _, _, _, editorSession, editorCore) = try await setup()
        try await editorCore.resumePendingDiscussions { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertTrue(editorSession.sent.isEmpty, "An editor draft without Send is not queued work.")
    }

    func testDefiniteDiscussionRefusalSurvivesRestartAndExplicitRetryKeepsIdentity() async throws {
        let (context, persistence, domain, binding, session, core) = try await setup()
        session.result = .rejected(reason: ExactText("temporarily refused"))
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        let first = try XCTUnwrap(session.sent.first)
        let restored = try await reopenWithServerCache(domain, context: context, persistence: persistence)
        let restartedCore = try NativeRelayCore(store: restored, context: context, session: session)
        _ = try await restartedCore.resyncAndDrainOutbox()
        try await restartedCore.resumePendingDiscussions { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertEqual(session.sent.count, 1, "A definitive refusal waits for explicit Retry.")
        let rejected = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
        XCTAssertEqual(rejected.operationID, first.1)
        XCTAssertEqual(rejected.disposition, .rejected(ExactText("temporarily refused")))
        session.result = .unresolved
        _ = try await restartedCore.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertEqual(session.sent.count, 2)
        XCTAssertEqual(session.sent.last?.0, first.0)
        XCTAssertEqual(session.sent.last?.1, first.1)
    }

    func testDepartureDuringUploadPreventsLateReadinessAndSendWithoutLosingText() async throws {
        let file = ConversationFile(id: ExactText("retained"), name: ExactText("large.bin"), byteCount: 300_000,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .localFile(ExactText("retained")))
        let (context, persistence, domain, binding, session, core) = try await setup(files: [file])
        session.uploadHook = {
            let cleanup = try domain.abandonConversationUploads(for: binding.request, context: context)
            XCTAssertEqual(cleanup.count, 1)
            async let navigation: Void = core.discardAbandonedUploads(for: binding.request)
            async let refresh: Void = core.discardAbandonedUploads(for: binding.request)
            _ = try await (navigation, refresh)
            XCTAssertTrue(session.cleanupRequests.isEmpty, "Discard waits for the upload flight to finish")
        }
        do { _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }; XCTFail("Departure must prevent send") }
        catch { XCTAssertEqual(error as? ConversationError, .pendingSubmission) }
        XCTAssertTrue(session.sent.isEmpty)
        try await core.discardAbandonedUploads(for: binding.request)
        XCTAssertEqual(session.cleanupRequests.count, 1)
        let restored = try await reopenWithServerCache(domain, context: context, persistence: persistence)
        let thread = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("Exact original text"))
        XCTAssertEqual(thread.drafts[1]?.files, [file], "Cleanup never removes original local files")
        XCTAssertTrue(thread.uploadGroups?.isEmpty ?? true)
        XCTAssertTrue(try restored.snapshot(context: context).intents.isEmpty)
        XCTAssertTrue(try restored.snapshot(context: context).outbox.isEmpty)
    }

    func testUnknownCleanupRetriesOnlyItsStableCommandWithoutResendingDiscussion() async throws {
        let file = ConversationFile(id: ExactText("retained"), name: ExactText("large.bin"), byteCount: 300_000,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .localFile(ExactText("retained")))
        let (context, persistence, domain, binding, session, core) = try await setup(files: [file])
        session.result = .rejected(reason: ExactText("Refused"))
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        let cleanup = try XCTUnwrap(domain.abandonConversationUploads(for: binding.request, context: context).first)
        session.failCleanup = true
        do { try await core.discardAbandonedUploads(for: binding.request); XCTFail("Unknown cleanup must remain unknown") } catch {}
        let restored = try await reopenWithServerCache(domain, context: context, persistence: persistence)
        guard case .unknown = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[binding.request]?.uploadCleanups?[cleanup.id]?.outcome) else {
            return XCTFail("Offline response cannot acknowledge deletion")
        }
        session.failCleanup = false
        try await core.discardAbandonedUploads(for: binding.request)
        XCTAssertEqual(session.cleanupRequests.map(\.id), [cleanup.id, cleanup.id])
        XCTAssertEqual(session.cleanupRequests.map(\.binding), [binding, binding])
        XCTAssertEqual(session.sent.count, 1, "Cleanup retries never resend the original discussion")
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.disposition, .saved)
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertEqual(session.sent.count, 2, "Cleanup cannot refuse an explicit new Send")
    }

    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    private func largeFile() -> ConversationFile {
        ConversationFile(id: ExactText("local"), name: ExactText("file.bin"), byteCount: 300_000,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .localFile(ExactText("local")))
    }

    private func pendingCleanup(_ domain: ClientRepository, context: ProfileContext,
                                binding: ConversationBinding, file: ConversationFile) throws {
        let old = try domain.prepareDiscussion(binding, context: context)
        try domain.registerConversationUpload(file, binding: binding, operation: old, context: context)
        try domain.markDiscussionOutcome(binding, operation: old, rejection: ExactText("Refused"), context: context)
        _ = try domain.abandonConversationUploads(for: binding.request, context: context)
        try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("New send"), files: [file]), context: context)
    }

    func testUploadSendQueuesImmediatelyAndWaitsOnlyForDiscardAlreadyInFlight() async throws {
        let file = largeFile()
        let (context, _, domain, binding, session, core) = try await setup(files: [file])
        try pendingCleanup(domain, context: context, binding: binding, file: file)
        let entered = Gate(), release = Gate(), limitsRead = Gate()
        session.cleanupHook = {
            await entered.release()
            await release.wait()
        }
        let cleanup = Task { try await core.discardAbandonedUploads(for: binding.request) }
        await entered.wait()
        let queued = try domain.prepareDiscussion(binding, context: context)
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.disposition,
                       .submitting(queued), "Send is accepted while housekeeping is outstanding")
        session.limitsHook = { await limitsRead.release() }
        session.uploadHook = { try await cleanup.value }
        session.result = .accepted(turnID: ExactText("2"))
        let send = Task { try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") } }
        await limitsRead.wait()
        XCTAssertEqual(session.uploadAttempts, 0)
        await release.release()
        _ = try await send.value
        try await cleanup.value
        XCTAssertEqual(session.uploadAttempts, 1)
        XCTAssertEqual(session.sent.count, 1)
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.files, [file])
    }

    func testPendingDiscardYieldsToNewUploadAndRunsAfterCommit() async throws {
        let file = largeFile()
        let (context, _, domain, binding, session, core) = try await setup(files: [file])
        try pendingCleanup(domain, context: context, binding: binding, file: file)
        let committed = Gate(), discarded = Gate()
        session.uploadHook = {
            try await core.discardAbandonedUploads(for: binding.request)
            XCTAssertTrue(session.cleanupRequests.isEmpty)
        }
        session.sendHook = { await committed.release() }
        session.cleanupHook = { await committed.wait(); await discarded.release() }
        session.result = .accepted(turnID: ExactText("2"))
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        let operation = try XCTUnwrap(session.sent.first?.1)
        try session.acceptedTurn(operation: operation, text: "New send", files: [.object([
            JSONMember("name", .string(file.name)), JSONMember("tier", .string(ExactText("upload"))),
            JSONMember("size", .number(JSONNumber(lexeme: String(file.byteCount)))),
            JSONMember("sha256", .string(file.sha256)), JSONMember("upload_id", .string(ExactText(session.uploadID)))
        ])])
        _ = try await core.resyncAndDrainOutbox()
        try await core.discardAbandonedUploads(for: binding.request)
        await discarded.wait()
        XCTAssertEqual(session.uploadAttempts, 1)
        XCTAssertEqual(session.sent.count, 1)
        let history = try domain.conversationSnapshot(context: context).threads[binding.request]?.turns.last
        XCTAssertEqual(history?.operationID, operation)
        XCTAssertEqual(history?.files.first?.content, .uploaded(ExactText(session.uploadID)))
    }

    func testInlineFrozenRetryThenEditAndDepartureRetainsFile() async throws {
        let file = ConversationFile(id: ExactText("small"), name: ExactText("small.txt"), byteCount: 1,
            sha256: ExactText("4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a"), content: .inline(Data([1])))
        let (context, _, domain, binding, session, core) = try await setup(files: [file])
        session.result = .rejected(reason: ExactText("Refused"))
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertEqual(session.sent[0].0, session.sent[1].0)
        XCTAssertEqual(session.sent[0].1, session.sent[1].1)
        XCTAssertTrue(try domain.conversationSnapshot(context: context).threads[binding.request]?.uploadGroups?.isEmpty ?? true)
        try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Edited"), files: [file]), context: context)
        XCTAssertTrue(try domain.abandonConversationUploads(for: binding.request, context: context).isEmpty)
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.files, [file])
    }

    func testFailureBeforeTierSelectionThenEditRetainsInlineFile() async throws {
        let small = ConversationFile(id: ExactText("small"), name: ExactText("small.txt"), byteCount: 1,
            sha256: ExactText("4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a"), content: .inline(Data([1])))
        let (context, _, domain, binding, session, core) = try await setup(files: [small, largeFile()])
        session.inlineBudget = 1
        session.cap = 1
        do { _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }; XCTFail("Published cap applies") }
        catch { XCTAssertNotNil(error as? ConversationError) }
        try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Edited"), files: [small]), context: context)
        XCTAssertTrue(try domain.abandonConversationUploads(for: binding.request, context: context).isEmpty)
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.files, [small])
    }

    func testDepartureDuringLimitsDiscoveryFencesUploadsAndRetainsFiles() async throws {
        let file = largeFile()
        let (context, _, domain, binding, session, core) = try await setup(files: [file])
        session.limitsHook = { _ = try domain.abandonConversationUploads(for: binding.request, context: context) }
        do { _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }; XCTFail("Departed preparation cannot upload") }
        catch { XCTAssertEqual(error as? ConversationError, .pendingSubmission) }
        XCTAssertEqual(session.uploadAttempts, 0)
        try await core.discardAbandonedUploads(for: binding.request)
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.files, [file])
    }

    func testFailedCleanupLeavesDraftEditableAndSendUsable() async throws {
        let file = largeFile()
        let (context, _, domain, binding, session, core) = try await setup(files: [file])
        try pendingCleanup(domain, context: context, binding: binding, file: file)
        session.failCleanup = true
        do { try await core.discardAbandonedUploads(for: binding.request); XCTFail("Offline") } catch {}
        try await MainActor.run {
            let model = try LivePresentationStore(store: domain, context: context)
            XCTAssertFalse(model.uploadNeedsReselection(file, for: binding.request, revision: 1))
            model.updateConversation(for: binding.request, revision: 1, files: [file])
            model.navigateMessage(from: binding.request, to: nil)
            model.navigateMessage(from: nil, to: binding.request)
            XCTAssertEqual(model.conversationDraft(for: binding.request, revision: 1).files, [file])
        }
        session.result = .rejected(reason: ExactText("Refused"))
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertEqual(session.uploadAttempts, 1)
        XCTAssertEqual(session.sent.count, 1)
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.files, [file])
    }

    func testLateDiscardCancellationIsDefiniteFailureAndExplicitRetryUploadsAgain() async throws {
        let file = largeFile()
        let (context, _, domain, binding, session, core) = try await setup(files: [file])
        session.uploadError = .server(status: 409, reason: ExactText("upload_discarded"))
        do { _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }; XCTFail("Cancelled upload") } catch {}
        let failed = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1])
        guard case .rejected = failed.disposition else { return XCTFail("A cancelled upload must offer Retry") }
        XCTAssertEqual(failed.files, [file])
        session.uploadError = nil
        session.result = .rejected(reason: ExactText("Refused"))
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertEqual(session.uploadAttempts, 2)
        XCTAssertEqual(session.sent.count, 1)
    }

    func testInlineSendDoesNotWaitForDiscardInFlight() async throws {
        let oldFile = largeFile()
        let (context, _, domain, binding, session, core) = try await setup(files: [oldFile])
        try pendingCleanup(domain, context: context, binding: binding, file: oldFile)
        let small = ConversationFile(id: ExactText("inline"), name: ExactText("inline.txt"), byteCount: 1,
            sha256: ExactText("4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a"), content: .inline(Data([1])))
        try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Inline"), files: [small]), context: context)
        let entered = Gate(), release = Gate()
        session.cleanupHook = { await entered.release(); await release.wait() }
        let cleanup = Task { try await core.discardAbandonedUploads(for: binding.request) }
        await entered.wait()
        session.result = .rejected(reason: ExactText("Refused"))
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertEqual(session.sent.count, 1)
        XCTAssertEqual(session.uploadAttempts, 0)
        await release.release()
        try await cleanup.value
        XCTAssertEqual(try domain.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.files, [small])
    }

    func testPublishedInlineBudgetChoosesUploadWithoutAnInventedThreshold() async throws {
        let file = ConversationFile(id: ExactText("one"), name: ExactText("one.txt"), byteCount: 1,
            sha256: ExactText("4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a"), content: .inline(Data([1])))
        let (_, _, _, binding, session, core) = try await setup(files: [file])
        session.inlineBudget = 0
        session.result = .rejected(reason: ExactText("Refused"))
        _ = try await core.submitDiscussion(binding) { _ in URL(fileURLWithPath: "/unused") }
        XCTAssertEqual(session.uploadAttempts, 1)
    }

}
