import AttentionDomain
import CryptoKit
import XCTest
@testable import AttentionClientDuoPrototype

@MainActor
final class ConversationPresentationTests: XCTestCase {
    func testInlineTurnAndDraftBytesStayBehindAccountFileReferencesAcrossComposerWrites() throws {
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
        try domain.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("After composer edit"), files: saved.files),
            context: context)

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
        XCTAssertEqual(thread.drafts[1]?.text, ExactText("After composer edit"))
        XCTAssertEqual(thread.drafts[1]?.files.first?.content, savedFile.content)
        try restored.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(turn)), context: context)
        XCTAssertEqual(try restored.conversationSnapshot(context: context).cursor, 2,
            "A duplicate inline replay normalizes to the same retained reference instead of conflicting.")
    }

    func testQuestionRevisionArchivesTheOldAnswerAndInvalidatesItsSelectorWithoutReusingIt() throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("fictional-relay"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("request"))
        let first = try JSONValue.parse(Data(#"{"title":"First wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Old choice","kind":"value","value":"old"}]}}"#.utf8))
        let second = try JSONValue.parse(Data(#"{"title":"Revised wording","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"new","label":"New choice","kind":"value","value":"new"}]}}"#.utf8))
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
        XCTAssertThrowsError(try port.submit(SubmitIntent(context: port.context, selector: oldSelector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("old"))])))
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

}
