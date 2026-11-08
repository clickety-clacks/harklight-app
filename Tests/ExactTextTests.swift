import AttentionDomain
import XCTest

final class ExactTextTests: XCTestCase {
    func testEqualityUsesExactUTF8BytesIncludingEmbeddedNUL() {
        XCTAssertEqual(ExactText(""), ExactText(""))
        XCTAssertNotEqual(ExactText("prefix\u{0000}a"), ExactText("prefix\u{0000}b"))
        XCTAssertNotEqual(ExactText("\u{00E9}"), ExactText("e\u{0301}"))
    }

    func testEqualValuesHaveEqualHashesAndShareDictionaryKey() {
        let first = ExactText("identifier-\u{1F680}-\u{00E9}-\u{0000}-tail")
        let second = ExactText(String(decoding: first.rawValue.utf8, as: UTF8.self))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)

        var values = [first: 1]
        values[second] = 2

        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[first], 2)
    }
}
