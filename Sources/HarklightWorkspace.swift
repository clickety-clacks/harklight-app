import SwiftUI
import UIKit
import AttentionDomain

enum InboxPriorityDisplay: Equatable {
    case urgent
    case high
    case low

    var title: LocalizedStringResource {
        switch self {
        case .urgent: "Urgent"
        case .high: "High priority"
        case .low: "Low priority"
        }
    }

    static func label(for priority: InboxMessagePriority) -> Self? {
        switch priority {
        case .now: .urgent
        case .high: .high
        case .low: .low
        case .normal: nil
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

struct SupersedesTarget: Hashable {
    let key: RequestKey
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

    init(route: NativeInboxNavigation, rows: [InboxItem]) {
        guard let key = route.request else {
            selection = nil
            selectedTab = .inbox
            workspaceTab = .inbox
            return
        }

        let selection = InboxSelection.request(key)
        let isReplied = rows.first(where: { $0.id == selection })?.belongsToReplied == true
        let messageTab: InboxMessageTab = isReplied ? .replied : .inbox
        self.selection = selection
        selectedTab = messageTab
        workspaceTab = isReplied ? .replied : .inbox
    }
}

private struct InboxListRowScrollTarget: Hashable {
    let tab: InboxWorkspaceTab
    let selection: InboxSelection
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
    var symbol: String = "text.bubble"
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
    var isRetracted = false
    var chatUnread: Bool? = nil
    var initials: String = ""
    var emphasis: InboxRowEmphasis = .standard
    var messageType: HarklightMessageType? = nil
    var tier: InboxAttentionTier = .middle
    var priority: InboxMessagePriority? = nil
    var thread: ExactText? = nil
    var hasInboxViewEntry = false
    var duePhrase: String? = nil
    var orderingReason: String? = nil
    var defaultAnswerStatus: String? = nil
    var id: RequestKey { key }

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
    var showsLocalExamples = false
    var notificationNavigation: NativeInboxNavigation? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: InboxSelection?
    @State private var supersedesNavigationPath: [SupersedesTarget] = []
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
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
    private var cardNavigationIDs: [InboxSelection] {
        // A Seen or answered card may leave this tab while it remains open.
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return orderedIDs
        }
        return InboxListProjection.filteredRows(rows, in: workspaceTab,
            search: search).map(\.id)
    }
    private var activeNotificationNavigation: NativeInboxNavigation? {
        notificationNavigation ?? testNotificationNavigation
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
        preferredCompactColumn = next == nil ? .sidebar : .detail
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

        let oldSampleID: String? = if case let .sample(id) = previous { id }
            else if previous == nil { samples.selectedID }
            else { nil }
        let newSampleID: String? = if case let .sample(id) = next { id } else { nil }

        if let next { lastViewedSelection = next }
        if let newRequest { selectRequest(newRequest) }
        samples.select(newSampleID, departingFrom: oldSampleID)
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
            "compactColumn=\(preferredCompactColumn) sizeClass=\(horizontalSizeClass.map { "\($0)" } ?? "nil") landscape=\(landscape)",
            "samples.selected=\(samples.selectedID ?? "nil") samples.lastViewed=\(samples.lastViewedID ?? "nil") loadError=\(samples.loadError ?? "nil")",
            "rows=\(rowSummary)",
            UIDiagnostics.shared.eventSummary,
        ].joined(separator: " | ")
    }

    private var navigationSelection: Binding<InboxSelection?> {
        Binding(get: { selection }, set: { next in
            navigate(to: next)
            if next != nil { preferredCompactColumn = .detail }
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
                    sender: key.senderID.rawValue, title: request.title?.rawValue ?? "")
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
        .navigationDestination(for: SupersedesTarget.self) { target in
            if conversationStore?.request(for: target.key) != nil {
                requestDetail(target.key, .supersedesTarget)
            } else {
                ContentUnavailableView("Message not available", systemImage: "questionmark.folder")
            }
        }
        .toolbar(horizontalSizeClass == .compact && item != nil ? .hidden : .automatic,
                 for: .tabBar)
    }

    private func inboxSplitView(for tab: InboxWorkspaceTab, inlineChat: Bool,
                                geometry: GeometryProxy) -> some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            InboxList(tab: tab, rows: rows, warnings: visibleWarnings,
                  showsBasicOrderMarker: showsBasicOrderMarker, isRefreshing: isRefreshing,
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
            NavigationStack(path: $supersedesNavigationPath) {
                detailContent(for: selection, inlineChat: inlineChat,
                              geometry: geometry)
            }
            .onChange(of: selection) { _, _ in
                supersedesNavigationPath.removeAll()
            }
        }
    }

    private func cardContext(for id: InboxSelection, inlineChat: Bool = false) -> InboxCardContext {
        let ids = cardNavigationIDs
        let index = ids.firstIndex(of: id)
        let hasPrevious = index.map { $0 > 0 } ?? false
        let hasNext = index.map { $0 + 1 < ids.count } ?? false
        return InboxCardContext(position: (index ?? 0) + 1, total: ids.count,
            hasPrevious: hasPrevious,
            hasNext: hasNext,
            inlineChat: inlineChat,
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
                let destination = InboxNotificationDestination(route: route, rows: rows)
                workspaceTab = destination.workspaceTab
                selectedTab = destination.selectedTab
                search = destination.search
                selection = destination.selection
                preferredCompactColumn = selection == nil ? .sidebar : .detail
                if let key = route.request {
                    lastViewedSelection = .request(key)
                    selectRequest(key)
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
                preferredCompactColumn = .detail
                lastViewedSelection = .sample(id)
            }
            .uiDiagnostics("inbox-ui-diagnostics", diagnosticSummary(landscape: landscape))
        }
        .sheet(isPresented: $settings, content: settingsContent)
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
    }
}

@MainActor
struct InboxList: View {
    let tab: InboxWorkspaceTab
    let rows: [InboxItem]
    let warnings: [String]
    var showsBasicOrderMarker = false
    var isRefreshing = false
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
    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }
    @Environment(\.colorScheme) private var colorScheme
    @State private var canRequestOlderPageOnDrag = false
    @State private var isUserScrolling = false
    @State private var requestedInGesture = false
    @State private var isFetchingOlderPage = false
    @State private var warningContentHeight: CGFloat = 0
    @State private var expandedThreadGroups: Set<InboxListEntryID> = []

