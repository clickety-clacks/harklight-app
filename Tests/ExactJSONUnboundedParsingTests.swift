import Foundation
import AttentionDomain
import XCTest

final class ExactJSONUnboundedParsingTests: XCTestCase {
    func testParseAcceptsInputLargerThanFormerFrameCeiling() throws {
        let formerLimit = 2 * (2 * 1024 * 1024) + 16_384
        var data = Data(repeating: 0x20, count: formerLimit + 1)
        data.append(contentsOf: "null".utf8)

        XCTAssertEqual(try JSONValue.parse(data), .null)
    }

    func testParseAcceptsNestingDeeperThanFormerLimit() throws {
        let depth = 129
        let data = Data(String(repeating: "[", count: depth).utf8) +
            Data("null".utf8) +
            Data(String(repeating: "]", count: depth).utf8)

        var value = try JSONValue.parse(data)
        for _ in 0..<depth {
            value = try XCTUnwrap(value.arrayValues?.first)
        }
        XCTAssertEqual(value, .null)
    }
}
