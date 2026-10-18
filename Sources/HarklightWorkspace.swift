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
        ViewThatFits {
            if large {
                VStack(spacing: 16) {
                    LighthouseMark().frame(width: 64, height: 78)
                    Text("Harklight").font(.largeTitle.bold())
                    Text("Select a message").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 9) {
                    LighthouseMark().frame(width: 24, height: 30)
                    Text("Harklight").font(.title.bold())
                }
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
    case unseen
    case seen
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
    var localSeenSelected = false
    var id: RequestKey { key }

    var belongsToSeenTab: Bool {
        if localSeenSelected { return true }
        switch informationalSeenStatus {
        case .some(.pending), .some(.confirmed): return true
        case .some(.available), .some(.resolvedWithoutSeen), .none: return false
        }
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
    @ViewBuilder let requestDetail: (RequestKey, InboxCardContext) -> RequestDetail
    @ViewBuilder let settingsContent: () -> SettingsContent
    var warnings: [String] = []
    var conversationStore: LivePresentationStore? = nil
    var showsLocalExamples = true
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: InboxSelection?
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var settings = false
    @State private var selectedTab: InboxMessageTab = .unseen
    @State private var lastViewedSelection: InboxSelection?
    @State private var navigatedBetweenMessages = false
    @State private var restoreLastViewedOnReturn = false
    @State private var chatOpen = false
    @State private var windowSize: CGSize = .zero

    private var rows: [InboxItem] {
        showsLocalExamples ? samples.inboxItems(appendingTo: requests) : requests.map { .request($0) }
    }
    private var orderedIDs: [InboxSelection] { rows.map(\.id) }

    private func preview(for id: InboxSelection) -> InboxCardPreview? {
        rows.first { $0.id == id }?.preview
    }

    private func navigate(to next: InboxSelection?) {
        let previous = selection
        guard previous != next else { return }
        let oldRequest: RequestKey? = if case let .request(key) = previous { key } else { nil }
        let newRequest: RequestKey? = if case let .request(key) = next { key } else { nil }
        conversationStore?.navigateMessage(from: oldRequest, to: newRequest)
        let oldExample: RequestKey? = if case let .sample(id) = previous { samples.responses[id]?.key } else { nil }
        let newExample: RequestKey? = if case let .sample(id) = next { samples.responses[id]?.key } else { nil }
        samples.fixture?.viewModel.navigateMessage(from: oldExample, to: newExample)
        selection = next
        if let next { lastViewedSelection = next }
        if let newRequest { selectRequest(newRequest) }
        if case let .sample(id) = next { samples.select(id) }
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

    private func restoreLastViewedListPosition() {
        guard navigatedBetweenMessages else {
            restoreLastViewedOnReturn = false
            return
        }
        navigatedBetweenMessages = false
        guard let lastViewedSelection,
              let lastViewedItem = rows.first(where: { $0.id == lastViewedSelection }) else {
            restoreLastViewedOnReturn = false
            return
        }
        selectedTab = lastViewedItem.belongsToSeenTab ? .seen : .unseen
        restoreLastViewedOnReturn = true
    }

    // SwiftUI writes this binding for its native compact Back navigation.
    // Our adaptive/programmatic changes write state directly, not this setter.
    private var compactNavigation: Binding<NavigationSplitViewColumn> {
        Binding(get: { compactColumn }, set: { column in
            if compactColumn == .detail, column == .sidebar,
               horizontalSizeClass == .compact {
                restoreLastViewedListPosition()
                navigate(to: nil)
            }
            compactColumn = column
        })
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

    var body: some View {
        GeometryReader { geometry in
            let landscape = windowSize.width > windowSize.height
            let wideChat = UIDevice.current.userInterfaceIdiom == .pad && geometry.size.width >= 820
            let inlineChat = wideChat && (landscape || chatOpen)
            NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: compactNavigation) {
                InboxList(rows: rows, selected: selection, selectedTab: $selectedTab,
                          lastViewedSelection: lastViewedSelection,
                          restoreLastViewed: restoreLastViewedOnReturn,
                          didRestoreLastViewed: { restoreLastViewedOnReturn = false },
                          showSettings: { settings = true }, markSeen: markSeen, select: { id in
                    navigatedBetweenMessages = selection != nil && selection != id
                    restoreLastViewedOnReturn = false
                    navigate(to: id)
                    compactColumn = .detail
                    if !landscape { visibility = .detailOnly }
                })
                .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 380)
            } detail: {
                HStack(spacing: 0) {
                    NavigationStack {
                        switch selection {
                        case let .request(key):
                            requestDetail(key, cardContext(for: .request(key), inlineChat: inlineChat,
                                canInlineChat: wideChat, openChat: { chatOpen.toggle() }))
                                .id(key)
                        case let .sample(id):
                            if showsLocalExamples,
                               samples.messages.contains(where: { $0.id == id }),
                               let response = samples.responses[id] {
                                SampleCardScreen(response: response,
                                    context: cardContext(for: .sample(id), inlineChat: inlineChat,
                                        canInlineChat: wideChat, openChat: { chatOpen.toggle() }))
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
            .onChange(of: samples.selectedID) { _, id in
                if showsLocalExamples, let id, case .sample = selection { selection = .sample(id) }
            }
            .onChange(of: showsLocalExamples) { _, visible in
                if !visible, case .sample = selection {
                    selection = nil
                    chatOpen = false
                }
            }
            .onChange(of: samples.messages.count) { _, _ in
                // Populate the existing list; never present a second navigation stack.
                visibility = .all
                compactColumn = .sidebar
            }
            .onChange(of: landscape) { _, isLandscape in
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
        }
        .background(WorkspaceWindowReader { windowSize = $0 })
        .sheet(isPresented: $settings, content: settingsContent)
        .tint(.blue)
    }
}

@MainActor
struct InboxList: View {
    let rows: [InboxItem]
    let selected: InboxSelection?
    @Binding var selectedTab: InboxMessageTab
    let lastViewedSelection: InboxSelection?
    let restoreLastViewed: Bool
    let didRestoreLastViewed: () -> Void
    let showSettings: () -> Void
    let markSeen: (InboxSelection) -> Void
    let select: (InboxSelection) -> Void
    @State private var search = ""
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool

    private var filteredRows: [InboxItem] {
        let inTab = rows.filter { $0.belongsToSeenTab == (selectedTab == .seen) }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return inTab }
        return inTab.filter {
            $0.preview.title.localizedCaseInsensitiveContains(query) ||
            $0.preview.sender.localizedCaseInsensitiveContains(query) ||
            $0.preview.body.localizedCaseInsensitiveContains(query)
        }
    }

    private func restoreLastViewed(using proxy: ScrollViewProxy) {
        guard restoreLastViewed else { return }
        guard let lastViewedSelection,
              rows.contains(where: { $0.id == lastViewedSelection }) else {
            didRestoreLastViewed()
            return
        }
        if !filteredRows.contains(where: { $0.id == lastViewedSelection }) {
            search = ""
            return
        }
        proxy.scrollTo(lastViewedSelection, anchor: .center)
        didRestoreLastViewed()
    }

    private func openSettings() {
        searchFocused = false
        showSettings()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredRows) { row in
                        Button {
                            searchFocused = false
                            select(row.id)
                        } label: {
                            switch row {
                            case let .request(request):
                                InboxRowContent(row: request, selected: selected == row.id)
                            case let .example(_, response):
                                if let request = response.inboxRow {
                                    InboxRowContent(row: request, selected: selected == row.id)
                                } else {
                                    EmptyView()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if row.canMarkSeen {
                                Button { markSeen(row.id) } label: {
                                    Label("Seen", systemImage: "checkmark")
                                }
                                .tint(.blue)
                                .accessibilityIdentifier("inbox-mark-seen")
                            }
                        }
                        .id(row.id)
                        .accessibilityIdentifier(row.accessibilityID)
                    }
                }
            }
            .background { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
            .swipeActionsContainer()
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                InboxBottomControls(selectedTab: $selectedTab, search: $search,
                    isSearchPresented: $searchPresented, searchFocused: $searchFocused,
                    showSettings: openSettings)
            }
            .onAppear { restoreLastViewed(using: proxy) }
            .onChange(of: restoreLastViewed) { _, shouldRestore in
                if shouldRestore { restoreLastViewed(using: proxy) }
            }
            .onChange(of: search) { _, _ in
                if restoreLastViewed { restoreLastViewed(using: proxy) }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { HarklightBrand() }
                ToolbarItem(placement: .primaryAction) {
                    if !searchPresented {
                        Button("Settings", systemImage: "gearshape", action: openSettings)
                            .labelStyle(.iconOnly).accessibilityIdentifier("inbox-settings")
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
            .navigationTitle("Harklight")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct InboxBottomControls: View {
    @Binding var selectedTab: InboxMessageTab
    @Binding var search: String
    @Binding var isSearchPresented: Bool
    @FocusState.Binding var searchFocused: Bool
    let showSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isSearchPresented {
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .glassEffect(.regular, in: Capsule())
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .accessibilityIdentifier("inbox-search-field")
                    .onSubmit { searchFocused = false }
                Button("Close search", systemImage: "xmark") {
                    searchFocused = false
                    search = ""
                    withAnimation(.snappy(duration: 0.28)) { isSearchPresented = false }
                }
                .labelStyle(.iconOnly)
                .frame(width: 46, height: 46)
                .glassEffect(.regular, in: Circle())
                .accessibilityIdentifier("inbox-search-dismiss")
                Button("Settings", systemImage: "gearshape", action: showSettings)
                    .labelStyle(.iconOnly)
                    .frame(width: 46, height: 46)
                    .glassEffect(.regular, in: Circle())
                    .accessibilityIdentifier("inbox-settings-search")
            } else {
                Picker("Message status", selection: $selectedTab) {
                    Label("Unseen", systemImage: "envelope.badge").tag(InboxMessageTab.unseen)
                    Label("Seen", systemImage: "envelope.open").tag(InboxMessageTab.seen)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .glassEffect(.regular, in: Capsule())
                .accessibilityIdentifier("inbox-message-tabs")
                Spacer(minLength: 8)
                Button("Search", systemImage: "magnifyingglass") {
                    withAnimation(.snappy(duration: 0.28)) { isSearchPresented = true }
                }
                .labelStyle(.iconOnly)
                .frame(width: 46, height: 46)
                .glassEffect(.regular, in: Circle())
                .accessibilityIdentifier("inbox-search-button")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .onChange(of: isSearchPresented) { _, isPresented in
            searchFocused = isPresented
        }
    }
}

struct InboxRowContent: View {
    let row: InboxRequestRow
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if row.isLocalExample {
                    Text(row.sender).font(.caption.weight(.medium))
                }
                if row.isLocalExample {
                    Text("Local example").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let createdAt = row.createdAt {
                    Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Label(row.title, systemImage: row.symbol).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let bodyText = row.bodyText, !bodyText.isEmpty {
                Text(bodyText).font(.subheadline).foregroundStyle(.secondary)
            }
            if !row.status.isEmpty { Text(row.status).font(.caption).foregroundStyle(.secondary) }
            if let localStatus = row.localStatus {
                Text(localStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.blue.opacity(0.055) : Color(uiColor: .systemBackground))
        .foregroundStyle(row.isResolved ? .secondary : .primary)
        .accessibilityElement(children: .combine)
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
