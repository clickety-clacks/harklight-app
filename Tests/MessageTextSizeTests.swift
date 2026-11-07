import XCTest
import UIKit
@testable import Harklight

final class MessageTextSizeTests: XCTestCase {
    func testUnknownStoredValueFallsBackToStandard() {
        XCTAssertEqual(MessageTextSize.resolve(storedValue: "unrecognized"), .standard)
        XCTAssertEqual(MessageTextSize.resolve(storedValue: "large"), .large)
    }

    func testStandardMatchesSystemBodyAndLargerStepsMultiplyWithDynamicType() {
        let defaultTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityLarge)
        let systemBody = UIFont.preferredFont(forTextStyle: .body, compatibleWith: defaultTraits)

        let standard = MessageTextSize.standard.uiFont(compatibleWith: defaultTraits)
        let large = MessageTextSize.large.uiFont(compatibleWith: defaultTraits)
        let larger = MessageTextSize.larger.uiFont(compatibleWith: defaultTraits)
        let accessibilityStandard = MessageTextSize.standard.uiFont(compatibleWith: accessibilityTraits)
        let accessibilityLarge = MessageTextSize.large.uiFont(compatibleWith: accessibilityTraits)
        let accessibilityLarger = MessageTextSize.larger.uiFont(compatibleWith: accessibilityTraits)

        XCTAssertEqual(standard.pointSize, systemBody.pointSize, accuracy: 0.1)
        XCTAssertEqual(large.pointSize / standard.pointSize, 1.2, accuracy: 0.02)
        XCTAssertEqual(larger.pointSize / standard.pointSize, 1.4, accuracy: 0.02)
        XCTAssertGreaterThan(accessibilityStandard.pointSize, standard.pointSize)
        XCTAssertEqual(accessibilityLarge.pointSize / accessibilityStandard.pointSize,
                       1.2, accuracy: 0.02)
        XCTAssertEqual(accessibilityLarger.pointSize / accessibilityStandard.pointSize,
                       1.4, accuracy: 0.02)
    }

    @MainActor
    func testScaledMarkdownKeepsBoldItalicAndMonospacedTraits() throws {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityLarge)
        let bodyFont = MessageTextSize.large.uiFont(compatibleWith: traits)
        let rendered = SystemDetectedMessageBody.attributedMessage(
            "Plain **bold**, *italic*, `code`",
            foregroundColor: .label,
            bodyFont: bodyFont)

        func font(for substring: String) throws -> UIFont {
            let index = (rendered.string as NSString).range(of: substring).location
            return try XCTUnwrap(rendered.attribute(.font, at: index, effectiveRange: nil) as? UIFont)
        }

        XCTAssertEqual(try font(for: "Plain").pointSize, bodyFont.pointSize, accuracy: 0.1)
        XCTAssertTrue(try font(for: "bold").fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(try font(for: "italic").fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertTrue(try font(for: "code").fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertEqual(try font(for: "code").pointSize, bodyFont.pointSize, accuracy: 0.1)
    }
}
