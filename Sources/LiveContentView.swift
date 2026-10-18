import AttentionDomain
import SwiftUI
import UIKit

@MainActor
struct LiveContentView: View {
    let store: LivePresentationStore
    let samples: SampleLibrary
    let launch: NativeAppLaunch?
    let archiveDeparture: NativeAccountDeparture?

    init(store: LivePresentationStore,
         samples: SampleLibrary,
         launch: NativeAppLaunch? = nil,
         archiveDeparture: NativeAccountDeparture? = nil) {
        self.store = store
        self.samples = samples
        self.launch = launch
        self.archiveDeparture = archiveDeparture
    }

    var body: some View {
        let progress = launch?.foregroundConnectProgress
        let showsRecovery = !store.isReadOnly && (progress.map { $0.outcome != .confirmed } ?? false)
        let failureKey = launch?.foregroundConnectFailureKey
        let diagnostic = launch?.foregroundConnectDiagnostic
        let connectionStatus = showsRecovery ? progress?.headline : store.connectionWarning
        let presentsFailureDetails = !store.isReadOnly && diagnostic != nil &&
            (failureKey.map { launch?.shouldPresentForegroundConnectFailure($0) ?? false } ?? false)
        let failureAlertPresented = Binding<Bool>(
            get: { presentsFailureDetails },
            set: { isPresented in
                guard !isPresented, let launch, let failureKey else { return }
                launch.dismissForegroundConnectFailure(failureKey)
            })
        HarklightInbox(
            requests: store.inboxRows, samples: samples, selectRequest: { store.selectRequest($0) },
            requestDetail: { key, context in
                if let request = store.request(for: key) {
                    LiveRequestDetail(request: request, store: store, context: context)
                } else {
                    ContentUnavailableView("Request unavailable", systemImage: "questionmark.folder")
                }
            },
            settingsContent: { LiveInboxSettings(store: store, samples: samples, launch: launch,
                                                  archiveDeparture: archiveDeparture,
                                                  connectionStatus: connectionStatus) },
            warnings: [launch?.notificationNavigationMessage, store.observationError, store.notificationWarning,
                       store.pushRegistrationWarning, launch?.archiveCatalogWarning,
                       launch?.disconnectedAccount?.removed == true ? nil : launch?.disconnectMessage]
                .compactMap { $0 },
            conversationStore: store,
            showsLocalExamples: !store.isReadOnly,
            notificationNavigation: launch?.notificationNavigation)
        .alert("Connection needs attention", isPresented: failureAlertPresented,
               presenting: diagnostic) { diagnostic in
            Button("Copy details") {
                UIPasteboard.general.string = diagnostic.shareText
                if let launch, let failureKey {
                    launch.dismissForegroundConnectFailure(failureKey)
                }
            }
            Button("Dismiss", role: .cancel) {
                if let launch, let failureKey {
                    launch.dismissForegroundConnectFailure(failureKey)
                }
            }
        } message: { diagnostic in
            Text(diagnostic.progress.message)
        }
    }
}

@MainActor
struct LiveInboxSettings: View {
    let store: LivePresentationStore
    let samples: SampleLibrary
    let launch: NativeAppLaunch?
    let archiveDeparture: NativeAccountDeparture?
    let connectionStatus: String?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDisconnect = false
    @State private var confirmingEndpointMigration = false

    private var record: NativeEnrollmentRecord? {
        if store.isReadOnly { return archiveDeparture?.record ?? launch?.disconnectedAccount?.record }
        return launch?.activeEnrollmentRecord
    }

    private var pendingAnswerCount: Int {
        store.presentation.requests.filter { $0.lifecycleStatus == .pending }.count
    }

    private var editedDraftCount: Int {
        store.presentation.requests.filter { $0.draft.hasEdits }.count
    }

