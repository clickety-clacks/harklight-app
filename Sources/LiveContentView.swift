import AttentionDomain
import SwiftUI
import UIKit

@MainActor
struct LiveContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    let store: LivePresentationStore
    let samples: SampleLibrary
    let launch: NativeAppLaunch?
    let archiveDeparture: NativeAccountDeparture?
    let fixtureStore: PrototypeStore?

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
        if let loadError = fixtureStore?.loadError {
            ContentUnavailableView(loadError, systemImage: "exclamationmark.triangle")
        } else {
            HarklightInbox(
                requests: store.inboxRows.map { row in
                    var row = row
                    if store.conversation(for: row.key) != nil { row.chatUnread = false }
                    return row
                }, samples: samples, selectRequest: { store.selectRequest($0) },
                markSeenRequest: { markSeen($0) },
                markNoCommentRequest: { store.submitNoCommentFromUser($0) },
                clearRetractedRequest: { store.clearRetracted($0) },
                requestDetail: { key, context in
                    if let request = store.request(for: key) {
                        LiveRequestDetail(request: request, store: store, context: context,
                                          fixtureStore: fixtureStore)
                    } else {
                        ContentUnavailableView("Request unavailable", systemImage: "questionmark.folder")
                    }
                },
                settingsContent: { LiveInboxSettings(store: store, samples: samples, launch: launch,
                                                      archiveDeparture: archiveDeparture,
                                                      connectionStatus: connectionStatus) },
                warnings: [launch?.notificationNavigationMessage, store.observationError, store.notificationWarning,
                           store.pushRegistrationWarning, store.unresolvedSendWarning,
                           launch?.archiveCatalogWarning,
                           launch?.disconnectedAccount?.removed == true ? nil : launch?.disconnectMessage,
                           fixtureStore?.persistenceError,
                           recoveryStatusFixture]
                    .compactMap { $0 },
                conversationStore: store,
                fetchOlderInboxPage: store.isReadOnly ? nil : { await store.fetchNextInboxPage() },
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
            .onChange(of: store.presentation.revision) { _, _ in
                fixtureStore?.refreshFromDurableStore()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { store.flushPendingDrafts() }
            }
        }
    }

    private func markSeen(_ key: RequestKey) {
        if let fixtureStore {
            guard fixtureStore.sendSelectedAnswer(for: key,
                                                   explicitCompatibilityAction: ExactText("seen")) else { return }
            try? store.refreshFromDurableStore()
        } else {
            store.submitFromUser(key, explicitCompatibilityAction: ExactText("seen"))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                if !initials.isEmpty {
                    Text(initials)
                        .font(.caption.bold())
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: Circle())
                }
                if let sender {
                    Text(sender).font(.subheadline)
                }
                Spacer(minLength: 0)
                if let createdAt {
                    Text(InboxFriendlyDate.label(for: createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let chatUnread {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(chatUnread ? .blue : .secondary)
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
    var localExample: SampleResponse? = nil
    var fixtureStore: PrototypeStore? = nil
    var noCommentUnavailableOverride: Bool? = nil
    private var showsNoCommentUnavailable: Bool {
        noCommentUnavailableOverride ?? request.noCommentUnavailable
    }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var deferred = false
    @State private var chatPresented = false
    @State private var enlargedPicture: SampleOption?
    @State private var fixtureOutcomePresented = false
    @State private var requestDetailsPresented = false
    @State private var answerSubmittedHere = false
    @FocusState private var focusedReplyActionID: String?

    private var controlsReadOnly: Bool {
        if let localExample {
            return store.isReadOnly || request.lifecycleStatus != .open ||
                request.intentReceipt != nil || store.isRetracted(request.key) || localExample.finished
        }
        return !canAnswer
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

    private func finishSeenAction() {
        if let localExample { localExample.finishLocally() }
        else if let availableSeenAction { submitSeenAction(availableSeenAction) }
    }

    private var seenActionIsComplete: Bool {
        localExample?.localSeenSelected == true ||
            request.informationalSeenStatus == .pending ||
            request.informationalSeenStatus == .confirmed
    }

    private var finishSeenButton: some View {
        Button(action: finishSeenAction) {
            if seenActionIsComplete {
                Label("Seen", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.green)
                    .font(.headline)
            } else {
                Image(systemName: "checkmark")
                    .font(.headline)
            }
        }
        .tint(seenActionIsComplete ? .green : .blue)
        .opacity(seenActionIsComplete ? 0.76 : (controlsReadOnly ? 0.48 : 1))
        .disabled(controlsReadOnly || !canFinishSeenAction || seenActionIsComplete)
        .accessibilityLabel(seenActionIsComplete ? "Seen with green checkmark" : "Mark as seen")
        .accessibilityValue(seenActionIsComplete ? "Completed" : "Available")
        .accessibilityIdentifier("request-finish-seen")
    }

    private var answerIsComplete: Bool {
        guard localExample == nil, request.informationalSeenStatus == nil,
              !store.isRetracted(request.key) else { return false }
        return Self.answerStatusIsComplete(lifecycleStatus: request.lifecycleStatus,
                                           ownOutcome: request.receiptFacts?.ownOutcome,
                                           answerNotDelivered: request.answerNotDelivered)
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

    private var submissionIsConfirmedAccepted: Bool {
        Self.submissionDismissesToList(ownOutcome: request.receiptFacts?.ownOutcome,
                                       answerNotDelivered: request.answerNotDelivered)
    }

    /// A checkmark submission returns the compact detail to the list only once
    /// the relay confirms acceptance. A pending or refused send must not
    /// dismiss as if it were done.
    static func submissionDismissesToList(ownOutcome: OwnOutcome?,
                                          answerNotDelivered: Bool) -> Bool {
        guard !answerNotDelivered else { return false }
        return ownOutcome == .accepted
    }

    private var answerStatusText: String? {
        guard let facts = request.receiptFacts else { return nil }
        return Self.answerStatusText(lifecycleStatus: request.lifecycleStatus,
                                     ownOutcome: facts.ownOutcome,
                                     answeredFromThisDevice: request.intentReceipt != nil)
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
            Label("Answered", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.green)
                .font(.headline)
        }
        .tint(.green)
        .opacity(0.76)
        .disabled(true)
        .accessibilityLabel("Answered with green checkmark")
        .accessibilityValue("Completed")
        .accessibilityIdentifier("request-answered")
    }

    private var noCommentSelected: Bool {
        localExample?.noCommentSelected ?? store.draft(for: request.key)?.noCommentSelected ?? false
    }

    private var canSubmitCurrentAnswer: Bool {
        if noCommentSelected { return canOfferNoComment }
        return canAnswer
    }

    private var canOfferNoComment: Bool {
        guard request.informationalSeenStatus == nil else { return false }
        if let localExample { return localExample.canDeclineLocally }
        if let fixtureStore { return fixtureStore.canSendNoCommentLocally(for: request.key) }
        guard request.inboxStateIsCurrent, !store.isReadOnly,
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
        focusedReplyActionID = nil
        store.selectNoComment(for: request.key)
    }

    private func submitSeenAction(_ action: ExactText) {
        if let localSeenAction {
            localSeenAction(action)
        } else {
            store.submitFromUser(request.key, explicitCompatibilityAction: action)
        }
    }

    var canAnswer: Bool {
        guard request.inboxStateIsCurrent, !store.isReadOnly, !store.isRetracted(request.key), request.lifecycleStatus == .open,
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
        if noCommentSelected && showsNoCommentUnavailable { return "Retry No comment" }
        if case let .sender(sender) = request.projection { return sender.submissionLabel.rawValue }
        return "Send answer"
    }

    var body: some View {
        MessageCardSurface(context: context,
            backgroundColor: Color(uiColor: .systemBackground)) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    requestDetailsPresented = true
                } label: {
                    MessageHeading(sender: localExample?.message.sender
                                   ?? InboxSenderDisplay.name(for: request.key.senderID.rawValue),
                               initials: localExample?.message.initials
                                   ?? String(InboxSenderDisplay.name(for: request.key.senderID.rawValue)
                                       .split(whereSeparator: { !$0.isLetter }).prefix(2).compactMap(\.first)).uppercased(),
                               title: request.title?.rawValue ?? "Message",
                               createdAt: request.createdAt,
                               symbol: localExample?.message.kind.symbol ?? (request.informationalSeenStatus == nil ? "text.bubble" : "info.circle"),
                               titleColor: localExample?.message.kind == .error
                                   ? Color(red: 0.70, green: 0, blue: 0.06)
                                   : localExample?.message.kind == .warning
                                       ? Color(red: 0.48, green: 0.30, blue: 0)
                                       : .primary,
                               chatUnread: conversationIndicator)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("request-heading")
                .accessibilityHint("Open request details")
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
                            .font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier(localExample.noCommentSelected
                                ? "request-local-no-comment-status"
                                : "request-local-answer-status")
                    } else if localExample.deferred {
                        HStack {
                            Label("Deferred locally", systemImage: "clock")
                            Spacer()
                            Button("Undo") { localExample.deferred = false }
                        }.font(.subheadline)
                    }
                }
                if let thread = store.conversation(for: request.key), thread.currentRevision > 1 {
                    Text(store.hasAcceptedUpdate(for: request.key) ? "Updated · version \(thread.currentRevision)" : "Question version \(thread.currentRevision)")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("request-update-fact")
                }
                if store.isRetracted(request.key) {
                    Text("The sender retracted this request. Saved work and its original delivery status are retained; no further answer will be sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if localExample == nil && deferred {
                    HStack {
                        Label("Not now", systemImage: "clock")
                        Spacer()
                        Button("Undo") { deferred = false }
                    }.font(.subheadline)
                }
                if let body = request.body {
                    if let noticeBodyColor {
                        Text(MessageTextLinks.attributed(body.rawValue))
                            .textSelection(.enabled)
                            .foregroundStyle(noticeTextColor)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(noticeBodyColor, in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        Text(MessageTextLinks.attributed(body.rawValue))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                                               focusedReplyActionID: $focusedReplyActionID,
                                               localExample: localExample,
                                               enlargePicture: { enlargedPicture = $0 })
                        if canOfferNoComment { noCommentChoice }
                    }
                case let .compatibility(actions):
                    LiveCompatibilityActions(request: request,
                                             actions: actions,
                                             store: store,
                                             readOnly: controlsReadOnly,
                                             localExample: localExample,
                                             onSeen: submitSeenAction,
                                             canOfferNoComment: canOfferNoComment,
                                             noCommentSelected: noCommentSelected,
                                             noCommentUnavailable: showsNoCommentUnavailable,
                                             onSelectNoComment: selectNoCommentAction,
                                             focusedReplyActionID: $focusedReplyActionID)
                case .unsupported:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("This request uses an unsupported answer format.")
                            .foregroundStyle(.secondary)
                        if canOfferNoComment { noCommentChoice }
                    }
                }
                if request.answerNotDelivered {
                    Label("Answer not delivered", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("request-answer-not-delivered")
                }
                if showsNoCommentUnavailable {
                    Text("No comment was not delivered: this server does not support it. Tap the checkmark to retry.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("request-no-comment-unavailable")
                }
                if request.inboxStateIsCurrent {
                    if store.isRetracted(request.key) {
                        Text(store.retractionLabel(request.key))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("request-lifecycle-status")
                    } else if request.lifecycleStatus != .open && request.lifecycleStatus != .answered {
                        Text(String(localized: LiveLifecycleTitle(request.lifecycleStatus).label))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("request-lifecycle-status")
                    }
                    if let seenStatus = request.informationalSeenStatus,
                       seenStatus != .available {
                        Label(Self.informationalSeenText(seenStatus),
                              systemImage: Self.informationalSeenSymbol(seenStatus))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("informational-seen-status")
                    }
                } else {
                    Label("Cached history · status not refreshed", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("inbox-status-unrefreshed")
                    if let localStatus = Self.cachedOperationStatus(request.intentReceipt?.localState) {
                        Text(localStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if localExample == nil && fixtureStore == nil && request.lifecycleStatus == .pending {
                    Button("Retry delivery") { store.retryPendingDelivery() }
                        .buttonStyle(.bordered)
                        .disabled(store.isReadOnly)
                }
                if let fixtureStore, request.lifecycleStatus == .pending {
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
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("request-receipt-evidence")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if request.informationalSeenStatus != nil {
                    if seenActionIsComplete {
                        finishSeenButton.buttonStyle(.plain)
                    } else {
                        finishSeenButton.buttonStyle(.glass)
                    }
                } else if let localExample {
                    Button("Finish locally", systemImage: "checkmark") {
                        localExample.finishLocally()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .disabled(!localExample.canFinishLocally || localExample.finished)
                    .accessibilityIdentifier("sample-finish")
                } else if answerIsComplete {
                    answeredStatusButton.buttonStyle(.plain)
                } else {
                    Button(submitLabel, systemImage: "checkmark") {
                        if let fixtureStore {
                            let sent = store.draft(for: request.key)?.noCommentSelected == true
                                ? fixtureStore.sendNoCommentLocally(for: request.key)
                                : fixtureStore.sendSelectedAnswer(for: request.key)
                            guard sent else { return }
                            answerSubmittedHere = true
                            try? store.refreshFromDurableStore()
                        } else {
                            guard store.submitFromUser(request.key) else { return }
                            answerSubmittedHere = true
                        }
                    }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glassProminent)
                        .disabled(fixtureStore.map { !$0.canSend(for: request.key) } ?? !canSubmitCurrentAnswer)
                        .accessibilityIdentifier("request-finish")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .phone {
                    if context.openChat == nil {
                        chatButton.popover(isPresented: $chatPresented, arrowEdge: .bottom) {
                            conversationPanel.frame(idealWidth: 380, idealHeight: 560)
                        }
                    } else {
                        chatButton
                    }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if horizontalSizeClass == .compact {
                    Spacer()
                    compactBottomControls
                    Spacer()
                } else {
                Button("Later", systemImage: "clock") {
                    if let localExample { localExample.deferred.toggle() }
                    else { deferred.toggle() }
                }
                .labelStyle(.iconOnly)
                .disabled(store.isReadOnly || store.isRetracted(request.key) || localExample?.finished == true)
                Spacer()
                if horizontalSizeClass != .regular || UIDevice.current.userInterfaceIdiom != .phone {
                    if context.openChat != nil || context.canInlineChat {
                        chatButton
                    } else if horizontalSizeClass == .compact {
                        chatButton.sheet(isPresented: $chatPresented) {
                            conversationPanel
                                .presentationDetents([.medium, .large])
                        }
                    } else if UIDevice.current.userInterfaceIdiom != .phone {
                        chatButton.popover(isPresented: $chatPresented, arrowEdge: .bottom) {
                            conversationPanel.frame(idealWidth: 380, idealHeight: 560)
                        }
                    }
                }
                }
            }
        }
        .toolbar(focusedReplyActionID == nil ? .visible : .hidden, for: .bottomBar)
        .onChange(of: submissionIsConfirmedAccepted) { _, confirmed in
            guard confirmed, answerSubmittedHere, horizontalSizeClass == .compact else { return }
            context.dismissToList?()
        }
        .sheet(item: $enlargedPicture) { picture in
            SamplePictureViewer(initialPicture: picture)
        }
        .sheet(isPresented: $requestDetailsPresented) {
            requestDetailsSheet
        }
        .onChange(of: context.inlineChat) { _, inline in
            if inline { chatPresented = false }
        }
    }

    private var chatButton: some View {
        Button("Chat", systemImage: "bubble.left.and.bubble.right") {
            localExample?.chatRead = true
            if let openChat = context.openChat { openChat() }
            else { chatPresented = true }
        }
        .labelStyle(.iconOnly)
    }

    private var requestDetailsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Sender: \(request.key.senderID.rawValue)")
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

    private var compactBottomControls: some View {
        HStack(spacing: 0) {
            Button("Later", systemImage: "clock") {
                if let localExample { localExample.deferred.toggle() }
                else { deferred.toggle() }
            }
            .labelStyle(.iconOnly)
            .frame(width: 58, height: 52)
            .disabled(store.isReadOnly || store.isRetracted(request.key) || localExample?.finished == true)

            if context.openChat != nil || context.canInlineChat {
                chatButton.frame(width: 58, height: 52)
            } else {
                chatButton
                    .frame(width: 58, height: 52)
                    .sheet(isPresented: $chatPresented) {
                        conversationPanel.presentationDetents([.medium, .large])
                    }
            }
        }
    }

    private var noticeBodyColor: Color? {
        switch localExample?.message.kind {
        case .some(.error): Color(red: 1, green: 0.89, blue: 0.88)
        case .some(.warning): Color(red: 1, green: 0.95, blue: 0.80)
        case .some(.information): informationBodyColor
        case .some(.completed): Color(red: 0.89, green: 0.96, blue: 0.90)
        default: request.informationalSeenStatus == nil ? nil : informationBodyColor
        }
    }

    private var informationBodyColor: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground)
            : Color(red: 0.89, green: 0.94, blue: 1)
    }

    private var conversationIndicator: Bool? {
        if let localExample {
            return localExample.message.hasChat
                ? localExample.message.chatUnread && !localExample.chatRead : nil
        }
        return store.conversation(for: request.key) == nil ? nil : store.hasUnreadAgentReply(request.key)
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
        NavigationStack {
            ConversationPanel(store: store, key: request.key,
                sender: request.key.senderID.rawValue, title: request.title?.rawValue ?? "")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { chatPresented = false }.labelStyle(.iconOnly)
                    }
                }
        }
    }

    static func informationalSeenText(_ status: InformationalSeenStatus) -> String {
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
                                       focusedReplyActionID: $focusedReplyActionID)
            case let .compatibility(actions):
                LiveCompatibilityActions(request: request, actions: actions, store: store,
                                         readOnly: true,
                                         focusedReplyActionID: $focusedReplyActionID)
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
    @FocusState.Binding var focusedReplyActionID: String?
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
                                       readOnly: readOnly,
                                       localExample: localExample,
                                       enlargePicture: enlargePicture,
                                       focusedReplyActionID: $focusedReplyActionID)
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
                               node: child, store: store, readOnly: readOnly,
                               focusedReplyActionID: $focusedReplyActionID,
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
    var localExample: SampleResponse? = nil
    var enlargePicture: (SampleOption) -> Void = { _ in }
    @State private var pointGestureCapture = PointGestureCapture()
    @State private var typedInputText: String?
    @State private var replyEditorTexts: [ExactText: String] = [:]
    @GestureState private var pointGestureActive = false
    @FocusState.Binding var focusedReplyActionID: String?
    @Environment(\.colorScheme) private var colorScheme

    private var draft: InputDraft? {
        readOnly ? request.draft.inputs[input.id] : store.draft(for: request.key)?.inputs[input.id]
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { typedInputText ?? draft?.text?.rawValue ?? "" },
            set: {
                typedInputText = $0
                store.stageText($0, input: input.id, action: nil, for: request.key)
            }
        )
    }

    private var textEditor: some View {
        TextField(input.label.rawValue, text: textBinding, axis: .vertical)
            .lineLimit(4...8)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(input.label.rawValue)
            .accessibilityIdentifier("request-input-" + input.id.rawValue)
            .disabled(readOnly)
    }

    private var replyEditorSurface: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground)
            : Color(red: 0.96, green: 0.975, blue: 1)
    }

    private func activate(_ action: ProjectedAction) {
        withAnimation(.smooth(duration: 0.25), completionCriteria: .logicallyComplete) {
            if let localExample, action.id.rawValue == "own" {
                if localExample.message.kind == .multipleChoice {
                    localExample.choices = []
                }
                localExample.ownAnswer = true
            } else {
                store.selectAction(action.id, input: input.id, for: request.key)
            }
        } completion: {
            focusedReplyActionID = action.kind == .text ? action.id.rawValue : nil
        }
    }

    @ViewBuilder
    private func inlineReplyAction(_ action: ProjectedAction,
                                   selected: Bool,
                                   text: String) -> some View {
        let detail = localExample != nil && action.id.rawValue == "own"
            ? "Write it here, or say why none of these fit."
            : ""
        let cardShape = RoundedRectangle(cornerRadius: 16)
        let card = VStack(spacing: 0) {
            MessageChoiceLabel(title: action.label.rawValue, detail: detail,
                               selected: selected, multiple: false, suggested: false,
                               ownAnswer: action.id.rawValue == "own", drawsSurface: false)
            TextEditor(text: Binding(
                get: { replyEditorTexts[action.id] ?? draft?.textByActionID[action.id]?.rawValue ?? text },
                set: {
                    replyEditorTexts[action.id] = $0
                    store.stageText($0, input: input.id, action: action.id, for: request.key)
                }
            ))
            .font(.body)
            .foregroundStyle(.primary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120)
            .padding(8)
            .background(replyEditorSurface)
            .focused($focusedReplyActionID, equals: action.id.rawValue)
            .accessibilityLabel(action.label.rawValue)
            .accessibilityIdentifier("request-input-" + input.id.rawValue + "-response")
            .disabled(readOnly || !selected)
        }
        .background(selected ? Color.blue : Color(uiColor: .secondarySystemBackground), in: cardShape)
        .overlay(cardShape.strokeBorder(selected ? Color.blue : Color(uiColor: .separator), lineWidth: 1.5))
        .clipShape(cardShape)
        .opacity(selected ? 1 : 0.55)
        .animation(.smooth(duration: 0.25), value: selected)

        if selected {
            card
        } else {
            Button { activate(action) } label: { card }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .disabled(readOnly)
        }
    }

    var body: some View {
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
                                                 point: draft?.effectivePoint)
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
                                                    store.setPoint(point, input: input.id, for: request.key)
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
                                store.setPoint(PointValue(x: 500, y: 500), input: input.id, for: request.key)
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

    @ViewBuilder
    private func actionButton(_ action: ProjectedAction) -> some View {
        let selected = draft?.selectedActionID == action.id
        let replyText = draft?.textByActionID[action.id]?.rawValue ?? ""
        if action.kind == .text && (selected || !replyText.isEmpty) {
            inlineReplyAction(action, selected: selected, text: replyText)
        } else if let localExample,
           let option = localExample.message.options.first(where: { $0.id == action.id.rawValue }) {
            SampleChoiceRow(option: option, selected: selected,
                            multiple: false,
                            swatch: localExample.message.kind == .colorChoice ? option.id : nil,
                            sound: localExample.message.kind == .soundChoice) {
                store.selectAction(action.id, input: input.id, for: request.key)
            }
            .disabled(readOnly)
        } else {
            Button {
                activate(action)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    if let artID = action.illustrationID,
                       let illustration = sender.illustrations.first(where: { $0.id == artID }) {
                        SenderIllustrationCanvas(illustration: illustration, point: nil)
                    }
                    let detail = localExample != nil && action.id.rawValue == "own"
                        ? "Write it here, or say why none of these fit."
                        : ""
                    MessageChoiceLabel(title: action.label.rawValue, detail: detail,
                                       selected: selected, multiple: false, suggested: false,
                                       ownAnswer: action.id.rawValue == "own")
                }
            }
            .buttonStyle(.plain)
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
    var localExample: SampleResponse? = nil
    var onSeen: ((ExactText) -> Void)? = nil
    var canOfferNoComment = false
    var noCommentSelected = false
    var noCommentUnavailable = false
    var onSelectNoComment: () -> Void = {}
    @State private var replyTextByActionID: [ExactText: String] = [:]
    @FocusState.Binding var focusedReplyActionID: String?
    @Environment(\.colorScheme) private var colorScheme

    private var selected: ExactText? {
        readOnly ? request.draft.compatibility.selectedActionID : store.draft(for: request.key)?.compatibility.selectedActionID
    }

    private var seenActionIsComplete: Bool {
        localExample?.localSeenSelected == true ||
            request.informationalSeenStatus == .pending ||
            request.informationalSeenStatus == .confirmed
    }

    private var replyEditorSurface: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground)
            : Color(red: 0.96, green: 0.975, blue: 1)
    }

    private func activate(_ action: ProjectedAction) {
        withAnimation(.smooth(duration: 0.25), completionCriteria: .logicallyComplete) {
            store.selectAction(action.id, input: nil, for: request.key)
        } completion: {
            focusedReplyActionID = action.kind == .text ? action.id.rawValue : nil
        }
    }

    @ViewBuilder
    private func compatibilityChoice(_ action: ProjectedAction,
                                     selected: Bool,
                                     detail: String,
                                     text: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        let card = VStack(spacing: 0) {
            MessageChoiceLabel(title: action.label.rawValue, detail: detail,
                               selected: selected, multiple: false, suggested: false,
                               drawsSurface: false)
            TextEditor(text: Binding(
                get: {
                    replyTextByActionID[action.id] ??
                        (readOnly ? request.draft.compatibility : store.draft(for: request.key)?.compatibility)?
                            .textByActionID[action.id]?.rawValue ?? text
                },
                set: {
                    replyTextByActionID[action.id] = $0
                    store.stageCompatibilityText($0, action: action.id, for: request.key)
                }
            ))
            .font(.body)
            .foregroundStyle(.primary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120)
            .padding(8)
            .background(replyEditorSurface)
            .focused($focusedReplyActionID, equals: action.id.rawValue)
            .accessibilityLabel(action.label.rawValue)
            .accessibilityIdentifier("request-compatibility-" + action.id.rawValue + "-response")
            .disabled(readOnly || !selected)
        }
        .background(selected ? Color.blue : Color(uiColor: .secondarySystemBackground), in: shape)
        .overlay(shape.strokeBorder(selected ? Color.blue : Color(uiColor: .separator), lineWidth: 1.5))
        .clipShape(shape)
        .opacity(selected ? 1 : 0.55)
        .animation(.smooth(duration: 0.25), value: selected)

        if selected {
            card
        } else {
            Button { activate(action) } label: { card }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .disabled(readOnly)
        }
    }

    @ViewBuilder
    var body: some View {
        if let seenStatus = request.informationalSeenStatus {
            switch seenStatus {
            case .available, .pending, .confirmed:
                Button {
                    guard seenStatus == .available, let action = actions.first else { return }
                    if let onSeen {
                        onSeen(action.id)
                    } else {
                        store.submitFromUser(request.key, explicitCompatibilityAction: action.id)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: seenActionIsComplete ? "checkmark" : "eye")
                            .foregroundStyle(seenActionIsComplete ? Color.green : Color.blue)
                        Text(seenActionIsComplete ? "Seen" : (actions.first?.label.rawValue ?? "Seen"))
                            .foregroundStyle(seenActionIsComplete ? Color.green : Color.primary)
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
                .disabled(readOnly || seenStatus != .available)
                .opacity(seenActionIsComplete ? 0.76 : (readOnly ? 0.48 : 1))
                .accessibilityIdentifier("request-seen-action")
            case .resolvedWithoutSeen:
                Label("Resolved without Seen confirmation", systemImage: "checkmark.circle")
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(actions, id: \.id) { action in
                    let option = localExample?.message.options.first { $0.id == action.id.rawValue }
                    let isSelected = selected == action.id
                    let replyText = replyTextByActionID[action.id] ??
                        (readOnly ? request.draft.compatibility : store.draft(for: request.key)?.compatibility)?
                            .textByActionID[action.id]?.rawValue ?? ""
                    if action.kind == .text && (isSelected || !replyText.isEmpty) {
                        compatibilityChoice(action, selected: isSelected, detail: option?.detail ?? "",
                                            text: replyText)
                    } else {
                        Button { activate(action) } label: {
                            MessageChoiceLabel(title: action.label.rawValue,
                                    detail: option?.detail ?? "",
                                    selected: isSelected, multiple: false,
                                    suggested: option.map { if case .suggested = $0.role { true } else { false } } ?? false,
                                    selectionColor: option.map { if case .destructive = $0.role { .red } else { .blue } } ?? .blue)
                        }
                        .buttonStyle(.plain)
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
