import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest

final class UnboundedNativeWireParsingTests: XCTestCase {
    private let formerFrameCeiling = 2 * (2 * 1024 * 1024) + 16_384

    private func context() -> ProfileContext {
        ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("reader")), transportMode: .relay)
    }

    private func oversizedFrame(prefix: String) -> Data {
        let payload = String(repeating: "x", count: formerFrameCeiling + 1)
        let bytes = Data((prefix + payload + "\"}").utf8)
        XCTAssertGreaterThan(bytes.count, formerFrameCeiling)
        return bytes
    }

    func testRelayWireAcceptsResyncReplyAboveFormerFrameCeiling() throws {
        let bytes = oversizedFrame(prefix: #"{"v":1,"type":"ok","ref":"native-sync","padding":""#)
        XCTAssertTrue(try RelayWire(profile: context()).isResyncAccepted(bytes))
    }

    func testInboxPagingWireAcceptsStartReplyAboveFormerFrameCeiling() throws {
        let bytes = oversizedFrame(prefix: #"{"v":1,"type":"ok","ref":"start","paging_version":1,"snapshot_id":"snapshot","high_water":0,"items":[],"next_cursor":null,"receipt_cursor":null,"padding":""#)
        let page = try InboxPagingWire(profile: context()).decodeStart(bytes, ref: "start")
        XCTAssertEqual(page.snapshotID, "snapshot")
        XCTAssertTrue(page.items.isEmpty)
    }

    func testConversationWireAcceptsReplyAboveFormerFrameCeiling() throws {
        let bytes = oversizedFrame(prefix: #"{"v":1,"type":"ok","ref":"native-conversation-sync","padding":""#)
        XCTAssertNil(try ConversationWire(profile: context()).originEndpoint(bytes))
    }
}
