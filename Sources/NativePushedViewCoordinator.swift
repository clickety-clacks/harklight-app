import AttentionDomain
import HarklightNativeRelay
import Observation
import SwiftUI

struct NativePushedViewPair: Equatable {
    let senderID: String
    let messageID: String

    func matches(_ key: RequestKey) -> Bool {
        senderID == key.senderID.rawValue && messageID == key.messageID.rawValue
    }
}

@MainActor
@Observable
final class NativePushedViewCoordinator {
    static let shared = NativePushedViewCoordinator()

    private enum TypingSource: Hashable, Sendable {
        case replyEditors
        case conversationComposer
    }

    private(set) var passivePair: NativePushedViewPair?
    private(set) var contentTouchRevision: UInt64 = 0
    private(set) var lastTouchedPair: NativePushedViewPair?

    private struct PendingShow {
        let frame: ViewShowFrame
        let arrivalUptime: TimeInterval
    }

    @ObservationIgnored private let wire = ViewShowWire()
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private var pendingShow: PendingShow?
    @ObservationIgnored private var mostRecentOwnOpenUptime: TimeInterval?
    @ObservationIgnored private var applyHandler: (@MainActor (ViewShowFrame) async -> Void)?
    @ObservationIgnored private var sceneIsActive = false
    @ObservationIgnored private var activeStartedAt: TimeInterval?
    @ObservationIgnored private var accumulatedActiveTime: TimeInterval = 0
    @ObservationIgnored private var focusedTypingSources = Set<TypingSource>()
    @ObservationIgnored private var lastTypingActivity: TimeInterval?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var focusLossTasks: [TypingSource: Task<Void, Never>] = [:]

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    func setApplyHandler(_ handler: (@MainActor (ViewShowFrame) async -> Void)?) {
        applyHandler = handler
        if handler == nil { cancelApplyTask() }
        else { attemptPendingShow() }
    }

    func receive(_ data: Data) {
        guard let frame = wire.frame(data) else { return }
        let arrival = uptime() -
            TimeInterval(frame.heldMilliseconds ?? 0) / 1_000
        pendingShow = PendingShow(frame: frame, arrivalUptime: arrival)
        cancelApplyTask()
        attemptPendingShow()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard !sceneIsActive else { return }
            sceneIsActive = true
            activeStartedAt = uptime()
            attemptPendingShow()
        case .inactive, .background:
            pauseActiveClock()
            cancelApplyTask()
        @unknown default:
            pauseActiveClock()
            cancelApplyTask()
        }
    }

    func replyEditorFocusChanged(_ isFocused: Bool, resetActivity: Bool = false) {
        updateTypingFocus(.replyEditors, isFocused: isFocused, resetActivity: resetActivity)
    }

    func conversationComposerFocusChanged(_ isFocused: Bool) {
        updateTypingFocus(.conversationComposer, isFocused: isFocused, resetActivity: isFocused)
    }

    func noteReplyTextChanged() {
        guard isTypingFieldFocused else { return }
        lastTypingActivity = activeTimeNow
        attemptPendingShow()
    }

    /// Records a deliberate message open. Held shows older than this choice
    /// are discarded when received as well as when they become applicable.
    func recordOwnOpen() {
        let ownOpenUptime = uptime()
        mostRecentOwnOpenUptime = ownOpenUptime
        passivePair = nil
        if let pendingShow,
           pendingShow.arrivalUptime <= ownOpenUptime {
            self.pendingShow = nil
            cancelApplyTask()
        }
    }

    func isPassive(_ key: RequestKey) -> Bool {
        passivePair?.matches(key) == true
    }

    @discardableResult
    func performReadIfContentIsActive(for key: RequestKey, action: () -> Void) -> Bool {
        guard !isPassive(key) else { return false }
        action()
        return true
    }

    @discardableResult
    func contentWasTouched(_ key: RequestKey, perform action: () -> Void) -> Bool {
        guard isPassive(key) else { return false }
        lastTouchedPair = passivePair
        passivePair = nil
        contentTouchRevision &+= 1
        action()
        return true
    }

    func clearPassiveContent(_ key: RequestKey) {
        guard isPassive(key) else { return }
        passivePair = nil
    }

    func accountConnectionWillBeRemoved() {
        pendingShow = nil
        passivePair = nil
        mostRecentOwnOpenUptime = nil
        focusedTypingSources.removeAll()
        lastTypingActivity = nil
        for task in focusLossTasks.values { task.cancel() }
        focusLossTasks.removeAll()
        cancelApplyTask()
    }

    private var activeTimeNow: TimeInterval {
        accumulatedActiveTime + (activeStartedAt.map {
            max(0, uptime() - $0)
        } ?? 0)
    }

    private var typingQuietDuration: TimeInterval? {
        guard isTypingFieldFocused, let lastTypingActivity else { return nil }
        return max(0, activeTimeNow - lastTypingActivity)
    }

    private var isTypingFieldFocused: Bool {
        !focusedTypingSources.isEmpty
    }

    private func updateTypingFocus(_ source: TypingSource,
                                  isFocused: Bool,
                                  resetActivity: Bool) {
        if isFocused {
            let wasFocused = focusedTypingSources.contains(source)
            focusedTypingSources.insert(source)
            if !wasFocused || resetActivity { lastTypingActivity = activeTimeNow }
            focusLossTasks[source]?.cancel()
            focusLossTasks[source] = nil
            attemptPendingShow()
            return
        }
        guard focusedTypingSources.contains(source), sceneIsActive else { return }
        focusLossTasks[source]?.cancel()
        focusLossTasks[source] = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.focusLossTasks[source] = nil
            guard self.sceneIsActive else { return }
            self.focusedTypingSources.remove(source)
            if self.focusedTypingSources.isEmpty { self.lastTypingActivity = nil }
            self.attemptPendingShow()
        }
    }

    private func pauseActiveClock() {
        guard let activeStartedAt else {
            sceneIsActive = false
            return
        }
        accumulatedActiveTime += max(0, uptime() - activeStartedAt)
        self.activeStartedAt = nil
        sceneIsActive = false
    }

    func attemptPendingShow() {
        cancelApplyTask()
        guard sceneIsActive, let pendingShow, let applyHandler else { return }

        if let mostRecentOwnOpenUptime,
           pendingShow.arrivalUptime <= mostRecentOwnOpenUptime {
            self.pendingShow = nil
            return
        }

        if let typingQuietDuration, typingQuietDuration < 5 {
            let remaining = 5 - typingQuietDuration
            applyTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, let self else { return }
                self.applyTask = nil
                self.attemptPendingShow()
            }
            return
        }

        self.pendingShow = nil
        passivePair = NativePushedViewPair(senderID: pendingShow.frame.senderID,
                                           messageID: pendingShow.frame.messageID)
        Task { @MainActor in await applyHandler(pendingShow.frame) }
    }

    private func cancelApplyTask() {
        applyTask?.cancel()
        applyTask = nil
    }
}
