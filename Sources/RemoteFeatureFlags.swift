import AttentionDomain
import Foundation
import HarklightNativeRelay
import Observation
import OSLog

/// A feature supplies its registered name and built-in default at its call site.
struct RemoteFeatureFlag: Sendable {
    let name: String
    let defaultValue: Bool

    // Default-on exception: Progress was requested, reviewed and merged before
    // servers supported flags. Older servers must continue to show it.
    static let progressInbox = Self(name: "progress_inbox", defaultValue: true)
    static let serverMatchedPushRouting = Self(name: "server_matched_push_routing", defaultValue: false)
    static let priorityLevelEditing = Self(name: "priority_level_editing", defaultValue: false)
}

/// In-memory cache for the active server. No persisted value can override a
/// server snapshot. SwiftUI observes accessor reads and updates without relaunch.
@MainActor
@Observable
final class RemoteFeatureFlags {
    private var context: ProfileContext?
    private var connectionID: UUID?
    private var values: [String: Bool] = [:]
    private let reportError: @Sendable () -> Void

    init(reportError: @escaping @Sendable () -> Void = {
        Logger(subsystem: "co.clicketyclacks.Harklight", category: "FeatureFlags")
            .error("Malformed feature_flags received; using built-in defaults for invalid values")
    }) {
        self.reportError = reportError
    }

    func isEnabled(_ flag: RemoteFeatureFlag) -> Bool {
        values[flag.name] ?? flag.defaultValue
    }

    func connect(context: ProfileContext, connectionID: UUID) {
        if self.context != context { values = [:] }
        self.context = context
        self.connectionID = connectionID
    }

    func replace(_ snapshot: RemoteFeatureFlagSnapshot, connectionID: UUID) {
        guard self.connectionID == connectionID else { return }
        values = snapshot.values
        if snapshot.hasMalformedValues { reportError() }
    }

    func reset() {
        context = nil
        connectionID = nil
        values = [:]
    }
}
