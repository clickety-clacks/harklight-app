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

enum AnswerConfirmationText {
    static func formatted(accountAnswerOutcome: AccountAnswerOutcome?,
                         submittedAnswer: RequestDraft?,
                         projection: AdmittedRequestProjection,
                         defaultAnswerAction: ProjectedActionReference? = nil) -> String? {
        switch accountAnswerOutcome {
        case let .some(.reply(text)):
            if !text.rawValue.isEmpty { return text.rawValue }
        case let .some(.defaultAnswer(_, text)):
            if let text, !text.rawValue.isEmpty { return text.rawValue }
            if let defaultAnswerAction,
               let action = projectedAction(defaultAnswerAction, in: projection) {
                return action.label.rawValue
            }
            return nil
        case .some(.noComment), .some(.seen):
            return nil
        case .none:
            break
        }

        guard let submittedAnswer, !submittedAnswer.noCommentSelected else { return nil }
        return formatted(submittedAnswer, projection: projection)
    }

    private static func formatted(_ answer: RequestDraft,
                                  projection: AdmittedRequestProjection) -> String? {
        switch projection {
        case let .compatibility(actions):
            return actionText(answer.compatibility.selectedActionID,
                              textByActionID: answer.compatibility.textByActionID,
                              actions: actions)
        case let .sender(sender):
            var lines: [String] = []
            for input in sender.inputs {
                guard let draft = answer.inputs[input.id] else { continue }
                let value: String?
                var includeInputLabel = true
                switch input.kind {
                case let .response(actions):
                    value = actionText(draft.selectedActionID,
                                       textByActionID: draft.textByActionID,
                                       actions: actions)
                case .text:
                    value = draft.text?.rawValue.isEmpty == false ? draft.text?.rawValue : nil
                case .point:
                    guard let point = draft.effectivePoint else { continue }
                    let coordinates = "Horizontal \(point.x), vertical \(point.y)"
                    if let label = pointResultLabel(in: sender.scene, matching: point) {
                        value = "\(label)\n\(coordinates)"
                        includeInputLabel = false
                    } else {
                        value = coordinates
                    }
                }
                guard let value else { continue }
                if sender.inputs.count > 1 && input.label.rawValue != "Response" && includeInputLabel {
                    lines.append("\(input.label.rawValue)\n\(value)")
                } else {
                    lines.append(value)
                }
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        case .unsupported:
            return nil
        }
    }

    private static func actionText(_ selectedActionID: ExactText?,
                                   textByActionID: [ExactText: ExactText],
                                   actions: [ProjectedAction]) -> String? {
        if let selectedActionID,
           let action = actions.first(where: { $0.id == selectedActionID }) {
            if action.kind == .text,
               let text = textByActionID[selectedActionID], !text.rawValue.isEmpty {
                return text.rawValue
            }
            return action.label.rawValue
        }
        for action in actions where action.kind == .text {
            if let text = textByActionID[action.id], !text.rawValue.isEmpty {
                return text.rawValue
            }
        }
        return nil
    }

    private static func projectedAction(_ reference: ProjectedActionReference,
                                        in projection: AdmittedRequestProjection) -> ProjectedAction? {
        switch projection {
        case let .compatibility(actions) where reference.inputID == nil:
            return actions.first { $0.id == reference.actionID }
        case let .sender(sender):
            guard let inputID = reference.inputID,
                  let input = sender.inputs.first(where: { $0.id == inputID }),
                  case let .response(actions) = input.kind else { return nil }
            return actions.first { $0.id == reference.actionID }
        case .compatibility, .unsupported:
            return nil
        }
    }

    private static func pointResultLabel(in node: ProjectedSceneNode,
                                         matching point: PointValue) -> String? {
        switch node.kind {
        case let .resultPoint(_, label, result) where result == point:
            return label.rawValue
        case let .stack(_, children), let .grid(_, children):
            for child in children {
                if let label = pointResultLabel(in: child, matching: point) { return label }
            }
            return nil
        default:
            return nil
        }
    }
}

private struct AnswerConfirmationCard: View {
    let title: LocalizedStringResource
    let answer: String?
    let identifier: String
    let accessibilityValue: LocalizedStringResource
    let symbolName: String?
    var answerIdentifier: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    private var appearance: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private var messageColors: HarklightDesignSource.MessageType {
        appearance.messageType(messageType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.headline.weight(.semibold))
                }
                Text(title).font(.headline.weight(.semibold))
            }
            .foregroundStyle(messageColors.textColor)

