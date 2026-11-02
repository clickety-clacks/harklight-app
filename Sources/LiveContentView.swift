import AttentionDomain
import Observation
import SwiftUI
import UIKit

struct SeenActionPresentation: Equatable {
    let status: InformationalSeenStatus

    var isPending: Bool { status == .pending }
    var isCompleted: Bool { status == .confirmed }

    var title: LocalizedStringResource {
        switch status {
        case .pending: "Pending"
        case .confirmed: "Seen"
        case .available, .resolvedWithoutSeen: "Seen"
        }
    }

    var symbolName: String {
        switch status {
        case .pending: "clock"
        case .confirmed: "checkmark"
        case .available, .resolvedWithoutSeen: "checkmark"
        }
    }

    var accessibilityLabel: LocalizedStringResource {
        switch status {
        case .pending: "Seen pending confirmation"
        case .confirmed: "Seen with green checkmark"
        case .available, .resolvedWithoutSeen: "Mark as seen"
        }
    }

    var accessibilityValue: LocalizedStringResource {
        switch status {
        case .pending: "Pending"
        case .confirmed: "Completed"
        case .available, .resolvedWithoutSeen: "Available"
        }
    }
}

/// True while a reply editor below has keyboard focus. The foreground connection
/// alert defers while this is set, because presenting over the editor resigns
/// first responder mid-typing.
struct ReplyEditorFocusKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct ReplyEditorTarget: Hashable {
    let inputID: String?
    let actionID: String
    var isInputText: Bool = false

    var actionIdentifier: String { actionID }

    var fieldIdentifier: String {
        if let inputID { "request-input-\(inputID)-response" }
        else { "request-compatibility-\(actionID)-response" }
    }

    var summaryIdentifier: String {
        if let inputID { "request-input-\(inputID)-reply-\(actionID)" }
        else { "request-compatibility-reply-\(actionID)" }
    }

    var editorCardIdentifier: String { "\(fieldIdentifier)-card" }
}

@MainActor
@Observable
final class ReplyEditorDraftSession {
    let requestKey: RequestKey
    private(set) var requestRevision: UInt64
    private(set) var canSubmitFromSnapshot: Bool
    private(set) var draft: RequestDraft
    private(set) var noCommentSelected: Bool
    private(set) var hasLocalChanges = false

    init(request: PresentedRequest, canSubmitFromSnapshot: Bool) {
        requestKey = request.key
        requestRevision = request.requestRevision
        self.canSubmitFromSnapshot = canSubmitFromSnapshot
        let initialDraft = Self.initialDraft(for: request)
        draft = initialDraft
        noCommentSelected = initialDraft.noCommentSelected
    }

    func updateText(_ text: String, target: ReplyEditorTarget) {
        var updated = draft
        updated.noCommentSelected = false
        if let inputID = target.inputID {
            let input = ExactText(inputID)
            if target.isInputText {
                updated.inputs[input]?.text = ExactText(text)
            } else {
                updated.inputs[input]?.textByActionID[ExactText(target.actionID)] = ExactText(text)
            }
        } else {
            updated.compatibility.textByActionID[ExactText(target.actionID)] = ExactText(text)
        }
        store(updated)
    }

    func selectAction(_ actionID: ExactText, inputID: ExactText?) {
        var updated = draft
        updated.noCommentSelected = false
        if let inputID {
            updated.inputs[inputID]?.selectedActionID = actionID
        } else {
            updated.compatibility.selectedActionID = actionID
        }
        store(updated)
    }

    func setPoint(_ point: PointValue, inputID: ExactText) {
        var updated = draft
        updated.noCommentSelected = false
        updated.inputs[inputID]?.point = point
        updated.inputs[inputID]?.horizontalText = ExactText(String(point.x))
        updated.inputs[inputID]?.verticalText = ExactText(String(point.y))
        store(updated)
    }

    func selectNoComment() {
        var updated = draft
        updated.noCommentSelected = true
        updated.compatibility.selectedActionID = nil
        for inputID in Array(updated.inputs.keys) {
            updated.inputs[inputID]?.selectedActionID = nil
        }
        store(updated)
    }

    func adoptUneditedRequest(_ request: PresentedRequest, canSubmit: Bool) {
        guard request.key == requestKey, !hasLocalChanges else { return }
        requestRevision = request.requestRevision
        canSubmitFromSnapshot = canSubmit
        draft = Self.initialDraft(for: request)
        noCommentSelected = draft.noCommentSelected
    }

    private func store(_ updated: RequestDraft) {
        draft = updated
        if noCommentSelected != updated.noCommentSelected {
            noCommentSelected = updated.noCommentSelected
        }
        hasLocalChanges = true
    }

    private static func initialDraft(for request: PresentedRequest) -> RequestDraft {
        var inputs: [ExactText: InputDraft] = [:]
        if case let .sender(sender) = request.projection {
            for input in sender.inputs {
                switch input.kind {
                case .text:
                    inputs[input.id] = InputDraft(text: ExactText(""))
                case .response(_), .point(_):
                    inputs[input.id] = InputDraft()
                }
            }
        }
        return RequestDraft(inputs: inputs)
    }
}

private enum ReplyInputSurfaceStyle {
    static func fill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black.opacity(0.10) : Color.white.opacity(0.10)
    }

    static let darkPlaceholder = Color.white.opacity(0.72)
}

@ViewBuilder
private func liveChoiceButton<Label: View>(style: MessageChoiceStyle?,
                                           perform action: @escaping () -> Void,
                                           @ViewBuilder label: () -> Label) -> some View {
    switch style {
    case .primary:
        Button(action: action, label: label)
            .buttonStyle(.borderedProminent)
    case .destructive:
        Button(role: .destructive, action: action, label: label)
            .buttonStyle(.bordered)
    case .secondary, nil:
        Button(action: action, label: label)
            .buttonStyle(.plain)
    }
}

private struct ReplyChoiceCard: View {
    let title: String
    let detail: String
    let selected: Bool
    @Binding var text: String
    @FocusState.Binding var focusedActionID: String?
    let isEditing: Bool
    let multiple: Bool
    let suggested: Bool
    let ownAnswer: Bool
    let style: MessageChoiceStyle?
    let textColor: Color
    let selectedColor: Color
    let replySurface: Color
    let inputSurface: Color
    let target: ReplyEditorTarget
    let isReadOnly: Bool
    let onOpen: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        let inputShape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 16,
            bottomTrailingRadius: 16,
            topTrailingRadius: 0,
            style: .continuous
        )
        let showsEditor = !isReadOnly && (isEditing || selected)
        let card = VStack(alignment: .leading, spacing: 0) {
            MessageChoiceLabel(title: title, detail: detail, selected: selected,
                               multiple: multiple, suggested: suggested,
                               ownAnswer: ownAnswer, drawsSurface: false)
            if showsEditor {
                TextEditor(text: $text)
                    .font(.body)
                    .foregroundColor(Color.white)
                    .tint(Color.white)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(inputSurface, in: inputShape)
                    .clipShape(inputShape)
                    .focused($focusedActionID, equals: target.actionIdentifier)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(target.fieldIdentifier)
                    .disabled(isReadOnly || !selected)
            } else if !text.isEmpty {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(replySurface, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(showsEditor ? 0 : 14)
        .background(selected ? selectedColor : Color.clear, in: shape)
        .overlay(shape.strokeBorder(selected ? textColor : textColor.opacity(0.30), lineWidth: 1.5))
        .clipShape(shape)
        .opacity(selected ? 1 : 0.55)
        .animation(.smooth(duration: 0.25), value: selected)

        if showsEditor || isReadOnly {
            card
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(target.editorCardIdentifier)
        } else {
            liveChoiceButton(style: style, perform: onOpen) {
                card
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(target.summaryIdentifier)
            .accessibilityHint(text.isEmpty ? "Opens the reply field." : "Edit your reply.")
        }
    }
}

@MainActor
struct LiveContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    let store: LivePresentationStore
    let samples: SampleLibrary
    let launch: NativeAppLaunch?
    let archiveDeparture: NativeAccountDeparture?
    let fixtureStore: PrototypeStore?
    @State private var replyEditorFocused = false
#if DEBUG
    @State private var didApplyPresentationTestFixture = false
#endif

    init(store: LivePresentationStore,
         samples: SampleLibrary,
         launch: NativeAppLaunch? = nil,
         archiveDeparture: NativeAccountDeparture? = nil,
         fixtureStore: PrototypeStore? = nil) {
        self.store = store
        self.samples = samples
        self.launch = launch
        self.archiveDeparture = archiveDeparture
        self.fixtureStore = fixtureStore
    }

#if DEBUG
    private var recoveryStatusFixture: String? {
        ProcessInfo.processInfo.arguments.contains("--harklight-test-recovery-status")
            ? "Could not verify notification. Checking again while open." : nil
    }
#else
    private var recoveryStatusFixture: String? { nil }
#endif

    private var showsSampleMessages: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--harklight-samples")
        #else
        return false
        #endif
    }

    var body: some View {
        let progress = launch?.foregroundConnectProgress
        let showsRecovery = !store.isReadOnly && (progress.map { $0.outcome != .confirmed } ?? false)
        let failureKey = launch?.foregroundConnectFailureKey
        let diagnostic = launch?.foregroundConnectDiagnostic
        let connectionStatus = showsRecovery ? progress?.headline : store.connectionWarning
        let connectionWarning = showsRecovery ? progress?.message : store.connectionWarning
        let presentsFailureDetails = !store.isReadOnly && diagnostic != nil &&
            (failureKey.map { launch?.shouldPresentForegroundConnectFailure($0) ?? false } ?? false)
        let failureAlertPresented = Binding<Bool>(
            get: { presentsFailureDetails && !replyEditorFocused },
            set: { isPresented in
                guard !isPresented, let launch, let failureKey else { return }
                launch.dismissForegroundConnectFailure(failureKey)
            })
        if let loadError = fixtureStore?.loadError {
            ContentUnavailableView(loadError, systemImage: "exclamationmark.triangle")
        } else {
            HarklightInbox(
                requests: store.inboxRows,
                showsBasicOrderMarker: store.presentation.showsBasicOrderMarker,
                samples: samples, selectRequest: { store.selectRequest($0) },
                markSeenRequest: { key, revision in markSeen(key, requestRevision: revision) },
                markNoCommentRequest: { key, revision in
                    store.submitNoCommentFromUser(key, requestRevision: revision)
                },
                clearRetractedRequest: { store.clearRetracted($0) },
                requestDetail: { key, context in
                    if let request = store.request(for: key) {
                        LiveRequestDetail(request: request, store: store, context: context,
                                          fixtureStore: fixtureStore)
                    } else {
                        ContentUnavailableView("Request unavailable", systemImage: "questionmark.folder")
                    }
                },
                settingsContent: { LiveInboxSettings(store: store, launch: launch,
                                                      archiveDeparture: archiveDeparture,
                                                      connectionStatus: connectionStatus) },
                warnings: [launch?.notificationNavigationMessage, connectionWarning,
                           store.observationError, store.notificationWarning,
                           store.pushRegistrationWarning, store.unresolvedSendWarning,
                           launch?.archiveCatalogWarning,
                           launch?.disconnectedAccount?.removed == true ? nil : launch?.disconnectMessage,
                           fixtureStore?.persistenceError,
                           recoveryStatusFixture]
                    .compactMap { $0 },
                isRefreshing: store.isRefreshing,
                conversationStore: store,
                fetchOlderInboxPage: store.isReadOnly ? nil : { await store.fetchNextInboxPage() },
                showsLocalExamples: showsSampleMessages && !store.isReadOnly,
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
            .onChange(of: store.presentation.revision) { _, _ in
                fixtureStore?.refreshFromDurableStore()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { store.flushPendingDrafts() }
            }
            .onPreferenceChange(ReplyEditorFocusKey.self) { replyEditorFocused = $0 }
            .onAppear { applyPresentationTestFixtureIfNeeded() }
        }
    }

#if DEBUG
    private func applyPresentationTestFixtureIfNeeded() {
        guard !didApplyPresentationTestFixture else { return }
        didApplyPresentationTestFixture = true
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--harklight-test-refreshing") {
            store.beginRefresh()
        }
        if arguments.contains("--harklight-test-connection-warning") {
            store.connectionWarning = "The approved server could not be reached."
        }
        if arguments.contains("--harklight-test-stale-answer"),
           let current = store.presentation.requests.first {
            store.staleAnswerDialog = StaleAnswerDialog(
                operationID: UUID(), requestKey: current.key,
                submittedRevision: current.requestRevision,
                currentRevision: current.requestRevision + 1,
                title: "Updated request: \(current.title?.rawValue ?? "Message")",
                body: "The sender updated this request. Review the new details before answering.")
        }
    }
#else
    private func applyPresentationTestFixtureIfNeeded() {}
#endif

    private func markSeen(_ key: RequestKey, requestRevision: UInt64) {
        if let fixtureStore {
            guard fixtureStore.sendSelectedAnswer(for: key,
                                                   explicitCompatibilityAction: ExactText("seen")) else { return }
            try? store.refreshFromDurableStore()
        } else {
            store.submitFromUser(key, explicitCompatibilityAction: ExactText("seen"),
                                 requestRevision: requestRevision)
        }
    }
}

