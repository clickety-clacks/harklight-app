import XCTest
import UIKit
@testable import Harklight

final class MessageMarkdownTests: XCTestCase {
    func testCommonInlineAndBlockMarkdownBecomesReadableAttributedText() throws {
        let source = """
        A **bold** word and [the guide](https://example.com/guide).

        - first item
        - second item

        > quoted text

        ```swift
        let count = 2
        ```
        """

        let rendered = MessageMarkdown.attributed(source)
        let visible = String(rendered.characters)

        XCTAssertTrue(visible.contains("bold"), visible)
        XCTAssertTrue(visible.contains("the guide"), visible)
        XCTAssertFalse(visible.contains("**"), visible)
        XCTAssertFalse(visible.contains("[the guide]"), visible)
        XCTAssertTrue(visible.contains("• first item"), visible)
        XCTAssertTrue(visible.contains("• second item"), visible)
        XCTAssertTrue(visible.contains("▏ quoted text"), visible)
        XCTAssertTrue(visible.contains("let count = 2"), visible)
        XCTAssertFalse(visible.contains("```"), visible)

        let guide = try XCTUnwrap(rendered.runs.first { $0.link != nil })
        XCTAssertEqual(guide.link, URL(string: "https://example.com/guide"))
        XCTAssertTrue(rendered.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertTrue(rendered.runs.contains {
            $0.inlinePresentationIntent?.contains(.code) == true
        })
    }

    func testPlainTextRemainsReadableAndCanUseGeneratedSummary() {
        let source = "A plain message with no Markdown formatting."

        XCTAssertEqual(String(MessageMarkdown.attributed(source).characters), source)
        XCTAssertFalse(MessageMarkdown.hasFormattingOrLinks(source))
    }

    @MainActor
    func testUIKitMessageBodyAppliesThemeColorToPlainAndMarkdownRuns() throws {
        let color = UIColor.white
        let rendered = SystemDetectedMessageBody.attributedMessage(
            "A plain **bold** [link](https://example.com)",
            foregroundColor: color,
            bodyFont: UIFont.preferredFont(forTextStyle: .body))
        let linkIndex = (rendered.string as NSString).range(of: "link").location

        XCTAssertGreaterThan(linkIndex, 0)
        XCTAssertEqual(rendered.attribute(.link, at: linkIndex, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))
        for index in 0..<rendered.length {
            let runColor = try XCTUnwrap(
                rendered.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor)
            XCTAssertTrue(runColor.isEqual(color), "Unexpected message body color at UTF-16 index \(index)")
        }
    }

    @MainActor
    func testUIKitMessageBodyUsesSystemBodySizeAndPreservesMarkdownFontTraits() throws {
        let standardTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTraits = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraLarge)
        let standardBody = UIFont.preferredFont(forTextStyle: .body, compatibleWith: standardTraits)
        let accessibilityBody = UIFont.preferredFont(forTextStyle: .body,
                                                      compatibleWith: accessibilityTraits)
        XCTAssertGreaterThan(accessibilityBody.pointSize, standardBody.pointSize)

        let source = "Plain **bold**, *italic*, `code`, [link](https://example.com)"
        let standard = SystemDetectedMessageBody.attributedMessage(
            source, foregroundColor: .label, bodyFont: standardBody)
        let accessibility = SystemDetectedMessageBody.attributedMessage(
            source, foregroundColor: .label, bodyFont: accessibilityBody)

        func font(for substring: String, in text: NSAttributedString,
                  file: StaticString = #filePath, line: UInt = #line) throws -> UIFont {
            let index = (text.string as NSString).range(of: substring).location
            XCTAssertNotEqual(index, NSNotFound, file: file, line: line)
            return try XCTUnwrap(text.attribute(.font, at: index, effectiveRange: nil) as? UIFont,
                                 file: file, line: line)
        }

        for (text, expectedPointSize) in [(standard, standardBody.pointSize),
                                          (accessibility, accessibilityBody.pointSize)] {
            XCTAssertEqual(try font(for: "Plain", in: text).pointSize,
                           expectedPointSize, accuracy: 0.1)
            XCTAssertTrue(try font(for: "bold", in: text).fontDescriptor.symbolicTraits
                .contains(.traitBold))
            XCTAssertTrue(try font(for: "italic", in: text).fontDescriptor.symbolicTraits
                .contains(.traitItalic))
            XCTAssertTrue(try font(for: "code", in: text).fontDescriptor.symbolicTraits
                .contains(.traitMonoSpace))
            let linkIndex = (text.string as NSString).range(of: "link").location
            XCTAssertEqual(text.attribute(.link, at: linkIndex, effectiveRange: nil) as? URL,
                           URL(string: "https://example.com"))
        }

        XCTAssertGreaterThan(try font(for: "Plain", in: accessibility).pointSize,
                             try font(for: "Plain", in: standard).pointSize)
    }

