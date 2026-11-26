import AttentionDomain
import HarklightNativeRelay
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

enum SharedAnswerPresentation {
    struct Row: Identifiable {
        let id: ExactText
        let name: String
        let answer: String
    }

    static func rows(in shared: APISharedItem) -> [Row] {
        shared.answers.compactMap { entry in
            guard let answer = entry.terminal.answer else { return nil }
            let speaker = entry.terminal.speaker
            let name = shared.members.first { $0.person.id == entry.personID }?.person.displayName
                ?? speaker?.displayName
            guard let name else { return nil }
            let summary: String = switch answer.kind {
            case "no_comment": String(localized: "No comment")
            case "choice": answer.label?.rawValue ?? String(localized: "Answered")
            case "reply": answer.text?.rawValue ?? String(localized: "Answered")
            case "default":
                answer.text?.rawValue ?? answer.value?.jsonString ?? String(localized: "Answered by default")
            case "result": answer.value?.jsonString ?? String(localized: "Answered")
            default: String(localized: "Answered")
            }
            return Row(id: entry.personID, name: name.rawValue, answer: summary)
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
        case let .some(.choice(_, label)):
            return label.rawValue
        case .some(.result):
            // Shown as today's answered-with-result: the answer given here, if any.
            break
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
    /// Nil when the check and the answer say it all, as for a confirmed answer.
    let title: LocalizedStringResource?
    let answer: String?
    let identifier: String
    let accessibilityValue: LocalizedStringResource
    let symbolName: String?
    var answerIdentifier: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    private var messageColors: HarklightMessageColors {
        HarklightDesignSystem.palette(for: colorScheme).message(messageType)
    }

    private let symbolWidth: CGFloat = HarklightDesignSystem.shape(.answeredCardSymbolWidth)
    private let symbolSpacing: CGFloat = HarklightDesignSystem.shape(.answeredCardSymbolGap)

    private func answerText(_ answer: String) -> some View {
        Text(answer)
            .harklightType(.messageBody)
            .fontWeight(.semibold)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(messageColors.text)
            .accessibilityIdentifier(answerIdentifier ?? "\(identifier)-answer")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HarklightDesignSystem.shape(.card))
        VStack(alignment: .leading, spacing: HarklightDesignSystem.shape(.answeredCardStackSpacing)) {
            HStack(alignment: .firstTextBaseline, spacing: symbolSpacing) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: HarklightDesignSystem.shape(.answeredCardSymbolSize), weight: .semibold))
                        .foregroundStyle(messageColors.beam)
                        .frame(width: symbolWidth)
                }
                if let title {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(messageColors.text)
                } else if let answer, !answer.isEmpty {
                    answerText(answer)
                }
            }

            if title != nil, let answer, !answer.isEmpty {
                answerText(answer)
                    .padding(.leading, symbolName == nil ? 0 : symbolWidth + symbolSpacing)
            }
        }
        .padding(HarklightDesignSystem.shape(.answeredCardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(messageColors.pickedFill, in: shape)
        .overlay(shape.strokeBorder(messageColors.beam, lineWidth: HarklightDesignSystem.shape(.lineWidth)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(Text(accessibilityValue))
    }
}

/// True while a live text field has keyboard focus. Foreground notices defer
/// while this is set, because presenting over a field resigns first responder.
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

    /// Edit on a failed send: its sent answer becomes this session's edited draft.
    func restore(_ sent: RequestDraft) {
        store(sent)
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
        // A definitively failed send keeps showing what it sent until Edit or
        // another answer.
        if let sent = request.failedAnswer { return sent }
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

@MainActor
private func liveChoiceButton<Label: View>(style: MessageChoiceStyle?,
                                           selected: Bool = false,
                                           readOnly: Bool = false,
                                           perform action: @escaping () -> Void,
                                           @ViewBuilder label: () -> Label) -> some View {
    LiveChoiceButton(style: style, selected: selected, readOnly: readOnly, action: action, label: label())
}

/// A choice button. When the picked answer failed and can retry, tapping the
/// picked choice resends the same operation; it shows Retry in place. That
/// Retry stays tappable while the other controls are locked, as they are
/// after a lost send.
private struct LiveChoiceButton<Label: View>: View {
    let style: MessageChoiceStyle?
    let selected: Bool
    var readOnly = false
    let action: () -> Void
    let label: Label

    @Environment(\.harklightSubmissionDisplay) private var submission

    private var retry: (() -> Void)? {
        selected ? submission.retryAction(.answer) : nil
    }

    var body: some View {
        button(perform: retry ?? action)
            .disabled(readOnly && retry == nil)
    }

    @ViewBuilder
    private func button(perform: @escaping () -> Void) -> some View {
        switch MessageChoiceAppearance(style: style) {
        case .prominent:
            Button(action: perform) { label }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .environment(\.harklightChoiceAppearance, .prominent)
        case .destructive:
            Button(role: .destructive, action: perform) { label }
                .buttonStyle(.bordered)
                .tint(.red)
                .environment(\.harklightChoiceAppearance, .destructive)
        case .card:
            Button(action: perform) { label }
                .buttonStyle(.plain)
        }
    }
}

/// One card for a written reply: the Reply label on top and, once Reply is
/// picked, the text pane below it inside the same border.
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
    let target: ReplyEditorTarget
    let isReadOnly: Bool
    let onOpen: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType
    @Environment(\.harklightSubmissionDisplay) private var submission

    private var messageColors: HarklightMessageColors {
        HarklightDesignSystem.palette(for: colorScheme).message(messageType)
    }

    private func savedReplyForeground(_ appearance: MessageChoiceAppearance) -> AnyShapeStyle {
        if let token = appearance.savedReplyForegroundToken(for: colorScheme, isEnabled: isEnabled) {
            return AnyShapeStyle(Color(harklightToken: token))
        }
        return appearance == .prominent
            ? AnyShapeStyle(.foreground) : AnyShapeStyle(messageColors.text)
    }

    var body: some View {
        let radius = HarklightDesignSystem.shape(.card)
        let shape = RoundedRectangle(cornerRadius: radius)
        // A failed written reply is locked: Retry resends exactly what is shown,
        // and Edit (where the server definitively did not take it) makes it a
        // draft again.
        let failedHere = selected && submission.isFailed(.answer)
        let showsEditor = !isReadOnly && !failedHere && (isEditing || selected)
        let showsPane = showsEditor || !text.isEmpty
        let appearance = MessageChoiceAppearance.writtenReply(
            style: style, showsEditor: showsEditor, isReadOnly: isReadOnly, failed: failedHere)
        let card = VStack(alignment: .leading, spacing: HarklightDesignSystem.shape(.replyHeaderPaneGap)) {
            // The card's own row below shows a failure once, with Edit and Retry.
            MessageChoiceLabel(title: title, detail: detail, selected: selected,
                               multiple: multiple, suggested: suggested,
                               ownAnswer: ownAnswer, drawsSurface: false, showsFailure: false)
            if showsEditor {
                TextEditor(text: $text)
                    .harklightType(.messageBody)
                    .foregroundStyle(messageColors.text)
                    .tint(messageColors.text)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity,
                           minHeight: HarklightDesignSystem.shape(.replyPaneMinHeight),
                           alignment: .topLeading)
                    .padding(.horizontal, HarklightDesignSystem.shape(.replyEditorHorizontalPadding))
                    .padding(.vertical, HarklightDesignSystem.shape(.replyEditorVerticalPadding))
                    .background(messageColors.replyPane)
                    .focused($focusedActionID, equals: target.actionIdentifier)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(target.fieldIdentifier)
                    .disabled(isReadOnly || !selected)
            } else if showsPane {
                Text(text)
                    .harklightType(.messageBody)
                    .foregroundStyle(savedReplyForeground(appearance))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: HarklightDesignSystem.shape(.replyPaneMinHeight),
                           alignment: .topLeading)
                    .padding(.horizontal, HarklightDesignSystem.shape(.replySavedHorizontalPadding))
                    .padding(.vertical, HarklightDesignSystem.shape(.replySavedVerticalPadding))
                    .background(messageColors.replyPane)
            }
            if failedHere {
                HStack(spacing: HarklightDesignSystem.shape(.replyFailureGap)) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: HarklightDesignSystem.shape(.replyFailureSymbolSize), weight: .regular))
                        .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme).coral)
                        .accessibilityLabel("Did not send")
                    Spacer(minLength: 0)
                    if submission.canEdit(.answer), let edit = submission.edit {
                        Button("Edit", action: edit)
                            .accessibilityIdentifier("request-reply-edit")
                    }
                    if let retry = submission.retryAction(.answer) {
                        Button("Retry", action: retry)
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("request-reply-retry")
                    }
                }
                .tint(messageColors.beam)
                .padding(.horizontal, HarklightDesignSystem.shape(.replyFailureHorizontalPadding))
                .padding(.vertical, HarklightDesignSystem.shape(.replyFailureVerticalPadding))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !appearance.usesSystemSurface {
                shape.fill(selected ? messageColors.pickedFill : messageColors.raised)
            }
        }
        .clipShape(shape)
        .overlay {
            if !appearance.usesSystemSurface {
                shape.strokeBorder(selected ? messageColors.beam : messageColors.line,
                                  style: StrokeStyle(lineWidth: HarklightDesignSystem.shape(.lineWidth),
                                                     dash: selected ? [] : HarklightDesignSystem.replyBorderDash))
            }
        }
        .animation(.smooth(duration: 0.25), value: selected)

        if showsEditor || isReadOnly || failedHere {
            card
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(target.editorCardIdentifier)
        } else {
            let summary = liveChoiceButton(style: style, perform: onOpen) {
                card
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(target.summaryIdentifier)
            .accessibilityHint(text.isEmpty ? "Opens the reply field." : "Edit your reply.")
            if appearance.usesSystemSurface {
                summary
                    .buttonBorderShape(.roundedRectangle(radius: radius))
                    .clipShape(shape)
            } else {
                summary
            }
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

    var connectionWarning: String? {
        if !store.isReadOnly, !store.v2AccountPaused,
           let progress = launch?.foregroundConnectProgress, progress.outcome != .confirmed {
            return progress.userFacingMessage
        }
        return store.connectionWarning
    }

    var presentsConnectionFailure: Bool {
        guard !store.isReadOnly, !store.v2AccountPaused,
              let launch, launch.foregroundConnectDiagnostic != nil,
              let key = launch.foregroundConnectFailureKey else { return false }
        return launch.shouldPresentForegroundConnectFailure(key)
    }

    var body: some View {
        let failureKey = launch?.foregroundConnectFailureKey
        let diagnostic = launch?.foregroundConnectDiagnostic
        let failureAlertPresented = Binding<Bool>(
            get: { presentsConnectionFailure && !replyEditorFocused },
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
                        let row = store.inboxRow(for: key)
                        if store.progressInboxEnabled, let progress = request.messageProgress,
                           row?.fyiUsesRepliedForProgress != true, row?.fyiUsesInboxSearchForProgress != true {
                            if request.isResolved || row?.isRetracted == true {
                                ContentUnavailableView("Progress unavailable", systemImage: "checkmark.circle")
                            } else {
                                ProgressMessageDetail(title: request.title?.rawValue ?? "Message",
                                    sender: request.senderDisplayName?.rawValue ?? key.senderID.rawValue,
                                    bodyText: request.body?.rawValue, progress: progress,
                                    messageType: context.messageType,
                                    metadata: .init(declaredType: request.messageType, kind: request.messageKind,
                                                    hasSeenDescriptor: request.informationalSeenStatus != nil),
                                    createdAt: request.createdAt,
                                    itemID: store.isLocalExample ? nil : key.messageID,
                                    seenPending: row?.isFYISeenPending == true,
                                    onSeen: row?.canMarkFYISeen == true
                                        ? { store.markProgressFYISeen(key, requestRevision: request.requestRevision) }
                                        : nil)
                            }
                        } else {
                        LiveRequestDetail(request: request, store: store, context: context,
                            fixtureStore: fixtureStore,
                            testNotificationRouter: testNotificationRouter,
                            testOpenForegroundChatIndicator: testOpenForegroundChatIndicator,
                            testConversationSheetDidAppear: testConversationSheetDidAppear)
                        }
                    } else {
                        ContentUnavailableView("Request unavailable", systemImage: "questionmark.folder")
                    }
                },
                settingsContent: { LiveInboxSettings(store: store, launch: launch,
                                                      archiveDeparture: archiveDeparture,
                                                      connectionStatus: connectionWarning) },
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
                diagnostics: launch?.diagnostics,
                refreshInbox: inboxRefreshAction,
                showsLocalExamples: showsSampleMessages && !store.isReadOnly,
                notificationNavigation: testNotificationNavigation ??
                    (store.isReadOnly ? nil : launch?.notificationNavigation),
                notificationChatRouteDidOpen: { serial in
                    if let testNotificationChatRouteDidOpen {
                        testNotificationChatRouteDidOpen(serial)
                    } else {
                        launch?.notificationChatRouteWasOpened(serial: serial)
                    }
                },
                userOpenedMessage: { launch?.userOpenedMessage() },
                testNotificationRouter: testNotificationRouter,
                testOpenForegroundChatIndicator: testOpenForegroundChatIndicator)
            .environment(\.errorLogModel, launch?.errorLogModel)
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
                Text(diagnostic.progress.userFacingMessage)
            }
            .alert("Couldn't show message", isPresented: Binding(
                get: { !store.isReadOnly && launch?.pushedViewUnavailableMessage != nil },
                set: { if !$0 { launch?.dismissPushedViewUnavailableMessage() } }
            )) {
                Button("OK", role: .cancel) { launch?.dismissPushedViewUnavailableMessage() }
            } message: {
                Text(launch?.pushedViewUnavailableMessage ?? "")
            }
            .onChange(of: store.presentation.revision) { _, _ in
                fixtureStore?.refreshFromDurableStore()
            }
            .onChange(of: store.isReadOnly, initial: true) { _, readOnly in
                NativeFocusReporter.shared.setReportsVisiblePresentation(!readOnly)
                if !readOnly, let launch {
                    NativePushedViewCoordinator.shared.setApplyHandler { show in
                        await launch.applyPushedView(show)
                    }
                } else {
                    NativePushedViewCoordinator.shared.setApplyHandler(nil)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                NativeFocusReporter.shared.scenePhaseChanged(phase)
                NativePushedViewCoordinator.shared.scenePhaseChanged(phase)
                if phase == .active { refreshRetractionVisibilityForSceneActivation() }
                if phase == .background { store.flushPendingDrafts() }
            }
            .onPreferenceChange(ReplyEditorFocusKey.self) { isFocused in
                replyEditorFocused = isFocused
                NativePushedViewCoordinator.shared.replyEditorFocusChanged(isFocused)
            }
            .onAppear {
                NativeFocusReporter.shared.scenePhaseChanged(scenePhase)
                NativePushedViewCoordinator.shared.scenePhaseChanged(scenePhase)
                applyPresentationTestFixtureIfNeeded()
            }
            .onDisappear {
                NativePushedViewCoordinator.shared.setApplyHandler(nil)
            }
            .task(id: store.nextRetractionExpiry) {
                await store.waitForNextRetractionExpiry()
            }
        }
    }

    private func refreshRetractionVisibilityForSceneActivation() {
        store.refreshRetractionVisibility()
    }

