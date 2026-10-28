import XCTest
@testable import Harklight
import AttentionDomain

final class ReleaseNotesTests: XCTestCase {
    func testBuildSeventyEightReplyCheckmarkNoteIsFixedAndHiddenUntilThatBuild() throws {
        let entry = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == 78 })
        let highlight = try XCTUnwrap(entry.highlights.first)

        XCTAssertEqual(HarklightReleaseNotes.entries.first?.buildIdentifier, 78)
        XCTAssertEqual(entry.marketingVersion, "0.1.0")
        XCTAssertEqual(entry.highlights.map(\.id), ["reply-checkmark-commit"])
        XCTAssertEqual(highlight.symbol, "square.and.pencil")
        XCTAssertEqual(String(localized: highlight.title), "Reply waits for the checkmark")
        XCTAssertEqual(String(localized: highlight.detail),
                       "Your text and choices stay in the Reply box until you send your answer.")
        XCTAssertFalse(HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "77")
            .contains { $0.buildIdentifier == 78 })
        XCTAssertEqual(HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "78")
            .first?.buildIdentifier, 78)
    }

    func testBuildSeventySevenInboxAnswerRecoveryNoteIsFixedAndHiddenUntilThatBuild() throws {
        let entry = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == 77 })

        XCTAssertEqual(HarklightReleaseNotes.entries.first?.buildIdentifier, 78)
        XCTAssertEqual(entry.marketingVersion, "0.1.0")
        XCTAssertEqual(entry.highlights.map(\.id), ["inbox-answer-recovery"])
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "76")
                .compactMap(\.buildIdentifier).first,
            76)
        XCTAssertFalse(HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "76")
            .contains { $0.buildIdentifier == 77 })
        XCTAssertTrue(HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "77")
            .contains { $0.buildIdentifier == 77 })
    }

    func testBuildOneReleaseNoteShowsMarketingVersionAndRetainsBuildIdentity() throws {
        let first = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == 1 })

        XCTAssertEqual(first.marketingVersion, "0.1.0")
        XCTAssertEqual(first.buildIdentifier, 1)
    }

    func testBuildFiftyNineSettingsNoteIsHiddenUntilThatBuildIsRunning() {
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "58")
                .compactMap(\.buildIdentifier),
            [1])

        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "59")
                .compactMap(\.buildIdentifier),
            [59, 1])
    }

    func testDatedHistoryIsSettingsOnlyAndStartsAtItsFirstConfirmedBuild() {
        let historyNote = HarklightReleaseNote(
            historyIdentifier: "earlier-on-2026-10-25",
            marketingVersion: "0.1.0",
            historyDateDescription: LocalizedStringResource("Earlier on October 25, 2026"),
            visibleFromBuildIdentifier: 59,
            highlights: [])
        let buildNotes = [releaseNote(1), releaseNote(59)]

        XCTAssertEqual(
            HarklightReleaseNotes.settingsHistory(
                currentBuildIdentifier: "58",
                entries: buildNotes,
                historyEntries: [historyNote]).map(\.id),
            ["1"])
        XCTAssertEqual(
            HarklightReleaseNotes.settingsHistory(
                currentBuildIdentifier: "59",
                entries: buildNotes,
                historyEntries: [historyNote]).map(\.id),
            ["59", "earlier-on-2026-10-25", "1"])
        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "59",
                entries: buildNotes + [historyNote],
                lastSeenBuildIdentifier: 1,
                hasPriorAppState: true).map(\.id),
            ["59"])
    }

    func testHistoricalEntryHasNoBuildNumberAndOnlyListsShippedChanges() throws {
        let note = try XCTUnwrap(HarklightReleaseNotes.historyEntries.first)

        XCTAssertNil(note.buildIdentifier)
        XCTAssertEqual(note.marketingVersion, "0.1.0")
        XCTAssertEqual(note.highlights.map(\.id), [
            "inline-reply-field",
            "listening-status",
            "chat-toolbar",
            "chat-history-keyboard"
        ])
    }

    func testBuildSixtyOneEntryIsFixedAndHiddenUntilThatBuild() throws {
        let entry = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == 61 })

        XCTAssertEqual(entry.marketingVersion, "0.1.0")
        XCTAssertEqual(entry.highlights.map(\.id), [
            "inbox-scrolling",
            "release-note-format"
        ])
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "60")
                .compactMap(\.buildIdentifier),
            [59, 1])
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "61")
                .compactMap(\.buildIdentifier),
            [61, 59, 1])
        XCTAssertEqual(
            HarklightReleaseNotes.settingsHistory(currentBuildIdentifier: "60")
                .compactMap(\.buildIdentifier),
            [59, 1])
        XCTAssertTrue(ReleaseNotesLifecycle.notesToPresent(
            currentBuildIdentifier: "60",
            entries: HarklightReleaseNotes.entries,
            lastSeenBuildIdentifier: 59,
            hasPriorAppState: true).isEmpty)
        XCTAssertEqual(ReleaseNotesLifecycle.notesToPresent(
            currentBuildIdentifier: "61",
            entries: HarklightReleaseNotes.entries,
            lastSeenBuildIdentifier: 60,
            hasPriorAppState: true).compactMap(\.buildIdentifier), [61])
    }

    func testLaterBuildPresentsOnlyItsUnseenNote() {
        XCTAssertEqual(ReleaseNotesLifecycle.notesToPresent(
            currentBuildIdentifier: "62",
            entries: HarklightReleaseNotes.entries,
            lastSeenBuildIdentifier: 61,
            hasPriorAppState: true).compactMap(\.buildIdentifier), [62])
    }

    func testBuildSixtyTwoReplyNoteIsFixedAndHiddenUntilThatBuild() throws {
        let entry = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == 62 })

        XCTAssertEqual(entry.marketingVersion, "0.1.0")
        XCTAssertEqual(entry.highlights.map(\.id), ["reply-box"])
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "61")
                .compactMap(\.buildIdentifier),
            [61, 59, 1])
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "62")
                .compactMap(\.buildIdentifier),
            [62, 61, 59, 1])
        XCTAssertEqual(
            HarklightReleaseNotes.settingsHistory(currentBuildIdentifier: "61")
                .compactMap(\.buildIdentifier),
            [61, 59, 1])
        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "62",
                entries: HarklightReleaseNotes.entries,
                lastSeenBuildIdentifier: 61,
                hasPriorAppState: true).compactMap(\.buildIdentifier),
            [62])
        XCTAssertTrue(ReleaseNotesLifecycle.notesToPresent(
            currentBuildIdentifier: "62",
            entries: HarklightReleaseNotes.entries,
            lastSeenBuildIdentifier: 62,
            hasPriorAppState: true).isEmpty)
    }

    func testBuildSixtyThreeDuoSplitNoteIsFixedAndHiddenUntilThatBuild() throws {
        let entry = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == 63 })

        XCTAssertEqual(entry.marketingVersion, "0.1.0")
        XCTAssertEqual(entry.highlights.map(\.id), ["duo-book-split"])
        XCTAssertEqual(entry.highlights.first?.symbol, "rectangle.split.2x1")
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "62")
                .compactMap(\.buildIdentifier),
            [62, 61, 59, 1])
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "63")
                .compactMap(\.buildIdentifier),
            [63, 62, 61, 59, 1])
        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "63",
                entries: HarklightReleaseNotes.entries,
                lastSeenBuildIdentifier: 62,
                hasPriorAppState: true).compactMap(\.buildIdentifier),
            [63])
    }

    func testBuildSixtyFourToolbarActionsNoteIsFixedAndHiddenUntilThatBuild() throws {
        let entry = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == 64 })

        XCTAssertEqual(entry.marketingVersion, "0.1.0")
        XCTAssertEqual(entry.highlights.map(\.id), ["toolbar-actions"])
        XCTAssertEqual(entry.highlights.first?.symbol, "hand.tap")
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "63")
                .compactMap(\.buildIdentifier),
            [63, 62, 61, 59, 1])
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "64")
                .compactMap(\.buildIdentifier),
            [64, 63, 62, 61, 59, 1])
        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "63",
                entries: HarklightReleaseNotes.entries,
                lastSeenBuildIdentifier: 63,
                hasPriorAppState: true).compactMap(\.buildIdentifier),
            [])
        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "64",
                entries: HarklightReleaseNotes.entries,
                lastSeenBuildIdentifier: 63,
                hasPriorAppState: true).compactMap(\.buildIdentifier),
            [64])
    }

    func testBuildSeventySixConnectionLanguageNoteIsFixedAndHiddenUntilThatBuild() throws {
        let entry = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == 76 })

        XCTAssertEqual(entry.marketingVersion, "0.1.0")
        XCTAssertEqual(entry.highlights.map(\.id), ["plain-connection-language"])
        XCTAssertEqual(entry.highlights.first?.symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "75")
                .compactMap(\.buildIdentifier),
            [75, 74, 73, 72, 71, 70, 69, 68, 67, 66, 65, 64, 63, 62, 61, 59, 1])
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "76").first?.buildIdentifier,
            76)
        XCTAssertTrue(ReleaseNotesLifecycle.notesToPresent(
            currentBuildIdentifier: "75",
            entries: HarklightReleaseNotes.entries,
            lastSeenBuildIdentifier: 75,
            hasPriorAppState: true).isEmpty)
        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "76",
                entries: HarklightReleaseNotes.entries,
                lastSeenBuildIdentifier: 75,
                hasPriorAppState: true).compactMap(\.buildIdentifier),
            [76])
    }

    func testBuildSixtySevenReplyInputNoteIsFixedAndHiddenUntilThatBuild() throws {
        let entry = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == 67 })

        XCTAssertEqual(entry.marketingVersion, "0.1.0")
        XCTAssertEqual(entry.highlights.map(\.id), ["reply-input-surface"])
        XCTAssertEqual(entry.highlights.first?.symbol, "square.and.pencil")
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "66")
                .compactMap(\.buildIdentifier),
            [66, 65, 64, 63, 62, 61, 59, 1])
        XCTAssertEqual(
            HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "67")
                .compactMap(\.buildIdentifier),
            [67, 66, 65, 64, 63, 62, 61, 59, 1])
        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "67",
                entries: HarklightReleaseNotes.entries,
                lastSeenBuildIdentifier: 66,
                hasPriorAppState: true).compactMap(\.buildIdentifier),
            [67])
        XCTAssertTrue(ReleaseNotesLifecycle.notesToPresent(
            currentBuildIdentifier: "67",
            entries: HarklightReleaseNotes.entries,
            lastSeenBuildIdentifier: 67,
            hasPriorAppState: true).isEmpty)
    }

    func testBuildSeventyAccountPhoneOutcomeNoteIsHiddenUntilThatBuild() throws {
        let entry = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == 70 })

        XCTAssertEqual(entry.marketingVersion, "0.1.0")
        XCTAssertEqual(entry.highlights.map(\.id), ["account-phone-outcome-sync"])
        XCTAssertEqual(entry.highlights.first?.symbol, "arrow.triangle.2.circlepath")
        XCTAssertFalse(HarklightReleaseNotes.releasedEntries(currentBuildIdentifier: "69")
            .contains { $0.buildIdentifier == 70 })
        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "70",
                entries: HarklightReleaseNotes.entries,
                lastSeenBuildIdentifier: 69,
                hasPriorAppState: true).compactMap(\.buildIdentifier),
            [70])
    }

    func testFreshInstallDoesNotPresentPreviouslyReleasedNotes() {
        let notes = [releaseNote(1), releaseNote(2)]

        XCTAssertTrue(ReleaseNotesLifecycle.notesToPresent(
            currentBuildIdentifier: "2",
            entries: notes,
            lastSeenBuildIdentifier: nil,
            hasPriorAppState: false).isEmpty)
    }

    func testLegacyUpgradeShowsNewestReleasedNoteOnly() {
        let notes = [releaseNote(1), releaseNote(3), releaseNote(2), releaseNote(4)]

        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "3",
                entries: notes,
                lastSeenBuildIdentifier: nil,
                hasPriorAppState: true).compactMap(\.buildIdentifier),
            [3])
    }

    func testUpdateShowsEveryUnseenReleasedNoteNewestFirst() {
        let notes = [releaseNote(2), releaseNote(4), releaseNote(1), releaseNote(3)]

        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "4",
                entries: notes,
                lastSeenBuildIdentifier: 1,
                hasPriorAppState: true).compactMap(\.buildIdentifier),
            [4, 3, 2])
    }

    @MainActor
    func testFreshInstallStoresCurrentBuildWithoutPresentingSheet() throws {
        let suite = "ReleaseNotesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let presentation = ReleaseNotesPresentation(
            currentBuildIdentifier: "2",
            hasPriorAppState: false,
            entries: [releaseNote(1), releaseNote(2)],
            defaults: defaults)

        XCTAssertFalse(presentation.isShowingCurrentRelease)
        XCTAssertEqual(defaults.integer(forKey: ReleaseNotesLifecycle.lastSeenBuildIdentifierDefaultsKey), 2)
        XCTAssertEqual(defaults.stringArray(forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey),
                       ["1", "2"])
    }

    @MainActor
    func testUpgradeNotesAreShownOnceAndCurrentBuildIsRecorded() throws {
        let suite = "ReleaseNotesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let notes = [releaseNote(1), releaseNote(2)]
        let presentation = ReleaseNotesPresentation(
            currentBuildIdentifier: "2",
            hasPriorAppState: true,
            entries: notes,
            defaults: defaults)

        XCTAssertEqual(presentation.notesToShow.compactMap(\.buildIdentifier), [2])
        XCTAssertTrue(presentation.isShowingCurrentRelease)
        XCTAssertEqual(defaults.integer(forKey: ReleaseNotesLifecycle.lastSeenBuildIdentifierDefaultsKey), 2)
        presentation.isShowingCurrentRelease = false
        XCTAssertEqual(defaults.stringArray(forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey),
                       ["1", "2"])

        let relaunched = ReleaseNotesPresentation(
            currentBuildIdentifier: "2",
            hasPriorAppState: true,
            entries: notes,
            defaults: defaults)
        XCTAssertFalse(relaunched.isShowingCurrentRelease)
    }

    @MainActor
    func testNewBuildShowsItsNotesWithoutForgettingEarlierBuilds() throws {
        let suite = "ReleaseNotesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["1"], forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey)

        let presentation = ReleaseNotesPresentation(
            currentBuildIdentifier: "2",
            hasPriorAppState: true,
            entries: [releaseNote(1), releaseNote(2)],
            defaults: defaults)

        XCTAssertTrue(presentation.isShowingCurrentRelease)
        presentation.isShowingCurrentRelease = false
        XCTAssertEqual(Set(defaults.stringArray(forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey) ?? []),
                       ["1", "2"])
    }

    @MainActor
    func testLegacySeenBuildsMigrateToTheHighestBuild() throws {
        let suite = "ReleaseNotesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["1", "59"], forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey)

        let presentation = ReleaseNotesPresentation(
            currentBuildIdentifier: "61",
            hasPriorAppState: true,
            defaults: defaults)

        XCTAssertEqual(presentation.notesToShow.compactMap(\.buildIdentifier), [61])
        XCTAssertEqual(defaults.integer(forKey: ReleaseNotesLifecycle.lastSeenBuildIdentifierDefaultsKey), 61)
        XCTAssertEqual(defaults.stringArray(forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey),
                       ["1", "59", "61"])
    }

    @MainActor
    func testLastSeenBuildNeverMovesBackward() throws {
        let suite = "ReleaseNotesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(62, forKey: ReleaseNotesLifecycle.lastSeenBuildIdentifierDefaultsKey)

        let presentation = ReleaseNotesPresentation(
            currentBuildIdentifier: "61",
            hasPriorAppState: true,
            defaults: defaults)

        XCTAssertFalse(presentation.isShowingCurrentRelease)
        XCTAssertEqual(defaults.integer(forKey: ReleaseNotesLifecycle.lastSeenBuildIdentifierDefaultsKey), 62)
    }

    func testSettingsHistoryPlacesCurrentBuildBeforeEarlierNotes() {
        let history = HarklightReleaseNotes.settingsHistory(
            currentBuildIdentifier: "2",
            entries: [releaseNote(1), releaseNote(2)])

        XCTAssertEqual(history.compactMap(\.buildIdentifier), [2, 1])
    }

    func testSettingsHistorySortsReleasedNotesWhenCurrentBuildHasNoEntry() {
        let history = HarklightReleaseNotes.settingsHistory(
            currentBuildIdentifier: "3",
            entries: [releaseNote(1), releaseNote(2)])

        XCTAssertEqual(history.compactMap(\.buildIdentifier), [2, 1])
    }

    func testSettingsHistoryHidesFutureBuildsAndSortsNewestFirst() {
        let history = HarklightReleaseNotes.settingsHistory(
            currentBuildIdentifier: "3",
            entries: [releaseNote(4), releaseNote(1), releaseNote(3), releaseNote(2)])

        XCTAssertEqual(history.compactMap(\.buildIdentifier), [3, 2, 1])
    }

    func testReleasedNotesIgnoreMalformedCurrentAndFutureBuildIdentifiers() {
        let released = HarklightReleaseNotes.releasedEntries(
            currentBuildIdentifier: "invalid",
            entries: [releaseNote(4), releaseNote(2), releaseNote(3)])

        XCTAssertTrue(released.isEmpty)

        let releasedBeforeFutureEntry = HarklightReleaseNotes.releasedEntries(
            currentBuildIdentifier: "3",
            entries: [releaseNote(4), releaseNote(2), releaseNote(3)])

        XCTAssertEqual(releasedBeforeFutureEntry.compactMap(\.buildIdentifier), [3, 2])
    }

    @MainActor
    func testBuildWithoutUnseenNotesRecordsCurrentHighWatermark() throws {
        let suite = "ReleaseNotesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["1", "2"], forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey)

        let presentation = ReleaseNotesPresentation(
            currentBuildIdentifier: "3",
            hasPriorAppState: true,
            entries: [releaseNote(1), releaseNote(2)],
            defaults: defaults)

        XCTAssertFalse(presentation.isShowingCurrentRelease)
        XCTAssertEqual(defaults.integer(forKey: ReleaseNotesLifecycle.lastSeenBuildIdentifierDefaultsKey), 3)
        XCTAssertEqual(defaults.stringArray(forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey),
                       ["1", "2", "3"])
    }

    @MainActor
    func testSavedRequestFilesCountAsPriorAppStateButFixtureFilesDoNot() throws {
        struct ProfileHeader: Encodable {
            let profileIdentity: ProfileIdentity
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseNotesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(NativeInstallationHistory.hasPersistedAttentionState(in: directory))
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        XCTAssertFalse(NativeInstallationHistory.hasPersistedAttentionState(in: directory))

        let fixtureIdentity = ProfileIdentity(
            trustedRelayAuthority: ExactText("fixture-only:attention-client-m2"),
            personID: ExactText("sample-account"),
            deviceID: ExactText("fictional-sample-device"))
        let stateURL = directory.appendingPathComponent("profile.plist")
        try PropertyListEncoder().encode(ProfileHeader(profileIdentity: fixtureIdentity)).write(to: stateURL)
        XCTAssertFalse(NativeInstallationHistory.hasPersistedAttentionState(in: directory))

        let savedAccountIdentity = ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person-1"),
            deviceID: ExactText("device-1"))
        try PropertyListEncoder().encode(ProfileHeader(profileIdentity: savedAccountIdentity)).write(to: stateURL)
        XCTAssertTrue(NativeInstallationHistory.hasPersistedAttentionState(in: directory))
    }

    private func releaseNote(_ buildIdentifier: Int) -> HarklightReleaseNote {
        HarklightReleaseNote(
            buildIdentifier: buildIdentifier,
            marketingVersion: "0.1.0",
            highlights: [])
    }
}
