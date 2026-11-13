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

    func testEveryMessageTypeHasATintInBothAppearances() {
        let expectedTypes = Set(HarklightMessageType.allCases.map(\.rawValue))
        XCTAssertEqual(Set(HarklightDesignSystem.source.light.derived.typeTint.keys), expectedTypes)
        XCTAssertEqual(Set(HarklightDesignSystem.source.dark.derived.typeTint.keys), expectedTypes)
        XCTAssertEqual(HarklightDesignSystem.source.light.typeTintToken(.request), "#DDDDF7")
        XCTAssertEqual(HarklightDesignSystem.source.dark.typeTintToken(.request), "#131527")
    }

    func testDarkSmallLabelsUseTheReadableGray() {
        // Client PO ruling: dark "Delivered" and every dark small label use #9aa4b8.
        XCTAssertEqual(HarklightDesignSystem.source.dark.color.label, "#9AA4B8")
        XCTAssertEqual(HarklightDesignSystem.source.light.color.label, "#4F5A6E")
    }

    func testTextMeetsContrastOnEverySurfaceItSits() {
        for appearance in [HarklightDesignSystem.source.light, HarklightDesignSystem.source.dark] {
            let background = HarklightRGBA(token: appearance.color.background)
            let panel = HarklightRGBA(token: appearance.color.panel)
            var surfaces = [background, panel]
            for overlay in [appearance.color.raised, appearance.color.group] {
                let token = HarklightRGBA(token: overlay)
                surfaces.append(token.mixed(token.alpha, over: background))
                surfaces.append(token.mixed(token.alpha, over: panel))
            }
            for type in HarklightMessageType.allCases {
                surfaces.append(HarklightRGBA(token: appearance.typeTintToken(type)))
            }
            for surface in surfaces {
                for text in [appearance.color.text, appearance.color.secondary, appearance.color.label] {
                    XCTAssertGreaterThanOrEqual(HarklightRGBA.contrast(HarklightRGBA(token: text), surface), 4.5,
                                                "\(text) on \(surface)")
                }
            }
            for type in HarklightMessageType.allCases {
                let beam = HarklightRGBA(token: appearance.typeColorToken(type))
                XCTAssertGreaterThanOrEqual(HarklightRGBA.contrast(beam, background), 4.5, "\(type) beam")
                XCTAssertGreaterThanOrEqual(
                    HarklightRGBA.contrast(beam, HarklightRGBA(token: appearance.typeTintToken(type))), 4.5,
                    "\(type) beam on its tint")
                XCTAssertGreaterThanOrEqual(
                    HarklightRGBA.contrast(HarklightRGBA(token: appearance.color.onBeam), beam), 4.5,
                    "\(type) on-beam text")
            }
            XCTAssertGreaterThanOrEqual(HarklightRGBA.contrast(HarklightRGBA(token: appearance.color.onInverse),
                                                               HarklightRGBA(token: appearance.color.inverse)), 4.5)
            XCTAssertGreaterThanOrEqual(HarklightRGBA.contrast(HarklightRGBA(token: appearance.color.onAccent),
                                                               HarklightRGBA(token: appearance.color.accentFill)), 4.5)
        }
    }

    func testHeadingFontIsBundled() {
        XCTAssertNotNil(Bundle.main.url(forResource: "Fraunces", withExtension: "ttf"))
        let title = HarklightTypography.resolve(.messageTitle)
        XCTAssertTrue(title.font.familyName.contains("Fraunces"), title.font.familyName)
        XCTAssertEqual(title.font.pointSize, 28, accuracy: 0.5)
    }
}