#if DEBUG
    private func applyPresentationTestFixtureIfNeeded() {
        guard !didApplyPresentationTestFixture else { return }
        didApplyPresentationTestFixture = true
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--harklight-test-settings-diagnostics"), let launch {
            launch.errorLog.report(ErrorLogReport(concern: .sync, connectionRole: .stream,
                operation: "catch_up", phase: "batch",
                reason: .serverReason(APIErrorToken.internalError.rawValue),
                initiator: .unknown, retryable: false, httpStatus: 500))
            launch.errorLogModel.refresh()
        }
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

/// Shared message identity parts for detail headings and FYI list rows.
struct MessageHeading: View {
    struct Detail {
        let itemID: ExactText?
        let onOpenDetails: () -> Void
    }

    let sender: String?
    let initials: String
    let title: String
    var createdAt: Date? = nil
    var messageType: HarklightMessageType = .request
    var metadata = MessageMetadataPresentation()
    var inFYIList = false
    var detail: Detail? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var palette: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private var senderLine: String? {
        if inFYIList { return sender }
        let parts = [sender, createdAt.map { InboxFriendlyDate.detailLabel(for: $0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var bylineIdentity: some View {
        HStack(spacing: inFYIList ? HarklightDesignSystem.shape(.fyiListBylineGap) : 10) {
            if !initials.isEmpty {
                let badgeSize = HarklightDesignSystem.shape(inFYIList ? .rowInitials : .messageInitials)
                Text(initials)
                    .font(inFYIList ? .system(size: HarklightDesignSystem.shape(.fyiListInitialsTextSize), weight: .medium) : .caption)
                    .foregroundStyle(palette.label)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(palette.field, in: Circle())
                    .overlay(Circle().strokeBorder(palette.line, lineWidth: 1))
                    .accessibilityHidden(true)
            }
            if let senderLine {
                Text(verbatim: senderLine)
                    .harklightType(inFYIList ? .rowByline : .messageSender)
                    .foregroundStyle(palette.secondary)
            }
        }
    }

    private var titleText: Text { Text(MessageMarkdown.attributed(title)) }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: inFYIList ? HarklightDesignSystem.shape(.fyiListTitleSymbolGap) : 14) {
            Image(systemName: metadata.iconRole(for: messageType).token.sfSymbol)
                .font(.system(size: inFYIList ? HarklightDesignSystem.shape(.fyiListTitleSymbolSize) : 22, weight: .medium))
                .foregroundStyle(palette.typeColor(messageType))
                .accessibilityHidden(true)
            titleText
                .harklightType(inFYIList ? .inboxMessageTitle : .messageTitle)
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(metadata.accessibilityTitle(titleText))
        }
    }

    var body: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: detail.onOpenDetails) {
                    titleLine
                }
                .buttonStyle(.plain)
                .accessibilityLabel(metadata.accessibilityTitle(titleText))
                .accessibilityIdentifier("request-heading")
                .accessibilityHint("Open request details")

                if let itemID = detail.itemID {
                    MessageIDByline(identity: bylineIdentity, itemID: itemID)
                        .id(itemID)
                } else {
                    bylineIdentity
                }
            }
        } else {
            VStack(alignment: .leading, spacing: inFYIList ? HarklightDesignSystem.shape(.fyiListHeadingStackSpacing) : 6) {
                HStack(spacing: inFYIList ? HarklightDesignSystem.shape(.fyiListBylineGap) : 8) {
                    bylineIdentity
                    Spacer(minLength: 0)
                    if let createdAt {
                        Text(InboxFriendlyDate.detailLabel(for: createdAt))
                            .harklightType(.rowTime)
                            .foregroundStyle(palette.label)
                    }
                }
                titleLine
            }
            .accessibilityElement(children: .combine)
        }
    }
}