            if let answer, !answer.isEmpty {
                Text(answer)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 28)
                    .foregroundStyle(messageColors.textColor)
                    .accessibilityIdentifier(answerIdentifier ?? "\(identifier)-answer")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(appearance.detail.selectedChoiceColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(messageColors.textColor, lineWidth: 1.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(Text(accessibilityValue))
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
    var testNotificationNavigation: NativeInboxNavigation? = nil
    var testNotificationRouter: NativeNotificationRouter? = nil
    var testOpenForegroundChatIndicator: (() -> Void)? = nil
    var testConversationSheetDidAppear: (() -> Void)? = nil
    var testNotificationChatRouteDidOpen: ((UInt64) -> Void)? = nil
    @State private var replyEditorFocused = false
#if DEBUG
    @State private var didApplyPresentationTestFixture = false
#endif

    init(store: LivePresentationStore,
         samples: SampleLibrary,
         launch: NativeAppLaunch? = nil,
         archiveDeparture: NativeAccountDeparture? = nil,
         fixtureStore: PrototypeStore? = nil,
         testNotificationNavigation: NativeInboxNavigation? = nil,
         testNotificationRouter: NativeNotificationRouter? = nil,
         testOpenForegroundChatIndicator: (() -> Void)? = nil,
         testConversationSheetDidAppear: (() -> Void)? = nil,
         testNotificationChatRouteDidOpen: ((UInt64) -> Void)? = nil) {
        self.store = store
        self.samples = samples
        self.launch = launch
        self.archiveDeparture = archiveDeparture
        self.fixtureStore = fixtureStore
        self.testNotificationNavigation = testNotificationNavigation
        self.testNotificationRouter = testNotificationRouter
        self.testOpenForegroundChatIndicator = testOpenForegroundChatIndicator
        self.testConversationSheetDidAppear = testConversationSheetDidAppear
        self.testNotificationChatRouteDidOpen = testNotificationChatRouteDidOpen
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

    private var inboxRefreshAction: (@MainActor () async -> Void)? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--harklight-test-list-refresh") {
            return { await refreshListForTesting() }
        }
        #endif
        guard let launch, !store.isReadOnly, !store.isLocalExample else { return nil }
        return { await launch.refreshLive() }
    }

    #if DEBUG
    private func refreshListForTesting() async {
        store.beginRefresh()
        defer { store.endRefresh() }
        try? await Task.sleep(for: .seconds(4))
        store.connectionWarning = "The approved server could not be reached."
    }
    #endif

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
                            fixtureStore: fixtureStore,
                            testNotificationRouter: testNotificationRouter,
                            testOpenForegroundChatIndicator: testOpenForegroundChatIndicator,
                            testConversationSheetDidAppear: testConversationSheetDidAppear)
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
                refreshInbox: inboxRefreshAction,
                showsLocalExamples: showsSampleMessages && !store.isReadOnly,
                notificationNavigation: testNotificationNavigation ?? launch?.notificationNavigation,
                notificationChatRouteDidOpen: { serial in
                    if let testNotificationChatRouteDidOpen {
                        testNotificationChatRouteDidOpen(serial)
                    } else {
                        launch?.notificationChatRouteWasOpened(serial: serial)
                    }
                },
                testNotificationRouter: testNotificationRouter,
                testOpenForegroundChatIndicator: testOpenForegroundChatIndicator)
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
                if phase == .active { refreshRetractionVisibilityForSceneActivation() }
                if phase == .background { store.flushPendingDrafts() }
            }
            .onPreferenceChange(ReplyEditorFocusKey.self) { replyEditorFocused = $0 }
            .onAppear { applyPresentationTestFixtureIfNeeded() }
            .task(id: store.nextRetractionExpiry) {
                await store.waitForNextRetractionExpiry()
            }
#if DEBUG
            .overlay(alignment: .top) {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--harklight-test-server-retraction") ||
                    arguments.contains("--harklight-test-retraction-expiry-after-deadline") {
                    VStack(spacing: 8) {
                        if let status = fixtureStore?.serverRetractionTestStatus {
                            Text(status)
                                .font(.caption)
                                .accessibilityIdentifier("server-retraction-persistence-readback")
                        }
                        if arguments.contains("--harklight-test-server-retraction") {
                            Button("Advance retraction expiry clock") {
                                store.advanceRetractionExpiryForTesting()
                            }
                            .accessibilityIdentifier("advance-server-retraction-expiry")
                        }
                    }
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
#endif
        }
    }

    private func refreshRetractionVisibilityForSceneActivation() {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--harklight-test-retraction-expiry-after-deadline") {
            return
        }
#endif
        store.refreshRetractionVisibility()
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
                Text(MessageMarkdown.attributed(title))
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
                    currentBuildIdentifier: HarklightReleaseNotes.currentBuildIdentifier(),
                    entries: HarklightReleaseNotes.numberedEntries(
                        currentBuildIdentifier: HarklightReleaseNotes.currentBuildIdentifier())))
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") { dismiss() }.labelStyle(.iconOnly)
            } }
        }
    }
}

@MainActor
private struct ReplacedByMessagesSection: View {
    let replacementKeys: [RequestKey]
    let secondaryTextColor: Color

    private var orderedReplacementKeys: [RequestKey] {
        replacementKeys.sorted {
            if $0.senderID.rawValue != $1.senderID.rawValue {
                return $0.senderID.rawValue < $1.senderID.rawValue
            }
            return $0.messageID.rawValue < $1.messageID.rawValue
        }
    }

