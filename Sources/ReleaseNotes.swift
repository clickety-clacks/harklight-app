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
        let text: LocalizedStringResource
    }

    let buildIdentifier: String
    let marketingVersion: String
    let title: LocalizedStringResource
    let introduction: LocalizedStringResource
    let highlights: [Highlight]

    var id: String { buildIdentifier }
}

enum HarklightReleaseNotes {
    /// Keep entries newest first. Add an entry for every build that carries
    /// user-visible changes, recording both CFBundleVersion and MARKETING_VERSION.
    static let entries: [HarklightReleaseNote] = [
        HarklightReleaseNote(
            buildIdentifier: "1",
            marketingVersion: "0.1.0",
            title: LocalizedStringResource(
                "Release notes in one place",
                comment: "Heading for a release-notes entry about finding app updates."),
            introduction: LocalizedStringResource(
                "See what’s new when you first open a release with notes, then revisit updates in Settings.",
                comment: "Introduction to the release-notes feature."),
            highlights: [
                .init(
                    id: "whats-new-sheet",
                    text: LocalizedStringResource(
                        "A short What’s New summary appears the first time you open a release that includes notes.",
                        comment: "Release-note detail about the once-per-release summary.")),
                .init(
                    id: "release-notes-settings",
                    text: LocalizedStringResource(
                        "In Settings, choose Release notes to revisit this update and earlier ones.",
                        comment: "Release-note detail explaining where to revisit updates."))
            ])
    ]

    static func currentBuildIdentifier(in bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !value.isEmpty else { return nil }
        return value
    }

    static func settingsHistory(
        currentBuildIdentifier: String?,
        entries: [HarklightReleaseNote] = HarklightReleaseNotes.entries
    ) -> [HarklightReleaseNote] {
        guard let currentBuildIdentifier,
              let current = entries.first(where: { $0.buildIdentifier == currentBuildIdentifier }) else {
            return entries
        }
        return [current] + entries.filter { $0.buildIdentifier != currentBuildIdentifier }
    }
}

enum ReleaseNotesLaunchDecision: Equatable {
    case noNotesForCurrentBuild
    case alreadySeen
    case showCurrentNotes
    case markFreshInstallSeen
}

enum ReleaseNotesLifecycle {
    static let seenBuildIdentifiersDefaultsKey = "release-notes.seen-build-identifiers"

    static func launchDecision(
        currentBuildIdentifier: String?,
        noteBuildIdentifiers: Set<String>,
        seenBuildIdentifiers: Set<String>?,
        hasPriorAppState: Bool
    ) -> ReleaseNotesLaunchDecision {
        guard let currentBuildIdentifier,
              noteBuildIdentifiers.contains(currentBuildIdentifier) else {
            return .noNotesForCurrentBuild
        }
        if let seenBuildIdentifiers {
            return seenBuildIdentifiers.contains(currentBuildIdentifier)
                ? .alreadySeen
                : .showCurrentNotes
        }
        return hasPriorAppState ? .showCurrentNotes : .markFreshInstallSeen
    }
}

@MainActor
@Observable
final class ReleaseNotesPresentation {
    private(set) var currentNote: HarklightReleaseNote?
    @ObservationIgnored private let currentBuildIdentifier: String?
    @ObservationIgnored private let defaults: UserDefaults

    var isShowingCurrentRelease = false {
        didSet {
            guard oldValue, !isShowingCurrentRelease else { return }
            markCurrentBuildSeen()
        }
    }

    init(
        currentBuildIdentifier: String?,
        hasPriorAppState: Bool,
        entries: [HarklightReleaseNote] = HarklightReleaseNotes.entries,
        defaults: UserDefaults = .standard
    ) {
        self.currentBuildIdentifier = currentBuildIdentifier
        self.defaults = defaults
        currentNote = currentBuildIdentifier.flatMap { build in
            entries.first { $0.buildIdentifier == build }
        }

        let storedSeenBuilds: Set<String>?
        if defaults.object(forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey) == nil {
            storedSeenBuilds = nil
        } else {
            storedSeenBuilds = Set(defaults.stringArray(
                forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey) ?? [])
        }
        let decision = ReleaseNotesLifecycle.launchDecision(
            currentBuildIdentifier: currentBuildIdentifier,
            noteBuildIdentifiers: Set(entries.map(\.buildIdentifier)),
            seenBuildIdentifiers: storedSeenBuilds,
            hasPriorAppState: hasPriorAppState)

        switch decision {
        case .noNotesForCurrentBuild, .alreadySeen:
            break
        case .showCurrentNotes:
            isShowingCurrentRelease = currentNote != nil
        case .markFreshInstallSeen:
            markCurrentBuildSeen()
        }
    }

    private func markCurrentBuildSeen() {
        guard let currentBuildIdentifier, currentNote != nil else { return }
        var seen = Set(defaults.stringArray(
            forKey: ReleaseNotesLifecycle.seenBuildIdentifiersDefaultsKey) ?? [])
        seen.insert(currentBuildIdentifier)
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
    let note: HarklightReleaseNote
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ReleaseNoteSection(note: note)
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
            Text(note.introduction)
            ForEach(note.highlights) { highlight in
                Text(highlight.text)
            }
        } header: {
            Text(note.title)
        } footer: {
            Text("Version \(note.marketingVersion) · Build \(note.buildIdentifier)",
                 comment: "Marketing version and build number associated with this release-notes entry.")
        }
    }
}