    private var designPalette: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private func filteredRows(in tab: InboxWorkspaceTab) -> [InboxItem] {
        InboxListProjection.filteredRows(rows, in: tab, search: search)
    }

    private var tabMembershipIDs: Set<InboxSelection> {
        Set(rows.filter { $0.belongsToReplied == (tab.messageTab == .replied) }.map(\.id))
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
        guard let lastViewedSelection,
              rows.contains(where: { $0.id == lastViewedSelection }) else {
            didRestoreLastViewed()
            return
        }
        if !filteredRows(in: tab).contains(where: { $0.id == lastViewedSelection }) {
            UIDiagnostics.shared.record("list.restoreClearsSearch search=\(search) last=\(UIDiagnostics.describe(lastViewedSelection))")
            search = ""
            return
        }
        expandThreadContaining(lastViewedSelection, in: tab)
        proxy.scrollTo(InboxListRowScrollTarget(tab: tab, selection: lastViewedSelection), anchor: .center)
        didRestoreLastViewed()
    }

    /// When a filter shrinks the list while it is scrolled down, the lazy stack
    /// can keep its old visible range and draw none of the matching rows, so a
    /// filter change starts the list again at its first row.
    private func showFirstRow(using proxy: ScrollViewProxy, in tab: InboxWorkspaceTab) {
        guard let first = filteredRows(in: tab).first else { return }
        expandThreadContaining(first.id, in: tab)
        proxy.scrollTo(InboxListRowScrollTarget(tab: tab, selection: first.id), anchor: .top)
    }

