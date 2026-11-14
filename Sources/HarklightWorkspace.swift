import SwiftUI
import UIKit
import AttentionDomain

extension HarklightMessageType {
    /// The design type of a message from its wire type and kind, as the app
    /// and the web page share it. An untyped legacy message is an fyi when it
    /// carries the Seen descriptor and a request otherwise.
    init(declaredType: MessageTypeValue?, kind: MessageKindValue?, hasSeenDescriptor: Bool) {
        let type = declaredType ?? (hasSeenDescriptor ? .fyi : .request)
        switch (type, kind) {
        case (.request, .blocker): self = .error
        case (.request, _): self = .request
        case (.fyi, .blocker): self = .warning
        case (.fyi, .success): self = .done
        case (.fyi, nil): self = .info
        }
    }
}

enum InboxPriorityDisplay: String, Equatable {
    case urgent = "now"
    case high
    case low

    var title: LocalizedStringResource {
        switch self {
        case .urgent: "Urgent"
        case .high: "High priority"
        case .low: "Low priority"
        }
    }

    static func forScore(_ score: Double?) -> Self? {
        guard let score, score.isFinite, (0.0...1.0).contains(score) else { return nil }
        return switch score {
        case ..<0.25: .low
        case ..<0.70: nil
        case ..<0.90: .high
        default: .urgent
        }
    }
}

/// Window bounds describe the available app window without shrinking when the
/// keyboard appears. Read this view's window, never a global screen or window.
struct WorkspaceWindowReader: UIViewRepresentable {
    let changed: (CGSize) -> Void
    func makeUIView(context: Context) -> WindowMeasurementView {
        let view = WindowMeasurementView()
        view.changed = changed
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: WindowMeasurementView, context: Context) {
        view.changed = changed
    }
}

final class WindowMeasurementView: UIView {
    var changed: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero
    override func didMoveToWindow() { super.didMoveToWindow(); measure() }
    override func layoutSubviews() { super.layoutSubviews(); measure() }
    private func measure() {
        guard let size = window?.bounds.size, size != lastSize else { return }
        lastSize = size
        Task { @MainActor [weak self] in self?.changed?(size) }
    }
}

struct HarklightBrand: View {
    var large = false

    var body: some View {
        Group {
            if large {
                VStack(spacing: 16) {
                    LighthouseMark().frame(width: 64, height: 78)
                    Text("Harklight").harklightType(.messageTitle)
                    Text("Select a message").harklightType(.rowBody).foregroundStyle(.hkSecondary)
                }
            } else {
                HStack(spacing: 14) {
                    LighthouseMark().frame(width: 15, height: 19)
                    Text("Harklight").harklightType(.brand)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .foregroundStyle(.hkText)
        .accessibilityElement(children: .combine)
    }
}

// Product artwork from the approved lighthouse, not an invented system symbol.
struct LighthouseMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 18, y: rect.minY + rect.height * y / 22)
        }
        path.move(to: point(9, 1)); path.addLine(to: point(5.6, 5)); path.addLine(to: point(12.4, 5)); path.closeSubpath()
        path.move(to: point(6.4, 7)); path.addLine(to: point(11.6, 7)); path.addLine(to: point(13.5, 21)); path.addLine(to: point(4.5, 21)); path.closeSubpath()
        path.move(to: point(2, 5)); path.addLine(to: point(6, 6.4)); path.addLine(to: point(6, 7.6)); path.addLine(to: point(2, 6.2)); path.closeSubpath()
        path.move(to: point(16, 5)); path.addLine(to: point(12, 6.4)); path.addLine(to: point(12, 7.6)); path.addLine(to: point(16, 6.2)); path.closeSubpath()
        return path
    }
}

enum InboxSelection: Hashable {
    case request(RequestKey)
    case sample(String)
    case notificationPending(UInt64)
}

enum RelatedMessageTarget: Hashable {
    case supersedes(RequestKey)
    case replacement(RequestKey)
}

enum InboxMessageTab: String, Hashable {
    case inbox
    case replied
}

/// The root tab bar: Inbox and Replied, and the search tab the system
/// shows as a separate round button at the trailing end.
enum InboxRootTab: Hashable {
    case inbox
    case replied
    case search
}

enum InboxWorkspaceTab: Hashable {
    case inbox
    case replied

    var rootTab: InboxRootTab {
        switch self {
        case .inbox: .inbox
        case .replied: .replied
        }
    }

    var messageTab: InboxMessageTab {
        switch self {
        case .inbox: .inbox
        case .replied: .replied
        }
    }
}

@MainActor
enum InboxListProjection {
    static func filteredRows(_ rows: [InboxItem], in tab: InboxWorkspaceTab,
                             search: String) -> [InboxItem] {
        let messageTab = tab.messageTab
        let inTab = rows.filter { $0.belongsToReplied == (messageTab == .replied) }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return inTab }
        return inTab.filter { $0.matchesSearch(query) }
    }

    static func visibleEntries(_ rows: [InboxItem], in tab: InboxWorkspaceTab,
                               search: String) -> [InboxListEntry] {
        let isRepliedTab = tab.messageTab == .replied
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return InboxThreadListProjection.grouped(rows).compactMap { entry in
            let matches = entry.members.filter { item in
                item.belongsToReplied == isRepliedTab &&
                    (query.isEmpty || item.matchesSearch(query))
            }
            guard !matches.isEmpty else { return nil }
            guard case let .thread(thread, _) = entry, matches.count > 1 else {
                return .row(matches[0])
            }
            return .thread(thread: thread, members: matches)
        }
    }
}

@MainActor
struct InboxNotificationDestination: Equatable {
    let selection: InboxSelection?
    let selectedTab: InboxMessageTab
    let workspaceTab: InboxWorkspaceTab
    let search = ""

    init(route: NativeInboxNavigation, rows: [InboxItem], usesFreeOrder: Bool = false) {
        guard let key = route.request else {
            selection = .notificationPending(route.serial)
            selectedTab = .inbox
            workspaceTab = .inbox
            return
        }

        let selection = InboxSelection.request(key)
        let isReplied = !usesFreeOrder && rows.first(where: { $0.id == selection })?.belongsToReplied == true
        let messageTab: InboxMessageTab = isReplied ? .replied : .inbox
        self.selection = selection
        selectedTab = messageTab
        workspaceTab = isReplied ? .replied : .inbox
    }
}

struct InboxNotificationPendingPresentation: Equatable {
    enum Target: Equatable {
        case message
        case chat
    }

    enum State: Equatable {
        case opening
        case checkingAgain
        case invalid
        case accountUnavailable
        case messageUnavailable
        case retracted
    }

    enum ListRowState: Equatable {
        case opening(Target)
        case checkingAgain
        case invalid
        case accountUnavailable
        case messageUnavailable
        case retracted

        var showsProgress: Bool {
            switch self {
            case .opening, .checkingAgain: true
            case .invalid, .accountUnavailable, .messageUnavailable, .retracted: false
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .opening(.message): "Opening message"
            case .opening(.chat): "Opening chat"
            case .checkingAgain: "Checking notification again"
            case .invalid: "Message link unavailable"
            case .accountUnavailable: "Account unavailable"
            case .messageUnavailable: "Message unavailable"
            case .retracted: "Message retracted"
            }
        }

        var symbolName: String? {
            switch self {
            case .opening, .checkingAgain: nil
            case .invalid: "bell.slash"
            case .accountUnavailable: "person.crop.circle.badge.questionmark"
            case .messageUnavailable: "clock"
            case .retracted: "arrow.uturn.backward"
            }
        }
    }

    let serial: UInt64
    let locator: NativeNotificationLocator?
    let profile: NativeNotificationProfile?
    let target: Target
    let state: State

    init(route: NativeInboxNavigation, intent: NativeNotificationIntent?,
         statusMessage: String?) {
        let matchingIntent = intent.flatMap { $0.serial == route.serial ? $0 : nil }
        serial = route.serial
        locator = matchingIntent?.locator
        profile = matchingIntent?.profile
        target = matchingIntent?.locator?.target == "chat" ? .chat : .message
        state = Self.presentationState(for: statusMessage,
                                       hasMatchingIntent: matchingIntent != nil,
                                       hasLocator: matchingIntent?.locator != nil)
    }

    var listRowState: ListRowState {
        switch state {
        case .opening: .opening(target)
        case .checkingAgain: .checkingAgain
        case .invalid: .invalid
        case .accountUnavailable: .accountUnavailable
        case .messageUnavailable: .messageUnavailable
        case .retracted: .retracted
        }
    }

    static func isNotificationStatusMessage(_ message: String) -> Bool {
        switch message {
        case "Checking this notification.",
             "Could not verify notification. Checking again while open.",
             "Could not check this notification's account.",
             "This notification's message has not loaded yet.",
             "This message link couldn't be opened.",
             "The sender retracted this message.",
             "Looking for this message.":
            true
        default:
            false
        }
    }

    private static func presentationState(for message: String?,
                                          hasMatchingIntent: Bool,
                                          hasLocator: Bool) -> State {
        guard hasMatchingIntent, hasLocator else { return .invalid }
        switch message {
        case "Could not verify notification. Checking again while open.":
            return .checkingAgain
        case "Could not check this notification's account.":
            return .accountUnavailable
        case "This notification's message has not loaded yet.":
            return .messageUnavailable
        case "This message link couldn't be opened.":
            return .invalid
        case "The sender retracted this message.":
            return .retracted
        default:
            return .opening
        }
    }
}

enum InboxNotificationNavigationPolicy {
    static func dismissalSerial(from previous: InboxSelection?,
                                to next: InboxSelection?) -> UInt64? {
        guard previous != next,
              case let .notificationPending(serial)? = previous else { return nil }
        return serial
    }

    static func shouldApply(_ route: NativeInboxNavigation,
                            afterDismissedSerial dismissedSerial: UInt64?) -> Bool {
        dismissedSerial != route.serial
    }
}

private struct InboxNotificationPendingDetail: View {
    let presentation: InboxNotificationPendingPresentation
    let canRefreshInbox: Bool
    let onRefreshInbox: () -> Void
    let onReturnToInbox: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            InboxNotificationPendingStatusContent(presentation: presentation)
            if presentation.state == .messageUnavailable, canRefreshInbox {
                Button("Refresh inbox", action: onRefreshInbox)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("notification-pending-refresh")
            }
            Button("Back to inbox", action: onReturnToInbox)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("notification-pending-back")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("notification-pending-detail")
    }
}

private struct InboxNotificationPendingListRow: View {
    let state: InboxNotificationPendingPresentation.ListRowState

    var body: some View {
        HStack(spacing: 12) {
            if state.showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else if let symbolName = state.symbolName {
                Image(systemName: symbolName)
                    .foregroundStyle(.hkSecondary)
                    .accessibilityHidden(true)
            }
            Text(state.title)
        }
    }
}

private struct InboxNotificationPendingStatusContent: View {
    let presentation: InboxNotificationPendingPresentation

