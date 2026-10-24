import AttentionDomain
import SwiftUI
import UniformTypeIdentifiers
import QuickLook

@MainActor
struct ConversationPanel: View {
    let store: LivePresentationStore
    let key: RequestKey
    let sender: String
    let title: String
    @State private var selectedRevision: UInt64?
    @State private var inspectedFile: ConversationFile?
    @State private var inspectedFileRevision: UInt64?
    @State private var previewURL: URL?
    @State private var openingFile = false
    @State private var fileError: String?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var thread: ConversationThread? { store.conversation(for: key) }
    private var revision: UInt64 { selectedRevision ?? thread?.currentRevision ?? 1 }
    private var draft: ConversationDraft { store.conversationDraft(for: key, revision: revision) }

    var body: some View {
        VStack(spacing: 0) {
            if let thread {
                if thread.revisionNumbers.count > 1 {
                    Picker("Question version", selection: Binding(get: { revision }, set: { selectedRevision = $0 })) {
                        ForEach(thread.revisionNumbers, id: \.self) { value in
                            Text("Version \(value)\(thread.drafts[value] == nil && thread.answerDrafts?[value] == nil ? "" : " · draft")").tag(value)
                    }
                    }.pickerStyle(.menu).font(.caption).accessibilityIdentifier("conversation-revision-picker")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if let earlier = store.historicalAnswerDraft(for: key, revision: revision) {
                                DisclosureGroup(thread.isRetracted ? "Saved answer draft · request retracted" : "Earlier answer draft · not delivered") {
                                    HistoricalAnswerDraftView(request: earlier, store: store, retracted: thread.isRetracted)
                                }.accessibilityIdentifier("conversation-earlier-answer")
                            }
                            ForEach(thread.turns) { turn in
                                ConversationTurnView(turn: turn, facts: thread.facts[turn.id] ?? ConversationTurnFacts(),
                                    sender: sender, local: store.isLocalExample,
                                    replyContext: turn.inReplyTo.flatMap { id in thread.turns.first { $0.id == id }?.text.rawValue },
                                    retracted: thread.isRetracted && thread.terminalTurn == turn.id,
                                    inspect: { file, fileRevision in
                                        fileError = nil
                                        inspectedFile = file
                                        inspectedFileRevision = fileRevision
                                    })
                                    .id(turn.id)
                            }
                        }.padding(.horizontal)
                    }
                    .onChange(of: thread.turns.count) { _, _ in
                        if let last = thread.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onChange(of: thread.latestAgentReply?.id, initial: true) { _, _ in
                        store.markConversationRead(key)
                    }
                }
                if let terminal = thread.terminal {
                    Label(thread.isRetracted ? store.retractionLabel(key) : "Request \(terminal.rawValue)", systemImage: "checkmark.circle")
                        .font(.caption).padding(8)
                }
                HStack {
                    Spacer(minLength: 0)
                    Text(store.isLocalExample ? "Local conversation · nothing sent" : "Discussion · version \(revision)")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal)
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
                    ConversationComposer(store: store, key: key, revision: revision,
                        inspect: { file, fileRevision in
                            fileError = nil
                            inspectedFile = file
                            inspectedFileRevision = fileRevision
                        })
                        .padding(verticalSizeClass == .compact ? 4 : 12)
                }
            } else {
                ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left.and.bubble.right",
                    description: Text("This request has no conversation record. Its existing answer remains available."))
            }
        }
        .onAppear { if selectedRevision == nil { selectedRevision = thread?.currentRevision } }
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

