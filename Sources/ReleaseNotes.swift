import AttentionDomain
import Foundation
import Observation
import SwiftUI

private struct PersistedAttentionStateHeader: Decodable {
    let profileIdentity: ProfileIdentity
}

struct HarklightReleaseNote: Identifiable, Sendable {
    struct Highlight: Identifiable, Sendable {
        let id: String
        let symbol: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
    }

    let id: String
    let buildIdentifier: String?
    let marketingVersion: String
    let historyDateDescription: LocalizedStringResource?
    /// Earliest confirmed running build that contains a dated history entry.
    /// This does not claim the unknown build number of the changes it describes.
    let visibleFromBuildIdentifier: String?
    let highlights: [Highlight]

    init(buildIdentifier: String, marketingVersion: String, highlights: [Highlight]) {
        id = buildIdentifier
        self.buildIdentifier = buildIdentifier
        self.marketingVersion = marketingVersion
        historyDateDescription = nil
        visibleFromBuildIdentifier = nil
        self.highlights = highlights
    }

    init(
        historyIdentifier: String,
        marketingVersion: String,
        historyDateDescription: LocalizedStringResource,
        visibleFromBuildIdentifier: String,
        highlights: [Highlight]
    ) {
        id = historyIdentifier
        buildIdentifier = nil
        self.marketingVersion = marketingVersion
        self.historyDateDescription = historyDateDescription
        self.visibleFromBuildIdentifier = visibleFromBuildIdentifier
        self.highlights = highlights
    }
}

