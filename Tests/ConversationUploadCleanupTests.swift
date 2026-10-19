import AttentionDomain
import HarklightNativeRelay
import XCTest
@testable import Harklight

final class ConversationUploadCleanupTests: XCTestCase {
    private func setup() throws -> (ProfileContext, MemoryAttentionStatePersistence, AttentionDomainStore, ConversationBinding) {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        try store.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key,
            originalPayload: .object([JSONMember("title", .string(ExactText("Keep this request")))])), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("handle"), eventID: ExactText("1"))), context: context)
        return (context, persistence, store, ConversationBinding(request: key, revision: 1))
    }
    private func file(_ name: String) -> ConversationFile {
        ConversationFile(id: ExactText(name), name: ExactText(name), byteCount: 300_000,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .localFile(ExactText(name)))
    }
    func testDepartureRetainsEveryUploadAttemptAndUnknownCleanupWithoutChangingTextOrCursors() throws {
        let (context, persistence, store, binding) = try setup()
        let first = file("first.bin"), second = file("second.bin")
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Keep exact text"), files: [first]), context: context)
        let operation1 = try store.prepareDiscussion(binding, context: context)
        try store.registerConversationUpload(first, binding: binding, operation: operation1, context: context)
        try store.markDiscussionOutcome(binding, operation: operation1, rejection: ExactText("Storage unavailable"), context: context)
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Keep exact text"), files: [second]), context: context)
        let operation2 = try store.prepareDiscussion(binding, context: context)
        try store.registerConversationUpload(second, binding: binding, operation: operation2, context: context)
        try store.markDiscussionOutcome(binding, operation: operation2, rejection: nil, context: context)
        // Rebuild/restoration and transport uncertainty alone do not request cleanup.
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        XCTAssertTrue(try restored.conversationSnapshot(context: context).threads[binding.request]?.uploadCleanups?.isEmpty ?? true)
        let cleanup = try XCTUnwrap(restored.abandonConversationUploads(for: binding.request, context: context).first)
        XCTAssertEqual(Set(cleanup.uploadOperations), Set([operation1, operation2]))
        XCTAssertNotEqual(cleanup.id, operation1)
        XCTAssertNotEqual(cleanup.id, operation2)
        try restored.recordConversationCleanup(cleanup.id, request: binding.request,
            outcome: .unknown(ExactText("Offline")), context: context)
        let retryStore = try AttentionDomainStore(context: context, persistence: persistence)
        let retry = try XCTUnwrap(retryStore.abandonConversationUploads(for: binding.request, context: context).first)
        XCTAssertEqual(retry.id, cleanup.id)
        XCTAssertEqual(retry.binding, binding)
        XCTAssertEqual(retry.outcome, .unknown(ExactText("Offline")))
        XCTAssertThrowsError(try retryStore.prepareDiscussion(binding, context: context))
        let thread = try XCTUnwrap(retryStore.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("Keep exact text"))
        XCTAssertEqual(thread.drafts[1]?.disposition, .outcomeUnknown(operation2))
        XCTAssertEqual(try retryStore.snapshot(context: context).cursor, 1)
        XCTAssertEqual(try retryStore.conversationSnapshot(context: context).cursor, 0)
        XCTAssertTrue(try retryStore.snapshot(context: context).outbox.isEmpty)
    }
    func testAcknowledgedRequestScopeCleanupRequiresReselectionAndUsesExactOriginWire() throws {
        let (context, persistence, store, binding) = try setup()
        let original = file("reselect.bin")
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Text remains"), files: [original]), context: context)
        let operation = try store.prepareDiscussion(binding, context: context)
        try store.registerConversationUpload(original, binding: binding, operation: operation, context: context)
        try store.markDiscussionOutcome(binding, operation: operation, rejection: ExactText("Not submitted"), context: context)
        let cleanup = try XCTUnwrap(store.abandonConversationUploads(for: binding.request, context: context).first)
        let wire = try ConversationFileWire(profile: context, originURL: URL(string: "https://relay.example:9443/origin/v1")!)
        let request = try wire.discardRequest(cleanup)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/origin/v1")
        let body = try JSONValue.parse(XCTUnwrap(request.httpBody))
        XCTAssertEqual(body.uniqueValue(named: "type"), .string(ExactText("discard_uploads")))
        XCTAssertEqual(body.uniqueValue(named: "revision")?.integerValue, 1)
        XCTAssertNil(body.uniqueValue(named: "request_revision"))
        XCTAssertEqual(body.uniqueValue(named: "op_id"), .string(ExactText(cleanup.id.uuidString.lowercased())))
        let mixed = try wire.decodeDiscard(Data(#"{"v":1,"type":"ok","state":"committed","discarded":1}"#.utf8), status: 200)
        XCTAssertEqual(mixed, ConversationUploadDiscardResult(state: .committed, discarded: 1))
        let zero = try wire.decodeDiscard(Data(#"{"v":1,"type":"ok","state":"discarded","discarded":0}"#.utf8), status: 200)
        XCTAssertEqual(zero.discarded, 0)
        try store.recordConversationCleanup(cleanup.id, request: binding.request, outcome: .acknowledged(zero), context: context)
        try store.recordConversationCleanup(cleanup.id, request: binding.request, outcome: .unknown(ExactText("Late failure")), context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let thread = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(thread.uploadCleanups?[cleanup.id]?.outcome, .acknowledged(zero))
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("Text remains"))
        XCTAssertTrue(thread.drafts[1]?.files.isEmpty == true)
        XCTAssertTrue(try restored.abandonConversationUploads(for: binding.request, context: context).isEmpty)
        XCTAssertThrowsError(try wire.decodeDiscard(Data(#"{"v":1,"type":"ok","discarded":0}"#.utf8), status: 200))
    }
    @MainActor
    func testActualMessageDepartureDiffersFromSelectionRebuildAndKeepsOfflineCleanupRecoverable() async throws {
        let (context, persistence, domain, binding) = try setup()
        let original = file("unsubmitted.bin")
        try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Keep exact draft"), files: [original]), context: context)
        let operation = try domain.prepareDiscussion(binding, context: context)
        try domain.markDiscussionOutcome(binding, operation: operation, rejection: ExactText("Not sent"), context: context)
        let model = try LivePresentationStore(store: domain, context: context)
        model.selectRequest(binding.request)
        model.selectRequest(binding.request)
        try model.refreshFromDurableStore()
        model.navigateMessage(from: binding.request, to: binding.request)
        XCTAssertTrue(try domain.conversationSnapshot(context: context).threads[binding.request]?.uploadCleanups?.isEmpty ?? true)
        model.navigateMessage(from: binding.request, to: nil)
        XCTAssertTrue(model.hasPendingUploadCleanup(for: binding.request, revision: 1))
        XCTAssertTrue(model.uploadNeedsReselection(original, for: binding.request, revision: 1))
        let cleanup = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[binding.request]?.uploadCleanups?.values.first)
        await model.retryUploadCleanup(for: binding.request) // Unconfigured disposable profile: no service can be contacted.
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let pending = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[binding.request]?.uploadCleanups?[cleanup.id])
        guard case .unknown = pending.outcome else { return XCTFail("Offline cleanup must not become confirmed") }
        XCTAssertEqual(pending.uploadOperations, [operation])
        XCTAssertEqual(try restored.conversationSnapshot(context: context).threads[binding.request]?.drafts[1]?.text, ExactText("Keep exact draft"))
        XCTAssertTrue(try restored.snapshot(context: context).outbox.isEmpty)
    }

    @MainActor
    func testMixedCleanupKeepsUnidentifiedReferencesAndHistoryUntilReplayOrExplicitReselection() throws {
        let (context, persistence, store, binding) = try setup()
        let original = file("unidentified.bin")
        let committedFile = ConversationFile(id: ExactText("history-file"), name: ExactText("previous.bin"), byteCount: 300_000,
            sha256: original.sha256, content: .uploaded(ExactText(UUID().uuidString.lowercased())))
        let history = ConversationTurn(id: ExactText("2"), binding: binding, author: .person,
            sessionHandle: ExactText("handle"), text: ExactText("Already accepted"), files: [committedFile])
        try store.applyConversation(ConversationEvent(sequence: 1, binding: binding, fact: .turn(history)), context: context)
        let retainedHistory = try XCTUnwrap(store.conversationSnapshot(context: context).threads[binding.request]?.turns)
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Keep original note"), files: [original]), context: context)
        let operation = try store.prepareDiscussion(binding, context: context)
        try store.markDiscussionOutcome(binding, operation: operation, rejection: ExactText("Not submitted"), context: context)
        let cleanup = try XCTUnwrap(store.abandonConversationUploads(for: binding.request, context: context).first)
        let mixed = ConversationUploadDiscardResult(state: .committed, discarded: 1)
        try store.recordConversationCleanup(cleanup.id, request: binding.request, outcome: .acknowledged(mixed), context: context)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let thread = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[binding.request])
        XCTAssertEqual(thread.drafts[1]?.files, [original], "A count cannot identify which draft file was discarded or committed")
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("Keep original note"))
        XCTAssertEqual(thread.turns, retainedHistory, "Keep only actually replayed committed content; do not fabricate a history entry")
        XCTAssertEqual(thread.uploadCleanups?[cleanup.id]?.outcome, .acknowledged(mixed))
        XCTAssertThrowsError(try restored.prepareDiscussion(binding, context: context), "Unidentified old references cannot resend")
        let model = try LivePresentationStore(store: restored, context: context)
        XCTAssertTrue(model.hasUnreadyUploadReference(for: binding.request, revision: 1))
        XCTAssertTrue(model.uploadHistoryNeedsReconciliation(for: binding.request, revision: 1))
        let selected = ConversationFile(id: ExactText(UUID().uuidString), name: original.name,
            byteCount: original.byteCount, sha256: original.sha256, content: original.content)
        model.updateConversation(for: binding.request, revision: 1, files: [selected])
        XCTAssertFalse(model.hasUnreadyUploadReference(for: binding.request, revision: 1))
        XCTAssertNotEqual(try restored.prepareDiscussion(binding, context: context), operation, "Explicit reselection prepares a new upload operation, never the abandoned one")
        XCTAssertEqual(try restored.conversationSnapshot(context: context).threads[binding.request]?.turns, retainedHistory)
    }

}
