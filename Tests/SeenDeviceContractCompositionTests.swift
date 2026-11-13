import AttentionDomain
import Foundation
import XCTest

final class SeenDeviceContractCompositionTests: XCTestCase {
    func testOnlyCanonicalSeenMapsToNullInPreviewAndOriginalOperation() throws {
        let cases: [(actions: String, input: TypedInputRecord, expected: JSONValue, isSeen: Bool)] = [
            (#"[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]"#,
             .compatibilityValue(action: ExactText("seen")), .null, true),
            (#"[{"id":"seen","label":"Seen","kind":"value","value":"custom"}]"#,
             .compatibilityValue(action: ExactText("seen")), .string(ExactText("custom")), false),
            (#"[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}},{"id":"reply","label":"Reply","kind":"text"}]"#,
             .compatibilityValue(action: ExactText("seen")),
             try JSONValue.parse(Data(#"{"acknowledgment":"seen"}"#.utf8)), false),
            (#"[{"id":"reply","label":"Reply","kind":"text"}]"#,
             .compatibilityText(action: ExactText("reply"), text: ExactText("Exact reply")),
             .string(ExactText("Exact reply")), false)
        ]
        for scenario in cases {
            let context = context(device: "sender")
            let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
            let key = key(context)
            let payload = try JSONValue.parse(Data("{\"title\":\"Notice\",\"answer_ui\":{\"schema\":\"attention-client.actions/1\",\"actions\":\(scenario.actions)}}".utf8))
            _ = try repository.apply(RelayEvent(sequence: 1,
                body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
            let port = AttentionDomainPort(store: repository)
            let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
            XCTAssertEqual(try port.preview(context: port.context, selector: selector, inputs: [scenario.input]),
                           scenario.expected)
            let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
                intentID: UUID(), inputs: [scenario.input]))
            let submission = try XCTUnwrap(repository.lookupIntent(receipt.intentID, context: context))
            let frame = try JSONValue.parse(submission.wireFrame)
            XCTAssertEqual(frame.uniqueValue(named: "type")?.stringValue, ExactText("answer"))
            XCTAssertEqual(frame.uniqueValue(named: "answer"), scenario.expected,
                           "Seen must include an explicit null answer; other actions retain their values.")
            XCTAssertEqual(frame.uniqueValue(named: "op_id")?.stringValue,
                           ExactText(receipt.opID.uuidString.lowercased()))
            XCTAssertFalse(submission.isNoComment, "Seen is distinct from the No Comment action.")
            XCTAssertEqual(try port.inspect(context: port.context, request: key).requests.first?.informationalSeenStatus,
                           scenario.isSeen ? .pending : nil)
        }
    }

    func testSharedSeenOutcomeConfirmsOnEitherDeviceWithoutLocalIntent() throws {
        for device in ["first", "second"] {
            let context = context(device: device)
            let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
            let key = key(context)
            let payload = try JSONValue.parse(Data(#"{"title":"Notice","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
            _ = try repository.apply(RelayEvent(sequence: 1,
                body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
            _ = try repository.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil),
                accountAnswerOutcome: .seen), context: context)
            let port = AttentionDomainPort(store: repository)
            let request = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first)
            XCTAssertEqual(request.accountAnswerOutcome, .seen)
            XCTAssertEqual(request.informationalSeenStatus, .confirmed)
            XCTAssertTrue(try repository.snapshot(context: context).intents.isEmpty)
        }
    }

    private func context(device: String) -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText(device)), transportMode: .relay)
    }

    private func key(_ context: ProfileContext) -> RequestKey {
        RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("notice"))
    }
}