    func testVisibleTextForAccessibilityOmitsMarkdownSyntax() {
        XCTAssertEqual(MessageMarkdown.visibleText("A **Markdown** note"), "A Markdown note")
    }

    func testEveryParagraphInMultiParagraphQuotesKeepsItsQuoteMarker() {
        let source = "> First quoted paragraph\n>\n> Second quoted paragraph"
        let visible = String(MessageMarkdown.attributed(source).characters)

        XCTAssertTrue(visible.contains("▏ First quoted paragraph"), visible)
        XCTAssertTrue(visible.contains("▏ Second quoted paragraph"), visible)
    }

    func testOrderedListsKeepTheirOrdinalMarkers() {
        let source = "1. First step\n2. Second step"
        let visible = String(MessageMarkdown.attributed(source).characters)

        XCTAssertTrue(visible.contains("1. First step"), visible)
        XCTAssertTrue(visible.contains("2. Second step"), visible)
    }

    func testHeaderFormattingKeepsInlineEmphasisAndReplyPrefixStaysPlain() {
        let heading = MessageMarkdown.attributed("# A *lean* heading")
        let headingText = String(heading.characters)
        XCTAssertTrue(headingText.contains("A lean heading"), headingText)
        XCTAssertFalse(headingText.contains("#"), headingText)
        XCTAssertTrue(heading.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertTrue(heading.runs.contains {
            $0.inlinePresentationIntent?.contains(.emphasized) == true
        })

        let reply = MessageMarkdown.attributed("> The *earlier* point", prefixedBy: "Replying to: ")
        let replyText = String(reply.characters)
        XCTAssertTrue(replyText.contains("Replying to: ▏ The earlier point"), replyText)
    }

    func testBareWebLinkRemainsVisibleAndTappable() throws {
        let rendered = MessageMarkdown.attributed("Read https://example.com/guide before continuing.")
        let visible = String(rendered.characters)
        XCTAssertTrue(visible.contains("https://example.com/guide"), visible)
        XCTAssertEqual(try XCTUnwrap(rendered.runs.first { $0.link != nil }).link,
                       URL(string: "https://example.com/guide"))
    }

    func testCompactPreviewTruncatesParsedTextAndRetainsLinkAndEmphasis() throws {
        let rendered = MessageMarkdown.preview(
            "A **bold** [link](https://example.com) followed by more authored words.",
            characterLimit: 11)
        let visible = String(rendered.characters)

        XCTAssertEqual(visible, "A bold link…")
        XCTAssertTrue(rendered.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertEqual(try XCTUnwrap(rendered.runs.first { $0.link != nil }).link,
                       URL(string: "https://example.com"))
    }

    func testCompactPreviewFallsBackToGeneratedSummaryOnlyForPlainAuthoredText() throws {
        let plain = MessageMarkdown.compactPreview(
            authored: "A plain authored message with several details.",
            generatedSummary: "A concise summary.",
            characterLimit: 100)
        XCTAssertEqual(String(plain.characters), "A concise summary.")

        let formatted = MessageMarkdown.compactPreview(
            authored: "A **bold** [link](https://example.com) with details.",
            generatedSummary: "A concise summary.",
            characterLimit: 100)
        XCTAssertEqual(String(formatted.characters), "A bold link with details.")
        XCTAssertTrue(formatted.runs.contains { $0.link != nil })
        XCTAssertTrue(formatted.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
    }

    func testFormattedTextAndLinksMustUseTheAuthoredPreview() {
        XCTAssertTrue(MessageMarkdown.hasFormattingOrLinks("A **bold** message."))
        XCTAssertTrue(MessageMarkdown.hasFormattingOrLinks("[Open](https://example.com)"))
        XCTAssertTrue(MessageMarkdown.hasFormattingOrLinks("Read https://example.com"))
        XCTAssertTrue(MessageMarkdown.hasFormattingOrLinks("- First item"))
        XCTAssertTrue(MessageMarkdown.hasFormattingOrLinks("> Quoted text"))
        XCTAssertTrue(MessageMarkdown.hasFormattingOrLinks("`let count = 2`"))
    }
}
