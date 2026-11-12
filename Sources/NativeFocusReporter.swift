import HarklightNativeRelay
import SwiftUI

typealias NativeFocusChatVisibility = FocusReportChatVisibility

private extension FocusReportChatVisibility {
    func report(senderID: String, messageID: String) -> FocusReport {
        .chat(senderID: senderID, messageID: messageID, visibility: self)
    }
}

@MainActor
final class NativeFocusReporter {
    static let shared = NativeFocusReporter()

    private(set) var currentFocus: FocusReport? = .inbox

    typealias ReportHandler = @Sendable (FocusReport) async -> Void

    private var isSceneActive = false
    private var isSceneBackgrounded = false
    private var reportedBackground = false
    private var pendingReport: Task<Void, Never>?
    private var pendingReportRestoreFocus: FocusReport?
    private var reportDeliveryTask: Task<Void, Never>?
    private var focusBeforeSettings: FocusReport?
    private var selectionFocus: FocusReport = .inbox
    private var reportTransportID: UUID?
    private var readyTransportID: UUID?
    private var unsupportedTransportID: UUID?
    private var lastReportedFocus: FocusReport?
    private var reportHandlerGeneration = UUID()
    private var reportHandler: ReportHandler?

    private init() {}

    func installReportHandler(for transportID: UUID?, handler: ReportHandler?) {
        cancelPendingReport()
        pendingReportRestoreFocus = nil
        reportHandler = handler
        reportTransportID = handler == nil ? nil : transportID
        readyTransportID = nil
        unsupportedTransportID = nil
        lastReportedFocus = nil
        reportDeliveryTask = nil
        reportHandlerGeneration = UUID()
    }

    func selectionChanged(to report: FocusReport) {
        selectionFocus = report
        if currentFocus?.screen == .settings {
            focusBeforeSettings = focusForSelection(report, preservingChat: focusBeforeSettings)
            return
        }
        updateFocus(focusForSelection(report, preservingChat: currentFocus))
    }

    func selectionChanged(to selection: InboxSelection?) {
        selectionChanged(to: NativeFocusSelection.report(for: selection))
    }

    func conversationAppeared(senderID: String,
                              messageID: String,
                              visibility: NativeFocusChatVisibility) {
        let focus = visibility.report(senderID: senderID, messageID: messageID)
        if currentFocus?.screen == .settings {
            focusBeforeSettings = focus
        } else {
            updateFocus(focus)
        }
    }

    func conversationVisibleTurnChanged(senderID: String,
                                        messageID: String,
                                        visibility: NativeFocusChatVisibility) {
        let focus = visibility.report(senderID: senderID, messageID: messageID)
        if currentFocus?.screen == .settings {
            focusBeforeSettings = focus
        } else if currentFocus?.screen == .chat {
            updateFocus(focus)
        }
    }

    func conversationScrollBegan(senderID: String, messageID: String) {
        guard currentFocus?.screen == .chat,
              currentFocus?.senderID == senderID,
              currentFocus?.messageID == messageID,
              let restoreFocus = pendingReportRestoreFocus else { return }
        cancelPendingReport()
        pendingReportRestoreFocus = nil
        currentFocus = restoreFocus
    }

    func conversationDismissed(senderID: String, messageID: String) {
        if currentFocus?.screen == .settings {
            guard focusBeforeSettings?.screen == .chat,
                  focusBeforeSettings?.senderID == senderID,
                  focusBeforeSettings?.messageID == messageID else { return }
            focusBeforeSettings = selectionFocus
        } else {
            guard currentFocus?.screen == .chat,
                  currentFocus?.senderID == senderID,
                  currentFocus?.messageID == messageID else { return }
            updateFocus(selectionFocus)
        }
    }

    func settingsPresented(underlyingFocus: FocusReport) {
        if currentFocus?.screen != .settings {
            focusBeforeSettings = currentFocus ?? underlyingFocus
        }
        updateFocus(.settings)
    }

