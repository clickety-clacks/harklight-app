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
    @State private var previewURL: URL?
    @State private var openingFile = false
    @State private var fileError: String?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var thread: ConversationThread? { store.conversation(for: key) }
    private var revision: UInt64 { selectedRevision ?? thread?.currentRevision ?? 1 }
    private var draft: ConversationDraft { store.conversationDraft(for: key, revision: revision) }

    var body: some View {
        VStack(spacing: 0) {
            if verticalSizeClass != .compact {
                VStack(alignment: .leading, spacing: 5) {
                    Text(sender).font(.headline)
                    Text("About \(title)").font(.caption).foregroundStyle(.secondary)
                    if let thread { ConversationAvailabilityLabel(availability: thread.availability, local: store.isLocalExample) }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let thread {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if let earlier = store.historicalAnswerDraft(for: key, revision: revision) {
                                DisclosureGroup("Earlier answer draft · not delivered") {
                                    HistoricalAnswerDraftView(request: earlier, store: store)
                                }.accessibilityIdentifier("conversation-earlier-answer")
                            }
                            ForEach(thread.turns) { turn in
                                ConversationTurnView(turn: turn, facts: thread.facts[turn.id] ?? ConversationTurnFacts(),
                                    sender: sender, local: store.isLocalExample,
                                    replyContext: turn.inReplyTo.flatMap { id in thread.turns.first { $0.id == id }?.text.rawValue }, inspect: { fileError = nil; inspectedFile = $0 })
                                    .id(turn.id)
                            }
                        }.padding(.horizontal)
                    }
                    .onChange(of: thread.turns.count) { _, _ in
                        if let last = thread.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                if let terminal = thread.terminal {
                    Label("Request \(terminal.rawValue)", systemImage: "checkmark.circle")
                        .font(.caption).padding(8)
                }
                HStack {
                    if thread.revisionNumbers.count > 1 {
                        Picker("Question version", selection: Binding(get: { revision }, set: { selectedRevision = $0 })) {
                            ForEach(thread.revisionNumbers, id: \.self) { value in
                                Text("Version \(value)\(thread.drafts[value] == nil && thread.answerDrafts?[value] == nil ? "" : " · draft")").tag(value)
                            }
                        }.pickerStyle(.menu).font(.caption).accessibilityIdentifier("conversation-revision-picker")
                    }
                    Spacer(minLength: 0)
                    Text(store.isLocalExample ? "Local conversation · nothing sent" : "Discussion · version \(revision)")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal)
                ConversationDraftStatus(disposition: draft.disposition)
                if let error = store.conversationError {
                    Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                ConversationComposer(store: store, key: key, revision: revision, inspect: { fileError = nil; inspectedFile = $0 })
                    .padding(verticalSizeClass == .compact ? 4 : 12)
            } else {
                ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left.and.bubble.right",
                    description: Text("This request has no conversation record. Its existing answer remains available."))
            }
        }
        .onAppear { if selectedRevision == nil { selectedRevision = thread?.currentRevision } }
        .sheet(item: $inspectedFile) { file in
            NavigationStack {
                Form {
                    LabeledContent("File", value: file.name.rawValue)
                    LabeledContent("Original bytes", value: String(file.byteCount))
                    Text("SHA-256").font(.headline)
                    Text(file.sha256.rawValue).font(.caption.monospaced()).textSelection(.enabled)
                    if !store.isLocalExample {
                        Button(openingFile ? "Opening…" : "Open file") {
                            openingFile = true
                            fileError = nil
                            Task {
                                defer { openingFile = false }
                                do { previewURL = try await store.prepareConversationPreview(file) }
                                catch { fileError = "\(file.name.rawValue) could not be opened (\(error)). Its saved metadata and draft are retained." }
                            }
                        }.disabled(openingFile)
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
private struct ConversationComposer: View {
    let store: LivePresentationStore
    let key: RequestKey
    let revision: UInt64
    let inspect: (ConversationFile) -> Void
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
            } label: { Image(systemName: "plus") }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                .accessibilityLabel(store.isLocalExample ? "Add sample attachment" : "Add attachment")
                .disabled(frozen || thread?.terminal != nil)
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
                                    Button { inspect(file) } label: {
                                        VStack(spacing: 4) {
                                            ConversationAttachmentThumbnail(file: file, local: store.isLocalExample)
                                            Text(file.name.rawValue).lineLimit(1)
                                        }
                                    }.font(.caption)
                                    Button("Remove", systemImage: "xmark.circle.fill") {
                                        store.updateConversation(for: key, revision: revision,
                                            files: draft.files.filter { $0.id != file.id })
                                    }.labelStyle(.iconOnly).disabled(frozen)
                                }
                            }
                        }
                    }
                }
                TextField("Write a message…", text: Binding(get: { draft.text.rawValue }, set: {
                    store.updateConversation(for: key, revision: revision, text: $0)
                }), axis: .vertical)
                    .lineLimit(1...5).disabled(frozen || thread?.terminal != nil)
                    .accessibilityIdentifier("sample-chat-composer")
            }
            .padding(12).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain).accessibilityIdentifier("sample-chat-input-surface")
            Button { store.sendDiscussion(for: key, revision: revision) } label: {
                Image(systemName: frozen ? "arrow.clockwise" : "arrow.up").font(.headline)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.regular)
            .accessibilityLabel(store.isLocalExample ? "Send locally" : frozen ? "Retry saved discussion" : "Send message")
            .disabled(store.isSendingDiscussion || thread?.terminal != nil || (draft.text.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.files.isEmpty))
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                let addressedRevision = revision
                Task { await store.importConversationFiles(urls, for: key, revision: addressedRevision) }
            } else if case let .failure(error) = result {
                store.reportConversationImportError(error.localizedDescription)
            }
        }
    }



    private func addExample(_ kind: String) {
        var number = 1
        while draft.files.contains(where: { $0.name.rawValue == "\(kind) \(number)" }) { number += 1 }
        store.addLocalAttachment("\(kind) \(number)", for: key, revision: revision)
    }
}

