import Foundation
import XCTest
@testable import Harklight
import AttentionDomain
import SwiftUI

final class InboxVisualRulesTests: XCTestCase {
    func testFYIPostedSortUsesOriginalServerTimeInsteadOfUpdatedContent() {
        var later = fyiRow("later")
        later.fyiPostedAt = Date(timeIntervalSince1970: 200)
        later.createdAt = Date(timeIntervalSince1970: 10)
        later.fyiPriority = .low
        var earlier = fyiRow("earlier")
        earlier.fyiPostedAt = Date(timeIntervalSince1970: 100)
        earlier.createdAt = Date(timeIntervalSince1970: 400)
        earlier.fyiPriority = .high

        XCTAssertEqual(FYIOrder.posted.sorted([earlier, later]).map(\.key), [later.key, earlier.key])
        XCTAssertEqual(FYIOrder.priority.sorted([later, earlier]).map(\.key), [earlier.key, later.key])
    }

    func testFYISeenUsesExistingResponseStateAndKeepsConfirmedRows() {
        var item = fyiRow("item")
        item.informationalSeenStatus = .available
        item.canMarkSeen = true
        XCTAssertTrue(item.canMarkFYISeen)
        item.informationalSeenStatus = .pending
        item.canMarkSeen = false
        XCTAssertTrue(item.isUnseenFYI)
        XCTAssertFalse(item.canMarkFYISeen)
        item.informationalSeenStatus = .confirmed
        item.fyiServerSeen = false
        XCTAssertFalse(item.isUnseenFYI)
        XCTAssertEqual(FYIOrder.priority.sorted([item]).map(\.key), [item.key])
    }

    func testExplicitFYIWithoutResponseUsesOrdinaryNativeSeen() {
        var item = fyiRow("item")
        item.canReportFYISeen = true
        item.fyiServerSeen = false
        XCTAssertTrue(item.canMarkFYISeen)
        item.fyiServerSeen = true
        XCTAssertFalse(item.canMarkFYISeen)
        item.declaredMessageType = .request
        XCTAssertFalse(item.isFYI)
    }

