import XCTest
@testable import Harklight
import AttentionDomain

final class ReleaseNotesTests: XCTestCase {
    func testBuildOneReleaseNoteShowsMarketingVersionAndRetainsBuildIdentity() throws {
        let first = try XCTUnwrap(HarklightReleaseNotes.entries.first { $0.buildIdentifier == "1" })

        XCTAssertEqual(first.marketingVersion, "0.1.0")
        XCTAssertEqual(first.buildIdentifier, "1")
    }

    func testFreshInstallDoesNotPresentPreviouslyReleasedNotes() {
        let notes = [releaseNote("1"), releaseNote("2")]

        XCTAssertTrue(ReleaseNotesLifecycle.notesToPresent(
            currentBuildIdentifier: "2",
            entries: notes,
            seenBuildIdentifiers: nil,
            hasPriorAppState: false).isEmpty)
    }

    func testLegacyUpgradeShowsNewestReleasedNoteOnly() {
        let notes = [releaseNote("1"), releaseNote("3"), releaseNote("2"), releaseNote("4")]

        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "3",
                entries: notes,
                seenBuildIdentifiers: nil,
                hasPriorAppState: true).map(\.buildIdentifier),
            ["3"])
    }

    func testUpdateShowsEveryUnseenReleasedNoteNewestFirst() {
        let notes = [releaseNote("2"), releaseNote("4"), releaseNote("1"), releaseNote("3")]

        XCTAssertEqual(
            ReleaseNotesLifecycle.notesToPresent(
                currentBuildIdentifier: "4",
                entries: notes,
                seenBuildIdentifiers: ["1"],
                hasPriorAppState: true).map(\.buildIdentifier),
            ["4", "3", "2"])
    }

    @MainActor
    func testFreshInstallStoresCurrentBuildWithoutPresentingSheet() throws {
        let suite = "ReleaseNotesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let presentation = ReleaseNotesPresentation(
            currentBuildIdentifier: "2",
            hasPriorAppState: false,
            entries: [releaseNote("1"), releaseNote("2")],
            defaults: defaults)

        XCTAssertFalse(presentation.isShowingCurrentRelease)
        XCTAssertEqual(defaults.stringArray(forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey),
                       ["1", "2"])
    }

    @MainActor
    func testUpgradeNotesAreShownOnceAndDismissalPersistsReleasedBuilds() throws {
        let suite = "ReleaseNotesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let notes = [releaseNote("1"), releaseNote("2")]
        let presentation = ReleaseNotesPresentation(
            currentBuildIdentifier: "2",
            hasPriorAppState: true,
            entries: notes,
            defaults: defaults)

        XCTAssertEqual(presentation.notesToShow.map(\.buildIdentifier), ["2"])
        XCTAssertTrue(presentation.isShowingCurrentRelease)
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
            entries: [releaseNote("1"), releaseNote("2")],
            defaults: defaults)

        XCTAssertTrue(presentation.isShowingCurrentRelease)
        presentation.isShowingCurrentRelease = false
        XCTAssertEqual(Set(defaults.stringArray(forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey) ?? []),
                       ["1", "2"])
    }

    func testSettingsHistoryPlacesCurrentBuildBeforeEarlierNotes() {
        let history = HarklightReleaseNotes.settingsHistory(
            currentBuildIdentifier: "2",
            entries: [releaseNote("1"), releaseNote("2")])

        XCTAssertEqual(history.map(\.buildIdentifier), ["2", "1"])
    }

    func testSettingsHistorySortsReleasedNotesWhenCurrentBuildHasNoEntry() {
        let history = HarklightReleaseNotes.settingsHistory(
            currentBuildIdentifier: "3",
            entries: [releaseNote("1"), releaseNote("2")])

        XCTAssertEqual(history.map(\.buildIdentifier), ["2", "1"])
    }

    func testSettingsHistoryHidesFutureBuildsAndSortsNewestFirst() {
        let history = HarklightReleaseNotes.settingsHistory(
            currentBuildIdentifier: "3",
            entries: [releaseNote("4"), releaseNote("1"), releaseNote("3"), releaseNote("2")])

        XCTAssertEqual(history.map(\.buildIdentifier), ["3", "2", "1"])
    }

    func testReleasedNotesIgnoreMalformedAndFutureBuildIdentifiers() {
        let released = HarklightReleaseNotes.releasedEntries(
            currentBuildIdentifier: "3",
            entries: [releaseNote("future"), releaseNote("4"), releaseNote("2"), releaseNote("3")])

        XCTAssertEqual(released.map(\.buildIdentifier), ["3", "2"])
    }

    @MainActor
    func testBuildWithoutUnseenNotesDoesNotPresentSheetOrChangeSeenBuilds() throws {
        let suite = "ReleaseNotesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["1", "2"], forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey)

        let presentation = ReleaseNotesPresentation(
            currentBuildIdentifier: "3",
            hasPriorAppState: true,
            entries: [releaseNote("1"), releaseNote("2")],
            defaults: defaults)

        XCTAssertFalse(presentation.isShowingCurrentRelease)
        XCTAssertEqual(defaults.stringArray(forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey),
                       ["1", "2"])
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

    private func releaseNote(_ buildIdentifier: String) -> HarklightReleaseNote {
        HarklightReleaseNote(
            buildIdentifier: buildIdentifier,
            marketingVersion: "0.1.0",
            title: "Release update",
            introduction: "A release update.",
            highlights: [])
    }
}
