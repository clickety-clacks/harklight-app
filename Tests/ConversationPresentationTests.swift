import AttentionDomain
import CryptoKit
import Foundation
import XCTest
@testable import Harklight

@MainActor
final class ConversationPresentationTests: XCTestCase {
    func testInlineTurnAndDraftBytesStayBehindReferencesAcrossTextOnlyComposerWrites() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = FileAttentionStatePersistence(directoryURL: root.appendingPathComponent("State", isDirectory: true))
        let storage = try ConversationFileStorage(identity: identity, root: root.appendingPathComponent("Files", isDirectory: true))
        let domain = try AttentionDomainStore(context: context, persistence: persistence,
            conversationFileReferences: storage)
        let request = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: request, revision: 1)
        let bytes = Data(repeating: 0xA7, count: 200_000)
        let digest = ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let inline = ConversationFile(id: ExactText("attachment"), name: ExactText("large-note.bin"),
            byteCount: UInt64(bytes.count), sha256: digest, content: .inline(bytes))
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null)), context: context)
        try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Before edit"), files: [inline]),
            context: context)
        let turn = ConversationTurn(id: ExactText("turn-2"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Shared exact bytes"), files: [inline])
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(turn)), context: context)

        let saved = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[request]?.drafts[1])
        let savedFile = try XCTUnwrap(saved.files.first)
        guard case .localFile = savedFile.content else { return XCTFail("Inline bytes must become an account-owned file reference.") }
        let model = try LivePresentationStore(store: domain, context: context)
        model.updateConversation(for: request, revision: 1, text: "After composer edit")
        XCTAssertNil(model.conversationError)
        let firstEdit = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[request]?.drafts[1])
        XCTAssertEqual(firstEdit.files, saved.files, "A text-only edit preserves the original file identity and reference.")
        model.updateConversation(for: request, revision: 1, text: "After the next keystroke")
        XCTAssertNil(model.conversationError)
        let secondEdit = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[request]?.drafts[1])
        XCTAssertEqual(secondEdit.files, saved.files, "Later text edits keep the same normalized file references.")

        let persisted = try XCTUnwrap(persistence.load(identity: identity))
        XCTAssertLessThan(persisted.count, bytes.count / 2, "Whole-state persistence must contain references, not copied inline payloads.")
        XCTAssertNil(persisted.range(of: bytes), "Composer keystrokes must not rewrite attachment bytes into account state.")
        let storedURL = try storage.fileURL(for: savedFile)
        try storage.verify(storedURL, for: savedFile)
        XCTAssertEqual(try Data(contentsOf: storedURL), bytes)

        let restored = try AttentionDomainStore(context: context, persistence: persistence,
            conversationFileReferences: storage)
        let thread = try XCTUnwrap(restored.conversationSnapshot(context: context).threads[request])
        XCTAssertEqual(thread.currentRevision, 1)
        XCTAssertEqual(thread.turns.first?.id, turn.id)
        XCTAssertEqual(thread.turns.first?.binding, binding)
        XCTAssertEqual(thread.turns.first?.files.first?.id, inline.id)
        XCTAssertEqual(thread.turns.first?.files.first?.content, savedFile.content)
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("After the next keystroke"))
        XCTAssertEqual(thread.drafts[1]?.files.first?.content, savedFile.content)
        try restored.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(turn)), context: context)
        XCTAssertEqual(try restored.conversationSnapshot(context: context).cursor, 2,
            "A duplicate inline replay normalizes to the same retained reference instead of conflicting.")
    }

    func testLegacyInlineRecoveryAfterFailedTextWriteKeepsRetryAndDuplicateReplayNormalized() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("legacy-inline"))
        let binding = ConversationBinding(request: request, revision: 1)
        let bytes = Data(repeating: 0xB4, count: 200_000)
        let digest = ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let inline = ConversationFile(id: ExactText("legacy-attachment"), name: ExactText("legacy-note.bin"),
            byteCount: UInt64(bytes.count), sha256: digest, content: .inline(bytes))
        let requestEvent = ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: .null))
        let turn = ConversationTurn(id: ExactText("legacy-turn"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Retained exact bytes"), files: [inline])
        let turnEvent = ConversationEvent(sequence: 2, binding: binding, fact: .turn(turn))

        // Build a pre-externalization state with the memory persistence's
        // explicitly permitted inline representation, then seed those exact
        // encoded bytes as an older on-disk account state.
        let legacyPersistence = MemoryAttentionStatePersistence()
        let legacyStore = try AttentionDomainStore(context: context, persistence: legacyPersistence)
        try legacyStore.applyConversation(requestEvent, context: context)
        try legacyStore.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Before retry"), files: [inline]),
            context: context)
        try legacyStore.applyConversation(turnEvent, context: context)
        let legacyBytes = try XCTUnwrap(legacyPersistence.load(identity: identity))
        XCTAssertNotNil(legacyBytes.range(of: bytes), "The fixture must contain legacy inline payload bytes.")

        let backing = FileAttentionStatePersistence(directoryURL: root.appendingPathComponent("State", isDirectory: true))
        try backing.commit(legacyBytes, identity: identity)
        let failingPersistence = FailOnceAttentionStatePersistence(backing: backing)
        let storage = try ConversationFileStorage(identity: identity, root: root.appendingPathComponent("Files", isDirectory: true))
        let store = try AttentionDomainStore(context: context, persistence: failingPersistence,
            conversationFileReferences: storage)

        let initiallyNormalized = try XCTUnwrap(store.conversationSnapshot(context: context).threads[request])
        let retainedTurnFile = try XCTUnwrap(initiallyNormalized.turns.first?.files.first)
        let retainedDraftFile = try XCTUnwrap(initiallyNormalized.drafts[1]?.files.first)
        guard case .localFile = retainedTurnFile.content, case .localFile = retainedDraftFile.content else {
            return XCTFail("Loading a legacy inline state must externalize its conversation files.")
        }
        XCTAssertEqual(retainedTurnFile.id, inline.id)
        XCTAssertEqual(retainedDraftFile.id, inline.id)

        failingPersistence.failNextCommit()
        XCTAssertThrowsError(try store.updateConversationDraftText(ExactText("Failed attempt"), for: binding, context: context)) { error in
            guard let storeError = error as? AttentionStoreError, case .persistence = storeError else {
                return XCTFail("Expected the injected durable-write failure; received \(error).")
            }
        }
        let recovered = try XCTUnwrap(store.conversationSnapshot(context: context).threads[request])
        XCTAssertEqual(recovered.drafts[1]?.text, ExactText("Before retry"), "The failed edit is not reported as saved.")
        XCTAssertEqual(recovered.turns.first?.files.first, retainedTurnFile)
        XCTAssertEqual(recovered.drafts[1]?.files.first, retainedDraftFile)
        let unchangedDiskBytes = try XCTUnwrap(failingPersistence.load(identity: identity))
        XCTAssertNotNil(unchangedDiskBytes.range(of: bytes), "A pre-replacement failure leaves the older plist intact.")

        let retried = try store.updateConversationDraftText(ExactText("Saved retry"), for: binding, context: context)
        XCTAssertEqual(retried.text, ExactText("Saved retry"))
        XCTAssertEqual(retried.binding, binding)
        XCTAssertEqual(retried.files, [retainedDraftFile])
        let retriedDiskBytes = try XCTUnwrap(failingPersistence.load(identity: identity))
        XCTAssertNil(retriedDiskBytes.range(of: bytes), "The successful retry persists references instead of legacy payload bytes.")
        let retainedURL = try storage.fileURL(for: retainedTurnFile)
        try storage.verify(retainedURL, for: retainedTurnFile)
        XCTAssertEqual(try Data(contentsOf: retainedURL), bytes)

        let cursorBeforeDuplicate = try store.conversationSnapshot(context: context).cursor
        try store.applyConversation(turnEvent, context: context)
        let afterDuplicate = try XCTUnwrap(store.conversationSnapshot(context: context).threads[request])
        XCTAssertEqual(try store.conversationSnapshot(context: context).cursor, cursorBeforeDuplicate)
        XCTAssertEqual(afterDuplicate.turns.count, 1, "The original turn remains a single idempotently replayed fact.")
        XCTAssertEqual(afterDuplicate.turns.first?.id, turn.id)
        XCTAssertEqual(afterDuplicate.turns.first?.binding, binding)
        XCTAssertEqual(afterDuplicate.turns.first?.files.first, retainedTurnFile)
        let finalDiskBytes = try XCTUnwrap(failingPersistence.load(identity: identity))
        XCTAssertNil(finalDiskBytes.range(of: bytes), "Duplicate replay leaves the normalized persisted state unchanged.")
    }

    func testQuestionRevisionKeepsAnOldSelectorBoundToTheVersionThePersonSaw() throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("fictional-relay"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        let first = try JSONValue.parse(Data(#"{"title":"First wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Old choice","kind":"text"}]}}"#.utf8))
        let second = try JSONValue.parse(Data(#"{"title":"Revised wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"new","label":"New choice","kind":"text"}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: first), .message)), context: context)
        let b1 = ConversationBinding(request: key, revision: 1)
        let b2 = ConversationBinding(request: key, revision: 2)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: b1,
            fact: .request(sessionHandle: ExactText("origin"), payload: first)), context: context)
        let port = AttentionDomainPort(store: domain)
        let oldSelector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let old = try port.submit(SubmitIntent(context: port.context, selector: oldSelector, intentID: UUID(),
            inputs: [.compatibilityValue(action: ExactText("old"))]))
        XCTAssertEqual(try domain.lookupIntent(old.intentID, context: context)?.requestRevision, 1)
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: b2,
            fact: .request(sessionHandle: ExactText("origin"), payload: second)), context: context)
        let revised = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first)
        XCTAssertEqual(revised.title, ExactText("Revised wording"))
        XCTAssertNil(revised.intentReceipt, "The earlier answer must not become the new version's receipt")
        XCTAssertNil(revised.draft.compatibility.selectedActionID)
        let stale = try port.submit(SubmitIntent(context: port.context, selector: oldSelector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("old"))]))
        let staleSubmission = try XCTUnwrap(domain.lookupIntent(stale.intentID, context: context))
        XCTAssertEqual(staleSubmission.requestRevision, 1)
        XCTAssertEqual(staleSubmission.operation.uniqueValue(named: "request_revision")?.integerValue, 1)
        try domain.recordAnswerStaleRevision(stale.intentID, operationID: stale.opID,
            currentRevision: 2, context: context)
        let currentAfterDecline = try XCTUnwrap(port.observe(context: port.context).requests.first)
        XCTAssertEqual(currentAfterDecline.title, ExactText("Revised wording"))
        XCTAssertEqual(currentAfterDecline.staleAnswerRevision?.submittedRevision, 1)
        XCTAssertEqual(currentAfterDecline.staleAnswerRevision?.currentRevision, 2)
        let viewedAgain = try XCTUnwrap(port.inspect(context: port.context, request: key, revision: 1).requests.first)
        XCTAssertEqual(viewedAgain.draft.compatibility.selectedActionID, ExactText("old"))
        let liveAfterDecline = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(liveAfterDecline.staleAnswerDialog?.currentRevision, 2)
        XCTAssertTrue(liveAfterDecline.staleAnswerDialog?.message.contains("Revised wording") == true)
        liveAfterDecline.dismissStaleAnswerDialog()
        try liveAfterDecline.refreshFromDurableStore()
        XCTAssertNil(liveAfterDecline.staleAnswerDialog, "A dismissed stale-answer notice does not repeat in this session.")
        let thread = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[key])
        XCTAssertEqual(thread.answerDrafts?[1]?.compatibility.selectedActionID, ExactText("old"))
        XCTAssertEqual(thread.revisions[1], first)
        let historical = try XCTUnwrap(port.inspectAnswerDraft(context: port.context, request: key, revision: 1))
        XCTAssertEqual(historical.title, ExactText("First wording"))
        XCTAssertEqual(historical.draft.compatibility.selectedActionID, ExactText("old"))
        XCTAssertNil(historical.selector, "Historical drafts cannot acquire a current answer selector")
        XCTAssertTrue(try domain.snapshot(context: context).outbox.isEmpty)
        let retained = try XCTUnwrap(domain.lookupIntent(old.intentID, context: context))
        XCTAssertEqual(retained.disposition, .lost)
        XCTAssertEqual(retained.answer, .string(ExactText("old")))
        let newSelector = try XCTUnwrap(revised.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: newSelector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("new"))]))
        let current = try XCTUnwrap(domain.lookupIntent(receipt.intentID, context: context))
        XCTAssertEqual(current.requestRevision, 2)
        XCTAssertEqual(current.operation.uniqueValue(named: "request_revision")?.integerValue, 2)
        XCTAssertEqual(try domain.snapshot(context: context).intents.count, 2, "Both original facts remain inspectable")
    }

    func testPendingDraftBuffersStayBoundToTheirRequestRevision() throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("fictional-relay"),
            personID: ExactText("draft-revision-person"), deviceID: ExactText("device")), transportMode: .relay)
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("draft-revision"))
        let first = try JSONValue.parse(Data(#"{"title":"First wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Old choice","kind":"value","value":"old"}]}}"#.utf8))
        let second = try JSONValue.parse(Data(#"{"title":"Revised wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"new","label":"New choice","kind":"value","value":"new"}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: first), .message)), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("origin"), payload: first)), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 2,
            binding: ConversationBinding(request: key, revision: 2),
            fact: .request(sessionHandle: ExactText("origin"), payload: second)), context: context)

        let live = try LivePresentationStore(store: domain, context: context)
        let port = AttentionDomainPort(store: domain)
        live.selectAction(ExactText("old"), input: nil, for: key, requestRevision: 1)
        live.stageCompatibilityText("Old-version draft", action: ExactText("old"),
                                    for: key, requestRevision: 1)

        let historical = try XCTUnwrap(port.inspect(context: port.context, request: key, revision: 1).requests.first)
        let current = try XCTUnwrap(port.inspect(context: port.context, request: key, revision: 2).requests.first)
        XCTAssertEqual(historical.draft.compatibility.selectedActionID, ExactText("old"))
        XCTAssertNil(current.draft.compatibility.selectedActionID,
                     "Editing the version on screen must not apply its answer to the newer version.")
        XCTAssertEqual(live.draft(for: key, revision: 1)?.compatibility.textByActionID[ExactText("old")],
                       ExactText("Old-version draft"))
        XCTAssertNil(live.draft(for: key, revision: 2)?.compatibility.textByActionID[ExactText("new")])

        let receipt = try live.submit(key, requestRevision: 1)
        XCTAssertEqual(receipt.selector.requestRevision, 1)
        XCTAssertEqual(receipt.exactAnswerJSON, #""Old-version draft"#)
        XCTAssertEqual(try domain.snapshot(context: context).outbox.first?.requestRevision, 1)
    }

    func testShakeConversationUsesTheDomainAndOrdinaryViewModelAndCannotPrepareDelivery() throws {
        let library = SampleLibrary()
        library.populate()
        let fixture = try XCTUnwrap(library.fixture)
        let response = try XCTUnwrap(library.responses["sample-information-0"])
        let before = try XCTUnwrap(fixture.viewModel.conversation(for: response.key))
        response.chatDraft = "Inspect the exact local model"
        response.attachments = ["Local example"]
        response.sendLocalChat()
        let restored = try LivePresentationStore(localFixtureStore: fixture.domain, context: fixture.context)
        let thread = try XCTUnwrap(restored.conversation(for: response.key))
        XCTAssertEqual(thread.turns.count, before.turns.count + 1)
        let last = try XCTUnwrap(thread.turns.last)
        XCTAssertEqual(last.text, ExactText("Inspect the exact local model"))
        XCTAssertEqual(last.binding.request, response.key)
        XCTAssertEqual(last.files.first?.name, ExactText("Local example"))
        XCTAssertNil(last.operationID)
        XCTAssertEqual(thread.facts[last.id]?.delivered, false)
        XCTAssertNil(thread.facts[last.id]?.actedBy)
        XCTAssertTrue(try fixture.domain.snapshot(context: fixture.context).intents.isEmpty)
        XCTAssertTrue(try fixture.domain.snapshot(context: fixture.context).outbox.isEmpty)
        let state = try fixture.domain.conversationSnapshot(context: fixture.context)
        library.populate()
        XCTAssertEqual(try fixture.domain.conversationSnapshot(context: fixture.context).cursor, state.cursor)
        XCTAssertEqual(fixture.viewModel.conversation(for: response.key)?.turns, thread.turns)
    }

    func testRetainedFileUsesOriginalBytesAfterPickerSourceDisappearsAndRejectsAnIncompleteCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay"), personID: ExactText("person"), deviceID: ExactText("device"))
        let storage = try ConversationFileStorage(identity: identity, root: root)
        let source = root.appendingPathComponent("larger-than-inline.bin")
        let bytes = Data(repeating: 231, count: 3 * 1_048_576 + 17)
        try bytes.write(to: source)
        let file = try storage.retain(source)
        try FileManager.default.removeItem(at: source)
        let copy = try storage.fileURL(for: file)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(file.byteCount, UInt64(bytes.count))
        try storage.verify(copy, for: file)
        try Data(bytes.prefix(1024)).write(to: copy)
        XCTAssertThrowsError(try storage.verify(copy, for: file))
        let other = try ConversationFileStorage(identity: ProfileIdentity(trustedRelayAuthority: identity.trustedRelayAuthority,
            personID: ExactText("other-person"), deviceID: identity.deviceID), root: root)
        XCTAssertNotEqual(other.directory, storage.directory)
    }
    func testInlinePreviewRetainsExactBytesAndAccountRemovalLeavesAnotherAccountUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstIdentity = ProfileIdentity(trustedRelayAuthority: ExactText("relay"), personID: ExactText("first"), deviceID: ExactText("device"))
        let secondIdentity = ProfileIdentity(trustedRelayAuthority: ExactText("relay"), personID: ExactText("second"), deviceID: ExactText("device"))
        let first = try ConversationFileStorage(identity: firstIdentity, root: root)
        let second = try ConversationFileStorage(identity: secondIdentity, root: root)
        let bytes = Data("Exact original file text\n".utf8)
        let digest = ExactText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let file = ConversationFile(id: ExactText("note"), name: ExactText("note.txt"), byteCount: UInt64(bytes.count), sha256: digest, content: .inline(bytes))
        let firstURL = try XCTUnwrap(first.cachedPreview(for: file))
        let secondURL = try XCTUnwrap(second.cachedPreview(for: file))
        XCTAssertEqual(firstURL.lastPathComponent, "note.txt")
        XCTAssertEqual(try Data(contentsOf: firstURL), bytes)
        XCTAssertEqual(try first.cachedPreview(for: file), firstURL)
        try first.removeAccountFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(try Data(contentsOf: secondURL), bytes)
    }

    func testRetainedCopiesKeepTheirBasenameAndOlderCopyReferencesRemainReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay"), personID: ExactText("person"), deviceID: ExactText("device"))
        let storage = try ConversationFileStorage(identity: identity, root: root)
        let source = root.appendingPathComponent("original.txt")
        let bytes = Data("Original picker bytes".utf8)
        try bytes.write(to: source)
        let retained = try storage.retain(source)
        let retainedURL = try XCTUnwrap(storage.cachedPreview(for: retained))
        XCTAssertEqual(retainedURL.lastPathComponent, "original.txt")
        let olderURL = storage.directory.appendingPathComponent("older-copy")
        try bytes.write(to: olderURL)
        let older = ConversationFile(id: ExactText("older"), name: ExactText("original.txt"), byteCount: retained.byteCount,
            sha256: retained.sha256, content: .localFile(ExactText("older-copy")))
        XCTAssertEqual(try storage.cachedPreview(for: older), olderURL)
        XCTAssertEqual(try Data(contentsOf: olderURL), bytes)
    }

    func testShakeExamplesIncludeRevisionArchiveDistinctFileFactsAndClosureWithoutOperations() throws {
        let library = SampleLibrary()
        library.populate()
        let fixture = try XCTUnwrap(library.fixture)
        let revised = try XCTUnwrap(library.responses["sample-approval-2"])
        let revision = try XCTUnwrap(fixture.viewModel.conversation(for: revised.key))
        XCTAssertEqual(revision.currentRevision, 2)
        XCTAssertNotNil(revision.answerDrafts?[1]?.inputs[ExactText("answer")]?.selectedActionID)
        XCTAssertTrue(fixture.viewModel.request(for: revised.key)?.body?.rawValue.contains("review before archiving") == true)
        let files = try XCTUnwrap(library.responses["sample-information-2"])
        let fileThread = try XCTUnwrap(fixture.viewModel.conversation(for: files.key))
        let turn = try XCTUnwrap(fileThread.turns.last)
        let file = try XCTUnwrap(turn.files.first)
        XCTAssertEqual(fileThread.facts[turn.id]?.fileTransfers[file.id], .transferred)
        XCTAssertEqual(fileThread.facts[turn.id]?.fileUses[file.id], .unusable(reason: ExactText("Fictional unsupported format")))
        let closed = try XCTUnwrap(library.responses["sample-completed-2"])
        XCTAssertEqual(fixture.viewModel.conversation(for: closed.key)?.terminal, .cleared)
        XCTAssertEqual(fixture.viewModel.conversation(for: closed.key)?.terminalAuthor, .origin)
        XCTAssertTrue(closed.isClosed)
        let before = try fixture.domain.conversationSnapshot(context: fixture.context)
        library.populate()
        XCTAssertEqual(try fixture.domain.conversationSnapshot(context: fixture.context).cursor, before.cursor)
        let state = try fixture.domain.snapshot(context: fixture.context)
        XCTAssertTrue(state.intents.isEmpty)
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertThrowsError(try fixture.domain.prepareDiscussion(ConversationBinding(request: revised.key, revision: 2), context: fixture.context))
    }

    func testAgentReplyStaysUnreadUntilChatShowsItAcrossForegroundAndRelaunch() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = FileAttentionStatePersistence(directoryURL: root)
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let request = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        let binding = ConversationBinding(request: request, revision: 1)
        let session = ExactText("session")
        func turn(_ id: String, _ author: ConversationAuthor, _ kind: ConversationTurn.Kind) -> ConversationTurn {
            ConversationTurn(id: ExactText(id), binding: binding, author: author, sessionHandle: session,
                text: ExactText("Turn \(id)"), inReplyTo: author == .person ? nil : ExactText("2"), kind: kind)
        }
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: session, payload: .null)), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .turn(turn("2", .person, .discussion))), context: context)
        let model = try LivePresentationStore(store: domain, context: context)
        XCTAssertFalse(model.hasUnreadAgentReply(request), "The person's own turn does not light the marker.")

        // Foreground: the reply arrives while Chat is closed.
        try domain.applyConversation(ConversationEvent(sequence: 3, binding: binding,
            fact: .turn(turn("3", .agent, .reply))), context: context)
        try model.refreshFromDurableStore()
        XCTAssertTrue(model.hasUnreadAgentReply(request))

        // Opening Chat clears it, and the cleared state survives a relaunch.
        model.markConversationRead(request)
        XCTAssertFalse(model.hasUnreadAgentReply(request))
        let relaunched = try LivePresentationStore(store: AttentionDomainStore(context: context, persistence: persistence),
            context: context)
        XCTAssertFalse(relaunched.hasUnreadAgentReply(request))

        // Background: a later reply is replayed into durable state before the app shows it.
        let replayed = try AttentionDomainStore(context: context, persistence: persistence)
        try replayed.applyConversation(ConversationEvent(sequence: 4, binding: binding,
            fact: .turn(turn("4", .origin, .reply))), context: context)
        let resumed = try LivePresentationStore(store: AttentionDomainStore(context: context, persistence: persistence),
            context: context)
        XCTAssertTrue(resumed.hasUnreadAgentReply(request))
        resumed.markConversationRead(request)
        XCTAssertFalse(resumed.hasUnreadAgentReply(request))
    }

}

private final class FailOnceAttentionStatePersistence: AttentionStatePersistence, @unchecked Sendable {
    private let backing: FileAttentionStatePersistence
    private let lock = NSLock()
    private var failNextWrite = false

    init(backing: FileAttentionStatePersistence) {
        self.backing = backing
    }

    func failNextCommit() {
        lock.lock()
        failNextWrite = true
        lock.unlock()
    }

    func load(identity: ProfileIdentity) throws -> Data? {
        try backing.load(identity: identity)
    }

    func commit(_ data: Data, identity: ProfileIdentity) throws {
        lock.lock()
        let shouldFail = failNextWrite
        failNextWrite = false
        lock.unlock()
        if shouldFail {
            throw AttentionStoreError.persistence("Injected pre-replacement test write failure.")
        }
        try backing.commit(data, identity: identity)
    }
}
