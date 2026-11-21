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