@MainActor
struct LiveInboxSettings: View {
    let store: LivePresentationStore
    let launch: NativeAppLaunch?
    let archiveDeparture: NativeAccountDeparture?
    let connectionStatus: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openCatalogueMessage) private var openCatalogueMessage
    @State private var alertsState: ClientAPIv2Connection.AlertsState?
    @State private var startingAlertsSave = false
    @State private var alertsSaveFailed = false
    @State private var showsFeatures = false
    @State private var confirmingDisconnect = false

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
            ScrollViewReader { proxy in
            Form {
                Section {
                    Button {
                        showsFeatures = true
                    } label: {
                        Label("Features", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("settings-features")
                }
                if let connectionStatus {
                    HarklightFormSection("Connection status") {
                        Text(connectionStatus).foregroundStyle(.hkSecondary)
                    }
                }
                if let record {
                    HarklightFormSection("Account") {
                        LabeledContent("Account", value: record.savedAccountName ?? "Current account")
                        LabeledContent("Server", value: record.serverDisplayName ?? record.host)
                    }
                }
                if !store.isReadOnly, (try? store.recoveredPreviousProtocolText().isEmpty) == false {
                    HarklightFormSection("Saved text") {
                        NavigationLink("Unsent from the previous version") {
                            PreviousDeviceUnsentTextView(title: "Unsent from the previous version",
                                explanation: "You can copy this saved text and use it in a new message. Some earlier sends may already have reached the server.") {
                                    try store.recoveredPreviousProtocolText()
                                }
                        }
                    }
                }
                if let launch {
                    let otherArchives = launch.availableDisconnectedAccounts
                        .filter { $0.archiveID != archiveDeparture?.archiveID }
                    if !otherArchives.isEmpty {
                        HarklightFormSection("Saved accounts") {
                            ForEach(otherArchives, id: \.archiveID) { departure in
                                Button {
                                    launch.showArchivedAccount(departure)
                                    dismiss()
                                } label: {
                                    Label(departure.record.savedAccountName ?? "Disconnected account",
                                          systemImage: "lock")
                                }
                                .accessibilityHint("Open this account’s saved messages and discussion read-only")
                                if departure.hasV2TextRecovery {
                                    NavigationLink("Unsent from your previous device") {
                                        PreviousDeviceUnsentTextView { try launch.recoveredUnsentText(for: departure) }
                                    }
                                }
                            }
                        }
                    }
                }
                if store.isReadOnly {
                    if let launch, let archiveDeparture, archiveDeparture.hasV2TextRecovery {
                        HarklightFormSection("Saved text") {
                            NavigationLink("View unsent text") {
                                PreviousDeviceUnsentTextView { try launch.recoveredUnsentText(for: archiveDeparture) }
                            }
                        }
                    }
                    HarklightFormSection("Connection") {
                        if let archiveDeparture {
                            Label("Disconnected · Read-only", systemImage: "lock")
                            Text("These saved messages, discussion history, drafts and local files belong to this account. They are read-only and are not shared with another account.")
                                .foregroundStyle(.hkSecondary)
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
                                .foregroundStyle(.hkSecondary)
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
                                .foregroundStyle(.hkSecondary)
                        }
                    }
                    if let launch {
                        let currentArchiveID = archiveDeparture?.archiveID ?? launch.disconnectedAccount?.archiveID
                        let otherPendingRemovals = launch.unconfirmedAccountDepartures.filter {
                            $0.archiveID != currentArchiveID
                        }
                        if !otherPendingRemovals.isEmpty {
                            HarklightFormSection("Other pending removals") {
                                ForEach(otherPendingRemovals, id: \.archiveID) { departure in
                                    UnconfirmedAccountRemovalNotice(launch: launch, departure: departure)
                                        .font(.footnote)
                                }
                            }
                        }
                    }
                } else if launch != nil {
                    HarklightFormSection("Connection") {
                        Text("This phone is registered to this account.")
                            .foregroundStyle(.hkSecondary)
                        if let launch {
                            ForEach(launch.unconfirmedAccountDepartures, id: \.archiveID) { departure in
                                UnconfirmedAccountRemovalNotice(launch: launch, departure: departure)
                                    .font(.footnote)
                            }
                        }
                        Button("Disconnect this phone…", role: .destructive) {
                            confirmingDisconnect = true
                        }
                        .foregroundStyle(.hkCoral)
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
                            Text(message).font(.footnote).foregroundStyle(.hkCoral)
                        }
                    }
                }
                if !store.isReadOnly && !store.isLocalExample, let alertsState {
                    AlertsSettingsSection(state: alertsState, startingSave: startingAlertsSave,
                                          showsFailure: alertsSaveFailed, save: saveAlerts)
                        .task(id: alertsState.refusedWriteID) {
                            guard let id = alertsState.refusedWriteID else { return }
                            alertsSaveFailed = true
                            await NativeRelayLifecycle.shared.acknowledgeAlertsRefusal(
                                id, expected: store.notificationContext)
                        }
                }
                if NativeRelayLifecycle.shared.featureFlags.isEnabled(.priorityLevelEditing),
                   !store.isReadOnly && !store.isLocalExample {
                    PriorityLevelsSettingsSection(store: store)
                        .id("priority-levels-settings")
                }
                if let launch {
                    InboxDiagnosticsSettingsSection(launch: launch, isReadOnly: store.isReadOnly,
                                                    closeSettings: { dismiss() })
                }
                ReleaseNotesSettingsSection(notes: HarklightReleaseNotes.settingsHistory(
                    currentBuildIdentifier: HarklightReleaseNotes.currentBuildIdentifier(),
                    entries: HarklightReleaseNotes.numberedEntries(
                        currentBuildIdentifier: HarklightReleaseNotes.currentBuildIdentifier())))
            }
            .harklightListSurface(.sheet)
            .harklightSheetTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                HarklightDoneButton { dismiss() }
            } }
            .navigationDestination(isPresented: $showsFeatures) {
                FeatureCatalogueView(store: store, alertsAvailable: alertsState != nil) { route in
                    switch route {
                    case let .progressMessage(key):
                        openCatalogueMessage?(key)
                    case .priorityLevels:
                        showsFeatures = false
                        proxy.scrollTo("priority-levels-settings", anchor: .top)
                    }
                }
            }
            }
        }
        .harklightSheetSurface()
        .task(id: store.notificationContext) {
            guard !store.isReadOnly && !store.isLocalExample else { return }
            await observeAlerts(expected: store.notificationContext)
        }
    }

    private func observeAlerts(expected: ProfileContext) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--harklight-test-alerts-settings") {
            let settings = try? APISettings(json: JSONValue.parse(Data(#"{"rev":1,"alerts":"important"}"#.utf8)))
            alertsState = settings?.alerts.map {
                .init(confirmed: $0, canSave: true, isSaving: false, hasFailure: false)
            }
            return
        }
        #endif
        let relay = NativeRelayLifecycle.shared
        let updates = relay.priorityLevelsUpdates(for: expected)
        alertsState = await relay.alertsState(for: expected)
        await relay.refreshAlerts(expected: expected)
        alertsState = await relay.alertsState(for: expected)
        for await _ in updates {
            alertsState = await relay.alertsState(for: expected)
        }
    }

    private func saveAlerts(_ choice: APIAlerts) {
        guard let alertsState, !startingAlertsSave,
              choice != alertsState.confirmed || alertsState.hasUnconfirmedWrite else { return }
        startingAlertsSave = true
        alertsSaveFailed = false
        let context = store.notificationContext
        Task {
            let relay = NativeRelayLifecycle.shared
            do { try await relay.saveAlerts(choice, expected: context) }
            catch { alertsSaveFailed = true }
            self.alertsState = await relay.alertsState(for: context)
            startingAlertsSave = false
        }
    }
}

private struct AlertsSettingsSection: View {
    let state: ClientAPIv2Connection.AlertsState
    let startingSave: Bool
    let showsFailure: Bool
    let save: (APIAlerts) -> Void

    var body: some View {
        Section {
            Group {
                if state.hasUnconfirmedWrite {
                    // Even choosing the displayed value must supersede a paused write.
                    Menu {
                        Button("Questions and urgent") { save(.important) }
                        Button("Everything") { save(.all) }
                    } label: {
                        LabeledContent("Alerts") {
                            Text(state.confirmed == .important ? "Questions and urgent" : "Everything")
                        }
                    }
                } else {
                    Picker("Alerts", selection: Binding(get: { state.confirmed }, set: save)) {
                        Text("Questions and urgent").tag(APIAlerts.important)
                        Text("Everything").tag(APIAlerts.all)
                    }
                    .pickerStyle(.menu)
                }
            }
            .disabled(startingSave || state.isSaving || !state.canSave)
            .accessibilityIdentifier("settings-alerts")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Other messages arrive quietly. They still appear in your Inbox and on the badge.")
                if startingSave || state.isSaving {
                    Text("Saving alerts…")
                } else if showsFailure || state.hasFailure {
                    Text("Your choice wasn’t saved. The Server’s current setting is shown.")
                }
            }
        }
    }
}

@MainActor
private struct PriorityLevelsSettingsSection: View {
    let store: LivePresentationStore
    @Environment(\.scenePhase) private var scenePhase

    private var statusText: LocalizedStringResource {
        if let reason = store.priorityLevelsState.failureReason {
            switch reason {
            case "unknown_type":
                if store.priorityLevelsState.pendingSave != nil {
                    return "This Server does not support priority levels yet. The submitted save remains unconfirmed on this phone and will retry after reconnecting to a supporting Server; later edits stay separate."
                }
                return "This Server does not support priority levels yet. Your draft stays on this phone and is not applied."
            case "forbidden":
                return "This phone was not allowed to access the priority levels. Your local draft remains here."
            case "invalid_field":
                return "The Server rejected this table. Correct the values and save again; the previous applied table remains in place."
            case "operation_conflict":
                return "The Server rejected this save because its operation conflicted. Your draft remains here; another save will use a new operation."
            case "precondition_failed":
                return "Priority levels changed on the Server. Your draft is still here. Compare it with the confirmed table before saving again."
            default:
                if store.priorityLevelsState.pendingSave != nil {
                    return "The Server did not confirm this save. The same operation will retry after reconnection; later edits stay separate."
                }
                return "The latest Server result was not confirmed. Your local draft remains separate from the last confirmed table."
            }
        }
        if store.priorityLevelsState.pendingSave != nil {
            return "Save is waiting for Server confirmation. The same operation will be retried after reconnection; later edits stay separate."
        }
        guard let confirmed = store.priorityLevelsState.confirmedLevels else {
            return "The applied table has not been confirmed from the Server yet. Edits remain on this phone until saved while connected."
        }
        if confirmed.isEmpty {
            return "The Server has no priority levels configured. Add a complete table to set one."
        }
        return "The editable rows are a local draft. Saving while connected applies them on the Server."
    }

    private var confirmedTableContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Last confirmed table:")
            if let levels = store.priorityLevelsState.confirmedLevels {
                if levels.isEmpty {
                    Text("None configured.")
                } else {
                    // A band's lower bound is unique in a valid table and identifies its range.
                    ForEach(levels, id: \.lowerBound) { level in
                        if let days = level.bounceAfterDays {
                            Text("\(level.name.rawValue) from \(level.lowerBound.formatted()), bounce after \(days.formatted()) days")
                        } else {
                            Text("\(level.name.rawValue) from \(level.lowerBound.formatted()), bounce disabled")
                        }
                    }
                }
            } else {
                Text("Not confirmed yet.")
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("priority-levels-confirmed-table")
    }

