import AttentionDomain
import Observation
import SwiftUI
import UniformTypeIdentifiers
import QuickLook

enum ConversationPanelEmptyState: Equatable {
    case noChat
    case checkingAvailability
    case chatUnavailable
    case connectionUnavailable
    case offline
    case availabilityUnconfirmed

    @MainActor
    static func resolve(availability: NativeConversationAvailability.State,
                        isRefreshing: Bool,
                        hasConnectionWarning: Bool,
                        canCheckAvailability: Bool) -> Self {
        if isRefreshing { return .checkingAvailability }
        if hasConnectionWarning { return .connectionUnavailable }

        switch availability {
        case .unavailable:
            return .chatUnavailable
        case .available:
            return .noChat
        case .unconfirmed:
            return canCheckAvailability ? .availabilityUnconfirmed : .offline
        }
    }
}

@MainActor
struct ConversationPanel: View {
    let store: LivePresentationStore
    let key: RequestKey
    let sender: String
    let title: String
    /// Scrolls this turn into view when the panel opens from a reply item.
    var initialScrollTurnID: ExactText? = nil
    var testNotificationRouter: NativeNotificationRouter? = nil
    var testOpenForegroundChatIndicator: (() -> Void)? = nil
    var testConversationSheetDidAppear: (() -> Void)? = nil
    @State private var selectedRevision: UInt64?
    @State private var inspectedFile: ConversationFile?
    @State private var inspectedFileRevision: UInt64?
    @State private var previewURL: URL?
    @State private var openingFile = false
    @State private var fileError: String?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    private var thread: ConversationThread? { store.conversation(for: key) }
    private var revision: UInt64 { selectedRevision ?? thread?.currentRevision ?? 1 }
    private var draft: ConversationDraft { store.conversationDraft(for: key, revision: revision) }