    func settingsDismissed(fallback: FocusReport) {
        let restored = focusBeforeSettings ?? fallback
        focusBeforeSettings = nil
        updateFocus(restored)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard !isSceneActive else { return }
            isSceneActive = true
            isSceneBackgrounded = false
            reportedBackground = false
            cancelPendingReport()
            pendingReportRestoreFocus = nil
            if let currentFocus { send(currentFocus, immediately: true) }
        case .inactive:
            isSceneActive = false
            cancelPendingReport()
            pendingReportRestoreFocus = nil
        case .background:
            isSceneActive = false
            isSceneBackgrounded = true
            cancelPendingReport()
            pendingReportRestoreFocus = nil
            guard !reportedBackground else { return }
            reportedBackground = true
            send(.notInFront, immediately: true)
        @unknown default:
            isSceneActive = false
            cancelPendingReport()
            pendingReportRestoreFocus = nil
        }
    }

    func relaySessionBecameReady(_ transportID: UUID) {
        guard reportTransportID == transportID else { return }
        guard readyTransportID != transportID else { return }
        readyTransportID = transportID
        if !isSceneBackgrounded, let currentFocus {
            send(currentFocus, immediately: true)
        } else if isSceneBackgrounded {
            send(.notInFront, immediately: true)
        }
    }

    func relaySessionDoesNotSupportFocus(_ transportID: UUID) {
        guard reportTransportID == transportID,
              readyTransportID == transportID else { return }
        unsupportedTransportID = transportID
    }

    func accountConnectionWillBeRemoved() async {
        cancelPendingReport()
        pendingReportRestoreFocus = nil
        NativePushedViewCoordinator.shared.accountConnectionWillBeRemoved()
        if let transportID = reportTransportID,
           readyTransportID == transportID,
           unsupportedTransportID != transportID,
           let delivery = enqueue(.signedOut, transportID: transportID) {
            lastReportedFocus = .signedOut
            await delivery.value
        }
        currentFocus = .inbox
        focusBeforeSettings = nil
        selectionFocus = .inbox
        installReportHandler(for: nil, handler: nil)
    }

    private func updateFocus(_ report: FocusReport) {
        let previous = currentFocus
        guard previous != report else { return }
        currentFocus = report
        let restoreFocus = pendingReportRestoreFocus ?? previous
        cancelPendingReport()
        guard isSceneActive else { return }

        if previous?.screen != report.screen {
            pendingReportRestoreFocus = nil
            send(report, immediately: true)
            return
        }

        if lastReportedFocus == report {
            pendingReportRestoreFocus = nil
            return
        }

        pendingReportRestoreFocus = restoreFocus
        pendingReport = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  let self,
                  self.currentFocus == report,
                  self.isSceneActive else { return }
            self.pendingReport = nil
            self.pendingReportRestoreFocus = nil
            self.send(report)
        }
    }

    private func focusForSelection(_ report: FocusReport,
                                   preservingChat previous: FocusReport?) -> FocusReport {
        guard previous?.screen == .chat,
              report.screen == .message,
              let previous else { return report }
        return previous
    }

    private func cancelPendingReport() {
        pendingReport?.cancel()
        pendingReport = nil
    }

    private func send(_ report: FocusReport, immediately: Bool = false) {
        guard immediately || lastReportedFocus != report,
              let transportID = reportTransportID,
              enqueue(report, transportID: transportID) != nil else { return }
        lastReportedFocus = report
    }

    @discardableResult
    private func enqueue(_ report: FocusReport, transportID: UUID) -> Task<Void, Never>? {
        guard let reportHandler,
              readyTransportID == transportID,
              unsupportedTransportID != transportID else { return nil }
        let handlerGeneration = reportHandlerGeneration
        let previousDelivery = reportDeliveryTask
        let delivery = Task.detached { [weak self] in
            await previousDelivery?.value
            guard let self,
                  !Task.isCancelled,
                  await self.canDeliverReport(handlerGeneration, transportID: transportID) else { return }
            await reportHandler(report)
        }
        reportDeliveryTask = delivery
        return delivery
    }

    private func canDeliverReport(_ generation: UUID, transportID: UUID) -> Bool {
        reportHandlerGeneration == generation &&
        reportTransportID == transportID &&
        readyTransportID == transportID &&
        unsupportedTransportID != transportID
    }
}
