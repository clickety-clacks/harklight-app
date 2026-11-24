import HarklightNativeRelay
import Observation
import SwiftUI
import UIKit

/// Main-actor view of the Error Log for SwiftUI. It only reads and observes;
/// reporting and resolving go through `ErrorLogging` on the store, never
/// through this model, so no view can clear a record.
@MainActor
@Observable
final class ErrorLogModel {
    @ObservationIgnored let store: ErrorLogStore
    private(set) var records: [ErrorLogRecord]
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    init(store: ErrorLogStore) {
        self.store = store
        records = store.records
        store.setChangeHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        // Writes are batched in the background; make sure none is pending when
        // the app leaves the foreground or ends.
        for name in [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil) { [store] _ in store.flush() })
        }
    }

    func refresh() { records = store.records }

    var persistenceNote: String? {
        if case let .memoryFallback(cause) = store.persistenceStatus {
            return "The error log could not be saved (\(cause)). It is kept in memory until the app closes."
        }
        return nil
    }
}

extension EnvironmentValues {
    @Entry var errorLogModel: ErrorLogModel? = nil
}

private extension ErrorLogConcern {
    var failureTitle: String {
        switch self {
        case .snapshot: "Couldn't refresh"
        case .sync: "Live updates paused"
        case .actions: "Not delivered"
        }
    }

    var symbol: String {
        switch self {
        case .snapshot: "arrow.triangle.2.circlepath"
        case .sync: "pause.circle"
        case .actions: "exclamationmark.bubble"
        }
    }
}

private func errorLogTime(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}

/// A current failure and its recovery action. History and details live in Settings.
struct ErrorLogContextBanner: View {
    let surface: ErrorLogSurface
    @Environment(\.errorLogModel) private var model

    var body: some View {
        if let model,
           case let .failing(record)? = ErrorLogDisplay.inContext(
               records: model.records, surface: surface, now: Date()) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: record.concern.symbol)
                    .foregroundStyle(.hkCoral)
                    .accessibilityHidden(true)
                Text(record.concern == .actions && record.code == APIErrorToken.internalError.rawValue
                     ? "Delivery unconfirmed" : record.concern.failureTitle)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if record.code == APIErrorToken.internalError.rawValue {
                    Button("Try again") {
                        Task { await NativeRelayLifecycle.shared.retryV2InternalError(record) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .foregroundStyle(.hkText)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.hkRaised, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12).padding(.top, 6)
            .accessibilityIdentifier("error-log-banner-\(record.concern.rawValue)")
        }
    }
}

/// The inbox list's failure rows: live updates (sync) and refresh (snapshot).
/// Emits no row at all when there is nothing to show.
struct ErrorLogInboxBannerRows: View {
    @Environment(\.errorLogModel) private var model

    var body: some View {
        if let model {
            if shows(.liveIndicator, in: model) { bannerRow(.liveIndicator) }
            if shows(.inbox, in: model) { bannerRow(.inbox) }
        }
    }

    private func shows(_ surface: ErrorLogSurface, in model: ErrorLogModel) -> Bool {
        if case .failing? = ErrorLogDisplay.inContext(records: model.records, surface: surface, now: Date()) {
            return true
        }
        return false
    }

    private func bannerRow(_ surface: ErrorLogSurface) -> some View {
        ErrorLogContextBanner(surface: surface)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}

/// Selectable plain `key: value` text for one record, with Copy details.
struct ErrorLogDetailsContent: View {
    let record: ErrorLogRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            Text(ErrorLogDetails.text(for: record))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .accessibilityIdentifier("error-log-details-text")
        }
        .background(.hkBackground)
        .foregroundStyle(.hkText)
        .navigationTitle("Error details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy details") {
                    UIPasteboard.general.string = ErrorLogDetails.text(for: record)
                }
                .accessibilityIdentifier("error-log-copy-details")
            }
            if record.code == APIErrorToken.internalError.rawValue, !record.isResolved {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Try again") {
                        Task { await NativeRelayLifecycle.shared.retryV2InternalError(record) }
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Every record in the log, newest first.
struct ErrorLogDiagnosticsScreen: View {
    let model: ErrorLogModel

    var body: some View {
        List {
            if let note = model.persistenceNote {
                Text(note).font(.footnote).foregroundStyle(.hkSecondary)
            }
            if model.records.isEmpty {
                Text("No errors recorded.").foregroundStyle(.hkSecondary)
            }
            ForEach(model.records) { record in
                NavigationLink {
                    ErrorLogDetailsContent(record: record)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(record.concern.rawValue) · \(record.operation)")
                            .font(.callout.weight(.semibold))
                        Text("\(record.domain) \(record.code) · \(record.initiator.rawValue)")
                            .font(.footnote).foregroundStyle(.hkSecondary)
                        Text(summary(record)).font(.footnote).foregroundStyle(.hkSecondary)
                    }
                }
                .accessibilityIdentifier("error-log-record")
            }
        }
        .harklightListSurface(.sheet)
        .navigationTitle("Error log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy all details") {
                    UIPasteboard.general.string = ErrorLogDetails.text(for: model.records)
                }
                .disabled(model.records.isEmpty)
                .accessibilityIdentifier("error-log-copy-all")
            }
        }
    }

    private func summary(_ record: ErrorLogRecord) -> String {
        var text = errorLogTime(record.lastAt)
        if record.count > 1 { text += " · \(record.count) times" }
        text += record.isResolved ? " · resolved" : " · unresolved"
        return text
    }
}
