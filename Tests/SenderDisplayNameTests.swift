import AttentionDomain
import HarklightNativeRelay
import XCTest
@testable import Harklight

final class SenderDisplayNameTests: XCTestCase {
    private func context() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("reader-account"),
            deviceID: ExactText("reader")), transportMode: .relay)
    }

    func testFeedProjectionPreservesArbitraryAndEmptyNamesWithoutChangingSenderIdentity() throws {
        let profile = context()
        let store = try AttentionDomainStore(context: profile,
            persistence: MemoryAttentionStatePersistence())
        let wire = try RelayWire(profile: profile)
        let senderID = ExactText("agent:workspace/actor-17")
        let cases: [(messageID: String, displayName: String?)] = [
            ("arbitrary", "  A/雪:\n% e\u{301}  "),
            ("empty", ""),
            ("absent", nil)
        ]

        for (index, testCase) in cases.enumerated() {
            var messageMembers = [
                JSONMember("title", .string(ExactText("Question"))),
                JSONMember("answer_ui", .object([
                    JSONMember("schema", .string(ExactText("attention-client.actions/1"))),
                    JSONMember("actions", .array([
                        .object([
                            JSONMember("id", .string(ExactText("reply"))),
                            JSONMember("label", .string(ExactText("Reply"))),
                            JSONMember("kind", .string(ExactText("text")))
                        ])
                    ]))
                ]))
            ]
            if let displayName = testCase.displayName {
                messageMembers.append(JSONMember("display_name", .string(ExactText(displayName))))
            }
            let payload = JSONValue.object(messageMembers)
            let frame = """
            {"v":1,"type":"delivery","seq":\(index + 1),"sender_id":"agent:workspace/actor-17","message_id":"\(testCase.messageID)","origin":"server-origin","as":"message","message":\(payload.jsonString)}
            """
            let event = try wire.decodeEvent(Data(frame.utf8))
            guard case let .delivery(request, _) = event.body else {
                return XCTFail("Expected a delivery event")
            }

            XCTAssertEqual(request.key.senderID, senderID)
            XCTAssertEqual(request.senderDisplayName, testCase.displayName.map(ExactText.init))
            try store.apply(event, context: profile)
        }

        let port = AttentionDomainPort(store: store)
        let projected = try port.observe(context: port.context).requests
        XCTAssertEqual(projected.map(\.acceptanceOrder), [UInt64(3), 2, 1],
                       "The feed presents the newest accepted request first.")
        for testCase in cases {
            let request = try XCTUnwrap(projected.first {
                $0.key.messageID == ExactText(testCase.messageID)
            })
            XCTAssertEqual(request.key.senderID, senderID,
                           "The supplied display label must not replace the authenticated sender identity.")
            if let expected = testCase.displayName {
                let actual = try XCTUnwrap(request.senderDisplayName)
                XCTAssertTrue(actual.rawValue.utf8.elementsEqual(expected.utf8))
            } else {
                XCTAssertNil(request.senderDisplayName)
            }
        }
    }

    func testInboxLabelUsesDisplayNameVerbatimAndFallsBackOnlyWhenAbsent() {
        let senderID = ExactText("agent:workspace/actor-17")
        let key = RequestKey(accountScope: ExactText("reader-account"),
                             senderID: senderID, messageID: ExactText("request"))
        let arbitrary = "  A/雪:\n% e\u{301}  "
        let values: [String?] = [arbitrary, "", nil]

        for displayName in values {
            let row = InboxRequestRow(key: key, title: "Question", sender: senderID.rawValue,
                                      status: "Open", senderDisplayName: displayName)
            let expected = displayName ?? InboxSenderDisplay.name(for: senderID.rawValue)
            XCTAssertTrue(row.senderLabel.utf8.elementsEqual(expected.utf8))
            XCTAssertEqual(row.key.senderID, senderID,
                           "Display text must not change the RequestKey sender identity.")
        }
    }

    func testDetailLabelPreservesDisplayNameAndFallsBackToFullSenderID() {
        let senderID = "agent:workspace/actor-17"
        let arbitrary = "  A/雪:\n% e\u{301}  "
        let cases: [(displayName: String?, expected: String)] = [
            (arbitrary, arbitrary),
            ("", ""),
            (nil, senderID)
        ]

        for testCase in cases {
            let actual = InboxSenderDisplay.detailLabel(displayName: testCase.displayName,
                                                        senderID: senderID)
            XCTAssertTrue(actual.utf8.elementsEqual(testCase.expected.utf8))
        }
    }
}
