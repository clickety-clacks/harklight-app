import AttentionDomain
import CryptoKit
import XCTest
@testable import AttentionClientDuoPrototype

@MainActor
final class ConversationPresentationTests: XCTestCase {
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
}
