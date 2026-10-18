import AttentionDomain
import Observation
import SwiftUI

/// State capture for UI tests, active only with `--harklight-ui-diagnostics`.
/// It records navigation events and exposes current view and store state as
/// invisible accessibility text that a test can read at its failure point.
@MainActor @Observable
final class UIDiagnostics {
    static let shared = UIDiagnostics()

    @ObservationIgnored let enabled = ProcessInfo.processInfo.arguments.contains("--harklight-ui-diagnostics")
    private(set) var events: [String] = []
    @ObservationIgnored private var sequence = 0

    func record(_ event: @autoclosure () -> String) {
        guard enabled else { return }
        sequence += 1
        events.append("\(sequence) \(event())")
        if events.count > 30 { events.removeFirst(events.count - 30) }
    }

    var eventSummary: String { "events=[" + events.joined(separator: "; ") + "]" }

    static func describe(_ selection: InboxSelection?) -> String {
        switch selection {
        case let .request(key): "request:" + key.messageID.rawValue
        case let .sample(id): "sample:" + id
        case nil: "nil"
        }
    }

    static func describe(_ key: RequestKey?) -> String {
        key.map { $0.messageID.rawValue } ?? "nil"
    }
}

struct UIDiagnosticsProbe: View {
    let identifier: String
    let summary: String

    var body: some View {
        Text(summary)
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityLabel(summary)
            .accessibilityIdentifier(identifier)
    }
}

extension View {
    /// Adds a diagnostics probe only when UI diagnostics are enabled.
    @ViewBuilder
    func uiDiagnostics(_ identifier: String, _ summary: @autoclosure () -> String) -> some View {
        if UIDiagnostics.shared.enabled {
            overlay(alignment: .topLeading) { UIDiagnosticsProbe(identifier: identifier, summary: summary()) }
        } else {
            self
        }
    }
}

extension LivePresentationStore {
    /// Cleanup, upload binding and composer readiness for one request.
    func uiDiagnosticSummary(for key: RequestKey, revision: UInt64) -> String {
        let thread = conversation(for: key)
        let draft = conversationDraft(for: key, revision: revision)
        let groups = (thread?.uploadGroups ?? [:]).values.sorted { $0.operationID.uuidString < $1.operationID.uuidString }
            .map { group in
                "op=\(group.operationID.uuidString.prefix(8)) rev=\(group.binding.revision) cleanup=\(group.cleanupID.map { String($0.uuidString.prefix(8)) } ?? "nil") originals=\(group.originals.map { $0.id.rawValue }) uploaded=\(group.uploaded.count)"
            }
        let cleanups = (thread?.uploadCleanups ?? [:]).values.sorted { $0.id.uuidString < $1.id.uuidString }
            .map { cleanup in
                let outcome: String = switch cleanup.outcome {
                case .pending: "pending"
                case .unknown: "unknown"
                case let .acknowledged(result): "acknowledged-\(result.state.rawValue)"
                }
                return "id=\(cleanup.id.uuidString.prefix(8)) rev=\(cleanup.binding.revision) ops=\(cleanup.uploadOperations.map { String($0.uuidString.prefix(8)) }) outcome=\(outcome)"
            }
        let files = draft.files.map { "\($0.id.rawValue):reselect=\(uploadNeedsReselection($0, for: key, revision: revision))" }
        return [
            "request=\(UIDiagnostics.describe(key)) revision=\(revision) currentRevision=\(thread.map { String($0.currentRevision) } ?? "nil")",
            "readOnly=\(isReadOnly) local=\(isLocalExample) error=\(conversationError ?? "nil")",
            "draft text=\(draft.text.rawValue.count) disposition=\(draft.disposition) files=\(files)",
            "pendingCleanup=\(hasPendingUploadCleanup(for: key, revision: revision)) unreadyUpload=\(hasUnreadyUploadReference(for: key, revision: revision)) abandoned=\(hasAbandonedDiscussion(for: key, revision: revision))",
            "groups=\(groups) cleanups=\(cleanups)",
            UIDiagnostics.shared.eventSummary,
        ].joined(separator: " | ")
    }
}