    var body: some View {
        Section("Priority levels") {
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            confirmedTableContent
            Text("Local draft")
                .font(.subheadline.weight(.semibold))

            ForEach(store.priorityLevelsDraftRows) { row in
                PriorityLevelDraftEditorRow(
                    row: row,
                    name: binding(for: row.id, keyPath: \.name),
                    lowerBound: binding(for: row.id, keyPath: \.lowerBound),
                    bounceAfterDays: binding(for: row.id, keyPath: \.bounceAfterDays),
                    onRemove: { remove(row.id) })
            }

            Button {
                store.updatePriorityLevelsDraft(
                    store.priorityLevelsDraftRows + [PriorityLevelDraftRow()])
            } label: {
                Label("Add level", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("add-priority-level")

            if let validation = store.priorityLevelsValidationMessage {
                Text(validation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("priority-levels-validation")
            }
            if let localError = store.priorityLevelsLocalError {
                Text(localError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await store.savePriorityLevels() }
            } label: {
                if store.priorityLevelsState.pendingSave != nil {
                    Label("Waiting for confirmation…", systemImage: "clock")
                } else {
                    Label("Save levels", systemImage: "checkmark")
                }
            }
            .disabled(!store.canSavePriorityLevels)
            .accessibilityIdentifier("save-priority-levels")

            if !store.priorityLevelsRelayConfirmed {
                Text("Connect this phone before saving. Offline edits stay local and are not queued for upload.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            let updates = NativeRelayLifecycle.shared.priorityLevelsUpdates(for: store.notificationContext)
            await store.openPriorityLevelsEditor()
            for await _ in updates {
                guard !Task.isCancelled else { break }
                store.refreshPriorityLevelsProjection()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.openPriorityLevelsEditor() }
        }
    }

    private func binding(for id: UUID,
                         keyPath: WritableKeyPath<PriorityLevelDraftRow, String>) -> Binding<String> {
        Binding(
            get: {
                store.priorityLevelsDraftRows.first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
            },
            set: { value in
                var rows = store.priorityLevelsDraftRows
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
                rows[index][keyPath: keyPath] = value
                store.updatePriorityLevelsDraft(rows)
            })
    }

    private func remove(_ id: UUID) {
        var rows = store.priorityLevelsDraftRows
        rows.removeAll { $0.id == id }
        store.updatePriorityLevelsDraft(rows)
    }
}

@MainActor
private struct PriorityLevelDraftEditorRow: View {
    let row: PriorityLevelDraftRow
    @Binding var name: String
    @Binding var lowerBound: String
    @Binding var bounceAfterDays: String
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Level name", text: $name)
                .accessibilityIdentifier("priority-level-name-\(row.id.uuidString.lowercased())")
            HStack(spacing: 12) {
                TextField("Lower bound (0–1)", text: $lowerBound)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("priority-level-lower-bound-\(row.id.uuidString.lowercased())")
                TextField("Bounce after days (blank disables)", text: $bounceAfterDays)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("priority-level-bounce-days-\(row.id.uuidString.lowercased())")
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove level", systemImage: "minus.circle")
            }
            .accessibilityIdentifier("remove-priority-level-\(row.id.uuidString.lowercased())")
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct ReplacedByMessagesSection: View {
    let replacementKeys: [RequestKey]
    let messageLabel: (RequestKey, String) -> String
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
                        Text(messageLabel(replacementKey, String(localized: "Replacement message")))
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

struct MessageIDByline<Identity: View>: View {
    let identity: Identity
    let itemID: ExactText
    @State private var confirmation: UUID?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                identity.fixedSize(horizontal: true, vertical: false)
                pill.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 0) {
                identity
                pill
            }
        }
        .task(id: confirmation) {
            guard confirmation != nil else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            confirmation = nil
        }
    }

    private var pill: some View {
        Button {
            UIPasteboard.general.string = itemID.rawValue
            confirmation = UUID()
            AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        } label: {
            pillLabel
                .padding(.horizontal, HarklightDesignSystem.shape(.messageIDPillHorizontalPadding))
                .padding(.vertical, HarklightDesignSystem.shape(.messageIDPillVerticalPadding))
                .background(.quaternary, in: RoundedRectangle(
                    cornerRadius: HarklightDesignSystem.shape(.messageIDPillRadius), style: .circular))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy message ID")
        .accessibilityValue(confirmation == nil ? Text(verbatim: itemID.rawValue) : Text("Copied"))
        .accessibilityIdentifier("copy-message-id")
    }

    private var pillLabel: some View {
        ZStack {
            Text(verbatim: itemID.rawValue).opacity(confirmation == nil ? 1 : 0)
            if confirmation != nil { Text("Copied") }
        }
        .harklightType(.messageIDPill)
        .foregroundStyle(.secondary)
    }
}

private struct RequestDetailMetadata: View {
    let inboxPriority: InboxMessagePriority?
    let inboxScore: Double?
    let deadline: Date?
    let stake: String?
    let key: RequestKey
    let supersedesMessageIDs: [ExactText]
    let secondaryTextColor: Color

    var body: some View {
        Group {
            if let priorityLabel = InboxPriorityDisplay.forEntry(score: inboxScore, priority: inboxPriority) {
                Label {
                    Text(priorityLabel.title)
                } icon: {
                    Image(systemName: "flag.fill")
                }
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel(Text(priorityLabel.title))
                    .accessibilityIdentifier("request-priority")
            }
            if let deadline {
                Label("Deadline · \(deadline.formatted(date: .omitted, time: .shortened))",
                      systemImage: "calendar")
                    .font(.subheadline)
                    .accessibilityIdentifier("request-deadline")
            }
            if let stake {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What’s at stake")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryTextColor)
                    Text(MessageMarkdown.attributed(stake))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("request-stake")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !supersedesMessageIDs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Supersedes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryTextColor)
                    ForEach(supersedesMessageIDs, id: \.self) { messageID in
                        let targetKey = RequestKey(accountScope: key.accountScope,
                            senderID: key.senderID, messageID: messageID)
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
        }
    }
}

private struct RequestDetailLifecycleContent: View {
    let isCurrent: Bool
    let lifecycleText: String?
    let replyText: String?
    let seenStatus: InformationalSeenStatus?
    let localOperationStatus: String?
    let showsDefaultAnswer: Bool
    let defaultAnswerWords: String?
    let textColor: Color
    let secondaryTextColor: Color

    var body: some View {
        Group {
            if isCurrent {
                if let lifecycleText {
                    Text(lifecycleText)
                        .font(.caption).foregroundStyle(secondaryTextColor)
                        .accessibilityIdentifier("request-lifecycle-status")
                }
                if let replyText {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reply")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(secondaryTextColor)
                        Text(replyText)
                            .font(.subheadline)
                            .foregroundStyle(textColor)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("request-account-answer")
                    }
                }
                if let seenStatus {
                    Label(LiveRequestDetail.informationalSeenText(seenStatus),
                          systemImage: LiveRequestDetail.informationalSeenSymbol(seenStatus))
                        .font(.caption).foregroundStyle(secondaryTextColor)
                        .accessibilityIdentifier("informational-seen-status")
                }
            } else {
                Label("Cached history · status not refreshed", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(secondaryTextColor)
                    .accessibilityIdentifier("inbox-status-unrefreshed")
                if let localOperationStatus {
                    Text(localOperationStatus).font(.caption).foregroundStyle(secondaryTextColor)
                }
            }
            if showsDefaultAnswer {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Answered by default", systemImage: "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryTextColor)
                        .accessibilityIdentifier("request-default-answer-status")
                    if let defaultAnswerWords, !defaultAnswerWords.isEmpty {
                        Text(defaultAnswerWords)
                            .font(.subheadline)
                            .foregroundStyle(textColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("request-default-answer")
                    }
                }
            }
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
        let shared: APISharedItem?
        let sharedAnswerStatusText: String?
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
    private struct DetailPresentationState {
        var chatPresented: Bool = false
        var pendingChatScrollTarget: ExactText? = nil
        var enlargedPicture: SampleOption? = nil
        var fixtureOutcomePresented: Bool = false
        var requestDetailsPresented: Bool = false
        var warningDialog: WarningDialogKind? = nil
        var activeReplyEditor: ReplyEditorTarget? = nil
        var replyDraftSession: ReplyEditorDraftSession? = nil
        var localReplyEditingActive: Bool = false
        var storePresentationSnapshot: StorePresentationSnapshot
    }

    @State private var detailState: DetailPresentationState

    private var chatPresented: Bool {
        get { detailState.chatPresented }
        nonmutating set { detailState.chatPresented = newValue }
    }
    private var pendingChatScrollTarget: ExactText? {
        get { detailState.pendingChatScrollTarget }
        nonmutating set { detailState.pendingChatScrollTarget = newValue }
    }
    private var enlargedPicture: SampleOption? {
        get { detailState.enlargedPicture }
        nonmutating set { detailState.enlargedPicture = newValue }
    }
    private var fixtureOutcomePresented: Bool {
        get { detailState.fixtureOutcomePresented }
        nonmutating set { detailState.fixtureOutcomePresented = newValue }
    }
    private var requestDetailsPresented: Bool {
        get { detailState.requestDetailsPresented }
        nonmutating set { detailState.requestDetailsPresented = newValue }
    }
    private var warningDialog: WarningDialogKind? {
        get { detailState.warningDialog }
        nonmutating set { detailState.warningDialog = newValue }
    }
    private var activeReplyEditor: ReplyEditorTarget? {
        get { detailState.activeReplyEditor }
        nonmutating set { detailState.activeReplyEditor = newValue }
    }
    private var replyDraftSession: ReplyEditorDraftSession? {
        get { detailState.replyDraftSession }
        nonmutating set { detailState.replyDraftSession = newValue }
    }
    private var localReplyEditingActive: Bool {
        get { detailState.localReplyEditingActive }
        nonmutating set { detailState.localReplyEditingActive = newValue }
    }
    private var storePresentationSnapshot: StorePresentationSnapshot {
        get { detailState.storePresentationSnapshot }
        nonmutating set { detailState.storePresentationSnapshot = newValue }
    }
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
        let snapshot = Self.storePresentationSnapshot(request: request, store: store)
        let canSubmit = localExample == nil &&
            Self.canEditSnapshot(request: request, store: store, context: context)
        _detailState = State(initialValue: DetailPresentationState(
            replyDraftSession: canSubmit ? store.replyEditorSession(for: request) : nil,
            storePresentationSnapshot: snapshot))
    }

    private var detailColors: HarklightMessageColors {
        HarklightDesignSystem.palette(for: colorScheme).message(context.messageType)
    }

    private var isSinglePanePresentation: Bool {
        // Use the split view's current adaptive width, not a device or fold-state guess.
        horizontalSizeClass == .compact
    }

    private var isSupersedesReadOnly: Bool {
        context.isSupersedesTarget || request.lifecycleStatus == .superseded
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
        if request.informationalSeenStatus == nil,
           store.conversation(for: request.key)?.shared?.canAnswer == false { return false }
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
            conversationIndicator: thread.map { $0.hasUnreadAgentReply },
            shared: thread?.shared,
            sharedAnswerStatusText: thread?.sharedAnswerStatusText)
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
        // Changing a definitively failed answer replaces it: drop the failed
        // operation so the failure marks leave and the next send is new.
        if localReplySession?.hasLocalChanges == true {
            store.releaseDefinitiveFailureBeforeChange(request.key)
        }
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
                    NativePushedViewCoordinator.shared.noteReplyTextChanged()
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
                NativePushedViewCoordinator.shared.noteReplyTextChanged()
                if let inputID = target.inputID {
                    store.stageText(text, input: ExactText(inputID), action: ExactText(target.actionID),
                                    for: request.key, requestRevision: request.requestRevision)
                } else {
                    store.stageCompatibilityText(text, action: ExactText(target.actionID),
                                                 for: request.key, requestRevision: request.requestRevision)
                }
            })
    }

    var controlsReadOnly: Bool {
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

    private var progressSeenAlreadySet: Bool {
        request.messageProgress != nil && request.informationalSeenStatus == .available &&
            store.inboxRow(for: request.key)?.fyiServerSeen == true
    }

    private var availableSeenAction: ExactText? {
        guard request.informationalSeenStatus == .available, !progressSeenAlreadySet,
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
        // A failed Seen resends the same operation.
        if let retry = submissionDisplay.retryAction(.seen) {
            retry()
            return
        }
        if let localExample {
            guard localExample.canFinishLocally else { return }
            localExample.finishLocally()
        } else if let availableSeenAction {
            finishSeenAction(availableSeenAction, returnToList: returnToListIfSinglePane)
            return
        } else {
            return
        }
        returnToListIfSinglePane()
    }

    func finishSeenAction(_ action: ExactText, returnToList: () -> Void) {
        guard submitSeenAction(action) else { return }
        returnToList()
    }

    private var seenActionIsComplete: Bool {
        localExample?.localSeenSelected == true || seenActionPresentation.isCompleted
    }

    private var seenActionIsPending: Bool {
        seenActionPresentation.isPending
    }

    private var seenToolbarTint: Color? {
        guard !seenActionIsComplete, !seenActionIsPending else { return nil }
        return HarklightDesignSystem.palette(for: colorScheme).teal
    }

    private var finishSeenButton: some View {
        Button(action: finishSeenAction) {
            if seenActionIsComplete {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text("Seen")
                }
                    .padding(.horizontal, 6)
            } else if submissionDisplay.isFailed(.seen) {
                // A failed Seen reports pending; it shows the failure, not a spinner.
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme).coral)
            } else if seenActionIsPending || submissionDisplay.isSending(.seen) {
                // The check spins while Seen is sending.
                ProgressView()
                    .tint(HarklightDesignSystem.palette(for: colorScheme).text)
            } else {
                Image(systemName: "checkmark")
                    .foregroundStyle(seenToolbarTint == nil
                                     ? HarklightDesignSystem.palette(for: colorScheme).text
                                     : HarklightDesignSystem.palette(for: colorScheme).onBeam)
            }
        }
        .buttonStyle(.glassProminent)
        .tint(seenToolbarTint ?? HarklightDesignSystem.palette(for: colorScheme).raised)
        .disabled(submissionDisplay.retryAction(.seen) == nil &&
                  (sendControlsDisabled || !canFinishSeenAction || seenActionIsComplete))
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
        (answerIsComplete || isDurablyAccepted(.answer)) && !isSupersedesReadOnly
    }

    /// The server durably accepted this message's answer or No comment: that
    /// is its confirmation, so the control becomes its card without waiting
    /// for the final state. A later refusal changes the phase and reverts it.
    func isDurablyAccepted(_ kind: SubmissionControlPhase.Kind) -> Bool {
        guard localExample == nil, request.informationalSeenStatus == nil,
              !storePresentationSnapshot.isRetracted,
              submissionPhase?.kind == kind else { return false }
        return submissionPhase?.phase == .confirmed
    }

    /// A custom answer form that has been answered or got No comment shows its
    /// declared closing scene beneath the card: the state's own scene, or the
    /// form's fallback resolved scene. The projection carries that scene once
    /// the request has reached either state.
    static func closingSceneProjection(_ projection: AdmittedRequestProjection,
                                       lifecycleStatus: AppLifecycleStatus) -> AdmittedSenderProjection? {
        guard lifecycleStatus == .answered || lifecycleStatus == .noComment,
              case let .sender(sender) = projection else { return nil }
        return sender
    }

    @ViewBuilder
    private var closingScene: some View {
        if let sender = Self.closingSceneProjection(request.projection,
                                                    lifecycleStatus: request.lifecycleStatus) {
            LiveProjectedSceneView(request: request, sender: sender, node: sender.scene,
                                   store: store, readOnly: true, hideAnswerControls: true,
                                   focusedReplyActionID: $focusedReplyActionID,
                                   replyTextBinding: { replyTextBinding(for: $0) },
                                   enlargePicture: { enlargedPicture = $0 })
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("request-closing-scene")
        }
    }

    /// A confirmed answer shows only the check and the answer; a default
    /// answer still says so, because that is a reason the person can't see.
    static func answeredConfirmationTitle(isDefaultAnswered: Bool) -> LocalizedStringResource? {
        isDefaultAnswered ? "Answered by default" : nil
    }

    private var showsNoCommentConfirmation: Bool {
        Self.showsNoCommentConfirmation(lifecycleStatus: request.lifecycleStatus,
                                       isSupersedesReadOnly: isSupersedesReadOnly) ||
            (isDurablyAccepted(.noComment) && !isSupersedesReadOnly)
    }

    static func showsNoCommentConfirmation(lifecycleStatus: AppLifecycleStatus,
                                           isSupersedesReadOnly: Bool) -> Bool {
        lifecycleStatus == .noComment && !isSupersedesReadOnly
    }

    var showsPendingAnswerConfirmation: Bool {
        !isSupersedesReadOnly && !storePresentationSnapshot.isRetracted &&
            request.lifecycleStatus == .pending && request.intentReceipt != nil && !request.answerNotDelivered
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

    var pendingAnswerText: String? { attemptedAnswerText }

    private var attemptedAnswerText: String? {
        AnswerConfirmationText.formatted(accountAnswerOutcome: nil,
            submittedAnswer: request.submittedAnswer,
            projection: request.projection)
    }

    /// A send acknowledgement is not the final request state. Keep its saved
    /// answer pending until the Server reports an answered terminal.
    static func answerStatusIsComplete(lifecycleStatus: AppLifecycleStatus,
                                       ownOutcome: OwnOutcome?,
                                       answerNotDelivered: Bool) -> Bool {
        guard !answerNotDelivered else { return false }
        return lifecycleStatus == .answered
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
        if localState == .refusedClosed { return "This message was closed." }
        if localState == .refusedNotFound { return "This request is no longer available" }
        // A plain failure has no status line: the control that sent it shows
        // the circled mark and Retry.
        if answerNotDelivered || localState == .notDelivered { return nil }
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
        .tint(HarklightColor(token: .coral))
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
        .tint(HarklightColor(token: .coral))
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

    var canSubmitCurrentAnswer: Bool {
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
        return store.canSendToCurrentServer
    }

    private var canOfferNoComment: Bool {
        guard !isSupersedesReadOnly, request.informationalSeenStatus == nil else { return false }
        if let localReplySession { return localReplySession.canSubmitFromSnapshot }
        if let localExample { return localExample.canDeclineLocally }
        if let fixtureStore { return fixtureStore.canSendNoCommentLocally(for: request.key) }
        if unlocksAfterDefinitiveFailure { return store.canSendToCurrentServer }
        guard !store.isReadOnly, store.canSendToCurrentServer,
              !store.isRetracted(request.key), request.lifecycleStatus == .open,
              request.intentReceipt == nil else { return false }
        return true
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

    private func submitSeenAction(_ action: ExactText) -> Bool {
        if let localSeenAction {
            localSeenAction(action)
            return true
        } else {
            return store.submitFromUser(request.key, explicitCompatibilityAction: action,
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
        return Self.canEditSnapshot(request: request, store: store, context: context) ||
            unlocksAfterDefinitiveFailure
    }

    /// After a definitive failure the controls open again: picking another
    /// answer or sending drops the failed operation first, so the next send is
    /// a new one. A lost send stays locked apart from its Retry.
    var unlocksAfterDefinitiveFailure: Bool {
        guard localExample == nil, !context.isSupersedesTarget, !store.isReadOnly,
              !store.isRetracted(request.key), store.canSubmitAnswer(for: request.key),
              request.lifecycleStatus == .open || request.lifecycleStatus == .pending,
              case .failed(_, editable: true)? = submissionPhase?.phase,
              submissionPhase?.kind != .seen else { return false }
        return true
    }

    /// The No comment row: offered for a new answer, and kept while a sent
    /// No comment is in flight or failed so it can carry that state.
    var showsNoCommentRow: Bool {
        if canOfferNoComment { return true }
        guard request.informationalSeenStatus == nil, !isSupersedesReadOnly,
              submissionPhase?.kind == .noComment else { return false }
        switch submissionPhase?.phase {
        case .sending?, .failed?: return true
        default: return false
        }
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

    /// The latest answer, No comment or Seen sent from this message, for the
    /// control that sent it.
    var submissionPhase: SubmissionControlPhase? {
        SubmissionPhaseTestHook.phase(for: request.key) ?? store.submissionPhases[request.key]
    }

    var submissionDisplay: SubmissionDisplay {
        SubmissionDisplay(phase: submissionPhase, retry: { [store, key = request.key] in
            _ = store.retrySubmissionFromUser(key)
        }, edit: { [store, key = request.key] in
            _ = store.releaseFailedSubmissionForEdit(key)
        })
    }

    private func submissionReasonLine(_ reason: String) -> some View {
        Text(reason)
            .harklightType(.newStatus)
            .foregroundStyle(detailColors.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("request-submission-reason")
    }

    private var answerConfirmation: AnswerConfirmationCard? {
        if showsAnsweredConfirmation {
            return AnswerConfirmationCard(
                title: Self.answeredConfirmationTitle(isDefaultAnswered: request.isDefaultAnswered),
                answer: confirmedAnswerText,
                identifier: "request-answered",
                accessibilityValue: "Completed",
                symbolName: MessageIconRole.answered.token.sfSymbol,
                answerIdentifier: request.isDefaultAnswered
                    ? "request-default-answer" : "request-account-answer")
        } else if showsNoCommentConfirmation {
            return AnswerConfirmationCard(title: "No comment", answer: nil,
                identifier: "request-no-comment-status",
                accessibilityValue: "Completed", symbolName: "checkmark")
        }
        // Sending and failed sends show in the control that sent them
        // (submissionPhase), not as separate Pending or Not accepted cards.
        return nil
    }

    private var lifecycleStatusText: String? {
        guard request.inboxStateIsCurrent else { return nil }
        if storePresentationSnapshot.isRetracted { return storePresentationSnapshot.retractionLabel }
        if let answerStatus = storePresentationSnapshot.sharedAnswerStatusText { return answerStatus }
        // Pending is shown by the control that is sending, not as a line.
        if isSupersedesReadOnly || (request.lifecycleStatus != .open &&
            request.lifecycleStatus != .answered && request.lifecycleStatus != .pending &&
            !showsNoCommentConfirmation) {
            return String(localized: LiveLifecycleTitle(request.lifecycleStatus).label)
        }
        return nil
    }

    private var lifecycleReplyText: String? {
        guard request.inboxStateIsCurrent, !showsAnsweredConfirmation,
              case let .reply(text)? = request.accountAnswerOutcome else { return nil }
        return text.rawValue
    }

    private var lifecycleSeenStatus: InformationalSeenStatus? {
        guard request.inboxStateIsCurrent, let status = request.informationalSeenStatus,
              (status != .available || isSupersedesReadOnly),
              !(seenActionIsComplete && !isSupersedesReadOnly) else { return nil }
        return status
    }

    var body: some View {
        MessageCardSurface(context: context,
                           replyEditorIsOpen: activeReplyEditor != nil || focusedReplyActionID != nil,
                           onDownwardContentSwipe: {
                               focusedReplyActionID = nil
                           }) {
            VStack(alignment: .leading, spacing: 12) {
                MessageHeading(sender: senderLabel, initials: senderInitials,
                    title: request.title?.rawValue ?? "Message", createdAt: request.createdAt,
                    messageType: context.messageType,
                    metadata: MessageMetadataPresentation(declaredType: request.messageType, kind: request.messageKind,
                                                          hasSeenDescriptor: request.informationalSeenStatus != nil),
                    detail: .init(itemID: localExample == nil && !store.isLocalExample ? request.key.messageID : nil,
                                  onOpenDetails: { requestDetailsPresented = true }))
                RequestDetailMetadata(inboxPriority: request.inboxPriority,
                    inboxScore: request.inboxScore,
                    deadline: byWhenDate, stake: request.stakeText?.rawValue,
                    key: request.key, supersedesMessageIDs: request.supersedesMessageIDs,
                    secondaryTextColor: detailColors.secondary)
                if let shared = storePresentationSnapshot.shared, !shared.members.isEmpty {
                    DisclosureGroup("People and Seen") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(shared.members, id: \.person.id) { member in
                                let seen = member.seenRevision == request.requestRevision
                                LabeledContent {
                                    Text(seen ? "Seen" : "Unseen")
                                        .foregroundStyle(detailColors.secondary)
                                } label: {
                                    Text(verbatim: member.person.displayName.rawValue)
                                }
                            }
                        }
                        .font(.subheadline)
                    }
                    .accessibilityIdentifier("request-shared-members")
                }
                if let shared = storePresentationSnapshot.shared {
                    let answers = SharedAnswerPresentation.rows(in: shared)
                    if !answers.isEmpty {
                        DisclosureGroup("Answers") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(answers) { answer in
                                    LabeledContent {
                                        Text(verbatim: answer.answer).textSelection(.enabled)
                                    } label: {
                                        Text(verbatim: answer.name)
                                    }
                                }
                            }
                            .font(.subheadline)
                        }
                        .accessibilityIdentifier("request-shared-answers")
                    }
                }
                if !request.supersededByMessageKeys.isEmpty {
                    ReplacedByMessagesSection(
                        replacementKeys: request.supersededByMessageKeys,
                        messageLabel: store.relatedMessageLabel,
                        secondaryTextColor: detailColors.secondary)
                }
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
                            .font(.subheadline).foregroundStyle(detailColors.secondary)
                            .accessibilityIdentifier(localExample.noCommentSelected
                                ? "request-local-no-comment-status"
                                : "request-local-answer-status")
                    }
                }
                HistoricalVersionAccess(key: request.key, store: store,
                    currentRevision: storePresentationSnapshot.conversationRevision,
                    hasAcceptedUpdate: storePresentationSnapshot.hasAcceptedUpdate,
                    secondaryTextColor: detailColors.secondary,
                    messageTextColor: detailColors.text,
                    messageBackgroundColor: detailColors.tint)
                if storePresentationSnapshot.isRetracted {
                    Text("The sender retracted this request. Saved work and its original delivery status are retained; no further answer will be sent.")
                        .font(.caption).foregroundStyle(detailColors.secondary)
                }
                if let body = request.body {
                    SystemDetectedMessageBody(text: body.rawValue,
                                               foregroundColor: detailColors.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if localExample?.message.kind == .review {
                    SampleDiffView()
                }
                if let answerConfirmation {
                    answerConfirmation
                    if showsAnsweredConfirmation || showsNoCommentConfirmation { closingScene }
                } else if case let .compatibility(actions) = request.projection,
                          let seenStatus = request.informationalSeenStatus {
                    if let reason = submissionDisplay.reasonLine {
                        submissionReasonLine(reason)
                    }
                    InformationalSeenControl(status: seenStatus,
                        locallyCompleted: localExample?.localSeenSelected == true,
                        hidden: isSupersedesReadOnly || progressSeenAlreadySet,
                        sendDisabled: sendControlsDisabled,
                        textColor: detailColors.text,
                        secondaryTextColor: detailColors.secondary,
                        onSeen: {
                            guard let action = actions.first else { return }
                            finishSeenAction(action.id, returnToList: returnToListIfSinglePane)
                        })
                    .environment(\.harklightSubmissionDisplay, submissionDisplay)
                } else {
                    if let reason = submissionDisplay.reasonLine {
                        submissionReasonLine(reason)
                    }
                    LiveRequestAnswerControls(
                        request: request, store: store,
                        controlsReadOnly: controlsReadOnly,
                        isSupersedesReadOnly: isSupersedesReadOnly,
                        sendControlsDisabled: sendControlsDisabled,
                        localExample: localExample,
                        canOfferNoComment: showsNoCommentRow,
                        noCommentSelected: noCommentSelected,
                        showsNoCommentUnavailable: showsNoCommentUnavailable,
                        canOpenFailureDetails: failedResponseWarning != nil,
                        secondaryTextColor: detailColors.secondary,
                        focusedReplyActionID: $focusedReplyActionID,
                        activeReplyEditor: activeReplyEditor,
                        localReplySession: localReplySession,
                        openReplyEditor: openReplyEditor,
                        replyTextBinding: { replyTextBinding(for: $0) },
                        closeReplyEditor: closeReplyEditor,
                        markLocalReplyInteraction: markLocalReplyInteraction,
                        selectNoCommentAction: selectNoCommentAction,
                        onSeen: { action in
                            finishSeenAction(action, returnToList: returnToListIfSinglePane)
                        },
                        enlargePicture: { enlargedPicture = $0 })
                    .environment(\.harklightSubmissionDisplay, submissionDisplay)
                    // While one answer is sending, the other controls step back.
                    .disabled(submissionDisplay.isSendingAny)
                }
                RequestDetailLifecycleContent(
                    isCurrent: request.inboxStateIsCurrent,
                    lifecycleText: lifecycleStatusText,
                    replyText: lifecycleReplyText,
                    seenStatus: lifecycleSeenStatus,
                    // Send states show in the controls themselves, never as a line here.
                    localOperationStatus: nil,
                    showsDefaultAnswer: request.isDefaultAnswered && !showsAnsweredConfirmation,
                    defaultAnswerWords: request.defaultAnswerWords,
                    textColor: detailColors.text,
                    secondaryTextColor: detailColors.secondary)
                // Retry lives in the control that failed; there is no separate
                // Retry or Refresh status button under the answers.
                if !isSupersedesReadOnly, let fixtureStore, request.lifecycleStatus == .pending {
                    Button("Simulate fixture outcome", systemImage: "testtube.2") {
                        fixtureOutcomePresented = true
                    }
                    .accessibilityIdentifier("fixture-outcome-menu")
                    .confirmationDialog("Simulate fixture outcome",
                                        isPresented: $detailState.fixtureOutcomePresented,
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
                        .foregroundStyle(.hkCoral)
                        .accessibilityIdentifier("request-action-error")
                } else if localExample == nil, fixtureStore == nil,
                          request.lifecycleStatus == .open,
                          let reason = store.actionUnavailableReason(for: request.key) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(detailColors.secondary)
                        .accessibilityIdentifier("request-action-unavailable")
                }
                if let statusText = answerStatusText {
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(detailColors.secondary)
                        .accessibilityIdentifier("request-receipt-evidence")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(detailColors.text)
            .tint(detailColors.text)
        }
        .toolbar {
            if skippedMessageWarning != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    skippedMessageWarningButton
                }
            }
            // Delivery details stay one tap away, beside the check rather than
            // in its place: the check comes back after a failed send.
            if failedResponseWarning != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    failedResponseWarningButton
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                chatButton
            }
            // The action check stays in place once it cannot apply (completed,
            // answered or superseded), shown greyed out rather than removed.
            ToolbarItem(placement: .confirmationAction) {
                if isSupersedesReadOnly {
                    if request.informationalSeenStatus != nil {
                        if !progressSeenAlreadySet { finishSeenButton.disabled(true) }
                    } else {
                        submitReplyButton.disabled(true)
                    }
                } else if request.informationalSeenStatus != nil {
                    if !progressSeenAlreadySet { finishSeenButton }
                } else if let localExample {
                    Button {
                        closeReplyEditor()
                        localExample.finishLocally()
                    } label: {
                        Label("Finish locally", systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme).onInverse)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(HarklightDesignSystem.palette(for: colorScheme).inverse)
                    .disabled(!localExample.canFinishLocally || localExample.finished ||
                              localExample.localSeenSelected)
                    .accessibilityIdentifier("sample-finish")
                } else if isEditingLocalReply {
                    submitReplyButton
                } else if showsAnsweredConfirmation || showsNoCommentConfirmation ||
                            showsNotAcceptedConfirmation {
                    submitReplyButton.disabled(true)
                } else {
                    submitReplyButton
                }
            }
        }
        .modifier(DetailPresentationModifier(
            enlargedPicture: $detailState.enlargedPicture,
            requestDetailsPresented: $detailState.requestDetailsPresented,
            warningDialog: $detailState.warningDialog,
            chatPresented: $detailState.chatPresented,
            pendingChatScrollTarget: $detailState.pendingChatScrollTarget,
            requestKey: request.key, store: store,
            failedResponseWarning: failedResponseWarning,
            skippedMessageWarning: skippedMessageWarning,
            testNotificationRouter: testNotificationRouter,
            testOpenForegroundChatIndicator: testOpenForegroundChatIndicator,
            requestDetailsSheet: { requestDetailsSheet },
            conversationPanel: { conversationPanel }))
        .modifier(DetailChangeEffects(
            inlineChat: context.inlineChat,
            chatTargetFallsBackToMessage: context.chatTargetFallsBackToMessage,
            notificationChatRouteSerial: context.notificationChatRouteSerial,
            request: request, conversationThreads: store.conversationThreads,
            focusedReplyActionID: focusedReplyActionID,
            failedResponseWarning: failedResponseWarning,
            skippedMessageWarning: skippedMessageWarning,
            chatPresented: $detailState.chatPresented, warningDialog: $detailState.warningDialog,
            openNotificationChat: openNotificationChat,
            refreshRequestPresentation: refreshRequestPresentation,
            activateReplyFocus: activateReplyFocus,
            resetReplyForRequest: resetReplyForRequest))
        .preference(key: ReplyEditorFocusKey.self, value: focusedReplyActionID != nil)
    }

    private struct RequestDetailsSheet: View {
        let sender: String
        let messageID: String
        let originalContentJSON: String
        let answerJSON: String?
        let receiptEvidence: String?
        @Binding var isPresented: Bool

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Sender: \(sender)")
                        Text("Message: \(messageID)")
                        Text(originalContentJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("request-original-content-json")
                        if let answerJSON {
                            Text("Original answer")
                                .font(.headline)
                            Text(answerJSON)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .accessibilityIdentifier("request-details-original-answer-json")
                        }
                        if let receiptEvidence {
                            Text("Receipt evidence")
                                .font(.headline)
                            Text(receiptEvidence)
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
                        Button("Done") { isPresented = false }
                            .accessibilityIdentifier("request-details-done")
                    }
                }
            }
        }
    }

    private struct DetailPresentationModifier: ViewModifier {
        @Binding var enlargedPicture: SampleOption?
        @Binding var requestDetailsPresented: Bool
        @Binding var warningDialog: WarningDialogKind?
        @Binding var chatPresented: Bool
        @Binding var pendingChatScrollTarget: ExactText?
        let requestKey: RequestKey
        let store: LivePresentationStore
        let failedResponseWarning: LivePresentationStore.FailedResponseWarning?
        let skippedMessageWarning: LivePresentationStore.SkippedMessageWarning?
        let testNotificationRouter: NativeNotificationRouter?
        let testOpenForegroundChatIndicator: (() -> Void)?
        let requestDetailsSheet: () -> RequestDetailsSheet
        let conversationPanel: () -> ConversationPanel

        func body(content: Content) -> some View {
            content
            .sheet(item: $enlargedPicture) { picture in
                SamplePictureViewer(initialPicture: picture)
                    .foregroundChatNotificationLayer(testRouter: testNotificationRouter,
                                                     testOpen: testOpenForegroundChatIndicator)
            }
            .sheet(isPresented: $requestDetailsPresented) {
                requestDetailsSheet()
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
                                canRetry: store.canRetryFailedResponse(for: requestKey),
                                onRetry: { _ = store.retryFailedResponse(for: requestKey) },
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
                conversationPanel()
                    .foregroundChatNotificationLayer(testRouter: testNotificationRouter,
                                                     testOpen: testOpenForegroundChatIndicator)
                    .harklightSheetSurface()
            }
        }
    }

    private struct DetailChangeEffects: ViewModifier {
        let inlineChat: Bool
        let chatTargetFallsBackToMessage: Bool
        let notificationChatRouteSerial: UInt64?
        let request: PresentedRequest
        let conversationThreads: [RequestKey: ConversationThread]
        let focusedReplyActionID: String?
        let failedResponseWarning: LivePresentationStore.FailedResponseWarning?
        let skippedMessageWarning: LivePresentationStore.SkippedMessageWarning?
        @Binding var chatPresented: Bool
        @Binding var warningDialog: WarningDialogKind?
        let openNotificationChat: () -> Void
        let refreshRequestPresentation: () -> Void
        let activateReplyFocus: () -> Void
        let resetReplyForRequest: () -> Void

        func body(content: Content) -> some View {
            content
            .onChange(of: inlineChat) { _, inline in
                if inline { chatPresented = false }
            }
            .onChange(of: chatTargetFallsBackToMessage) { _, fallsBack in
                if fallsBack { chatPresented = false }
            }
            .onChange(of: notificationChatRouteSerial, initial: true) { _, serial in
                guard serial != nil else { return }
                openNotificationChat()
            }
            .onChange(of: request) { _, _ in
                refreshRequestPresentation()
            }
            .onChange(of: focusedReplyActionID) { _, focused in
                if focused != nil {
                    activateReplyFocus()
                }
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
            .onChange(of: conversationThreads) { _, _ in
                refreshRequestPresentation()
            }
            .onChange(of: request.key) { _, _ in
                resetReplyForRequest()
            }
        }
    }

    private func openNotificationChat() {
        // Capture the scroll target before didOpen, which may clear the route.
        pendingChatScrollTarget = context.chatScrollTargetTurnID
        if !context.inlineChat { chatPresented = true }
        context.notificationChatRouteDidOpen?()
    }

    private func refreshRequestPresentation() {
        refreshStorePresentationSnapshot()
        refreshUneditedReplySession()
    }

    private func activateReplyFocus() {
        NativePushedViewCoordinator.shared.replyEditorFocusChanged(true, resetActivity: true)
        activatePassivePushContent()
    }

    private func resetReplyForRequest() {
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
        Button {
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
        } label: {
            if submissionIsSendingAnswer {
                // The send itself spins until the server answers.
                ProgressView()
                    .tint(HarklightDesignSystem.palette(for: colorScheme).onInverse)
                    .accessibilityLabel("Sending")
            } else {
                Label(submitLabel, systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme).onInverse)
            }
        }
        .buttonStyle(.glassProminent)
        .tint(HarklightDesignSystem.palette(for: colorScheme).inverse)
        .disabled(submissionIsSendingAnswer || (isEditingLocalReply
                  ? !canSubmitCurrentAnswer
                  : (fixtureStore.map { !$0.canSend(for: request.key) } ?? !canSubmitCurrentAnswer)))
        .accessibilityIdentifier("request-finish")
    }

    private var submissionIsSendingAnswer: Bool {
        submissionDisplay.isSending(.answer) || submissionDisplay.isSending(.noComment)
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
        Button {
            if localExample == nil {
                activatePassivePushContent()
                NativePushedViewCoordinator.shared.recordOwnOpen()
            }
            localExample?.chatRead = true
            if context.inlineChat, let reopenInlineChat = context.reopenInlineChat {
                reopenInlineChat()
            } else {
                chatPresented = true
            }
        } label: {
            Label("Chat", systemImage: "bubble.left")
                .labelStyle(.iconOnly)
                .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme).text)
        }
        .tint(HarklightDesignSystem.palette(for: colorScheme).text)
        .badge(conversationIndicator == true ? 1 : 0)
        .accessibilityLabel("Chat")
        .accessibilityHint(conversationIndicator == true ? "Unread conversation" : "")
    }

    private func activatePassivePushContent() {
        guard localExample == nil else { return }
        NativePushedViewCoordinator.shared.contentWasTouched(request.key) {
            store.reportMessageContentOpened(request)
        }
    }

    private var requestDetailsSheet: RequestDetailsSheet {
        RequestDetailsSheet(sender: detailSenderLabel, messageID: request.key.messageID.rawValue,
            originalContentJSON: request.originalContentJSON,
            answerJSON: request.intentReceipt?.exactAnswerJSON,
            receiptEvidence: request.receiptFacts?.evidenceLabel,
            isPresented: $detailState.requestDetailsPresented)
    }

    private var conversationIndicator: Bool? {
        if let localExample {
            return localExample.message.hasChat
                ? localExample.message.chatUnread && !localExample.chatRead : nil
        }
        return storePresentationSnapshot.conversationIndicator
    }

    private var conversationPanel: ConversationPanel {
        ConversationPanel(store: store, key: request.key,
            sender: detailSenderLabel, title: request.title?.rawValue ?? "",
            initialScrollTurnID: pendingChatScrollTarget,
            testNotificationRouter: testNotificationRouter,
            testOpenForegroundChatIndicator: testOpenForegroundChatIndicator,
            testConversationSheetDidAppear: testConversationSheetDidAppear,
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

    fileprivate static func informationalSeenSymbol(_ status: InformationalSeenStatus) -> String {
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
                .font(.caption).foregroundStyle(.hkSecondary)
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
                .foregroundStyle(.hkSecondary)
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
                .font(.callout).foregroundStyle(.hkSecondary)
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

/// A concrete boundary keeps the answer projection's generic view tree out of
/// the surrounding card and its sheets. Draft and navigation state stay above it.
@MainActor
private struct LiveRequestAnswerControls: View {
    let request: PresentedRequest
    let store: LivePresentationStore
    let controlsReadOnly: Bool
    let isSupersedesReadOnly: Bool
    let sendControlsDisabled: Bool
    let localExample: SampleResponse?
    let canOfferNoComment: Bool
    let noCommentSelected: Bool
    let showsNoCommentUnavailable: Bool
    let canOpenFailureDetails: Bool
    let secondaryTextColor: Color
    @FocusState.Binding var focusedReplyActionID: String?
    let activeReplyEditor: ReplyEditorTarget?
    let localReplySession: ReplyEditorDraftSession?
    let openReplyEditor: (ReplyEditorTarget) -> Void
    let replyTextBinding: (ReplyEditorTarget) -> Binding<String>
    let closeReplyEditor: () -> Void
    let markLocalReplyInteraction: () -> Void
    let selectNoCommentAction: () -> Void
    let onSeen: (ExactText) -> Void
    let enlargePicture: (SampleOption) -> Void

    private var noCommentChoice: some View {
        NoCommentChoiceRow(selected: noCommentSelected,
                           unavailable: showsNoCommentUnavailable,
                           canOpenFailureDetails: canOpenFailureDetails,
                           onSelect: selectNoCommentAction)
    }

    /// A picked choice or written reply already carries a failed answer's
    /// state; a form of typed or point inputs carries it below its fields.
    private func showsFailureInPickedChoice(_ sender: AdmittedSenderProjection) -> Bool {
        let answer = request.failedAnswer ?? request.submittedAnswer ?? request.draft
        return sender.inputs.contains { input in
            guard case .response = input.kind else { return false }
            return answer.inputs[input.id]?.selectedActionID != nil
        }
    }

    var body: some View {
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
                                       replyTextBinding: { replyTextBinding($0) },
                                       closeReplyEditor: closeReplyEditor,
                                       onLocalReplyInteraction: markLocalReplyInteraction,
                                       localExample: localExample,
                                       enlargePicture: enlargePicture)
                if !isSupersedesReadOnly, !showsFailureInPickedChoice(sender) {
                    FormSubmissionFailureRow()
                }
                if canOfferNoComment { noCommentChoice }
            }
        case let .compatibility(actions):
            if request.customAnswerScreenNotShown {
                // Client API v2 (APP-09/10): a screen this app cannot show is
                // replaced by the plain reply, and the person is told why.
                Text("The sender's custom answer screen isn't shown. You can reply in text.")
                    .font(.callout)
                    .foregroundStyle(secondaryTextColor)
                    .accessibilityIdentifier("custom-answer-screen-not-shown")
            }
            LiveCompatibilityActions(request: request,
                                     actions: actions,
                                     store: store,
                                     readOnly: controlsReadOnly,
                                     hideAnswerControls: isSupersedesReadOnly,
                                     sendDisabled: sendControlsDisabled,
                                     localExample: localExample,
                                     onSeen: onSeen,
                                     canOfferNoComment: canOfferNoComment,
                                     noCommentSelected: noCommentSelected,
                                     noCommentUnavailable: showsNoCommentUnavailable,
                                     canOpenFailureDetails: canOpenFailureDetails,
                                     onSelectNoComment: selectNoCommentAction,
                                     focusedReplyActionID: $focusedReplyActionID,
                                     replyTextBinding: { replyTextBinding($0) },
                                     localReplyDraftSession: localReplySession,
                                     activeReplyEditor: activeReplyEditor,
                                     openReplyEditor: { openReplyEditor($0) },
                                     closeReplyEditor: closeReplyEditor,
                                     onLocalReplyInteraction: markLocalReplyInteraction)
        case .unsupported:
            VStack(alignment: .leading, spacing: 10) {
                Text("This request uses an unsupported answer format.")
                    .foregroundStyle(secondaryTextColor)
                if canOfferNoComment { noCommentChoice }
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
    @Environment(\.harklightSubmissionDisplay) private var submission

    /// Typed and point inputs stay locked after a failed send until Edit;
    /// choices open again so another answer can be picked.
    private var inputLocked: Bool { readOnly || submission.isFailed(.answer) }

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

    private var detailColors: HarklightMessageColors {
        HarklightDesignSystem.palette(for: colorScheme).message(messageType)
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
                    NativePushedViewCoordinator.shared.noteReplyTextChanged()
                    onLocalReplyInteraction()
                    localReplyDraftSession.updateText($0, target: target)
                })
        }
        return Binding(
            get: { typedInputTextByRevision[request.requestRevision] ?? draft?.text?.rawValue ?? "" },
            set: {
                NativePushedViewCoordinator.shared.noteReplyTextChanged()
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
            prompt: Text(input.label.rawValue).foregroundColor(detailColors.secondary),
            axis: .vertical
        )
            .lineLimit(4...8)
            .textFieldStyle(.plain)
            .harklightType(.messageBody)
            .foregroundStyle(detailColors.text)
            .tint(detailColors.text)
            .padding(12)
            .background(detailColors.field, in: RoundedRectangle(cornerRadius: HarklightDesignSystem.shape(.small)))
            .overlay(RoundedRectangle(cornerRadius: HarklightDesignSystem.shape(.small))
                .strokeBorder(detailColors.line, lineWidth: HarklightDesignSystem.shape(.lineWidth)))
            .accessibilityLabel(input.label.rawValue)
            .accessibilityIdentifier("request-input-" + input.id.rawValue)
            .focused($focusedReplyActionID, equals: target.actionIdentifier)
            .onChange(of: focusedReplyActionID) { _, focused in
                if focused == target.actionIdentifier {
                    NativePushedViewCoordinator.shared.replyEditorFocusChanged(true,
                                                                               resetActivity: true)
                    activatePassivePushContent()
                }
                guard focused == target.actionIdentifier else { return }
                onLocalReplyInteraction()
                openReplyEditor(target)
            }
            .disabled(inputLocked)
    }

    private func activatePassivePushContent() {
        guard localExample == nil else { return }
        NativePushedViewCoordinator.shared.contentWasTouched(request.key) {
            store.reportMessageContentOpened(request)
        }
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
                                                    guard !inputLocked else { return }
                                                    var capture = pointGestureCapture
                                                    _ = capture.update(at: value.location, in: bounds)
                                                    pointGestureCapture = capture
                                                }
                                                .onEnded { value in
                                                    defer { pointGestureCapture.gestureDidEnd() }
                                                    guard !inputLocked else { return }
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
                                                }, isEnabled: !inputLocked)
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
                                .accessibilityHint(inputLocked ? "Read-only illustration." : "Tap or drag to select a point.")
                                .accessibilityAction(named: "Set point at center") {
                                    guard !inputLocked else { return }
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
            liveChoiceButton(style: action.style, selected: selected, readOnly: readOnly,
                             perform: { activate(action) }) {
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
        }
    }

}