enum HarklightReleaseNotes {
    /// Keep entries newest first. Add an entry for every build that carries
    /// user-visible changes, recording both CFBundleVersion and MARKETING_VERSION.
    static let entries: [HarklightReleaseNote] = [
        HarklightReleaseNote(
            buildIdentifier: "59",
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "settings-toolbar",
                    symbol: "gearshape",
                    title: LocalizedStringResource(
                        "Settings in the toolbar",
                        comment: "Short release-note title for opening Settings from the top toolbar."),
                    detail: LocalizedStringResource(
                        "Open Settings from the top toolbar on any screen size.",
                        comment: "One-sentence release-note detail about reaching Settings."))
            ]),
        HarklightReleaseNote(
            buildIdentifier: "1",
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "whats-new-sheet",
                    symbol: "sparkles",
                    title: LocalizedStringResource(
                        "What’s New after an update",
                        comment: "Short release-note title for the update summary."),
                    detail: LocalizedStringResource(
                        "See a short summary the first time you open a release that includes notes.",
                        comment: "One-sentence release-note detail about the update summary.")),
                .init(
                    id: "release-notes-settings",
                    symbol: "doc.text",
                    title: LocalizedStringResource(
                        "Release notes in Settings",
                        comment: "Short release-note title for the update history."),
                    detail: LocalizedStringResource(
                        "Find this and earlier updates in Settings.",
                        comment: "One-sentence release-note detail about the update history."))
            ])
    ]

    /// These changes shipped before Build 59, but their archived build numbers
    /// are not available. Show their dated summary in Settings from the first
    /// confirmed build containing them; never present it as a new-build popup.
    static let historyEntries: [HarklightReleaseNote] = [
        HarklightReleaseNote(
            historyIdentifier: "earlier-on-2026-10-25",
            marketingVersion: "0.1.0",
            historyDateDescription: LocalizedStringResource(
                "Earlier on October 25, 2026",
                comment: "Date label for shipped changes whose build number is unknown."),
            visibleFromBuildIdentifier: "59",
            highlights: [
                .init(
                    id: "inline-reply-field",
                    symbol: "square.and.pencil",
                    title: LocalizedStringResource(
                        "Reply right from the message",
                        comment: "Release-note title for composing a text reply inline with a request."),
                    detail: LocalizedStringResource(
                        "Write and send a text reply from the request itself.",
                        comment: "Release-note detail about the inline reply field.")),
                .init(
                    id: "listening-status",
                    symbol: "waveform",
                    title: LocalizedStringResource(
                        "See when your agent is listening",
                        comment: "Release-note title for listening availability in Chat."),
                    detail: LocalizedStringResource(
                        "The Chat sheet shows listening status near the composer.",
                        comment: "Release-note detail about listening availability.")),
                .init(
                    id: "chat-toolbar",
                    symbol: "bubble.left.and.bubble.right",
                    title: LocalizedStringResource(
                        "Open Chat from the message toolbar",
                        comment: "Release-note title for opening Chat from a message."),
                    detail: LocalizedStringResource(
                        "Find Chat in the message toolbar and see when a conversation is unavailable.",
                        comment: "Release-note detail about Chat access and availability.")),
                .init(
                    id: "chat-history-keyboard",
                    symbol: "keyboard",
                    title: LocalizedStringResource(
                        "Keep your keyboard while reading",
                        comment: "Release-note title for using the keyboard while browsing Chat history."),
                    detail: LocalizedStringResource(
                        "Scroll through older Chat messages without losing the keyboard, or swipe the history to dismiss it.",
                        comment: "Release-note detail about keyboard behavior in Chat history."))
            ])
    ]

    /// Bind the current-build note to the running app's CFBundleVersion,
    /// rather than assuming the source project's build setting is the archive value.
    static func entriesForCurrentBuild(
        currentBuildIdentifier: String?,
        marketingVersion: String?,
        previousEntries: [HarklightReleaseNote] = entries
    ) -> [HarklightReleaseNote] {
        guard let currentBuildIdentifier,
              let currentBuild = Int(currentBuildIdentifier),
              let marketingVersion, !marketingVersion.isEmpty,
              let latestNumberedBuild = previousEntries
                .compactMap({ $0.buildIdentifier.flatMap(Int.init) })
                .max(),
              currentBuild > latestNumberedBuild else {
            return previousEntries
        }

        // Once a pending highlight is recorded under a known build, do not
        // present it as a new current-build change on later releases.
        let numberedHighlightIDs = Set(previousEntries
            .filter { $0.buildIdentifier != nil }
            .flatMap { $0.highlights.map(\.id) })
        let pendingHighlights = currentBuildHighlights.filter {
            !numberedHighlightIDs.contains($0.id)
        }
        guard !pendingHighlights.isEmpty else { return previousEntries }

        let currentBuildEntry = HarklightReleaseNote(
            buildIdentifier: currentBuildIdentifier,
            marketingVersion: marketingVersion,
            highlights: pendingHighlights)
        return [currentBuildEntry] + previousEntries
    }

    /// Notes for changes in the next source archive. The entry's build and
    /// marketing versions are resolved from the archived app's bundle metadata.
    static let currentBuildHighlights: [HarklightReleaseNote.Highlight] = [
        .init(
            id: "inbox-scrolling",
            symbol: "list.bullet",
            title: LocalizedStringResource(
                "Scroll through your Inbox more smoothly",
                comment: "Release-note title for smoother Inbox scrolling."),
            detail: LocalizedStringResource(
                "Keep your place while browsing messages and loading older items.",
                comment: "Release-note detail about Inbox scrolling.")),
        .init(
            id: "release-note-format",
            symbol: "sparkles",
            title: LocalizedStringResource(
                "See clearer release notes",
                comment: "Release-note title for the updated note presentation."),
            detail: LocalizedStringResource(
                "Each update now has an icon, a short title and a clear description.",
                comment: "Release-note detail about the updated notes presentation.")),
        .init(
            id: "single-rounded-reply-box",
            symbol: "square.and.pencil",
            title: LocalizedStringResource(
                "A single rounded Reply box",
                comment: "Release-note title for the combined inline Reply label and editor."),
            detail: LocalizedStringResource(
                "The Reply label and full-width editor now sit together in one rounded box.",
                comment: "Release-note detail for the combined inline Reply editor."))
    ]

    static func currentBuildIdentifier(in bundle: Bundle = .main) -> String? {
        if ProcessInfo.processInfo.environment["HARKLIGHT_RELEASE_NOTES_UI_TEST"] == "1",
           let testBuild = ProcessInfo.processInfo.environment["HARKLIGHT_RELEASE_NOTES_UI_TEST_BUILD"],
           !testBuild.isEmpty {
            return testBuild
        }
        guard let value = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !value.isEmpty else { return nil }
        return value
    }

    static func currentMarketingVersion(in bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !value.isEmpty else { return nil }
        return value
    }

    static func releasedEntries(
        currentBuildIdentifier: String?,
        entries: [HarklightReleaseNote] = HarklightReleaseNotes.entries
    ) -> [HarklightReleaseNote] {
        guard let currentBuild = currentBuildIdentifier.flatMap(Int.init) else { return [] }
        let released = entries.compactMap { note -> (note: HarklightReleaseNote, build: Int)? in
            guard let buildIdentifier = note.buildIdentifier,
                  let build = Int(buildIdentifier), build <= currentBuild else {
                return nil
            }
            return (note: note, build: build)
        }
        return released.sorted { $0.build > $1.build }.map(\.note)
    }

    static func settingsHistory(
        currentBuildIdentifier: String?,
        entries: [HarklightReleaseNote]? = nil,
        historyEntries: [HarklightReleaseNote] = HarklightReleaseNotes.historyEntries
    ) -> [HarklightReleaseNote] {
        guard let currentBuild = currentBuildIdentifier.flatMap(Int.init) else { return [] }
        let entries = entries ?? entriesForCurrentBuild(
            currentBuildIdentifier: currentBuildIdentifier,
            marketingVersion: currentMarketingVersion())
        let buildNotes = releasedEntries(currentBuildIdentifier: currentBuildIdentifier,
                                         entries: entries)
            .compactMap { note -> (note: HarklightReleaseNote, build: Int, priority: Int)? in
                guard let buildIdentifier = note.buildIdentifier,
                      let build = Int(buildIdentifier) else { return nil }
                return (note, build, 1)
            }
        let datedNotes = historyEntries.compactMap {
            note -> (note: HarklightReleaseNote, build: Int, priority: Int)? in
            guard note.buildIdentifier == nil,
                  let visibleFrom = note.visibleFromBuildIdentifier.flatMap(Int.init),
                  visibleFrom <= currentBuild else { return nil }
            return (note, visibleFrom, 0)
        }
        return (buildNotes + datedNotes)
            .sorted {
                if $0.build != $1.build { return $0.build > $1.build }
                return $0.priority > $1.priority
            }
            .map(\.note)
    }
}