private struct ConversationAvailabilityLabel: View {
    let availability: ConversationAvailability
    let local: Bool
    var body: some View {
        let prefix = local ? "Example · " : ""
        switch availability {
        case .listening: Text(prefix + "Agent listening · delivery shown per message").font(.caption2).foregroundStyle(.secondary)
        case let .notListening(time): Text(prefix + "Agent not listening" + (time.map { " since " + $0.rawValue } ?? "")).font(.caption2).foregroundStyle(.secondary)
        case .gone: Text(prefix + "Originating session gone · request remains available").font(.caption2).foregroundStyle(.secondary)
        case let .unsupported(reason): Text(prefix + "Listening unsupported · " + reason.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct ConversationDraftStatus: View {
    let disposition: ConversationDraft.Disposition
    var body: some View {
        switch disposition {
        case .saved: EmptyView()
        case .submitting: Text("Submitting · saved draft retained").font(.caption)
        case .outcomeUnknown: Text("Submission unconfirmed · saved draft retained").font(.caption)
        case .acceptedPendingReplay: Text("Accepted · awaiting synchronized history").font(.caption)
        case let .rejected(reason): Text(reason.rawValue).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ConversationTurnView: View {
    let turn: ConversationTurn
    let facts: ConversationTurnFacts
    let sender: String
    let local: Bool
    let replyContext: String?
    let inspect: (ConversationFile) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(turn.author == .person ? "You" : turn.author == .origin ? sender : "Harklight")
                Text("· version \(turn.binding.revision)")
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let replyContext {
                Text("Replying to: " + replyContext).lineLimit(2).font(.caption2).foregroundStyle(.secondary)
            }
            if turn.contentRedacted == true {
                Text("Person-authored content is not included in this device projection.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if turn.kind == .revision { Text(turn.binding.revision == 1 ? "Original question" : "Question revised").font(.caption.weight(.semibold)) }
                if turn.kind == .terminal { Text("Request closed").font(.caption.weight(.semibold)) }
                if let status = turn.resultStatus {
                    Text("Original answer result: " + status.rawValue).font(.caption.weight(.semibold))
                }
                if !turn.text.rawValue.isEmpty { Text(turn.text.rawValue).textSelection(.enabled) }
            }
            ForEach(turn.files) { file in
                Button { inspect(file) } label: { Label(file.name.rawValue, systemImage: "doc") }.font(.caption)
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
