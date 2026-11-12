import Foundation
import XCTest
@testable import Harklight
import AttentionDomain
import SwiftUI

final class InboxVisualRulesTests: XCTestCase {
    func testAbsoluteScoreUsesExistingPlainLanguageLabelsAndOmitsNormal() {
        func renderedLabel(for score: Double?) -> String? {
            guard let display = InboxPriorityDisplay.forScore(score) else { return nil }
            return String(localized: display.title)
        }

        XCTAssertEqual(renderedLabel(for: 0.10), "Low priority")
        XCTAssertNil(renderedLabel(for: 0.50))
        XCTAssertEqual(renderedLabel(for: 0.75), "High priority")
        XCTAssertEqual(renderedLabel(for: 0.95), "Urgent")
    }

    func testAbsoluteScoreMappingUsesExactThresholdsAndRejectsUnusableValues() {
        XCTAssertEqual(InboxPriorityDisplay.forScore(0.0), .low)
        XCTAssertEqual(InboxPriorityDisplay.forScore(0.249_999), .low)
        XCTAssertNil(InboxPriorityDisplay.forScore(0.25))
        XCTAssertNil(InboxPriorityDisplay.forScore(0.699_999))
        XCTAssertEqual(InboxPriorityDisplay.forScore(0.70), .high)
        XCTAssertEqual(InboxPriorityDisplay.forScore(0.899_999), .high)
        XCTAssertEqual(InboxPriorityDisplay.forScore(0.90), .urgent)
        XCTAssertEqual(InboxPriorityDisplay.forScore(1.0), .urgent)

        XCTAssertNil(InboxPriorityDisplay.forScore(nil))
        XCTAssertNil(InboxPriorityDisplay.forScore(-0.001))
        XCTAssertNil(InboxPriorityDisplay.forScore(1.001))
        XCTAssertNil(InboxPriorityDisplay.forScore(.nan))
        XCTAssertNil(InboxPriorityDisplay.forScore(.infinity))
    }

    func testExplicitTiersCapBodyAtEightFourAndTwoLines() {
        XCTAssertEqual(InboxAttentionTier.top.bodyLineLimit, 8)
        XCTAssertEqual(InboxAttentionTier.middle.bodyLineLimit, 4)
        XCTAssertEqual(InboxAttentionTier.low.bodyLineLimit, 2)
    }

    func testServerTierSelectsItsMatchingInboxRowStyle() {
        XCTAssertEqual(AttentionTier.top.inboxRowStyleTier, .top)
        XCTAssertEqual(AttentionTier.middle.inboxRowStyleTier, .middle)
        XCTAssertEqual(AttentionTier.low.inboxRowStyleTier, .low)
    }

    func testWashedPriorityRowsRetainModeSpecificColors() throws {
        let lightHigh = try XCTUnwrap(
            InboxPriorityRowTreatment.forLevel(.high, colorScheme: .light))
        XCTAssertEqual(lightHigh.topHex, "#73592A")
        XCTAssertEqual(lightHigh.bottomHex, "#5E4720")
        XCTAssertEqual(lightHigh.primaryTextHex, "#F6F1E7")
        XCTAssertEqual(lightHigh.secondaryTextHex, "#E3DCCF")

        let lightNow = try XCTUnwrap(
            InboxPriorityRowTreatment.forLevel(.urgent, colorScheme: .light))
        XCTAssertEqual(lightNow.topHex, "#A63A2A")
        XCTAssertEqual(lightNow.bottomHex, "#8A2C1E")
        XCTAssertEqual(lightNow.primaryTextHex, "#F6F1E7")
        XCTAssertEqual(lightNow.secondaryTextHex, "#E3DCCF")

        let darkHigh = try XCTUnwrap(
            InboxPriorityRowTreatment.forLevel(.high, colorScheme: .dark))
        XCTAssertEqual(darkHigh.topHex, "#3A3119")
        XCTAssertEqual(darkHigh.bottomHex, "#2B2516")
        XCTAssertEqual(darkHigh.primaryTextHex, "#E6D9B8")
        XCTAssertEqual(darkHigh.secondaryTextHex, "#AEA283")

        let darkNow = try XCTUnwrap(
            InboxPriorityRowTreatment.forLevel(.urgent, colorScheme: .dark))
        XCTAssertEqual(darkNow.topHex, "#5A2219")
        XCTAssertEqual(darkNow.bottomHex, "#3A1A14")
        XCTAssertEqual(darkNow.primaryTextHex, "#F2C9BE")
        XCTAssertEqual(darkNow.secondaryTextHex, "#C0948A")

        for treatment in [lightHigh, lightNow, darkHigh, darkNow] {
            XCTAssertEqual(treatment.initialsFillOpacity, 0.18)
        }
        XCTAssertNil(InboxPriorityRowTreatment.forLevel(nil, colorScheme: .light))
        XCTAssertNil(InboxPriorityRowTreatment.forLevel(.low, colorScheme: .dark))
    }