/// Shared message identity header for ordinary live and local-example details.
/// Only explicit protocol metadata is shown; missing metadata stays absent.
struct MessageHeading: View {
    let sender: String?
    let initials: String
    let title: String
    var createdAt: Date? = nil
    var symbol: String? = nil
    var titleColor: Color = .primary
    var chatUnread: Bool? = nil
    var secondaryTextColor: Color? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var neutralTokens: HarklightDesignSource.Neutral {
        HarklightDesignSystem.palette(for: colorScheme).neutral
    }

    private var mutedTextColor: Color {
        secondaryTextColor ?? neutralTokens.secondaryTextColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                if !initials.isEmpty {
                    Text(initials)
                        .font(.caption.bold())
                        .frame(width: 28, height: 28)
                        .background(titleColor.opacity(0.18), in: Circle())
                }
                if let sender {
                    Text(verbatim: sender).font(.subheadline)
                }
                Spacer(minLength: 0)
                if let createdAt {
                    Text(InboxFriendlyDate.label(for: createdAt))
                        .font(.caption)
                        .foregroundStyle(mutedTextColor)
                }
                if let chatUnread {
                    Image(systemName: chatUnread ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(chatUnread ? titleColor : mutedTextColor)
                        .accessibilityLabel(chatUnread ? "Unread conversation" : "Conversation read")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct LiveInboxSettings: View {
    let store: LivePresentationStore
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
        let account = record?.savedAccountName ?? "this account"
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
                        LabeledContent("Account", value: record.savedAccountName ?? "Current account")
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
                                    Label(departure.record.savedAccountName ?? "Disconnected account",
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
                                Button(launch?.isDisconnectBusy(for: archiveDeparture) == true
                                       ? "Retrying removal…" : "Retry removal") {
                                    Task { await launch?.retryDisconnectRemoval(for: archiveDeparture) }
                                }
                                .disabled(launch?.isDisconnectBusy(for: archiveDeparture) == true)
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
                                Button(launch?.isDisconnectBusy(for: departure) == true
                                       ? "Retrying removal…" : "Retry removal") {
                                    Task { await launch?.retryDisconnectRemoval(for: departure) }
                                }
                                .disabled(launch?.isDisconnectBusy(for: departure) == true)
                            }
                        } else {
                            Label("Read-only saved messages", systemImage: "lock")
                            Text("These messages remain associated with their original account. Connect only with an invitation for that account to resume them.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let launch {
                        let currentArchiveID = archiveDeparture?.archiveID ?? launch.disconnectedAccount?.archiveID
                        let otherPendingRemovals = launch.unconfirmedAccountDepartures.filter {
                            $0.archiveID != currentArchiveID
                        }
                        if !otherPendingRemovals.isEmpty {
                            Section("Other pending removals") {
                                ForEach(otherPendingRemovals, id: \.archiveID) { departure in
                                    UnconfirmedAccountRemovalNotice(launch: launch, departure: departure)
                                        .font(.footnote)
                                }
                            }
                        }
                    }
                } else if launch != nil {
                    Section("Connection") {
                        Text("This phone is registered to this account.")
                            .foregroundStyle(.secondary)
                        if let launch {
                            ForEach(launch.unconfirmedAccountDepartures, id: \.archiveID) { departure in
                                UnconfirmedAccountRemovalNotice(launch: launch, departure: departure)
                                    .font(.footnote)
                            }
                        }
                        if launch?.canMigrateDirectEndpointToGibson == true {
                            Button(launch?.isEndpointMigrationBusy == true ? "Checking new server…" : "Switch connection to new server…") {
                                confirmingEndpointMigration = true
                            }
                            .disabled(launch?.isEndpointMigrationBusy == true)
                            .confirmationDialog("Switch this connection?", isPresented: $confirmingEndpointMigration,
                                                titleVisibility: .visible) {
                                Button("Switch connection to new server") {
                                    Task { await launch?.migrateDirectEndpointToGibson() }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Harklight will check the new server before switching. Your account, device identity, trust certificate, messages and drafts stay on this phone. This does not unregister or enroll the device. If the switch cannot be completed, your current connection stays active.")
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

struct LiveRequestDetail: View {
    private struct StorePresentationSnapshot: Equatable {
        let conversationRevision: UInt64?
        let hasAcceptedUpdate: Bool
        let isRetracted: Bool
        let retractionLabel: String
        let conversationIndicator: Bool?
    }

    let request: PresentedRequest
    let store: LivePresentationStore
    var context: InboxCardContext = .standalone
    var localExample: SampleResponse? = nil
    var fixtureStore: PrototypeStore? = nil
    var noCommentUnavailableOverride: Bool? = nil
    private var showsNoCommentUnavailable: Bool {
        noCommentUnavailableOverride ?? request.noCommentUnavailable
    }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var chatPresented = false
    @State private var enlargedPicture: SampleOption?
    @State private var fixtureOutcomePresented = false
    @State private var requestDetailsPresented = false
    @State private var activeReplyEditor: ReplyEditorTarget?
    @State private var replyDraftSession: ReplyEditorDraftSession?
    @State private var localReplyEditingActive = false
    @State private var storePresentationSnapshot: StorePresentationSnapshot
    @FocusState private var focusedReplyActionID: String?

    init(request: PresentedRequest,
         store: LivePresentationStore,
         context: InboxCardContext = .standalone,
         localExample: SampleResponse? = nil,
         fixtureStore: PrototypeStore? = nil,
         noCommentUnavailableOverride: Bool? = nil) {
        self.request = request
        self.store = store
        self.context = context
        self.localExample = localExample
        self.fixtureStore = fixtureStore
        self.noCommentUnavailableOverride = noCommentUnavailableOverride
        _storePresentationSnapshot = State(initialValue: Self.storePresentationSnapshot(
            request: request, store: store))
        let canSubmit = localExample == nil &&
            Self.canEditSnapshot(request: request, store: store, context: context)
        if canSubmit {
            _replyDraftSession = State(initialValue: ReplyEditorDraftSession(
                request: request,
                canSubmitFromSnapshot: canSubmit))
        } else {
            _replyDraftSession = State(initialValue: nil)
        }
    }

    private var detailColors: HarklightDesignSource.MessageType {
        HarklightDesignSystem.palette(for: colorScheme).messageType(context.messageType)
    }

    private var isSinglePanePresentation: Bool {
        // Use the split view's current adaptive width, not a device or fold-state guess.
        horizontalSizeClass == .compact
    }

    private var isSupersedesReadOnly: Bool {
        context.isSupersedesTarget || request.lifecycleStatus == .superseded
    }

    private var replyEditorSurface: Color {
        HarklightDesignSystem.palette(for: colorScheme).detail.replyFieldColor
    }

    private static func canEditSnapshot(request: PresentedRequest,
                                        store: LivePresentationStore,
                                        context: InboxCardContext) -> Bool {
        guard !context.isSupersedesTarget,
              !store.isReadOnly, !store.isRetracted(request.key),
              request.lifecycleStatus == .open,
              request.intentReceipt == nil else { return false }
        switch request.projection {
        case .sender:
            return true
        case let .compatibility(actions):
            if request.informationalSeenStatus != nil {
                return request.informationalSeenStatus == .available && actions.count == 1
            }
            return !actions.isEmpty
        case .unsupported:
            return false
        }
    }

    private static func storePresentationSnapshot(request: PresentedRequest,
                                                  store: LivePresentationStore) -> StorePresentationSnapshot {
        let thread = store.conversation(for: request.key)
        let retractionOutcome: UInt64? = {
            guard let outcome = request.intentReceipt?.relayOutcome,
                  case let .refusedByRetraction(retractedAtMilliseconds) = outcome else { return nil }
            return retractedAtMilliseconds
        }()
        let retractionTimestamp = thread?.retraction?.retractedAtMilliseconds
            ?? thread?.reportedRetractedAtMilliseconds
            ?? retractionOutcome
        let label = retractionTimestamp.map {
            "Retracted · " + Date(timeIntervalSince1970: Double($0) / 1_000)
                .formatted(date: .abbreviated, time: .shortened)
        } ?? "Retracted"
        return StorePresentationSnapshot(
            conversationRevision: thread?.currentRevision,
            hasAcceptedUpdate: thread?.acceptedUpdates.isEmpty == false,
            isRetracted: thread?.isRetracted == true || retractionOutcome != nil,
            retractionLabel: label,
            conversationIndicator: thread.map { $0.hasUnreadAgentReply })
    }

    private var localReplySession: ReplyEditorDraftSession? {
        guard localExample == nil,
              let session = replyDraftSession,
              session.requestKey == request.key else { return nil }
        return session
    }

    private var isEditingLocalReply: Bool {
        localReplyEditingActive && localReplySession?.canSubmitFromSnapshot == true
    }

    private func markLocalReplyInteraction() {
        guard localReplySession?.canSubmitFromSnapshot == true else { return }
        if !localReplyEditingActive { localReplyEditingActive = true }
    }

    private func openReplyEditor(_ target: ReplyEditorTarget) {
        markLocalReplyInteraction()
        activeReplyEditor = target
        focusedReplyActionID = target.actionIdentifier
    }

    private func closeReplyEditor() {
        focusedReplyActionID = nil
        activeReplyEditor = nil
    }

    private func replyTextBinding(for target: ReplyEditorTarget) -> Binding<String> {
        if let session = localReplySession {
            return Binding(
                get: {
                    if let inputID = target.inputID {
                        return session.draft.inputs[ExactText(inputID)]?
                            .textByActionID[ExactText(target.actionID)]?.rawValue ?? ""
                    }
                    return session.draft.compatibility.textByActionID[ExactText(target.actionID)]?.rawValue ?? ""
                },
                set: { text in
                    guard !controlsReadOnly else { return }
                    markLocalReplyInteraction()
                    session.updateText(text, target: target)
                })
        }
        return Binding(
            get: {
                let draft = (controlsReadOnly ? request.submittedAnswer : nil)
                    ?? store.draft(for: request.key, revision: request.requestRevision)
                    ?? request.draft
                guard draft.hasEdits else {
                    return ""
                }
                if let inputID = target.inputID {
                    return draft.inputs[ExactText(inputID)]?
                        .textByActionID[ExactText(target.actionID)]?.rawValue ?? ""
                }
                return draft.compatibility.textByActionID[ExactText(target.actionID)]?.rawValue ?? ""
            },
            set: { text in
                guard !controlsReadOnly else { return }
                if let inputID = target.inputID {
                    store.stageText(text, input: ExactText(inputID), action: ExactText(target.actionID),
                                    for: request.key, requestRevision: request.requestRevision)
                } else {
                    store.stageCompatibilityText(text, action: ExactText(target.actionID),
                                                 for: request.key, requestRevision: request.requestRevision)
                }
            })
    }

    private var controlsReadOnly: Bool {
        if isSupersedesReadOnly { return true }
        if let localExample {
            return store.isReadOnly || request.lifecycleStatus != .open ||
                request.intentReceipt != nil || store.isRetracted(request.key) || localExample.finished
        }
        if isEditingLocalReply {
            return localReplySession?.canSubmitFromSnapshot != true
        }
        return !canEdit
    }

    /// Send actions follow the visible request's eligibility. Freshness is
    /// carried by the request revision for answers and cannot block Seen while
    /// the inbox is checking whether its snapshot is current.
    private var sendControlsDisabled: Bool {
        if localExample != nil { return controlsReadOnly }
        return !canEdit
    }

    private var localSeenAction: ((ExactText) -> Void)? {
        if let localExample {
            return { _ in localExample.finishLocally() }
        }
        guard let fixtureStore else { return nil }
        return { action in
            guard fixtureStore.sendSelectedAnswer(for: request.key,
                                                   explicitCompatibilityAction: action) else { return }
            try? store.refreshFromDurableStore()
        }
    }

    private var availableSeenAction: ExactText? {
        guard request.informationalSeenStatus == .available,
              case let .compatibility(actions) = request.projection else { return nil }
        return actions.first?.id
    }

    private var canFinishSeenAction: Bool {
        guard request.informationalSeenStatus == .available else { return false }
        if let localExample {
            return localExample.canFinishLocally
        }
        return availableSeenAction != nil
    }

    private var seenActionPresentation: SeenActionPresentation {
        SeenActionPresentation(status: request.informationalSeenStatus ?? .available)
    }

    private func finishSeenAction() {
        if let localExample {
            guard localExample.canFinishLocally else { return }
            localExample.finishLocally()
        } else if let availableSeenAction {
            submitSeenAction(availableSeenAction)
        } else {
            return
        }
        returnToListIfSinglePane()
    }

    private var seenActionIsComplete: Bool {
        localExample?.localSeenSelected == true || seenActionPresentation.isCompleted
    }

    private var seenActionIsPending: Bool {
        seenActionPresentation.isPending
    }

    private var seenToolbarTint: Color? {
        guard !seenActionIsComplete, !seenActionIsPending else { return nil }
        return HarklightDesignSystem.palette(for: colorScheme).accent.seenColor
    }

    private var finishSeenButton: some View {
        Button(action: finishSeenAction) {
            if seenActionIsComplete {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text("Seen")
                }
                    .padding(.horizontal, 6)
            } else {
                Image(systemName: seenActionIsPending ? "clock" : "checkmark")
            }
        }
        .tint(seenToolbarTint)
        .disabled(sendControlsDisabled || !canFinishSeenAction || seenActionIsComplete)
        .accessibilityLabel(seenActionIsComplete ? "Seen"
                            : seenActionIsPending ? "Seen pending confirmation" : "Mark as seen")
        .accessibilityValue(Text(localExample?.localSeenSelected == true
                                 ? "Completed"
                                 : seenActionPresentation.accessibilityValue))
        .accessibilityIdentifier("request-finish-seen")
        // A fresh native glass host avoids retaining the pressed button's
        // oversized background when confirmation expands the label.
        .id(seenActionIsComplete ? "seen-complete" : "seen-action")
    }

    private var answerIsComplete: Bool {
        guard localExample == nil, request.informationalSeenStatus == nil,
              !storePresentationSnapshot.isRetracted else { return false }
        return Self.answerStatusIsComplete(lifecycleStatus: request.lifecycleStatus,
                                           ownOutcome: request.receiptFacts?.ownOutcome,
                                           answerNotDelivered: request.answerNotDelivered)
    }

    private var pinsAnsweredStatusInWidePhoneToolbar: Bool {
        answerIsComplete && UIDevice.current.userInterfaceIdiom == .phone &&
            horizontalSizeClass == .regular
    }

    /// A pending or refused send never counts as Answered; only a request the
    /// relay reports answered, or an accepted submission, completes the state.
    static func answerStatusIsComplete(lifecycleStatus: AppLifecycleStatus,
                                       ownOutcome: OwnOutcome?,
                                       answerNotDelivered: Bool) -> Bool {
        guard !answerNotDelivered else { return false }
        if lifecycleStatus == .answered { return true }
        return ownOutcome == .accepted && lifecycleStatus != .noComment
    }

    private func returnToListIfSinglePane() {
        guard isSinglePanePresentation else { return }
        context.dismissToList?()
    }

    private var answerStatusText: String? {
        guard let facts = request.receiptFacts else { return nil }
        return Self.answerStatusText(lifecycleStatus: request.lifecycleStatus,
                                     ownOutcome: facts.ownOutcome,
                                     answeredFromThisDevice: request.intentReceipt != nil)
    }

    private var byWhenDate: Date? {
        guard let milliseconds = request.byWhenMilliseconds else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    /// Plain-language send status for the content area. Internal evidence
    /// wording stays in the request details sheet.
    static func answerStatusText(lifecycleStatus: AppLifecycleStatus,
                                 ownOutcome: OwnOutcome,
                                 answeredFromThisDevice: Bool) -> String? {
        switch lifecycleStatus {
        case .open, .answered:
            return nil
        case .noComment:
            return "The sender recorded your No comment answer."
        case .pending:
            return ownOutcome == .unconfirmed
                ? "Your answer is saved on this device. Delivery is not yet confirmed."
                : nil
        case .cleared, .expired, .superseded:
            if ownOutcome == .refused {
                return "The sender retracted this request before your answer was accepted. The answer was not accepted."
            }
            if ownOutcome == .unconfirmed && answeredFromThisDevice {
                return "This request closed without a confirmed result for your answer."
            }
            return nil
        }
    }

    private var answeredStatusButton: some View {
        Button(action: {}) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                Text(Self.answeredStatusTitle(accountAnswerOutcome: request.accountAnswerOutcome,
                                              isLiveRequest: localExample == nil && fixtureStore == nil))
            }
                .padding(.horizontal, 6)
        }
        .tint(nil)
        .disabled(true)
        .accessibilityLabel(Self.answeredStatusTitle(accountAnswerOutcome: request.accountAnswerOutcome,
                                                       isLiveRequest: localExample == nil && fixtureStore == nil))
        .accessibilityValue("Completed")
        .accessibilityIdentifier("request-answered")
    }

    static func answeredStatusTitle(accountAnswerOutcome: AccountAnswerOutcome?,
                                    isLiveRequest: Bool) -> String {
        switch accountAnswerOutcome {
        case .some(.seen): "Seen"
        case .some(.reply(_)): "Replied"
        case .some(.noComment): "No comment"
        case .some(.defaultAnswer(_, _)): "Answered by default"
        case .none: isLiveRequest ? "Answered" : "Replied"
        }
    }

    private var noCommentStatusButton: some View {
        Button(action: {}) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                Text("No comment")
            }
                .padding(.horizontal, 6)
        }
        .tint(nil)
        .disabled(true)
        .accessibilityLabel("No comment")
        .accessibilityValue("Completed")
        .accessibilityIdentifier("request-no-comment-status")
    }

    private var noCommentSelected: Bool {
        if let localReplySession { return localReplySession.noCommentSelected }
        return localExample?.noCommentSelected
            ?? request.submittedAnswer?.noCommentSelected
            ?? request.draft.noCommentSelected
    }

    private var canSubmitCurrentAnswer: Bool {
        if let session = localReplySession {
            return session.noCommentSelected
                ? session.canSubmitFromSnapshot && request.informationalSeenStatus == nil
                : session.canSubmitFromSnapshot
        }
        if noCommentSelected { return canOfferNoComment }
        return canAnswer
    }

    private var canOfferNoComment: Bool {
        guard !isSupersedesReadOnly, request.informationalSeenStatus == nil else { return false }
        if let localReplySession { return localReplySession.canSubmitFromSnapshot }
        if let localExample { return localExample.canDeclineLocally }
        if let fixtureStore { return fixtureStore.canSendNoCommentLocally(for: request.key) }
        guard !store.isReadOnly,
              !store.isRetracted(request.key), request.lifecycleStatus == .open,
              request.intentReceipt == nil else { return false }
        return true
    }

    private var noCommentChoice: some View {
        NoCommentChoiceRow(selected: noCommentSelected,
                           unavailable: showsNoCommentUnavailable,
                           onSelect: selectNoCommentAction)
    }

    private func selectNoCommentAction() {
        closeReplyEditor()
        if let session = localReplySession {
            session.selectNoComment()
            markLocalReplyInteraction()
        } else {
            store.selectNoComment(for: request.key, requestRevision: request.requestRevision)
        }
    }

    private func submitSeenAction(_ action: ExactText) {
        if let localSeenAction {
            localSeenAction(action)
        } else {
            store.submitFromUser(request.key, explicitCompatibilityAction: action,
                                 requestRevision: request.requestRevision)
        }
    }

    var canAnswer: Bool {
        canEdit
    }

    /// Answer eligibility follows the visible request, not the cache's
    /// transient freshness. Every submission carries request.requestRevision;
    /// the server can decline that exact version if the message changed.
    var canEdit: Bool {
        if isEditingLocalReply { return true }
        return Self.canEditSnapshot(request: request, store: store, context: context)
    }

    private var submitLabel: String {
        if noCommentSelected && showsNoCommentUnavailable { return "Retry No comment" }
        if case let .sender(sender) = request.projection { return sender.submissionLabel.rawValue }
        return "Send answer"
    }

    private var senderLabel: String {
        if let localExample { return localExample.message.sender }
        return InboxSenderDisplay.label(displayName: request.senderDisplayName?.rawValue,
                                        senderID: request.key.senderID.rawValue)
    }

    private var detailSenderLabel: String {
        if let localExample { return localExample.message.sender }
        return InboxSenderDisplay.detailLabel(displayName: request.senderDisplayName?.rawValue,
                                              senderID: request.key.senderID.rawValue)
    }

    private var senderInitials: String {
        if let localExample { return localExample.message.initials }
        return String(senderLabel.split(whereSeparator: { !$0.isLetter })
            .prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        MessageCardSurface(context: context,
                           replyEditorIsOpen: activeReplyEditor != nil || focusedReplyActionID != nil,
                           onDownwardContentSwipe: {
                               focusedReplyActionID = nil
                           }) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    requestDetailsPresented = true
                } label: {
                    MessageHeading(sender: senderLabel,
                               initials: senderInitials,
                               title: request.title?.rawValue ?? "Message",
                               createdAt: request.createdAt,
                               symbol: localExample?.message.kind.symbol ?? (request.informationalSeenStatus == nil ? "text.bubble" : "info.circle"),
                               titleColor: detailColors.textColor,
                               chatUnread: conversationIndicator,
                               secondaryTextColor: detailColors.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("request-heading")
                .accessibilityHint("Open request details")
                if let priority = request.inboxPriority,
                   let priorityLabel = InboxPriorityDisplay.label(for: priority) {
                    Label {
                        Text(priorityLabel.title)
                    } icon: {
                        Image(systemName: "flag.fill")
                    }
                        .font(.caption.weight(.semibold))
                        .accessibilityLabel(Text(priorityLabel.title))
                        .accessibilityIdentifier("request-priority")
                }
                if request.messageType != nil || request.messageKind != nil {
                    MessageMetadataBadges(messageType: request.messageType,
                                          messageKind: request.messageKind,
                                          containsChildAccessibilityElements: true)
                }
                if let deadline = byWhenDate {
                    Label("Deadline · \(deadline.formatted(date: .omitted, time: .shortened))",
                          systemImage: "calendar")
                        .font(.subheadline)
                        .accessibilityIdentifier("request-deadline")
                }
                if let stake = request.stakeText {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What’s at stake")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(detailColors.secondaryTextColor)
                        Text(stake.rawValue)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("request-stake")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !request.supersedesMessageIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Supersedes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(detailColors.secondaryTextColor)
                        ForEach(request.supersedesMessageIDs, id: \.self) { messageID in
                            let targetKey = RequestKey(accountScope: request.key.accountScope,
                                senderID: request.key.senderID, messageID: messageID)
                            NavigationLink(value: SupersedesTarget(key: targetKey)) {
                                Text(messageID.rawValue)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                            }
                            .accessibilityIdentifier("request-supersedes-" + messageID.rawValue)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let localExample {
                    if localExample.message.revised || localExample.message.deadline != nil {
                        LocalSampleContext(response: localExample)
                    }
                    if localExample.finished {
                        Label(localExample.noCommentSelected
                              ? "No comment selected locally · nothing sent"
                              : request.informationalSeenStatus == nil
                                  ? "Answered locally · nothing sent"
                                  : "Seen selected locally · nothing sent",
                              systemImage: "checkmark.circle")
                            .font(.subheadline).foregroundStyle(detailColors.secondaryTextColor)
                            .accessibilityIdentifier(localExample.noCommentSelected
                                ? "request-local-no-comment-status"
                                : "request-local-answer-status")
                    }
                }
                if let revision = storePresentationSnapshot.conversationRevision, revision > 1 {
                    Text(storePresentationSnapshot.hasAcceptedUpdate ? "Updated · version \(revision)" : "Question version \(revision)")
                        .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                        .accessibilityIdentifier("request-update-fact")
                }
                if storePresentationSnapshot.isRetracted {
                    Text("The sender retracted this request. Saved work and its original delivery status are retained; no further answer will be sent.")
                        .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                }
                if let body = request.body {
                    SystemDetectedMessageBody(text: body.rawValue,
                                               foregroundColor: detailColors.textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if localExample?.message.kind == .review {
                    SampleDiffView()
                }
                switch request.projection {
                case let .sender(sender):
                    VStack(alignment: .leading, spacing: 10) {
                        LiveProjectedSceneView(request: request,
                                               sender: sender,
                                               node: sender.scene,
                                               store: store,
                                               readOnly: controlsReadOnly,
                                               hideAnswerControls: isSupersedesReadOnly,
                                               focusedReplyActionID: $focusedReplyActionID,
                                               activeReplyEditor: activeReplyEditor,
                                               localReplyDraftSession: localReplySession,
                                               openReplyEditor: { openReplyEditor($0) },
                                               replyTextBinding: { replyTextBinding(for: $0) },
                                               closeReplyEditor: closeReplyEditor,
                                               onLocalReplyInteraction: markLocalReplyInteraction,
                                               localExample: localExample,
                                               enlargePicture: { enlargedPicture = $0 })
                        if canOfferNoComment { noCommentChoice }
                    }
                case let .compatibility(actions):
                    LiveCompatibilityActions(request: request,
                                             actions: actions,
                                             store: store,
                                             readOnly: controlsReadOnly,
                                             hideAnswerControls: isSupersedesReadOnly,
                                             sendDisabled: sendControlsDisabled,
                                             localExample: localExample,
                                             onSeen: { action in
                                                 submitSeenAction(action)
                                                 returnToListIfSinglePane()
                                             },
                                             canOfferNoComment: canOfferNoComment,
                                             noCommentSelected: noCommentSelected,
                                             noCommentUnavailable: showsNoCommentUnavailable,
                                             onSelectNoComment: selectNoCommentAction,
                                             focusedReplyActionID: $focusedReplyActionID,
                                             replyTextBinding: { replyTextBinding(for: $0) },
                                             localReplyDraftSession: localReplySession,
                                             activeReplyEditor: activeReplyEditor,
                                             openReplyEditor: { openReplyEditor($0) },
                                             closeReplyEditor: closeReplyEditor,
                                             onLocalReplyInteraction: markLocalReplyInteraction)
                case .unsupported:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("This request uses an unsupported answer format.")
                            .foregroundStyle(detailColors.secondaryTextColor)
                        if canOfferNoComment { noCommentChoice }
                    }
                }
                if request.answerNotDelivered {
                    Label("Answer not delivered", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("request-answer-not-delivered")
                }
                if showsNoCommentUnavailable && !isSupersedesReadOnly {
                    Text("No comment was not delivered: this server does not support it. Tap the checkmark to retry.")
                        .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                        .accessibilityIdentifier("request-no-comment-unavailable")
                }
                if request.inboxStateIsCurrent {
                    if storePresentationSnapshot.isRetracted {
                        Text(storePresentationSnapshot.retractionLabel)
                            .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                            .accessibilityIdentifier("request-lifecycle-status")
                    } else if isSupersedesReadOnly {
                        Text(String(localized: LiveLifecycleTitle(request.lifecycleStatus).label))
                            .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                            .accessibilityIdentifier("request-lifecycle-status")
                    } else if request.lifecycleStatus != .open && request.lifecycleStatus != .answered {
                        Text(String(localized: LiveLifecycleTitle(request.lifecycleStatus).label))
                            .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                            .accessibilityIdentifier("request-lifecycle-status")
                    }
                    if case let .reply(answerText)? = request.accountAnswerOutcome {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reply")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(detailColors.secondaryTextColor)
                            Text(answerText.rawValue)
                                .font(.subheadline)
                                .foregroundStyle(Color.white)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("request-account-answer")
                        }
                    }
                    if let seenStatus = request.informationalSeenStatus,
                       seenStatus != .available || isSupersedesReadOnly {
                        Label(Self.informationalSeenText(seenStatus),
                              systemImage: Self.informationalSeenSymbol(seenStatus))
                            .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                            .accessibilityIdentifier("informational-seen-status")
                    }
                } else {
                    Label("Cached history · status not refreshed", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                        .accessibilityIdentifier("inbox-status-unrefreshed")
                    if let localStatus = Self.cachedOperationStatus(request.intentReceipt?.localState) {
                        Text(localStatus).font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                    }
                }
                if request.isDefaultAnswered {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Answered by default", systemImage: "clock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(detailColors.secondaryTextColor)
                            .accessibilityIdentifier("request-default-answer-status")
                        if let answerWords = request.defaultAnswerWords, !answerWords.isEmpty {
                            Text(answerWords)
                                .font(.subheadline)
                                .foregroundStyle(Color.white)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("request-default-answer")
                        }
                    }
                }
                if !isSupersedesReadOnly, localExample == nil, fixtureStore == nil,
                   request.lifecycleStatus == .pending {
                    Button("Retry delivery") { store.retryPendingDelivery() }
                        .buttonStyle(.bordered)
                        .disabled(store.isReadOnly)
                }
                if !isSupersedesReadOnly, let fixtureStore, request.lifecycleStatus == .pending {
                    Button("Simulate fixture outcome", systemImage: "testtube.2") {
                        fixtureOutcomePresented = true
                    }
                    .accessibilityIdentifier("fixture-outcome-menu")
                    .confirmationDialog("Simulate fixture outcome",
                                        isPresented: $fixtureOutcomePresented,
                                        titleVisibility: .visible) {
                        ForEach([DemoTerminalScenario.ownOperationAccepted,
                                 .answerOutcomeUnconfirmed, .cleared]) { scenario in
                            Button(scenario.simulationTitle) {
                                guard fixtureStore.simulateTerminal(for: request.key,
                                                                    scenario: scenario) else { return }
                                try? store.refreshFromDurableStore()
                            }
                            .accessibilityIdentifier("fixture-outcome-" + scenario.id)
                        }
                    }
                }
                if let actionError = store.actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if request.inboxStateIsCurrent, let statusText = answerStatusText {
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(detailColors.secondaryTextColor)
                        .accessibilityIdentifier("request-receipt-evidence")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(detailColors.textColor)
            .tint(detailColors.textColor)
        }
        .toolbar {
            if !isSupersedesReadOnly {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    chatButton
                }
                if pinsAnsweredStatusInWidePhoneToolbar {
                    ToolbarItem(placement: .topBarPinnedTrailing) {
                        answeredStatusButton
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        if request.informationalSeenStatus != nil {
                            finishSeenButton
                        } else if let localExample {
                            Button("Finish locally", systemImage: "checkmark") {
                                closeReplyEditor()
                                localExample.finishLocally()
                            }
                            .labelStyle(.iconOnly)
                            .disabled(!localExample.canFinishLocally || localExample.finished)
                            .accessibilityIdentifier("sample-finish")
                        } else if isEditingLocalReply {
                            submitReplyButton
                        } else if request.lifecycleStatus == .noComment {
                            noCommentStatusButton
                        } else if answerIsComplete {
                            answeredStatusButton
                        } else {
                            submitReplyButton
                        }
                    }
                }
            }
        }
        .sheet(item: $enlargedPicture) { picture in
            SamplePictureViewer(initialPicture: picture)
        }
        .sheet(isPresented: $requestDetailsPresented) {
            requestDetailsSheet
        }
        .sheet(isPresented: $chatPresented) {
            conversationPanel
        }
        .onChange(of: context.inlineChat) { _, inline in
            if inline { chatPresented = false }
        }
        .onChange(of: request) { _, _ in
            refreshStorePresentationSnapshot()
            refreshUneditedReplySession()
        }
        .onChange(of: store.conversationThreads) { _, _ in
            refreshStorePresentationSnapshot()
            refreshUneditedReplySession()
        }
        .onChange(of: request.key) { _, _ in
            closeReplyEditor()
            localReplyEditingActive = false
            let canSubmit = localExample == nil &&
                Self.canEditSnapshot(request: request, store: store, context: context)
            if canSubmit {
                replyDraftSession = ReplyEditorDraftSession(
                    request: request,
                    canSubmitFromSnapshot: canSubmit)
            } else {
                replyDraftSession = nil
            }
        }
        .preference(key: ReplyEditorFocusKey.self, value: focusedReplyActionID != nil)
    }

    private func refreshUneditedReplySession() {
        guard !localReplyEditingActive else { return }
        let canSubmit = localExample == nil &&
            Self.canEditSnapshot(request: request, store: store, context: context)
        if canSubmit {
            if let session = localReplySession {
                session.adoptUneditedRequest(request, canSubmit: true)
            } else {
                replyDraftSession = ReplyEditorDraftSession(request: request,
                                                            canSubmitFromSnapshot: true)
            }
        } else {
            replyDraftSession = nil
        }
    }

    private func refreshStorePresentationSnapshot() {
        storePresentationSnapshot = Self.storePresentationSnapshot(request: request, store: store)
    }

    private var submitReplyButton: some View {
        Button(submitLabel, systemImage: "checkmark") {
            let submitted: Bool
            if let fixtureStore {
                let sent: Bool
                if let session = localReplySession {
                    if session.noCommentSelected {
                        sent = fixtureStore.sendNoCommentLocally(for: request.key,
                                                                 selectionIsLocal: true)
                    } else {
                        sent = fixtureStore.sendSelectedAnswer(for: request.key,
                                                               answerDraft: session.draft)
                    }
                } else {
                    sent = store.draft(for: request.key,
                                       revision: request.requestRevision)?.noCommentSelected == true
                        ? fixtureStore.sendNoCommentLocally(for: request.key)
                        : fixtureStore.sendSelectedAnswer(for: request.key)
                }
                guard sent else { return }
                submitted = true
                try? store.refreshFromDurableStore()
            } else if let session = localReplySession {
                if session.noCommentSelected {
                    submitted = store.submitNoCommentFromUser(request.key,
                                                             requestRevision: session.requestRevision,
                                                             selectionIsLocal: true)
                } else {
                    submitted = store.submitFromUser(request.key,
                                                     answerDraft: session.draft,
                                                     requestRevision: session.requestRevision)
                }
                guard submitted else {
                    endLocalReplyIfRequestChanged(session)
                    return
                }
            } else {
                submitted = store.submitFromUser(request.key,
                                                 requestRevision: request.requestRevision)
                guard submitted else { return }
            }
            localReplyEditingActive = false
            replyDraftSession = nil
            closeReplyEditor()
            returnToListIfSinglePane()
        }
        .labelStyle(.iconOnly)
        .disabled(isEditingLocalReply
                  ? !canSubmitCurrentAnswer
                  : (fixtureStore.map { !$0.canSend(for: request.key) } ?? !canSubmitCurrentAnswer))
        .accessibilityIdentifier("request-finish")
    }

    private func endLocalReplyIfRequestChanged(_ session: ReplyEditorDraftSession) {
        guard let current = store.request(for: session.requestKey) else {
            localReplyEditingActive = false
            replyDraftSession = nil
            closeReplyEditor()
            return
        }
        let isSameEligibleRequest = current.requestRevision == session.requestRevision &&
            Self.canEditSnapshot(request: current, store: store, context: context) &&
            (!session.noCommentSelected || current.informationalSeenStatus == nil)
        guard !isSameEligibleRequest else { return }

        localReplyEditingActive = false
        let canEditCurrentRequest = localExample == nil &&
            Self.canEditSnapshot(request: current, store: store, context: context)
        replyDraftSession = canEditCurrentRequest
            ? ReplyEditorDraftSession(request: current, canSubmitFromSnapshot: true)
            : nil
        closeReplyEditor()
    }

    private var chatButton: some View {
        Button("Chat", systemImage: "bubble.left.and.bubble.right") {
            localExample?.chatRead = true
            chatPresented = true
        }
        .labelStyle(.iconOnly)
        .badge(conversationIndicator == true ? 1 : 0)
        .accessibilityLabel("Chat")
        .accessibilityHint(conversationIndicator == true ? "Unread conversation" : "")
    }

    private var requestDetailsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Sender: \(detailSenderLabel)")
                    Text("Message: \(request.key.messageID.rawValue)")
                    Text(request.originalContentJSON)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("request-original-content-json")
                    if let receipt = request.intentReceipt {
                        Text("Original answer")
                            .font(.headline)
                        Text(receipt.exactAnswerJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("request-details-original-answer-json")
                    }
                    if let facts = request.receiptFacts {
                        Text("Receipt evidence")
                            .font(.headline)
                        Text(facts.evidenceLabel)
                            .font(.caption)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("request-details-receipt-evidence")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Request details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { requestDetailsPresented = false }
                        .accessibilityIdentifier("request-details-done")
                }
            }
        }
    }

    private var conversationIndicator: Bool? {
        if let localExample {
            return localExample.message.hasChat
                ? localExample.message.chatUnread && !localExample.chatRead : nil
        }
        return storePresentationSnapshot.conversationIndicator
    }

    private var noticeTextColor: Color {
        switch localExample?.message.kind {
        case .some(.error): Color(red: 0.48, green: 0, blue: 0.04)
        case .some(.warning): Color(red: 0.36, green: 0.24, blue: 0)
        case .some(.completed): Color(red: 0.10, green: 0.37, blue: 0.16)
        default: colorScheme == .dark
            ? Color(uiColor: .secondaryLabel)
            : Color(red: 0.04, green: 0.23, blue: 0.43)
        }
    }

    private var conversationPanel: some View {
        ConversationPanel(store: store, key: request.key,
            sender: detailSenderLabel, title: request.title?.rawValue ?? "")
    }

    static func informationalSeenText(_ status: InformationalSeenStatus) -> String {
        switch status {
        case .available: "Seen available"
        case .pending: "Seen pending confirmation"
        case .confirmed: "Seen"
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

    private static func cachedOperationStatus(_ state: LocalIntentState?) -> String? {
        guard let state else { return nil }
        return switch state {
        case .durable, .queuedForRelay: "Answer pending on this device"
        case .accepted: "Answer accepted"
        case .refusedByRetraction: "Answer refused · request retracted"
        case .terminalUnconfirmed: "Answer sent · result not confirmed"
        case .notDelivered: "Answer not delivered"
        case .unsupported: "No comment is unsupported by this server"
        case .repairRequired: "Answer needs recovery"
        }
    }
}

@MainActor
struct HistoricalAnswerDraftView: View {
    let request: PresentedRequest
    let store: LivePresentationStore
    var retracted = false
    @FocusState private var focusedReplyActionID: String?

    private func replyTextBinding(for target: ReplyEditorTarget) -> Binding<String> {
        let text: String
        if let inputID = target.inputID {
            text = request.draft.inputs[ExactText(inputID)]?
                .textByActionID[ExactText(target.actionID)]?.rawValue ?? ""
        } else {
            text = request.draft.compatibility
                .textByActionID[ExactText(target.actionID)]?.rawValue ?? ""
        }
        return .constant(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title?.rawValue ?? "Earlier question").font(.headline)
            if let body = request.body { Text(body.rawValue).font(.caption) }
            Text(retracted ? "Saved answer · request retracted. Its original wording and choices are retained." : "Not delivered · this selection belongs to the earlier question")
                .font(.caption).foregroundStyle(.secondary)
            switch request.projection {
            case let .sender(sender):
                LiveProjectedSceneView(request: request, sender: sender, node: sender.scene,
                                       store: store, readOnly: true,
                                       focusedReplyActionID: $focusedReplyActionID,
                                       replyTextBinding: { replyTextBinding(for: $0) })
            case let .compatibility(actions):
                LiveCompatibilityActions(request: request, actions: actions, store: store,
                                         readOnly: true,
                                         sendDisabled: true,
                                         focusedReplyActionID: $focusedReplyActionID,
                                         replyTextBinding: { replyTextBinding(for: $0) })
            case .unsupported:
                Text("This saved answer format cannot be displayed.").font(.caption)
            }
        }
    }
}

@MainActor
private func senderPictureLoader(for request: PresentedRequest,
                                 store: LivePresentationStore) -> SenderPictureLoader {
    { file in
        try await store.prepareConversationPreview(file, for: request.key,
                                                  revision: 1)
    }
}

@MainActor
private struct LiveProjectedSceneView: View {
    let request: PresentedRequest
    let sender: AdmittedSenderProjection
    let node: ProjectedSceneNode
    let store: LivePresentationStore
    let readOnly: Bool
    var hideAnswerControls = false
    @FocusState.Binding var focusedReplyActionID: String?
    var activeReplyEditor: ReplyEditorTarget? = nil
    var localReplyDraftSession: ReplyEditorDraftSession? = nil
    var openReplyEditor: (ReplyEditorTarget) -> Void = { _ in }
    var replyTextBinding: (ReplyEditorTarget) -> Binding<String>
    var closeReplyEditor: () -> Void = {}
    var onLocalReplyInteraction: () -> Void = {}
    var localExample: SampleResponse? = nil
    var enlargePicture: (SampleOption) -> Void = { _ in }

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
                SenderIllustrationCanvas(illustration: illustration, point: nil,
                                         deliveredFiles: request.deliveredFiles,
                                         pictureLoader: senderPictureLoader(for: request, store: store))
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
                                       readOnly: readOnly,
                                       hideAnswerControls: hideAnswerControls,
                                       focusedReplyActionID: $focusedReplyActionID,
                                       localExample: localExample,
                                       enlargePicture: enlargePicture,
                                       activeReplyEditor: activeReplyEditor,
                                       localReplyDraftSession: localReplyDraftSession,
                                       openReplyEditor: openReplyEditor,
                                       replyTextBinding: replyTextBinding,
                                       closeReplyEditor: closeReplyEditor,
                                       onLocalReplyInteraction: onLocalReplyInteraction)
            }
        case let .resultPoint(illustrationID, label, point):
            if let illustration = sender.illustrations.first(where: { $0.id == illustrationID }) {
                VStack(alignment: .leading, spacing: 8) {
                    SenderIllustrationCanvas(illustration: illustration, point: point,
                                             deliveredFiles: request.deliveredFiles,
                                             pictureLoader: senderPictureLoader(for: request, store: store))
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
                               node: child, store: store, readOnly: readOnly,
                               hideAnswerControls: hideAnswerControls,
                               focusedReplyActionID: $focusedReplyActionID,
                               activeReplyEditor: activeReplyEditor,
                               localReplyDraftSession: localReplyDraftSession,
                               openReplyEditor: openReplyEditor,
                               replyTextBinding: replyTextBinding,
                               closeReplyEditor: closeReplyEditor,
                               onLocalReplyInteraction: onLocalReplyInteraction,
                               localExample: localExample, enlargePicture: enlargePicture)
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
    var hideAnswerControls = false
    @FocusState.Binding var focusedReplyActionID: String?
    var localExample: SampleResponse? = nil
    var enlargePicture: (SampleOption) -> Void = { _ in }
    var activeReplyEditor: ReplyEditorTarget? = nil
    var localReplyDraftSession: ReplyEditorDraftSession? = nil
    var openReplyEditor: (ReplyEditorTarget) -> Void = { _ in }
    var replyTextBinding: (ReplyEditorTarget) -> Binding<String>
    var closeReplyEditor: () -> Void = {}
    var onLocalReplyInteraction: () -> Void = {}
    @State private var pointGestureCapture = PointGestureCapture()
    @State private var typedInputTextByRevision: [UInt64: String] = [:]
    @GestureState private var pointGestureActive = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    private var readOnlyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if input.label.rawValue != "Response" {
                Text(input.label.rawValue).font(.headline)
            }
            switch input.kind {
            case let .response(actions):
                ForEach(actions, id: \.id) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        if let artID = action.illustrationID,
                           let illustration = sender.illustrations.first(where: { $0.id == artID }) {
                            SenderIllustrationCanvas(illustration: illustration, point: nil,
                                                     deliveredFiles: request.deliveredFiles,
                                                     pictureLoader: senderPictureLoader(for: request, store: store))
                        }
                        Text(action.label.rawValue)
                    }
                }
            case .text:
                EmptyView()
            case let .point(illustrationID):
                if let illustration = sender.illustrations.first(where: { $0.id == illustrationID }) {
                    SenderIllustrationCanvas(illustration: illustration, point: draft?.effectivePoint,
                                             deliveredFiles: request.deliveredFiles,
                                             pictureLoader: senderPictureLoader(for: request, store: store))
                    if let point = draft?.effectivePoint {
                        Text("Horizontal \(point.x), vertical \(point.y)")
                    }
                }
            }
        }
    }

    private var detailColors: HarklightDesignSource.MessageType {
        HarklightDesignSystem.palette(for: colorScheme).messageType(messageType)
    }

    private var draft: InputDraft? {
        if let localReplyDraftSession {
            return localReplyDraftSession.draft.inputs[input.id]
        }
        return readOnly ? (request.submittedAnswer ?? request.draft).inputs[input.id]
            : store.draft(for: request.key, revision: request.requestRevision)?.inputs[input.id]
    }

    private var textBinding: Binding<String> {
        if let localReplyDraftSession {
            let target = ReplyEditorTarget(inputID: input.id.rawValue,
                                           actionID: "input-text",
                                           isInputText: true)
            return Binding(
                get: { localReplyDraftSession.draft.inputs[input.id]?.text?.rawValue ?? "" },
                set: {
                    guard !readOnly else { return }
                    onLocalReplyInteraction()
                    localReplyDraftSession.updateText($0, target: target)
                })
        }
        return Binding(
            get: { typedInputTextByRevision[request.requestRevision] ?? draft?.text?.rawValue ?? "" },
            set: {
                typedInputTextByRevision[request.requestRevision] = $0
                store.stageText($0, input: input.id, action: nil, for: request.key,
                                requestRevision: request.requestRevision)
            }
        )
    }

    private var textEditor: some View {
        let target = ReplyEditorTarget(inputID: input.id.rawValue,
                                       actionID: "input-text",
                                       isInputText: true)
        return TextField(
            input.label.rawValue,
            text: textBinding,
            prompt: Text(input.label.rawValue).foregroundColor(Color.white),
            axis: .vertical
        )
            .lineLimit(4...8)
            .textFieldStyle(.plain)
            .foregroundStyle(Color.white)
            .tint(Color.white)
            .padding(8)
            .background(replyEditorSurface, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(input.label.rawValue)
            .accessibilityIdentifier("request-input-" + input.id.rawValue)
            .focused($focusedReplyActionID, equals: target.actionIdentifier)
            .onChange(of: focusedReplyActionID) { _, focused in
                guard focused == target.actionIdentifier else { return }
                onLocalReplyInteraction()
                openReplyEditor(target)
            }
            .disabled(readOnly)
    }

    private var replyEditorSurface: Color {
        HarklightDesignSystem.palette(for: colorScheme).detail.replyFieldColor
    }

    private func activate(_ action: ProjectedAction) {
        withAnimation(.smooth(duration: 0.25), completionCriteria: .logicallyComplete) {
            if let localReplyDraftSession {
                localReplyDraftSession.selectAction(action.id, inputID: input.id)
                onLocalReplyInteraction()
            } else if let localExample, action.id.rawValue == "own" {
                if localExample.message.kind == .multipleChoice {
                    localExample.choices = []
                }
                localExample.ownAnswer = true
            } else {
                store.selectAction(action.id, input: input.id, for: request.key,
                                   requestRevision: request.requestRevision)
            }
        } completion: {
            if action.kind == .text {
                openReplyEditor(ReplyEditorTarget(inputID: input.id.rawValue,
                                                  actionID: action.id.rawValue))
            } else {
                closeReplyEditor()
            }
        }
    }

    @ViewBuilder
    private func inlineReplyAction(_ action: ProjectedAction,
                                   selected: Bool,
                                   text: String) -> some View {
        let detail = localExample != nil && action.id.rawValue == "own"
            ? "Write it here, or say why none of these fit."
            : ""
        let target = ReplyEditorTarget(inputID: input.id.rawValue, actionID: action.id.rawValue)
        ReplyChoiceCard(title: action.label.rawValue, detail: detail,
                        selected: selected, text: replyTextBinding(target),
                        focusedActionID: $focusedReplyActionID,
                        isEditing: activeReplyEditor == target,
                        multiple: false, suggested: false,
                        ownAnswer: action.id.rawValue == "own",
                        style: action.style,
                        textColor: detailColors.textColor,
                        selectedColor: HarklightDesignSystem.palette(for: colorScheme).detail.selectedChoiceColor,
                        replySurface: replyEditorSurface,
                        inputSurface: ReplyInputSurfaceStyle.fill(for: colorScheme),
                        target: target, isReadOnly: readOnly,
                        onOpen: { activate(action) })
    }

    var body: some View {
        if hideAnswerControls {
            readOnlyContent
        } else {
            switch input.kind {
            case let .response(actions):
                if let localExample,
                   localExample.message.kind == .pictureChoice,
                   input.id.rawValue == "answer" {
                    let options = localExample.message.options.filter { option in
                        actions.contains { $0.id.rawValue == option.id }
                    }
                    SamplePictureChoices(options: options, response: localExample,
                                         isReadOnly: readOnly, enlarge: enlargePicture)
                } else if let localExample,
                          localExample.message.kind == .multipleChoice,
                          input.id.rawValue != "answer",
                          let option = localExample.message.options.first(where: { $0.id == input.id.rawValue }) {
                    SampleChoiceRow(option: option,
                                    selected: localExample.choices.contains(option.id),
                                    multiple: true, swatch: nil, sound: false) {
                        localExample.choose(option.id, multiple: true)
                    }
                    .disabled(readOnly)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if input.label.rawValue != "Response" {
                            Text(input.label.rawValue).font(.headline)
                        }
                        VStack(spacing: 10) {
                            ForEach(actions.filter { action in
                                !(localExample?.message.kind == .multipleChoice &&
                                  input.id.rawValue == "answer" && action.id.rawValue == "options")
                            }, id: \.id) { action in actionButton(action) }
                        }
                    }
                }
            case .text:
                if let localExample,
                   localExample.message.kind == .value,
                   input.id.rawValue == "value" {
                    SampleNumberInput(response: localExample, isReadOnly: readOnly)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(input.label.rawValue).font(.headline)
                        textEditor
                    }
                }
            case let .point(illustrationID):
                if let illustration = sender.illustrations.first(where: { $0.id == illustrationID }) {
                    if let localExample, localExample.message.kind == .point {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(input.label.rawValue).font(.headline)
                            SampleAnnotationEditor(response: localExample,
                                                   illustration: illustration,
                                                   point: draft?.effectivePoint,
                                                   isReadOnly: readOnly)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(input.label.rawValue).font(.headline)
                            SenderIllustrationCanvas(illustration: illustration,
                                                     point: draft?.effectivePoint,
                                                     deliveredFiles: request.deliveredFiles,
                                                     pictureLoader: senderPictureLoader(for: request, store: store))
                                .overlay {
                                    GeometryReader { geometry in
                                        let bounds = CGRect(origin: .zero, size: geometry.size)
                                        Color.clear
                                            .contentShape(Rectangle())
                                            .gesture(DragGesture(minimumDistance: 0)
                                                .updating($pointGestureActive) { _, active, _ in
                                                    active = true
                                                }
                                                .onChanged { value in
                                                    guard !readOnly else { return }
                                                    var capture = pointGestureCapture
                                                    _ = capture.update(at: value.location, in: bounds)
                                                    pointGestureCapture = capture
                                                }
                                                .onEnded { value in
                                                    defer { pointGestureCapture.gestureDidEnd() }
                                                    guard !readOnly else { return }
                                                    var capture = pointGestureCapture
                                                    if let point = capture.finish(at: value.location, in: bounds) {
                                                        if let localReplyDraftSession {
                                                            localReplyDraftSession.setPoint(point, inputID: input.id)
                                                            onLocalReplyInteraction()
                                                        } else {
                                                            store.setPoint(point, input: input.id, for: request.key,
                                                                            requestRevision: request.requestRevision)
                                                        }
                                                    }
                                                    pointGestureCapture = capture
                                                }, isEnabled: !readOnly)
                                            .onChange(of: geometry.size) { _, size in
                                                var capture = pointGestureCapture
                                                capture.cancelIfBoundsChanged(to: CGRect(origin: .zero, size: size))
                                                pointGestureCapture = capture
                                            }
                                            .onChange(of: pointGestureActive) { wasActive, isActive in
                                                guard wasActive && !isActive else { return }
                                                var capture = pointGestureCapture
                                                capture.gestureDidEnd()
                                                pointGestureCapture = capture
                                            }
                                    }
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(illustration.label.rawValue)
                                .accessibilityHint(readOnly ? "Read-only illustration." : "Tap or drag to select a point.")
                                .accessibilityAction(named: "Set point at center") {
                                    guard !readOnly else { return }
                                    if let localReplyDraftSession {
                                        localReplyDraftSession.setPoint(PointValue(x: 500, y: 500), inputID: input.id)
                                        onLocalReplyInteraction()
                                    } else {
                                        store.setPoint(PointValue(x: 500, y: 500), input: input.id, for: request.key,
                                                       requestRevision: request.requestRevision)
                                    }
                                }
                                .accessibilityIdentifier("request-point-" + input.id.rawValue)
                            if let point = draft?.effectivePoint {
                                Text("Horizontal \(point.x), vertical \(point.y)")
                                    .accessibilityIdentifier("request-point-value-" + input.id.rawValue)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: ProjectedAction) -> some View {
        let selected = request.isDefaultAnswered
            ? request.defaultAnswerAction == ProjectedActionReference(inputID: input.id, actionID: action.id)
            : draft?.selectedActionID == action.id
        let replyText = draft?.textByActionID[action.id]?.rawValue ?? ""
        if action.kind == .text && (selected || !replyText.isEmpty) {
            inlineReplyAction(action, selected: selected, text: replyText)
        } else if let localExample,
           let option = localExample.message.options.first(where: { $0.id == action.id.rawValue }) {
            SampleChoiceRow(option: option, selected: selected,
                            multiple: false,
                            swatch: localExample.message.kind == .colorChoice ? option.id : nil,
                            sound: localExample.message.kind == .soundChoice) {
                if let localReplyDraftSession {
                    localReplyDraftSession.selectAction(action.id, inputID: input.id)
                    onLocalReplyInteraction()
                } else {
                    store.selectAction(action.id, input: input.id, for: request.key,
                                       requestRevision: request.requestRevision)
                }
            }
            .disabled(readOnly)
        } else {
            liveChoiceButton(style: action.style, perform: { activate(action) }) {
                VStack(alignment: .leading, spacing: 8) {
                    if let artID = action.illustrationID,
                       let illustration = sender.illustrations.first(where: { $0.id == artID }) {
                        SenderIllustrationCanvas(illustration: illustration, point: nil,
                                                 deliveredFiles: request.deliveredFiles,
                                                 pictureLoader: senderPictureLoader(for: request, store: store))
                    }
                    let detail = localExample != nil && action.id.rawValue == "own"
                        ? "Write it here, or say why none of these fit."
                        : ""
                    MessageChoiceLabel(title: action.label.rawValue, detail: detail,
                                       selected: selected, multiple: false, suggested: false,
                                       ownAnswer: action.id.rawValue == "own")
                }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .disabled(readOnly)
        }
    }

}

@MainActor
private struct LiveCompatibilityActions: View {
    let request: PresentedRequest
    let actions: [ProjectedAction]
    let store: LivePresentationStore
    let readOnly: Bool
    var hideAnswerControls = false
    /// Used only by the informational Seen control. Inbox freshness must not
    /// dim or disable a response while a refresh is pending.
    let sendDisabled: Bool
    var localExample: SampleResponse? = nil
    var onSeen: ((ExactText) -> Void)? = nil
    var canOfferNoComment = false
    var noCommentSelected = false
    var noCommentUnavailable = false
    var onSelectNoComment: () -> Void = {}
    @FocusState.Binding var focusedReplyActionID: String?
    var replyTextBinding: (ReplyEditorTarget) -> Binding<String>
    var localReplyDraftSession: ReplyEditorDraftSession? = nil
    var activeReplyEditor: ReplyEditorTarget? = nil
    var openReplyEditor: (ReplyEditorTarget) -> Void = { _ in }
    var closeReplyEditor: () -> Void = {}
    var onLocalReplyInteraction: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    private var detailColors: HarklightDesignSource.MessageType {
        HarklightDesignSystem.palette(for: colorScheme).messageType(messageType)
    }

    private var seenColor: Color {
        HarklightDesignSystem.palette(for: colorScheme).accent.seenColor
    }

    private var selected: ExactText? {
        if request.isDefaultAnswered {
            return request.defaultAnswerAction?.inputID == nil
                ? request.defaultAnswerAction?.actionID : nil
        }
        if let localReplyDraftSession {
            return localReplyDraftSession.draft.compatibility.selectedActionID
        }
        return readOnly ? (request.submittedAnswer ?? request.draft).compatibility.selectedActionID
            : store.draft(for: request.key, revision: request.requestRevision)?.compatibility.selectedActionID
    }

    private var seenActionPresentation: SeenActionPresentation {
        SeenActionPresentation(status: request.informationalSeenStatus ?? .available)
    }

    private var seenActionIsComplete: Bool {
        localExample?.localSeenSelected == true || seenActionPresentation.isCompleted
    }

    private var seenActionIsPending: Bool {
        seenActionPresentation.isPending
    }

    private var seenActionColor: Color {
        if seenActionIsComplete { return seenColor }
        if seenActionIsPending { return detailColors.secondaryTextColor }
        return detailColors.textColor
    }

    private var seenActionSymbol: String {
        if seenActionIsComplete { return "checkmark" }
        if seenActionIsPending { return seenActionPresentation.symbolName ?? "clock" }
        return "eye"
    }

    private func activate(_ action: ProjectedAction) {
        withAnimation(.smooth(duration: 0.25), completionCriteria: .logicallyComplete) {
            if let localReplyDraftSession {
                localReplyDraftSession.selectAction(action.id, inputID: nil)
                onLocalReplyInteraction()
            } else {
                store.selectAction(action.id, input: nil, for: request.key,
                                   requestRevision: request.requestRevision)
            }
        } completion: {
            if action.kind == .text {
                openReplyEditor(ReplyEditorTarget(inputID: nil, actionID: action.id.rawValue))
            } else {
                closeReplyEditor()
            }
        }
    }

    @ViewBuilder
    private func compatibilityChoice(_ action: ProjectedAction,
                                     selected: Bool,
                                     detail: String,
                                     text: String) -> some View {
        let target = ReplyEditorTarget(inputID: nil, actionID: action.id.rawValue)
        let suggested = localExample?.message.options.first { $0.id == action.id.rawValue }.map {
            if case .suggested = $0.role { true } else { false }
        } ?? false
        ReplyChoiceCard(title: action.label.rawValue, detail: detail,
                        selected: selected, text: replyTextBinding(target),
                        focusedActionID: $focusedReplyActionID,
                        isEditing: activeReplyEditor == target,
                        multiple: false, suggested: suggested, ownAnswer: false,
                        style: action.style,
                        textColor: detailColors.textColor,
                        selectedColor: HarklightDesignSystem.palette(for: colorScheme).detail.selectedChoiceColor,
                        replySurface: HarklightDesignSystem.palette(for: colorScheme).detail.replyFieldColor,
                        inputSurface: ReplyInputSurfaceStyle.fill(for: colorScheme),
                        target: target, isReadOnly: readOnly,
                        onOpen: { activate(action) })
    }

    @ViewBuilder
    var body: some View {
        if hideAnswerControls {
            if request.informationalSeenStatus == nil {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(actions, id: \.id) { action in
                        Text(action.label.rawValue)
                    }
                }
            }
        } else if let seenStatus = request.informationalSeenStatus {
            VStack(alignment: .leading, spacing: 8) {
                Label("FYI", systemImage: "info.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(detailColors.secondaryTextColor)
                    .accessibilityIdentifier("request-seen-form-label")
                switch seenStatus {
                case .available, .pending, .confirmed:
                    Button {
                        guard seenStatus == .available, let action = actions.first else { return }
                        if let onSeen {
                            onSeen(action.id)
                        } else {
                            store.submitFromUser(request.key, explicitCompatibilityAction: action.id,
                                                 requestRevision: request.requestRevision)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: seenActionSymbol)
                                .foregroundStyle(seenActionColor)
                            if seenActionIsComplete {
                                Text("Seen").foregroundStyle(seenActionColor)
                            } else if seenActionIsPending {
                                Text(seenActionPresentation.title).foregroundStyle(seenActionColor)
                            } else {
                                Text(actions.first?.label.rawValue ?? "Seen")
                                    .foregroundStyle(seenActionColor)
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glass)
                    .tint(seenActionColor)
                    .disabled(sendDisabled || seenStatus != .available)
                    .opacity(seenActionIsComplete ? 0.76 : (sendDisabled ? 0.48 : 1))
                    .accessibilityLabel(Text(localExample?.localSeenSelected == true
                                             ? "Seen with green checkmark"
                                             : seenActionPresentation.accessibilityLabel))
                    .accessibilityValue(Text(localExample?.localSeenSelected == true
                                             ? "Completed"
                                             : seenActionPresentation.accessibilityValue))
                    .accessibilityIdentifier("request-seen-action")
                case .resolvedWithoutSeen:
                    Label("Resolved without Seen confirmation", systemImage: "checkmark.circle")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(actions, id: \.id) { action in
                    let option = localExample?.message.options.first { $0.id == action.id.rawValue }
                    let isSelected = selected == action.id
                    let compatibilityDraft: CompatibilityDraft? = readOnly
                        ? (request.submittedAnswer ?? request.draft).compatibility :
                        (localReplyDraftSession?.draft.compatibility ??
                         store.draft(for: request.key, revision: request.requestRevision)?.compatibility)
                    let replyText = compatibilityDraft?.textByActionID[action.id]?.rawValue ?? ""
                    if action.kind == .text && (isSelected || !replyText.isEmpty) {
                        compatibilityChoice(action, selected: isSelected, detail: option?.detail ?? "",
                                            text: replyText)
                    } else {
                        liveChoiceButton(style: action.style, perform: { activate(action) }) {
                            MessageChoiceLabel(title: action.label.rawValue,
                                    detail: option?.detail ?? "",
                                    selected: isSelected, multiple: false,
                                    suggested: option.map { if case .suggested = $0.role { true } else { false } } ?? false)
                        }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                        .disabled(readOnly)
                    }
                }
                if canOfferNoComment {
                    NoCommentChoiceRow(selected: noCommentSelected,
                                       unavailable: noCommentUnavailable,
                                       onSelect: onSelectNoComment)
                }
            }
        }
    }
}

private struct NoCommentChoiceRow: View {
    let selected: Bool
    let unavailable: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            MessageChoiceLabel(title: "No comment", detail: "",
                               selected: selected, multiple: false,
                               suggested: false)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(unavailable
            ? "This server did not accept No comment. Use the checkmark to retry, or choose another answer."
            : "Select No comment as your answer, then send it with the checkmark.")
        .accessibilityIdentifier("request-no-comment")
    }
}

struct LiveLifecycleTitle {
    let label: LocalizedStringResource

    init(_ status: AppLifecycleStatus) {
        switch status {
        case .open: label = "Open"
        case .pending: label = "Pending"
        case .answered: label = "Answered"
        case .noComment: label = "No comment"
        case .cleared: label = "Cleared"
        case .expired: label = "Expired"
        case .superseded: label = "Superseded"
        }
    }
}
