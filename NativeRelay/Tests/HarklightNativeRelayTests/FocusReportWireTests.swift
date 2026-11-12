import Foundation
@testable import HarklightNativeRelay
import XCTest

final class FocusReportWireTests: XCTestCase {
    func testFocusReportContainsOnlyContractFieldsAndOmitsMissingIdentifiers() throws {
        let wire = FocusReportWire()
        let bytes = try wire.request(for: .chat(
            senderID: "sender-7", messageID: "message-12",
            visibility: .eventID("4182")), ref: "focus-1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set([
            "v", "type", "ref", "screen", "sender_id", "message_id", "visible_event_id"
        ]))
        XCTAssertEqual(object["sender_id"] as? String, "sender-7")
        XCTAssertEqual(object["message_id"] as? String, "message-12")
        XCTAssertEqual(object["visible_event_id"] as? String, "4182")

        let emptyChat = try wire.request(
            for: .chat(senderID: "sender-7", messageID: "message-12", visibility: .noTurns),
            ref: "focus-2")
        let emptyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyChat) as? [String: Any])
        XCTAssertEqual(Set(emptyObject.keys), Set(["v", "type", "ref", "screen", "sender_id", "message_id"]))
        XCTAssertNil(emptyObject["visible_event_id"])
    }

    func testFocusRepliesRouteOnlyByTheirRefAndUnknownTypeStopsFutureReports() throws {
        let wire = FocusReportWire()
        var router = FocusReportReplyRouter()
        XCTAssertTrue(router.register(ref: "focus-1"))
        XCTAssertTrue(router.register(ref: "focus-2"))

        XCTAssertEqual(router.route(try reply(type: "ok", ref: "inbox-1"), using: wire), .unrelated)
        XCTAssertTrue(router.supportsFocusReports)
        XCTAssertEqual(router.route(try reply(type: "error", ref: "focus-1", reason: "unknown_type"), using: wire), .unsupported)
        XCTAssertFalse(router.supportsFocusReports)
        XCTAssertEqual(router.route(try reply(type: "ok", ref: "focus-2"), using: wire), .consumed,
                       "A reply already in flight is still consumed after support is disabled.")
        XCTAssertFalse(router.register(ref: "focus-3"))
    }

    func testViewShowParsesHeldDurationAndIgnoresUnknownTargets() throws {
        let wire = ViewShowWire()
        let valid = Data(#"{"v":1,"type":"view_show","sender_id":"agent","message_id":"message","target":"chat","held_ms":5400000}"#.utf8)
        let show = try XCTUnwrap(wire.frame(valid))
        XCTAssertEqual(show.senderID, "agent")
        XCTAssertEqual(show.messageID, "message")
        XCTAssertEqual(show.target, .chat)
        XCTAssertEqual(show.heldMilliseconds, 5_400_000)

        let unknown = Data(#"{"v":1,"type":"view_show","sender_id":"agent","message_id":"message","target":"future-view"}"#.utf8)
        XCTAssertNil(wire.frame(unknown))
    }

    private func reply(type: String, ref: String, reason: String? = nil) throws -> Data {
        var object: [String: Any] = ["v": 1, "type": type, "ref": ref]
        if let reason { object["reason"] = reason }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
