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
    /// Draft and send state for one request, without exposing message content.
    func uiDiagnosticSummary(for key: RequestKey, revision: UInt64) -> String {
        let thread = conversation(for: key)
        let draft = conversationDraft(for: key, revision: revision)
        let files = draft.files.map(\.id.rawValue)
        let carriedOver = draft.carriedOverSend.map {
            "op=\($0.operationID?.uuidString.prefix(8) ?? "nil") text=\($0.text.rawValue.count) unsettled=\($0.currentAttemptUnsettled)"
        } ?? "nil"
        return [
            "request=\(UIDiagnostics.describe(key)) revision=\(revision) currentRevision=\(thread.map { String($0.currentRevision) } ?? "nil")",
            "readOnly=\(isReadOnly) local=\(isLocalExample) error=\(conversationError ?? "nil")",
            "draft text=\(draft.text.rawValue.count) disposition=\(draft.disposition) operation=\(draft.operationID?.uuidString.prefix(8) ?? "nil") inFlight=\(draft.inFlightOperationID?.uuidString.prefix(8) ?? "nil") unsettled=\(draft.currentAttemptUnsettled) files=\(files)",
            "failure=\(draft.failure?.summary ?? "nil") carriedOver=\(carriedOver)",
            UIDiagnostics.shared.eventSummary,
        ].joined(separator: " | ")
    }
}
