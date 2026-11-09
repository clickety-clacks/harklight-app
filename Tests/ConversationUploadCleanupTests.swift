import AttentionDomain
import HarklightNativeRelay
import XCTest
@testable import Harklight

@MainActor
final class ConversationUploadContractTests: XCTestCase {
    private final class Session: AuthenticatedConversationCleanupSession, @unchecked Sendable {
        let authenticatedIdentity: ProfileIdentity
        let uploadID = UUID().uuidString.lowercased()
        var uploadedOperations: [UUID] = []
        var discardRequests: [ConversationUploadCleanup] = []
        var transmissions: [(Data, UUID)] = []
        var transmissionOrder: [String] = []
        var durableDraftBeforeTransmission: (@Sendable () async -> ConversationDraft?)?
        var transmittedDrafts: [ConversationDraft?] = []

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
            data("{\"v\":1,\"type\":\"ok\",\"ref\":\"\(ref)\"}")
        }

        func acknowledge(_ request: Data) async throws {}

        func openConversation(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
            let since = try JSONValue.parse(request).uniqueValue(named: "since")?.integerValue ?? 0
            try await consume(data(#"{"v":1,"type":"ok","ref":"native-conversation-sync","origin_https_port":9443}"#))
            try await consume(data("{\"v\":1,\"type\":\"conversation_resynced\",\"conversation_seq\":\(since)}"))
        }

        func acknowledgeConversation(_ request: Data) async throws {}

        func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
            .unresolved
        }

        func conversationFileLimits(originURL: URL) async throws -> ConversationFileLimits {
            ConversationFileLimits(inlineDecodedBytes: 262_144, uploadCap: nil)
        }

        func uploadConversationFile(_ file: ConversationFile, from source: URL, binding: ConversationBinding,
                                    operationID: UUID, limits: ConversationFileLimits,
                                    originURL: URL) async throws -> ConversationFile {
            uploadedOperations.append(operationID)
            transmissionOrder.append("upload")
            return ConversationFile(id: file.id, name: file.name, byteCount: file.byteCount,
                                    sha256: file.sha256, content: .uploaded(ExactText(uploadID)))
        }

        func discardConversationUploads(_ cleanup: ConversationUploadCleanup,
                                        originURL: URL) async throws -> ConversationUploadDiscardResult {
            discardRequests.append(cleanup)
            return ConversationUploadDiscardResult(state: .discarded,
                discarded: UInt64(cleanup.uploadOperations.count))
        }

        func sendDiscussion(_ frame: Data, operationID: UUID) async -> DiscussionOperationResult {
            transmittedDrafts.append(await durableDraftBeforeTransmission?())
            transmissions.append((frame, operationID))
            transmissionOrder.append("send")
            return .unresolved
        }
    }

    private func setup() async throws -> (ProfileContext, MemoryAttentionStatePersistence,
                                          AttentionDomainStore, ConversationBinding, Session, NativeRelayCore) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let binding = ConversationBinding(request: RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request")), revision: 1)
        let session = Session(context.identity)
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("handle"), payload: .object([
                JSONMember("title", .string(ExactText("Question")))
            ]))), context: context)
        return (context, persistence, store, binding, session, core)
    }

    func testUploadIsDurableBeforeSendAndSameDraftRetryReusesItWithoutCleanup() async throws {
        let (context, persistence, store, binding, session, core) = try await setup()
        let localFile = ConversationFile(id: ExactText("file"), name: ExactText("large.bin"),
            byteCount: 300_000, sha256: ExactText(String(repeating: "a", count: 64)),
            content: .localFile(ExactText("retained")))
        try await store.saveConversationDraft(ConversationDraft(binding: binding,
            text: ExactText("The attachment is relevant."), files: [localFile]), context: context)

        session.durableDraftBeforeTransmission = {
            guard let reloaded = try? AttentionDomainStore(context: context, persistence: persistence),
                  let snapshot = try? await reloaded.conversationSnapshot(context: context) else { return nil }
            return snapshot.threads[binding.request]?.drafts[binding.revision]
        }
        let retainedFile: @Sendable (ConversationFile) async throws -> URL = { _ in
            URL(fileURLWithPath: "/unused/large.bin")
        }
        let persistDraft: @Sendable (ConversationDraft?) async throws -> Void = { _ in }

        _ = try await core.submitDiscussion(binding, retainedFile: retainedFile, persistDraft: persistDraft)
        _ = try await core.submitDiscussion(binding, retainedFile: retainedFile, persistDraft: persistDraft)

        XCTAssertEqual(session.uploadedOperations.count, 1,
                       "A retry of the same draft reuses its uploaded attachment id.")
        XCTAssertEqual(session.transmissionOrder, ["upload", "send", "send"],
                       "Each explicit send follows the upload; the retry does not upload again.")
        XCTAssertEqual(session.transmissions.count, 2)
        let firstTransmission = try XCTUnwrap(session.transmissions.first)
        let retryTransmission = try XCTUnwrap(session.transmissions.last)
        XCTAssertEqual(firstTransmission.1, retryTransmission.1,
                       "An unresolved retry keeps the same operation id.")
        XCTAssertEqual(session.uploadedOperations.first, firstTransmission.1,
                       "The attachment upload is bound to the operation that sends it.")
        XCTAssertEqual(firstTransmission.0, retryTransmission.0,
                       "The retry carries the same frozen text and uploaded attachment id.")

        let durableDrafts = session.transmittedDrafts.compactMap { $0 }
        XCTAssertEqual(durableDrafts.count, 2)
        let expectedUploadedFile = ConversationFile(id: localFile.id, name: localFile.name,
            byteCount: localFile.byteCount, sha256: localFile.sha256,
            content: .uploaded(ExactText(session.uploadID)))
        XCTAssertEqual(durableDrafts.map(\.files), [[expectedUploadedFile], [expectedUploadedFile]],
                       "A newly loaded store must see the uploaded id before either send reaches the transport.")

        let frame = try JSONValue.parse(firstTransmission.0)
        let transmittedFile = try XCTUnwrap(frame.uniqueValue(named: "files")?.arrayValues?.first)
        XCTAssertEqual(transmittedFile.uniqueValue(named: "upload_id"),
                       .string(ExactText(session.uploadID)))
        let finalSnapshot = try await store.conversationSnapshot(context: context)
        let currentDraft = try XCTUnwrap(finalSnapshot.threads[binding.request]?.drafts[binding.revision])
        XCTAssertEqual(currentDraft.text, ExactText("The attachment is relevant."))
        XCTAssertEqual(currentDraft.files, [expectedUploadedFile])
        XCTAssertTrue(finalSnapshot.threads[binding.request]?.uploadCleanups?.isEmpty ?? true,
                      "A manual retry neither creates nor persists cleanup work.")
        XCTAssertTrue(session.discardRequests.isEmpty,
                      "A manual retry never invokes uploaded-file discard transport.")

        let attention = try await store.snapshot(context: context)
        XCTAssertTrue(attention.intents.isEmpty)
        XCTAssertTrue(attention.outbox.isEmpty,
                      "An explicit chat retry does not create an automatic delivery queue.")
    }
}
