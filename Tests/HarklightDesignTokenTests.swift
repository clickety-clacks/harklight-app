import XCTest
@testable import Harklight
import AttentionDomain

final class HarklightDesignTokenTests: XCTestCase {
    func testSampleKindsMapToTheirDesignedMessageTypes() {
        XCTAssertEqual(SampleKind.error.designMessageType, .error)
        XCTAssertEqual(SampleKind.warning.designMessageType, .warning)
        XCTAssertEqual(SampleKind.information.designMessageType, .info)
        XCTAssertEqual(SampleKind.completed.designMessageType, .done)
        XCTAssertEqual(SampleKind.approval.designMessageType, .request)
    }

    func testMessagePaletteComesFromTypeRatherThanRowImportance() {
        let emphasisValues: [InboxRowEmphasis] = [.standard, .error, .warning, .completed]
        for (index, emphasis) in emphasisValues.enumerated() {
            let row = InboxRequestRow(
                key: RequestKey(accountScope: ExactText("design"), senderID: ExactText("sender"),
                                messageID: ExactText("emphasis-\(index)")),
                title: "Example", sender: "Sender", status: "", emphasis: emphasis)
            XCTAssertEqual(row.resolvedMessageType, .request)
        }

        let informationalRow = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("design"), senderID: ExactText("sender"),
                            messageID: ExactText("information")),
            title: "Information", sender: "Sender", status: "",
            informationalSeenStatus: .available, emphasis: .error)
        XCTAssertEqual(informationalRow.resolvedMessageType, .info)
    }

    func testEveryMessageTypeHasReadableLightAndDarkPaletteTokens() {
        let source = HarklightDesignSystem.source
        let expectedTypes = Set(HarklightMessageType.allCases.map(\.rawValue))
        XCTAssertEqual(Set(source.light.types.keys), expectedTypes)
        XCTAssertEqual(Set(source.dark.types.keys), expectedTypes)

        for appearance in [source.light, source.dark] {
            let solidColors = [
                appearance.neutral.bg, appearance.neutral.text, appearance.neutral.text2,
                appearance.neutral.separator, appearance.neutral.replySurface,
                appearance.accent.accent, appearance.accent.onAccent, appearance.accent.seen,
            ]
            for color in solidColors {
                XCTAssertNotEqual(color.uppercased(), "#FFFFFF", "Palette contains pure white.")
                XCTAssertNotEqual(color.uppercased(), "#000000", "Palette contains pure black.")
            }

            for type in HarklightMessageType.allCases {
                guard let tokens = appearance.types[type.rawValue] else {
                    XCTFail("Missing palette for \(type.rawValue).")
                    continue
                }
                XCTAssertGreaterThan(contrastRatio(foreground: tokens.text, background: tokens.background),
                                     4.5, "\(type.rawValue) primary text misses the approved contrast ratio.")
                XCTAssertGreaterThan(contrastRatio(foreground: tokens.secondaryText, background: tokens.background),
                                     4.5, "\(type.rawValue) secondary text misses the approved contrast ratio.")
                for value in [tokens.background, tokens.text, tokens.secondaryText,
                              tokens.listIcon, tokens.cameBackBar] {
                    XCTAssertNotEqual(value.uppercased(), "#FFFFFF",
                                      "\(type.rawValue) contains pure white.")
                    XCTAssertNotEqual(value.uppercased(), "#000000",
                                      "\(type.rawValue) contains pure black.")
                }
            }
        }
    }

    private func contrastRatio(foreground: String, background: String) -> Double {
        let foregroundLuminance = luminance(foreground)
        let backgroundLuminance = luminance(background)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05) /
            (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private func luminance(_ token: String) -> Double {
        guard token.hasPrefix("#"), let value = UInt32(token.dropFirst(), radix: 16) else {
            XCTFail("Expected a hex color token, got \(token).")
            return 0
        }
        let components = [
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255,
        ].map { component in
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
    }
}
