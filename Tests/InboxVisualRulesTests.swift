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
    func testDigestIsEmptyWhenAllFYIsAreSeen() {
        var high = fyiRow("High")
        high.fyiPriority = .high
        high.fyiServerSeen = true
        var urgent = fyiRow("Urgent")
        urgent.fyiPriority = .now
        urgent.fyiServerSeen = true
        XCTAssertTrue(FYIDigest.highlights([high, urgent]).isEmpty)
    }

    @MainActor
    func testDigestDropsTerminalPlainFYIWithoutAnOpenedFlag() throws {
        let store = try NativeAppLaunch.makeFYITestStore(includeProgress: true, progressPercent: 100,
            progressTerminal: #"{"state":"expired","at_ms":1700000003000}"#)
        let expired = try XCTUnwrap(store.inboxRows.first { $0.isProgressFYI })
        var plain = expired
        plain.hasProgressMarker = false
        plain.progress = nil
        plain.informationalSeenStatus = nil

        XCTAssertTrue(FYIDigest.highlights([plain]).isEmpty)
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
    func testProgressWithSeparateSeenOffersAnActionAndTrustsTheServerFlag() throws {
        func row(percent: Int?, seen: Bool, terminal: String = "") throws -> InboxRequestRow {
            let store = try NativeAppLaunch.makeFYITestStore(includeProgress: true,
                progressPercent: percent, progressSeen: seen, progressTerminal: terminal)
            return try XCTUnwrap(store.inboxRows.first { $0.key.messageID == ExactText("progress-fyi") })
        }
        for percent in [nil, 0, 40, 100] {
            let unseen = try row(percent: percent, seen: false)
            XCTAssertTrue(unseen.isUnseenFYI)
            XCTAssertEqual(unseen.fyiSeenAction, percent == 100 ? .answer : .openedFlag)
            let seen = try row(percent: percent, seen: true)
            XCTAssertFalse(seen.isUnseenFYI)
            XCTAssertFalse(seen.canMarkFYISeen)
        }
        let answered = try row(percent: 100, seen: false,
            terminal: #"{"state":"answered","at_ms":1700000003000,"answer":{"kind":"seen"}}"#)
        XCTAssertFalse(answered.isUnseenFYI)
        XCTAssertFalse(answered.canMarkFYISeen)
        let closed = try row(percent: 100, seen: false,
            terminal: #"{"state":"expired","at_ms":1700000003000}"#)
        XCTAssertFalse(closed.isUnseenFYI)
        XCTAssertNil(closed.fyiSeenAction)
    }

    @MainActor
    func testProgressFYIQueuesOnlyItsRuledOperationAndDoesNotAnswerOnOpen() throws {
        let plainStore = try NativeAppLaunch.makeFYITestStore()
        let plain = try XCTUnwrap(plainStore.inboxRows.first { $0.key.messageID == ExactText("i-204") })
        plainStore.reportMessageContentOpened(try XCTUnwrap(plainStore.request(for: plain.key)))
        let savedOpen = try XCTUnwrap(plainStore.fyiTestSnapshot().pendingMessageOpens.first)
        XCTAssertEqual(savedOpen.requestKey, plain.key)
        try plainStore.refreshFromDurableStore()
        let pendingPlain = try XCTUnwrap(plainStore.inboxRow(for: plain.key))
        XCTAssertTrue(pendingPlain.isActiveFYI)
        XCTAssertTrue(pendingPlain.isFYISeenPending)
        XCTAssertNil(pendingPlain.fyiSeenAction)
        XCTAssertTrue(plainStore.retryFYISeen(plain.key, requestRevision: plain.requestRevision))
        XCTAssertEqual(try plainStore.fyiTestSnapshot().pendingMessageOpens.map(\.id), [savedOpen.id])
        for percent in [nil, 0, 40, 100] {
            let store = try NativeAppLaunch.makeFYITestStore(includeProgress: true, progressPercent: percent)
            let row = try XCTUnwrap(store.inboxRows.first { $0.isProgressFYI })
            let request = try XCTUnwrap(store.request(for: row.key))
            store.reportMessageContentOpened(request)
            XCTAssertTrue(try store.fyiTestSnapshot().pendingMessageOpens.isEmpty)

            XCTAssertTrue(store.markProgressFYISeen(row.key, requestRevision: row.requestRevision))
            let snapshot = try store.fyiTestSnapshot()
            if percent == 100 {
                let answer = try XCTUnwrap(snapshot.intents.values.first)
                XCTAssertEqual(answer.typedInputs, [.compatibilityValue(action: ExactText("seen"))])
                XCTAssertTrue(snapshot.pendingMessageOpens.isEmpty)
                let pending = try XCTUnwrap(store.inboxRow(for: row.key))
                XCTAssertEqual(pending.informationalSeenStatus, .pending)
                XCTAssertNil(pending.fyiSeenAction)
                XCTAssertFalse(store.markProgressFYISeen(row.key, requestRevision: row.requestRevision))
                XCTAssertTrue(store.retryFYISeen(row.key, requestRevision: row.requestRevision))
                XCTAssertEqual(try store.fyiTestSnapshot().intents.values.map(\.operationID), [answer.operationID])
            } else {
                XCTAssertTrue(snapshot.intents.isEmpty)
                XCTAssertEqual(snapshot.pendingMessageOpens.map(\.requestKey), [row.key])
            }
        }
    }

    @MainActor
    func testProgressUpdatesUseServerSeenAndLatestCompletionState() throws {
        let store = try NativeAppLaunch.makeFYITestStore(includeProgress: true,
            progressPercent: 40, progressSeen: true)
        let original = try XCTUnwrap(store.inboxRows.first { $0.isProgressFYI })
        XCTAssertFalse(original.isUnseenFYI)
        XCTAssertFalse(store.markProgressFYISeen(original.key, requestRevision: original.requestRevision))

        try store.applyFYIProgressTestSnapshot(percent: 70, seen: false, revision: 6)
        let updated = try XCTUnwrap(store.inboxRow(for: original.key))
        XCTAssertTrue(updated.isUnseenFYI, "Server 0.2.8 clears Seen on a substantive Progress update")
        XCTAssertEqual(updated.fyiSeenAction, .openedFlag)
        XCTAssertFalse(store.markProgressFYISeen(original.key, requestRevision: original.requestRevision))

        try store.applyFYIProgressTestSnapshot(percent: 100, seen: true, revision: 7)
        XCTAssertNil(store.inboxRow(for: original.key)?.fyiSeenAction, "A carried flag survives finishing")
        try store.applyFYIProgressTestSnapshot(percent: 100, seen: false, revision: 8)
        XCTAssertEqual(store.inboxRow(for: original.key)?.fyiSeenAction, .answer)
        try store.applyFYIProgressTestSnapshot(percent: 60, seen: true, revision: 9)
        XCTAssertNil(store.inboxRow(for: original.key)?.fyiSeenAction, "A carried flag survives regression")
        try store.applyFYIProgressTestSnapshot(percent: 60, seen: false, revision: 10)
        XCTAssertEqual(store.inboxRow(for: original.key)?.fyiSeenAction, .openedFlag)
    }

    @MainActor
    func testFYIProjectionReconciles135TerminalChangesAndKeepsLegacyRepliedSearch() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture.invalid"),
            personID: ExactText("fyi-fixture"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let model = ServerModelV2Store(fileURL: nil)
        let repo = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try LivePresentationStore(store: repo, context: context, newMessageAreaDefaults: defaults)

        let openCount = 135
        let itemCount = 840
        let initial = NativeAppLaunch.fyiBulkTestChanges(
            indices: 0..<itemCount, firstRevision: 1, openCount: openCount)
        try model.apply(initial, cursor: UInt64(itemCount))
        try repo.restoreCachedServerState(ServerModelV2Projection.cachedState(model.snapshot, identity: identity),
                                          context: context)
        try store.refreshFromDurableStore()
        let original = store.inboxRows
        let newBefore = try XCTUnwrap(store.newMessageAreaStore).entries.count
        let badgeBefore = InboxBadge.count(requests: original, samples: SampleLibrary(), showsLocalExamples: false)
        XCTAssertEqual(newBefore, openCount)
        XCTAssertEqual(badgeBefore, openCount)
        XCTAssertEqual(original.filter(\.isActiveFYI).count, openCount)
        XCTAssertEqual(FYIDigest.highlights(original).count, 4)
        XCTAssertTrue(FYIOrder.priority.sorted(original.filter(\.isActiveFYI)).contains { $0.title == "Bulletin 1" })

        let batch = NativeAppLaunch.fyiBulkTestChanges(
            indices: 0..<openCount, firstRevision: itemCount + 1, openCount: 0)
        let start = DispatchTime.now().uptimeNanoseconds
        try model.apply(batch, cursor: UInt64(itemCount + openCount))
        try repo.restoreCachedServerState(ServerModelV2Projection.cachedState(model.snapshot, identity: identity),
                                          context: context)
        try store.refreshFromDurableStore()
        let liveRows = store.inboxRows
        XCTAssertTrue(liveRows.filter(\.isActiveFYI).isEmpty)
        XCTAssertTrue(FYIDigest.highlights(liveRows).isEmpty)
        let oldBadgeCount = liveRows.filter { !$0.hasProgressMarker && !$0.belongsToReplied && !$0.isRetracted }.count
        let badgeCount = InboxBadge.count(requests: liveRows, samples: SampleLibrary(), showsLocalExamples: false)
        XCTAssertGreaterThan(oldBadgeCount, 0)
        XCTAssertEqual(badgeCount, 0)
        let newAfter = try XCTUnwrap(store.newMessageAreaStore).entries.count
        XCTAssertEqual(newAfter, 0)
        print("840 FYIs: badge \(badgeBefore) to \(badgeCount), New \(newBefore) to \(newAfter); previous settled badge \(oldBadgeCount)")
        let projected = DispatchTime.now().uptimeNanoseconds

        for serverItems in [nil, store.presentation.inboxViewListItems] {
            let replied = InboxNormalListProjection.entries(rows: liveRows.map(InboxItem.request),
                serverItems: serverItems, in: .replied, search: "")
            XCTAssertGreaterThan(replied.count, 500)
            let search = InboxNormalListProjection.entries(rows: liveRows.map(InboxItem.request),
                serverItems: serverItems, in: .replied, search: "Bulletin 501")
            XCTAssertEqual(search.count, 1, "A legacy FYI stays searchable in Replied.")
        }
        let searched = DispatchTime.now().uptimeNanoseconds
        let relaunched = try LivePresentationStore(store: repo, context: context)
        XCTAssertTrue(relaunched.inboxRows.filter(\.isActiveFYI).isEmpty)
        print("FYI 840-item fixture: apply 135 changes and project \(Double(projected - start) / 1_000_000) ms, "
            + "four Replied/search projections \(Double(searched - projected) / 1_000_000) ms")
    }

    @MainActor
    func testEndedUnansweredProgressIsReachableInInboxSearch() throws {
        let store = try NativeAppLaunch.makeFYITestStore(includeProgress: true, progressPercent: 40,
            progressTerminal: #"{"state":"expired","at_ms":1700000003000}"#)
        let items = store.inboxRows.map(InboxItem.request)
        let progress = try XCTUnwrap(store.inboxRows.first { $0.isProgressFYI })
        for list in [nil, store.presentation.inboxViewListItems] {
            let entries = InboxNormalListProjection.entries(rows: items, serverItems: list,
                in: .inbox, search: "Progress with a Seen response")
            XCTAssertEqual(entries.count, 1)
            XCTAssertTrue(InboxNormalListProjection.entries(rows: items, serverItems: list,
                in: .inbox, search: "").allSatisfy { entry in
                    guard case let .message(message) = entry else { return true }
                    return !message.members.contains { $0.id == .request(progress.key) }
                })
        }
        XCTAssertFalse(store.inboxRows.contains { $0.isProgressFYI && $0.isActiveFYI })
        XCTAssertFalse(FYIDigest.highlights(store.inboxRows).contains { $0.key.messageID == ExactText("progress-fyi") })
        store.reportMessageContentOpened(try XCTUnwrap(store.request(for: progress.key)))
        XCTAssertTrue(try store.fyiTestSnapshot().pendingMessageOpens.isEmpty)
    }

    @MainActor
    func testSettledPlainFYIsJoinRepliedWithoutBadgeAttention() throws {
        let store = try NativeAppLaunch.makeFYITestStore(gardenSeen: true, museumSeen: true)
        XCTAssertEqual(store.inboxRows.count, 2)
        XCTAssertTrue(store.inboxRows.allSatisfy { $0.isRepliedFYI && $0.belongsToReplied })
        XCTAssertEqual(InboxBadge.count(requests: store.inboxRows, samples: SampleLibrary(),
                                       showsLocalExamples: false), 0)
    }

    @MainActor
    func testFYIPlacementUsesAuthoritativeSeenAndKeepsOrdinaryAnswersUngrouped() {
        var opened = fyiRow("Opened")
        opened.fyiServerSeen = true
        opened.fyiHasEnded = true
        var answeredOtherwise = opened
        answeredOtherwise.fyiAnsweredOtherwise = true
        answeredOtherwise.informationalSeenStatus = .resolvedWithoutSeen
        answeredOtherwise.hasUserAction = true
        var pending = fyiRow("Waiting")
        pending.informationalSeenStatus = .pending
        var liveProgress = opened
        liveProgress.fyiHasEnded = false
        liveProgress.hasProgressMarker = true
        var confirmed = fyiRow("Confirmed")
        confirmed.declaredMessageType = nil
        confirmed.fyiServerSeen = false
        confirmed.informationalSeenStatus = .confirmed

        XCTAssertTrue(opened.isRepliedFYI)
        XCTAssertTrue(confirmed.isRepliedFYI)
        XCTAssertFalse(answeredOtherwise.isRepliedFYI)
        XCTAssertTrue(answeredOtherwise.belongsToReplied)
        XCTAssertFalse(liveProgress.isRepliedFYI)
        XCTAssertFalse(liveProgress.isActiveFYI)
        XCTAssertTrue(pending.isActiveFYI)
        XCTAssertFalse(pending.isRepliedFYI)
        XCTAssertTrue(pending.belongsToReplied)
        opened.fyiHasEnded = false
        opened.fyiServerSeen = false
        XCTAssertTrue(opened.isActiveFYI)
    }

    @MainActor
    func testLargeSeenFYIGroupRemainsSearchableAndDoesNotCountAsUnseen() {
        var seen = (0..<900).map { index in
            var row = fyiRow("Seen bulletin \(index)")
            row.informationalSeenStatus = .confirmed
            row.fyiServerSeen = false
            return row
        }
        let inbox = (0..<100).map { fyiRow("New bulletin \($0)") }
        let start = DispatchTime.now().uptimeNanoseconds
        let rows = seen + inbox
        XCTAssertEqual(FYIOrder.priority.sorted(rows.filter(\.isRepliedFYI)).count, 900)
        XCTAssertEqual(rows.filter(\.isActiveFYI).count, 100)
        XCTAssertEqual(FYIDigest.highlights(rows).count, 4)
        XCTAssertEqual(InboxBadge.count(requests: rows, samples: SampleLibrary(), showsLocalExamples: false), 100)
        XCTAssertEqual(InboxListProjection.filteredRows(rows.map(InboxItem.request),
            in: .replied, search: "Seen bulletin 899").count, 1)
        let destination = InboxNotificationDestination(route: NativeInboxNavigation(serial: 1, request: seen[0].key),
            rows: rows.map(InboxItem.request), usesFreeOrder: true)
        XCTAssertEqual(destination.workspaceTab, .replied)
        seen[0].informationalSeenStatus = .available
        XCTAssertTrue(seen[0].isActiveFYI)
        XCTAssertFalse(seen[0].isRepliedFYI)
        print("FYI 900 Seen + 100 Inbox: sort, search, digest, badge and move \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) ms")
    }

    @MainActor
    func testConfirmedProgressFYIRemainsReachableFromReplied() throws {
        let store = try NativeAppLaunch.makeFYITestStore(includeProgress: true, progressPercent: 100,
            progressTerminal: #"{"state":"answered","at_ms":1700000003000,"answer":{"kind":"seen"}}"#)
        let rows = store.inboxRows
        let progress = try XCTUnwrap(rows.first { $0.isProgressFYI })
        XCTAssertFalse(progress.isActiveFYI)
        XCTAssertFalse(progress.fyiUsesInboxSearchForProgress)
        let entries = InboxNormalListProjection.entries(rows: rows.map(InboxItem.request),
            serverItems: store.presentation.inboxViewListItems, in: .replied, search: "Progress")
        XCTAssertEqual(entries.count, 1)
    }

    @MainActor
    func testDefinitivelyFailedSeenCanBeMarkedAgain() throws {
        let store = try NativeAppLaunch.makeFYITestStore(includeProgress: true, progressPercent: 100)
        let row = try XCTUnwrap(store.inboxRows.first { $0.isProgressFYI })
        XCTAssertTrue(store.markProgressFYISeen(row.key, requestRevision: row.requestRevision))
        let original = try XCTUnwrap(store.fyiTestSnapshot().intents.values.first)
        try store.rejectFYITestAnswer(original)

        let failed = try XCTUnwrap(store.inboxRow(for: row.key))
        XCTAssertTrue(failed.hasFailedResponse)
        XCTAssertEqual(failed.fyiSeenAction, .answer)
        XCTAssertTrue(store.markProgressFYISeen(row.key, requestRevision: row.requestRevision))
        let pending = try XCTUnwrap(store.inboxRow(for: row.key))
        XCTAssertTrue(pending.isFYISeenPending)
        XCTAssertNotEqual(store.request(for: row.key)?.intentReceipt?.opID, original.operationID)
    }

    @MainActor
    func testDigestStopsShowingSummaryAsSoonAsAHighlightLeaves() async {
        let garden = fyiRow("Garden")
        let museum = fyiRow("Museum")
        let digest = FYIDigest()
        let scope = FYIDigest.Scope.inbox(nil)
        await digest.refresh(.init(highlights: FYIDigest.highlights([garden, museum])),
                             using: { _, _ in "Garden and museum highlights." })
        XCTAssertNotNil(digest.summary(for: scope, visibleKeys: [garden.key, museum.key]))
        XCTAssertNil(digest.summary(for: scope, visibleKeys: [museum.key]))
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
