import Foundation
import XCTest
@testable import Harklight
import AttentionDomain
import SwiftUI

final class InboxVisualRulesTests: XCTestCase {
    func testServerPriorityUsesPlainLanguageLabelsAndOmitsNormal() {
        func renderedLabel(for priority: InboxMessagePriority) -> String? {
            guard let display = InboxPriorityDisplay.label(for: priority) else { return nil }
            return String(localized: display.title)
        }

        XCTAssertEqual(renderedLabel(for: .now), "Urgent")
        XCTAssertEqual(renderedLabel(for: .high), "High priority")
        XCTAssertEqual(renderedLabel(for: .low), "Low priority")
        XCTAssertNil(renderedLabel(for: .normal))
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

    func testWashedPriorityRowsUseModeSpecificColorsAndEmphasizeNow() throws {
        let lightHigh = try XCTUnwrap(
            InboxPriorityRowTreatment.forPriority(.high, colorScheme: .light))
        XCTAssertEqual(lightHigh.topHex, "#73592A")
        XCTAssertEqual(lightHigh.bottomHex, "#5E4720")
        XCTAssertEqual(lightHigh.primaryTextHex, "#F6F1E7")
        XCTAssertEqual(lightHigh.secondaryTextHex, "#E3DCCF")
        XCTAssertNil(lightHigh.leadingBandHex)

        let lightNow = try XCTUnwrap(
            InboxPriorityRowTreatment.forPriority(.now, colorScheme: .light))
        XCTAssertEqual(lightNow.topHex, "#A63A2A")
        XCTAssertEqual(lightNow.bottomHex, "#8A2C1E")
        XCTAssertEqual(lightNow.primaryTextHex, "#F6F1E7")
        XCTAssertEqual(lightNow.secondaryTextHex, "#E3DCCF")
        XCTAssertEqual(lightNow.leadingBandHex, "#5A1A10")

        let darkHigh = try XCTUnwrap(
            InboxPriorityRowTreatment.forPriority(.high, colorScheme: .dark))
        XCTAssertEqual(darkHigh.topHex, "#3A3119")
        XCTAssertEqual(darkHigh.bottomHex, "#2B2516")
        XCTAssertEqual(darkHigh.primaryTextHex, "#E6D9B8")
        XCTAssertEqual(darkHigh.secondaryTextHex, "#AEA283")
        XCTAssertNil(darkHigh.leadingBandHex)

        let darkNow = try XCTUnwrap(
            InboxPriorityRowTreatment.forPriority(.now, colorScheme: .dark))
        XCTAssertEqual(darkNow.topHex, "#5A2219")
        XCTAssertEqual(darkNow.bottomHex, "#3A1A14")
        XCTAssertEqual(darkNow.primaryTextHex, "#F2C9BE")
        XCTAssertEqual(darkNow.secondaryTextHex, "#C0948A")
        XCTAssertEqual(darkNow.leadingBandHex, "#EE8B75")

        for treatment in [lightHigh, lightNow, darkHigh, darkNow] {
            XCTAssertEqual(treatment.capsuleFillHex, treatment.primaryTextHex)
            XCTAssertEqual(treatment.capsuleTextHex, treatment.topHex)
            XCTAssertEqual(treatment.initialsFillOpacity, 0.18)
        }
        XCTAssertNil(InboxPriorityRowTreatment.forPriority(.normal, colorScheme: .light))
        XCTAssertNil(InboxPriorityRowTreatment.forPriority(.low, colorScheme: .dark))
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
