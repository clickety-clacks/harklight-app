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

    func testServerTierSelectsItsMatchingInboxRowStyle() {
        XCTAssertEqual(AttentionTier.top.inboxRowStyleTier, .top)
        XCTAssertEqual(AttentionTier.middle.inboxRowStyleTier, .middle)
        XCTAssertEqual(AttentionTier.low.inboxRowStyleTier, .low)
    }

    func testUrgentAndHighRowsTakeTheirWashAndLeadingEdgeInEachAppearance() throws {
        let darkUrgent = try XCTUnwrap(InboxPriorityRowTreatment.forLevel(.urgent, colorScheme: .dark))
        XCTAssertEqual(darkUrgent, InboxPriorityRowTreatment(washHex: "#2F1F20", edgeHex: "#FF8A5C"))
        let darkHigh = try XCTUnwrap(InboxPriorityRowTreatment.forLevel(.high, colorScheme: .dark))
        XCTAssertEqual(darkHigh, InboxPriorityRowTreatment(washHex: "#25221C", edgeHex: "#FFC857"))
        let lightUrgent = try XCTUnwrap(InboxPriorityRowTreatment.forLevel(.urgent, colorScheme: .light))
        XCTAssertEqual(lightUrgent, InboxPriorityRowTreatment(washHex: "#EED5D0", edgeHex: "#A13811"))
        let lightHigh = try XCTUnwrap(InboxPriorityRowTreatment.forLevel(.high, colorScheme: .light))
        XCTAssertEqual(lightHigh, InboxPriorityRowTreatment(washHex: "#EFE3CC", edgeHex: "#7D5100"))
        XCTAssertNil(InboxPriorityRowTreatment.forLevel(nil, colorScheme: .light))
        XCTAssertNil(InboxPriorityRowTreatment.forLevel(.low, colorScheme: .dark))
        XCTAssertEqual(HarklightDesignSystem.shape(.priorityEdge), 2)
    }

    func testIPadOpenRowUsesAnEightPointBarAndSixteenPointIndent() {
        XCTAssertEqual(InboxRowSelectionDecoration.barWidth, 8)
        XCTAssertEqual(InboxRowSelectionDecoration.contentInset, 16)
        // The bar is the type color at 55 percent over the page background.
        let palette = HarklightDesignSystem.source.dark
        let expected = HarklightRGBA(token: "#9D8CFF").mixed(0.55, over: HarklightRGBA(token: "#070B14"))
        XCTAssertEqual(palette.typeColorToken(.request), "#9D8CFF")
        XCTAssertEqual(expected.red, 0.55 * 0x9D / 255 + 0.45 * 0x07 / 255, accuracy: 0.0001)
    }

    func testNewSectionPriorityLabelsAreReversedOnCoralAndAmber() {
        XCTAssertEqual(NewMessageAreaPriorityTreatment.forLevel(.urgent, colorScheme: .dark),
                       NewMessageAreaPriorityTreatment(capsuleFillHex: "#FF8A5C", capsuleTextHex: "#070B14"))
        XCTAssertEqual(NewMessageAreaPriorityTreatment.forLevel(.high, colorScheme: .dark),
                       NewMessageAreaPriorityTreatment(capsuleFillHex: "#FFC857", capsuleTextHex: "#070B14"))
        XCTAssertEqual(NewMessageAreaPriorityTreatment.forLevel(.urgent, colorScheme: .light),
                       NewMessageAreaPriorityTreatment(capsuleFillHex: "#A13811", capsuleTextHex: "#FFFFFF"))
        XCTAssertEqual(NewMessageAreaPriorityTreatment.forLevel(.high, colorScheme: .light),
                       NewMessageAreaPriorityTreatment(capsuleFillHex: "#7D5100", capsuleTextHex: "#FFFFFF"))
        XCTAssertNil(NewMessageAreaPriorityTreatment.forLevel(.low, colorScheme: .light))
        XCTAssertNil(NewMessageAreaPriorityTreatment.forLevel(nil, colorScheme: .dark))
    }

    func testRowLabelsMeetContrastOnPageAndPriorityWashes() {
        for appearance in [HarklightDesignSystem.source.light, HarklightDesignSystem.source.dark] {
            let surfaces = [appearance.color.background, appearance.derived.urgentWash,
                            appearance.derived.highWash]
            for surface in surfaces {
                for text in [appearance.color.text, appearance.color.secondary, appearance.color.label] {
                    XCTAssertGreaterThanOrEqual(
                        HarklightRGBA.contrast(HarklightRGBA(token: text), HarklightRGBA(token: surface)), 4.5,
                        "\(text) on \(surface)")
                }
            }
        }
    }

    func testOpenMessageDateReadsDayThenTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        func date(_ day: Int, hour: Int = 9, minute: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day,
                                               hour: hour, minute: minute))!
        }
        let now = date(19, hour: 14)
        func label(_ day: Int) -> String {
            InboxFriendlyDate.detailLabel(for: date(day), now: now, calendar: calendar, locale: locale)
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        XCTAssertEqual(label(19), "Today, 9:12 AM")
        XCTAssertEqual(label(18), "Yesterday, 9:12 AM")
        XCTAssertEqual(label(15), "Thursday, 9:12 AM")
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
}