    @ViewBuilder
    var body: some View {
        switch presentation.state {
        case .opening:
            ProgressView()
                .controlSize(.large)
            targetTitle
            Text("Verifying this notification before showing its destination.")
                .foregroundStyle(.hkSecondary)
                .multilineTextAlignment(.center)
        case .checkingAgain:
            ProgressView()
                .controlSize(.large)
            targetTitle
            Text("Harklight is checking this notification again.")
                .foregroundStyle(.hkSecondary)
                .multilineTextAlignment(.center)
        case .invalid:
            Image(systemName: "bell.slash")
                .font(.largeTitle)
                .foregroundStyle(.hkSecondary)
            Text("This message link couldn't be opened.")
                .font(.title2)
                .accessibilityIdentifier("notification-pending-title")
            Text("Return to your inbox to continue.")
                .foregroundStyle(.hkSecondary)
                .multilineTextAlignment(.center)
        case .accountUnavailable:
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.hkSecondary)
            Text("Could not check this notification's account.")
                .font(.title2)
                .accessibilityIdentifier("notification-pending-title")
            Text("Return to your inbox and try again.")
                .foregroundStyle(.hkSecondary)
                .multilineTextAlignment(.center)
        case .messageUnavailable:
            Image(systemName: "clock")
                .font(.largeTitle)
                .foregroundStyle(.hkSecondary)
            Text("This notification's message has not loaded yet.")
                .font(.title2)
                .accessibilityIdentifier("notification-pending-title")
            Text("Refresh the inbox or return to it.")
                .foregroundStyle(.hkSecondary)
                .multilineTextAlignment(.center)
        case .retracted:
            Image(systemName: "arrow.uturn.backward")
                .font(.largeTitle)
                .foregroundStyle(.hkSecondary)
            Text("The sender retracted this message.")
                .font(.title2)
                .accessibilityIdentifier("notification-pending-title")
            Text("Return to your inbox to continue.")
                .foregroundStyle(.hkSecondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var targetTitle: some View {
        switch presentation.target {
        case .message:
            Text("Opening message")
                .font(.title2)
                .accessibilityIdentifier("notification-pending-title")
        case .chat:
            Text("Opening chat")
                .font(.title2)
                .accessibilityIdentifier("notification-pending-title")
        }
    }
}

private struct InboxListRowScrollTarget: Hashable {
    let tab: InboxWorkspaceTab
    let selection: InboxSelection
    var placement: InboxListRowPlacement = .normal
}

private enum InboxListRowPlacement: Hashable {
    case normal
    case normalReplyItem
    case newMessageArea
    case replyItemArea
}

private struct NewMessageAreaVisibility: Hashable {
    enum Placement: Hashable {
        case area
        case normalList
    }

    enum Kind: Hashable {
        case message
        case replyItem
    }

    let key: RequestKey
    let placement: Placement
    var kind: Kind = .message
}

private struct NewMessageAreaExpiryTaskKey: Hashable {
    let scenePhase: String
    let nextExpiry: Date?
}

/// A tapped reply item: open the parent's chat with the item's earliest
/// unseen reply in view. Serials share the notification chat route's field
/// in InboxCardContext, so they start above any notification serial.
private struct ReplyChatRoute: Equatable {
    static let serialBase: UInt64 = 1 << 32

    let serial: UInt64
    let key: RequestKey
    let targetTurnID: ExactText?
    let targetConversationSequence: UInt64?
}

enum InboxResponseReceiptStatus: Equatable {
    case pendingOrAccepted
    case failed
}

struct InboxRequestRow: Identifiable {
    let key: RequestKey
    var requestRevision: UInt64 = 1
    let title: String
    let sender: String
    let status: String
    var senderDisplayName: String? = nil
    var bodyText: String? = nil
    var symbol: String = "envelope"
    var isResolved = false
    var createdAt: Date? = nil
    var isLocalExample = false
    var localStatus: String? = nil
    var informationalSeenStatus: InformationalSeenStatus? = nil
    var declaredMessageType: MessageTypeValue? = nil
    var declaredMessageKind: MessageKindValue? = nil
    var canMarkSeen = false
    var canNoComment = false
    var noCommentUnavailable = false
    var localSeenSelected = false
    var hasUserAction = false
    var hasFailedResponse = false
    var hasDeliveryWarning = false
    var hasMessageLoadWarning = false
    var isRetracted = false
    var chatUnread: Bool? = nil
    var initials: String = ""
    var emphasis: InboxRowEmphasis = .standard
    var messageType: HarklightMessageType? = nil
    var tier: InboxAttentionTier = .middle
    var inboxScore: Double? = nil
    var inboxReplyScores: [UInt64: Double] = [:]
    var thread: ExactText? = nil
    var hasInboxViewEntry = false
    var duePhrase: InboxDuePhrase.Presentation? = nil
    var orderingReason: String? = nil
    var defaultAnswerStatus: String? = nil
    var id: RequestKey { key }

    var visibleStatus: String {
        status.components(separatedBy: " · ")
            .filter { $0 != "Open" }
            .joined(separator: " · ")
    }

    var senderLabel: String {
        InboxSenderDisplay.label(displayName: senderDisplayName, senderID: sender)
    }

    var resolvedMessageType: HarklightMessageType {
        if let messageType { return messageType }
        return HarklightMessageType(declaredType: declaredMessageType, kind: declaredMessageKind,
                                    hasSeenDescriptor: informationalSeenStatus != nil)
    }

    static func responseReceiptStatus(_ receipt: IntentReceipt?,
                                      hasUnconfirmedOutcome: Bool = false,
                                      serverReportedFinalResponse: Bool = false,
                                      hasAcceptedOwnSubmission: Bool = false) -> InboxResponseReceiptStatus? {
        if serverReportedFinalResponse {
            // A current answered or no-comment lifecycle settles list routing. Only an accepted
            // own-operation receipt identifies this device's answer as confirmed.
            return hasAcceptedOwnSubmission ? .pendingOrAccepted : nil
        }
        if hasUnconfirmedOutcome { return .failed }
        guard let state = receipt?.localState else { return nil }
        return switch state {
        case .durable, .queuedForRelay, .accepted: .pendingOrAccepted
        case .refusedByRetraction, .terminalUnconfirmed, .notDelivered, .unsupported, .repairRequired: .failed
        }
    }

    var belongsToReplied: Bool {
        // A failed delivery returns a response-marked row to Inbox, even if its
        // previous Seen state was still reported as pending.
        guard !hasFailedResponse else { return false }
        return hasUserAction || localSeenSelected || informationalSeenStatus == .pending ||
            informationalSeenStatus == .confirmed
    }
}

enum InboxRowEmphasis {
    case standard, error, warning, completed
}

enum InboxAttentionTier: Equatable {
    case top, middle, low
}

enum InboxFriendlyDate {
    static func label(for date: Date, now: Date = .now,
                      calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? Int.max
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch daysAgo {
        case 0:
            formatter.timeStyle = .short
        case 1:
            return String(localized: "Yesterday")
        case 2...6:
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        default:
            formatter.dateStyle = .short
        }
        return formatter.string(from: date)
    }

    /// An open message's day and time, such as "Today, 9:12 AM".
    static func detailLabel(for date: Date, now: Date = .now,
                            calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? Int.max
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        let time = formatter.string(from: date)
        let dayText: String
        switch daysAgo {
        case 0:
            dayText = String(localized: "Today")
        case 1:
            dayText = String(localized: "Yesterday")
        case 2...6:
            formatter.timeStyle = .none
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            dayText = formatter.string(from: date)
        default:
            formatter.timeStyle = .none
            formatter.dateStyle = .medium
            dayText = formatter.string(from: date)
        }
        return String(localized: "\(dayText), \(time)")
    }
}

enum InboxSenderDisplay {
    static func label(displayName: String?, senderID: String) -> String {
        displayName ?? name(for: senderID)
    }

    /// Detail and conversation surfaces retain the complete sender identity
    /// when no sender-authored display name was supplied.
    static func detailLabel(displayName: String?, senderID: String) -> String {
        displayName ?? senderID
    }

    static func name(for senderID: String) -> String {
        let withoutKind = senderID.split(separator: ":", omittingEmptySubsequences: false).last
            .map(String.init) ?? senderID
        let agentName = withoutKind.split(separator: "/", omittingEmptySubsequences: false).last
            .map(String.init) ?? withoutKind
        return agentName.isEmpty ? senderID : agentName
    }
}

/// One ordinary inbox for admitted requests and additive local examples.
/// Source-bound selections retain the correct domain/view-model action owner.
@MainActor
struct HarklightInbox<RequestDetail: View, SettingsContent: View>: View {
    let requests: [InboxRequestRow]
    var showsBasicOrderMarker = false
    let samples: SampleLibrary
    let selectRequest: (RequestKey) -> Void
    var markSeenRequest: (RequestKey, UInt64) -> Void = { _, _ in }
    var markNoCommentRequest: (RequestKey, UInt64) -> Void = { _, _ in }
    var clearRetractedRequest: (RequestKey) -> Void = { _ in }
    @ViewBuilder let requestDetail: (RequestKey, InboxCardContext) -> RequestDetail
    @ViewBuilder let settingsContent: () -> SettingsContent
    var warnings: [String] = []
    var isRefreshing = false
    var conversationStore: LivePresentationStore? = nil
    var fetchOlderInboxPage: (() async -> Bool)? = nil
    var refreshInbox: (@MainActor () async -> Void)? = nil
    var showsLocalExamples = false
    var notificationNavigation: NativeInboxNavigation? = nil
    var notificationChatRouteDidOpen: (UInt64) -> Void = { _ in }
    var userOpenedMessage: () -> Void = {}
    var testNotificationRouter: NativeNotificationRouter? = nil
    var testOpenForegroundChatIndicator: (() -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: InboxSelection?
    @State private var relatedMessageNavigationPath: [RelatedMessageTarget] = []
    @State private var isWarningPresented = false
    @State private var settings = false
    @State private var selectedTab: InboxMessageTab = .inbox
    @State private var workspaceTab: InboxWorkspaceTab = .inbox
    @State private var rootTab: InboxRootTab = .inbox
    @State private var search = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var testNotificationNavigation: NativeInboxNavigation?
    @State private var listTabOnMessageEntry: InboxMessageTab?
    @State private var lastViewedSelection: InboxSelection?
    @State private var navigatedBetweenMessages = false
    @State private var restoreLastViewedOnReturn = false
    @State private var replyChatRoute: ReplyChatRoute?
    @State private var dismissedNotificationSerial: UInt64?
    @State private var dismissedInlineChatRequests: Set<RequestKey> = []

    private var rows: [InboxItem] {
        showsLocalExamples ? samples.inboxItems(appendingTo: requests) : requests.map { .request($0) }
    }

    private var visibleWarnings: [String] {
        let messages = warnings + [samples.loadError].compactMap { $0 }
        guard let route = activeNotificationNavigation,
              dismissedNotificationSerial == route.serial else { return messages }
        return messages.filter {
            !InboxNotificationPendingPresentation.isNotificationStatusMessage($0)
        }
    }

    private func warningPresentationBinding(for tab: InboxWorkspaceTab) -> Binding<Bool> {
        Binding(
            get: { workspaceTab == tab && isWarningPresented && !visibleWarnings.isEmpty },
            set: { isWarningPresented = $0 }
        )
    }

    private var staleAnswerPresentation: Binding<Bool> {
        Binding(
            get: { conversationStore?.staleAnswerDialog != nil },
            set: { isPresented in
                if !isPresented { conversationStore?.dismissStaleAnswerDialog() }
            }
        )
    }

    private func dismissWarningWhenCleared(_ warnings: [String]) {
        if warnings.isEmpty { isWarningPresented = false }
    }

    /// Search filters only the search tab's list; Inbox and Replied always
    /// show everything.
    private var activeSearch: String {
        rootTab == .search ? search : ""
    }

    private var orderedIDs: [InboxSelection] {
        InboxListProjection.filteredRows(rows, in: .inbox, search: activeSearch).map(\.id)
    }
    private var usesFreeOrder: Bool {
        InboxFreeOrder.isSupported(version: conversationStore?.presentation.inboxFreeOrderVersion,
                                   items: conversationStore?.presentation.inboxViewListItems)
    }
    private var cardNavigationIDs: [InboxSelection] {
        // Keep detail navigation aligned with the current Inbox list, including
        // its search results and server-ranked ordering when free order is active.
        if usesFreeOrder {
            return InboxNormalListProjection.entries(rows: rows,
                serverItems: conversationStore?.presentation.inboxViewListItems,
                freeOrderVersion: conversationStore?.presentation.inboxFreeOrderVersion,
                in: .inbox, search: activeSearch).flatMap { entry -> [InboxSelection] in
                    guard case let .message(message) = entry else { return [] }
                    return message.members.map(\.id)
                }
        }
        return orderedIDs
    }
    private var activeNotificationNavigation: NativeInboxNavigation? {
        notificationNavigation ?? testNotificationNavigation
    }
    private var visibleNotificationNavigation: NativeInboxNavigation? {
        guard let route = activeNotificationNavigation,
              InboxNotificationNavigationPolicy.shouldApply(
                route, afterDismissedSerial: dismissedNotificationSerial) else { return nil }
        return route
    }
    private var activeNotificationIntent: NativeNotificationIntent? {
        guard let route = activeNotificationNavigation else { return nil }
        let intent = (testNotificationRouter ?? NativeNotificationRouter.shared).intent
        return intent?.serial == route.serial ? intent : nil
    }
    private func notificationPendingPresentation(for serial: UInt64) -> InboxNotificationPendingPresentation? {
        guard let route = activeNotificationNavigation, route.serial == serial,
              route.request == nil, visibleNotificationNavigation != nil else { return nil }
        let statusMessage = visibleWarnings.first {
            InboxNotificationPendingPresentation.isNotificationStatusMessage($0)
        }
        return InboxNotificationPendingPresentation(route: route, intent: activeNotificationIntent,
                                                    statusMessage: statusMessage)
    }
    private var notificationPendingListPresentation: InboxNotificationPendingPresentation? {
        guard let route = visibleNotificationNavigation, route.request == nil else { return nil }
        return notificationPendingPresentation(for: route.serial)
    }
    private var newMessageAreaExpiryTaskKey: NewMessageAreaExpiryTaskKey {
        NewMessageAreaExpiryTaskKey(
            scenePhase: String(describing: scenePhase),
            nextExpiry: nextNewMessageAreaExpiry)
    }
    private var nextNewMessageAreaExpiry: Date? {
        [conversationStore?.newMessageAreaStore?.nextExpiry,
         conversationStore?.replyItemAreaStore?.nextExpiry].compactMap { $0 }.min()
    }
    private var exposesNotificationTestAction: Bool {
        ProcessInfo.processInfo.arguments.contains("--harklight-test-notification-navigation")
    }

    private func triggerNotificationTestAction() {
        guard exposesNotificationTestAction, let key = requests.first?.key else { return }
        let serial = max(notificationNavigation?.serial ?? 0,
                         testNotificationNavigation?.serial ?? 0) &+ 1
        testNotificationNavigation = NativeInboxNavigation(serial: serial, request: key)
    }

    private func currentItem(for selection: InboxSelection) -> InboxItem? {
        if case let .request(key) = selection,
           let request = conversationStore?.inboxRow(for: key) {
            return .request(request)
        }
        return rows.first { $0.id == selection }
    }

    private func navigate(to next: InboxSelection?) {
        navigate(from: selection, to: next)
    }

    private func dismissInlineChat(for key: RequestKey) {
        withAnimation(.easeInOut(duration: 0.22)) {
            dismissedInlineChatRequests.insert(key)
        }
    }

    private func reopenInlineChat(for key: RequestKey) {
        withAnimation(.easeInOut(duration: 0.22)) {
            dismissedInlineChatRequests.remove(key)
        }
    }

    private func dismissPendingNotification() {
        guard let selection, case .notificationPending = selection else { return }
        navigate(to: nil)
    }

    private func navigate(from previous: InboxSelection?, to next: InboxSelection?) {
        let nextRequest: RequestKey? = if case let .request(key)? = next { key } else { nil }
        if case let .request(previousKey)? = previous, nextRequest != previousKey {
            NativePushedViewCoordinator.shared.clearPassiveContent(previousKey)
        }
        var openedPassivePush = false
        if case let .request(key)? = next {
            let pushes = NativePushedViewCoordinator.shared
            openedPassivePush = pushes.isPassive(key)
            pushes.contentWasTouched(key) {
                conversationStore?.newMessageAreaStore?.open(key)
                reportMessageContentOpen(for: key)
            }
            pushes.recordOwnOpen()
        }
        guard previous != next else { return }
        if nextRequest != nil, !openedPassivePush { userOpenedMessage() }
        if let serial = InboxNotificationNavigationPolicy.dismissalSerial(from: previous, to: next) {
            dismissedNotificationSerial = serial
        }
        UIDiagnostics.shared.record("inbox.navigate \(UIDiagnostics.describe(previous))->\(UIDiagnostics.describe(next))")
        if case let .request(key) = previous { conversationStore?.flushPendingDraft(for: key) }
        if next != nil {
            restoreLastViewedOnReturn = false
            if previous == nil {
                listTabOnMessageEntry = selectedTab
                navigatedBetweenMessages = false
            } else {
                navigatedBetweenMessages = true
            }
        }
        selection = next
        // Keep departure cleanup bound to the explicit identity transition;
        // split-view adaptation changes columns without leaving this message.
        selectionDidChange(from: previous, to: next)
        if previous != nil, next == nil {
            restoreLastViewedListPosition()
        }
    }

    private func selectionDidChange(from previous: InboxSelection?, to next: InboxSelection?) {
        let oldRequest: RequestKey? = if case let .request(key) = previous { key } else { nil }
        let newRequest: RequestKey? = if case let .request(key) = next { key } else { nil }
        conversationStore?.navigateMessage(from: oldRequest, to: newRequest)

        if let route = replyChatRoute, newRequest != route.key { replyChatRoute = nil }

        let oldSampleID: String? = if case let .sample(id) = previous { id }
            else if previous == nil { samples.selectedID }
            else { nil }
        let newSampleID: String? = if case let .sample(id) = next { id } else { nil }

        if let next { lastViewedSelection = next }
        if let newRequest {
            if replyChatRoute?.key != newRequest,
               !NativePushedViewCoordinator.shared.isPassive(newRequest) {
                conversationStore?.newMessageAreaStore?.open(newRequest)
                reportMessageContentOpen(for: newRequest)
            }
            selectRequest(newRequest)
        }
        samples.select(newSampleID, departingFrom: oldSampleID)
    }

    private func reportMessageContentOpen(for key: RequestKey) {
        guard let request = conversationStore?.request(for: key) else { return }
        conversationStore?.reportMessageContentOpened(request)
    }

    private func activatePassivePushContent(for key: RequestKey) {
        NativePushedViewCoordinator.shared.contentWasTouched(key) {
            conversationStore?.newMessageAreaStore?.open(key)
            reportMessageContentOpen(for: key)
        }
    }

    /// Opens a reply group's parent with its relevant reply in view.
    private func openReplyItem(parent: RequestKey,
                               targetTurnID: ExactText?,
                               targetConversationSequence: UInt64?) {
        let serial = max(replyChatRoute?.serial ?? 0, ReplyChatRoute.serialBase) &+ 1
        replyChatRoute = ReplyChatRoute(serial: serial, key: parent,
                                        targetTurnID: targetTurnID,
                                        targetConversationSequence: targetConversationSequence)
        navigate(to: .request(parent))
    }

    private func replyRouteTargetTurnID(for key: RequestKey) -> ExactText? {
        guard let route = replyChatRoute, route.key == key else { return nil }
        if let targetTurnID = route.targetTurnID { return targetTurnID }
        guard let targetSequence = route.targetConversationSequence,
              let thread = conversationStore?.conversation(for: key) else { return nil }
        return thread.turns.first { turn in
            turn.conversationSequence == targetSequence &&
                turn.kind == .reply && turn.author == .origin
        }?.id
    }

    private func markSeen(_ id: InboxSelection) {
        switch id {
        case let .request(key):
            guard let item = rows.first(where: { $0.id == id }),
                  case let .request(row) = item, row.canMarkSeen else { return }
            markSeenRequest(key, row.requestRevision)
        case let .sample(sampleID):
            guard let response = samples.responses[sampleID], response.canMarkSeenLocally else { return }
            response.finishLocally()
        case .notificationPending:
            return
        }
    }

    private func markNoComment(_ id: InboxSelection) {
        switch id {
        case let .request(key):
            guard let item = rows.first(where: { $0.id == id }),
                  case let .request(row) = item, row.canNoComment else { return }
            markNoCommentRequest(key, row.requestRevision)
        case let .sample(sampleID):
            guard let response = samples.responses[sampleID], response.canDeclineLocally else { return }
            response.declineLocally()
        case .notificationPending:
            return
        }
    }

    private func clearRetracted(_ id: InboxSelection) {
        switch id {
        case let .request(key):
            guard rows.first(where: { $0.id == id })?.isRetracted == true else { return }
            clearRetractedRequest(key)
        case let .sample(sampleID):
            guard let response = samples.responses[sampleID],
                  response.inboxRow?.isRetracted == true else { return }
            response.clearRetractedLocally()
        case .notificationPending:
            return
        }
    }

    private func restoreLastViewedListPosition() {
        let lastViewedItem = lastViewedSelection.flatMap(currentItem(for:))
        guard navigatedBetweenMessages else {
            listTabOnMessageEntry = nil
            restoreLastViewedOnReturn = false
            UIDiagnostics.shared.record("inbox.restorePosition entryTab tab=\(selectedTab.rawValue)")
            return
        }
        navigatedBetweenMessages = false
        listTabOnMessageEntry = nil
        guard let lastViewedSelection, let lastViewedItem else {
            restoreLastViewedOnReturn = false
            UIDiagnostics.shared.record("inbox.restorePosition missing last=\(UIDiagnostics.describe(lastViewedSelection))")
            return
        }
        restoreLastViewedOnReturn = true
        UIDiagnostics.shared.record("inbox.restorePosition lastViewed=\(UIDiagnostics.describe(lastViewedSelection)) tab=\(selectedTab.rawValue)")
    }

    private func diagnosticSummary(landscape: Bool) -> String {
        let rowSummary = rows.map { row -> String in
            let missingRow: Bool = if case let .example(_, response) = row { response.inboxRow == nil } else { false }
            return row.accessibilityID + ":" + (row.belongsToReplied ? "R" : "I") + (missingRow ? ":empty" : "")
        }
        return [
            "selection=\(UIDiagnostics.describe(selection)) tab=\(selectedTab.rawValue) entryTab=\(listTabOnMessageEntry?.rawValue ?? "nil") lastViewed=\(UIDiagnostics.describe(lastViewedSelection))",
            "betweenMessages=\(navigatedBetweenMessages) restoreOnReturn=\(restoreLastViewedOnReturn)",
            "sizeClass=\(horizontalSizeClass.map { "\($0)" } ?? "nil") landscape=\(landscape)",
            "samples.selected=\(samples.selectedID ?? "nil") samples.lastViewed=\(samples.lastViewedID ?? "nil") loadError=\(samples.loadError ?? "nil")",
            "rows=\(rowSummary)",
            UIDiagnostics.shared.eventSummary,
        ].joined(separator: " | ")
    }

    private var navigationSelection: Binding<InboxSelection?> {
        Binding(get: { selection }, set: { next in
            navigate(to: next)
        })
    }

    @ViewBuilder
    private func detailContent(for item: InboxSelection?, inlineChat: Bool,
                               geometry: GeometryProxy) -> some View {
        let pushedChatFallsBackToMessage: Bool = if case let .request(key)? = item,
            let route = activeNotificationNavigation, route.request == key {
            route.chatTargetFallsBackToMessage
        } else {
            false
        }
        HStack(spacing: 0) {
            Group {
                switch item {
                case let .request(key)?:
                    let reopenInlineChat: (() -> Void)? = inlineChat &&
                        !pushedChatFallsBackToMessage &&
                        conversationStore?.request(for: key) != nil
                        ? { [self] in self.reopenInlineChat(for: key) }
                        : nil
                    requestDetail(key, cardContext(for: .request(key),
                        inlineChat: inlineChat, reopenInlineChat: reopenInlineChat))
                        .id(key)
                        .simultaneousGesture(TapGesture().onEnded {
                            activatePassivePushContent(for: key)
                        })
                case let .sample(id)?:
                    if showsLocalExamples,
                       samples.messages.contains(where: { $0.id == id }),
                       let response = samples.responses[id] {
                        SampleCardScreen(response: response,
                            context: cardContext(for: .sample(id), inlineChat: inlineChat))
                            .id(id)
                    }
                case let .notificationPending(serial)?:
                    if let presentation = notificationPendingPresentation(for: serial) {
                        InboxNotificationPendingDetail(
                            presentation: presentation,
                            canRefreshInbox: refreshInbox != nil,
                            onRefreshInbox: {
                                guard let refreshInbox else { return }
                                Task { await refreshInbox() }
                            },
                            onReturnToInbox: { navigate(to: nil) })
                    } else {
                        ContentUnavailableView("Notification no longer available",
                                               systemImage: "bell.slash")
                    }
                case nil:
                    HarklightBrand(large: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { HarklightDesignSystem.palette(for: colorScheme).background.ignoresSafeArea() }
                }
            }
            .frame(maxWidth: .infinity)
            if inlineChat, !pushedChatFallsBackToMessage, case let .request(key)? = item,
               !dismissedInlineChatRequests.contains(key), let conversationStore,
               let request = conversationStore.request(for: key) {
                Group {
                    Rectangle().fill(.hkLine).frame(width: 1).ignoresSafeArea()
                    ConversationPanel(store: conversationStore, key: key,
                        sender: key.senderID.rawValue, title: request.title?.rawValue ?? "",
                        initialScrollTurnID: replyRouteTargetTurnID(for: key),
                        onDismissChat: { dismissInlineChat(for: key) },
                        discussionUnavailableReason: request.lifecycleStatus == .superseded
                            ? ConversationPanelText.supersededReadOnlyReason
                            : nil)
                        .frame(width: min(360, geometry.size.width * 0.34))
                        .background { Rectangle().fill(.hkBackground).ignoresSafeArea() }
                }
                .transition(.move(edge: .trailing))
            }
            if inlineChat, case let .sample(id)? = item,
               let message = samples.messages.first(where: { $0.id == id }),
               let response = samples.responses[id] {
                Rectangle().fill(.hkLine).frame(width: 1).ignoresSafeArea()
                SampleChatView(sender: message.sender, title: message.title, response: response)
                    .frame(width: min(360, geometry.size.width * 0.34))
                    .background { Rectangle().fill(.hkBackground).ignoresSafeArea() }
            }
        }
        .navigationDestination(for: RelatedMessageTarget.self) { target in
            switch target {
            case let .supersedes(key):
                if conversationStore?.request(for: key) != nil {
                    requestDetail(key, .supersedesTarget)
                } else {
                    ContentUnavailableView("Message not available", systemImage: "questionmark.folder")
                }
            case let .replacement(key):
                if conversationStore?.request(for: key) != nil {
                    requestDetail(key, cardContext(for: .request(key), inlineChat: inlineChat))
                        .id(key)
                } else {
                    ContentUnavailableView("Replacement not available yet",
                        systemImage: "clock",
                        description: Text("The original message is still available."))
                }
            }
        }
        .toolbar(horizontalSizeClass == .compact && item != nil ? .hidden : .automatic,
                 for: .tabBar)
    }

    @ViewBuilder
    private func inboxSplitView(for tab: InboxWorkspaceTab, inlineChat: Bool,
                                geometry: GeometryProxy, searching: Bool = false) -> some View {
        let splitView = NavigationSplitView {
            InboxList(tab: tab, rows: rows, warnings: visibleWarnings,
                  showsBasicOrderMarker: showsBasicOrderMarker, isRefreshing: isRefreshing,
                  refreshInbox: refreshInbox,
                  conversationStore: conversationStore,
                  newMessageAreaStore: conversationStore?.newMessageAreaStore,
                  replyItemAreaStore: conversationStore?.replyItemAreaStore,
                  openReplyItem: openReplyItem,
                  isWarningPresented: warningPresentationBinding(for: tab),
                  selected: navigationSelection,
                      workspaceTab: $workspaceTab,
                      search: searching ? $search : .constant(""),
                      lastViewedSelection: lastViewedSelection,
                      restoreLastViewed: restoreLastViewedOnReturn,
                      didRestoreLastViewed: { restoreLastViewedOnReturn = false },
                      showSettings: { dismissPendingNotification(); settings = true },
                      markSeen: markSeen,
                      markNoComment: markNoComment,
                      clearRetracted: clearRetracted,
                      fetchOlderInboxPage: fetchOlderInboxPage,
                      notificationNavigation: visibleNotificationNavigation,
                      notificationPendingPresentation: notificationPendingListPresentation,
                      triggerNotification: exposesNotificationTestAction
                          ? { triggerNotificationTestAction() } : nil)
        } detail: {
            NavigationStack(path: $relatedMessageNavigationPath) {
                detailContent(for: selection, inlineChat: inlineChat,
                              geometry: geometry)
            }
            .onChange(of: selection) { _, _ in
                relatedMessageNavigationPath.removeAll()
            }
            .onChange(of: relatedMessageNavigationPath) { oldPath, newPath in
                if let target = newPath.last {
                    let key: RequestKey
                    switch target {
                    case let .supersedes(targetKey), let .replacement(targetKey):
                        key = targetKey
                    }
                    NativeFocusReporter.shared.selectionChanged(
                        to: NativeFocusSelection.messageReport(for: key))
                    if newPath.count > oldPath.count {
                        NativePushedViewCoordinator.shared.recordOwnOpen()
                        reportMessageContentOpen(for: key)
                    }
                } else {
                    NativeFocusReporter.shared.selectionChanged(
                        to: NativeFocusSelection.report(for: selection))
                }
            }
        }
        splitView.scrollBounceBehavior(.always, axes: .vertical)
            .background { splitBackground.ignoresSafeArea() }
    }

    /// On iPad the open message's type tint runs behind the floating list
    /// panel to the screen edge; with nothing open the page shows.
    private var splitBackground: Color {
        let palette = HarklightDesignSystem.palette(for: colorScheme)
        guard let selection, let item = rows.first(where: { $0.id == selection }) else {
            return palette.background
        }
        return palette.typeTint(item.resolvedMessageType)
    }

    private func cardContext(for id: InboxSelection, inlineChat: Bool = false,
                             reopenInlineChat: (() -> Void)? = nil) -> InboxCardContext {
        let ids = cardNavigationIDs
        let index = ids.firstIndex(of: id)
        let hasPrevious = index.map { $0 > 0 } ?? false
        let hasNext = index.map { $0 + 1 < ids.count } ?? false
        let chatTargetFallsBack = if case let .request(key) = id,
            let route = visibleNotificationNavigation, route.request == key {
            route.chatTargetFallsBackToMessage
        } else {
            false
        }
        let chatRouteSerial: UInt64?
        var chatScrollTargetTurnID: ExactText? = nil
        var chatRouteDidOpen: (() -> Void)? = nil
        if case let .request(key) = id,
           let route = visibleNotificationNavigation,
           route.opensChat, route.request == key {
            chatRouteSerial = route.serial
            chatRouteDidOpen = { [self] in
                self.dismissedInlineChatRequests.remove(key)
                self.notificationChatRouteDidOpen(route.serial)
            }
        } else if case let .request(key) = id,
                  let route = replyChatRoute, route.key == key {
            chatRouteSerial = route.serial
            chatScrollTargetTurnID = replyRouteTargetTurnID(for: key)
            chatRouteDidOpen = { [self] in
                guard self.replyChatRoute?.serial == route.serial else { return }
                self.dismissedInlineChatRequests.remove(key)
                self.replyChatRoute = nil
            }
        } else {
            chatRouteSerial = nil
        }
        return InboxCardContext(position: index.map { $0 + 1 },
            total: index == nil ? nil : ids.count,
            hasPrevious: hasPrevious,
            hasNext: hasNext,
            inlineChat: inlineChat,
            reopenInlineChat: reopenInlineChat,
            chatTargetFallsBackToMessage: chatTargetFallsBack,
            notificationChatRouteSerial: chatRouteSerial,
            notificationChatRouteDidOpen: chatRouteDidOpen,
            chatScrollTargetTurnID: chatScrollTargetTurnID,
            dismissToList: { navigate(to: nil) },
            messageType: rows.first(where: { $0.id == id })?.resolvedMessageType ?? .request) { direction in
                // Resolve against today's list; the displayed identity stays stable on refresh.
                let currentIDs = cardNavigationIDs
                guard let current = currentIDs.firstIndex(of: id),
                      currentIDs.indices.contains(current + direction) else { return }
                let next = currentIDs[current + direction]
                navigatedBetweenMessages = true
                navigate(to: next)
            }
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let wideChat = UIDevice.current.userInterfaceIdiom == .pad && geometry.size.width >= 820
            let inlineChat = wideChat && landscape
            let tabs = TabView(selection: $rootTab) {
                Tab(value: .inbox) {
                    inboxSplitView(for: .inbox, inlineChat: inlineChat,
                                   geometry: geometry)
                } label: {
                    // TabView fills SF Symbol variants; keep this stock symbol’s outline and solid dot.
                    Label {
                        Text("Inbox")
                    } icon: {
                        Image(uiImage: UIImage(systemName: "envelope.badge")!)
                    }
                }

                Tab("Replied", systemImage: "envelope.open", value: .replied) {
                    inboxSplitView(for: .replied, inlineChat: inlineChat,
                                   geometry: geometry)
                }

                // The search role gives the system's round search button at the
                // trailing end. It searches the list the person came from.
                Tab(value: .search, role: .search) {
                    inboxSplitView(for: workspaceTab, inlineChat: inlineChat,
                                   geometry: geometry, searching: true)
                        .id(workspaceTab)
                        .searchable(text: Binding(get: { search }, set: { value in
                            search = value
                            NativePushedViewCoordinator.shared.noteReplyTextChanged()
                        }), prompt: "Search messages")
                        .searchFocused($searchFieldFocused)
                }
            }
            .tabViewSearchActivation(.searchTabSelection)
            .preference(key: ReplyEditorFocusKey.self, value: searchFieldFocused)
            .onChange(of: searchFieldFocused) { _, focused in
                if focused {
                    NativePushedViewCoordinator.shared.replyEditorFocusChanged(true,
                                                                               resetActivity: true)
                }
            }
            .tint(HarklightDesignSystem.palette(for: colorScheme).amber)
            .onChange(of: rootTab) { _, newRootTab in
                switch newRootTab {
                case .inbox: workspaceTab = .inbox
                case .replied: workspaceTab = .replied
                case .search:
                    // One tap on the search tab focuses its field on iPhone. The
                    // search list is rebuilt for the tab it searches, so focus is
                    // set here as well as by the system activation. iPad leaves the
                    // field unfocused so the keyboard does not cover the view.
                    if horizontalSizeClass == .compact {
                        Task { @MainActor in searchFieldFocused = true }
                    }
                }
                if newRootTab != .search, !search.isEmpty { search = "" }
            }
            .onChange(of: workspaceTab) { oldTab, newTab in
                if oldTab != newTab { isWarningPresented = false }
                selectedTab = newTab.messageTab
                guard newTab != .inbox,
                      let route = activeNotificationNavigation, route.request == nil,
                      case let .notificationPending(serial)? = selection,
                      serial == route.serial else { return }
                dismissPendingNotification()
            }
            .onChange(of: search) { _, newSearch in
                guard !newSearch.isEmpty,
                      let route = activeNotificationNavigation, route.request == nil,
                      case let .notificationPending(serial)? = selection,
                      serial == route.serial else { return }
                dismissPendingNotification()
            }
            .onChange(of: selectedTab) { _, tab in
                workspaceTab = tab == .replied ? .replied : .inbox
            }
            .onChange(of: workspaceTab) { _, tab in
                if rootTab != .search { rootTab = tab.rootTab }
            }
            .onChange(of: visibleWarnings, initial: true) { _, newWarnings in
                dismissWarningWhenCleared(newWarnings)
            }
            tabs
            .onChange(of: activeNotificationNavigation, initial: true) { _, route in
                guard let route,
                      InboxNotificationNavigationPolicy.shouldApply(
                        route, afterDismissedSerial: dismissedNotificationSerial) else { return }
                if dismissedNotificationSerial != route.serial { dismissedNotificationSerial = nil }
                settings = false
                // Notification routing changes presentation only. Keep it out
                // of ordinary navigation cleanup so a tap cannot mutate the domain.
                let destination = InboxNotificationDestination(route: route, rows: rows,
                                                               usesFreeOrder: usesFreeOrder)
                workspaceTab = destination.workspaceTab
                rootTab = destination.workspaceTab.rootTab
                selectedTab = destination.selectedTab
                search = destination.search
                selection = destination.selection
                if let key = route.request {
                    if !NativePushedViewCoordinator.shared.isPassive(key) {
                        conversationStore?.newMessageAreaStore?.open(key)
                        reportMessageContentOpen(for: key)
                    }
                    lastViewedSelection = .request(key)
                    selectRequest(key)
                }
            }
            .onChange(of: selection, initial: true) { _, next in
                NativeFocusReporter.shared.selectionChanged(to: next)
            }
            .onChange(of: settings) { _, isPresented in
                if isPresented {
                    let underlying = NativeFocusReporter.shared.currentFocus ??
                        NativeFocusSelection.report(for: selection)
                    NativeFocusReporter.shared.settingsPresented(underlyingFocus: underlying)
                } else {
                    NativeFocusReporter.shared.settingsDismissed(
                        fallback: NativeFocusSelection.report(for: selection))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, UIApplication.shared.isProtectedDataAvailable else { return }
                conversationStore?.newMessageAreaStore?.removeExpired()
                conversationStore?.replyItemAreaStore?.removeExpired()
            }
            .task(id: newMessageAreaExpiryTaskKey) {
                guard scenePhase == .active,
                      UIApplication.shared.isProtectedDataAvailable else { return }
                while let expiry = nextNewMessageAreaExpiry {
                    let delay = max(0, expiry.timeIntervalSinceNow)
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          scenePhase == .active,
                          UIApplication.shared.isProtectedDataAvailable else { return }
                    conversationStore?.newMessageAreaStore?.removeExpired()
                    conversationStore?.replyItemAreaStore?.removeExpired()
                }
            }
            .onChange(of: samples.selectedID) { _, id in
                let sampleIDDescription: String = id ?? "nil"
                let selectionDescription: String = UIDiagnostics.describe(selection)
                let diagnostic = "inbox.samplesSelectedChanged " + sampleIDDescription +
                    " selection=" + selectionDescription
                UIDiagnostics.shared.record(diagnostic)
                guard showsLocalExamples, case .sample = selection else { return }
                navigate(to: id.map { .sample($0) })
            }
            .onChange(of: showsLocalExamples) { _, visible in
                if !visible, case .sample = selection {
                    navigate(to: nil)
                }
            }
            .onAppear {
                UIDiagnostics.shared.record("inbox.appear selection=\(UIDiagnostics.describe(selection)) samples.selected=\(samples.selectedID ?? "nil")")
                guard showsLocalExamples, selection == nil,
                      let id = samples.selectedID, samples.responses[id] != nil else { return }
                selection = .sample(id)
                lastViewedSelection = .sample(id)
            }
            .uiDiagnostics("inbox-ui-diagnostics", diagnosticSummary(landscape: landscape))
        }
        .sheet(isPresented: $settings) {
            settingsContent()
                .foregroundChatNotificationLayer(testRouter: testNotificationRouter,
                                                 testOpen: testOpenForegroundChatIndicator)
        }
        .alert("The message changed", isPresented: staleAnswerPresentation,
               presenting: conversationStore?.staleAnswerDialog) { dialog in
            Button("Review message") {
                conversationStore?.dismissStaleAnswerDialog()
                settings = false
                workspaceTab = .inbox
                rootTab = .inbox
                selectedTab = .inbox
                search = ""
                navigate(to: .request(dialog.requestKey))
            }
            Button("Dismiss", role: .cancel) {
                conversationStore?.dismissStaleAnswerDialog()
            }
        } message: { dialog in
            Text(dialog.localizedMessage)
        }
        .tint(HarklightDesignSystem.palette(for: colorScheme).text)
    }
}

@MainActor
struct InboxList: View {
    let tab: InboxWorkspaceTab
    let rows: [InboxItem]
    let warnings: [String]
    var showsBasicOrderMarker = false
    var isRefreshing = false
    var refreshInbox: (@MainActor () async -> Void)? = nil
    let conversationStore: LivePresentationStore?
    let newMessageAreaStore: NewMessageAreaStore?
    let replyItemAreaStore: ReplyItemAreaStore?
    let openReplyItem: (RequestKey, ExactText?, UInt64?) -> Void
    @Binding var isWarningPresented: Bool
    @Binding var selected: InboxSelection?
    @Binding var workspaceTab: InboxWorkspaceTab
    @Binding var search: String
    let lastViewedSelection: InboxSelection?
    let restoreLastViewed: Bool
    let didRestoreLastViewed: () -> Void
    let showSettings: () -> Void
    let markSeen: (InboxSelection) -> Void
    let markNoComment: (InboxSelection) -> Void
    let clearRetracted: (InboxSelection) -> Void
    let fetchOlderInboxPage: (() async -> Bool)?
    let notificationNavigation: NativeInboxNavigation?
    var notificationPendingPresentation: InboxNotificationPendingPresentation? = nil
    let triggerNotification: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.harklightReduceMotionOverride) private var reduceMotionOverride
    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var canRequestOlderPageOnDrag = false
    @State private var isUserScrolling = false
    @State private var requestedInGesture = false
    @State private var isFetchingOlderPage = false
    @State private var warningContentHeight: CGFloat = 0
    @State private var expandedThreadGroups: Set<InboxListEntryID> = []
    @State private var isNewMessageAreaExpanded = false
    @State private var visibleMessagePlacements: Set<NewMessageAreaVisibility> = []
    @State private var lastViewedReplyTarget: RequestKey?

    private struct NewMessageAreaListRow: Identifiable {
        let entry: NewMessageAreaEntry
        let row: InboxRequestRow
        var id: RequestKey { entry.key }
    }

    private struct ReplyItemListRow {
        let entry: ReplyItemEntry
        let row: InboxRequestRow?

        var parentTitle: String { row?.title ?? entry.parent.messageID.rawValue }
        var senderLabel: String { row?.senderLabel ?? entry.parent.senderID.rawValue }
        var inboxReplyScores: [UInt64: Double] { row?.inboxReplyScores ?? [:] }
    }

    private struct NormalReplyItemListRow: Identifiable {
        let reference: InboxViewListItem
        let projection: ReplyItemNormalRow?
        let parent: InboxRequestRow?

        var id: RequestKey { reference.key }
        var parentTitle: String { parent?.title ?? reference.key.messageID.rawValue }
        var senderLabel: String { parent?.senderLabel ?? reference.key.senderID.rawValue }
    }

    /// One parent can hold both a new-message entry and a reply item, so
    /// the combined ids keep the two kinds distinct.
    private enum NewMessageAreaCombinedRow: Identifiable {
        case message(NewMessageAreaListRow)
        case reply(ReplyItemListRow)

        enum ID: Hashable {
            case message(RequestKey)
            case reply(RequestKey)
        }

        var id: ID {
            switch self {
            case let .message(item): .message(item.entry.key)
            case let .reply(item): .reply(item.entry.parent)
            }
        }

        var receivedAt: Date {
            switch self {
            case let .message(item): item.entry.receivedAt
            case let .reply(item): item.entry.receivedAt
            }
        }
    }

    private var designPalette: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    /// Rows sit on the page background on iPhone. On iPad the list is in the
    /// system's floating glass sidebar, so rows leave the glass showing.
    private var rowSurface: Color {
        isPadSidebar ? .clear : designPalette.background
    }

    private var isPadSidebar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass != .compact
    }

    private var listTint: Color {
        guard let selected,
              let item = rows.first(where: { $0.id == selected }) else {
            return designPalette.amber
        }
        return designPalette.openRowFill(item.resolvedMessageType)
    }

    private func filteredRows(in tab: InboxWorkspaceTab) -> [InboxItem] {
        if showsFreeOrder {
            return normalListEntries.flatMap { entry -> [InboxItem] in
                guard case let .message(message) = entry else { return [] }
                return message.members
            }
        }
        return InboxListProjection.filteredRows(rows, in: tab, search: search)
    }

    private var showsFreeOrder: Bool {
        tab == .inbox && InboxFreeOrder.isSupported(
            version: conversationStore?.presentation.inboxFreeOrderVersion,
            items: conversationStore?.presentation.inboxViewListItems)
    }

    private var freeHistoryIDs: Set<InboxNormalListDisplayEntry.ID> {
        guard showsFreeOrder else { return [] }
        return Set((conversationStore?.presentation.inboxViewListItems ?? []).compactMap { item in
            guard item.freeSection?.state == .history else { return nil }
            return item.kind == .reply ? .reply(item.key) : .message(.row(.request(item.key)))
        })
    }

    private var normalListEntries: [InboxNormalListDisplayEntry] {
        InboxNormalListProjection.entries(
            rows: rows,
            serverItems: conversationStore?.presentation.inboxViewListItems,
            freeOrderVersion: conversationStore?.presentation.inboxFreeOrderVersion,
            in: tab,
            search: search)
    }

    private var matchingExpiredRetractionRows: [InboxRequestRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let conversationStore else { return [] }
        let isRepliedTab = tab.messageTab == .replied
        return conversationStore.expiredRetractionSearchRows.filter { row in
            let item = InboxItem.request(row)
            return item.belongsToReplied == isRepliedTab && item.matchesSearch(query)
        }
    }

    private func normalReplyProjection(for reference: InboxViewListItem) -> ReplyItemNormalRow? {
        ReplyItemNormalRowProjection.resolve(
            reference, in: conversationStore?.conversation(for: reference.key))
    }

    private func localReplyReceiptDate(for parent: RequestKey, replyID: ExactText) -> Date? {
        ReplyItemLocalReceiptTime.resolve(replyID, in: conversationStore?.conversation(for: parent))
    }

    private var matchingNewMessageAreaRows: [NewMessageAreaListRow] {
        guard tab == .inbox, let newMessageAreaStore else { return [] }
        var requestRows: [RequestKey: InboxRequestRow] = [:]
        for item in rows {
            guard case let .request(row) = item else { continue }
            requestRows[row.key] = row
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return newMessageAreaStore.entries.compactMap { entry in
            guard let row = requestRows[entry.key],
                  query.isEmpty || InboxItem.request(row).matchesSearch(query) else { return nil }
            return NewMessageAreaListRow(entry: entry, row: row)
        }
    }

    private var matchingReplyItemRows: [ReplyItemListRow] {
        guard tab == .inbox, let replyItemAreaStore else { return [] }
        var requestRows: [RequestKey: InboxRequestRow] = [:]
        for item in rows {
            guard case let .request(row) = item else { continue }
            requestRows[row.key] = row
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return replyItemAreaStore.entries.compactMap { entry in
            let row = conversationStore?.inboxRow(for: entry.parent) ?? requestRows[entry.parent]
            let matchesSearch = row.map { InboxItem.request($0).matchesSearch(query) } ??
                (entry.parent.senderID.rawValue.localizedCaseInsensitiveContains(query) ||
                 entry.parent.messageID.rawValue.localizedCaseInsensitiveContains(query))
            guard query.isEmpty || matchesSearch else { return nil }
            return ReplyItemListRow(entry: entry, row: row)
        }
    }

    private var combinedNewMessageAreaRows: [NewMessageAreaCombinedRow] {
        NewMessageAreaRowOrder.merged(
            messages: matchingNewMessageAreaRows,
            replies: matchingReplyItemRows,
            messageDate: { $0.entry.receivedAt },
            replyDate: { $0.entry.receivedAt },
            message: NewMessageAreaCombinedRow.message,
            reply: NewMessageAreaCombinedRow.reply)
    }

    private func updateVisibility(_ token: NewMessageAreaVisibility, isVisible: Bool) {
        if isVisible {
            guard workspaceTab == tab else {
                visibleMessagePlacements.remove(token)
                return
            }
            visibleMessagePlacements.insert(token)
            if canRecordFirstSeen, !NativePushedViewCoordinator.shared.isPassive(token.key) {
                markFirstSeen(token)
            }
        } else {
            visibleMessagePlacements.remove(token)
        }
    }

    private func markFirstSeen(_ token: NewMessageAreaVisibility) {
        switch token.kind {
        case .message: newMessageAreaStore?.markFirstSeen(token.key)
        case .replyItem: replyItemAreaStore?.markFirstSeen(token.key)
        }
    }

    private var canRecordFirstSeen: Bool {
        scenePhase == .active && workspaceTab == tab &&
            UIApplication.shared.isProtectedDataAvailable
    }

    private func recordVisibleMessagesAsSeen() {
        guard canRecordFirstSeen else { return }
        for placement in visibleMessagePlacements {
            if !NativePushedViewCoordinator.shared.isPassive(placement.key) {
                markFirstSeen(placement)
            }
        }
    }

    private func selectReplyItem(_ parent: RequestKey,
                                 targetTurnID: ExactText?,
                                 targetConversationSequence: UInt64?,
                                 fromNewArea: Bool,
                                 using proxy: ScrollViewProxy) {
        lastViewedReplyTarget = parent
        if fromNewArea {
            withAnimation(reduceMotion ? nil : .default) {
                replyItemAreaStore?.removeForSelection(parent)
            }
        }
        openReplyItem(parent, targetTurnID, targetConversationSequence)
        guard fromNewArea else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation(reduceMotion ? nil : .default) {
                proxy.scrollTo(InboxListRowScrollTarget(
                    tab: tab,
                    selection: .request(parent),
                    placement: .normalReplyItem), anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func newMessageAreaRow(_ item: NewMessageAreaListRow,
                                  in tab: InboxWorkspaceTab,
                                  selected isSelected: Bool) -> some View {
        NavigationLink(value: InboxSelection.request(item.row.key)) {
            NewMessageAreaRowContent(
                key: item.row.key,
                title: item.row.title,
                bodyText: item.row.bodyText,
                requestRevision: item.row.requestRevision,
                createdAt: item.row.createdAt,
                receivedAt: item.entry.receivedAt,
                inboxScore: item.row.inboxScore,
                messageType: item.row.resolvedMessageType,
                store: newMessageAreaStore,
                selected: isSelected)
        }
        .buttonStyle(.plain)
        .tint(.clear)
        .navigationLinkIndicatorVisibility(.hidden)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .tag(InboxSelection.request(item.row.key))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            messageSwipeActions(for: .request(item.row), in: tab)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            messageSwipeActions(for: .request(item.row), in: tab)
        }
        .id(InboxListRowScrollTarget(tab: tab,
                                     selection: .request(item.row.key),
                                     placement: .newMessageArea))
        .onScrollVisibilityChange(threshold: 0.001) { isVisible in
            updateVisibility(.init(key: item.row.key, placement: .area), isVisible: isVisible)
        }
        .accessibilityIdentifier("new-message-area-\(InboxItem.request(item.row).accessibilityID)")
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(rowSurface)
    }

    @ViewBuilder
    private func replyItemRow(_ item: ReplyItemListRow,
                              in tab: InboxWorkspaceTab,
                              selected isSelected: Bool,
                              using proxy: ScrollViewProxy) -> some View {
        Button {
            selectReplyItem(item.entry.parent,
                            targetTurnID: item.entry.earliestUnseenReply?.turnID,
                            targetConversationSequence: item.entry.earliestUnseenReply?.conversationSequence,
                            fromNewArea: true,
                            using: proxy)
        } label: {
            ReplyItemRowContent(
                entry: item.entry,
                parentTitle: item.parentTitle,
                senderLabel: item.senderLabel,
                priorityScore: ReplyItemPriorityProjection.score(
                    for: item.entry,
                    perReplyScores: item.inboxReplyScores,
                    serverListItems: conversationStore?.presentation.inboxViewListItems),
                receivedAt: item.entry.newestUnseenReply.flatMap {
                    localReplyReceiptDate(for: item.entry.parent, replyID: $0.turnID)
                },
                selected: isSelected)
        }
        .buttonStyle(.plain)
        .tint(.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(InboxListRowScrollTarget(tab: tab,
                                     selection: .request(item.entry.parent),
                                     placement: .replyItemArea))
        .onScrollVisibilityChange(threshold: 0.001) { isVisible in
            updateVisibility(.init(key: item.entry.parent, placement: .area, kind: .replyItem),
                             isVisible: isVisible)
        }
        .accessibilityIdentifier("reply-item-request-row-\(item.entry.parent.messageID.rawValue)")
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(rowSurface)
    }

    @ViewBuilder
    private func normalReplyItemRow(_ reference: InboxViewListItem,
                                   in tab: InboxWorkspaceTab,
                                   selected isSelected: Bool,
                                   using proxy: ScrollViewProxy) -> some View {
        let parent = conversationStore?.inboxRow(for: reference.key) ?? rows.compactMap { item -> InboxRequestRow? in
            guard case let .request(row) = item, row.key == reference.key else { return nil }
            return row
        }.first
        let item = NormalReplyItemListRow(
            reference: reference,
            projection: normalReplyProjection(for: reference),
            parent: parent)
        Button {
            let targetSequence = (reference.unseenCount ?? 0) > 0
                ? reference.openAtConversationSequence
                : reference.conversationSequence
            selectReplyItem(reference.key,
                            targetTurnID: item.projection?.openTargetTurnID,
                            targetConversationSequence: targetSequence,
                            fromNewArea: false,
                            using: proxy)
        } label: {
            ReplyItemNormalRowContent(
                reference: item.reference,
                projection: item.projection,
                parentTitle: item.parentTitle,
                senderLabel: item.senderLabel,
                selected: isSelected)
        }
        .buttonStyle(.plain)
        .tint(.clear)
        .tag(InboxSelection.request(reference.key))
        .id(InboxListRowScrollTarget(tab: tab,
                                     selection: .request(reference.key),
                                     placement: .normalReplyItem))
        .onScrollVisibilityChange(threshold: 0.001) { isVisible in
            updateVisibility(.init(key: reference.key, placement: .normalList, kind: .replyItem),
                             isVisible: isVisible)
        }
        .accessibilityIdentifier("normal-reply-item-\(reference.key.messageID.rawValue)")
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(rowSurface)
    }

    private var brandAndStatusHeader: some View {
        HStack(spacing: 8) {
            HarklightBrand().accessibilityIdentifier("inbox-brand")
            if isRefreshing {
                // Refreshing is status, not a control: a plain spinner with no
                // capsule or button chrome around it.
                ProgressView()
                    .controlSize(.small)
                    .tint(designPalette.label)
                    .accessibilityLabel("Refreshing")
                    .accessibilityIdentifier("inbox-refreshing-badge")
            }
        }
    }

    @ViewBuilder
    private var warningButton: some View {
        if !warnings.isEmpty {
            Button {
                isWarningPresented = true
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(designPalette.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Warnings")
            .accessibilityIdentifier("inbox-warning-button")
            .popover(isPresented: $isWarningPresented) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Harklight warning", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(designPalette.secondary)
                        ForEach(warnings.indices, id: \.self) { index in
                            Text(warnings[index])
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("inbox-warning-message")
                        }
                    }
                    .padding(16)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        warningContentHeight = height
                    }
                }
                .frame(width: 320,
                       height: min(max(warningContentHeight, 88), 440))
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var settingsButton: some View {
        Button(action: showSettings) {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .foregroundStyle(designPalette.text)
        }
        .tint(designPalette.text)
            .accessibilityIdentifier("inbox-settings")
    }

    private func restoreLastViewed(using proxy: ScrollViewProxy, in tab: InboxWorkspaceTab) {
        guard restoreLastViewed else { return }
        guard let lastViewedSelection else {
            didRestoreLastViewed()
            return
        }
        let requestedReplyTarget: RequestKey? = if case let .request(key) = lastViewedSelection,
                                                     lastViewedReplyTarget == key {
            key
        } else {
            nil
        }
        if let requestedReplyTarget,
           !normalListEntries.contains(where: { $0.id == .reply(requestedReplyTarget) }) {
            return
        }
        let replyTargetKey = requestedReplyTarget
        guard rows.contains(where: { $0.id == lastViewedSelection }) || replyTargetKey != nil else {
            if lastViewedReplyTarget != nil { return }
            didRestoreLastViewed()
            return
        }
        if !filteredRows(in: tab).contains(where: { $0.id == lastViewedSelection }) {
            if replyTargetKey != nil {
                proxy.scrollTo(InboxListRowScrollTarget(tab: tab,
                    selection: lastViewedSelection, placement: .normalReplyItem), anchor: .center)
                lastViewedReplyTarget = nil
                didRestoreLastViewed()
                return
            }
            UIDiagnostics.shared.record("list.restoreClearsSearch search=\(search) last=\(UIDiagnostics.describe(lastViewedSelection))")
            search = ""
            return
        }
        if replyTargetKey == nil {
            expandThreadContaining(lastViewedSelection, in: tab)
        }
        proxy.scrollTo(InboxListRowScrollTarget(
            tab: tab,
            selection: lastViewedSelection,
            placement: replyTargetKey == nil ? .normal : .normalReplyItem), anchor: .center)
        lastViewedReplyTarget = nil
        didRestoreLastViewed()
    }

    /// When a filter shrinks the list while it is scrolled down, the lazy stack
    /// can keep its old visible range and draw none of the matching rows, so a
    /// filter change starts the list again at its first row.
    private func showFirstRow(using proxy: ScrollViewProxy, in tab: InboxWorkspaceTab) {
        if showsFreeOrder {
            for entry in normalListEntries {
                switch entry {
                case .heading: continue
                case let .reply(reference):
                    proxy.scrollTo(InboxListRowScrollTarget(tab: tab,
                        selection: .request(reference.key), placement: .normalReplyItem), anchor: .top)
                case let .message(message):
                    let first = message.members[0]
                    expandThreadContaining(first.id, in: tab)
                    proxy.scrollTo(InboxListRowScrollTarget(tab: tab, selection: first.id), anchor: .top)
                }
                return
            }
            return
        }
        guard let first = filteredRows(in: tab).first else { return }
        expandThreadContaining(first.id, in: tab)
        proxy.scrollTo(InboxListRowScrollTarget(tab: tab, selection: first.id), anchor: .top)
    }

    private func expandThreadContaining(_ selection: InboxSelection, in tab: InboxWorkspaceTab) {
        let entries: [InboxListEntry] = showsFreeOrder ? normalListEntries.compactMap {
            guard case let .message(message) = $0 else { return nil }
            return message
        } : InboxListProjection.visibleEntries(rows, in: tab, search: search)
        guard let group = entries
            .first(where: { entry in
                guard case .thread = entry else { return false }
                return entry.members.contains { $0.id == selection }
            }) else { return }
        expandedThreadGroups.insert(group.id)
    }

    private func openSettings() {
        showSettings()
    }

    private var diagnosticSummary: String {
        let selectedMessageTab = tab.messageTab
        let inTab = rows.filter { $0.belongsToReplied == (selectedMessageTab == .replied) }
        let filtered = filteredRows(in: tab).map { row -> String in
            let missingRow: Bool = if case let .example(_, response) = row { response.inboxRow == nil } else { false }
            return row.accessibilityID + (missingRow ? ":empty" : "")
        }
        return [
            "search=\(search) workspaceTab=\(workspaceTab) listTab=\(tab) tab=\(selectedMessageTab.rawValue)",
            "restoreLastViewed=\(restoreLastViewed) lastViewed=\(UIDiagnostics.describe(lastViewedSelection)) selected=\(UIDiagnostics.describe(selected))",
            "refreshAvailable=\(refreshInbox != nil) isRefreshing=\(isRefreshing)",
            "rows=\(rows.count) inTab=\(inTab.count) filtered=\(filtered)",
        ].joined(separator: " | ")
    }

    private func requestOlderPage() {
        guard !requestedInGesture, !isFetchingOlderPage,
              let fetchOlderInboxPage else { return }
        requestedInGesture = true
        // Animate the loading row in and out: an unanimated content-size change
        // while the list is displaced past its extents clamps the offset and
        // reads as a snap instead of the native elastic settle.
        withAnimation { isFetchingOlderPage = true }
        Task {
            _ = await fetchOlderInboxPage()
            withAnimation { isFetchingOlderPage = false }
        }
    }

    private func inboxScrollMetrics(from geometry: ScrollGeometry) -> InboxScrollMetrics {
        let top: CGFloat = geometry.contentOffset.y + geometry.contentInsets.top
        let extent: CGFloat = max(0, geometry.contentSize.height - geometry.containerSize.height +
            geometry.contentInsets.top + geometry.contentInsets.bottom)
        let distanceToBottom: CGFloat = max(0, extent - top)
        return InboxScrollMetrics(offsetY: geometry.contentOffset.y,
                                  distanceToBottom: distanceToBottom,
                                  contentFits: extent == 0)
    }

    private func updateScrollMetrics(from oldMetrics: InboxScrollMetrics,
                                     to newMetrics: InboxScrollMetrics) {
        let canPageOnDrag = newMetrics.contentFits || newMetrics.distanceToBottom <= 80
        // Pixel offsets are for this callback only; publishing each one invalidates the list.
        if canRequestOlderPageOnDrag != canPageOnDrag {
            canRequestOlderPageOnDrag = canPageOnDrag
        }
        guard isUserScrolling,
              newMetrics.offsetY > oldMetrics.offsetY + 1,
              newMetrics.distanceToBottom <= 80 else { return }
        requestOlderPage()
    }

    private func updateScrollPhase(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) {
        let scrolling: Bool = newPhase == .interacting || newPhase == .decelerating
        if scrolling && !isUserScrolling { requestedInGesture = false }
        if isUserScrolling != scrolling { isUserScrolling = scrolling }
        if oldPhase == .interacting && !scrolling { requestedInGesture = false }
    }

    private var listSelection: Binding<InboxSelection?>? {
        $selected
    }

    @ViewBuilder
    private func rowContent(for row: InboxItem) -> some View {
        let isSelected = selected == row.id
        switch row {
        case let .request(request):
            NavigationLink(value: row.id) {
                inboxRowLabel(request, selected: isSelected)
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)
        case let .example(_, response):
            if let request = response.inboxRow {
                NavigationLink(value: row.id) {
                    inboxRowLabel(request, selected: isSelected)
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
            }
        }
    }

    private func inboxRowLabel(_ request: InboxRequestRow, selected: Bool) -> some View {
        InboxRowContent(row: request, selected: selected)
    }

    @ViewBuilder
    private func messageSwipeActions(for row: InboxItem, in tab: InboxWorkspaceTab) -> some View {
        let canAct = tab.messageTab == .inbox && !row.belongsToReplied
        let clearButton = Button { clearRetracted(row.id) } label: {
            Label("Clear", systemImage: "xmark")
        }
        .disabled(!canAct || !row.isRetracted)
        .tint(designPalette.secondary)
        .accessibilityIdentifier("inbox-clear-retracted")
        let seenButton = Button { markSeen(row.id) } label: {
            Label("Seen", systemImage: "checkmark")
        }
        .disabled(!canAct || !row.canMarkSeen)
        .tint(designPalette.teal)
        .accessibilityIdentifier("inbox-mark-seen")
        let noCommentButton = Button { markNoComment(row.id) } label: {
            Label("No comment", systemImage: "hand.raised")
        }
        .disabled(!canAct || !row.canNoComment)
        .tint(designPalette.secondary)
        .accessibilityIdentifier("inbox-no-comment")

        // Full swipe invokes the first action. Keep the applicable action first
        // while retaining the unavailable controls as visible, disabled buttons.
        if row.isRetracted {
            clearButton
            seenButton
            noCommentButton
        } else if row.canMarkSeen {
            seenButton
            clearButton
            noCommentButton
        } else if row.canNoComment {
            noCommentButton
            clearButton
            seenButton
        } else {
            clearButton
            seenButton
            noCommentButton
        }
    }

    @ViewBuilder
    private func listRow(for row: InboxItem, in tab: InboxWorkspaceTab) -> some View {
        rowContent(for: row)
            .tag(row.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                messageSwipeActions(for: row, in: tab)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                messageSwipeActions(for: row, in: tab)
            }
            .id(InboxListRowScrollTarget(tab: tab, selection: row.id))
            .accessibilityIdentifier(row.accessibilityID)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(rowSurface)
            .onScrollVisibilityChange(threshold: 0.001) { isVisible in
                guard case let .request(request) = row else { return }
                updateVisibility(.init(key: request.key, placement: .normalList),
                                  isVisible: isVisible)
            }
    }

    private func expiredRetractionHistoryRow(_ row: InboxRequestRow,
                                             in tab: InboxWorkspaceTab) -> some View {
        let item = InboxItem.request(row)
        return rowContent(for: item)
            .tag(item.id)
            .id(InboxListRowScrollTarget(tab: tab, selection: item.id))
            .accessibilityIdentifier("expired-retraction-history-\(row.key.messageID.rawValue)")
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(rowSurface)
    }

    private func threadExpansionBinding(for id: InboxListEntryID) -> Binding<Bool> {
        Binding(
            get: { expandedThreadGroups.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedThreadGroups.insert(id)
                } else {
                    expandedThreadGroups.remove(id)
                }
            })
    }

    private func threadGroupLabel(members: [InboxItem]) -> some View {
        let sender = members.first.map { item -> String in
            switch item {
            case let .request(row): row.senderLabel
            case let .example(message, _): InboxSenderDisplay.name(for: message.sender)
            }
        } ?? String(localized: "Sender")
        return HStack(spacing: 10) {
            Image(systemName: "square.stack")
                .foregroundStyle(designPalette.label)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "\(members.count) messages from \(sender)"))
                    .harklightType(.more)
                    .foregroundStyle(designPalette.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(members.count) messages from \(sender), in one thread"))
    }

    @ViewBuilder
    private func newMessageAreaListRow(_ combined: NewMessageAreaCombinedRow,
                                      in tab: InboxWorkspaceTab,
                                      using proxy: ScrollViewProxy) -> some View {
        switch combined {
        case let .message(item):
            let selection = InboxSelection.request(item.row.key)
            newMessageAreaRow(item, in: tab,
                              selected: selected == selection || lastViewedSelection == selection)
        case let .reply(item):
            let selection = InboxSelection.request(item.entry.parent)
            replyItemRow(item, in: tab,
                         selected: selected == selection || lastViewedSelection == selection,
                         using: proxy)
        }
    }

    @ViewBuilder
    private func normalListRow(_ entry: InboxNormalListDisplayEntry,
                               in tab: InboxWorkspaceTab,
                               using proxy: ScrollViewProxy) -> some View {
        switch entry {
        case let .heading(heading):
            VStack(alignment: .leading, spacing: 4) {
                Text(heading.title)
                    .harklightType(.sectionHeading)
                    .accessibilityAddTraits(.isHeader)
                if let explanation = heading.explanation {
                    Text(explanation).harklightType(.newStatus)
                }
            }
            .foregroundStyle(designPalette.label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(rowSurface)
        case let .message(messageEntry):
            switch messageEntry {
            case let .row(row):
                listRow(for: row, in: tab)
            case let .thread(_, members):
                DisclosureGroup(isExpanded: threadExpansionBinding(for: messageEntry.id)) {
                    ForEach(members) { row in
                        listRow(for: row, in: tab)
                    }
                } label: {
                    threadGroupLabel(members: members)
                }
                .accessibilityIdentifier("inbox-thread-group-\(members[0].accessibilityID)")
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        case let .reply(reference):
            let selection = InboxSelection.request(reference.key)
            normalReplyItemRow(reference, in: tab,
                               selected: selected == selection || lastViewedSelection == selection,
                               using: proxy)
        }
    }

    @ViewBuilder
    private func listContent(for tab: InboxWorkspaceTab,
                             using proxy: ScrollViewProxy) -> some View {
        let normalEntries = normalListEntries
        let historyIDs = freeHistoryIDs
        let historyRows = matchingExpiredRetractionRows
        let areaRows = combinedNewMessageAreaRows
        let shownAreaRows = isNewMessageAreaExpanded ? areaRows : Array(areaRows.prefix(5))
        List(selection: listSelection) {
            if tab == .inbox, let route = notificationNavigation, route.request == nil {
                let rowState = notificationPendingPresentation.flatMap {
                    $0.serial == route.serial ? $0.listRowState : nil
                } ?? .invalid
                NavigationLink(value: InboxSelection.notificationPending(route.serial)) {
                    InboxNotificationPendingListRow(state: rowState)
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("notification-pending-row")
            }
            if !areaRows.isEmpty {
                Section {
                    ForEach(shownAreaRows) { combined in
                        newMessageAreaListRow(combined, in: tab, using: proxy)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(rowSurface)
                    if areaRows.count > 5 {
                        Button(isNewMessageAreaExpanded ? "Less" : "More…") {
                            isNewMessageAreaExpanded.toggle()
                        }
                        .foregroundStyle(designPalette.text)
                        .harklightType(.more)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HarklightDesignSystem.shape(.rowHorizontalPadding))
                        .padding(.vertical, HarklightDesignSystem.shape(.rowVerticalPadding))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(designPalette.line).frame(height: 1)
                                .accessibilityHidden(true)
                        }
                        .listRowBackground(rowSurface)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("new-message-area-more")
                    }
                } header: {
                    Text(String(localized: "New · \(shownAreaRows.count) of \(areaRows.count)"))
                        .harklightType(.sectionHeading)
                        .foregroundStyle(designPalette.label)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HarklightDesignSystem.shape(.rowHorizontalPadding))
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(designPalette.line).frame(height: 1)
                                .accessibilityHidden(true)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("new-message-area-header")
                }
                .listSectionMargins(.vertical, 0)
            }
            if tab == .inbox && showsBasicOrderMarker && !showsFreeOrder {
                Text("Basic order")
                    .harklightType(.sectionHeading)
                    .foregroundStyle(designPalette.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("inbox-basic-order")
            }
            ForEach(normalEntries) { entry in
                normalListRow(entry, in: tab, using: proxy)
                    .opacity(historyIDs.contains(entry.id) ? 0.7 : 1)
            }
            // Row modifiers inside the conditional row builders do not reach
            // the list, so the list-row surface is set on each ForEach.
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(rowSurface)
            if !historyRows.isEmpty {
                Section {
                    ForEach(historyRows) { row in
                        expiredRetractionHistoryRow(row, in: tab)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(rowSurface)
                } header: {
                    Text("Retracted history")
                        .harklightType(.sectionHeading)
                        .foregroundStyle(designPalette.label)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("expired-retraction-history-header")
                }
            }
            if normalEntries.isEmpty, areaRows.isEmpty, historyRows.isEmpty, let triggerNotification {
                Button("Open notification", action: triggerNotification)
                    .accessibilityIdentifier("harklight-test-notification")
            }
            if isFetchingOlderPage {
                ProgressView().frame(maxWidth: .infinity).padding()
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .listSectionSeparator(.hidden)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .tint(listTint)
        .animation(reduceMotion ? nil : .default, value: normalEntries.map(\.id))
        .animation(reduceMotion ? nil : .default, value: shownAreaRows.map(\.id))
        .scrollContentBackground(.hidden)
        .background { rowSurface.ignoresSafeArea() }
        .foregroundStyle(designPalette.text)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Harklight")
        .toolbarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                brandAndStatusHeader
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) {
                settingsButton
                warningButton
            }
        }
        .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
        .toolbarMinimizationRestoration(.automatic, for: .navigationBar)
        .onAppear {
            guard workspaceTab == tab else { return }
            restoreLastViewed(using: proxy, in: tab)
            recordVisibleMessagesAsSeen()
        }
        .onChange(of: workspaceTab) { _, activeTab in
            guard activeTab == tab else {
                visibleMessagePlacements.removeAll()
                return
            }
            recordVisibleMessagesAsSeen()
            if restoreLastViewed {
                restoreLastViewed(using: proxy, in: tab)
            } else {
                showFirstRow(using: proxy, in: tab)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recordVisibleMessagesAsSeen() }
        }
        .onChange(of: NativePushedViewCoordinator.shared.contentTouchRevision) { _, _ in
            recordVisibleMessagesAsSeen()
        }
        .onChange(of: restoreLastViewed) { _, shouldRestore in
            if shouldRestore, workspaceTab == tab {
                restoreLastViewed(using: proxy, in: tab)
            }
        }
        .onChange(of: notificationNavigation) { _, route in
            guard route != nil, workspaceTab == tab else { return }
            search = ""
        }
        .onChange(of: search) { _, _ in
            guard workspaceTab == tab else { return }
            if restoreLastViewed {
                restoreLastViewed(using: proxy, in: tab)
            } else {
                showFirstRow(using: proxy, in: tab)
            }
        }
        .onChange(of: normalEntries.map(\.id)) { _, _ in
            guard workspaceTab == tab, restoreLastViewed else { return }
            restoreLastViewed(using: proxy, in: tab)
        }
        .onScrollGeometryChange(for: InboxScrollMetrics.self) { geometry in
            inboxScrollMetrics(from: geometry)
        } action: { oldMetrics, newMetrics in
            updateScrollMetrics(from: oldMetrics, to: newMetrics)
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            updateScrollPhase(from: oldPhase, to: newPhase)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard value.translation.height < -12 else { return }
                if !isUserScrolling { isUserScrolling = true }
                if canRequestOlderPageOnDrag {
                    requestOlderPage()
                }
            }
            .onEnded { _ in
                isUserScrolling = false
                requestedInGesture = false
            })
    }

    @ViewBuilder
    private func renderedList(using proxy: ScrollViewProxy) -> some View {
        listContent(for: tab, using: proxy)
            .uiDiagnostics("inbox-list-diagnostics", diagnosticSummary)
    }

    var body: some View {
        ScrollViewReader { proxy in
            if let refreshInbox {
                renderedList(using: proxy)
                    .refreshable { await refreshInbox() }
            } else {
                renderedList(using: proxy)
            }
        }
    }
}

private struct InboxScrollMetrics: Equatable {
    let offsetY: CGFloat
    let distanceToBottom: CGFloat
    let contentFits: Bool
}

/// The wash and leading edge that mark an urgent or high-priority row.
struct InboxPriorityRowTreatment: Equatable {
    let washHex: String
    let edgeHex: String

    var washColor: Color { Color(harklightToken: washHex) }
    var edgeColor: Color { Color(harklightToken: edgeHex) }

    static func forLevel(_ level: InboxPriorityDisplay?, colorScheme: ColorScheme)
        -> InboxPriorityRowTreatment? {
        let palette = HarklightDesignSystem.palette(for: colorScheme)
        return switch level {
        case .urgent?: Self(washHex: palette.derived.urgentWash, edgeHex: palette.color.coral)
        case .high?: Self(washHex: palette.derived.highWash, edgeHex: palette.color.amber)
        case .low?, nil: nil
        }
    }
}

/// The iPad open row: a fill and a brighter leading bar in the open
/// message's type color, with the row's contents moved in.
struct InboxRowSelectionDecoration {
    static var barWidth: CGFloat { HarklightDesignSystem.shape(.selectionBar) }
    static var contentInset: CGFloat { HarklightDesignSystem.shape(.selectionIndent) }

    let fill: Color
    let bar: Color

    static func forType(_ type: HarklightMessageType, colorScheme: ColorScheme) -> Self {
        let palette = HarklightDesignSystem.palette(for: colorScheme)
        return Self(fill: palette.openRowFill(type), bar: palette.openRowBar(type))
    }
}

/// The New section's right-aligned priority label: reversed text on coral
/// for Urgent and on amber for High priority.
struct NewMessageAreaPriorityTreatment: Equatable {
    let capsuleFillHex: String
    let capsuleTextHex: String

    var capsuleFillColor: Color { Color(harklightToken: capsuleFillHex) }
    var capsuleTextColor: Color { Color(harklightToken: capsuleTextHex) }

    static func forLevel(_ level: InboxPriorityDisplay?, colorScheme: ColorScheme) -> Self? {
        let palette = HarklightDesignSystem.palette(for: colorScheme)
        return switch level {
        case .urgent?: Self(capsuleFillHex: palette.color.coral, capsuleTextHex: palette.color.onBeam)
        case .high?: Self(capsuleFillHex: palette.color.amber, capsuleTextHex: palette.color.onBeam)
        case .low?, nil: nil
        }
    }
}

/// Shared row surface: the urgent or high wash and edge, the iPad open row
/// fill, bar and indent, and the 1 point line under every row.
private struct InboxRowSurface: ViewModifier {
    let priority: InboxPriorityDisplay?
    /// The open message's type when this row is the open one.
    let openType: HarklightMessageType?
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = HarklightDesignSystem.palette(for: colorScheme)
        let decoration = openType.map { InboxRowSelectionDecoration.forType($0, colorScheme: colorScheme) }
        let treatment = decoration == nil
            ? InboxPriorityRowTreatment.forLevel(priority, colorScheme: colorScheme) : nil
        content
            .padding(.leading, decoration == nil ? 0 : InboxRowSelectionDecoration.contentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Rows show the page through them; keep the whole row tappable.
            .contentShape(Rectangle())
            .background {
                if let decoration {
                    Rectangle().fill(decoration.fill)
                } else if let treatment {
                    Rectangle().fill(treatment.washColor)
                }
            }
            .overlay(alignment: .leading) {
                if let decoration {
                    Rectangle().fill(decoration.bar)
                        .frame(width: InboxRowSelectionDecoration.barWidth)
                        .frame(maxHeight: .infinity)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                } else if let treatment {
                    Rectangle().fill(treatment.edgeColor)
                        .frame(width: HarklightDesignSystem.shape(.priorityEdge))
                        .frame(maxHeight: .infinity)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.line)
                    .frame(height: HarklightDesignSystem.shape(.lineWidth))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    fileprivate func inboxRowSurface(priority: InboxPriorityDisplay?,
                                     openType: HarklightMessageType?) -> some View {
        modifier(InboxRowSurface(priority: priority, openType: openType))
    }
}

/// The reversed priority label used in the New section.
private struct InboxUrgencyPill: View {
    let level: InboxPriorityDisplay
    let identifier: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let treatment = NewMessageAreaPriorityTreatment.forLevel(level, colorScheme: colorScheme)
        Text(level.title)
            .harklightType(.urgencyPill)
            .foregroundStyle(treatment?.capsuleTextColor ?? .clear)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(treatment?.capsuleFillColor ?? .clear, in: Capsule())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel(Text(level.title))
            .accessibilityIdentifier(identifier)
    }
}

private struct NewMessageAreaRowContent: View {
    let key: RequestKey
    let title: String
    let bodyText: String?
    let requestRevision: UInt64
    let createdAt: Date?
    let receivedAt: Date
    let inboxScore: Double?
    let messageType: HarklightMessageType
    let store: NewMessageAreaStore?
    let selected: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var palette: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private var scoreBadge: InboxPriorityDisplay? {
        guard let level = InboxPriorityDisplay.forScore(inboxScore),
              level == .high || level == .urgent else { return nil }
        return level
    }

    private var summaryInput: String {
        NewMessageAreaSummaryText.source(title: title, body: bodyText)
    }

    private var summaryKey: NewMessageAreaSummaryKey {
        NewMessageAreaSummaryKey(request: key, revision: requestRevision)
    }

    private var fallbackText: String {
        NewMessageAreaSummaryText.fallback(summaryInput)
    }

    private var displayedSummary: AttributedString {
        MessageMarkdown.compactPreview(
            authored: summaryInput,
            generatedSummary: store?.summary(for: key, revision: requestRevision) ?? fallbackText,
            characterLimit: 320)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayedSummary)
                .harklightType(.newSummary)
                .foregroundStyle(palette.text)
                .tint(palette.text)
                .lineLimit(2)
                .truncationMode(.tail)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(InboxFriendlyDate.label(for: createdAt ?? receivedAt))
                    .harklightType(.newStatus)
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let scoreBadge {
                    InboxUrgencyPill(level: scoreBadge,
                                     identifier: "new-message-area-priority-\(scoreBadge.rawValue)")
                }
            }
        }
        .padding(.horizontal, HarklightDesignSystem.shape(.rowHorizontalPadding))
        .padding(.vertical, HarklightDesignSystem.shape(.rowVerticalPadding))
        .inboxRowSurface(priority: nil, openType: selected ? messageType : nil)
        .accessibilityElement(children: .combine)
        .task(id: summaryKey) {
            guard let store, !MessageMarkdown.hasFormattingOrLinks(summaryInput) else { return }
            await store.createSummaryIfNeeded(
                for: NewMessageAreaSummaryInput(key: key,
                    revision: requestRevision, text: summaryInput))
        }
    }

}

/// A chat reply in the new-message area: the newest unseen reply quoted
/// behind a vertical reply bar, with the parent message and sender it
/// belongs to. Shows the reply's own words, not a summary.
private struct ReplyItemRowContent: View {
    let entry: ReplyItemEntry
    let parentTitle: String
    let senderLabel: String
    let priorityScore: Double?
    let receivedAt: Date?
    let selected: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var palette: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private var scoreBadge: InboxPriorityDisplay? {
        guard let level = InboxPriorityDisplay.forScore(priorityScore),
              level == .high || level == .urgent else { return nil }
        return level
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text(MessageMarkdown.attributed(
                    parentTitle,
                    prefixedBy: String(localized: "Reply · \(senderLabel) · ")))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .harklightType(.newStatus)
            .foregroundStyle(palette.secondary)
            .tint(palette.secondary)

            HStack(alignment: .top, spacing: 8) {
                Capsule()
                    .fill(palette.amber.opacity(0.55))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                Text(MessageMarkdown.preview(entry.newestUnseenReply?.text ?? "",
                                             characterLimit: 320))
                    .harklightType(.newSummary)
                    .foregroundStyle(palette.text)
                    .tint(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let receivedAt {
                    Text(InboxFriendlyDate.label(for: receivedAt))
                        .harklightType(.newStatus)
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if entry.unseenCount > 1 {
                    Text(String(localized: "\(entry.unseenCount) new"))
                        .harklightType(.newStatus)
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                        .accessibilityIdentifier("reply-item-unseen-count")
                }
                Spacer(minLength: 4)
                if let scoreBadge {
                    InboxUrgencyPill(level: scoreBadge,
                                     identifier: "reply-item-priority-\(scoreBadge.rawValue)")
                }
            }
        }
        .padding(.horizontal, HarklightDesignSystem.shape(.rowHorizontalPadding))
        .padding(.vertical, HarklightDesignSystem.shape(.rowVerticalPadding))
        .inboxRowSurface(priority: nil, openType: selected ? .request : nil)
        .accessibilityElement(children: .combine)
    }
}

struct InboxRowContent: View {
    let row: InboxRequestRow
    var selected = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private var messageType: HarklightMessageType { row.resolvedMessageType }

    private var priorityMarkerLevel: InboxPriorityDisplay? {
        guard let level = InboxPriorityDisplay.forScore(row.inboxScore),
              level == .high || level == .urgent else { return nil }
        return level
    }

    /// The title's own column starts after the type symbol, so lines under
    /// the title line up with the title text.
    private let symbolColumn: CGFloat = 26
    private let symbolSpacing: CGFloat = 12

    @ViewBuilder
    private var leadingAccessories: some View {
        if row.isRetracted {
            Text("Retracted")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.text)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(palette.line, lineWidth: 1))
                .accessibilityIdentifier("inbox-retracted-pill")
        }
        if row.hasDeliveryWarning {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.coral)
                .accessibilityLabel("Response not delivered")
                .accessibilityIdentifier("inbox-response-delivery-warning")
        }
        if row.hasMessageLoadWarning {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.coral)
                .accessibilityLabel("Message could not be loaded and was skipped")
                .accessibilityIdentifier("inbox-message-load-warning")
        }
    }

    @ViewBuilder
    private var titleTrailingStatus: some View {
        // Only a chat with an unread turn is marked; a read chat shows nothing.
        if row.chatUnread == true {
            Image(systemName: "flag.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 16, height: 16)
                .foregroundStyle(palette.amber)
                .accessibilityLabel("Unread conversation")
        }
        if row.localSeenSelected || row.informationalSeenStatus == .confirmed {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 16, height: 16)
                .foregroundStyle(palette.teal)
                .accessibilityLabel("Seen")
        }
    }

    @ViewBuilder
    private var priorityAndDueLine: some View {
        if priorityMarkerLevel != nil || row.duePhrase != nil {
            HStack(alignment: .top, spacing: 4) {
                if let level = priorityMarkerLevel {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(level.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .harklightType(.priorityLine)
                    .foregroundStyle(palette.text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(level.title))
                    .accessibilityIdentifier("inbox-priority-\(level.rawValue)")
                    .layoutPriority(1)
                }
                Spacer(minLength: 0)
                if let duePhrase = row.duePhrase {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(duePhrase.dayLine)
                                .lineLimit(1)
                            Text(duePhrase.timeLine)
                                .lineLimit(1)
                        }
                        // Keep this candidate at natural width so compact rows use the stacked fallback.
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(duePhrase.dayLine)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(duePhrase.timeLine)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .harklightType(.rowTime)
                    .foregroundStyle(palette.label)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(duePhrase.accessibilityLabel))
                    .accessibilityIdentifier("inbox-due-phrase")
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(displayInitials)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(palette.label)
                    .frame(width: HarklightDesignSystem.shape(.rowInitials),
                           height: HarklightDesignSystem.shape(.rowInitials))
                    .background(palette.field, in: Circle())
                    .overlay(Circle().strokeBorder(palette.line, lineWidth: 1))
                Text(verbatim: row.senderLabel)
                    .harklightType(.rowSender)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let createdAt = row.createdAt {
                    Text(InboxFriendlyDate.label(for: createdAt))
                        .harklightType(.rowTime)
                        .monospacedDigit()
                        .foregroundStyle(palette.label)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: symbolSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    leadingAccessories
                    // The type symbol is centered on the title's first line.
                    Image(systemName: messageType.symbol)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(palette.typeColor(messageType))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                        .accessibilityHidden(true)
                }
                .frame(minWidth: symbolColumn - symbolSpacing, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(MessageMarkdown.attributed(row.title))
                            .harklightType(.rowTitle)
                            .foregroundStyle(palette.text)
                            .tint(palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        titleTrailingStatus
                    }
                    priorityAndDueLine
                    if row.declaredMessageType != nil || row.declaredMessageKind != nil {
                        MessageMetadataBadges(messageType: row.declaredMessageType,
                                              messageKind: row.declaredMessageKind)
                    }
                    if let bodyText = row.bodyText, !bodyText.isEmpty {
                        Text(MessageMarkdown.attributed(bodyText))
                            .harklightType(.rowBody)
                            .foregroundStyle(palette.secondary)
                            .tint(palette.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    if let reason = row.orderingReason {
                        Text(reason)
                            .harklightType(.newStatus)
                            .foregroundStyle(palette.label)
                            .accessibilityIdentifier("inbox-ordering-reason")
                    }
                    if let defaultAnswerStatus = row.defaultAnswerStatus {
                        Text(defaultAnswerStatus).harklightType(.newStatus).foregroundStyle(palette.label)
                            .accessibilityIdentifier("inbox-default-answer-status")
                    } else if !row.isResolved && !row.visibleStatus.isEmpty {
                        Text(row.visibleStatus).harklightType(.newStatus).foregroundStyle(palette.label)
                    }
                    if let localStatus = row.localStatus {
                        Text(localStatus).harklightType(.newStatus).foregroundStyle(palette.label)
                    }
                }
            }
        }
        .padding(.horizontal, HarklightDesignSystem.shape(.rowHorizontalPadding))
        .padding(.vertical, HarklightDesignSystem.shape(.rowVerticalPadding))
        .foregroundStyle(palette.text)
        .inboxRowSurface(priority: InboxPriorityDisplay.forScore(row.inboxScore),
                         openType: selected ? messageType : nil)
        .accessibilityElement(children: .combine)
    }

    private var displayInitials: String {
        if !row.initials.isEmpty { return row.initials }
        let words = row.senderLabel
            .split(whereSeparator: { !$0.isLetter })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

/// Explicit presentation fixtures for screenshot verification of every tier,
/// independent of the tiers supplied by incoming messages.
struct InboxTierReferenceScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    private let longBody = "The first version is ready to review. It preserves the original notes, keeps the work available to the team, and leaves room for another pass. Please compare the details carefully before choosing the next step. The remaining information continues beyond this preview so the list can stay easy to scan. The shared folder still contains the alternate sketches, the comments from the last review, and the proposed timeline. None of those items will be discarded by opening this message. The full request explains the choices and their effects before you answer."

    private var palette: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private var rows: [(String, InboxRequestRow)] {
        let now = Date.now
        func date(_ daysAgo: Int) -> Date {
            Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        }
        func row(_ id: String, _ sender: String, _ initials: String,
                 _ title: String, _ tier: InboxAttentionTier, _ daysAgo: Int) -> InboxRequestRow {
            InboxRequestRow(key: RequestKey(accountScope: ExactText("reference"),
                                            senderID: ExactText(sender), messageID: ExactText(id)),
                            title: title, sender: sender, status: "", bodyText: longBody,
                            symbol: "envelope", createdAt: date(daysAgo),
                            initials: initials, tier: tier)
        }
        let deadline = Int(now.addingTimeInterval(60 * 60).timeIntervalSince1970 * 1_000)
        let dueAndReason = InboxRequestRow(
            key: RequestKey(accountScope: ExactText("reference"),
                            senderID: ExactText("Release assistant"),
                            messageID: ExactText("due-and-reason")),
            title: "Review the collection plan?",
            sender: "Release assistant",
            status: "",
            tier: .middle,
            duePhrase: InboxDuePhrase.presentation(for: deadline),
            orderingReason: "Waiting on the scheduled handoff")
        return [
            ("Deadline and server reason", dueAndReason),
            ("Top · 8 lines", row("top", "Project assistant", "PA", "Approve the collection plan?", .top, 0)),
            ("Middle · 4 lines", row("middle", "Design assistant", "DA", "Which layout should we use?", .middle, 1)),
            ("Low · 2 lines", row("low", "Setup assistant", "SA", "Prepare the display", .low, 4)),
            ("Older date", row("older", "Research assistant", "RA", "Review the earlier notes", .middle, 15)),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows.indices, id: \.self) { index in
                        Text(rows[index].0).font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondary)
                            .padding(.horizontal, 16).padding(.top, 8)
                        InboxRowContent(row: rows[index].1)
                            .accessibilityIdentifier("tier-reference-" + rows[index].1.key.messageID.rawValue)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .foregroundStyle(palette.text)
            .navigationTitle("Cell tiers")
        }
        .background(palette.background.ignoresSafeArea())
    }
}

struct InboxSettings: View {
    var launch: NativeAppLaunch? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if let launch,
                   launch.diagnostics.hasEvents || launch.foregroundConnectDiagnostic != nil {
                    InboxDiagnosticsSettingsSection(launch: launch, closeSettings: { dismiss() })
                }
                ReleaseNotesSettingsSection(notes: HarklightReleaseNotes.settingsHistory(
                    currentBuildIdentifier: HarklightReleaseNotes.currentBuildIdentifier()))
            }
            .harklightListSurface(.sheet)
            .harklightSheetTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                HarklightDoneButton { dismiss() }
            } }
        }
        .harklightSheetSurface()
    }
}

@MainActor
struct InboxDiagnosticsSettingsSection: View {
    let launch: NativeAppLaunch
    var isReadOnly = false
    var closeSettings: () -> Void = {}

    var body: some View {
        HarklightFormSection("Diagnostics") {
            if launch.diagnostics.hasEvents {
                ShareLink(item: launch.diagnostics.shareText) {
                    Label("Share diagnostics", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("client-diagnostics-share")
                Text("Shares retained client history without answers or credentials.")
                    .font(.footnote).foregroundStyle(.hkSecondary)
            }
            if let diagnostic = launch.foregroundConnectDiagnostic {
                ShareLink(item: diagnostic.shareText) {
                    Label("Share connection details", systemImage: "waveform.path")
                }
                .accessibilityIdentifier("foreground-connect-diagnostics")
                Text("Includes the app build, observed connection phase and queued-operation receipt state. Answers and credentials are excluded.")
                    .font(.footnote).foregroundStyle(.hkSecondary)
            }
            if !isReadOnly, let failureKey = launch.foregroundConnectFailureKey {
                Button("View connection details") {
                    launch.reopenForegroundConnectFailure(failureKey)
                    closeSettings()
                }
                .accessibilityIdentifier("foreground-connect-reopen-details")
                Button(launch.guidedJoin.busy || launch.guidedJoin.isApprovedConnectBusy
                       ? "Retrying connection…" : "Retry connection") {
                    Task { await launch.retryForegroundConnection() }
                }
                .disabled(launch.guidedJoin.busy || launch.guidedJoin.isApprovedConnectBusy)
                .accessibilityIdentifier("foreground-connect-settings-retry")
            }
        }
    }
}

private struct ReplyItemNormalRowContent: View {
    let reference: InboxViewListItem
    let projection: ReplyItemNormalRow?
    let parentTitle: String
    let senderLabel: String
    let selected: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var palette: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private var priority: InboxPriorityDisplay? {
        InboxPriorityDisplay.forScore(reference.score)
    }

    private var priorityLabel: String? {
        guard let priority, priority == .high || priority == .urgent else { return nil }
        guard reference.scoreKind == .historical else { return String(localized: priority.title) }
        return switch priority {
        case .urgent: String(localized: "Previous priority: Urgent")
        case .high: String(localized: "Previous priority: High priority")
        case .low: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text(MessageMarkdown.attributed(
                    parentTitle,
                    prefixedBy: String(localized: "Reply · \(senderLabel) · ")))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .harklightType(.rowSender)
            .foregroundStyle(palette.secondary)
            .tint(palette.secondary)

            HStack(alignment: .top, spacing: 8) {
                Capsule()
                    .fill(palette.amber.opacity(0.55))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                if let projection {
                    Text(MessageMarkdown.preview(projection.quotedReply.text.rawValue,
                                                 characterLimit: 480))
                        .harklightType(.rowBody)
                        .foregroundStyle(palette.text)
                        .tint(palette.text)
                        .lineLimit(3)
                        .truncationMode(.tail)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading reply")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let receivedAt = projection?.receivedAt {
                    Text(InboxFriendlyDate.label(for: receivedAt))
                        .harklightType(.rowTime)
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let unseenCount = reference.unseenCount, unseenCount > 1 {
                    Text(String(localized: "\(unseenCount) new"))
                        .harklightType(.rowTime)
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                        .accessibilityIdentifier("normal-reply-item-unseen-count")
                }
                Spacer(minLength: 4)
                if let priorityLabel {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(priorityLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .harklightType(.priorityLine)
                    .foregroundStyle(palette.text)
                    .accessibilityIdentifier("normal-reply-item-priority-\(priority?.rawValue ?? "none")")
                }
            }
        }
        .padding(.horizontal, HarklightDesignSystem.shape(.rowHorizontalPadding))
        .padding(.vertical, HarklightDesignSystem.shape(.rowVerticalPadding))
        .inboxRowSurface(priority: priority, openType: selected ? .request : nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Chat reply from \(senderLabel) about \(MessageMarkdown.visibleText(parentTitle))"))
    }
}