    func testLightSelectedRowColorsAppearOnlyOverTheProminentSelectionFill() {
        XCTAssertTrue(InboxSelectedRowTextRule.usesSelectionFillColors(
            selected: true, backgroundProminence: .increased))
        XCTAssertFalse(InboxSelectedRowTextRule.usesSelectionFillColors(
            selected: true, backgroundProminence: .standard),
                       "A selected row without the tinted fill must keep its regular readable colors.")
        XCTAssertFalse(InboxSelectedRowTextRule.usesSelectionFillColors(
            selected: false, backgroundProminence: .increased))
        XCTAssertFalse(InboxSelectedRowTextRule.usesSelectionFillColors(
            selected: false, backgroundProminence: .standard))
    }

    func testSelectedRowBarUsesPickedSizeAndBrighterRowColorsInBothAppearances() {
        XCTAssertEqual(InboxRowSelectionDecoration.barWidth, 8)
        XCTAssertEqual(InboxRowSelectionDecoration.contentInset, 16)

        XCTAssertEqual(InboxRowSelectionDecoration.forLevel(nil, colorScheme: .light).barHex,
                       "#B3A389")
        XCTAssertEqual(InboxRowSelectionDecoration.forLevel(.high, colorScheme: .light).barHex,
                       "#C29747")
        XCTAssertEqual(InboxRowSelectionDecoration.forLevel(.urgent, colorScheme: .light).barHex,
                       "#D86B5A")

        XCTAssertEqual(InboxRowSelectionDecoration.forLevel(nil, colorScheme: .dark).barHex,
                       "#756B61")
        XCTAssertEqual(InboxRowSelectionDecoration.forLevel(.high, colorScheme: .dark).barHex,
                       "#917A3B")
        XCTAssertEqual(InboxRowSelectionDecoration.forLevel(.urgent, colorScheme: .dark).barHex,
                       "#B94331")
    }

    func testNewMessageAreaUsesQuietBlockAndSolidHighOrUrgentPills() {
        XCTAssertEqual(NewMessageAreaSurface.forScheme(.light).quietTitleHex, "#8A847A")
        XCTAssertEqual(NewMessageAreaSurface.forScheme(.light).separatorHex,
                       "rgba(49,48,45,0.08)")
        XCTAssertEqual(NewMessageAreaSurface.forScheme(.dark).quietTitleHex, "#726E67")
        XCTAssertEqual(NewMessageAreaSurface.forScheme(.dark).separatorHex,
                       "rgba(221,217,209,0.08)")

        XCTAssertEqual(NewMessageAreaPriorityTreatment.forLevel(.high, colorScheme: .light),
                       NewMessageAreaPriorityTreatment(capsuleFillHex: "#73592A",
                                                       capsuleTextHex: "#F6F1E7"))
        XCTAssertEqual(NewMessageAreaPriorityTreatment.forLevel(.urgent, colorScheme: .light),
                       NewMessageAreaPriorityTreatment(capsuleFillHex: "#A63A2A",
                                                       capsuleTextHex: "#F6F1E7"))
        XCTAssertEqual(NewMessageAreaPriorityTreatment.forLevel(.high, colorScheme: .dark),
                       NewMessageAreaPriorityTreatment(capsuleFillHex: "#7B6832",
                                                       capsuleTextHex: "#F6F1E7"))
        XCTAssertEqual(NewMessageAreaPriorityTreatment.forLevel(.urgent, colorScheme: .dark),
                       NewMessageAreaPriorityTreatment(capsuleFillHex: "#B94331",
                                                       capsuleTextHex: "#F6F1E7"))
        XCTAssertNil(NewMessageAreaPriorityTreatment.forLevel(.low, colorScheme: .light))
        XCTAssertNil(NewMessageAreaPriorityTreatment.forLevel(nil, colorScheme: .dark))
    }