    private var disconnectDisclosure: String {
        let account = record?.accountDisplayName ?? "this account"
        let drafts = editedDraftCount == 0
            ? "Saved messages, drafts, receipts and local attachment copies stay on this phone."
            : "Saved messages, \(editedDraftCount) edited \(editedDraftCount == 1 ? "draft" : "drafts"), receipts and local attachment copies stay on this phone."
        let pending = pendingAnswerCount == 0
            ? nil
            : "Pending answers stop retrying; some may already have reached the server."
        return (["Disconnect this phone from \(account)?",
                 "Your account and other devices remain active, and server history stays.",
                 drafts,
                 "This phone stops sending and receiving through its current registration. You’ll need an invitation and normal approval to connect again.",
                 pending].compactMap { $0 }).joined(separator: " ")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let connectionStatus {
                    Section("Connection status") {
                        Text(connectionStatus).foregroundStyle(.secondary)
                    }
                }
                if let record {
                    Section("Account") {
                        LabeledContent("Account", value: record.accountDisplayName ?? "Current account")
                        LabeledContent("Server", value: record.serverDisplayName ?? record.host)
                    }
                }
                if let launch {
                    let otherArchives = launch.availableDisconnectedAccounts
                        .filter { $0.archiveID != archiveDeparture?.archiveID }
                    if !otherArchives.isEmpty {
                        Section("Saved accounts") {
                            ForEach(otherArchives, id: \.archiveID) { departure in
                                Button {
                                    launch.showArchivedAccount(departure)
                                    dismiss()
                                } label: {
                                    Label(departure.record.accountDisplayName ?? "Disconnected account",
                                          systemImage: "lock")
                                }
                                .accessibilityHint("Open this account’s saved messages and discussion read-only")
                            }
                        }
                    }
                }
                if store.isReadOnly {
                    Section("Connection") {
                        if let archiveDeparture {
                            Label("Disconnected · Read-only", systemImage: "lock")
                            Text("These saved messages, discussion history, drafts and local files belong to this account. They are read-only and are not shared with another account.")
                                .foregroundStyle(.secondary)
                            if launch?.activeEnrollmentRecord != nil {
                                Button("Return to current account") {
                                    launch?.showCurrentAccount()
                                    dismiss()
                                }
                            } else if launch?.selectedArchivedAccount != nil {
                                Button("Return to connection status") {
                                    launch?.leaveSelectedArchive()
                                    dismiss()
                                }
                            } else if archiveDeparture.removed {
                                Button("Connect with an invitation") {
                                    launch?.beginReconnect()
                                }
                            } else {
                                Button(launch?.isDisconnectBusy == true ? "Retrying removal…" : "Retry removal") {
                                    Task { await launch?.retryDisconnectRemoval() }
                                }
                                .disabled(launch?.isDisconnectBusy == true)
                            }
                        } else if let departure = launch?.disconnectedAccount, departure.replacement == nil {
                            Label(departure.removed ? "Disconnected" : "Removal not confirmed",
                                  systemImage: departure.removed ? "wifi.slash" : "exclamationmark.triangle")
                            Text(departure.removed
                                 ? "This phone is disconnected. Its saved messages and drafts are read-only. The account, other devices and server history remain."
                                 : (launch?.disconnectMessage ?? "This phone is disconnected locally. The server has not confirmed removal; the original account identity is kept for retry."))
                                .foregroundStyle(.secondary)
                            if departure.removed {
                                Button("Connect with an invitation") { launch?.beginReconnect() }
                            } else {
                                Button(launch?.isDisconnectBusy == true ? "Retrying removal…" : "Retry removal") {
                                    Task { await launch?.retryDisconnectRemoval() }
                                }
                                .disabled(launch?.isDisconnectBusy == true)
                            }
                        } else {
                            Label("Read-only saved messages", systemImage: "lock")
                            Text("These messages remain associated with their original account. Connect only with an invitation for that account to resume them.")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if launch != nil {
                    Section("Connection") {
                        Text("This phone is registered to this account.")
                            .foregroundStyle(.secondary)
                        if launch?.canMigrateDirectEndpointToGibson == true {
                            Button(launch?.isEndpointMigrationBusy == true ? "Checking Gibson…" : "Move connection to Gibson…") {
                                confirmingEndpointMigration = true
                            }
                            .disabled(launch?.isEndpointMigrationBusy == true)
                            .confirmationDialog("Move this connection?", isPresented: $confirmingEndpointMigration,
                                                titleVisibility: .visible) {
                                Button("Move connection to Gibson") {
                                    Task { await launch?.migrateDirectEndpointToGibson() }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Harklight will verify the confirmed server address before switching. Your approved account, device identity, trust certificate, messages and drafts stay on this phone. This does not unregister or enroll the device. If verification fails, the current connection remains active.")
                            }
                        }
                        if let message = launch?.endpointMigrationMessage {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Disconnect this phone…", role: .destructive) {
                            confirmingDisconnect = true
                        }
                        .disabled(launch?.isEndpointMigrationBusy == true)
                        .confirmationDialog("Disconnect this phone?", isPresented: $confirmingDisconnect,
                                            titleVisibility: .visible) {
                            Button("Disconnect this phone", role: .destructive) {
                                Task { await launch?.disconnectCurrentAccount() }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(disconnectDisclosure)
                        }
                        if let message = launch?.disconnectMessage {
                            Text(message).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
                if let launch,
                   launch.diagnostics.hasEvents || launch.foregroundConnectDiagnostic != nil {
                    InboxDiagnosticsSettingsSection(launch: launch, isReadOnly: store.isReadOnly,
                                                    closeSettings: { dismiss() })
                }
                if !store.isReadOnly {
                    Section("Local examples") {
                    Text("Shake to add fictional messages to your inbox. Their answers, chat and attachments stay on this device and disappear when the app closes.")
                    Button("Add example messages") { samples.populate(); dismiss() }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") { dismiss() }.labelStyle(.iconOnly)
            } }
        }
    }
}

struct LiveRequestDetail: View {
    let request: PresentedRequest
    let store: LivePresentationStore
    var context: InboxCardContext = .standalone
    @State private var deferred = false
    @State private var chatPresented = false

    var canAnswer: Bool {
        guard !store.isReadOnly, request.lifecycleStatus == .open,
              request.intentReceipt == nil else { return false }
        switch request.projection {
        case .sender: return true
        case let .compatibility(actions):
            if request.informationalSeenStatus != nil {
                return request.informationalSeenStatus == .available && actions.count == 1
            }
            return !actions.isEmpty
        case .unsupported: return false
        }
    }

    private var submitLabel: String {
        if case let .sender(sender) = request.projection { return sender.submissionLabel.rawValue }
        return "Send answer"
    }

    var body: some View {
        MessageCardSurface(context: context) {
            VStack(alignment: .leading, spacing: 22) {
                MessageHeading(sender: request.key.senderID.rawValue,
                               initials: String(request.key.senderID.rawValue.prefix(2)).uppercased(),
                               title: request.title?.rawValue ?? request.key.senderID.rawValue)
                if let thread = store.conversation(for: request.key), thread.currentRevision > 1 {
                    Text(store.hasAcceptedUpdate(for: request.key) ? "Updated · version \(thread.currentRevision)" : "Question version \(thread.currentRevision)")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("request-update-fact")
                }
                Text(store.isRetracted(request.key) ? "Retracted" : String(localized: LiveLifecycleTitle(request.lifecycleStatus).label))
                    .font(.caption).foregroundStyle(.secondary)
                if let seenStatus = request.informationalSeenStatus {
                    Label(Self.informationalSeenText(seenStatus),
                          systemImage: Self.informationalSeenSymbol(seenStatus))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("informational-seen-status")
                }
                if store.isRetracted(request.key) {
                    Text("The sender retracted this request. Saved work and its original delivery status are retained; no further answer will be sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if deferred {
                    HStack {
                        Label("Not now", systemImage: "clock")
                        Spacer()
                        Button("Undo") { deferred = false }
                    }.font(.subheadline)
                }
                if let body = request.body {
                    Text(body.rawValue)
                        .textSelection(.enabled)
                }
                switch request.projection {
                case let .sender(sender):
                    LiveProjectedSceneView(request: request,
                                           sender: sender,
                                           node: sender.scene,
                                           store: store,
                                           readOnly: !canAnswer)
                case let .compatibility(actions):
                    LiveCompatibilityActions(request: request,
                                             actions: actions,
                                             store: store,
                                             readOnly: !canAnswer)
                case .unsupported:
                    Text("This request uses an unsupported answer format.")
                        .foregroundStyle(.secondary)
                }
                if request.lifecycleStatus == .pending {
                    Button("Retry delivery") { store.retryPendingDelivery() }
                        .buttonStyle(.bordered)
                        .disabled(store.isReadOnly)
                }
                if let actionError = store.actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if let facts = request.receiptFacts {
                    Text(facts.evidenceLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("Request details") {
                    Text("Sender: \(request.key.senderID.rawValue)")
                    Text("Message: \(request.key.messageID.rawValue)")
                    Text(request.originalContentJSON)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    if let receipt = request.intentReceipt {
                        Text("Original answer")
                            .font(.headline)
                        Text(receipt.exactAnswerJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if request.informationalSeenStatus == nil {
                    Button(submitLabel, systemImage: "checkmark") { store.submitFromUser(request.key) }
                        .labelStyle(.iconOnly).disabled(!canAnswer)
                        .accessibilityIdentifier("request-finish")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Later", systemImage: "clock") { deferred.toggle() }.labelStyle(.iconOnly)
                    .disabled(store.isReadOnly)
                Spacer()
                Button("Chat", systemImage: "bubble.left.and.bubble.right") {
                    if context.canInlineChat { context.openChat?() } else { chatPresented = true }
                }
                    .labelStyle(.iconOnly)
                    .popover(isPresented: $chatPresented, arrowEdge: .bottom) {
                        NavigationStack {
                            ConversationPanel(store: store, key: request.key,
                                sender: request.key.senderID.rawValue, title: request.title?.rawValue ?? "")
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Close", systemImage: "xmark") { chatPresented = false }.labelStyle(.iconOnly)
                                    }
                                }
                        }
                        .frame(idealWidth: 380, idealHeight: 560)
                        .presentationCompactAdaptation(.sheet)
                        .presentationDetents([.medium, .large])
                    }
            }
        }
        .onChange(of: context.inlineChat) { _, inline in
            if inline { chatPresented = false }
        }
    }

    private static func informationalSeenText(_ status: InformationalSeenStatus) -> String {
        switch status {
        case .available: "Seen available"
        case .pending: "Seen pending confirmation"
        case .confirmed: "Seen confirmed"
        case .resolvedWithoutSeen: "Resolved without Seen confirmation"
        }
    }

    private static func informationalSeenSymbol(_ status: InformationalSeenStatus) -> String {
        switch status {
        case .available: "info.circle"
        case .pending: "clock"
        case .confirmed: "checkmark.circle.fill"
        case .resolvedWithoutSeen: "checkmark.circle"
        }
    }
}

@MainActor
struct HistoricalAnswerDraftView: View {
    let request: PresentedRequest
    let store: LivePresentationStore
    var retracted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title?.rawValue ?? "Earlier question").font(.headline)
            if let body = request.body { Text(body.rawValue).font(.caption) }
            Text(retracted ? "Saved answer · request retracted. Its original wording and choices are retained." : "Not delivered · this selection belongs to the earlier question")
                .font(.caption).foregroundStyle(.secondary)
            switch request.projection {
            case let .sender(sender):
                LiveProjectedSceneView(request: request, sender: sender, node: sender.scene, store: store, readOnly: true)
            case let .compatibility(actions):
                LiveCompatibilityActions(request: request, actions: actions, store: store, readOnly: true)
            case .unsupported:
                Text("This saved answer format cannot be displayed.").font(.caption)
            }
        }
    }
}

@MainActor
private struct LiveProjectedSceneView: View {
    let request: PresentedRequest
    let sender: AdmittedSenderProjection
    let node: ProjectedSceneNode
    let store: LivePresentationStore
    let readOnly: Bool

    var body: some View {
        switch node.kind {
        case let .stack(axis, children):
            if axis == .vertical {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(children) { child in childView(child) }
                }
            } else {
                FlowLayout(spacing: 12) {
                    ForEach(children) { child in childView(child) }
                }
            }
        case let .grid(columns, children):
            AdaptiveGridLayout(maxColumns: columns, minimumItemWidth: 150, spacing: 12) {
                ForEach(children) { child in childView(child) }
            }
        case let .text(value, style):
            SceneTextView(text: value.rawValue, style: style)
        case let .illustration(id):
            if let illustration = sender.illustrations.first(where: { $0.id == id }) {
                SenderIllustrationCanvas(illustration: illustration, point: nil)
                    .accessibilityHidden(false)
                    .accessibilityLabel(illustration.label.rawValue)
            }
        case let .input(id, layout):
            if let input = sender.inputs.first(where: { $0.id == id }) {
                LiveProjectedInputView(request: request,
                                       input: input,
                                       layout: layout,
                                       sender: sender,
                                       store: store,
                                       readOnly: readOnly)
            }
        case let .resultPoint(illustrationID, label, point):
            if let illustration = sender.illustrations.first(where: { $0.id == illustrationID }) {
                VStack(alignment: .leading, spacing: 8) {
                    SenderIllustrationCanvas(illustration: illustration, point: point)
                    Text(label.rawValue)
                        .font(.caption)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label.rawValue)
                .accessibilityValue("Horizontal \(point.x), vertical \(point.y)")
            }
        }
    }

    @ViewBuilder
    private func childView(_ child: ProjectedSceneNode) -> some View {
        LiveProjectedSceneView(request: request, sender: sender,
                               node: child, store: store, readOnly: readOnly)
    }
}

@MainActor
private struct LiveProjectedInputView: View {
    let request: PresentedRequest
    let input: ProjectedInput
    let layout: InputLayout
    let sender: AdmittedSenderProjection
    let store: LivePresentationStore
    let readOnly: Bool

    private var draft: InputDraft? {
        readOnly ? request.draft.inputs[input.id] : store.request(for: request.key)?.draft.inputs[input.id]
    }

    var body: some View {
        switch input.kind {
        case let .response(actions):
            VStack(alignment: .leading, spacing: 10) {
                Text(input.label.rawValue).font(.headline)
                VStack(spacing: 10) {
                    ForEach(actions, id: \.id) { action in actionButton(action) }
                }
                if let selected = draft?.selectedActionID,
                   let action = actions.first(where: { $0.id == selected }),
                   action.kind == .text {
                    TextEditor(text: Binding(
                        get: { draft?.textByActionID[selected]?.rawValue ?? "" },
                        set: { store.updateText($0, input: input.id, action: selected, for: request.key) }
                    ))
                    .frame(minHeight: 120)
                    .accessibilityLabel(action.label.rawValue)
                    .disabled(readOnly)
                }
            }
        case .text:
            VStack(alignment: .leading, spacing: 8) {
                Text(input.label.rawValue).font(.headline)
                TextEditor(text: Binding(
                    get: { draft?.text?.rawValue ?? "" },
                    set: { store.updateText($0, input: input.id, action: nil, for: request.key) }
                ))
                .frame(minHeight: 120)
                .accessibilityLabel(input.label.rawValue)
                .disabled(readOnly)
            }
        case let .point(illustrationID):
            if let illustration = sender.illustrations.first(where: { $0.id == illustrationID }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(input.label.rawValue).font(.headline)
                    SenderIllustrationCanvas(illustration: illustration,
                                             point: draft?.effectivePoint)
                    if let point = draft?.effectivePoint {
                        Text("Horizontal \(point.x), vertical \(point.y)")
                        Stepper("Horizontal position", value: pointBinding(horizontal: true), in: 0...1000)
                            .disabled(readOnly)
                        Stepper("Vertical position", value: pointBinding(horizontal: false), in: 0...1000)
                            .disabled(readOnly)
                    } else if !readOnly {
                        Button("Set point") {
                            store.setPoint(PointValue(x: 500, y: 500), input: input.id, for: request.key)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: ProjectedAction) -> some View {
        let selected = draft?.selectedActionID == action.id
        Button {
            store.selectAction(action.id, input: input.id, for: request.key)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if let artID = action.illustrationID,
                   let illustration = sender.illustrations.first(where: { $0.id == artID }) {
                    SenderIllustrationCanvas(illustration: illustration, point: nil)
                }
                MessageChoiceLabel(title: action.label.rawValue, detail: "",
                                   selected: selected, multiple: false, suggested: false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .disabled(readOnly)
    }

    private func pointBinding(horizontal: Bool) -> Binding<Int> {
        Binding(
            get: {
                let point = draft?.effectivePoint
                return horizontal ? (point?.x ?? 500) : (point?.y ?? 500)
            },
            set: { value in
                let current = store.request(for: request.key)?.draft.inputs[input.id]?.effectivePoint
                    ?? PointValue(x: 500, y: 500)
                store.setPoint(PointValue(x: horizontal ? value : current.x,
                                          y: horizontal ? current.y : value),
                               input: input.id, for: request.key)
            }
        )
    }
}

@MainActor
private struct LiveCompatibilityActions: View {
    let request: PresentedRequest
    let actions: [ProjectedAction]
    let store: LivePresentationStore
    let readOnly: Bool

    private var selected: ExactText? {
        readOnly ? request.draft.compatibility.selectedActionID : store.request(for: request.key)?.draft.compatibility.selectedActionID
    }

    @ViewBuilder
    var body: some View {
        if let seenStatus = request.informationalSeenStatus {
            switch seenStatus {
            case .available:
                if let action = actions.first {
                    Button {
                        store.submitFromUser(request.key, explicitCompatibilityAction: action.id)
                    } label: {
                        Label(action.label.rawValue, systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(readOnly)
                    .accessibilityIdentifier("request-seen-action")
                }
            case .pending:
                Label("Seen pending confirmation", systemImage: "clock")
            case .confirmed:
                Label("Seen confirmed", systemImage: "checkmark.circle.fill")
            case .resolvedWithoutSeen:
                Label("Resolved without Seen confirmation", systemImage: "checkmark.circle")
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(actions, id: \.id) { action in
                    Button {
                        store.selectAction(action.id, input: nil, for: request.key)
                    } label: {
                        MessageChoiceLabel(title: action.label.rawValue, detail: "",
                            selected: selected == action.id, multiple: false, suggested: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selected == action.id ? "Selected" : "Not selected")
                    .disabled(readOnly)
                }
                if let selected,
                   let action = actions.first(where: { $0.id == selected }),
                   action.kind == .text {
                    TextEditor(text: Binding(
                        get: { (readOnly ? request.draft.compatibility : store.request(for: request.key)?.draft.compatibility)?.textByActionID[selected]?.rawValue ?? "" },
                        set: { store.updateCompatibilityText($0, action: selected, for: request.key) }
                    ))
                    .frame(minHeight: 120)
                    .accessibilityLabel(action.label.rawValue)
                    .disabled(readOnly)
                }
            }
        }
    }
}

struct LiveLifecycleTitle {
    let label: LocalizedStringResource

    init(_ status: AppLifecycleStatus) {
        switch status {
        case .open: label = "Open"
        case .pending: label = "Pending"
        case .answered: label = "Answered"
        case .cleared: label = "Cleared"
        case .expired: label = "Expired"
        case .superseded: label = "Superseded"
        }
    }
}
