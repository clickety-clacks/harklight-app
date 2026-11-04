import SwiftUI
import AttentionDomain

/// Temporary isolated composition for measuring the production InboxList in a
/// real NavigationSplitView primary column. This view exists only in the UI-test
/// host; the shipped app keeps its normal adaptive column sizing.
@MainActor
struct InboxListColumnCaptureHost: View {
    @State private var isWarningPresented = false
    @State private var selected: InboxSelection?
    @State private var workspaceTab: InboxWorkspaceTab = .inbox
    @State private var search = ""
    @State private var newMessageAreaStore: NewMessageAreaStore
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
        let fixture = InboxListColumnCaptureFixture.make(for: state)
        rows = fixture.rows.map(InboxItem.request)
        _selected = State(initialValue: fixture.selected)
        _newMessageAreaStore = State(initialValue: fixture.newMessageAreaStore)
    }

    var body: some View {
        NavigationSplitView {
            productionInboxList
                .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 250)
        } detail: {
            Text("Select a message")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var productionInboxList: some View {
        InboxList(
            tab: .inbox,
            rows: rows,
            warnings: [],
            newMessageAreaStore: newMessageAreaStore,
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
                    .accessibilityLabel(
                        "Inbox list column width: \(Int(geometry.size.width.rounded())) points")
                    .accessibilityIdentifier("priority-capture-list-column-width")
            }
        }
    }
}

@MainActor
private enum InboxListColumnCaptureFixture {
    enum State: String {
        case selectedPlain
        case selectedHigh
        case unselectedComparison
        case acceptedNewMessage
    }

    struct Contents {
        let rows: [InboxRequestRow]
        let selected: InboxSelection?
        let newMessageAreaStore: NewMessageAreaStore
    }

    static func make(for state: State) -> Contents {
        let accountScope = ExactText("selected-row-visual-fixture")
        let plainRow = row("visual-plain", "Review the weekly notes", score: 0.48,
                           accountScope: accountScope)
        let highRow = row("visual-high", "Review the collection plan?", score: 0.82,
                          accountScope: accountScope,
                          duePhrase: .init(dayLine: "Due tomorrow", timeLine: "at 9:00 AM",
                                           accessibilityLabel: "Due tomorrow at 9:00 AM"))
        let unselectedRow = row("visual-unselected", "Prepare the next review", score: 0.52,
                                accountScope: accountScope)
        let newMessageRow = row("visual-new", "A newly received project update", score: 0.52,
                                accountScope: accountScope,
                                bodyText: "A local synthetic request shown in the accepted new-message area.")

        let suiteName = "com.example.attentionclient.duo-prototype.uitesthost.capture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("The isolated inbox capture fixture could not create its local defaults suite.")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = NewMessageAreaStore(defaults: defaults,
                                        defaultsKey: "selected-row-capture-new-message-area")
        let now = Date()
        store.reconcile([], revisions: [:], accountScopes: [accountScope], now: now)
        if state == .acceptedNewMessage {
            store.reconcile([
                NewMessageAreaMessage(key: newMessageRow.key, acceptanceOrder: 1,
                                      isResolved: false, hasSubmittedAnswer: false)
            ], revisions: [newMessageRow.key: newMessageRow.requestRevision],
               accountScopes: [accountScope], now: now)
        }

        let rows: [InboxRequestRow]
        let selected: InboxSelection?
        switch state {
        case .selectedPlain:
            rows = [plainRow, unselectedRow]
            selected = .request(plainRow.key)
        case .selectedHigh:
            rows = [highRow, unselectedRow]
            selected = .request(highRow.key)
        case .unselectedComparison:
            rows = [plainRow, unselectedRow]
            selected = .request(plainRow.key)
        case .acceptedNewMessage:
            rows = [newMessageRow]
            selected = nil
        }

        return Contents(rows: rows, selected: selected,
                        newMessageAreaStore: store)
    }

    private static func row(_ messageID: String, _ title: String, score: Double,
                            accountScope: ExactText, bodyText: String? = nil,
                            duePhrase: InboxDuePhrase.Presentation? = nil) -> InboxRequestRow {
        let sender = "Local visual fixture"
        return InboxRequestRow(
            key: RequestKey(accountScope: accountScope, senderID: ExactText(sender),
                            messageID: ExactText(messageID)),
            title: title,
            sender: sender,
            status: "",
            bodyText: bodyText,
            symbol: "envelope",
            initials: "LV",
            tier: .middle,
            inboxScore: score,
            duePhrase: duePhrase
        )
    }
}
