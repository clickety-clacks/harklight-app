import SwiftUI
import UIKit
import AttentionDomain

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
    @Environment(\.colorScheme) private var colorScheme

    private var neutralTokens: HarklightDesignSource.Neutral {
        HarklightDesignSystem.palette(for: colorScheme).neutral
    }

    var body: some View {
        Group {
            if large {
                VStack(spacing: 16) {
                    LighthouseMark().frame(width: 64, height: 78)
                    Text("Harklight").font(.largeTitle.bold())
                    Text("Select a message").font(.subheadline).foregroundStyle(neutralTokens.secondaryTextColor)
                }
            } else {
                HStack(spacing: 20) {
                    LighthouseMark().frame(width: 24, height: 30)
                    Text("Harklight").font(.title.bold())
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .foregroundStyle(neutralTokens.textColor)
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
}

enum RelatedMessageTarget: Hashable {
    case supersedes(RequestKey)
    case replacement(RequestKey)
}

enum InboxMessageTab: String, Hashable {
    case inbox
    case replied
}

enum InboxWorkspaceTab: Hashable {
    case inbox
    case replied

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
            selection = nil
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
        if informationalSeenStatus != nil { return .info }
        return .request
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

    var bodyLineLimit: Int {
        switch self {
        case .top: 8
        case .middle: 4
        case .low: 2
        }
    }
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
    var testNotificationRouter: NativeNotificationRouter? = nil
    var testOpenForegroundChatIndicator: (() -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MessageTextSize.preferenceKey)
    private var selectedMessageTextSize = MessageTextSize.standard.rawValue
    @State private var selection: InboxSelection?
    @State private var relatedMessageNavigationPath: [RelatedMessageTarget] = []
    @State private var isWarningPresented = false
    @State private var settings = false
    @State private var selectedTab: InboxMessageTab = .inbox
    @State private var workspaceTab: InboxWorkspaceTab = .inbox
    @State private var search = ""
    @State private var testNotificationNavigation: NativeInboxNavigation?
    @State private var listTabOnMessageEntry: InboxMessageTab?
    @State private var lastViewedSelection: InboxSelection?
    @State private var navigatedBetweenMessages = false
    @State private var restoreLastViewedOnReturn = false
    @State private var replyChatRoute: ReplyChatRoute?

    private var rows: [InboxItem] {
        showsLocalExamples ? samples.inboxItems(appendingTo: requests) : requests.map { .request($0) }
    }

    private var visibleWarnings: [String] {
        warnings + [samples.loadError].compactMap { $0 }
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

    private var orderedIDs: [InboxSelection] { rows.map(\.id) }
    private var usesFreeOrder: Bool {
        InboxFreeOrder.isSupported(version: conversationStore?.presentation.inboxFreeOrderVersion,
                                   items: conversationStore?.presentation.inboxViewListItems)
    }
    private var cardNavigationIDs: [InboxSelection] {
        // A Seen or answered card may leave this tab while it remains open.
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return orderedIDs
        }
        if usesFreeOrder, workspaceTab == .inbox {
            return InboxNormalListProjection.entries(rows: rows,
                serverItems: conversationStore?.presentation.inboxViewListItems,
                freeOrderVersion: conversationStore?.presentation.inboxFreeOrderVersion,
                in: .inbox, search: search).flatMap { entry -> [InboxSelection] in
                    guard case let .message(message) = entry else { return [] }
                    return message.members.map(\.id)
                }
        }
        return InboxListProjection.filteredRows(rows, in: workspaceTab,
            search: search).map(\.id)
    }
    private var activeNotificationNavigation: NativeInboxNavigation? {
        notificationNavigation ?? testNotificationNavigation
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

    private func navigate(from previous: InboxSelection?, to next: InboxSelection?) {
        guard previous != next else { return }
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
            if replyChatRoute?.key != newRequest {
                conversationStore?.newMessageAreaStore?.open(newRequest)
            }
            selectRequest(newRequest)
        }
        samples.select(newSampleID, departingFrom: oldSampleID)
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
        HStack(spacing: 0) {
            Group {
                switch item {
                case let .request(key)?:
                    requestDetail(key, cardContext(for: .request(key), inlineChat: inlineChat))
                        .id(key)
                case let .sample(id)?:
                    if showsLocalExamples,
                       samples.messages.contains(where: { $0.id == id }),
                       let response = samples.responses[id] {
                        SampleCardScreen(response: response,
                            context: cardContext(for: .sample(id), inlineChat: inlineChat))
                            .id(id)
                    }
                case nil:
                    HarklightBrand(large: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { HarklightDesignSystem.palette(for: colorScheme).neutral.backgroundColor.ignoresSafeArea() }
                }
            }
            .frame(maxWidth: .infinity)
            if inlineChat, case let .request(key)? = item, let conversationStore,
               let request = conversationStore.request(for: key),
               request.lifecycleStatus != .superseded {
                Divider()
                ConversationPanel(store: conversationStore, key: key,
                    sender: key.senderID.rawValue, title: request.title?.rawValue ?? "",
                    initialScrollTurnID: replyRouteTargetTurnID(for: key))
                    .frame(width: min(360, geometry.size.width * 0.34))
            }
            if inlineChat, case let .sample(id)? = item,
               let message = samples.messages.first(where: { $0.id == id }),
               let response = samples.responses[id] {
                Divider()
                SampleChatView(sender: message.sender, title: message.title, response: response)
                    .frame(width: min(360, geometry.size.width * 0.34))
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
                                geometry: GeometryProxy) -> some View {
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
                      workspaceTab: $workspaceTab, search: $search,
                      lastViewedSelection: lastViewedSelection,
                      restoreLastViewed: restoreLastViewedOnReturn,
                      didRestoreLastViewed: { restoreLastViewedOnReturn = false },
                      showSettings: { settings = true }, markSeen: markSeen,
                      markNoComment: markNoComment,
                      clearRetracted: clearRetracted,
                      fetchOlderInboxPage: fetchOlderInboxPage,
                      notificationNavigation: activeNotificationNavigation,
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
        }
        splitView.scrollBounceBehavior(.always, axes: .vertical)
    }

    private func cardContext(for id: InboxSelection, inlineChat: Bool = false) -> InboxCardContext {
        let ids = cardNavigationIDs
        let index = ids.firstIndex(of: id)
        let hasPrevious = index.map { $0 > 0 } ?? false
        let hasNext = index.map { $0 + 1 < ids.count } ?? false
        let chatRouteSerial: UInt64?
        var chatScrollTargetTurnID: ExactText? = nil
        var chatRouteDidOpen: (() -> Void)? = nil
        if case let .request(key) = id,
           let route = activeNotificationNavigation,
           route.opensChat, route.request == key {
            chatRouteSerial = route.serial
            chatRouteDidOpen = { [self] in self.notificationChatRouteDidOpen(route.serial) }
        } else if case let .request(key) = id,
                  let route = replyChatRoute, route.key == key {
            chatRouteSerial = route.serial
            chatScrollTargetTurnID = replyRouteTargetTurnID(for: key)
            chatRouteDidOpen = { [self] in
                if self.replyChatRoute?.serial == route.serial { self.replyChatRoute = nil }
            }
        } else {
            chatRouteSerial = nil
        }
        return InboxCardContext(position: (index ?? 0) + 1, total: ids.count,
            hasPrevious: hasPrevious,
            hasNext: hasNext,
            inlineChat: inlineChat,
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
            let tabs = TabView(selection: $workspaceTab) {
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

            }
            .tint(HarklightDesignSystem.palette(for: colorScheme).accent.color)
            .onChange(of: workspaceTab) { oldTab, newTab in
                if oldTab != newTab { isWarningPresented = false }
                selectedTab = newTab.messageTab
            }
            .onChange(of: selectedTab) { _, tab in
                workspaceTab = tab == .replied ? .replied : .inbox
            }
            .onChange(of: visibleWarnings, initial: true) { _, newWarnings in
                dismissWarningWhenCleared(newWarnings)
            }
            tabs
            .onChange(of: activeNotificationNavigation, initial: true) { _, route in
                guard let route else { return }
                settings = false
                // Notification routing changes presentation only. Keep it out
                // of ordinary navigation cleanup so a tap cannot mutate the domain.
                let destination = InboxNotificationDestination(route: route, rows: rows,
                                                               usesFreeOrder: usesFreeOrder)
                workspaceTab = destination.workspaceTab
                selectedTab = destination.selectedTab
                search = destination.search
                selection = destination.selection
                if let key = route.request {
                    conversationStore?.newMessageAreaStore?.open(key)
                    lastViewedSelection = .request(key)
                    selectRequest(key)
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
        .tint(HarklightDesignSystem.palette(for: colorScheme).neutral.textColor)
        .environment(\.messageTextSize,
                     MessageTextSize.resolve(storedValue: selectedMessageTextSize))
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
    let triggerNotification: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.harklightReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }
    @Environment(\.colorScheme) private var colorScheme
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

    private var listTint: Color {
        guard let selected,
              let item = rows.first(where: { $0.id == selected }) else {
            return designPalette.accent.color
        }
        return designPalette.messageType(item.resolvedMessageType).backgroundColor
    }

    private var searchFieldPlacement: SearchFieldPlacement {
        horizontalSizeClass == .compact
            ? .navigationBarDrawer(displayMode: .always)
            : .sidebar
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
            if canRecordFirstSeen {
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
            markFirstSeen(placement)
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
                store: newMessageAreaStore,
                selected: isSelected)
        }
        .buttonStyle(.plain)
        .tint(.clear)
        .navigationLinkIndicatorVisibility(.hidden)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .tag(InboxSelection.request(item.row.key))
        .id(InboxListRowScrollTarget(tab: tab,
                                     selection: .request(item.row.key),
                                     placement: .newMessageArea))
        .onScrollVisibilityChange(threshold: 0.001) { isVisible in
            updateVisibility(.init(key: item.row.key, placement: .area), isVisible: isVisible)
        }
        .accessibilityIdentifier("new-message-area-\(InboxItem.request(item.row).accessibilityID)")
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(designPalette.neutral.backgroundColor)
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
        .listRowBackground(designPalette.neutral.backgroundColor)
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
        .listRowBackground(designPalette.neutral.backgroundColor)
    }

    private var brandAndStatusHeader: some View {
        HStack(spacing: 8) {
            HarklightBrand().accessibilityIdentifier("inbox-brand")
            if isRefreshing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(designPalette.accent.color)
                .tint(designPalette.accent.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(designPalette.accent.color.opacity(0.14), in: Capsule())
                .accessibilityElement(children: .combine)
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
                    .foregroundStyle(designPalette.neutral.secondaryTextColor)
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
                            .foregroundStyle(designPalette.neutral.secondaryTextColor)
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
        Button("Settings", systemImage: "gearshape", action: showSettings)
            .labelStyle(.iconOnly)
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
    private func listRow(for row: InboxItem, in tab: InboxWorkspaceTab) -> some View {
        let messageTab = tab.messageTab
        rowContent(for: row)
            .tag(row.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if messageTab == .inbox, !row.belongsToReplied, row.isRetracted {
                    Button { clearRetracted(row.id) } label: {
                        Label("Clear", systemImage: "xmark")
                    }
                    .tint(designPalette.neutral.secondaryTextColor)
                    .accessibilityIdentifier("inbox-clear-retracted")
                } else if messageTab == .inbox, !row.belongsToReplied, row.canMarkSeen {
                    Button { markSeen(row.id) } label: {
                        Label("Seen", systemImage: "checkmark")
                    }
                    .tint(designPalette.accent.seenColor)
                    .accessibilityIdentifier("inbox-mark-seen")
                } else if messageTab == .inbox, !row.belongsToReplied, row.canNoComment {
                    Button { markNoComment(row.id) } label: {
                        Label("No comment", systemImage: "hand.raised")
                    }
                    .tint(designPalette.neutral.secondaryTextColor)
                    .accessibilityIdentifier("inbox-no-comment")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if messageTab == .inbox, !row.belongsToReplied, row.isRetracted {
                    Button { clearRetracted(row.id) } label: {
                        Label("Clear", systemImage: "xmark")
                    }
                    .tint(designPalette.neutral.secondaryTextColor)
                    .accessibilityIdentifier("inbox-clear-retracted")
                } else if messageTab == .inbox, !row.belongsToReplied, row.canMarkSeen {
                    Button { markSeen(row.id) } label: {
                        Label("Seen", systemImage: "checkmark")
                    }
                    .tint(designPalette.accent.seenColor)
                    .accessibilityIdentifier("inbox-mark-seen")
                } else if messageTab == .inbox, !row.belongsToReplied, row.canNoComment {
                    Button { markNoComment(row.id) } label: {
                        Label("No comment", systemImage: "hand.raised")
                    }
                    .tint(designPalette.neutral.secondaryTextColor)
                    .accessibilityIdentifier("inbox-no-comment")
                }
            }
            .id(InboxListRowScrollTarget(tab: tab, selection: row.id))
            .accessibilityIdentifier(row.accessibilityID)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
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
                .foregroundStyle(designPalette.neutral.secondaryTextColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "\(members.count) messages from \(sender)"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(designPalette.neutral.textColor)
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
                    .font(.caption.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let explanation = heading.explanation {
                    Text(explanation).font(.caption)
                }
            }
            .foregroundStyle(designPalette.neutral.secondaryTextColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(designPalette.neutral.backgroundColor)
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
            if !areaRows.isEmpty {
                Section {
                    ForEach(shownAreaRows) { combined in
                        newMessageAreaListRow(combined, in: tab, using: proxy)
                    }
                    if areaRows.count > 5 {
                        Button(isNewMessageAreaExpanded ? "Less" : "More…") {
                            isNewMessageAreaExpanded.toggle()
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.top, 9)
                        .padding(.bottom, 10)
                        .listRowBackground(designPalette.neutral.rowTopColor)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("new-message-area-more")
                    }
                } header: {
                    Text(String(localized: "New · \(shownAreaRows.count) of \(areaRows.count)"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(NewMessageAreaSurface.forScheme(colorScheme).quietTitleColor)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                        .background(designPalette.neutral.rowTopColor)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("new-message-area-header")
                }
                .listSectionMargins(.vertical, 0)
            }
            if tab == .inbox && showsBasicOrderMarker && !showsFreeOrder {
                Text("Basic order")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(designPalette.neutral.secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("inbox-basic-order")
            }
            ForEach(normalEntries) { entry in
                normalListRow(entry, in: tab, using: proxy)
                    .opacity(historyIDs.contains(entry.id) ? 0.7 : 1)
            }
            if !historyRows.isEmpty {
                Section {
                    ForEach(historyRows) { row in
                        expiredRetractionHistoryRow(row, in: tab)
                    }
                } header: {
                    Text("Retracted history")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(designPalette.neutral.secondaryTextColor)
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
        .tint(listTint)
        .animation(reduceMotion ? nil : .default, value: normalEntries.map(\.id))
        .animation(reduceMotion ? nil : .default, value: shownAreaRows.map(\.id))
        .scrollContentBackground(.hidden)
        .background { designPalette.neutral.backgroundColor.ignoresSafeArea() }
        .foregroundStyle(designPalette.neutral.textColor)
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $search, placement: searchFieldPlacement, prompt: "Search messages")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .navigationTitle("Harklight")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                brandAndStatusHeader
            }
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

struct InboxPriorityRowTreatment: Equatable {
    let topHex: String
    let bottomHex: String
    let primaryTextHex: String
    let secondaryTextHex: String

    var topColor: Color { Color(harklightToken: topHex) }
    var primaryTextColor: Color { Color(harklightToken: primaryTextHex) }
    var secondaryTextColor: Color { Color(harklightToken: secondaryTextHex) }
    var initialsFillOpacity: Double { 0.18 }
    var initialsFillColor: Color { Color.white.opacity(initialsFillOpacity) }
    var backgroundStyle: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(
            colors: [topColor, Color(harklightToken: bottomHex)],
            startPoint: .top,
            endPoint: .bottom))
    }

    static func forLevel(_ level: InboxPriorityDisplay?, colorScheme: ColorScheme)
        -> InboxPriorityRowTreatment? {
        guard let level else { return nil }

        let values: (String, String, String, String)
        switch (level, colorScheme) {
        case (.high, .light):
            values = ("#73592A", "#5E4720", "#F6F1E7", "#E3DCCF")
        case (.urgent, .light):
            values = ("#A63A2A", "#8A2C1E", "#F6F1E7", "#E3DCCF")
        case (.high, .dark):
            values = ("#3A3119", "#2B2516", "#E6D9B8", "#AEA283")
        case (.urgent, .dark):
            values = ("#5A2219", "#3A1A14", "#F2C9BE", "#C0948A")
        default:
            return nil
        }

        return InboxPriorityRowTreatment(topHex: values.0, bottomHex: values.1,
                                         primaryTextHex: values.2,
                                         secondaryTextHex: values.3)
    }
}

struct InboxRowSelectionDecoration: Equatable {
    static let barWidth: CGFloat = 8
    static let contentInset: CGFloat = 16

    let barHex: String

    static func forLevel(_ level: InboxPriorityDisplay?, colorScheme: ColorScheme) -> Self {
        let barHex: String
        switch (level, colorScheme) {
        case (.high, .light): barHex = "#C29747"
        case (.high, .dark): barHex = "#917A3B"
        case (.urgent, .light): barHex = "#D86B5A"
        case (.urgent, .dark): barHex = "#B94331"
        case (_, .light): barHex = "#B3A389"
        case (_, .dark): barHex = "#756B61"
        default: barHex = "#B3A389"
        }
        return Self(barHex: barHex)
    }

    var barColor: Color { Color(harklightToken: barHex) }
}

/// The platform draws the tinted selection fill only while the selection is
/// emphasized (prominent background); an unfocused list or inactive scene gets
/// a pale fill instead, where the light selected-text colors would be
/// unreadable. Light text may appear only over the tinted fill.
enum InboxSelectedRowTextRule {
    static func usesSelectionFillColors(selected: Bool,
                                        backgroundProminence: BackgroundProminence) -> Bool {
        selected && backgroundProminence == .increased
    }
}

struct NewMessageAreaPriorityTreatment: Equatable {
    let capsuleFillHex: String
    let capsuleTextHex: String

    var capsuleFillColor: Color { Color(harklightToken: capsuleFillHex) }
    var capsuleTextColor: Color { Color(harklightToken: capsuleTextHex) }

    static func forLevel(_ level: InboxPriorityDisplay?, colorScheme: ColorScheme) -> Self? {
        let fill: String
        switch (level, colorScheme) {
        case (.high, .light): fill = "#73592A"
        case (.high, .dark): fill = "#7B6832"
        case (.urgent, .light): fill = "#A63A2A"
        case (.urgent, .dark): fill = "#B94331"
        default: return nil
        }
        return Self(capsuleFillHex: fill, capsuleTextHex: "#F6F1E7")
    }
}

struct NewMessageAreaSurface: Equatable {
    let quietTitleHex: String
    let separatorHex: String

    static func forScheme(_ colorScheme: ColorScheme) -> Self {
        switch colorScheme {
        case .light:
            Self(quietTitleHex: "#8A847A", separatorHex: "rgba(49,48,45,0.08)")
        case .dark:
            Self(quietTitleHex: "#726E67", separatorHex: "rgba(221,217,209,0.08)")
        @unknown default:
            Self(quietTitleHex: "#8A847A", separatorHex: "rgba(49,48,45,0.08)")
        }
    }

    var quietTitleColor: Color { Color(harklightToken: quietTitleHex) }
    var separatorColor: Color { Color(harklightToken: separatorHex) }
}

private struct NewMessageAreaRowContent: View {
    let key: RequestKey
    let title: String
    let bodyText: String?
    let requestRevision: UInt64
    let createdAt: Date?
    let receivedAt: Date
    let inboxScore: Double?
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

    private var badgeTreatment: NewMessageAreaPriorityTreatment? {
        .forLevel(scoreBadge, colorScheme: colorScheme)
    }

    private var selectionDecoration: InboxRowSelectionDecoration {
        .forLevel(nil, colorScheme: colorScheme)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(displayedSummary)
                .messageTextSize()
                .foregroundStyle(palette.neutral.textColor)
                .tint(palette.neutral.textColor)
                .lineLimit(2)
                .truncationMode(.tail)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(InboxFriendlyDate.label(for: createdAt ?? receivedAt))
                    .font(.caption)
                    .foregroundStyle(palette.neutral.secondaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let scoreBadge {
                    Text(scoreBadge.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeTreatment?.capsuleTextColor ?? .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(badgeTreatment?.capsuleFillColor ?? .clear, in: Capsule())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityLabel(Text(scoreBadge.title))
                        .accessibilityIdentifier("new-message-area-priority-\(scoreBadge.rawValue)")
                }
            }
        }
        .padding(.leading, 16 + (selected ? InboxRowSelectionDecoration.contentInset : 0))
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.neutral.backgroundColor)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(selectionDecoration.barColor)
                    .frame(width: InboxRowSelectionDecoration.barWidth)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NewMessageAreaSurface.forScheme(colorScheme).separatorColor)
                .frame(height: 0.5)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
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

    private var badgeTreatment: NewMessageAreaPriorityTreatment? {
        .forLevel(scoreBadge, colorScheme: colorScheme)
    }

    private var selectionDecoration: InboxRowSelectionDecoration {
        .forLevel(nil, colorScheme: colorScheme)
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
            .font(.caption)
            .foregroundStyle(palette.neutral.secondaryTextColor)
            .tint(palette.neutral.secondaryTextColor)

            HStack(alignment: .top, spacing: 8) {
                Capsule()
                    .fill(palette.accent.color.opacity(0.55))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                Text(MessageMarkdown.preview(entry.newestUnseenReply?.text ?? "",
                                             characterLimit: 320))
                    .messageTextSize()
                    .foregroundStyle(palette.neutral.textColor)
                    .tint(palette.neutral.textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let receivedAt {
                    Text(InboxFriendlyDate.label(for: receivedAt))
                        .font(.caption)
                        .foregroundStyle(palette.neutral.secondaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if entry.unseenCount > 1 {
                    Text(String(localized: "\(entry.unseenCount) new"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.neutral.secondaryTextColor)
                        .lineLimit(1)
                        .accessibilityIdentifier("reply-item-unseen-count")
                }
                Spacer(minLength: 4)
                if let scoreBadge {
                    Text(scoreBadge.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeTreatment?.capsuleTextColor ?? .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(badgeTreatment?.capsuleFillColor ?? .clear, in: Capsule())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityLabel(Text(scoreBadge.title))
                        .accessibilityIdentifier("reply-item-priority-\(scoreBadge.rawValue)")
                }
            }
        }
        .padding(.leading, 16 + (selected ? InboxRowSelectionDecoration.contentInset : 0))
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.neutral.backgroundColor)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(selectionDecoration.barColor)
                    .frame(width: InboxRowSelectionDecoration.barWidth)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NewMessageAreaSurface.forScheme(colorScheme).separatorColor)
                .frame(height: 0.5)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
    }
}

struct InboxRowContent: View {
    let row: InboxRequestRow
    var selected = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.backgroundProminence) private var backgroundProminence
    @Environment(\.messageTextSize) private var messageTextSize
    @ScaledMetric(relativeTo: .title2) private var topTitlePointSize: CGFloat = 22
    @ScaledMetric(relativeTo: .headline) private var middleTitlePointSize: CGFloat = 17
    @ScaledMetric(relativeTo: .subheadline) private var lowTitlePointSize: CGFloat = 15

    private var palette: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private var typeTokens: HarklightDesignSource.MessageType {
        palette.messageType(row.resolvedMessageType)
    }

    private var showsSelectionFill: Bool {
        InboxSelectedRowTextRule.usesSelectionFillColors(
            selected: selected, backgroundProminence: backgroundProminence)
    }

    private var priorityTreatment: InboxPriorityRowTreatment? {
        guard !selected else { return nil }
        return .forLevel(InboxPriorityDisplay.forScore(row.inboxScore), colorScheme: colorScheme)
    }

    private var priorityMarkerLevel: InboxPriorityDisplay? {
        guard let level = InboxPriorityDisplay.forScore(row.inboxScore),
              level == .high || level == .urgent else { return nil }
        return level
    }

    private var primaryRowTextColor: Color {
        if showsSelectionFill { return typeTokens.textColor }
        return priorityTreatment?.primaryTextColor
            ?? (row.isResolved ? palette.neutral.secondaryTextColor : palette.neutral.textColor)
    }

    private var secondaryRowTextColor: Color {
        if showsSelectionFill { return typeTokens.secondaryTextColor }
        return priorityTreatment?.secondaryTextColor ?? palette.neutral.secondaryTextColor
    }

    private var leadingTitleAccessories: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if row.isRetracted {
                Text("Retracted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(primaryRowTextColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.neutral.separatorColor, in: Capsule())
                    .accessibilityIdentifier("inbox-retracted-pill")
            }
            Image(systemName: row.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(showsSelectionFill ? typeTokens.textColor
                                 : priorityTreatment?.primaryTextColor ?? typeTokens.listIconColor)
                .accessibilityHidden(true)
            if row.hasDeliveryWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(showsSelectionFill ? typeTokens.textColor
                                     : priorityTreatment?.primaryTextColor ?? .red)
                    .accessibilityLabel("Response not delivered")
                    .accessibilityIdentifier("inbox-response-delivery-warning")
            }
            if row.hasMessageLoadWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(showsSelectionFill ? typeTokens.textColor
                                     : priorityTreatment?.primaryTextColor ?? .red)
                    .accessibilityLabel("Message could not be loaded and was skipped")
                    .accessibilityIdentifier("inbox-message-load-warning")
            }
        }
    }

    @ViewBuilder
    private var titleTrailingStatus: some View {
        if let chatUnread = row.chatUnread {
            Image(systemName: chatUnread
                  ? "bubble.left.and.bubble.right.fill"
                  : "bubble.left.and.bubble.right")
                .font(.caption)
                .foregroundStyle(chatUnread
                                 ? (showsSelectionFill ? typeTokens.textColor
                                    : priorityTreatment?.primaryTextColor ?? palette.accent.color)
                                 : secondaryRowTextColor)
                .accessibilityLabel(chatUnread ? "Unread conversation" : "Conversation read")
        }
        if row.localSeenSelected || row.informationalSeenStatus == .confirmed {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondaryRowTextColor)
                .accessibilityLabel("Seen")
        }
    }

    @ViewBuilder
    private var priorityAndDueLine: some View {
        if priorityMarkerLevel != nil || row.duePhrase != nil {
            HStack(alignment: .top, spacing: 4) {
                if let level = priorityMarkerLevel {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "flag.fill")
                            .accessibilityHidden(true)
                        Text(level.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(titleColor)
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
                    .font(.caption2)
                    .foregroundStyle(secondaryRowTextColor)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(duePhrase.accessibilityLabel))
                    .accessibilityIdentifier("inbox-due-phrase")
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(displayInitials)
                    .font(.caption2.bold())
                    .frame(width: 24, height: 24)
                    .foregroundStyle(showsSelectionFill ? typeTokens.textColor
                                     : priorityTreatment?.primaryTextColor
                                        ?? palette.neutral.secondaryTextColor)
                    .background(priorityTreatment?.initialsFillColor
                                ?? palette.neutral.separatorColor, in: Circle())
                Text(verbatim: row.senderLabel).lineLimit(1)
                Spacer(minLength: 4)
                if let createdAt = row.createdAt {
                    Text(InboxFriendlyDate.label(for: createdAt))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(secondaryRowTextColor)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                leadingTitleAccessories
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(MessageMarkdown.attributed(row.title))
                            .font(titleFont)
                            .foregroundStyle(titleColor)
                            .tint(titleColor)
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
                            .messageTextSize()
                            .foregroundStyle(secondaryRowTextColor)
                            .tint(secondaryRowTextColor)
                            .lineLimit(row.tier.bodyLineLimit)
                            .truncationMode(.tail)
                    }
                    if let reason = row.orderingReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(secondaryRowTextColor)
                            .accessibilityIdentifier("inbox-ordering-reason")
                    }
                    if let defaultAnswerStatus = row.defaultAnswerStatus {
                        Text(defaultAnswerStatus).font(.caption2).foregroundStyle(secondaryRowTextColor)
                            .accessibilityIdentifier("inbox-default-answer-status")
                    } else if !row.isResolved && !row.visibleStatus.isEmpty {
                        Text(row.visibleStatus).font(.caption2).foregroundStyle(secondaryRowTextColor)
                    }
                    if let localStatus = row.localStatus {
                        Text(localStatus).font(.caption2).foregroundStyle(secondaryRowTextColor)
                    }
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.vertical, row.tier == .top ? 18 : 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let priorityTreatment {
                Rectangle().fill(priorityTreatment.backgroundStyle)
            }
        }
        .foregroundStyle(primaryRowTextColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.neutral.separatorColor)
                .frame(height: 0.5)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
    }

    private var titleFont: Font {
        switch row.tier {
        case .top:
            messageTextSize.font(basePointSize: topTitlePointSize, weight: .bold)
        case .middle:
            messageTextSize.font(basePointSize: middleTitlePointSize, weight: .semibold)
        case .low:
            messageTextSize.font(basePointSize: lowTitlePointSize, weight: .semibold)
        }
    }

    private var titleColor: Color {
        primaryRowTextColor
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

    private var neutralTokens: HarklightDesignSource.Neutral {
        HarklightDesignSystem.palette(for: colorScheme).neutral
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
                            .foregroundStyle(neutralTokens.secondaryTextColor)
                            .padding(.horizontal, 16).padding(.top, 8)
                        InboxRowContent(row: rows[index].1)
                            .accessibilityIdentifier("tier-reference-" + rows[index].1.key.messageID.rawValue)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(neutralTokens.backgroundColor)
            .foregroundStyle(neutralTokens.textColor)
            .navigationTitle("Cell tiers")
        }
        .background(neutralTokens.backgroundColor.ignoresSafeArea())
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
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") { dismiss() }.labelStyle(.iconOnly)
            } }
        }
    }
}

@MainActor
struct InboxDiagnosticsSettingsSection: View {
    let launch: NativeAppLaunch
    var isReadOnly = false
    var closeSettings: () -> Void = {}

    var body: some View {
        Section("Diagnostics") {
            if launch.diagnostics.hasEvents {
                ShareLink(item: launch.diagnostics.shareText) {
                    Label("Share diagnostics", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("client-diagnostics-share")
                Text("Shares retained client history without answers or credentials.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let diagnostic = launch.foregroundConnectDiagnostic {
                ShareLink(item: diagnostic.shareText) {
                    Label("Share connection details", systemImage: "waveform.path")
                }
                .accessibilityIdentifier("foreground-connect-diagnostics")
                Text("Includes the app build, observed connection phase and queued-operation receipt state. Answers and credentials are excluded.")
                    .font(.footnote).foregroundStyle(.secondary)
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

    private var priorityTreatment: InboxPriorityRowTreatment? {
        guard !selected else { return nil }
        return .forLevel(priority, colorScheme: colorScheme)
    }

    private var primaryTextColor: Color {
        priorityTreatment?.primaryTextColor ?? palette.neutral.textColor
    }

    private var secondaryTextColor: Color {
        priorityTreatment?.secondaryTextColor ?? palette.neutral.secondaryTextColor
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

    private var selectionDecoration: InboxRowSelectionDecoration {
        .forLevel(nil, colorScheme: colorScheme)
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
            .font(.caption)
            .foregroundStyle(secondaryTextColor)
            .tint(secondaryTextColor)

            HStack(alignment: .top, spacing: 8) {
                Capsule()
                    .fill(palette.accent.color.opacity(0.55))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                if let projection {
                    Text(MessageMarkdown.preview(projection.quotedReply.text.rawValue,
                                                 characterLimit: 480))
                        .messageTextSize()
                        .foregroundStyle(primaryTextColor)
                        .tint(primaryTextColor)
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
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let unseenCount = reference.unseenCount, unseenCount > 1 {
                    Text(String(localized: "\(unseenCount) new"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                        .accessibilityIdentifier("normal-reply-item-unseen-count")
                }
                Spacer(minLength: 4)
                if let priorityLabel {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "flag.fill")
                            .accessibilityHidden(true)
                        Text(priorityLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .accessibilityIdentifier("normal-reply-item-priority-\(priority?.rawValue ?? "none")")
                }
            }
        }
        .padding(.leading, 16 + (selected ? InboxRowSelectionDecoration.contentInset : 0))
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let priorityTreatment {
                Rectangle().fill(priorityTreatment.backgroundStyle)
            } else {
                palette.neutral.backgroundColor
            }
        }
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(selectionDecoration.barColor)
                    .frame(width: InboxRowSelectionDecoration.barWidth)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NewMessageAreaSurface.forScheme(colorScheme).separatorColor)
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Chat reply from \(senderLabel) about \(MessageMarkdown.visibleText(parentTitle))"))
    }
}
