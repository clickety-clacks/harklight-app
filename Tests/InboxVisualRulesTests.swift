import Foundation
import XCTest
@testable import AttentionClientDuoPrototype
import AttentionDomain

final class InboxVisualRulesTests: XCTestCase {
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