    private func hasNotAcceptedCardForRetainedAnswer(thread: ConversationThread,
                                                      request: PresentedRequest?) -> Bool {
        guard thread.isRetracted,
              let request,
              request.lifecycleStatus != .superseded,
              request.supersededByMessageKeys.isEmpty else { return false }
        let attemptedAnswer = AnswerConfirmationText.formatted(
            accountAnswerOutcome: nil,
            submittedAnswer: request.submittedAnswer,
            projection: request.projection)
        return LiveRequestDetail.shouldShowNotAcceptedConfirmation(
            isRetracted: true,
            isSupersedesReadOnly: false,
            ownOutcome: request.receiptFacts?.ownOutcome,
            relayOutcome: request.intentReceipt?.relayOutcome,
            attemptedAnswerText: attemptedAnswer,
            ownAnswerWasRefusedByRetraction: request.ownAnswerWasRefusedByRetraction)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let thread {
                let request = store.request(for: key)
                let hasNotAcceptedCard = hasNotAcceptedCardForRetainedAnswer(thread: thread,
                                                                              request: request)
                if thread.revisionNumbers.count > 1 {
                    Picker("Question version", selection: Binding(get: { revision }, set: { selectedRevision = $0 })) {
                        ForEach(thread.revisionNumbers, id: \.self) { value in
                            let hasDraft = thread.drafts[value] != nil || thread.answerDrafts?[value] != nil
                            let revisionLabel = value == 1 ? "Original" : "Version \(value)"
                            Text(revisionLabel + (hasDraft ? " · draft" : "")).tag(value)
                    }
                    }.pickerStyle(.menu).font(.caption).accessibilityIdentifier("conversation-revision-picker")
                }
                ConversationHistoryContent(store: store, key: key, revision: revision,
                    thread: thread, request: request, sender: sender,
                    local: store.isLocalExample,
                    hasNotAcceptedCardForRetainedAnswer: hasNotAcceptedCard,
                    initialScrollTurnID: initialScrollTurnID,
                    dynamicTypeSize: dynamicTypeSize,
                    inspect: { file, fileRevision in
                        fileError = nil
                        inspectedFile = file
                        inspectedFileRevision = fileRevision
                    })
                    .equatable()
                if let terminal = thread.terminal {
                    Label(thread.isRetracted ? store.retractionLabel(key) : "Request \(terminal.rawValue)", systemImage: "checkmark.circle")
                        .font(.caption).padding(8)
                }
                ConversationDraftStatus(disposition: draft.disposition)
                ConversationUploadCleanupStatus(store: store, key: key, revision: revision)
                if let error = store.conversationError {
                    Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                if let message = store.conversationUnavailableMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                        .accessibilityIdentifier("conversation-unavailable")
                } else if store.isReadOnly {
                    ReadOnlyConversationDraftView(draft: draft) { file in
                        fileError = nil
                        inspectedFile = file
                        inspectedFileRevision = revision
                    }
                        .padding(verticalSizeClass == .compact ? 4 : 12)
                } else {
                    ConversationAvailabilityNotice(
                        observation: thread.latestReportedAvailabilityObservation)
                        .padding(.horizontal)
                    ConversationComposer(store: store, key: key, revision: revision,
                        inspect: { file, fileRevision in
                            fileError = nil
                            inspectedFile = file
                            inspectedFileRevision = fileRevision
                        })
                        .padding(verticalSizeClass == .compact ? 4 : 12)
                }
            } else {
                switch ConversationPanelEmptyState.resolve(
                    availability: store.conversationAvailabilityState,
                    isRefreshing: store.isRefreshing,
                    hasConnectionWarning: store.connectionWarning != nil,
                    canCheckAvailability: store.canCheckConversationAvailability
                ) {
                case .noChat:
                    ContentUnavailableView("No chat", systemImage: "bubble.left.and.bubble.right",
                        description: Text("The agent that sent this didn’t open a chat for it. You can still respond to the message itself."))
                        .accessibilityIdentifier("conversation-no-chat-empty-state")
                case .checkingAvailability:
                    ProgressView("Checking chat availability…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("conversation-availability-checking")
                case .chatUnavailable:
                    ContentUnavailableView("Chat unavailable", systemImage: "bubble.left.and.bubble.right",
                        description: Text("Chat is not available on this server yet."))
                        .accessibilityIdentifier("conversation-unavailable")
                case .connectionUnavailable:
                    ContentUnavailableView("Chat status unavailable", systemImage: "wifi.slash",
                        description: Text("The server connection could not confirm whether a chat was opened."))
                        .accessibilityIdentifier("conversation-status-unavailable")
                case .offline:
                    ContentUnavailableView("Chat status unavailable offline", systemImage: "wifi.slash",
                        description: Text("This offline view cannot confirm whether a chat was opened."))
                        .accessibilityIdentifier("conversation-status-offline")
                case .availabilityUnconfirmed:
                    ContentUnavailableView("Chat status not confirmed", systemImage: "questionmark.bubble",
                        description: Text("The server has not confirmed whether a chat was opened yet."))
                        .accessibilityIdentifier("conversation-status-unconfirmed")
                }
            }
        }
        .onAppear {
            if selectedRevision == nil { selectedRevision = thread?.currentRevision }
            if scenePhase == .active { NativeNotificationRouter.shared.conversationBecameVisible(key) }
            testConversationSheetDidAppear?()
        }
        .onDisappear { NativeNotificationRouter.shared.conversationBecameHidden(key) }
        .onChange(of: key) { oldKey, newKey in
            NativeNotificationRouter.shared.conversationBecameHidden(oldKey)
            if scenePhase == .active { NativeNotificationRouter.shared.conversationBecameVisible(newKey) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                NativeNotificationRouter.shared.conversationBecameVisible(key)
            } else {
                NativeNotificationRouter.shared.conversationBecameHidden(key)
            }
        }
        .uiDiagnostics("conversation-ui-diagnostics", store.uiDiagnosticSummary(for: key, revision: revision))
        .sheet(item: $inspectedFile) { file in
            NavigationStack {
                Form {
                    LabeledContent("File", value: file.name.rawValue)
                    LabeledContent("Original bytes", value: String(file.byteCount))
                    Text("SHA-256").font(.headline)
                    Text(file.sha256.rawValue).font(.caption.monospaced()).textSelection(.enabled)
                    if !store.isLocalExample {
                        Button(openingFile ? "Opening…" : (store.isReadOnly ? "Open saved file" : "Open file")) {
                            openingFile = true
                            fileError = nil
                            Task {
                                defer { openingFile = false }
                                do {
                                    previewURL = try await store.prepareConversationPreview(file, for: key,
                                        revision: inspectedFileRevision ?? revision)
                                }
                                catch { fileError = "\(file.name.rawValue) could not be opened (\(error)). Its saved metadata and draft are retained." }
                            }
                        }.disabled(openingFile || (store.isReadOnly && !store.hasCachedConversationPreview(file)))
                        if store.isReadOnly && !store.hasCachedConversationPreview(file) {
                            Text("This file is not saved locally on this phone. The archive will not download it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let fileError { Text(fileError).font(.caption).foregroundStyle(.secondary) }
                    Text("Transfer and agent-reported use are separate facts. A completed transfer does not establish that the agent read this file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { inspectedFile = nil } } }
                .quickLookPreview($previewURL)
            }
            .foregroundChatNotificationLayer(testRouter: testNotificationRouter,
                                             testOpen: testOpenForegroundChatIndicator)
        }
    }

}

@MainActor
private struct ConversationHistoryContent: View, Equatable {
    let store: LivePresentationStore
    let key: RequestKey
    let revision: UInt64
    let thread: ConversationThread
    let request: PresentedRequest?
    let sender: String
    let local: Bool
    let hasNotAcceptedCardForRetainedAnswer: Bool
    let initialScrollTurnID: ExactText?
    let dynamicTypeSize: DynamicTypeSize
    let inspect: (ConversationFile, UInt64) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Read cursors change as replies cross the visibility threshold, but
        // they do not change any content rendered by this transcript subtree.
        lhs.store === rhs.store &&
        lhs.key == rhs.key &&
        lhs.revision == rhs.revision &&
        lhs.thread.currentRevision == rhs.thread.currentRevision &&
        lhs.thread.revisions == rhs.thread.revisions &&
        lhs.thread.turns == rhs.thread.turns &&
        lhs.thread.facts == rhs.thread.facts &&
        lhs.thread.answerDrafts == rhs.thread.answerDrafts &&
        lhs.thread.latestReportedAvailabilityObservation == rhs.thread.latestReportedAvailabilityObservation &&
        lhs.thread.terminalTurn == rhs.thread.terminalTurn &&
        lhs.thread.isRetracted == rhs.thread.isRetracted &&
        lhs.request == rhs.request &&
        lhs.sender == rhs.sender &&
        lhs.local == rhs.local &&
        lhs.hasNotAcceptedCardForRetainedAnswer == rhs.hasNotAcceptedCardForRetainedAnswer &&
        lhs.initialScrollTurnID == rhs.initialScrollTurnID &&
        lhs.dynamicTypeSize == rhs.dynamicTypeSize
        // `inspect` writes through the same ConversationPanel @State slots;
        // closure identity changes on body re-evaluation but its target does not.
    }

    var body: some View {
        let textByTurnID = Dictionary(
            thread.turns.map { ($0.id, $0.text.rawValue) },
            uniquingKeysWith: { first, _ in first })
        let replyTargetIDs = Set(thread.turns.compactMap { turn -> ExactText? in
            guard turn.author != .person,
                  turn.kind == nil || turn.kind == .reply else { return nil }
            return turn.inReplyTo
        })
        let turnIDs = Set(thread.turns.map(\.id))

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let earlier = store.historicalAnswerDraft(for: key, revision: revision),
                       !hasNotAcceptedCardForRetainedAnswer {
                        DisclosureGroup(thread.isRetracted ? "Saved answer draft · request retracted" : "Earlier answer draft · not delivered") {
                            HistoricalAnswerDraftView(request: earlier, store: store, retracted: thread.isRetracted)
                        }.accessibilityIdentifier("conversation-earlier-answer")
                    }
                    ForEach(thread.turns) { turn in
                        ConversationTurnView(turn: turn, facts: thread.facts[turn.id] ?? ConversationTurnFacts(),
                            sender: sender, local: local,
                            availability: thread.latestReportedAvailabilityObservation,
                            hasReply: replyTargetIDs.contains(turn.id),
                            replyContext: turn.inReplyTo.flatMap { textByTurnID[$0] },
                            retracted: thread.isRetracted && thread.terminalTurn == turn.id,
                            inspect: inspect)
                            .id(turn.id)
                            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                                guard isVisible, turn.kind == .reply, turn.author == .origin else { return }
                                store.markConversationRead(key, through: turn.id)
                            }
                    }
                }.padding(.horizontal)
            }
            .accessibilityIdentifier("conversation-history-scroll")
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread.turns.count) { _, _ in
                if let last = thread.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: initialScrollTurnID, initial: true) { _, target in
                guard let target, turnIDs.contains(target) else { return }
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }
}

@MainActor
private struct ReadOnlyConversationDraftView: View {
    let draft: ConversationDraft
    let inspect: (ConversationFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ConversationDraftPresentationText.readOnlyHeading, systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
            if !draft.text.rawValue.isEmpty {
                Text(draft.text.rawValue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            ForEach(draft.files) { file in
                Button { inspect(file) } label: {
                    Label(file.name.rawValue, systemImage: "paperclip")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            Text("This account is disconnected. Its saved discussion cannot be edited or sent.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .accessibilityIdentifier("read-only-conversation-draft")
    }
}

enum ConversationDraftPresentationText {
    static let readOnlyHeading: LocalizedStringResource = "Saved discussion draft"

    enum Status: Equatable {
        case submitting
        case outcomeUnknown
        case acceptedPendingReplay
        case rejected(ExactText)
    }

    static func status(for disposition: ConversationDraft.Disposition) -> Status? {
        switch disposition {
        case .saved: nil
        case .submitting: .submitting
        case .outcomeUnknown: .outcomeUnknown
        case .acceptedPendingReplay: .acceptedPendingReplay
        case let .rejected(reason): .rejected(reason)
        }
    }
}

enum ConversationSubmittedText {
    static func afterResult(accepted: Bool, submitted: String, submittedEdit: UInt64,
                            current: String, currentEdit: UInt64) -> String {
        accepted && currentEdit == submittedEdit && current == submitted ? "" : current
    }
}

@MainActor
@Observable
private final class ConversationComposerTextSession {
    // Keystroke updates stay in the editor/send leaves instead of invalidating
    // the composer that also builds attachment and control content.
    var stagedText = ""
    var textEditRevision: UInt64 = 0
    var savedText = ""
    var stagedBinding: ConversationBinding?
    @ObservationIgnored var textSaveTask: Task<Void, Never>?
}

@MainActor
private struct ConversationComposerTextInput: View {
    let session: ConversationComposerTextSession
    let isEnabled: Bool
    let onTextChange: () -> Void
    let onReturn: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ConversationReturnTextView(text: Binding(get: { session.stagedText }, set: { text in
                guard session.stagedText != text else { return }
                session.textEditRevision &+= 1
                session.stagedText = text
                onTextChange()
            }), isEnabled: isEnabled, onReturn: onReturn)
                .padding(.vertical, 11)
            if session.stagedText.isEmpty {
                Text("Write a message…")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

@MainActor
private struct ConversationComposerSendButton: View {
    let session: ConversationComposerTextSession
    let isLocalExample: Bool
    let frozen: Bool
    let isSendingDiscussion: Bool
    let allowsDiscussion: Bool
    let hasFiles: Bool
    let hasPendingUploadCleanup: Bool
    let hasAbandonedDiscussion: Bool
    let hasUnreadyUploadReference: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: frozen ? "arrow.clockwise" : "arrow.up")
                .font(.headline)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.regular)
        .accessibilityLabel(isLocalExample ? "Send locally" : frozen ? "Retry saved discussion" : "Send message")
        .accessibilityIdentifier("sample-chat-send")
        .disabled(isSendingDiscussion || !allowsDiscussion || hasPendingUploadCleanup ||
                  hasAbandonedDiscussion || hasUnreadyUploadReference ||
                  (!frozen && session.stagedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasFiles))
    }
}

@MainActor
private struct ConversationComposer: View {
    let store: LivePresentationStore
    let key: RequestKey
    let revision: UInt64
    let inspect: (ConversationFile, UInt64) -> Void
    @State private var pickingFiles = false
    @State private var attachmentChoices = false
    @State private var textSession = ConversationComposerTextSession()
    @Environment(\.scenePhase) private var scenePhase
    private var thread: ConversationThread? { store.conversation(for: key) }
    private var draft: ConversationDraft { store.conversationDraft(for: key, revision: revision) }
    private var allowsDiscussion: Bool { thread?.allowsDiscussion == true }
    private var frozen: Bool {
        switch draft.disposition { case .submitting, .outcomeUnknown, .acceptedPendingReplay: return true; default: return false }
    }

    var body: some View {
        // Each regular glass button adds 7 points around its label, for a 44-point target.
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                guard persistStagedText() else { return }
                if store.isLocalExample { attachmentChoices = true } else { pickingFiles = true }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                .accessibilityLabel(store.isLocalExample ? "Add sample attachment" : "Add attachment")
                .accessibilityIdentifier("sample-chat-add-attachment")
                .disabled(frozen || !allowsDiscussion || store.hasPendingUploadCleanup(for: key, revision: revision))
                .confirmationDialog("Add a local example", isPresented: $attachmentChoices, titleVisibility: .visible) {
                    Button("Sample photo") { addExample("Photo") }
                    Button("Sample file") { addExample("Document") }
                    Button("Sample camera image") { addExample("Camera") }
                    Button("Cancel", role: .cancel) {}
                }
            VStack(alignment: .leading, spacing: 8) {
                if !draft.files.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(draft.files) { file in
                                VStack(spacing: 4) {
                                    Button { inspect(file, revision) } label: {
                                        VStack(spacing: 4) {
                                            ConversationAttachmentThumbnail(file: file, local: store.isLocalExample)
                                            Text(file.name.rawValue).lineLimit(1)
                                        }
                                    }.font(.caption)
                                    .disabled(store.uploadNeedsReselection(file, for: key, revision: revision))
                                    if store.uploadNeedsReselection(file, for: key, revision: revision) {
                                        Text("Not ready · reselect after cleanup").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Button("Remove", systemImage: "xmark.circle.fill") {
                                        guard persistStagedText() else { return }
                                        store.updateConversation(for: key, revision: revision,
                                            files: draft.files.filter { $0.id != file.id })
                                    }.labelStyle(.iconOnly).disabled(frozen)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                ConversationComposerTextInput(session: textSession,
                    isEnabled: !frozen && allowsDiscussion,
                    onTextChange: scheduleTextSave, onReturn: sendStagedText)
            }
            .padding(.horizontal, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain).accessibilityIdentifier("sample-chat-input-surface")
            ConversationComposerSendButton(session: textSession,
                isLocalExample: store.isLocalExample, frozen: frozen,
                isSendingDiscussion: store.isSendingDiscussion,
                allowsDiscussion: allowsDiscussion,
                hasFiles: !draft.files.isEmpty,
                hasPendingUploadCleanup: store.hasPendingUploadCleanup(for: key, revision: revision),
                hasAbandonedDiscussion: store.hasAbandonedDiscussion(for: key, revision: revision),
                hasUnreadyUploadReference: store.hasUnreadyUploadReference(for: key, revision: revision),
                action: sendStagedText)
        }
        .onChange(of: ConversationBinding(request: key, revision: revision), initial: true) { _, binding in
            if let stagedBinding = textSession.stagedBinding, stagedBinding != binding { _ = persistStagedText() }
            textSession.textSaveTask?.cancel()
            textSession.stagedBinding = binding
            let current = store.conversationDraft(for: binding.request, revision: binding.revision)
            if let unsaved = store.unsavedConversationText(for: binding) {
                textSession.stagedText = unsaved
                textSession.savedText = current.text.rawValue
                return
            }
            // A confirmed send can await replay while its exact operation stays durable.
            if case .acceptedPendingReplay = current.disposition {
                textSession.stagedText = ""
                textSession.savedText = ""
            } else {
                textSession.stagedText = current.text.rawValue
                textSession.savedText = textSession.stagedText
            }
        }
        .onChange(of: draft.text) { old, new in
            guard textSession.stagedText == textSession.savedText else { return }
            if old != new {
                textSession.stagedText = new.rawValue
                textSession.savedText = textSession.stagedText
            }
        }
        .onChange(of: draft.disposition) { _, disposition in
            if case .saved = disposition, textSession.stagedText != textSession.savedText { scheduleTextSave() }
            if case .rejected = disposition, textSession.stagedText != textSession.savedText { scheduleTextSave() }
        }
        .onDisappear {
            textSession.textSaveTask?.cancel()
            _ = persistStagedText()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                textSession.textSaveTask?.cancel()
                _ = persistStagedText()
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                let addressedRevision = revision
                Task { await store.importConversationFiles(urls, for: key, revision: addressedRevision) }
            } else if case let .failure(error) = result {
                store.reportConversationImportError(error, for: key, revision: revision)
            }
        }
    }

    private func scheduleTextSave() {
        textSession.textSaveTask?.cancel()
        let expected = textSession.stagedText
        let binding = textSession.stagedBinding
        textSession.textSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, textSession.stagedBinding == binding,
                  textSession.stagedText == expected else { return }
            _ = persistStagedText()
        }
    }

    @discardableResult
    private func persistStagedText() -> Bool {
        guard let binding = textSession.stagedBinding else { return false }
        guard textSession.stagedText != textSession.savedText else { return true }
        guard store.updateConversation(for: binding.request, revision: binding.revision,
                                       text: textSession.stagedText) else { return false }
        textSession.savedText = textSession.stagedText
        return true
    }

    private func sendStagedText() {
        textSession.textSaveTask?.cancel()
        guard !store.isSendingDiscussion, allowsDiscussion,
              !store.hasPendingUploadCleanup(for: key, revision: revision),
              !store.hasAbandonedDiscussion(for: key, revision: revision),
              !store.hasUnreadyUploadReference(for: key, revision: revision),
              frozen || !textSession.stagedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.files.isEmpty else { return }
        guard persistStagedText(), let binding = textSession.stagedBinding else { return }
        let submittedText = textSession.stagedText
        let submittedEdit = textSession.textEditRevision
        store.sendDiscussion(for: binding.request, revision: binding.revision) { accepted in
            guard textSession.stagedBinding == binding else { return }
            let remaining = ConversationSubmittedText.afterResult(
                accepted: accepted, submitted: submittedText, submittedEdit: submittedEdit,
                current: textSession.stagedText, currentEdit: textSession.textEditRevision)
            if remaining != textSession.stagedText {
                textSession.stagedText = remaining
                textSession.savedText = remaining
            }
        }
    }



    private func addExample(_ kind: String) {
        var number = 1
        while draft.files.contains(where: { $0.name.rawValue == "\(kind) \(number)" }) { number += 1 }
        store.addLocalAttachment("\(kind) \(number)", for: key, revision: revision)
    }
}

@MainActor
private struct ConversationUploadCleanupStatus: View {
    let store: LivePresentationStore
    let key: RequestKey
    let revision: UInt64
    private var cleanups: [ConversationUploadCleanup] {
        (store.conversation(for: key)?.uploadCleanups ?? [:]).values
            .filter { $0.binding.revision == revision }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    var body: some View {
        if !cleanups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(cleanups) { cleanup in
                    switch cleanup.outcome {
                    case .pending:
                        Text("Upload cleanup pending. Deletion is not confirmed; your text draft is retained.")
                    case .unknown:
                        Text("Upload cleanup unconfirmed. Retry cleanup before reselecting files; your text draft is retained.")
                    case let .acknowledged(result):
                        Text("Cleanup acknowledged: \(result.discarded) unsubmitted uploads removed. Reselect unready files to upload again.")
                        if result.state == .committed {
                            Text("Some upload references are committed. Individual file status awaits synchronized history; retained draft references are not ready to resend.")
                        }
                    }
                }
                if store.hasPendingUploadCleanup(for: key, revision: revision), store.isLocalExample {
                    Text("Local example · cleanup is unconfirmed; no service is contacted.")
                }
                if store.hasPendingUploadCleanup(for: key, revision: revision), !store.isLocalExample, !store.isReadOnly {
                    Button("Retry upload cleanup") { Task { await store.retryUploadCleanup(for: key) } }
                        .disabled(store.retryingCleanupRequests.contains(key))
                        .accessibilityIdentifier("conversation-retry-cleanup")
                }
                if !store.isReadOnly &&
                   (store.hasAbandonedDiscussion(for: key, revision: revision) || store.uploadHistoryNeedsReconciliation(for: key, revision: revision)) {
                    Text("Refresh history to reconcile retained file and submission identities. These unready references will not be resent.")
                    Button("Refresh discussion history") { Task { await store.refreshDiscussionHistory() } }
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("conversation-upload-cleanup-status")
        }
    }
}

private struct ConversationDraftStatus: View {
    let disposition: ConversationDraft.Disposition
    @ViewBuilder var body: some View {
        if let status = ConversationDraftPresentationText.status(for: disposition) {
            switch status {
            case .submitting:
                Text("Submitting · saved draft retained").font(.caption).foregroundStyle(.secondary)
            case .outcomeUnknown:
                Text("Submission unconfirmed · saved draft retained").font(.caption).foregroundStyle(.secondary)
            case .acceptedPendingReplay:
                Text("Sent · syncing chat history").font(.caption).foregroundStyle(.secondary)
            case let .rejected(reason):
                Text(reason.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum ConversationSentChatStatusPresentation {
    static let unpickedDelayMilliseconds: UInt64 = 120_000

    enum Delivery: Equatable {
        case sent
        case notDeliveredYet
        case noOneWillGetThis
        case delivered
        case sending
        case noListenerPickedThisUp
        case waitingFor(String)
        case notDelivered(String)
        case deliveredAck
        case deliveredTo(String)
    }

    static func delivery(for facts: ConversationTurnFacts,
                         availability: ConversationAvailabilityObservation? = nil, hasReply: Bool,
                         nowMilliseconds: UInt64) -> Delivery {
        // Receipt, action, and an actual reply all establish delivery. They
        // remain separate stored facts; this is only their shared presentation.
        if facts.delivered || facts.actedBy != nil || hasReply { return .delivered }
        if let availability {
            switch availability.state {
            case .notListening: return .notDeliveredYet
            case .unsupported, .gone: return .noOneWillGetThis
            case .listening: break
            }
        }
        guard let acceptedAt = facts.acceptedAtMilliseconds,
              nowMilliseconds >= acceptedAt,
              nowMilliseconds - acceptedAt >= unpickedDelayMilliseconds else {
            return .sent
        }
        return .notDeliveredYet
    }

    static func delivery(for turn: ConversationTurn, facts: ConversationTurnFacts,
                         availability: ConversationAvailabilityObservation? = nil, hasReply: Bool,
                         conversationAgentName: String, nowMilliseconds: UInt64) -> Delivery {
        guard usesDeliveryAckPresentation(turn: turn, facts: facts) else {
            return delivery(for: facts, availability: availability, hasReply: hasReply,
                            nowMilliseconds: nowMilliseconds)
        }

        // Existing Seen, acted and reply facts outrank every delivery-ack state.
        if facts.delivered || facts.actedBy != nil || hasReply { return .deliveredAck }

        if case let .handed(_, rerouted, _, agent)? = facts.deliveryAck2 {
            return rerouted ? (agent.map { .deliveredTo($0.rawValue) } ?? .deliveredAck) : .deliveredAck
        }
        if case .listenerReceived(_, false, _, _)? = facts.deliveryAck1 { return .deliveredAck }

        if let availability {
            switch availability.state {
            case .unsupported, .gone:
                return .noOneWillGetThis
            case .listening, .notListening:
                break
            }
        }

        if case let .notHanded(_, reason, _, _)? = facts.deliveryAck2 {
            return .notDelivered(reason.rawValue)
        }
        if case let .listenerReceived(atMilliseconds, true, _, _)? = facts.deliveryAck1 {
            guard nowMilliseconds >= atMilliseconds,
                  nowMilliseconds - atMilliseconds >= unpickedDelayMilliseconds else {
                return .sending
            }
            return .waitingFor(conversationAgentName)
        }

        if case .notListening? = availability?.state { return .noListenerPickedThisUp }
        guard let acceptedAt = facts.acceptedAtMilliseconds,
              nowMilliseconds >= acceptedAt,
              nowMilliseconds - acceptedAt >= unpickedDelayMilliseconds else {
            return .sending
        }
        return .noListenerPickedThisUp
    }

    static func usesDeliveryAckPresentation(turn: ConversationTurn,
                                            facts: ConversationTurnFacts) -> Bool {
        turn.author == .person && turn.kind == .discussion &&
            (turn.deliveryAcks == true || facts.deliveryAck1 != nil || facts.deliveryAck2 != nil)
    }
}

enum ConversationAvailabilityNoticePresentation: Equatable {
    case none
    case nothingListening
    case noOneWillGetThis

    static func notice(for observation: ConversationAvailabilityObservation?) -> Self {
        guard let observation else { return .none }
        switch observation.state {
        case .listening: return .none
        case .notListening: return .nothingListening
        case .unsupported, .gone: return .noOneWillGetThis
        }
    }
}

private struct ConversationAvailabilityNotice: View {
    let observation: ConversationAvailabilityObservation?

    var body: some View {
        Group {
            switch ConversationAvailabilityNoticePresentation.notice(for: observation) {
            case .none:
                EmptyView()
            case .nothingListening:
                Label("Nothing's listening right now", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case .noOneWillGetThis:
                Label("No one will get this", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHint("Based on the latest availability reported for this chat.")
        .accessibilityIdentifier("conversation-availability-notice")
    }
}

private struct ConversationSentChatStatus: View {
    let turn: ConversationTurn
    let facts: ConversationTurnFacts
    let availability: ConversationAvailabilityObservation?
    let hasReply: Bool
    let conversationAgentName: String
    let local: Bool

    // Unreceived turns use the latest reported conversation availability.
    // Receipt, action, and reply facts take precedence and remain independent.
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if local {
                Text("Local example · status is simulated; nothing was sent.")
                    .foregroundStyle(.secondary)
            }
            deliveryStatus
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("conversation-sent-chat-status")
    }

    @ViewBuilder
    private var deliveryStatus: some View {
        if shouldAgeDelivery {
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                deliveryLabel(ConversationSentChatStatusPresentation.delivery(
                    for: turn, facts: facts, availability: availability, hasReply: hasReply,
                    conversationAgentName: conversationAgentName,
                    nowMilliseconds: Self.milliseconds(timeline.date)))
            }
        } else {
            deliveryLabel(ConversationSentChatStatusPresentation.delivery(
                for: turn, facts: facts, availability: availability, hasReply: hasReply,
                conversationAgentName: conversationAgentName,
                nowMilliseconds: Self.milliseconds(.now)))
        }
    }

    private var shouldAgeDelivery: Bool {
        guard !facts.delivered, facts.actedBy == nil, !hasReply else { return false }
        if ConversationSentChatStatusPresentation.usesDeliveryAckPresentation(turn: turn, facts: facts) {
            if case .handed? = facts.deliveryAck2 { return false }
            if case .notHanded? = facts.deliveryAck2 { return false }
            if case .listenerReceived(_, false, _, _)? = facts.deliveryAck1 { return false }
            if case .unsupported? = availability?.state { return false }
            if case .gone? = availability?.state { return false }
            if case .listenerReceived(_, true, _, _)? = facts.deliveryAck1 { return true }
            if case .notListening? = availability?.state { return false }
            return facts.acceptedAtMilliseconds != nil
        }
        guard facts.acceptedAtMilliseconds != nil else { return false }
        switch availability?.state {
        case .notListening?, .unsupported?, .gone?: return false
        case .listening?, nil: return true
        }
    }

    @ViewBuilder
    private func deliveryLabel(_ delivery: ConversationSentChatStatusPresentation.Delivery) -> some View {
        switch delivery {
        case .sent:
            Text("Sent")
                .foregroundStyle(.secondary)
        case .notDeliveredYet:
            Text("Not delivered yet")
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
        case .noOneWillGetThis:
            Label("No one will get this", systemImage: "xmark.circle.fill")
                .fontWeight(.semibold)
                .foregroundStyle(.red)
        case .delivered:
            Text("Delivered")
                .foregroundStyle(.secondary)
        case .sending:
            Text("Sending…")
                .foregroundStyle(.secondary)
        case .noListenerPickedThisUp:
            Text("No listener has picked this up")
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
        case let .waitingFor(agent):
            Text("Waiting for \(agent)")
                .foregroundStyle(.secondary)
        case let .notDelivered(reason):
            Text("Not delivered: \(reason)")
                .fontWeight(.semibold)
                .foregroundStyle(.red)
        case .deliveredAck:
            Label("Delivered", systemImage: "checkmark")
                .foregroundStyle(.secondary)
        case let .deliveredTo(agent):
            Label("Delivered to \(agent)", systemImage: "checkmark")
                .foregroundStyle(.secondary)
        }
    }

    private static func milliseconds(_ date: Date) -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        return value > 0 ? UInt64(value) : 0
    }
}

private struct ConversationTurnView: View {
    let turn: ConversationTurn
    let facts: ConversationTurnFacts
    let sender: String
    let local: Bool
    let availability: ConversationAvailabilityObservation?
    let hasReply: Bool
    let replyContext: String?
    let retracted: Bool
    let inspect: (ConversationFile, UInt64) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                authorLabel
                if turn.binding.revision != 1 {
                    Text("· version \(turn.binding.revision)")
                }
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let replyContext {
                Text(MessageMarkdown.attributed(replyContext, prefixedBy: "Replying to: "))
                    .lineLimit(2)
                    .messageTextSize(basePointSize: 11, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
            }
            if turn.contentRedacted == true {
                Text("Person-authored content is not included in this device projection.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if turn.kind == .revision { Text(turn.binding.revision == 1 ? "Original question" : "Updated").font(.caption.weight(.semibold)) }
                if turn.kind == .terminal { Text(retracted ? "Retracted" : "Request closed").font(.caption.weight(.semibold)) }
                if let status = turn.resultStatus {
                    Text("Original answer result: " + status.rawValue).font(.caption.weight(.semibold))
                }
                if !turn.text.rawValue.isEmpty {
                    Text(MessageMarkdown.attributed(turn.text.rawValue))
                        .messageTextSize()
                        .textSelection(.enabled)
                }
            }
            ForEach(turn.files) { file in
                Button { inspect(file, turn.binding.revision) } label: { Label(file.name.rawValue, systemImage: "doc") }.font(.caption)
                if turn.author == .person {
                    ConversationFileFacts(transfer: facts.fileTransfers[file.id] ?? .unknown,
                        use: facts.fileUses[file.id] ?? .unknown, local: local)
                }
            }
            if turn.author == .person {
                ConversationSentChatStatus(turn: turn, facts: facts, availability: availability,
                    hasReply: hasReply, conversationAgentName: sender, local: local)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(turn.author == .person ? Color.blue.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var authorLabel: some View {
        switch turn.author {
        case .person: Text("You")
        case .origin: Text(verbatim: sender)
        case .agent: Text("Agent")
        case .server: Text("Harklight")
        }
    }
}

private struct ConversationFileFacts: View {
    let transfer: ConversationFileTransfer
    let use: ConversationFileUse
    var local = false
    private var prefix: String { local ? "Example · " : "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch transfer {
            case .unknown: Text(prefix + "Transfer not confirmed")
            case .transferred: Text(prefix + "Exact bytes transferred")
            case let .notTransferred(reason): Text(prefix + "Not transferred: " + reason.rawValue)
            }
            switch use {
            case .unknown: Text(prefix + "Agent use not reported")
            case .used: Text(prefix + "Agent reported used")
            case let .unusable(reason): Text(prefix + "Agent reported unusable" + (reason.map { ": " + $0.rawValue } ?? ""))
            }
        }.font(.caption2).foregroundStyle(.secondary)
    }
}

private struct ConversationAttachmentThumbnail: View {
    let file: ConversationFile
    let local: Bool
    var body: some View {
        if case let .inline(bytes) = file.content, let image = UIImage(data: bytes) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 72, height: 48)
        } else if local && (file.name.rawValue.hasPrefix("Photo") || file.name.rawValue.hasPrefix("Camera")) {
            SamplePicture(name: "harbor").frame(width: 72)
        } else {
            Image(systemName: "doc.text.fill").font(.title).frame(width: 72, height: 48)
        }
    }
}
