import SwiftUI
import UIKit
import AttentionDomain

/// A hosting-controller ancestor receives motion events without replacing the
/// text field's responder. No global window hooks or live-store mutations.
struct ShakeHostingView<Content: View>: UIViewControllerRepresentable {
    let onShake: () -> Void
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> ShakeHostingController<Content> {
        ShakeHostingController(rootView: content(), onShake: onShake)
    }

    func updateUIViewController(_ controller: ShakeHostingController<Content>, context: Context) {
        controller.rootView = content()
        controller.onShake = onShake
    }
}

final class ShakeHostingController<Content: View>: UIHostingController<Content> {
    var onShake: () -> Void
    init(rootView: Content, onShake: @escaping () -> Void) {
        self.onShake = onShake
        super.init(rootView: rootView)
    }
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("Use init(rootView:onShake:)") }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake() } else { super.motionEnded(motion, with: event) }
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
                    Text("Harklight").font(.largeTitle.bold())
                    Text("Select a message").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 20) {
                    LighthouseMark().frame(width: 24, height: 30)
                    Text("Harklight").font(.title.bold())
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .foregroundStyle(.primary)
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

enum InboxMessageTab: String, Hashable {
    case inbox
    case replied
}

struct InboxRequestRow: Identifiable {
    let key: RequestKey
    let title: String
    let sender: String
    let status: String
    var bodyText: String? = nil
    var symbol: String = "text.bubble"
    var isResolved = false
    var createdAt: Date? = nil
    var isLocalExample = false
    var localStatus: String? = nil
    var informationalSeenStatus: InformationalSeenStatus? = nil
    var canMarkSeen = false
    var canNoComment = false
    var noCommentUnavailable = false
    var localSeenSelected = false
    var hasUserAction = false
    var chatUnread: Bool? = nil
    var initials: String = ""
    var emphasis: InboxRowEmphasis = .standard
    var tier: InboxAttentionTier = .middle
    var id: RequestKey { key }

    var belongsToReplied: Bool {
        hasUserAction || localSeenSelected || informationalSeenStatus == .pending ||
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
    let samples: SampleLibrary
    let selectRequest: (RequestKey) -> Void
    var markSeenRequest: (RequestKey) -> Void = { _ in }
    var markNoCommentRequest: (RequestKey) -> Void = { _ in }
    @ViewBuilder let requestDetail: (RequestKey, InboxCardContext) -> RequestDetail
    @ViewBuilder let settingsContent: () -> SettingsContent
    var warnings: [String] = []
    var conversationStore: LivePresentationStore? = nil
    var fetchOlderInboxPage: (() async -> Bool)? = nil
    var showsLocalExamples = true
    var notificationNavigation: NativeInboxNavigation? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: InboxSelection?
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var settings = false
    @State private var selectedTab: InboxMessageTab = .inbox
    @State private var listTabOnMessageEntry: InboxMessageTab?
    @State private var lastViewedSelection: InboxSelection?
    @State private var navigatedBetweenMessages = false
    @State private var restoreLastViewedOnReturn = false
    @State private var chatOpen = false
    @State private var conversationPresented = false
    @State private var windowSize: CGSize = .zero

    private var rows: [InboxItem] {
        showsLocalExamples ? samples.inboxItems(appendingTo: requests) : requests.map { .request($0) }
    }
    private var orderedIDs: [InboxSelection] { rows.map(\.id) }

    private func preview(for id: InboxSelection) -> InboxCardPreview? {
        rows.first { $0.id == id }?.preview
    }

    private func currentItem(for selection: InboxSelection) -> InboxItem? {
        if case let .request(key) = selection,
           let request = conversationStore?.inboxRows.first(where: { $0.key == key }) {
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
        if let next {
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
            chatOpen = false
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
            guard rows.first(where: { $0.id == id })?.canMarkSeen == true else { return }
            markSeenRequest(key)
        case let .sample(sampleID):
            guard let response = samples.responses[sampleID], response.canMarkSeenLocally else { return }
            response.finishLocally()
        }
    }

    private func markNoComment(_ id: InboxSelection) {
        switch id {
        case let .request(key):
            guard rows.first(where: { $0.id == id })?.canNoComment == true else { return }
            markNoCommentRequest(key)
        case let .sample(sampleID):
            guard let response = samples.responses[sampleID], response.canDeclineLocally else { return }
            response.declineLocally()
        }
    }

    private func restoreLastViewedListPosition() {
        let lastViewedItem = lastViewedSelection.flatMap(currentItem(for:))
        guard navigatedBetweenMessages else {
            if let lastViewedItem {
                selectedTab = lastViewedItem.belongsToReplied ? .replied : .inbox
            } else if let listTabOnMessageEntry {
                selectedTab = listTabOnMessageEntry
            }
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
        selectedTab = lastViewedItem.belongsToReplied ? .replied : .inbox
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
            "betweenMessages=\(navigatedBetweenMessages) restoreOnReturn=\(restoreLastViewedOnReturn) chatOpen=\(chatOpen) sheet=\(conversationPresented)",
            "visibility=\(visibility) sizeClass=\(horizontalSizeClass.map { "\($0)" } ?? "nil") window=\(Int(windowSize.width))x\(Int(windowSize.height)) landscape=\(landscape)",
            "samples.selected=\(samples.selectedID ?? "nil") samples.lastViewed=\(samples.lastViewedID ?? "nil") loadError=\(samples.loadError ?? "nil")",
            "rows=\(rowSummary)",
            UIDiagnostics.shared.eventSummary,
        ].joined(separator: " | ")
    }

    private var navigationSelection: Binding<InboxSelection?> {
        Binding(get: { selection }, set: { navigate(to: $0) })
    }

    private func cardContext(for id: InboxSelection, inlineChat: Bool = false,
                             canInlineChat: Bool = false, openChat: (() -> Void)? = nil) -> InboxCardContext {
        let ids = orderedIDs
        let index = ids.firstIndex(of: id) ?? 0
        return InboxCardContext(position: index + 1, total: ids.count,
            previous: index > 0 ? preview(for: ids[index - 1]) : nil,
            next: index + 1 < ids.count ? preview(for: ids[index + 1]) : nil,
            inlineChat: inlineChat, canInlineChat: canInlineChat, openChat: openChat) { direction in
                // Resolve against today's list; the displayed identity stays stable on refresh.
                guard let current = orderedIDs.firstIndex(of: id),
                      orderedIDs.indices.contains(current + direction) else { return }
                let next = orderedIDs[current + direction]
                navigatedBetweenMessages = true
                navigate(to: next)
            }
    }

    @ViewBuilder
    private var conversationPresentation: some View {
        NavigationStack {
            Group {
                switch selection {
                case let .request(key):
                    if let conversationStore,
                       let request = conversationStore.request(for: key) {
                        ConversationPanel(store: conversationStore, key: key,
                                          sender: key.senderID.rawValue,
                                          title: request.title?.rawValue ?? "")
                    } else {
                        ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left.and.bubble.right")
                    }
                case let .sample(id):
                    if let message = samples.messages.first(where: { $0.id == id }),
                       let response = samples.responses[id] {
                        ConversationPanel(store: response.viewModel, key: response.key,
                                          sender: message.sender, title: message.title)
                            .onAppear { response.chatRead = true }
                    } else {
                        ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left.and.bubble.right")
                    }
                case nil:
                    ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { conversationPresented = false }
                        .labelStyle(.iconOnly)
                }
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = windowSize.width > windowSize.height
            let wideChat = UIDevice.current.userInterfaceIdiom == .pad && geometry.size.width >= 820
            let inlineChat = wideChat && (landscape || chatOpen)
            NavigationSplitView(columnVisibility: $visibility) {
                InboxList(rows: rows, selected: navigationSelection, selectedTab: $selectedTab,
                          lastViewedSelection: lastViewedSelection,
                          restoreLastViewed: restoreLastViewedOnReturn,
                          didRestoreLastViewed: { restoreLastViewedOnReturn = false },
                          showSettings: { settings = true }, markSeen: markSeen,
                          markNoComment: markNoComment,
                          fetchOlderInboxPage: fetchOlderInboxPage,
                          notificationNavigation: notificationNavigation)
                .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 380)
            } detail: {
                    HStack(spacing: 0) {
                        Group {
                            switch selection {
                            case let .request(key):
                                requestDetail(key, cardContext(for: .request(key), inlineChat: inlineChat,
                                    canInlineChat: wideChat, openChat: {
                                        if wideChat { chatOpen.toggle() }
                                        else { conversationPresented = true }
                                    }))
                                    .id(key)
                            case let .sample(id):
                                if showsLocalExamples,
                                   samples.messages.contains(where: { $0.id == id }),
                                   let response = samples.responses[id] {
                                    SampleCardScreen(response: response,
                                        context: cardContext(for: .sample(id), inlineChat: inlineChat,
                                            canInlineChat: wideChat, openChat: {
                                                if wideChat { chatOpen.toggle() }
                                                else { conversationPresented = true }
                                            }))
                                        .id(id)
                                }
                            case nil:
                                HarklightBrand(large: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background { Color(uiColor: .systemBackground).ignoresSafeArea() }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    if inlineChat, case let .request(key) = selection, let conversationStore,
                       let request = conversationStore.request(for: key) {
                        Divider()
                        ConversationPanel(store: conversationStore, key: key,
                            sender: key.senderID.rawValue, title: request.title?.rawValue ?? "")
                            .frame(width: min(360, geometry.size.width * 0.34))
                    }
                    if inlineChat, case let .sample(id) = selection,
                       let message = samples.messages.first(where: { $0.id == id }),
                       let response = samples.responses[id] {
                        Divider()
                        SampleChatView(sender: message.sender, title: message.title, response: response)
                            .frame(width: min(360, geometry.size.width * 0.34))
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .sheet(isPresented: $conversationPresented) {
                conversationPresentation
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: notificationNavigation, initial: true) { _, route in
                guard let route else { return }
                settings = false
                chatOpen = false
                conversationPresented = false
                // Notification navigation changes selection only. The ordinary
                // navigate helper also schedules abandoned-upload cleanup.
                // A tap must not turn that into a domain mutation.
                selection = route.request.map(InboxSelection.request)
                if let key = route.request {
                    lastViewedSelection = .request(key)
                    selectRequest(key)
                }
                visibility = route.request == nil ? .all : .detailOnly
            }
            .onChange(of: samples.selectedID) { _, id in
                UIDiagnostics.shared.record("inbox.samplesSelectedChanged \(id ?? "nil") selection=\(UIDiagnostics.describe(selection))")
                guard showsLocalExamples, case .sample = selection else { return }
                navigate(to: id.map { .sample($0) })
            }
            .onChange(of: showsLocalExamples) { _, visible in
                if !visible, case .sample = selection {
                    navigate(to: nil)
                    chatOpen = false
                }
            }
            .onAppear {
                UIDiagnostics.shared.record("inbox.appear selection=\(UIDiagnostics.describe(selection)) samples.selected=\(samples.selectedID ?? "nil")")
                guard showsLocalExamples, selection == nil,
                      let id = samples.selectedID, samples.responses[id] != nil else { return }
                selection = .sample(id)
                lastViewedSelection = .sample(id)
            }
            .onChange(of: samples.messages.count) { _, _ in
                // Populate the existing list; never present a second navigation stack.
                visibility = .all
            }
            .onChange(of: landscape) { _, isLandscape in
                UIDiagnostics.shared.record("inbox.landscape \(isLandscape) selection=\(UIDiagnostics.describe(selection))")
                visibility = isLandscape || selection == nil ? .all : .detailOnly
            }
            .safeAreaBar(edge: .top) {
                if !(warnings + [samples.loadError].compactMap { $0 }).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(warnings + [samples.loadError].compactMap { $0 }, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                        }
                    }.padding(8)
                }
            }
            .uiDiagnostics("inbox-ui-diagnostics", diagnosticSummary(landscape: landscape))
        }
        .background(WorkspaceWindowReader { windowSize = $0 })
        .sheet(isPresented: $settings, content: settingsContent)
        .tint(.blue)
    }
}

@MainActor
struct InboxList: View {
    let rows: [InboxItem]
    @Binding var selected: InboxSelection?
    @Binding var selectedTab: InboxMessageTab
    let lastViewedSelection: InboxSelection?
    let restoreLastViewed: Bool
    let didRestoreLastViewed: () -> Void
    let showSettings: () -> Void
    let markSeen: (InboxSelection) -> Void
    let markNoComment: (InboxSelection) -> Void
    let fetchOlderInboxPage: (() async -> Bool)?
    let notificationNavigation: NativeInboxNavigation?
    @State private var search = ""
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    @State private var scrollMetrics = InboxScrollMetrics.empty
    @State private var isUserScrolling = false
    @State private var requestedInGesture = false
    @State private var isFetchingOlderPage = false

    private var filteredRows: [InboxItem] {
        let inTab = rows.filter { $0.belongsToReplied == (selectedTab == .replied) }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return inTab }
        let filtered = inTab.filter {
            $0.preview.title.localizedCaseInsensitiveContains(query) ||
            $0.preview.sender.localizedCaseInsensitiveContains(query) ||
            $0.preview.body.localizedCaseInsensitiveContains(query)
        }
        return filtered
    }

    private func restoreLastViewed(using proxy: ScrollViewProxy) {
        guard restoreLastViewed else { return }
        guard let lastViewedSelection,
              rows.contains(where: { $0.id == lastViewedSelection }) else {
            didRestoreLastViewed()
            return
        }
        if !filteredRows.contains(where: { $0.id == lastViewedSelection }) {
            UIDiagnostics.shared.record("list.restoreClearsSearch search=\(search) last=\(UIDiagnostics.describe(lastViewedSelection))")
            search = ""
            return
        }
        proxy.scrollTo(lastViewedSelection, anchor: .center)
        didRestoreLastViewed()
    }

    /// When a filter shrinks the list while it is scrolled down, the lazy stack
    /// can keep its old visible range and draw none of the matching rows, so a
    /// filter change starts the list again at its first row.
    private func showFirstRow(using proxy: ScrollViewProxy) {
        guard let first = filteredRows.first else { return }
        proxy.scrollTo(first.id, anchor: .top)
    }

    private func openSettings() {
        searchFocused = false
        showSettings()
    }

    private var diagnosticSummary: String {
        let inTab = rows.filter { $0.belongsToReplied == (selectedTab == .replied) }
        let filtered = filteredRows.map { row -> String in
            let missingRow: Bool = if case let .example(_, response) = row { response.inboxRow == nil } else { false }
            return row.accessibilityID + (missingRow ? ":empty" : "")
        }
        return [
            "search=\(search) presented=\(searchPresented) focused=\(searchFocused) tab=\(selectedTab.rawValue)",
            "restoreLastViewed=\(restoreLastViewed) lastViewed=\(UIDiagnostics.describe(lastViewedSelection)) selected=\(UIDiagnostics.describe(selected))",
            "rows=\(rows.count) inTab=\(inTab.count) filtered=\(filtered)",
        ].joined(separator: " | ")
    }

    private func requestOlderPage() {
        guard !requestedInGesture, !isFetchingOlderPage,
              let fetchOlderInboxPage else { return }
        requestedInGesture = true
        isFetchingOlderPage = true
        Task {
            _ = await fetchOlderInboxPage()
            isFetchingOlderPage = false
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selected) {
                ForEach(filteredRows) { row in
                    Group {
                        switch row {
                        case let .request(request):
                            InboxRowContent(row: request,
                                            selected: selected == row.id || lastViewedSelection == row.id)
                        case let .example(_, response):
                            if let request = response.inboxRow {
                                InboxRowContent(row: request,
                                                selected: selected == row.id || lastViewedSelection == row.id)
                            } else {
                                EmptyView()
                            }
                        }
                    }
                    .tag(row.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if row.canMarkSeen {
                            Button { markSeen(row.id) } label: {
                                Label("Seen", systemImage: "checkmark")
                            }
                            .tint(.blue)
                            .accessibilityIdentifier("inbox-mark-seen")
                        } else if row.canNoComment {
                            Button { markNoComment(row.id) } label: {
                                Label("No comment", systemImage: "bubble.left")
                            }
                            .tint(.gray)
                            .disabled(row.noCommentUnavailable)
                            .accessibilityIdentifier("inbox-no-comment")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if row.canMarkSeen {
                            Button { markSeen(row.id) } label: {
                                Label("Seen", systemImage: "checkmark")
                            }
                            .tint(.blue)
                            .accessibilityIdentifier("inbox-mark-seen")
                        } else if row.canNoComment {
                            Button { markNoComment(row.id) } label: {
                                Label("No comment", systemImage: "bubble.left")
                            }
                            .tint(.gray)
                            .disabled(row.noCommentUnavailable)
                            .accessibilityIdentifier("inbox-no-comment")
                        }
                    }
                    .id(row.id)
                    .accessibilityIdentifier(row.accessibilityID)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                if isFetchingOlderPage {
                    ProgressView().frame(maxWidth: .infinity).padding()
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { Color(uiColor: .systemBackground).ignoresSafeArea() }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                InboxBottomControls(selectedTab: $selectedTab, search: $search,
                    isSearchPresented: $searchPresented, searchFocused: $searchFocused)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    HarklightBrand()
                    Spacer(minLength: 16)
                    Button("Settings", systemImage: "gearshape", action: openSettings)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("inbox-settings")
                }
                .frame(height: 52)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(uiColor: .systemBackground))
            }
            .onAppear { restoreLastViewed(using: proxy) }
            .onChange(of: restoreLastViewed) { _, shouldRestore in
                if shouldRestore { restoreLastViewed(using: proxy) }
            }
            .onChange(of: notificationNavigation) { _, route in
                guard route != nil else { return }
                search = ""
                searchFocused = false
            }
            .onChange(of: selected) { _, _ in searchFocused = false }
            .onChange(of: search) { _, _ in
                if restoreLastViewed { restoreLastViewed(using: proxy) } else { showFirstRow(using: proxy) }
            }
            .onChange(of: selectedTab) { _, _ in
                if !restoreLastViewed { showFirstRow(using: proxy) }
            }
            .onScrollGeometryChange(for: InboxScrollMetrics.self) { geometry in
                let top = geometry.contentOffset.y + geometry.contentInsets.top
                let extent = max(0, geometry.contentSize.height - geometry.containerSize.height +
                    geometry.contentInsets.top + geometry.contentInsets.bottom)
                return InboxScrollMetrics(offsetY: geometry.contentOffset.y,
                    distanceToBottom: max(0, extent - top), contentFits: extent == 0)
            } action: { oldMetrics, newMetrics in
                scrollMetrics = newMetrics
                guard isUserScrolling,
                      newMetrics.offsetY > oldMetrics.offsetY + 1,
                      newMetrics.distanceToBottom <= 80 else { return }
                requestOlderPage()
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                let scrolling = newPhase == .interacting || newPhase == .decelerating
                if scrolling && !isUserScrolling { requestedInGesture = false }
                isUserScrolling = scrolling
                if oldPhase == .interacting && !scrolling { requestedInGesture = false }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard value.translation.height < -12 else { return }
                    isUserScrolling = true
                    if scrollMetrics.contentFits || scrollMetrics.distanceToBottom <= 80 {
                        requestOlderPage()
                    }
                }
                .onEnded { _ in
                    isUserScrolling = false
                    requestedInGesture = false
                })
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .bottomBar)
            .uiDiagnostics("inbox-list-diagnostics", diagnosticSummary)
        }
    }
}

struct InboxBottomControls: View {
    @Binding var selectedTab: InboxMessageTab
    @Binding var search: String
    @Binding var isSearchPresented: Bool
    @FocusState.Binding var searchFocused: Bool
    @Namespace private var glassNamespace
    private let controlHeight: CGFloat = 56

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if isSearchPresented {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.primary)
                        TextField("Search", text: $search)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .accessibilityIdentifier("inbox-search-field")
                            .onSubmit { searchFocused = false }
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: controlHeight)
                    .background(.thickMaterial, in: Capsule())
                    .glassEffect(.regular, in: Capsule())
                    .glassEffectID("search", in: glassNamespace)
                    Button("Close search", systemImage: "xmark") {
                        searchFocused = false
                        search = ""
                        withAnimation(.smooth(duration: 0.35)) { isSearchPresented = false }
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: controlHeight, height: controlHeight)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityIdentifier("inbox-search-dismiss")
                } else {
                    HStack(spacing: 0) {
                        tab(.inbox, symbol: "envelope.badge", label: "Inbox")
                        tab(.replied, symbol: "envelope.open", label: "Replied")
                    }
                    .frame(height: controlHeight)
                    .glassEffect(.regular, in: Capsule())
                    Spacer(minLength: 8)
                    Button("Search", systemImage: "magnifyingglass") {
                        withAnimation(.smooth(duration: 0.35)) { isSearchPresented = true }
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: controlHeight, height: controlHeight)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .glassEffectID("search", in: glassNamespace)
                    .accessibilityIdentifier("inbox-search-button")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onChange(of: isSearchPresented) { _, isPresented in
            searchFocused = isPresented
        }
    }

    private func tab(_ tab: InboxMessageTab, symbol: String, label: String) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { selectedTab = tab }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
                .foregroundStyle(selectedTab == tab ? .blue : .primary)
                .frame(width: 68, height: 48)
                .background {
                    if selectedTab == tab {
                        Capsule().fill(.primary.opacity(0.08))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
        .accessibilityIdentifier("inbox-tab-" + tab.rawValue)
    }
}

private struct InboxScrollMetrics: Equatable {
    let offsetY: CGFloat
    let distanceToBottom: CGFloat
    let contentFits: Bool

    static let empty = InboxScrollMetrics(offsetY: 0, distanceToBottom: .greatestFiniteMagnitude,
                                          contentFits: false)
}

struct InboxRowContent: View {
    let row: InboxRequestRow
    var selected = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(displayInitials)
                    .font(.caption2.bold())
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
                Text(InboxSenderDisplay.name(for: row.sender)).lineLimit(1)
                Spacer(minLength: 4)
                if let createdAt = row.createdAt {
                    Text(InboxFriendlyDate.label(for: createdAt))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: row.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
                Text(row.title)
                    .font(titleFont)
                    .foregroundStyle(titleColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let chatUnread = row.chatUnread {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(chatUnread ? .blue : .secondary)
                        .accessibilityLabel(chatUnread ? "Unread conversation" : "Conversation read")
                }
                if row.localSeenSelected || row.informationalSeenStatus == .confirmed {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Seen")
                }
            }
            if let bodyText = row.bodyText, !bodyText.isEmpty {
                Text(bodyText)
                    .font(.subheadline)
                    .foregroundStyle(row.isResolved ? Color(uiColor: .tertiaryLabel) : .secondary)
                    .lineLimit(row.tier.bodyLineLimit)
                    .truncationMode(.tail)
            }
            if !row.isResolved && !row.status.isEmpty && row.status != "Open" {
                Text(row.status).font(.caption2).foregroundStyle(.secondary)
            }
            if let localStatus = row.localStatus {
                Text(localStatus).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, row.tier == .top ? 18 : 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .foregroundStyle(row.isResolved ? .secondary : .primary)
        .accessibilityElement(children: .combine)
    }

    private var backgroundColor: Color {
        if selected {
            return colorScheme == .dark
                ? Color(red: 0.12, green: 0.22, blue: 0.34)
                : Color(red: 0.894, green: 0.933, blue: 0.988)
        }
        if row.tier == .top {
            return colorScheme == .dark
                ? Color(uiColor: .secondarySystemBackground)
                : Color(red: 0.933, green: 0.941, blue: 0.957)
        }
        return Color(uiColor: .systemBackground)
    }

    private var titleFont: Font {
        switch row.tier {
        case .top: .title2.bold()
        case .middle: .headline
        case .low: .subheadline.weight(.semibold)
        }
    }

    private var titleColor: Color {
        if row.isResolved { return .secondary }
        return switch row.emphasis {
        case .error: Color(red: 0.70, green: 0, blue: 0.06)
        case .warning: Color(red: 0.48, green: 0.30, blue: 0)
        case .completed: .secondary
        case .standard: .primary
        }
    }

    private var displayInitials: String {
        if !row.initials.isEmpty { return row.initials }
        let words = InboxSenderDisplay.name(for: row.sender)
            .split(whereSeparator: { !$0.isLetter })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    private var symbolColor: Color {
        if row.isResolved { return .secondary }
        return switch row.emphasis {
        case .error: .red
        case .warning: .orange
        case .completed: .green
        case .standard: .secondary
        }
    }
}

/// Explicit presentation fixtures for screenshot verification of every tier,
/// independent of the tiers supplied by incoming messages.
struct InboxTierReferenceScreen: View {
    private let longBody = "The first version is ready to review. It preserves the original notes, keeps the work available to the team, and leaves room for another pass. Please compare the details carefully before choosing the next step. The remaining information continues beyond this preview so the list can stay easy to scan. The shared folder still contains the alternate sketches, the comments from the last review, and the proposed timeline. None of those items will be discarded by opening this message. The full request explains the choices and their effects before you answer."

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
        return [
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
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.top, 8)
                        InboxRowContent(row: rows[index].1)
                            .accessibilityIdentifier("tier-reference-" + rows[index].1.key.messageID.rawValue)
                    }
                }
            }
            .navigationTitle("Cell tiers")
        }
    }
}

struct InboxSettings: View {
    let samples: SampleLibrary
    var launch: NativeAppLaunch? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if let launch,
                   launch.diagnostics.hasEvents || launch.foregroundConnectDiagnostic != nil {
                    InboxDiagnosticsSettingsSection(launch: launch, closeSettings: { dismiss() })
                }
                LocalExamplesSettingsSection(samples: samples, close: { dismiss() })
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

@MainActor
private struct LocalExamplesSettingsSection: View {
    let samples: SampleLibrary
    let close: () -> Void

    var body: some View {
        Section("Local examples") {
            Text("Shake to add fictional messages to your inbox. Their answers, chat and attachments stay on this device and disappear when the app closes.")
            Button("Add example messages") {
                samples.populate()
                close()
            }
        }
    }
}
