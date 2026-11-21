import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

/// The v2 write requests (`docs/client-api-v2.md` §5), including contract
/// round 10: an FYI's Seen is an answer with `choice: "seen"`.
final class ClientAPIWritesTests: XCTestCase {
    private let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                           personID: ExactText("person-A"), deviceID: ExactText("installation-A"))
    private let seenUI = #"{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}"#
    private let replyUI = #"{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}"#

    private func body(_ write: ClientAPIWrite) -> String {
        String(decoding: write.write.body ?? Data(), as: UTF8.self)
    }

    /// Projects one v2 item into the repository and submits through the port,
    /// the same path a tap takes.
    private func submit(message: String, inputs: [TypedInputRecord]) throws -> Submission {
        let model = ServerModelV2Store(fileURL: nil)
        try model.apply(kind: "item", rev: 1, data: V2Fixture.json(V2Fixture.item("item-1", rev: 1, rankKey: "a",
                                                                                   message: message)))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try repository.restoreCachedServerState(ServerModelV2Projection.cachedState(model.snapshot, identity: identity),
                                                context: context)
        let port = AttentionDomainPort(store: repository)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"),
                             messageID: ExactText("item-1"))
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                                                   inputs: inputs))
        return try XCTUnwrap(repository.lookupIntent(receipt.intentID, context: context))
    }

    func testAnFYISeenTapIsAnAnswerWithTheSeenChoice() throws {
        let submission = try submit(message: #"{"title":"Deployed","answer_ui":\#(seenUI)}"#,
                                    inputs: [.compatibilityValue(action: ExactText("seen"))])
        let write = try ClientAPIWrites.answer(submission, answerUI: try json(seenUI))
        XCTAssertEqual(write.write.method, .post)
        XCTAssertEqual(write.write.path, "/v2/items/item-1/answer")
        XCTAssertEqual(body(write), #"{"request_revision":1,"choice":"seen"}"#)
        XCTAssertEqual(write.operation, "answer")
        XCTAssertEqual(write.target, "item:item-1")
    }

    func testATextActionReplyIsAComment() throws {
        let submission = try submit(message: #"{"title":"Question","answer_ui":\#(replyUI)}"#,
                                    inputs: [.compatibilityText(action: ExactText("reply"), text: ExactText("Ship it"))])
        XCTAssertEqual(body(try ClientAPIWrites.answer(submission, answerUI: try json(replyUI))),
                       #"{"request_revision":1,"comment":"Ship it"}"#)
    }

    func testThePlainReplyOfAnUnshowableScreenIsAComment() throws {
        // The v2 client degrades a screen it cannot show to the plain reply.
        let saved = AnswerScreenRules.current
        AnswerScreenRules.current = AnswerScreenRules(limits: .builtIn, degradesUnshowableScreens: true)
        defer { AnswerScreenRules.current = saved }
        let unknown = #"{"schema":"attention-client.future/9","anything":true}"#
        let submission = try submit(message: #"{"title":"Question","answer_ui":\#(unknown)}"#,
                                    inputs: [.compatibilityText(action: ExactText("reply"), text: ExactText("Later"))])
        XCTAssertEqual(body(try ClientAPIWrites.answer(submission, answerUI: try json(unknown))),
                       #"{"request_revision":1,"comment":"Later"}"#)
    }

    private func submission(inputs: [TypedInputRecord], answer: JSONValue, kind: SubmissionAnswerKind? = nil,
                            revision: UInt64? = 3) -> Submission {
        Submission(requestKey: RequestKey(accountScope: identity.personID, senderID: ExactText("agent-app"),
                                          messageID: ExactText("item-2")),
                   answer: answer, answerKind: kind, intentID: UUID(), operationID: UUID(), operation: .null,
                   typedInputs: inputs, descriptorFingerprint: "", contentFingerprint: "", requestRevision: revision)
    }

    private let uiScreen = #"{"schema":"attention-client.ui/1","requires":["scene/1","result/1"],"illustrations":[],"inputs":[],"open":{"kind":"text","text":"Ready?","style":"body"},"resolved":{"kind":"text","text":"Done","style":"body"},"submission":{"label":"Done","result":{"kind":"literal","value":null}}}"#

    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    func testAUI1ScreenSendsItsBuiltResult() throws {
        let result = try json(#"{"approve":true,"note":"ok","weight":1.50}"#)
        let write = try ClientAPIWrites.answer(submission(inputs: [.text(input: ExactText("note"), text: ExactText("ok"))],
                                                          answer: result), answerUI: try json(uiScreen))
        XCTAssertEqual(body(write), #"{"request_revision":3,"result":{"approve":true,"note":"ok","weight":1.50}}"#,
                       "The result is sent exactly as built.")
    }

    /// #386 review B-8 and round 16: a UI/1 screen with no inputs (a confirm
    /// button with a literal result) is answerable, through the same port a tap uses.
    func testAUI1ScreenWithNoInputsIsAnsweredWithItsLiteralResultEvenNull() throws {
        let submission = try submit(message: #"{"title":"Confirm","answer_ui":\#(uiScreen)}"#, inputs: [])
        let reopened = try JSONDecoder().decode(Submission.self, from: JSONEncoder().encode(submission))
        XCTAssertEqual(reopened.answerUISchema?.rawValue, "attention-client.ui/1")
        let write = try ClientAPIWrites.answer(reopened)
        XCTAssertEqual(body(write), #"{"request_revision":1,"result":null}"#,
                       "A null result is present: a structured answer whose value is null.")
    }

    /// Round 16: the result may be any JSON value; the screen decides, not the value's shape.
    func testAUI1ResultMayBeAnyJSONValue() throws {
        for literal in [#"{"a":1}"#, #"[1,"two"]"#, #""yes""#, "42", "1.50", "true", "false", "null"] {
            let write = try ClientAPIWrites.answer(submission(inputs: [], answer: try json(literal)),
                                                   answerUI: try json(uiScreen))
            XCTAssertEqual(body(write), #"{"request_revision":3,"result":"# + literal + "}")
        }
    }

    func testAPlainReplyOnAUI1ItemIsStillAComment() throws {
        let write = try ClientAPIWrites.answer(
            submission(inputs: [.compatibilityText(action: ExactText("reply"), text: ExactText("Later"))],
                       answer: .null), answerUI: try json(uiScreen))
        XCTAssertEqual(body(write), #"{"request_revision":3,"comment":"Later"}"#)
    }

    func testNoCommentSendsOnlyTheRevision() throws {
        let write = try ClientAPIWrites.answer(submission(inputs: [], answer: .null, kind: .noComment),
                                               answerUI: try json(uiScreen))
        XCTAssertEqual(body(write), #"{"request_revision":3}"#)
    }

    func testAnAnswerWithNoV2FormIsRefused() throws {
        XCTAssertThrowsError(try ClientAPIWrites.answer(submission(inputs: [], answer: .null), answerUI: try json(replyUI))) {
            XCTAssertEqual($0 as? ClientAPIWrites.BuildError, .unsupportedAnswer)
        }
        XCTAssertThrowsError(try ClientAPIWrites.answer(
            submission(inputs: [.text(input: ExactText("note"), text: ExactText("ok"))], answer: .null),
            answerUI: try json(replyUI)), "A result only goes to a UI/1 screen.")
        XCTAssertThrowsError(try ClientAPIWrites.answer(submission(inputs: [.compatibilityValue(action: ExactText("a")),
                                                                            .compatibilityValue(action: ExactText("b"))],
                                                                   answer: .null), answerUI: try json(seenUI)))
        XCTAssertThrowsError(try ClientAPIWrites.answer(submission(inputs: [.compatibilityValue(action: ExactText("a"))],
                                                                   answer: .null, revision: nil), answerUI: nil)) {
            XCTAssertEqual($0 as? ClientAPIWrites.BuildError, .missingRequestRevision)
        }
    }

    /// #386 review L-31: an id is percent-encoded once, by the builder; the
    /// transport sends the path as it is.
    func testTheTransportDoesNotEncodeTheIdAgain() throws {
        let transport = HTTPSClientAPITransport(baseURL: try XCTUnwrap(URL(string: "https://server.example:8443")),
                                                configuration: .ephemeral, delegate: nil)
        let write = ClientAPIWrites.seen(itemID: ExactText("a b/c"))
        let request = transport.urlRequest(for: APIRequest(method: write.write.method, path: write.write.path,
                                                           body: write.write.body))
        XCTAssertEqual(request.url?.absoluteString, "https://server.example:8443/v2/items/a%20b%2Fc/seen")
        let listed = transport.urlRequest(for: .get("/v2/inbox", query: ["limit": "200"]))
        XCTAssertEqual(listed.url?.absoluteString, "https://server.example:8443/v2/inbox?limit=200")
    }

    func testSeenReadPositionAndReplyRequests() throws {
        let seen = ClientAPIWrites.seen(itemID: ExactText("a/b c"))
        XCTAssertEqual(seen.write.path, "/v2/items/a%2Fb%20c/seen", "The opaque id is one path segment.")
        XCTAssertEqual(body(seen), "{}")
        XCTAssertEqual(seen.operation, "mark_seen")

        let position = ClientAPIWrites.readPosition(itemID: ExactText("i"), entryID: ExactText("e9"))
        XCTAssertEqual(position.write.method, .put)
        XCTAssertEqual(position.write.path, "/v2/items/i/read-position")
        XCTAssertEqual(body(position), #"{"entry_id":"e9"}"#)

        XCTAssertEqual(body(ClientAPIWrites.reply(itemID: ExactText("i"), text: ExactText("hi"))), #"{"text":"hi"}"#)
        let upload = try APIFileCreated(json: json(#"{"file_id":"f1","name":"photo.png","size":3,"sha256":"hash"}"#))
        let withFiles = ClientAPIWrites.reply(itemID: ExactText("i"), text: ExactText("see"), fileIDs: [upload.handle])
        XCTAssertEqual(withFiles.write.path, "/v2/items/i/replies")
        XCTAssertEqual(body(withFiles), #"{"text":"see","file_ids":["f1"]}"#)
        XCTAssertEqual(withFiles.write.contentType, "application/json")
    }
}