@MainActor
private struct ConversationComposer: View {
    let store: LivePresentationStore
    let key: RequestKey
    let revision: UInt64
    let inspect: (ConversationFile, UInt64) -> Void
    @State private var pickingFiles = false
    @State private var attachmentChoices = false
    private var thread: ConversationThread? { store.conversation(for: key) }
    private var draft: ConversationDraft { store.conversationDraft(for: key, revision: revision) }
    private var frozen: Bool {
        switch draft.disposition { case .submitting, .outcomeUnknown, .acceptedPendingReplay: return true; default: return false }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                if store.isLocalExample { attachmentChoices = true } else { pickingFiles = true }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                .accessibilityLabel(store.isLocalExample ? "Add sample attachment" : "Add attachment")
                .accessibilityIdentifier("sample-chat-add-attachment")
                .disabled(frozen || thread?.terminal != nil || store.hasPendingUploadCleanup(for: key, revision: revision))
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
                                        store.updateConversation(for: key, revision: revision,
                                            files: draft.files.filter { $0.id != file.id })
                                    }.labelStyle(.iconOnly).disabled(frozen)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                TextField("Write a message…", text: Binding(get: { draft.text.rawValue }, set: {
                    store.updateConversation(for: key, revision: revision, text: $0)
                }), axis: .vertical)
                    .lineLimit(1...5).disabled(frozen || thread?.terminal != nil)
                    .padding(.vertical, 11)
                    .accessibilityIdentifier("sample-chat-composer")
            }
            .padding(.horizontal, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain).accessibilityIdentifier("sample-chat-input-surface")
            Button { store.sendDiscussion(for: key, revision: revision) } label: {
                Image(systemName: frozen ? "arrow.clockwise" : "arrow.up")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.regular)
            .accessibilityLabel(store.isLocalExample ? "Send locally" : frozen ? "Retry saved discussion" : "Send message")
            .accessibilityIdentifier("sample-chat-send")
            .disabled(store.isSendingDiscussion || thread?.terminal != nil || store.hasPendingUploadCleanup(for: key, revision: revision) || store.hasAbandonedDiscussion(for: key, revision: revision) || store.hasUnreadyUploadReference(for: key, revision: revision) || (draft.text.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.files.isEmpty))
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



    private func addExample(_ kind: String) {
        var number = 1
        while draft.files.contains(where: { $0.name.rawValue == "\(kind) \(number)" }) { number += 1 }
        store.addLocalAttachment("\(kind) \(number)", for: key, revision: revision)
    }
}

struct ConversationAvailabilityLabel: View {
    let availability: ConversationAvailability
    let local: Bool
    var body: some View {
        let prefix = local ? "Example · " : ""
        switch availability {
        case .listening: Text(prefix + "Agent listening · delivery shown per message").font(.caption2).foregroundStyle(.secondary)
        case let .notListening(time): Text(prefix + Self.notListeningText(since: time)).font(.caption2).foregroundStyle(.secondary)
        case .gone: Text(prefix + "Originating session gone · request remains available").font(.caption2).foregroundStyle(.secondary)
        case let .unsupported(reason): Text(prefix + "Listening unsupported · " + reason.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The relay reports the detach time in epoch milliseconds; show it as a date.
    static func notListeningText(since time: ExactText?) -> String {
        guard let time else { return "Agent not listening" }
        guard let milliseconds = UInt64(time.rawValue) else { return "Agent not listening since " + time.rawValue }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        return "Agent not listening since " + date.formatted(date: .abbreviated, time: .shortened)
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
                Text("Accepted · awaiting synchronized history").font(.caption).foregroundStyle(.secondary)
            case let .rejected(reason):
                Text(reason.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConversationTurnView: View {
    let turn: ConversationTurn
    let facts: ConversationTurnFacts
    let sender: String
    let local: Bool
    let replyContext: String?
    let retracted: Bool
    let inspect: (ConversationFile, UInt64) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(authorLabel)
                Text("· version \(turn.binding.revision)")
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let replyContext {
                Text("Replying to: " + replyContext).lineLimit(2).font(.caption2).foregroundStyle(.secondary)
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
                if !turn.text.rawValue.isEmpty { Text(MessageTextLinks.attributed(turn.text.rawValue)).textSelection(.enabled) }
            }
            ForEach(turn.files) { file in
                Button { inspect(file, turn.binding.revision) } label: { Label(file.name.rawValue, systemImage: "doc") }.font(.caption)
                if turn.author == .person {
                    ConversationFileFacts(transfer: facts.fileTransfers[file.id] ?? .unknown,
                        use: facts.fileUses[file.id] ?? .unknown, local: local)
                }
            }
            if turn.author == .person {
                Text(local ? "Local example · nothing sent" : facts.actedBy != nil ? "Agent acted" : facts.delivered ? "Delivered to originating session" : "Accepted · queued for originating session")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(turn.author == .person ? Color.blue.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 12))
    }

    private var authorLabel: String {
        switch turn.author {
        case .person: return "You"
        case .origin: return sender
        case .agent: return "Agent"
        case .server: return "Harklight"
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
