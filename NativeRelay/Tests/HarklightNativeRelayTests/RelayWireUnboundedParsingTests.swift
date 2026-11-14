import AttentionDomain
import Foundation
import XCTest
@testable import HarklightNativeRelay

final class RelayWireUnboundedParsingTests: XCTestCase {
    func testDecodeResyncedAcceptsBytesAboveFormerFrameCeiling() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"),
                                       deviceID: ExactText("installation"))
        let wire = try RelayWire(profile: ProfileContext(identity: identity, transportMode: .relay))
        let formerLimit = 2 * (2 * 1024 * 1024) + 16_384
        let padding = String(repeating: "x", count: formerLimit + 1)
        let frame = Data("{\"v\":1,\"type\":\"resynced\",\"seq\":1,\"padding\":\"\(padding)\"}\n".utf8)

        XCTAssertEqual(try wire.decodeResynced(frame), 1)
    }
}
