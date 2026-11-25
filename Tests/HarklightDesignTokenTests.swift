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

    func testWireTypeAndKindChooseTheMessageType() {
        func type(_ declared: MessageTypeValue?, _ kind: MessageKindValue?, seen: Bool = false) -> HarklightMessageType {
            HarklightMessageType(declaredType: declared, kind: kind, hasSeenDescriptor: seen)
        }
        XCTAssertEqual(type(.request, nil), .request)
        XCTAssertEqual(type(.request, .blocker), .error)
        XCTAssertEqual(type(.request, .success), .request)
        XCTAssertEqual(type(.fyi, nil), .info)
        XCTAssertEqual(type(.fyi, .success), .done)
        XCTAssertEqual(type(.fyi, .blocker), .warning)
        XCTAssertEqual(type(.request, nil, seen: true), .request,
                       "A declared type wins over the legacy Seen descriptor.")
        XCTAssertEqual(type(nil, nil, seen: true), .info)
        XCTAssertEqual(type(nil, nil), .request)

        let blockerRow = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("design"), senderID: ExactText("sender"),
                            messageID: ExactText("blocker")),
            title: "Blocked", sender: "Sender", status: "",
            declaredMessageType: .fyi, declaredMessageKind: .blocker)
        XCTAssertEqual(blockerRow.resolvedMessageType, .warning)
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

    func testSharedLayoutTokensPreserveTheAppMetrics() {
        let expected: [HarklightShape: CGFloat] = [
            .answeredCardPadding: 16,
            .answeredCardStackSpacing: 8,
            .answeredCardSymbolGap: 12,
            .answeredCardSymbolSize: 18,
            .answeredCardSymbolWidth: 22,
            .brandEmptyDetailWidth: 190,
            .brandHeaderStatusGap: 8,
            .brandHeaderWidth: 128,
            .brandPromptGap: 16,
            .choiceCheckboxRadius: 4,
            .choiceListSpacing: 10,
            .choiceMarkBaselineOffset: 6,
            .choiceMarkGap: 16,
            .choiceMarkSize: 20,
            .choiceMarkStroke: 1.5,
            .choicePadding: 16,
            .choicePickedRadioStroke: 6,
            .choiceSuggestedGap: 8,
            .choiceTextStackSpacing: 4,
            .fyiDigestBadgeGap: 8,
            .fyiDigestBadgeHorizontalPadding: 7,
            .fyiDigestBadgeVerticalPadding: 2,
            .fyiDigestBottomInset: 10,
            .fyiDigestDisclosureSize: 18,
            .fyiDigestDisclosureSymbolSize: 9,
            .fyiDigestHeaderGap: 8,
            .fyiDigestHorizontalInset: 12,
            .fyiDigestPadding: 16,
            .fyiDigestRadius: 12,
            .fyiDigestStackSpacing: 6,
            .fyiDigestStackedBadgeGap: 4,
            .fyiDigestTopInset: 6,
            .fyiListBylineGap: 8,
            .fyiListHeadingStackSpacing: 6,
            .fyiListInitialsTextSize: 10.5,
            .fyiListRowSpacing: 8,
            .fyiListSortLabelGap: 4,
            .fyiListStatusVerticalPadding: 6,
            .fyiListTitleSymbolGap: 8,
            .fyiListTitleSymbolSize: 17,
            .replyBorderDashLength: 4,
            .replyBorderDashGap: 3,
            .replyEditorHorizontalPadding: 12,
            .replyEditorVerticalPadding: 10,
            .replyFailureGap: 16,
            .replyFailureHorizontalPadding: 16,
            .replyFailureSymbolSize: 18,
            .replyFailureVerticalPadding: 12,
            .replyHeaderPaneGap: 0,
            .replySavedHorizontalPadding: 16,
            .replySavedVerticalPadding: 14,
            .rowActionGlyphSize: 15,
            .rowActionGlyphStroke: 1.1,
            .rowActionTileRadius: 7,
            .rowActionTileSize: 23,
            .rowBylineGap: 8,
            .rowContentSpacing: 6,
            .rowDueTimeGap: 4,
            .rowInitialsTextSize: 10.5,
            .rowLeadingAccessoryGap: 6,
            .rowLegacyTypeColumnGap: 12,
            .rowLegacyTypeColumnWidth: 26,
            .rowPriorityDueGap: 4,
            .rowPriorityFlagGap: 6,
            .rowPriorityFlagSize: 12,
            .rowStackSpacing: 6,
            .rowStatusFrameSize: 16,
            .rowStatusSymbolSize: 14,
            .rowSubmissionFailureSymbolSize: 14,
            .rowTimeMinimumGap: 4,
            .rowTitleStatusGap: 8,
            .rowTypeBaselineOffset: 6,
            .rowTypeColumnGap: 8,
            .rowTypeColumnWidth: 23,
            .rowTypeSymbolSize: 17,
        ]
        for (role, value) in expected {
            XCTAssertEqual(HarklightDesignSystem.shape(role), value, role.rawValue)
        }
    }

    func testSharedFillAndTypeTokensPreserveTheAppMetrics() throws {
        let source = HarklightDesignSystem.source
        for appearance in [source.light, source.dark] {
            XCTAssertEqual(appearance.derived.openRowFillShare, 0.15)
            XCTAssertEqual(appearance.derived.openRowBarShare, 0.55)
            XCTAssertEqual(appearance.derived.pickedFillShare, 0.09)
        }
        let preview = source.type.token(for: .fyiDigestPreview)
        XCTAssertEqual(preview.face, .system)
        XCTAssertEqual(preview.size, 15)
        XCTAssertEqual(preview.weight, 400)
        XCTAssertNil(preview.tracking)
        XCTAssertEqual(preview.relativeTo, .subheadline)
        XCTAssertNil(preview.lineHeight)
        XCTAssertNil(source.type.token(for: .choiceTitle).lineHeight)
        XCTAssertNil(source.type.token(for: .choiceDetail).lineHeight)

        let url = try XCTUnwrap(Bundle.main.url(forResource: "tokens", withExtension: "json")
            ?? Bundle.main.url(forResource: "tokens", withExtension: "json", subdirectory: "Design"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let type = try XCTUnwrap(json["type"] as? [String: Any])
        let styles = try XCTUnwrap(type["styles"] as? [String: [String: Any]])
        let roles: [HarklightTextStyle] = [.fyiDigestPreview, .choiceTitle, .choiceDetail]
        for role in roles {
            let style = try XCTUnwrap(styles[role.rawValue], role.rawValue)
            XCTAssertTrue(style["lineHeight"] is NSNull, "\(role.rawValue).lineHeight must be explicitly null")
        }
    }

    func testHeadingFontIsBundled() {
        XCTAssertNotNil(Bundle.main.url(forResource: "Fraunces", withExtension: "ttf"))
        let title = HarklightTypography.resolve(.messageTitle)
        XCTAssertTrue(title.font.familyName.contains("Fraunces"), title.font.familyName)
        XCTAssertEqual(title.font.pointSize, 28, accuracy: 0.5)
    }

    func testMessageIDPillUsesSharedCapsuleGeometryAndScalableMonospacedType() {
        XCTAssertEqual(HarklightDesignSystem.shape(.messageIDPillHorizontalPadding), 8)
        XCTAssertEqual(HarklightDesignSystem.shape(.messageIDPillVerticalPadding), 4)
        XCTAssertEqual(HarklightDesignSystem.shape(.messageIDPillRadius), 999)
        let regular = HarklightTypography.resolve(.messageIDPill)
        let larger = HarklightTypography.resolve(.messageIDPill, dynamicTypeSize: .accessibility1)
        XCTAssertTrue(regular.font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertGreaterThan(larger.font.pointSize, regular.font.pointSize)
    }
}