enum ReleaseNotesLifecycle {
    static let seenBuildIdentifiersDefaultsKey = "release-notes.seen-build-identifiers"

    static func notesToPresent(
        currentBuildIdentifier: String?,
        entries: [HarklightReleaseNote] = HarklightReleaseNotes.entries,
        seenBuildIdentifiers: Set<String>?,
        hasPriorAppState: Bool
    ) -> [HarklightReleaseNote] {
        let released = HarklightReleaseNotes.releasedEntries(
            currentBuildIdentifier: currentBuildIdentifier,
            entries: entries)
        guard let seenBuildIdentifiers else {
            return hasPriorAppState ? Array(released.prefix(1)) : []
        }
        return released.filter { note in
            guard let buildIdentifier = note.buildIdentifier else { return false }
            return !seenBuildIdentifiers.contains(buildIdentifier)
        }
    }
}

@MainActor
@Observable
final class ReleaseNotesPresentation {
    private(set) var notesToShow: [HarklightReleaseNote] = []
    @ObservationIgnored private let currentBuildIdentifier: String?
    @ObservationIgnored private let releasedBuildIdentifiers: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    var isShowingCurrentRelease = false {
        didSet {
            guard oldValue, !isShowingCurrentRelease else { return }
            markReleasedBuildsSeen()
        }
    }

    init(
        currentBuildIdentifier: String?,
        hasPriorAppState: Bool,
        entries: [HarklightReleaseNote]? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.currentBuildIdentifier = currentBuildIdentifier
        self.defaults = defaults
        let entries = entries ?? HarklightReleaseNotes.entriesForCurrentBuild(
            currentBuildIdentifier: currentBuildIdentifier,
            marketingVersion: HarklightReleaseNotes.currentMarketingVersion())
        let released = HarklightReleaseNotes.releasedEntries(
            currentBuildIdentifier: currentBuildIdentifier,
            entries: entries)
        releasedBuildIdentifiers = Set(released.compactMap(\.buildIdentifier))

        let storedSeenBuilds: Set<String>?
        if defaults.object(forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey) == nil {
            storedSeenBuilds = nil
        } else {
            storedSeenBuilds = Set(defaults.stringArray(
                forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey) ?? [])
        }
        notesToShow = ReleaseNotesLifecycle.notesToPresent(
            currentBuildIdentifier: currentBuildIdentifier,
            entries: entries,
            seenBuildIdentifiers: storedSeenBuilds,
            hasPriorAppState: hasPriorAppState)

        if storedSeenBuilds == nil, !hasPriorAppState {
            markReleasedBuildsSeen()
        }
        isShowingCurrentRelease = !notesToShow.isEmpty
    }