    @MainActor
    func testNormalFYIsReachTheDigestModel() async {
        let rows = ["Garden", "Museum", "Station", "Library", "Market"].enumerated().map { index, title in
            var row = fyiRow(title)
            row.fyiPostedAt = Date(timeIntervalSince1970: TimeInterval(100 - index))
            return row
        }
        let highlights = FYIDigest.highlights(Array(rows.reversed()))
        XCTAssertEqual(highlights.map(\.key), rows.prefix(4).map(\.key))
        let digest = FYIDigest()
        var calls: [String] = []
        await digest.refresh(.init(highlights: highlights), using: { text, _ in
            calls.append(text)
            return "Garden reopened. Museum extended hours."
        })
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls.first?.contains("Garden") == true)
        XCTAssertTrue(calls.first?.contains("Museum") == true)
        XCTAssertEqual(digest.summary, "Garden reopened. Museum extended hours.")
    }

    @MainActor
    func testDigestPrefersUnseenAndRanksHighPriorityFirst() {
        var urgentSeen = fyiRow("Urgent seen")
        urgentSeen.fyiPriority = .now
        urgentSeen.fyiServerSeen = true
        var high = fyiRow("High")
        high.fyiPriority = .high
        var urgent = fyiRow("Urgent")
        urgent.fyiPriorityScore = 0.92
        var retracted = fyiRow("Retracted")
        retracted.fyiPriority = .now
        retracted.isRetracted = true
        let rows = [fyiRow("Normal"), high, urgentSeen, retracted, urgent]
        XCTAssertEqual(FYIDigest.highlights(rows).map(\.key), [urgent.key, high.key])
        XCTAssertEqual(FYIDigest.highlights([urgentSeen, fyiRow("Normal")]).map(\.key),
                       [fyiRow("Normal").key])
    }

    @MainActor
    func testDigestUsesSeenMessagesWhenNoneAreUnseen() {
        var high = fyiRow("High")
        high.fyiPriority = .high
        high.fyiServerSeen = true
        var urgent = fyiRow("Urgent")
        urgent.fyiPriority = .now
        urgent.fyiServerSeen = true
        XCTAssertEqual(FYIDigest.highlights([high, urgent]).map(\.key), [urgent.key, high.key])
    }

    @MainActor
    func testDigestFallsBackWhenTheModelRefusesAllHighlights() async {
        let digest = FYIDigest()
        let request = FYIDigest.Request(highlights: FYIDigest.highlights([fyiRow("Garden"), fyiRow("Museum")]))
        var calls: [String] = []
        var failures: [OnDeviceMessageSummarizer.Failure] = []
        await digest.refresh(request, using: { text, _ in
            calls.append(text)
            throw OnDeviceMessageSummarizer.Failure.guardrail
        }, onFallback: { failures.append($0) })
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.first?.contains("Garden") == true)
        XCTAssertTrue(calls.first?.contains("Museum") == true)
        XCTAssertNil(digest.summary)
        XCTAssertEqual(failures, [.guardrail])
    }

    @MainActor
    func testDigestFallsBackWhileModelIsUnavailableAndRecoversWhenReady() async {
        let digest = FYIDigest()
        var request = FYIDigest.Request(highlights: FYIDigest.highlights([fyiRow("Garden")]),
                                        unavailability: .modelNotReady)
        var failures: [OnDeviceMessageSummarizer.Failure] = []
        await digest.refresh(request, using: { _, _ in
            XCTFail("The unavailable model should not be called")
            return "Unexpected"
        }, onFallback: { failures.append($0) })
        XCTAssertNil(digest.summary)
        XCTAssertEqual(failures, [.modelNotReady])
        request.unavailability = nil
        await digest.refresh(request, using: { _, _ in "Garden reopened." })
        XCTAssertEqual(digest.summary, "Garden reopened.")
    }

    @MainActor
    func testDigestSummarizesAllPartsOnContextOverflowAndThenCombines() async {
        let digest = FYIDigest()
        var garden = fyiRow("Garden")
        garden.bodyText = "Path reopened today. The gate closes at dusk."
        let request = FYIDigest.Request(highlights: FYIDigest.highlights([garden, fyiRow("Museum")]))
        let fullGardenText = "Garden\n" + (garden.bodyText ?? "")
        var sourceParts: [String] = []
        var combinations = 0
        var failures: [OnDeviceMessageSummarizer.Failure] = []
        await digest.refresh(request, using: { prompt, _ in
            if prompt.hasPrefix("Earlier highlights:") {
                combinations += 1
                return "Garden reopened. Museum extended hours."
            }
            if prompt.contains(fullGardenText) {
                throw OnDeviceMessageSummarizer.Failure.contextTooLong
            }
            sourceParts.append(prompt.components(separatedBy: ":\n")[1])
            return "Partial"
        }, onFallback: { failures.append($0) })
        XCTAssertEqual(sourceParts.count, 3)
        XCTAssertEqual(sourceParts.dropLast().joined(), fullGardenText)
        XCTAssertEqual(sourceParts.last, "Museum")
        XCTAssertEqual(combinations, 2)
        XCTAssertEqual(digest.summary, "Garden reopened. Museum extended hours.")
        XCTAssertTrue(failures.isEmpty)
    }

    @MainActor
    func testDigestKeepsFinishedSummaryDuringReplacementAndIgnoresSupersededResult() async {
        let digest = FYIDigest()
        let garden = FYIDigest.Request(highlights: FYIDigest.highlights([fyiRow("Garden")]))
        let museum = FYIDigest.Request(highlights: FYIDigest.highlights([fyiRow("Museum")]))
        let library = FYIDigest.Request(highlights: FYIDigest.highlights([fyiRow("Library")]))
        await digest.refresh(garden, using: { _, _ in
            XCTAssertNil(digest.summary)
            return "Garden reopened."
        })
        await digest.refresh(museum, using: { _, _ in
            XCTAssertEqual(digest.summary, "Garden reopened.")
            await digest.refresh(library, using: { _, _ in
                XCTAssertEqual(digest.summary, "Garden reopened.")
                return "Library extended hours."
            })
            return "Museum closed."
        })
        XCTAssertEqual(digest.summary, "Library extended hours.")
        await digest.refresh(library, using: { _, _ in
            XCTFail("The finished digest should be reused")
            return "Unexpected"
        })
    }

    @MainActor
    func testDigestCancellationLeavesFinishedSummaryAndPermitsReplacement() async {
        let digest = FYIDigest()
        let garden = FYIDigest.Request(highlights: FYIDigest.highlights([fyiRow("Garden")]))
        let museum = FYIDigest.Request(highlights: FYIDigest.highlights([fyiRow("Museum")]))
        await digest.refresh(garden, using: { _, _ in "Garden reopened." })
        let cancelled = Task {
            await digest.refresh(museum, using: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return "Discarded"
            }, onFallback: { _ in XCTFail("Cancellation is not a fallback") })
        }
        await cancelled.value
        XCTAssertEqual(digest.summary, "Garden reopened.")
        await digest.refresh(museum, using: { _, _ in "Museum closed." })
        XCTAssertEqual(digest.summary, "Museum closed.")
    }

    @MainActor
    func testDigestRecordsOnlySafeFailureCodeAndLimitsSummaryToFourLines() async {
        let digest = FYIDigest()
        let journal = NativeClientDiagnosticJournal(fileURL: nil)
        let request = FYIDigest.Request(highlights: FYIDigest.highlights([fyiRow("Garden")]))
        await digest.refresh(request, using: { _, _ in "   " }, onFallback: { failure in
            journal.record(area: .conversation, phase: .projectionRefresh,
                           transition: .failed, causeCode: failure.rawValue)
        })
        XCTAssertEqual(journal.events.map(\.causeCode), ["model_empty_output"])
        XCTAssertNil(digest.summary)
        await digest.refresh(request, using: { _, _ in "One\nTwo\nThree\nFour\nFive" })
        XCTAssertEqual(digest.summary, "One\nTwo\nThree\nFour")
    }

    @MainActor
    func testDigestDoesNotCacheAcrossAccountViews() async {
        let digest = FYIDigest()
        let highlights = FYIDigest.highlights([fyiRow("Garden")])
        func scope(_ account: String) -> FYIDigest.Scope {
            .inbox(ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                personID: ExactText(account), deviceID: ExactText("device")), transportMode: .relay))
        }
        let firstScope = scope("first")
        let secondScope = scope("second")
        await digest.refresh(.init(highlights: highlights, scope: firstScope),
                             using: { _, _ in "First account summary" })
        XCTAssertEqual(digest.summary(for: firstScope), "First account summary")
        XCTAssertNil(digest.summary(for: secondScope))
        XCTAssertNil(digest.summary(for: .unavailable))
        await digest.refresh(.init(highlights: highlights, scope: .unavailable),
                             using: { _, _ in XCTFail("Read-only inbox must not generate"); return "" })
        XCTAssertNil(digest.summary(for: firstScope))
    }

    @MainActor
    func testDigestKeepsOtherHighlightsWhenOneMessageIsRefused() async {
        let digest = FYIDigest()
        let request = FYIDigest.Request(highlights: FYIDigest.highlights([fyiRow("Garden"), fyiRow("Museum")]))
        var failures: [OnDeviceMessageSummarizer.Failure] = []
        await digest.refresh(request, using: { text, _ in
            if text.contains("Garden") { throw OnDeviceMessageSummarizer.Failure.unsupportedLanguage }
            return "Museum open late."
        }, onFallback: { failures.append($0) })
        XCTAssertEqual(digest.summary, "Museum open late.")
        XCTAssertEqual(failures, [.unsupportedLanguage])
    }

    @MainActor
    func testUnrelatedChangesDoNotRegenerateDigest() async {
        let digest = FYIDigest()
        let first = fyiRow("Garden")
        var second = fyiRow("Museum")
        await digest.refresh(.init(highlights: FYIDigest.highlights([first, second])),
                             using: { _, _ in "Summary" })
        second.requestRevision += 1
        second.hasDeliveryWarning = true
        await digest.refresh(.init(highlights: FYIDigest.highlights([second, first])),
                             using: { _, _ in XCTFail("The selected text and priority order are unchanged"); return "" })
        XCTAssertEqual(digest.summary, "Summary")
    }

    @MainActor
    func testCachedFYIsUseMetadataAcrossPagesWhenRelayIsDetached() throws {
        let rows = try NativeAppLaunch.makeFYITestStore().inboxRows
        let garden = try XCTUnwrap(rows.first { $0.title == "Community garden" })
        let museum = try XCTUnwrap(rows.first { $0.title == "Museum hours" })
        XCTAssertFalse(rows.contains { $0.key.messageID == ExactText("gone") })
        XCTAssertEqual(garden.key.messageID.rawValue, "legacy/fyi-garden")
        XCTAssertEqual(museum.key.messageID.rawValue, "i-204")
        XCTAssertEqual(garden.key.senderID.rawValue, "app:fixture/community")
        XCTAssertEqual(museum.key.senderID.rawValue, "fixture:community")
        XCTAssertEqual(garden.fyiPriorityScore, 0.9)
        XCTAssertEqual(museum.fyiPriorityScore, 0.5)
        XCTAssertEqual(garden.fyiServerSeen, false)
        XCTAssertEqual(FYIOrder.priority.sorted(rows).map(\.key), [garden.key, museum.key])
        XCTAssertEqual(FYIOrder.posted.sorted(rows).map(\.key), [museum.key, garden.key])
    }

    @MainActor
    func testProgressFYIWithAnExplicitSeenResponseHasNoEligibleSeenWrite() throws {
        let store = try NativeAppLaunch.makeFYITestStore(includeProgress: true)
        let progress = try XCTUnwrap(store.inboxRows.first { $0.key.messageID == ExactText("progress-fyi") })
        XCTAssertNotNil(progress.progress)
        XCTAssertEqual(progress.informationalSeenStatus, .available)
        XCTAssertTrue(progress.isUnseenFYI)
        XCTAssertFalse(progress.canMarkFYISeen)
    }

    func testEqualFYIPriorityUsesPostedOrder() {
        var earlier = fyiRow("Earlier")
        var later = fyiRow("Later")
        earlier.fyiPostedAt = Date(timeIntervalSince1970: 1)
        later.fyiPostedAt = Date(timeIntervalSince1970: 2)
        let rows = [earlier, later]
        XCTAssertEqual(FYIOrder.priority.sorted(rows).map(\.key), FYIOrder.posted.sorted(rows).map(\.key))
    }

    private func fyiRow(_ id: String) -> InboxRequestRow {
        var row = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("person"), senderID: ExactText("sender"),
                            messageID: ExactText(id)),
            title: id, sender: "Sender", status: "")
        row.declaredMessageType = .fyi
        return row
    }

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

    func testServerEntryPriorityFallsBackOnlyWhenScoreIsUnusable() {
        let priorities: [(InboxMessagePriority, InboxPriorityDisplay?)] = [
            (.low, .low), (.normal, nil), (.high, .high), (.now, .urgent)
        ]
        for (priority, expected) in priorities {
            XCTAssertEqual(InboxPriorityDisplay.forEntry(score: nil, priority: priority), expected)
            for score in [-0.001, 1.001, Double.nan, Double.infinity] {
                XCTAssertEqual(InboxPriorityDisplay.forEntry(score: score, priority: priority), expected)
            }
            // A usable Normal score omits the label even with an Urgent priority.
            XCTAssertNil(InboxPriorityDisplay.forEntry(score: 0.50, priority: priority))
            XCTAssertEqual(InboxPriorityDisplay.forEntry(score: 0.75, priority: priority), .high)
        }
        for (score, expected) in [(0.10, InboxPriorityDisplay.low), (0.75, .high), (0.95, .urgent)] {
            XCTAssertEqual(InboxPriorityDisplay.forEntry(score: score, priority: nil), expected)
        }
        XCTAssertNil(InboxPriorityDisplay.forEntry(score: 0.50, priority: nil))
        XCTAssertNil(InboxPriorityDisplay.forEntry(score: nil, priority: nil))
        XCTAssertNil(InboxPriorityDisplay.forEntry(
            score: nil, priority: InboxMessagePriority(rawValue: "unknown")))
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