    var body: some View {
        if !replacementKeys.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Replaced by")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondaryTextColor)
                ForEach(orderedReplacementKeys, id: \.self) { replacementKey in
                    NavigationLink(value: RelatedMessageTarget.replacement(replacementKey)) {
                        Text(replacementKey.messageID.rawValue)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                    .accessibilityIdentifier("request-replaced-by-" + replacementKey.messageID.rawValue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
    var testNotificationRouter: NativeNotificationRouter? = nil
    var testOpenForegroundChatIndicator: (() -> Void)? = nil
    var testConversationSheetDidAppear: (() -> Void)? = nil
    private var showsNoCommentUnavailable: Bool {
        noCommentUnavailableOverride ?? request.noCommentUnavailable
    }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var chatPresented = false
    @State private var pendingChatScrollTarget: ExactText?
    @State private var enlargedPicture: SampleOption?
    @State private var fixtureOutcomePresented = false
    @State private var requestDetailsPresented = false
    @State private var warningDialog: WarningDialogKind?
    @State private var activeReplyEditor: ReplyEditorTarget?
    @State private var replyDraftSession: ReplyEditorDraftSession?
    @State private var localReplyEditingActive = false
    @State private var storePresentationSnapshot: StorePresentationSnapshot
    @FocusState private var focusedReplyActionID: String?

    private enum WarningDialogKind: String, Equatable, Identifiable {
        case failedResponse
        case skippedMessage

        var id: String { rawValue }
    }

    init(request: PresentedRequest,
         store: LivePresentationStore,
         context: InboxCardContext = .standalone,
         localExample: SampleResponse? = nil,
         fixtureStore: PrototypeStore? = nil,
         noCommentUnavailableOverride: Bool? = nil,
         testNotificationRouter: NativeNotificationRouter? = nil,
         testOpenForegroundChatIndicator: (() -> Void)? = nil,
         testConversationSheetDidAppear: (() -> Void)? = nil) {
        self.request = request
        self.store = store
        self.context = context
        self.localExample = localExample
        self.fixtureStore = fixtureStore
        self.noCommentUnavailableOverride = noCommentUnavailableOverride
        self.testNotificationRouter = testNotificationRouter
        self.testOpenForegroundChatIndicator = testOpenForegroundChatIndicator
        self.testConversationSheetDidAppear = testConversationSheetDidAppear
        _storePresentationSnapshot = State(initialValue: Self.storePresentationSnapshot(
            request: request, store: store))
        let canSubmit = localExample == nil &&
            Self.canEditSnapshot(request: request, store: store, context: context)
        if canSubmit {
            _replyDraftSession = State(initialValue: store.replyEditorSession(for: request))
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

    private var failedResponseWarning: LivePresentationStore.FailedResponseWarning? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--harklight-test-copy-dialog"),
           request.key.messageID.rawValue == "facilities-01" {
            return LivePresentationStore.FailedResponseWarning(
                requestRevision: request.requestRevision,
                failedOperationID: nil,
                answerKind: .answer,
                submittedInputs: [],
                answerDraft: nil,
                detail: "A generated response was rejected for this test.",
                retryOperationID: nil)
        }
#endif
        guard localExample == nil, fixtureStore == nil,
              request.informationalSeenStatus == nil else { return nil }
        return store.failedResponseWarning(for: request.key, revision: request.requestRevision)
    }

    private var skippedMessageWarning: LivePresentationStore.SkippedMessageWarning? {
        guard localExample == nil, fixtureStore == nil else { return nil }
        return store.skippedMessageWarning(for: request.key)
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
        guard let session = localReplySession, session.canSubmitFromSnapshot else { return false }
        // The view's focus flag resets on navigation; the retained draft does not.
        return localReplyEditingActive || session.hasLocalChanges
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

    private var showsAnsweredConfirmation: Bool {
        answerIsComplete && !isSupersedesReadOnly
    }

    static func answeredConfirmationTitle(isDefaultAnswered: Bool) -> LocalizedStringResource {
        isDefaultAnswered ? "Answered by default" : "Answered"
    }

    private var showsNoCommentConfirmation: Bool {
        Self.showsNoCommentConfirmation(lifecycleStatus: request.lifecycleStatus,
                                       isSupersedesReadOnly: isSupersedesReadOnly)
    }

    static func showsNoCommentConfirmation(lifecycleStatus: AppLifecycleStatus,
                                           isSupersedesReadOnly: Bool) -> Bool {
        lifecycleStatus == .noComment && !isSupersedesReadOnly
    }

    private var showsPendingAnswerConfirmation: Bool {
        request.inboxStateIsCurrent &&
            !isSupersedesReadOnly && !storePresentationSnapshot.isRetracted &&
            request.lifecycleStatus == .pending && request.receiptFacts?.ownOutcome == .unconfirmed
    }

    private var showsNotAcceptedConfirmation: Bool {
        Self.shouldShowNotAcceptedConfirmation(
            isRetracted: storePresentationSnapshot.isRetracted,
            isSupersedesReadOnly: isSupersedesReadOnly,
            ownOutcome: request.receiptFacts?.ownOutcome,
            relayOutcome: request.intentReceipt?.relayOutcome,
            attemptedAnswerText: attemptedAnswerText,
            ownAnswerWasRefusedByRetraction: request.ownAnswerWasRefusedByRetraction)
    }

    static func shouldShowNotAcceptedConfirmation(isRetracted: Bool,
                                                  isSupersedesReadOnly: Bool,
                                                  ownOutcome: OwnOutcome?,
                                                  relayOutcome: RelayOutcome?,
                                                  attemptedAnswerText: String?,
                                                  ownAnswerWasRefusedByRetraction: Bool = false) -> Bool {
        guard isRetracted, !isSupersedesReadOnly,
              let attemptedAnswerText, !attemptedAnswerText.isEmpty else { return false }
        if ownAnswerWasRefusedByRetraction { return true }
        if ownOutcome == .refused { return true }
        if let relayOutcome, case .refusedByRetraction = relayOutcome { return true }
        return false
    }

    private var confirmedAnswerText: String? {
        AnswerConfirmationText.formatted(
            accountAnswerOutcome: request.accountAnswerOutcome,
            submittedAnswer: request.receiptFacts?.ownOutcome == .accepted ? request.submittedAnswer : nil,
            projection: request.projection,
            defaultAnswerAction: request.defaultAnswerAction)
    }

    private var pendingAnswerText: String? { nil }

    private var attemptedAnswerText: String? {
        AnswerConfirmationText.formatted(accountAnswerOutcome: nil,
            submittedAnswer: request.submittedAnswer,
            projection: request.projection)
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
        if let receipt = request.intentReceipt,
           store.isSendingAnswer(receipt.intentID) { return "Sending" }
        return Self.answerStatusText(lifecycleStatus: request.lifecycleStatus,
                                     ownOutcome: request.receiptFacts?.ownOutcome,
                                     answeredFromThisDevice: request.intentReceipt != nil,
                                     localState: request.intentReceipt?.localState,
                                     answerNotDelivered: request.answerNotDelivered)
    }

    private var byWhenDate: Date? {
        guard let milliseconds = request.byWhenMilliseconds else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    /// Plain-language send status for the content area. Internal evidence
    /// wording stays in the request details sheet.
    static func answerStatusText(lifecycleStatus: AppLifecycleStatus,
                                 ownOutcome: OwnOutcome?,
                                 answeredFromThisDevice: Bool,
                                 localState: LocalIntentState? = nil,
                                 answerNotDelivered: Bool = false) -> String? {
        if answerNotDelivered || localState == .notDelivered { return "Answer not delivered" }
        if localState == .terminalUnconfirmed ||
            (ownOutcome == .unconfirmed && answeredFromThisDevice) {
            return "Submission unconfirmed · saved draft retained"
        }
        if (localState.map { if case .accepted = $0 { true } else { false } } == true ||
            ownOutcome == .accepted) && lifecycleStatus != .answered && lifecycleStatus != .noComment {
            return "Answer accepted"
        }
        if ownOutcome == .refused {
            return "The sender retracted this request before your answer was accepted. The answer was not accepted."
        }
        return nil
    }

    private var failedResponseWarningButton: some View {
        Button {
            warningDialog = .failedResponse
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .labelStyle(.iconOnly)
        .tint(.red)
        .accessibilityLabel("Response not delivered")
        .accessibilityHint("View the delivery details and retry the same response")
        .accessibilityIdentifier("request-delivery-warning")
    }

    private var skippedMessageWarningButton: some View {
        Button {
            warningDialog = .skippedMessage
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .labelStyle(.iconOnly)
        .tint(.red)
        .accessibilityLabel("Message could not be loaded and was skipped")
        .accessibilityHint("View the safe diagnostic details")
        .accessibilityIdentifier("request-message-load-warning")
    }

    private var noCommentSelected: Bool {
        if let localReplySession { return localReplySession.noCommentSelected }
        return localExample?.noCommentSelected
            ?? request.submittedAnswer?.noCommentSelected
            ?? request.draft.noCommentSelected
    }

    private var canSubmitCurrentAnswer: Bool {
        let locallyValid: Bool
        if let session = localReplySession {
            locallyValid = session.noCommentSelected
                ? session.canSubmitFromSnapshot && request.informationalSeenStatus == nil
                : session.canSubmitFromSnapshot
        } else if noCommentSelected {
            locallyValid = canOfferNoComment
        } else {
            locallyValid = canAnswer
        }
        guard locallyValid else { return false }
        if localExample != nil || fixtureStore != nil { return true }
        return store.canSendToCurrentServer && request.inboxStateIsCurrent
    }

    private var canOfferNoComment: Bool {
        guard !isSupersedesReadOnly, request.informationalSeenStatus == nil else { return false }
        if let localReplySession { return localReplySession.canSubmitFromSnapshot }
        if let localExample { return localExample.canDeclineLocally }
        if let fixtureStore { return fixtureStore.canSendNoCommentLocally(for: request.key) }
        guard !store.isReadOnly, store.canSendToCurrentServer,
              request.inboxStateIsCurrent,
              !store.isRetracted(request.key), request.lifecycleStatus == .open,
              request.intentReceipt == nil else { return false }
        return true
    }

    private var noCommentChoice: some View {
        NoCommentChoiceRow(selected: noCommentSelected,
                           unavailable: showsNoCommentUnavailable,
                           canOpenFailureDetails: failedResponseWarning != nil,
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
                if let priorityLabel = InboxPriorityDisplay.forScore(request.inboxScore) {
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
                        Text(MessageMarkdown.attributed(stake.rawValue))
                            .font(.body)
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
                            NavigationLink(value: RelatedMessageTarget.supersedes(targetKey)) {
                                Text(messageID.rawValue)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                            }
                            .accessibilityIdentifier("request-supersedes-" + messageID.rawValue)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ReplacedByMessagesSection(
                    replacementKeys: request.supersededByMessageKeys,
                    secondaryTextColor: detailColors.secondaryTextColor
                )
                if let localExample {
                    if localExample.message.revised || localExample.message.deadline != nil {
                        LocalSampleContext(response: localExample)
                    }
                    if localExample.finished && !localExample.localSeenSelected {
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
                HistoricalVersionAccess(key: request.key, store: store,
                    currentRevision: storePresentationSnapshot.conversationRevision,
                    hasAcceptedUpdate: storePresentationSnapshot.hasAcceptedUpdate,
                    secondaryTextColor: detailColors.secondaryTextColor,
                    messageTextColor: detailColors.textColor,
                    messageBackgroundColor: detailColors.backgroundColor)
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
                if showsAnsweredConfirmation {
                    AnswerConfirmationCard(
                        title: Self.answeredConfirmationTitle(isDefaultAnswered: request.isDefaultAnswered),
                        answer: confirmedAnswerText,
                        identifier: "request-answered",
                        accessibilityValue: "Completed",
                        symbolName: "checkmark",
                        answerIdentifier: request.isDefaultAnswered
                            ? "request-default-answer" : "request-account-answer")
                } else if showsNoCommentConfirmation {
                    AnswerConfirmationCard(title: "No comment", answer: nil,
                        identifier: "request-no-comment-status",
                        accessibilityValue: "Completed", symbolName: "checkmark")
                } else if showsPendingAnswerConfirmation {
                    AnswerConfirmationCard(title: "Pending", answer: pendingAnswerText,
                        identifier: "request-pending-answer-status",
                        accessibilityValue: "Pending", symbolName: "clock",
                        answerIdentifier: "request-pending-answer")
                } else if showsNotAcceptedConfirmation {
                    AnswerConfirmationCard(title: "Not accepted", answer: attemptedAnswerText,
                        identifier: "request-not-accepted-status",
                        accessibilityValue: "Not accepted", symbolName: "xmark",
                        answerIdentifier: "request-not-accepted-answer")
                } else {
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
                                                 canOpenFailureDetails: failedResponseWarning != nil,
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
                    } else if request.lifecycleStatus != .open && request.lifecycleStatus != .answered &&
                                !showsNoCommentConfirmation {
                        Text(String(localized: LiveLifecycleTitle(request.lifecycleStatus).label))
                            .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                            .accessibilityIdentifier("request-lifecycle-status")
                    }
                    if case let .reply(answerText)? = request.accountAnswerOutcome,
                       !showsAnsweredConfirmation {
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
                       (seenStatus != .available || isSupersedesReadOnly),
                       !(seenActionIsComplete && !isSupersedesReadOnly) {
                        Label(Self.informationalSeenText(seenStatus),
                              systemImage: Self.informationalSeenSymbol(seenStatus))
                            .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                            .accessibilityIdentifier("informational-seen-status")
                    }
                } else {
                    Label("Cached history · status not refreshed", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                        .accessibilityIdentifier("inbox-status-unrefreshed")
                    if failedResponseWarning == nil,
                       let localStatus = store.answerOperationStatus(request.intentReceipt) {
                        Text(localStatus).font(.caption).foregroundStyle(detailColors.secondaryTextColor)
                    }
                }
                if request.isDefaultAnswered && !showsAnsweredConfirmation {
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
                   request.inboxStateIsCurrent,
                   request.intentReceipt?.localState == .terminalUnconfirmed {
                    Button("Retry") { _ = store.retryUnconfirmedAnswerFromUser(request.key) }
                        .buttonStyle(.bordered)
                        .disabled(!store.canRetryUnconfirmedAnswer(for: request.key))
                } else if !isSupersedesReadOnly, localExample == nil, fixtureStore == nil,
                          request.inboxStateIsCurrent,
                          request.lifecycleStatus == .pending, failedResponseWarning == nil {
                    Button("Refresh status") { store.retryPendingDelivery() }
                        .buttonStyle(.bordered)
                        .disabled(store.isReadOnly || store.isRefreshing)
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
                if let statusText = answerStatusText {
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
            if skippedMessageWarning != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    skippedMessageWarningButton
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                chatButton
            }
            if !isSupersedesReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    if request.informationalSeenStatus != nil {
                        if seenActionIsComplete { EmptyView() } else { finishSeenButton }
                    } else if let localExample {
                        if localExample.localSeenSelected {
                            EmptyView()
                        } else {
                            Button("Finish locally", systemImage: "checkmark") {
                                closeReplyEditor()
                                localExample.finishLocally()
                            }
                            .labelStyle(.iconOnly)
                            .disabled(!localExample.canFinishLocally || localExample.finished)
                            .accessibilityIdentifier("sample-finish")
                        }
                    } else if failedResponseWarning != nil {
                        failedResponseWarningButton
                    } else if isEditingLocalReply {
                        submitReplyButton
                    } else if showsAnsweredConfirmation || showsNoCommentConfirmation ||
                                showsNotAcceptedConfirmation {
                        EmptyView()
                    } else {
                        submitReplyButton
                    }
                }
            }
        }
        .sheet(item: $enlargedPicture) { picture in
            SamplePictureViewer(initialPicture: picture)
                .foregroundChatNotificationLayer(testRouter: testNotificationRouter,
                                                 testOpen: testOpenForegroundChatIndicator)
        }
        .sheet(isPresented: $requestDetailsPresented) {
            requestDetailsSheet
                .foregroundChatNotificationLayer(testRouter: testNotificationRouter,
                                                 testOpen: testOpenForegroundChatIndicator)
        }
        .sheet(item: $warningDialog) { dialogKind in
            Group {
                switch dialogKind {
                case .failedResponse:
                    if let warning = failedResponseWarning {
                        FailedResponseDialog(title: "Response delivery",
                            summary: warning.summary,
                            detail: .localized(warning.detail),
                            canRetry: store.canRetryFailedResponse(for: request.key),
                            onRetry: { _ = store.retryFailedResponse(for: request.key) },
                            onCopy: { UIPasteboard.general.string = $0 })
                    }
                case .skippedMessage:
                    if let warning = skippedMessageWarning {
                        FailedResponseDialog(title: "Message not loaded",
                            summary: "The message could not be loaded and was skipped.",
                            detail: .plain(store.skippedMessageDiagnosticText(for: warning) ??
                                "The safe diagnostic details are no longer retained."),
                            accessibilityPrefix: "message-load-warning",
                            canRetry: false,
                            onRetry: nil,
                            onCopy: { UIPasteboard.general.string = $0 })
                    }
                }
            }
            .foregroundChatNotificationLayer(testRouter: testNotificationRouter,
                                             testOpen: testOpenForegroundChatIndicator)
        }
        .sheet(isPresented: $chatPresented, onDismiss: { pendingChatScrollTarget = nil }) {
            conversationPanel
                .foregroundChatNotificationLayer(testRouter: testNotificationRouter,
                                                 testOpen: testOpenForegroundChatIndicator)
        }
        .onChange(of: context.inlineChat) { _, inline in
            if inline { chatPresented = false }
        }
        .onChange(of: context.notificationChatRouteSerial, initial: true) { _, serial in
            guard serial != nil else { return }
            // Capture the scroll target before didOpen, which may clear the route.
            pendingChatScrollTarget = context.chatScrollTargetTurnID
            if !context.inlineChat { chatPresented = true }
            context.notificationChatRouteDidOpen?()
        }
        .onChange(of: request) { _, _ in
            refreshStorePresentationSnapshot()
            refreshUneditedReplySession()
        }
        .onChange(of: failedResponseWarning) { previous, current in
            if previous != nil, current == nil, warningDialog == .failedResponse {
                warningDialog = nil
            }
        }
        .onChange(of: skippedMessageWarning) { previous, current in
            if previous != nil, current == nil, warningDialog == .skippedMessage {
                warningDialog = nil
            }
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
                replyDraftSession = store.replyEditorSession(for: request)
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
                replyDraftSession = store.replyEditorSession(for: request)
            }
        } else {
            if request.lifecycleStatus != .open || request.intentReceipt != nil {
                store.discardReplyEditorSession(for: request.key)
            }
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
            store.discardReplyEditorSession(for: request.key)
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
            store.discardReplyEditorSession(for: session.requestKey)
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
        if !canEditCurrentRequest {
            store.discardReplyEditorSession(for: current.key)
        }
        replyDraftSession = canEditCurrentRequest
            ? store.replyEditorSession(for: current)
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
            sender: detailSenderLabel, title: request.title?.rawValue ?? "",
            initialScrollTurnID: pendingChatScrollTarget,
            testNotificationRouter: testNotificationRouter,
            testOpenForegroundChatIndicator: testOpenForegroundChatIndicator,
            testConversationSheetDidAppear: testConversationSheetDidAppear,
            dismissToList: context.dismissToList,
            discussionUnavailableReason: isSupersedesReadOnly
                ? ConversationPanelText.supersededReadOnlyReason
                : nil)
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
            Text(MessageMarkdown.attributed(request.title?.rawValue ?? "Earlier question"))
                .font(.headline)
            if let body = request.body {
                Text(MessageMarkdown.attributed(body.rawValue)).font(.body)
            }
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

private struct HistoricalVersionSelection: Identifiable, Sendable {
    let revision: UInt64
    var id: UInt64 { revision }
}

@MainActor
private struct HistoricalVersionAccess: View {
    let key: RequestKey
    let store: LivePresentationStore
    let currentRevision: UInt64?
    let hasAcceptedUpdate: Bool
    let secondaryTextColor: Color
    let messageTextColor: Color
    let messageBackgroundColor: Color
    @State private var selection: HistoricalVersionSelection?

    private var revisionNumbers: [UInt64] {
        store.conversation(for: key)?.revisionNumbers ?? []
    }

    @ViewBuilder
    private func versionMenuItem(_ version: UInt64) -> some View {
        if version == 1 {
            Button("Original version") { selection = HistoricalVersionSelection(revision: version) }
                .accessibilityIdentifier("request-historical-version-\(version)")
        } else {
            Button("Version \(version)") { selection = HistoricalVersionSelection(revision: version) }
                .accessibilityIdentifier("request-historical-version-\(version)")
        }
    }

    var body: some View {
        Group {
            if let currentRevision, currentRevision > 1 {
                Menu {
                    ForEach(revisionNumbers.filter { $0 != currentRevision }, id: \.self) { version in
                        versionMenuItem(version)
                    }
                } label: {
                    Label(hasAcceptedUpdate
                          ? "Updated · version \(currentRevision)" : "Question version \(currentRevision)",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                }
                .accessibilityIdentifier("request-update-fact")
                .accessibilityHint("View earlier versions of this message")
            }
        }
        .sheet(item: $selection) { selected in
            HistoricalMessageVersionSheet(key: key, revision: selected.revision,
                store: store, messageTextColor: messageTextColor,
                messageBackgroundColor: messageBackgroundColor) {
                    selection = nil
                }
        }
    }
}

@MainActor
private struct HistoricalMessageVersionSheet: View {
    let key: RequestKey
    let revision: UInt64
    let store: LivePresentationStore
    let messageTextColor: Color
    let messageBackgroundColor: Color
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HistoricalVersionSheetHeader(revision: revision,
                messageTextColor: messageTextColor,
                messageBackgroundColor: messageBackgroundColor,
                onDone: onDone)
            if let version = store.historicalRequest(for: key, revision: revision) {
                HistoricalMessageVersionView(request: version, store: store)
            } else {
                ContentUnavailableView("This version is unavailable now",
                    systemImage: "questionmark.folder",
                    description: Text("No saved copy of this message version is available on this device."))
                    .accessibilityIdentifier("historical-version-unavailable")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(messageBackgroundColor.ignoresSafeArea())
        .foregroundStyle(messageTextColor)
        .tint(messageTextColor)
        .presentationDetents([.large])
        .foregroundChatNotificationLayer()
    }
}

private struct HistoricalVersionSheetHeader: View {
    let revision: UInt64
    let messageTextColor: Color
    let messageBackgroundColor: Color
    let onDone: () -> Void

    var body: some View {
        HStack {
            Text(revision == 1 ? "Original version" : "Version \(revision)")
                .font(.headline)
                .foregroundStyle(messageTextColor)
            Spacer()
            Button("Done", action: onDone)
                .font(.body.weight(.semibold))
                .foregroundStyle(messageTextColor)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
        .background(messageBackgroundColor)
    }
}

@MainActor
private struct HistoricalMessageVersionView: View {
    let request: PresentedRequest
    let store: LivePresentationStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HistoricalMessageOverview(version: request.requestRevision,
                    title: request.title?.rawValue ?? "Message",
                    messageBody: request.body?.rawValue, stake: request.stakeText?.rawValue)
                HistoricalMessageReadOnlyResponse(request: request, store: store)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .accessibilityIdentifier("historical-message-version")
    }
}

private struct HistoricalMessageOverview: View {
    let version: UInt64
    let title: String
    let messageBody: String?
    let stake: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Version \(version)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("historical-version-number")
            Text(title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("historical-version-title")
            if let messageBody {
                Text(MessageMarkdown.attributed(messageBody))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("historical-version-body")
            }
            if let stake {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What’s at stake").font(.caption.weight(.semibold))
                    Text(MessageMarkdown.attributed(stake))
                        .font(.body).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

@MainActor
private struct HistoricalMessageReadOnlyResponse: View {
    let request: PresentedRequest
    let store: LivePresentationStore
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

    @ViewBuilder
    var body: some View {
        switch request.projection {
        case let .sender(sender):
            LiveProjectedSceneView(request: request, sender: sender,
                node: sender.scene, store: store, readOnly: true,
                focusedReplyActionID: $focusedReplyActionID,
                replyTextBinding: replyTextBinding)
        case let .compatibility(actions):
            LiveCompatibilityActions(request: request, actions: actions,
                store: store, readOnly: true, sendDisabled: true,
                focusedReplyActionID: $focusedReplyActionID,
                replyTextBinding: replyTextBinding)
        case .unsupported:
            Text("This message version uses an unsupported answer format.")
                .font(.callout).foregroundStyle(.secondary)
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
    var canOpenFailureDetails = false
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
        } else if seenActionIsComplete {
            AnswerConfirmationCard(title: "Seen", answer: nil,
                identifier: "request-seen-confirmation",
                accessibilityValue: "Completed", symbolName: "checkmark")
        } else if let seenStatus = request.informationalSeenStatus {
            VStack(alignment: .leading, spacing: 8) {
                Label("FYI", systemImage: "info.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(detailColors.secondaryTextColor)
                    .accessibilityIdentifier("request-seen-form-label")
                switch seenStatus {
                case .available:
                    Button {
                        guard seenStatus == .available, let action = actions.first else { return }
                        if let onSeen {
                            onSeen(action.id)
                        } else {
                            store.submitFromUser(request.key, explicitCompatibilityAction: action.id,
                                                 requestRevision: request.requestRevision)
                        }
                    } label: {
                        Label("Seen", systemImage: "eye")
                            .font(.body)
                            .foregroundStyle(detailColors.textColor)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(detailColors.textColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(sendDisabled)
                    .accessibilityLabel(Text(seenActionPresentation.accessibilityLabel))
                    .accessibilityValue(Text(seenActionPresentation.accessibilityValue))
                    .accessibilityIdentifier("request-seen-action")
                case .pending:
                    Button {} label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock")
                                .foregroundStyle(detailColors.secondaryTextColor)
                            Text(seenActionPresentation.title)
                                .foregroundStyle(detailColors.secondaryTextColor)
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glass)
                    .tint(detailColors.secondaryTextColor)
                    .disabled(true)
                    .accessibilityLabel(Text(seenActionPresentation.accessibilityLabel))
                    .accessibilityValue(Text(seenActionPresentation.accessibilityValue))
                    .accessibilityIdentifier("request-seen-action")
                case .confirmed:
                    AnswerConfirmationCard(title: "Seen", answer: nil,
                        identifier: "request-seen-confirmation",
                        accessibilityValue: "Completed", symbolName: "checkmark")
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
                                       canOpenFailureDetails: canOpenFailureDetails,
                                       onSelect: onSelectNoComment)
                }
            }
        }
    }
}

private struct NoCommentChoiceRow: View {
    let selected: Bool
    let unavailable: Bool
    let canOpenFailureDetails: Bool
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
            ? (canOpenFailureDetails
                ? "No comment was not accepted. Open the warning icon to view delivery details."
                : "No comment was not accepted. Choose another answer.")
            : "Select No comment as your answer, then send it with the checkmark.")
        .accessibilityIdentifier("request-no-comment")
    }
}

struct FailedResponseDialogCopyContent: Equatable {
    static let buttonAccessibilityIdentifier = "failed-response-copy"

    let summary: String
    let detail: String

    var text: String { "\(summary)\n\n\(detail)" }

    func copy(using action: (String) -> Void) {
        action(text)
    }
}

private struct FailedResponseDialog: View {
    enum Detail {
        case localized(LocalizedStringResource)
        case plain(String)
    }

    let title: LocalizedStringResource
    let summary: LocalizedStringResource
    let detail: Detail
    var accessibilityPrefix = "failed-response"
    let canRetry: Bool
    let onRetry: (() -> Void)?
    let onCopy: (String) -> Void
    @Environment(\.locale) private var locale

    private var copyContent: FailedResponseDialogCopyContent {
        var localizedSummary = summary
        localizedSummary.locale = locale
        let detailText: String
        switch detail {
        case let .localized(resource):
            var localizedResource = resource
            localizedResource.locale = locale
            detailText = String(localized: localizedResource)
        case let .plain(text):
            detailText = text
        }
        return FailedResponseDialogCopyContent(
            summary: String(localized: localizedSummary),
            detail: detailText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.headline)
                    .accessibilityIdentifier("\(accessibilityPrefix)-title")
                Spacer(minLength: 8)
                Button("Copy") { copyContent.copy(using: onCopy) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(accessibilityPrefix)-copy")
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRetry)
                        .accessibilityIdentifier("failed-response-retry")
                }
            }
            .padding()
            Divider().accessibilityHidden(true)
            Text(copyContent.summary)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 16)
                .accessibilityIdentifier("\(accessibilityPrefix)-summary")
            ScrollView {
                Text(copyContent.detail)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("\(accessibilityPrefix)-detail")
            }
            .accessibilityIdentifier("\(accessibilityPrefix)-detail-scroll")
        }
        .frame(minWidth: 280, minHeight: 260)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
