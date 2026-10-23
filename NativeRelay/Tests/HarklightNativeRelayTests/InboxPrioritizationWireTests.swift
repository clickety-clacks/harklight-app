import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

final class InboxPrioritizationWireTests: XCTestCase {
    private func makeWire() throws -> (InboxPrioritizationWire, ProfileContext) {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"),
                                       deviceID: ExactText("installation-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        return (try InboxPrioritizationWire(profile: context), context)
    }

    func testViewGetSendsKnownRevisionOnlyWhenProvided() throws {
        let (wire, _) = try makeWire()

        let first = try JSONValue.parse(wire.viewGet(knownRevision: nil, ref: "view-a"))
        XCTAssertEqual(first.uniqueValue(named: "v")?.integerValue, 1)
        XCTAssertEqual(first.uniqueValue(named: "type")?.stringValue?.rawValue, "view_get")
        XCTAssertEqual(first.uniqueValue(named: "ref")?.stringValue?.rawValue, "view-a")
        XCTAssertNil(first.uniqueValue(named: "known_view_rev"))

        let later = try JSONValue.parse(wire.viewGet(knownRevision: "rev-3", ref: "view-b"))
        XCTAssertEqual(later.uniqueValue(named: "known_view_rev")?.stringValue?.rawValue, "rev-3")
    }

    func testDecodesOrderedViewReasonsUnchangedAndServerErrors() throws {
        let (wire, context) = try makeWire()
        let reply = #"{"v":1,"type":"ok","ref":"view-a","view_rev":"rev-4","algorithm":"jev-set","basis":"fallback","entries":[{"sender_id":"sender","message_id":"m2","reason":"Due soon","due_at":1792790400000},{"sender_id":"sender","message_id":"m1"}]}"#
        let decoded = try wire.decodeViewGetReply(Data((reply + "\n").utf8), ref: "view-a",
                                                  knownRevision: nil)
        let expected = InboxOrderView(revision: "rev-4", algorithm: .jevSet, basis: .fallback,
            entries: [
                InboxOrderEntry(key: RequestKey(accountScope: context.identity.personID,
                    senderID: ExactText("sender"), messageID: ExactText("m2")), reason: "Due soon",
                    dueAtMilliseconds: 1_792_790_400_000),
                InboxOrderEntry(key: RequestKey(accountScope: context.identity.personID,
                    senderID: ExactText("sender"), messageID: ExactText("m1")))
            ])
        XCTAssertEqual(decoded, .view(expected))

        let unchanged = #"{"v":1,"type":"ok","ref":"view-b","view_rev":"rev-4","unchanged":true}"#
        XCTAssertEqual(try wire.decodeViewGetReply(Data(unchanged.utf8), ref: "view-b",
                                                   knownRevision: "rev-4"),
                       .unchanged(revision: "rev-4"))

        let oldServer = #"{"v":1,"type":"error","ref":"view-c","reason":"unknown_type"}"#
        XCTAssertEqual(try wire.decodeViewGetReply(Data(oldServer.utf8), ref: "view-c",
                                                   knownRevision: nil), .unsupported)
        let refused = #"{"v":1,"type":"error","ref":"view-d","reason":"invalid_field"}"#
        XCTAssertThrowsError(try wire.decodeViewGetReply(Data(refused.utf8), ref: "view-d",
                                                          knownRevision: nil)) {
            XCTAssertEqual($0 as? InboxPrioritizationWireError, .serverRefused("invalid_field"))
        }
    }

    func testRejectsInvalidReasonsDuplicateRowsAndMismatchedReplies() throws {
        let (wire, _) = try makeWire()
        let invalidReplies = [
            #"{"v":1,"type":"ok","ref":"view-a","view_rev":"rev-1","algorithm":"baseline","basis":"selected","entries":[{"sender_id":"sender","message_id":"m1","reason":""}]}"#,
            #"{"v":1,"type":"ok","ref":"view-a","view_rev":"rev-1","algorithm":"baseline","basis":"selected","entries":[{"sender_id":"sender","message_id":"m1","reason":"first\nsecond"}]}"#,
            #"{"v":1,"type":"ok","ref":"view-a","view_rev":"rev-1","algorithm":"baseline","basis":"selected","entries":[{"sender_id":"sender","message_id":"m1","due_at":"tomorrow"}]}"#,
            #"{"v":1,"type":"ok","ref":"view-a","view_rev":"rev-1","algorithm":"baseline","basis":"selected","entries":[{"sender_id":"sender","message_id":"m1","due_at":1.5}]}"#,
            #"{"v":1,"type":"ok","ref":"view-a","view_rev":"rev-1","algorithm":"baseline","basis":"selected","entries":[{"sender_id":"sender","message_id":"m1"},{"sender_id":"sender","message_id":"m1"}]}"#,
            #"{"v":1,"type":"ok","ref":"wrong-ref","view_rev":"rev-1","algorithm":"baseline","basis":"selected","entries":[]}"#
        ]

        for reply in invalidReplies {
            XCTAssertThrowsError(try wire.decodeViewGetReply(Data(reply.utf8), ref: "view-a",
                                                              knownRevision: nil))
        }
    }
}