    func testLiveInboxLabelsMeetContrastOnTheirApprovedSurfaces() throws {
        let source = HarklightDesignSystem.source

        for (appearanceName, appearance) in [("light", source.light), ("dark", source.dark)] {
            let neutralText = try XCTUnwrap(rgb(appearance.neutral.text))
            let rowTop = try XCTUnwrap(rgb(appearance.neutral.rowTop))
            let accent = try XCTUnwrap(rgb(appearance.accent.accent))
            let background = try XCTUnwrap(rgb(appearance.neutral.bg))
            let refreshingWash = composite(accent, over: background, opacity: 0.14)

            XCTAssertGreaterThanOrEqual(
                contrastRatio(foreground: neutralText, background: rowTop), 4.5,
                "\(appearanceName) More/Less text must pass on rowTop.")
            XCTAssertGreaterThanOrEqual(
                contrastRatio(foreground: neutralText, background: refreshingWash), 4.5,
                "\(appearanceName) Refreshing text must pass on its accent wash.")
        }
    }

    func testDuePhrasePresentationSplitsBetweenDayAndTimeButKeepsOneAccessiblePhrase() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19,
                                                    hour: 14, minute: 0))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20,
                                                         hour: 9, minute: 0))!

        let presentation = InboxDuePhrase.presentation(
            for: Int(tomorrow.timeIntervalSince1970 * 1_000),
            now: now, calendar: calendar, locale: locale)
        let normalizedTimeLine = presentation.timeLine
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let normalizedAccessibilityLabel = presentation.accessibilityLabel
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        XCTAssertEqual(presentation.dayLine, "Due tomorrow")
        XCTAssertEqual(normalizedTimeLine, "at 9:00 AM")
        XCTAssertEqual(normalizedAccessibilityLabel, "Due tomorrow at 9:00 AM")
    }

    func testSenderLabelUsesLastKindAndAgentSegment() {
        XCTAssertEqual(InboxSenderDisplay.name(for: "fixture:Facilities"), "Facilities")
        XCTAssertEqual(InboxSenderDisplay.name(for: "app:tightbeam-harklight-0.1"), "tightbeam-harklight-0.1")
        XCTAssertEqual(InboxSenderDisplay.name(for: "app:tightbeam/harklight-pdo"), "harklight-pdo")
        XCTAssertEqual(InboxSenderDisplay.name(for: "app:"), "app:")
        XCTAssertEqual(InboxSenderDisplay.name(for: "Planning assistant"), "Planning assistant")
    }

    func testFriendlyDateUsesTimeYesterdayWeekdayAndShortDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        func date(_ day: Int, hour: Int = 9, minute: Int = 41) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day,
                                               hour: hour, minute: minute))!
        }
        let now = date(19, hour: 14)
        let todayLabel = InboxFriendlyDate.label(for: date(19), now: now,
                                                  calendar: calendar, locale: locale)
        let normalizedTodayLabel = todayLabel
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        XCTAssertEqual(normalizedTodayLabel, "9:41 AM")
        XCTAssertEqual(InboxFriendlyDate.label(for: date(18), now: now,
                                                calendar: calendar, locale: locale), "Yesterday")
        XCTAssertEqual(InboxFriendlyDate.label(for: date(15), now: now,
                                                calendar: calendar, locale: locale), "Thursday")
        XCTAssertEqual(InboxFriendlyDate.label(for: date(7), now: now,
                                                calendar: calendar, locale: locale), "10/7/26")
    }

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    private func rgb(_ token: String) -> RGB? {
        guard token.hasPrefix("#"), let value = UInt32(token.dropFirst(), radix: 16) else {
            return nil
        }
        return RGB(red: Double((value >> 16) & 0xFF) / 255,
                   green: Double((value >> 8) & 0xFF) / 255,
                   blue: Double(value & 0xFF) / 255)
    }

    private func composite(_ foreground: RGB, over background: RGB, opacity: Double) -> RGB {
        RGB(red: foreground.red * opacity + background.red * (1 - opacity),
            green: foreground.green * opacity + background.green * (1 - opacity),
            blue: foreground.blue * opacity + background.blue * (1 - opacity))
    }

    private func contrastRatio(foreground: RGB, background: RGB) -> Double {
        let foregroundLuminance = luminance(foreground)
        let backgroundLuminance = luminance(background)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05) /
            (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private func luminance(_ color: RGB) -> Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return linearize(color.red) * 0.2126 +
            linearize(color.green) * 0.7152 +
            linearize(color.blue) * 0.0722
    }
}
