import SwiftUI
import AttentionDomain

/// Temporary isolated composition for measuring the production InboxList in a
/// real NavigationSplitView primary column. This view exists only in the UI-test
/// host; the shipped app keeps its normal adaptive column sizing.
@MainActor
struct InboxListColumnCaptureHost: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isWarningPresented = false
    @State private var selected: InboxSelection?
    @State private var workspaceTab: InboxWorkspaceTab = .inbox
    @State private var search = ""
    @State private var newMessageAreaStore: NewMessageAreaStore
    @State private var replyItemAreaStore: ReplyItemAreaStore?
    private let captureState: InboxListColumnCaptureFixture.State
    private let sampleFixture: SampleFixtureDomain
    private let rows: [InboxItem]

    init() {
        let argument = ProcessInfo.processInfo.arguments.first {
            $0.hasPrefix("--harklight-test-inbox-list-state=")
        }
        let state = argument?.split(separator: "=", maxSplits: 1).last
            .flatMap { InboxListColumnCaptureFixture.State(rawValue: String($0)) }
        guard let state else {
            preconditionFailure("The isolated inbox capture host needs a known row state.")
        }
        let sampleFixture: SampleFixtureDomain
        do {
            let fixture = try SampleFixtureDomain()
            try fixture.populate()
            sampleFixture = fixture
        } catch {
            preconditionFailure("The isolated inbox capture host could not load its local request: \(error)")
        }
        captureState = state
        self.sampleFixture = sampleFixture
        let fixture = InboxListColumnCaptureFixture.make(for: state, sampleFixture: sampleFixture)
        rows = fixture.rows.map(InboxItem.request)
        _selected = State(initialValue: fixture.selected)
        _newMessageAreaStore = State(initialValue: fixture.newMessageAreaStore)
        _replyItemAreaStore = State(initialValue: fixture.replyItemAreaStore)
    }

    @ViewBuilder
    var body: some View {
        if captureState == .fullWidthHigh || captureState == .replyItemFullWidth {
            NavigationStack {
                productionInboxList
                    .navigationDestination(for: InboxSelection.self) { selection in
                        selectedDetail(for: selection)
                    }
            }
            .tint(HarklightDesignSystem.palette(for: colorScheme).accent.color)
            .overlay(alignment: .topLeading) { accessibilityProbe }
        } else {
            NavigationSplitView {
                productionInboxList
                    .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 250)
            } detail: {
                NavigationStack {
                    selectedDetail(for: selected)
                }
            }
            .navigationSplitViewStyle(.balanced)
            .tint(HarklightDesignSystem.palette(for: colorScheme).accent.color)
            .overlay(alignment: .topLeading) { accessibilityProbe }
        }
    }

    @ViewBuilder
    private func selectedDetail(for selection: InboxSelection?) -> some View {
        if let selection,
           case let .request(key) = selection,
           let row = rows.compactMap({ item -> InboxRequestRow? in
               guard case let .request(row) = item else { return nil }
               return row
           }).first(where: { $0.key == key }),
           let request = sampleFixture.viewModel.request(for: key) {
            LiveRequestDetail(
                request: request,
                store: sampleFixture.viewModel,
                context: InboxCardContext(position: 1, total: 1,
                                          hasPrevious: false, hasNext: false,
                                          messageType: row.resolvedMessageType,
                                          move: { _ in })
            )
            .id(key)
        } else {
            Text("Select a message")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    HarklightDesignSystem.palette(for: colorScheme)
                        .messageType(.request).backgroundColor
                        .ignoresSafeArea()
                }
        }
    }

    private var selectionProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Capture selection"))
            .accessibilityValue(Text(verbatim: selectionProbeValue))
            .accessibilityIdentifier("priority-capture-selection")
            .allowsHitTesting(false)
    }

    private var markdownFirstSeenProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Markdown row first seen"))
            .accessibilityValue(Text(verbatim: markdownFirstSeenValue))
            .accessibilityIdentifier("markdown-row-first-seen")
            .allowsHitTesting(false)
    }

    private var markdownReplyFirstSeenProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Markdown reply first seen"))
            .accessibilityValue(Text(verbatim: markdownReplyFirstSeenValue))
            .accessibilityIdentifier("markdown-reply-first-seen")
            .allowsHitTesting(false)
    }

    private var accessibilityProbe: some View {
        VStack(spacing: 0) {
            selectionProbe
            if captureState == .markdown {
                markdownFirstSeenProbe
                markdownReplyFirstSeenProbe
            }
        }
    }

    private var markdownFirstSeenValue: String {
        guard let row = rows.compactMap({ item -> InboxRequestRow? in
            guard case let .request(row) = item,
                  row.key.messageID.rawValue == "sample-markdown-acceptance" else { return nil }
            return row
        }).first,
              let entry = newMessageAreaStore.entries.first(where: { $0.key == row.key }) else {
            return "missing"
        }
        return entry.firstSeenAt.map { String($0.timeIntervalSince1970) } ?? "unseen"
    }

    private var markdownReplyFirstSeenValue: String {
        guard let row = rows.compactMap({ item -> InboxRequestRow? in
            guard case let .request(row) = item,
                  row.key.messageID.rawValue == "sample-markdown-acceptance" else { return nil }
            return row
        }).first,
              let entry = replyItemAreaStore?.entries.first(where: { $0.parent == row.key }) else {
            return "missing"
        }
        return entry.firstSeenAt.map { String($0.timeIntervalSince1970) } ?? "unseen"
    }

    private var selectionProbeValue: String {
        guard let selected else { return "none" }
        switch selected {
        case let .request(key): return key.messageID.rawValue
        case let .sample(id): return "sample:\(id)"
        case let .notificationPending(serial): return "notification-pending:\(serial)"
        }
    }

    private var productionInboxList: some View {
        InboxList(
            tab: .inbox,
            rows: rows,
            warnings: [],
            conversationStore: sampleFixture.viewModel,
            newMessageAreaStore: newMessageAreaStore,
            replyItemAreaStore: replyItemAreaStore,
            openReplyItem: { _, _, _ in },
            isWarningPresented: $isWarningPresented,
            selected: $selected,
            workspaceTab: $workspaceTab,
            search: $search,
            lastViewedSelection: nil,
            restoreLastViewed: false,
            didRestoreLastViewed: {},
            showSettings: {},
            markSeen: { _ in },
            markNoComment: { _ in },
            clearRetracted: { _ in },
            fetchOlderInboxPage: nil,
            notificationNavigation: nil,
            triggerNotification: nil
        )
        .background {
            GeometryReader { geometry in
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "Inbox list column width"))
                    .accessibilityValue(Text(verbatim: String(Int(geometry.size.width.rounded()))))
                    .accessibilityIdentifier("priority-capture-list-column-width")
            }
        }
    }
}