    private func markReleasedBuildsSeen() {
        var seen = Set(defaults.stringArray(
            forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey) ?? [])
        seen.formUnion(releasedBuildIdentifiers)
        if let currentBuildIdentifier { seen.insert(currentBuildIdentifier) }
        defaults.set(seen.sorted(), forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey)
    }
}

@MainActor
enum NativeInstallationHistory {
    static func hasPriorAppState(
        enrollment: NativeEnrollmentStore,
        guidedJoin: NativeGuidedJoinStore,
        attentionDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        do {
            if try enrollment.hasSavedInstallationState() { return true }
            if try guidedJoin.loadAttempt() != nil { return true }
            if try guidedJoin.departure() != nil { return true }
            let archivedDepartures = try guidedJoin.archivedDepartures()
            if !archivedDepartures.isEmpty { return true }
        } catch {
            // If saved-state inspection is unavailable, favor showing the
            // upgrade notes over silently treating an existing installation as new.
            return true
        }

        let directoryURL: URL
        if let attentionDirectoryURL {
            directoryURL = attentionDirectoryURL
        } else {
            do {
                directoryURL = try FileAttentionStatePersistence.applicationSupport().directoryURL
            } catch {
                return true
            }
        }
        if hasPersistedAttentionState(in: directoryURL, fileManager: fileManager) { return true }
        return false
    }

    static func hasPersistedAttentionState(
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return false }
        do {
            let files = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey])
                .filter { $0.pathExtension == "plist" && !$0.lastPathComponent.hasPrefix(".") }
            for url in files {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let header = try PropertyListDecoder().decode(PersistedAttentionStateHeader.self, from: data)
                if header.profileIdentity.trustedRelayAuthority.rawValue.hasPrefix("fixture-only:") {
                    continue
                }
                return true
            }
            return false
        } catch {
            // An unreadable profile may still contain real prior user data.
            return true
        }
    }
}

struct ReleaseNotesSettingsSection: View {
    let notes: [HarklightReleaseNote]

    var body: some View {
        Section("About") {
            NavigationLink {
                ReleaseNotesHistoryView(notes: notes)
            } label: {
                Label("Release notes", systemImage: "doc.text")
            }
            .accessibilityHint("See the latest release notes and earlier updates")
        }
    }
}

struct ReleaseNotesHistoryView: View {
    let notes: [HarklightReleaseNote]

    var body: some View {
        List {
            ForEach(notes) { note in
                ReleaseNoteSection(note: note)
            }
        }
        .navigationTitle("Release notes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReleaseNotesSheet: View {
    let notes: [HarklightReleaseNote]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(notes) { note in
                    ReleaseNoteSection(note: note)
                }
            }
            .navigationTitle("What’s New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ReleaseNoteSection: View {
    let note: HarklightReleaseNote

    var body: some View {
        Section {
            ForEach(note.highlights) { highlight in
                ReleaseNoteRow(highlight: highlight)
            }
        } header: {
            if let buildIdentifier = note.buildIdentifier {
                Text("Version \(note.marketingVersion) · Build \(buildIdentifier)",
                     comment: "Marketing version and build number associated with this release-notes entry.")
            } else if let historyDateDescription = note.historyDateDescription {
                Text("Version \(note.marketingVersion) · \(historyDateDescription)",
                     comment: "Marketing version and date associated with this history-only entry.")
            }
        }
    }
}

private struct ReleaseNoteRow: View {
    let highlight: HarklightReleaseNote.Highlight

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.title).font(.headline)
                Text(highlight.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: highlight.symbol)
                .font(.title2)
                .frame(width: 36)
        }
    }
}