    private func expandThreadContaining(_ selection: InboxSelection, in tab: InboxWorkspaceTab) {
        guard let group = InboxListProjection.visibleEntries(rows, in: tab, search: search)
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

    private var listSelection: Binding<InboxSelection?>? {
        $selected
    }

    @ViewBuilder
    private func rowContent(for row: InboxItem) -> some View {
        let isSelected = selected == row.id || lastViewedSelection == row.id
        switch row {
        case let .request(request):
            NavigationLink(value: row.id) {
                InboxRowContent(row: request, selected: isSelected)
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)
        case let .example(_, response):
            if let request = response.inboxRow {
                NavigationLink(value: row.id) {
                    InboxRowContent(row: request, selected: isSelected)
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
            }
        }
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
            .listRowBackground(Color.clear)
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
            Image(systemName: "bubble.left.and.bubble.right")
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
    private func listContent(for tab: InboxWorkspaceTab,
                             using proxy: ScrollViewProxy) -> some View {
        let visibleEntries = InboxListProjection.visibleEntries(rows, in: tab, search: search)
        List(selection: listSelection) {
            if tab == .inbox && showsBasicOrderMarker {
                Text("Basic order")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(designPalette.neutral.secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("inbox-basic-order")
            }
            ForEach(visibleEntries) { entry in
                switch entry {
                case let .row(row):
                    listRow(for: row, in: tab)
                case let .thread(_, members):
                    DisclosureGroup(isExpanded: threadExpansionBinding(for: entry.id)) {
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
            }
            if visibleEntries.isEmpty, let triggerNotification {
                Button("Open notification", action: triggerNotification)
                    .accessibilityIdentifier("harklight-test-notification")
            }
            if isFetchingOlderPage {
                ProgressView().frame(maxWidth: .infinity).padding()
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .animation(reduceMotion ? nil : .default, value: tabMembershipIDs)
        .scrollContentBackground(.hidden)
        .background { designPalette.neutral.backgroundColor.ignoresSafeArea() }
        .foregroundStyle(designPalette.neutral.textColor)
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $search, placement: .sidebar, prompt: "Search messages")
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
        }
        .onChange(of: workspaceTab) { _, activeTab in
            guard activeTab == tab else { return }
            if restoreLastViewed {
                restoreLastViewed(using: proxy, in: tab)
            } else {
                showFirstRow(using: proxy, in: tab)
            }
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
        .onScrollGeometryChange(for: InboxScrollMetrics.self) { geometry in
            let top = geometry.contentOffset.y + geometry.contentInsets.top
            let extent = max(0, geometry.contentSize.height - geometry.containerSize.height +
                geometry.contentInsets.top + geometry.contentInsets.bottom)
            return InboxScrollMetrics(offsetY: geometry.contentOffset.y,
                distanceToBottom: max(0, extent - top), contentFits: extent == 0)
        } action: { oldMetrics, newMetrics in
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
        .onScrollPhaseChange { oldPhase, newPhase in
            let scrolling = newPhase == .interacting || newPhase == .decelerating
            if scrolling && !isUserScrolling { requestedInGesture = false }
            if isUserScrolling != scrolling { isUserScrolling = scrolling }
            if oldPhase == .interacting && !scrolling { requestedInGesture = false }
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

    var body: some View {
        ScrollViewReader { proxy in
            listContent(for: tab, using: proxy)
                .uiDiagnostics("inbox-list-diagnostics", diagnosticSummary)
        }
    }
}

private struct InboxScrollMetrics: Equatable {
    let offsetY: CGFloat
    let distanceToBottom: CGFloat
    let contentFits: Bool
}

struct InboxRowContent: View {
    let row: InboxRequestRow
    var selected = false
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var palette: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private var typeTokens: HarklightDesignSource.MessageType {
        palette.messageType(row.resolvedMessageType)
    }

    private var cameBackBarWidth: CGFloat {
        horizontalSizeClass == .regular ? 10 : 6
    }

    private var cameBackBarRadius: CGFloat {
        horizontalSizeClass == .regular ? 8 : 6

    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(displayInitials)
                    .font(.caption2.bold())
                    .frame(width: 24, height: 24)
                    .background(palette.neutral.separatorColor, in: Circle())
                Text(verbatim: row.senderLabel).lineLimit(1)
                Spacer(minLength: 4)
                if let createdAt = row.createdAt {
                    Text(InboxFriendlyDate.label(for: createdAt))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(palette.neutral.secondaryTextColor)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if row.isRetracted {
                    Text("Retracted")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.neutral.textColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(palette.neutral.separatorColor, in: Capsule())
                        .accessibilityIdentifier("inbox-retracted-pill")
                }
                Image(systemName: row.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(typeTokens.listIconColor)
                    .accessibilityHidden(true)
                Text(row.title)
                    .font(titleFont)
                    .foregroundStyle(titleColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let priority = row.priority,
                   let priorityLabel = InboxPriorityDisplay.label(for: priority) {
                    Text(priorityLabel.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(priorityColor(for: priority))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(priorityColor(for: priority).opacity(0.14), in: Capsule())
                        .accessibilityLabel(Text(priorityLabel.title))
                        .accessibilityIdentifier("inbox-priority-\(priority.rawValue)")
                }
                if let chatUnread = row.chatUnread {
                    Image(systemName: chatUnread
                          ? "bubble.left.and.bubble.right.fill"
                          : "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(chatUnread ? palette.accent.color : palette.neutral.secondaryTextColor)
                        .accessibilityLabel(chatUnread ? "Unread conversation" : "Conversation read")
                }
                if row.localSeenSelected || row.informationalSeenStatus == .confirmed {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.neutral.secondaryTextColor)
                        .accessibilityLabel("Seen")
                }
            }
            if row.declaredMessageType != nil || row.declaredMessageKind != nil {
                MessageMetadataBadges(messageType: row.declaredMessageType,
                                      messageKind: row.declaredMessageKind)
            }
            if let bodyText = row.bodyText, !bodyText.isEmpty {
                Text(bodyText)
                    .font(.subheadline)
                    .foregroundStyle(palette.neutral.secondaryTextColor)
                    .lineLimit(row.tier.bodyLineLimit)
                    .truncationMode(.tail)
            }
            if let duePhrase = row.duePhrase {
                Text(duePhrase)
                    .font(.caption2)
                    .foregroundStyle(palette.neutral.secondaryTextColor)
                    .accessibilityIdentifier("inbox-due-phrase")
            }
            if let reason = row.orderingReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(palette.neutral.secondaryTextColor)
                    .accessibilityIdentifier("inbox-ordering-reason")
            }
            if let defaultAnswerStatus = row.defaultAnswerStatus {
                Text(defaultAnswerStatus).font(.caption2).foregroundStyle(palette.neutral.secondaryTextColor)
                    .accessibilityIdentifier("inbox-default-answer-status")
            } else if !row.isResolved && !row.status.isEmpty && row.status != "Open" {
                Text(row.status).font(.caption2).foregroundStyle(palette.neutral.secondaryTextColor)
            }
            if let localStatus = row.localStatus {
                Text(localStatus).font(.caption2).foregroundStyle(palette.neutral.secondaryTextColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, row.tier == .top ? 18 : 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.neutral.backgroundColor)
        .foregroundStyle(row.isResolved ? palette.neutral.secondaryTextColor : palette.neutral.textColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.neutral.separatorColor)
                .frame(height: 0.5)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            if selected {
                UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
                    topLeading: cameBackBarRadius, bottomLeading: cameBackBarRadius,
                    bottomTrailing: 0, topTrailing: 0))
                    .fill(typeTokens.cameBackBarColor)
                    .frame(width: cameBackBarWidth)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleFont: Font {
        switch row.tier {
        case .top: .title2.bold()
        case .middle: .headline
        case .low: .subheadline.weight(.semibold)
        }
    }

    private var titleColor: Color {
        row.isResolved ? palette.neutral.secondaryTextColor : palette.neutral.textColor
    }

    private func priorityColor(for priority: InboxMessagePriority) -> Color {
        switch priority {
        case .low: palette.neutral.secondaryTextColor
        case .normal: palette.accent.color
        case .high: .orange
        case .now: .red
        }
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
                            symbol: "text.bubble", createdAt: date(daysAgo),
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
            duePhrase: InboxDuePhrase.label(for: deadline),
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
