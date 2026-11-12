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
    private var reportDeliveryTask: Task<Void, Never>?
    private var focusBeforeSettings: FocusReport?
    private var reportTransportID: UUID?
    private var readyTransportID: UUID?
    private var unsupportedTransportID: UUID?
    private var reportHandlerGeneration = UUID()
    private var reportHandler: ReportHandler?

    private init() {}

    func installReportHandler(for transportID: UUID?, handler: ReportHandler?) {
        cancelPendingReport()
        reportHandler = handler
        reportTransportID = handler == nil ? nil : transportID
        readyTransportID = nil
        unsupportedTransportID = nil
        reportDeliveryTask = nil
        reportHandlerGeneration = UUID()
    }

    func selectionChanged(to report: FocusReport) {
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

    func conversationDismissed(senderID: String, messageID: String) {
        let messageFocus = FocusReport.message(senderID: senderID, messageID: messageID)
        if currentFocus?.screen == .settings {
            focusBeforeSettings = messageFocus
        } else {
            updateFocus(messageFocus)
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
            if let currentFocus { send(currentFocus) }
        case .inactive:
            isSceneActive = false
            cancelPendingReport()
        case .background:
            isSceneActive = false
            isSceneBackgrounded = true
            cancelPendingReport()
            guard !reportedBackground else { return }
            reportedBackground = true
            send(.notInFront)
        @unknown default:
            isSceneActive = false
            cancelPendingReport()
        }
    }

    func relaySessionBecameReady(_ transportID: UUID) {
        guard reportTransportID == transportID else { return }
        guard readyTransportID != transportID else { return }
        readyTransportID = transportID
        if !isSceneBackgrounded, let currentFocus {
            send(currentFocus)
        } else if isSceneBackgrounded {
            send(.notInFront)
        }
    }

    func relaySessionDoesNotSupportFocus(_ transportID: UUID) {
        guard reportTransportID == transportID,
              readyTransportID == transportID else { return }
        unsupportedTransportID = transportID
    }

    func accountConnectionWillBeRemoved() async {
        cancelPendingReport()
        if let transportID = reportTransportID,
           readyTransportID == transportID,
           unsupportedTransportID != transportID,
           let delivery = enqueue(.signedOut, transportID: transportID) {
            await delivery.value
        }
        currentFocus = .inbox
        focusBeforeSettings = nil
        installReportHandler(for: nil, handler: nil)
    }

    private func updateFocus(_ report: FocusReport) {
        let previous = currentFocus
        guard previous != report else { return }
        currentFocus = report
        cancelPendingReport()
        guard isSceneActive else { return }

        if previous?.screen != report.screen {
            send(report)
            return
        }

        pendingReport = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  let self,
                  self.currentFocus == report,
                  self.isSceneActive else { return }
            self.pendingReport = nil
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

    private func send(_ report: FocusReport) {
        guard let transportID = reportTransportID else { return }
        _ = enqueue(report, transportID: transportID)
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