@MainActor
private enum InboxListColumnCaptureFixture {
    enum State: String {
        case selectedHigh
        case selectedPlainAndUnselectedComparison
        case acceptedNewMessage
        case actionableNewMessage
        case markdown
        case fullWidthHigh
        case replyItem
        case replyItemFullWidth
    }

    struct Contents {
        let rows: [InboxRequestRow]
        let selected: InboxSelection?
        let newMessageAreaStore: NewMessageAreaStore
        let replyItemAreaStore: ReplyItemAreaStore?
    }

    static func make(for state: State, sampleFixture: SampleFixtureDomain) -> Contents {
        let plainRow = row("sample-approval-0", sampleFixture: sampleFixture)
        let highRow = row("sample-approval-0", score: 0.82,
                          duePhrase: .init(dayLine: "Due tomorrow", timeLine: "at 9:00 AM",
                                           accessibilityLabel: "Due tomorrow at 9:00 AM"),
                          sampleFixture: sampleFixture)
        let unselectedRow = row("sample-textChoice-0", sampleFixture: sampleFixture)
        let newMessageRow = row("sample-information-0", sampleFixture: sampleFixture)
        let markdownRow = state == .markdown
            ? row("sample-markdown-acceptance", sampleFixture: sampleFixture)
            : nil

        let suiteName = "com.example.attentionclient.duo-prototype.uitesthost.capture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("The isolated inbox capture fixture could not create its local defaults suite.")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = NewMessageAreaStore(defaults: defaults,
                                        defaultsKey: "selected-row-capture-new-message-area")
        let now = Date()
        let isReplyState = state == .replyItem || state == .replyItemFullWidth || state == .markdown
        var scopedRows = [plainRow, highRow, unselectedRow, newMessageRow]
        if let markdownRow { scopedRows.append(markdownRow) }
        let accountScopes = Set(scopedRows.map(\.key.accountScope))
        store.reconcile([], revisions: [:], accountScopes: accountScopes, now: now.addingTimeInterval(-120))
        if state == .markdown, let markdownRow {
            store.reconcile([
                NewMessageAreaMessage(key: markdownRow.key, acceptanceOrder: 1,
                                      isResolved: false, hasSubmittedAnswer: false)
            ], revisions: [markdownRow.key: markdownRow.requestRevision],
               accountScopes: accountScopes, now: now.addingTimeInterval(-60))
        } else if state == .actionableNewMessage {
            // Use the sample's actual local No comment eligibility so swipe
            // tests compare the same actionable request in both placements.
            store.reconcile([
                NewMessageAreaMessage(key: plainRow.key, acceptanceOrder: 1,
                                      isResolved: false, hasSubmittedAnswer: false)
            ], revisions: [plainRow.key: plainRow.requestRevision],
               accountScopes: accountScopes, now: now.addingTimeInterval(-60))
        } else if state == .acceptedNewMessage || isReplyState {
            store.reconcile([
                NewMessageAreaMessage(key: newMessageRow.key, acceptanceOrder: 1,
                                      isResolved: false, hasSubmittedAnswer: false)
            ], revisions: [newMessageRow.key: newMessageRow.requestRevision],
               accountScopes: accountScopes, now: now.addingTimeInterval(-60))
        }