@MainActor
private struct InformationalSeenControl: View {
    let status: InformationalSeenStatus
    let locallyCompleted: Bool
    let hidden: Bool
    let sendDisabled: Bool
    let textColor: Color
    let secondaryTextColor: Color
    let onSeen: () -> Void

    @Environment(\.harklightSubmissionDisplay) private var submission
    @Environment(\.colorScheme) private var colorScheme

    private var seenActionPresentation: SeenActionPresentation {
        SeenActionPresentation(status: status)
    }

    /// The Seen button while its send is in flight: a spinner in place.
    private var sendingSeenButton: some View {
        Button {} label: {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(textColor)
                Text("Seen")
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(true)
        .accessibilityLabel("Seen, sending")
        .accessibilityIdentifier("request-seen-action")
    }

    var body: some View {
        if hidden {
            EmptyView()
        } else if locallyCompleted || seenActionPresentation.isCompleted {
            AnswerConfirmationCard(title: "Seen", answer: nil,
                identifier: "request-seen-confirmation",
                accessibilityValue: "Completed", symbolName: "checkmark")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                switch status {
                case .available where submission.isSending(.seen):
                    sendingSeenButton
                case .available where submission.isFailed(.seen), .pending where submission.isFailed(.seen):
                    // It did not go through: the button itself offers Retry.
                    Button(action: submission.retryAction(.seen) ?? onSeen) {
                        Label {
                            Text("Retry Seen")
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme).coral)
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(textColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(submission.retryAction(.seen) == nil && sendDisabled)
                    .accessibilityIdentifier("request-seen-action")
                case .available:
                    Button(action: onSeen) {
                        Label("Seen", systemImage: "eye")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(textColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(sendDisabled)
                    .accessibilityLabel(Text(seenActionPresentation.accessibilityLabel))
                    .accessibilityValue(Text(seenActionPresentation.accessibilityValue))
                    .accessibilityIdentifier("request-seen-action")
                case .pending:
                    sendingSeenButton
                case .confirmed:
                    AnswerConfirmationCard(title: "Seen", answer: nil,
                        identifier: "request-seen-confirmation",
                        accessibilityValue: "Completed", symbolName: "checkmark")
                case .resolvedWithoutSeen:
                    Label("Resolved without Seen confirmation", systemImage: "checkmark.circle")
                }
            }
        }
    }
}

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

    private var detailColors: HarklightMessageColors {
        HarklightDesignSystem.palette(for: colorScheme).message(messageType)
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
                        target: target, isReadOnly: readOnly,
                        onOpen: { activate(action) })
    }

    @ViewBuilder
    var body: some View {
        if let seenStatus = request.informationalSeenStatus {
            InformationalSeenControl(status: seenStatus,
                locallyCompleted: localExample?.localSeenSelected == true,
                hidden: hideAnswerControls ||
                    (seenStatus == .available && request.messageProgress != nil &&
                        store.inboxRow(for: request.key)?.isUnseenFYI == false),
                sendDisabled: sendDisabled,
                textColor: detailColors.text,
                secondaryTextColor: detailColors.secondary,
                onSeen: {
                    guard seenStatus == .available, let action = actions.first else { return }
                    if let onSeen {
                        onSeen(action.id)
                    } else {
                        store.submitFromUser(request.key, explicitCompatibilityAction: action.id,
                                             requestRevision: request.requestRevision)
                    }
                })
        } else if hideAnswerControls {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(actions, id: \.id) { action in
                    Text(action.label.rawValue)
                }
            }
        } else if seenActionIsComplete {
            AnswerConfirmationCard(title: "Seen", answer: nil,
                identifier: "request-seen-confirmation",
                accessibilityValue: "Completed", symbolName: "checkmark")
        } else {
            VStack(alignment: .leading, spacing: HarklightDesignSystem.shape(.choiceListSpacing)) {
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
                        liveChoiceButton(style: action.style, selected: isSelected, readOnly: readOnly,
                                         perform: { activate(action) }) {
                            MessageChoiceLabel(title: action.label.rawValue,
                                    detail: option?.detail ?? "",
                                    selected: isSelected, multiple: false,
                                    suggested: option.map { if case .suggested = $0.role { true } else { false } } ?? false)
                        }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
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

/// A failed form answer: the circled exclamation mark with Retry, which
/// resends the same operation, and Edit where the server definitively did not
/// take it. Shows nothing otherwise.
private struct FormSubmissionFailureRow: View {
    @Environment(\.harklightSubmissionDisplay) private var submission
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    var body: some View {
        if submission.isFailed(.answer) {
            HStack(spacing: 16) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme).coral)
                    .accessibilityLabel("Did not send")
                Spacer(minLength: 0)
                if submission.canEdit(.answer), let edit = submission.edit {
                    Button("Edit", action: edit)
                        .accessibilityIdentifier("request-form-edit")
                }
                if let retry = submission.retryAction(.answer) {
                    Button("Retry", action: retry)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("request-form-retry")
                }
            }
            .tint(HarklightDesignSystem.palette(for: colorScheme).message(messageType).beam)
            .padding(.vertical, 4)
        }
    }
}

private struct NoCommentChoiceRow: View {
    let selected: Bool
    let unavailable: Bool
    let canOpenFailureDetails: Bool
    let onSelect: () -> Void

    @Environment(\.harklightSubmissionDisplay) private var submission

    var body: some View {
        // A failed No comment that can retry resends the same operation.
        Button(action: selected ? (submission.retryAction(.noComment) ?? onSelect) : onSelect) {
            MessageChoiceLabel(title: "No comment", detail: "",
                               selected: selected, multiple: false,
                               suggested: false, submissionKind: .noComment)
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

extension ConversationThread {
    var sharedAnswerStatusText: String? {
        guard shared != nil, let answerSpeaker else { return nil }
        let name = answerSpeaker.displayName.rawValue
        return String(localized: "Answered by \(name)")
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
