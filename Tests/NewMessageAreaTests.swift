import AttentionDomain
import XCTest
@testable import Harklight

final class NewMessageAreaTests: XCTestCase {
    private let baselineDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ id: String, order: UInt64,
                        account: String = "account",
                        isResolved: Bool = false,
                        hasSubmittedAnswer: Bool = false) -> NewMessageAreaMessage {
        NewMessageAreaMessage(
            key: RequestKey(accountScope: ExactText(account),
                            senderID: ExactText("sender"),
                            messageID: ExactText(id)),
            acceptanceOrder: order,
            isResolved: isResolved,
            hasSubmittedAnswer: hasSubmittedAnswer)
    }

    func testExistingMessagesAreBaselineAndOlderBackfillDoesNotEnter() {
        var ledger = NewMessageAreaLedger()
        let existing = [message("existing-4", order: 4), message("existing-5", order: 5)]

        ledger.reconcile(existing, now: baselineDate)
        XCTAssertTrue(ledger.entries.isEmpty)

        let newlyReceived = message("new-6", order: 6)
        ledger.reconcile(existing + [newlyReceived], now: baselineDate.addingTimeInterval(1))
        XCTAssertEqual(ledger.entries.map(\.key), [newlyReceived.key])

        ledger.reconcile(existing + [newlyReceived, message("history-3", order: 3)],
                         now: baselineDate.addingTimeInterval(2))
        XCTAssertEqual(ledger.entries.map(\.key), [newlyReceived.key],
                       "Older history loaded after the initial baseline is not a new arrival.")
    }

    func testEmptyInitialSnapshotEstablishesBaselineForItsAccount() {
        var ledger = NewMessageAreaLedger()
        let account = ExactText("account")
        ledger.reconcile([], accountScopes: [account], now: baselineDate)

        let firstArrival = message("first-arrival", order: 1)
        ledger.reconcile([firstArrival], accountScopes: [account],
                         now: baselineDate.addingTimeInterval(1))
        XCTAssertEqual(ledger.entries.map(\.key), [firstArrival.key],
                       "An empty first snapshot must not cause the first later message to be treated as history.")

        let laterAccountHistory = message("later-account-history", order: 20, account: "second")
        ledger.reconcile([firstArrival, laterAccountHistory],
                         accountScopes: [account, ExactText("second")],
                         now: baselineDate.addingTimeInterval(2))
        XCTAssertEqual(ledger.entries.map(\.key), [firstArrival.key],
                       "An account first observed after feature launch starts with its current history as baseline.")

        let laterAccountArrival = message("later-account-arrival", order: 21, account: "second")
        ledger.reconcile([firstArrival, laterAccountHistory, laterAccountArrival],
                         accountScopes: [account, ExactText("second")],
                         now: baselineDate.addingTimeInterval(3))
        XCTAssertEqual(ledger.entries.map(\.key), [laterAccountArrival.key, firstArrival.key])
    }

    func testEntriesUseAcceptanceOrderTopFiveAndMore() {
        var ledger = NewMessageAreaLedger()
        ledger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        let messages = (1...7).map { message("message-\($0)", order: UInt64($0)) }
        ledger.reconcile(messages, now: baselineDate.addingTimeInterval(1))

        XCTAssertTrue(ledger.hasMoreThanFiveEntries)
        XCTAssertEqual(ledger.visibleEntries(isExpanded: false).map(\.acceptanceOrder), [7, 6, 5, 4, 3])
        XCTAssertEqual(ledger.visibleEntries(isExpanded: true).map(\.acceptanceOrder), [7, 6, 5, 4, 3, 2, 1])

        let fiveEntries = messages.suffix(5)
        var fiveEntryLedger = NewMessageAreaLedger()
        fiveEntryLedger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        fiveEntryLedger.reconcile(Array(fiveEntries), now: baselineDate.addingTimeInterval(1))
        XCTAssertFalse(fiveEntryLedger.hasMoreThanFiveEntries)
        XCTAssertEqual(fiveEntryLedger.visibleEntries(isExpanded: false).count, 5)
    }

    func testFirstSeenPersistsAndExpiresAtOneHourWithoutReentry() throws {
        var ledger = NewMessageAreaLedger()
        ledger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        let arrival = message("expires", order: 1)
        ledger.reconcile([arrival], now: baselineDate.addingTimeInterval(10))

        XCTAssertNil(ledger.entries.first?.firstSeenAt,
                     "Receiving an entry does not start its visible-time clock.")
        let firstSeen = baselineDate.addingTimeInterval(20)
        ledger.markFirstSeen(arrival.key, at: firstSeen)

        var restored = try JSONDecoder().decode(NewMessageAreaLedger.self,
            from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.entries.first?.firstSeenAt, firstSeen)

        XCTAssertFalse(restored.pruneExpired(now: firstSeen.addingTimeInterval(3_599)))
        XCTAssertTrue(restored.pruneExpired(now: firstSeen.addingTimeInterval(3_600)))
        XCTAssertTrue(restored.entries.isEmpty)

        restored.reconcile([arrival], now: firstSeen.addingTimeInterval(3_601))
        XCTAssertTrue(restored.entries.isEmpty,
                      "An expired message remains known and cannot re-enter on replay.")
    }

    @MainActor
    func testStorePersistsEntryAndFirstSeenInTheLocalDefaultsDomain() throws {
        let suite = "NewMessageAreaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = RequestKey(accountScope: ExactText("account"),
                             senderID: ExactText("sender"),
                             messageID: ExactText("persistent"))
        let message = NewMessageAreaMessage(key: key, acceptanceOrder: 1,
                                            isResolved: false, hasSubmittedAnswer: false)
        let receivedAt = baselineDate.addingTimeInterval(1)
        let firstSeenAt = baselineDate.addingTimeInterval(2)

        let store = NewMessageAreaStore(defaults: defaults)
        store.reconcile([], revisions: [:], accountScopes: [ExactText("account")], now: baselineDate)
        store.reconcile([message], revisions: [key: 1], now: receivedAt)
        store.markFirstSeen(key, at: firstSeenAt)

        let restored = NewMessageAreaStore(defaults: defaults)
        XCTAssertEqual(restored.entries.first?.key, key)
        XCTAssertEqual(restored.entries.first?.receivedAt, receivedAt)
        XCTAssertEqual(restored.entries.first?.firstSeenAt, firstSeenAt)
        XCTAssertNil(restored.summary(for: key, revision: 1),
                     "Generated message text is held in memory, not persisted with local state.")
    }

    func testSubmittedAnswerAndResolvedOutcomeRemoveEntries() {
        var ledger = NewMessageAreaLedger()
        ledger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        let answered = message("answered", order: 1)
        let resolved = message("resolved", order: 2)
        ledger.reconcile([answered, resolved], now: baselineDate.addingTimeInterval(1))
        XCTAssertEqual(ledger.entries.count, 2)

        ledger.reconcile([
            message("answered", order: 1, hasSubmittedAnswer: true),
            message("resolved", order: 2, isResolved: true)
        ], now: baselineDate.addingTimeInterval(2))
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func testResolvedMessageDoesNotEnterAndOpenRemovalIsPermanent() {
        var ledger = NewMessageAreaLedger()
        ledger.reconcile([], accountScopes: [ExactText("account")], now: baselineDate)
        let alreadyResolved = message("already-resolved", order: 1, isResolved: true)
        ledger.reconcile([alreadyResolved], now: baselineDate.addingTimeInterval(1))
        XCTAssertTrue(ledger.entries.isEmpty)

        let opened = message("opened", order: 2)
        ledger.reconcile([alreadyResolved, opened], now: baselineDate.addingTimeInterval(2))
        ledger.remove(opened.key)
        ledger.reconcile([alreadyResolved, opened], now: baselineDate.addingTimeInterval(3))
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func testFallbackUsesOnlyTheFirstTwoMessageTextLines() {
        XCTAssertEqual(NewMessageAreaSummaryText.fallback("First\nSecond\nThird"), "First\nSecond")
        XCTAssertEqual(NewMessageAreaSummaryText.fallback("First\r\nSecond\r\nThird"), "First\nSecond")
        XCTAssertEqual(NewMessageAreaSummaryText.fallback("One line"), "One line")
        XCTAssertEqual(NewMessageAreaSummaryText.fallback(""), "")
    }
}