        var replyItemAreaStore: ReplyItemAreaStore?
        var replyParentRow = state == .markdown ? (markdownRow ?? newMessageRow) : newMessageRow
        if isReplyState {
            replyParentRow.inboxReplyScores = [5: 0.93, 6: 0.4]
            let replyStore = ReplyItemAreaStore(defaults: defaults,
                                                defaultsKey: "capture-reply-item-area")
            replyStore.reconcile([], accountScopes: accountScopes, now: now.addingTimeInterval(-120))
            let observations: [ReplyItemObservation]
            if state == .markdown,
               let thread = sampleFixture.viewModel.conversation(for: replyParentRow.key),
               let reply = thread.turns.first(where: {
                   $0.id == ExactText("markdown-reply-item") &&
                       $0.author == .origin && $0.kind == .reply
               }) {
                observations = [ReplyItemObservation(
                    parent: replyParentRow.key,
                    turnID: reply.id,
                    conversationSequence: reply.conversationSequence,
                    isSeen: false,
                    text: reply.text.rawValue)]
            } else {
                observations = [
                    ReplyItemObservation(parent: replyParentRow.key,
                                         turnID: ExactText("capture-reply-earliest"),
                                         conversationSequence: 5, isSeen: false,
                                         text: "Earliest unseen chat reply: the middle section of the draft now reads better."),
                    ReplyItemObservation(parent: replyParentRow.key,
                                         turnID: ExactText("capture-reply-newest"),
                                         conversationSequence: 6, isSeen: false,
                                         text: "Newest unseen chat reply: the revised draft tightens the opening, keeps the middle section's new ordering, and closes with the shorter summary we discussed, so the whole note should now fit on one screen.")
                ]
            }
            replyStore.reconcile(observations, accountScopes: accountScopes, now: now)
            replyItemAreaStore = replyStore
        }

        let rows: [InboxRequestRow]
        let selected: InboxSelection?
        switch state {
        case .selectedHigh:
            rows = [highRow, unselectedRow]
            selected = nil
        case .selectedPlainAndUnselectedComparison:
            rows = [plainRow, unselectedRow]
            selected = nil
        case .acceptedNewMessage:
            rows = [newMessageRow]
            selected = nil
        case .actionableNewMessage:
            rows = [plainRow]
            selected = nil
        case .markdown:
            guard let markdownRow else {
                preconditionFailure("The Markdown capture state needs its test-only sample message.")
            }
            rows = [replyParentRow]
            selected = nil
        case .fullWidthHigh:
            rows = [highRow, unselectedRow]
            selected = nil
        case .replyItem, .replyItemFullWidth:
            rows = [replyParentRow]
            selected = nil
        }

        return Contents(rows: rows, selected: selected,
                        newMessageAreaStore: store,
                        replyItemAreaStore: replyItemAreaStore)
    }

    private static func row(_ messageID: String,
                            score: Double? = nil,
                            duePhrase: InboxDuePhrase.Presentation? = nil,
                            sampleFixture: SampleFixtureDomain) -> InboxRequestRow {
        guard let message = SampleCatalog.messages.first(where: { $0.id == messageID }) else {
            preconditionFailure("The local request fixture is missing \(messageID).")
        }
        let key = sampleFixture.key(for: message)
        let response = SampleResponse(viewModel: sampleFixture.viewModel, key: key, message: message)
        guard var row = response.inboxRow else {
            preconditionFailure("The local request fixture did not produce \(messageID).")
        }
        row.inboxScore = score
        row.duePhrase = duePhrase
        return row
    }
}
