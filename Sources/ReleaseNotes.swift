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
    let buildIdentifier: Int?
    let marketingVersion: String
    let historyDateDescription: LocalizedStringResource?
    /// Earliest confirmed running build that contains a dated history entry.
    /// This does not claim the unknown build number of the changes it describes.
    let visibleFromBuildIdentifier: Int?
    let highlights: [Highlight]

    init(buildIdentifier: Int, marketingVersion: String, highlights: [Highlight]) {
        id = String(buildIdentifier)
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
        visibleFromBuildIdentifier: Int,
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
    /// Keep entries newest first. A future build stays hidden until that build is installed.
    static let entries: [HarklightReleaseNote] = [
        // Conservative estimate; adjust if the archive reports a different build.
        HarklightReleaseNote(
            buildIdentifier: 72,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "reply-and-detail-responsiveness",
                    symbol: "square.and.pencil",
                    title: LocalizedStringResource(
                        "Smoother Reply and message scrolling",
                        comment: "Release-note title for less repeated work while replying and scrolling."),
                    detail: LocalizedStringResource(
                        "Typing a Reply and scrolling within a message avoid repeated refreshes.",
                        comment: "Release-note detail for Reply typing and message scrolling responsiveness."))
            ]),
        // Conservative estimate; adjust if the archive reports a different build.
        HarklightReleaseNote(
            buildIdentifier: 71,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "reply-familiar-backgrounds",
                    symbol: "square.and.pencil",
                    title: LocalizedStringResource(
                        "Reply keeps its usual background",
                        comment: "Release-note title for restoring Reply surface colors."),
                    detail: LocalizedStringResource(
                        "Reply text stays easy to read in dark appearance.",
                        comment: "Release-note detail for light Reply text and cursor in dark appearance."))
            ]),
        // Conservative estimate; adjust if the archive reports a different build.
        HarklightReleaseNote(
            buildIdentifier: 70,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "account-phone-outcome-sync",
                    symbol: "arrow.triangle.2.circlepath",
                    title: LocalizedStringResource(
                        "Seen and replies sync across your phones",
                        comment: "Release-note title for showing the same request outcome across an account's phones."),
                    detail: LocalizedStringResource(
                        "Each phone shows the same Seen state, reply, No comment choice, and Chat unread status.",
                        comment: "Release-note detail for shared request outcomes and Chat read state across account phones."))
            ]),
        // Conservative estimate; adjust if the archive reports a different build.
        HarklightReleaseNote(
            buildIdentifier: 69,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "invitation-after-disconnect",
                    symbol: "link",
                    title: LocalizedStringResource(
                        "Invitation links work after Disconnect",
                        comment: "Release-note title for joining another invitation while an earlier server removal is unconfirmed."),
                    detail: LocalizedStringResource(
                        "An earlier removal may still be pending; join the new invitation, then retry that removal later.",
                        comment: "Release-note detail for joining another invitation while keeping an earlier removal retryable."))
            ]),
        HarklightReleaseNote(
            buildIdentifier: 68,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "reply-light-on-black",
                    symbol: "square.and.pencil",
                    title: LocalizedStringResource(
                        "Reply boxes are light on black",
                        comment: "Release-note title for readable Reply fields in every appearance."),
                    detail: LocalizedStringResource(
                        "Reply text and the cursor stay light against a black background.",
                        comment: "Release-note detail for the Reply fields' fixed black surface and light text."))
            ]),
        // Conservative estimate; adjust if the archive reports a different build.
        HarklightReleaseNote(
            buildIdentifier: 67,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "reply-input-surface",
                    symbol: "square.and.pencil",
                    title: LocalizedStringResource(
                        "A more comfortable Reply field",
                        comment: "Release-note title for the refined Reply editor surface."),
                    detail: LocalizedStringResource(
                        "The editor text now has breathing room, with a subtle fill and corners that fit the Reply box.",
                        comment: "Release-note detail for the Reply editor padding, fill, and shape."))
            ]),
        // Conservative estimate; adjust if the archive reports a different build.
        HarklightReleaseNote(
            buildIdentifier: 66,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "duo-answered-top-bar",
                    symbol: "checkmark",
                    title: LocalizedStringResource(
                        "See completed requests on Duo",
                        comment: "Release-note title for completed reply status in the Duo detail toolbar."),
                    detail: LocalizedStringResource(
                        "The message toolbar keeps completed reply status visible.",
                        comment: "Release-note detail for the Answered status in the Duo detail toolbar.")),
                .init(
                    id: "chat-after-answer",
                    symbol: "bubble.left.and.bubble.right",
                    title: LocalizedStringResource(
                        "Chat keeps working after you answer",
                        comment: "Release-note title for continuing a request's conversation after its answer."),
                    detail: LocalizedStringResource(
                        "Send follow-up messages and attachments after replying or choosing No comment.",
                        comment: "Release-note detail for Chat remaining available after an answer."))
            ]),
        // Conservative estimate; adjust if the archive reports a different build.
        HarklightReleaseNote(
            buildIdentifier: 65,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "landscape-default-split",
                    symbol: "rectangle.split.2x1",
                    title: LocalizedStringResource(
                        "Landscape uses the system's default split",
                        comment: "Release-note title for the trial of the default landscape split style."),
                    detail: LocalizedStringResource(
                        "The Inbox uses the system's default split style, with landscape inline Chat unchanged.",
                        comment: "Release-note detail for the default landscape split-style trial while preserving inline Chat."))
            ]),
        HarklightReleaseNote(
            buildIdentifier: 64,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "toolbar-actions",
                    symbol: "hand.tap",
                    title: LocalizedStringResource(
                        "Open Settings and Chat on the first tap",
                        comment: "Release-note title for reachable Settings and Chat toolbar actions."),
                    detail: LocalizedStringResource(
                        "Warnings remain available from the Inbox toolbar without covering Settings or Chat.",
                        comment: "Release-note detail for keeping the warning popover user-triggered."))
            ]),
        HarklightReleaseNote(
            buildIdentifier: 63,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "duo-book-split",
                    symbol: "rectangle.split.2x1",
                    title: LocalizedStringResource(
                        "A more natural split on iPhone Duo",
                        comment: "Release-note title for the native split adapting to the Duo fold."),
                    detail: LocalizedStringResource(
                        "In landscape, your Inbox and message panes adapt around the center fold.",
                        comment: "Release-note detail for the Duo book-pose split."))
            ]),
        // Conservative estimate; adjust if the archive reports a different build.
        HarklightReleaseNote(
            buildIdentifier: 62,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "reply-box",
                    symbol: "square.and.pencil",
                    title: LocalizedStringResource(
                        "A single rounded Reply box",
                        comment: "Release-note title for the combined Reply label and editor."),
                    detail: LocalizedStringResource(
                        "The Reply label and full-width editor now sit together in one rounded box.",
                        comment: "Release-note detail about the rounded Reply box."))
            ]),
        // Conservative estimate; adjust if the archive reports a different build.
        HarklightReleaseNote(
            buildIdentifier: 61,
            marketingVersion: "0.1.0",
            highlights: [
                .init(
                    id: "inbox-scrolling",
                    symbol: "list.bullet",
                    title: LocalizedStringResource(
                        "Scroll through your Inbox more smoothly",
                        comment: "Release-note title for smoother Inbox scrolling."),
                    detail: LocalizedStringResource(
                        "Scrolling the inbox list does less work, so it should feel smoother.",
                        comment: "Release-note detail about reduced work during Inbox list scrolling.")),
                .init(
                    id: "release-note-format",
                    symbol: "sparkles",
                    title: LocalizedStringResource(
                        "See clearer release notes",
                        comment: "Release-note title for the updated note presentation."),
                    detail: LocalizedStringResource(
                        "Each update now has an icon, a short title and a clear description.",
                        comment: "Release-note detail about the updated notes."))
            ]),
        HarklightReleaseNote(
            buildIdentifier: 59,
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
            buildIdentifier: 1,
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
            visibleFromBuildIdentifier: 59,
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

    static func releasedEntries(
        currentBuildIdentifier: String?,
        entries: [HarklightReleaseNote] = HarklightReleaseNotes.entries
    ) -> [HarklightReleaseNote] {
        guard let currentBuild = currentBuildIdentifier.flatMap(Int.init) else { return [] }
        let released = entries.compactMap { note -> (note: HarklightReleaseNote, build: Int)? in
            guard let build = note.buildIdentifier, build <= currentBuild else {
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
        let entries = entries ?? HarklightReleaseNotes.entries
        let buildNotes = releasedEntries(currentBuildIdentifier: currentBuildIdentifier,
                                         entries: entries)
            .compactMap { note -> (note: HarklightReleaseNote, build: Int, priority: Int)? in
                guard let build = note.buildIdentifier else { return nil }
                return (note, build, 1)
            }
        let datedNotes = historyEntries.compactMap {
            note -> (note: HarklightReleaseNote, build: Int, priority: Int)? in
            guard note.buildIdentifier == nil,
                  let visibleFrom = note.visibleFromBuildIdentifier,
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
    static let lastSeenBuildIdentifierDefaultsKey = "release-notes.last-seen-build-identifier"

    static func lastSeenBuildIdentifier(defaults: UserDefaults) -> Int? {
        if let storedBuild = defaults.object(forKey: lastSeenBuildIdentifierDefaultsKey) as? Int {
            return storedBuild
        }
        guard let seenBuildIdentifiers = defaults.stringArray(
            forKey: seenBuildIdentifiersDefaultsKey) else { return nil }
        return seenBuildIdentifiers.compactMap(Int.init).max() ?? 0
    }

    static func notesToPresent(
        currentBuildIdentifier: String?,
        entries: [HarklightReleaseNote] = HarklightReleaseNotes.entries,
        lastSeenBuildIdentifier: Int?,
        hasPriorAppState: Bool
    ) -> [HarklightReleaseNote] {
        let released = HarklightReleaseNotes.releasedEntries(
            currentBuildIdentifier: currentBuildIdentifier,
            entries: entries)
        guard let lastSeenBuildIdentifier else {
            return hasPriorAppState ? Array(released.prefix(1)) : []
        }
        return released.filter { ($0.buildIdentifier ?? 0) > lastSeenBuildIdentifier }
    }
}

@MainActor
@Observable
final class ReleaseNotesPresentation {
    private(set) var notesToShow: [HarklightReleaseNote] = []
    @ObservationIgnored private let defaults: UserDefaults

    var isShowingCurrentRelease = false

    init(
        currentBuildIdentifier: String?,
        hasPriorAppState: Bool,
        entries: [HarklightReleaseNote]? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        let entries = entries ?? HarklightReleaseNotes.entries
        let lastSeenBuildIdentifier = ReleaseNotesLifecycle.lastSeenBuildIdentifier(defaults: defaults)
        let released = HarklightReleaseNotes.releasedEntries(
            currentBuildIdentifier: currentBuildIdentifier,
            entries: entries)
        notesToShow = ReleaseNotesLifecycle.notesToPresent(
            currentBuildIdentifier: currentBuildIdentifier,
            entries: entries,
            lastSeenBuildIdentifier: lastSeenBuildIdentifier,
            hasPriorAppState: hasPriorAppState)

        if let currentBuild = currentBuildIdentifier.flatMap(Int.init) {
            let maxSeenBuild = max(currentBuild, lastSeenBuildIdentifier ?? 0)
            defaults.set(maxSeenBuild,
                         forKey: ReleaseNotesLifecycle.lastSeenBuildIdentifierDefaultsKey)
            let seenBuildIdentifiers = Set(defaults.stringArray(
                forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey) ?? [])
                .union(released.compactMap(\.buildIdentifier).map(String.init))
                .union([String(maxSeenBuild)])
            defaults.set(seenBuildIdentifiers.sorted(),
                         forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey)
        }
        isShowingCurrentRelease = !notesToShow.isEmpty
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
