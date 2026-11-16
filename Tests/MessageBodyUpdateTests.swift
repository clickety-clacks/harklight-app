import UIKit
import XCTest
@testable import Harklight

@MainActor
final class MessageBodyUpdateTests: XCTestCase {
    func testReadOnlyBodyCopiesSelectionAndWholeVisibleMessage() {
        let view = SystemDetectedMessageBody.MessageTextView()
        view.isEditable = false
        view.isSelectable = true
        let visible = "A bold message\nhttps://example.com\nNovember 4, 2027 at 2:00 PM."
        view.text = visible
        view.selectedRange = NSRange(location: 2, length: 4)
        UIPasteboard.general.string = "selected-copy-baseline"
        XCTAssertEqual(UIPasteboard.general.string, "selected-copy-baseline")
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "bold")

        XCTAssertTrue(view.canPerformAction(#selector(view.selectAll(_:)), withSender: nil))
        view.selectAll(nil)
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: (visible as NSString).length))
        UIPasteboard.general.string = "whole-copy-baseline"
        XCTAssertEqual(UIPasteboard.general.string, "whole-copy-baseline")
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, visible)
        XCTAssertFalse(view.canPerformAction(#selector(view.selectAll(_:)), withSender: nil))
        XCTAssertFalse(view.isEditable)
    }

    func testUnchangedMessagePreservesSelectionAndMarkdownTraits() throws {
        let view = UITextView()
        let renderer = SystemDetectedMessageBody.Coordinator()
        let font = UIFont.systemFont(ofSize: 17)
        let source = "A **bold** [link](https://example.com)"
        renderer.updateText(source, bodyFont: font, foregroundColor: .label, in: view)
        let selection = (view.text as NSString).range(of: "bold")
        view.selectedRange = selection
        renderer.updateText(source, bodyFont: font, foregroundColor: .label, in: view)

        XCTAssertEqual(view.selectedRange, selection)
        let bold = try XCTUnwrap(view.attributedText.attribute(.font,
            at: selection.location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        let link = (view.text as NSString).range(of: "link").location
        XCTAssertEqual(view.attributedText.attribute(.link, at: link,
            effectiveRange: nil) as? URL, URL(string: "https://example.com"))
    }

    func testChangedMessageFontAndColorAreAppliedIndependently() throws {
        let view = UITextView()
        let renderer = SystemDetectedMessageBody.Coordinator()
        let standard = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let enlarged = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge))
        renderer.updateText("Old message", bodyFont: standard, foregroundColor: .black, in: view)
        renderer.updateText("**New** message", bodyFont: standard, foregroundColor: .black, in: view)
        XCTAssertEqual(view.text, "New message")

        renderer.updateText("**New** message", bodyFont: enlarged, foregroundColor: .black, in: view)
        let font = try XCTUnwrap(view.attributedText.attribute(.font,
            at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(font.pointSize, standard.pointSize)
        XCTAssertEqual(font.pointSize, enlarged.pointSize, accuracy: 0.1)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))

        renderer.updateText("**New** message", bodyFont: enlarged, foregroundColor: .white, in: view)
        for index in 0..<view.attributedText.length {
            let color = try XCTUnwrap(view.attributedText.attribute(.foregroundColor,
                at: index, effectiveRange: nil) as? UIColor)
            XCTAssertTrue(color.isEqual(UIColor.white))
        }
    }
}
