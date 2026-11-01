import Foundation
import Observation
import AttentionDomain

// Visual metadata for locally registered examples; answer state belongs to the
// ordinary domain draft and LivePresentationStore, never to a second answer journal.
enum SampleKind: String, CaseIterable, Identifiable {
    case approval, textChoice, pictureChoice, instructions, review, multipleChoice
    case value, point, colorChoice, soundChoice, note
    case error, warning, information, completed
    var id: String { rawValue }
    var isNotice: Bool { [.error, .warning, .information, .completed].contains(self) }
    var designMessageType: HarklightMessageType {
        switch self {
        case .error: .error
        case .warning: .warning
        case .information: .info
        case .completed: .done
        default: .request
        }
    }
    var symbol: String {
        switch self {
        case .approval: "checkmark.circle"
        case .textChoice: "list.bullet"
        case .pictureChoice: "photo.on.rectangle"
        case .instructions: "hand.tap"
        case .review: "doc.text"
        case .multipleChoice: "checklist"
        case .value: "slider.horizontal.3"
        case .point: "scope"
        case .colorChoice: "paintpalette"
        case .soundChoice: "waveform"
        case .note: "text.bubble"
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        case .completed: "checkmark.circle.fill"
        }
    }
}

struct SampleOption: Identifiable, Equatable {
    enum Role { case plain, suggested, destructive }
    let id: String
    let title: String
    let detail: String
    var role: Role = .plain
}

struct SampleMessage: Identifiable, Equatable {
    let id: String
    let kind: SampleKind
    let sender: String
    let initials: String
    let title: String
    let body: String
    let options: [SampleOption]
    let deadline: String?
    let missed: Bool
    let revised: Bool
    let chatUnread: Bool
    let hasChat: Bool
    var tier: InboxAttentionTier = .middle
    // Stable per fixture identity so repeated registration keeps the original
    // payload instead of looking like an update to an existing request.
    let fixtureCreatedAtMilliseconds: Int
    var declaredMessageType: MessageTypeValue? = nil
    var declaredMessageKind: MessageKindValue? = nil
}

struct SampleMark: Identifiable, Equatable, Codable {
    var id = UUID()
    var x: Double
    var y: Double
    var note: String = ""
}

struct SampleChatLine: Identifiable, Equatable {
    let id: String
    let text: String
    let fromPerson: Bool
    var attachmentNames: [String] = []
}

@MainActor @Observable
final class SampleResponse {
    enum AnnotationAction: Equatable, Codable { case mark(UUID), stroke }
    let viewModel: LivePresentationStore
    let key: RequestKey
    let message: SampleMessage

    init(viewModel: LivePresentationStore, key: RequestKey, message: SampleMessage) {
        self.viewModel = viewModel
        self.key = key
        self.message = message
    }

    private var draft: RequestDraft? { viewModel.request(for: key)?.draft }
    var inboxRow: InboxRequestRow? {
        guard let request = viewModel.request(for: key) else { return nil }
        var statusParts: [String] = []
        if viewModel.hasAcceptedUpdate(for: key) { statusParts.append("Updated") }
        statusParts.append(viewModel.isRetracted(key)
            ? "Retracted"
            : String(localized: LiveLifecycleTitle(request.lifecycleStatus).label))
        if request.answerNotDelivered { statusParts.append("Answer not delivered") }
        if let seen = request.informationalSeenStatus,
           seen != .available, !localSeenSelected {
            statusParts.append(LiveRequestDetail.informationalSeenText(seen))
        }
        let hasUnconfirmedOutcome = request.intentReceipt != nil &&
            request.receiptFacts?.ownOutcome == .unconfirmed &&
            request.lifecycleStatus != .pending
        let serverReportedFinalResponse = request.inboxStateIsCurrent &&
            (request.lifecycleStatus == .answered || request.lifecycleStatus == .noComment)
        let hasAcceptedOwnSubmission = request.receiptFacts?.ownOutcome == .accepted
        let receiptStatus = request.answerNotDelivered ? .some(.failed) :
            InboxRequestRow.responseReceiptStatus(
            request.intentReceipt,
            hasUnconfirmedOutcome: hasUnconfirmedOutcome,
            serverReportedFinalResponse: serverReportedFinalResponse,
            hasAcceptedOwnSubmission: hasAcceptedOwnSubmission)
        let localStatus: String?
        if serverReportedFinalResponse {
            localStatus = nil
        } else if request.answerNotDelivered {
            localStatus = "Answer not delivered"
        } else if receiptStatus == .failed {
            if hasUnconfirmedOutcome {
                localStatus = "Answer sent · result not confirmed"
            } else if request.noCommentUnavailable {
                localStatus = "No comment not delivered · unsupported by this server"
            } else {
                switch request.intentReceipt?.localState {
                case .some(.refusedByRetraction): localStatus = "Answer refused · request retracted"
                case .some(.terminalUnconfirmed): localStatus = "Answer sent · result not confirmed"
                case .some(.notDelivered): localStatus = "Answer not delivered"
                case .some(.unsupported): localStatus = "No comment is unsupported by this server"
                case .some(.repairRequired): localStatus = "Answer needs recovery"
                default: localStatus = "Answer not delivered"
                }
            }
        } else if finished {
            localStatus = noCommentSelected
                ? "No comment selected locally · nothing sent"
                : request.informationalSeenStatus == nil
                    ? "Answered locally · nothing sent"
                    : "Seen selected locally · nothing sent"
        } else {
            localStatus = nil
        }
        let emphasis: InboxRowEmphasis = switch message.kind {
        case .error: .error
        case .warning: .warning
        case .completed: .completed
        default: .standard
        }
        return InboxRequestRow(key: request.key,
            title: request.title?.rawValue ?? "Message",
            sender: message.sender,
            status: statusParts.joined(separator: " · "),
            bodyText: request.body?.rawValue,
            symbol: message.kind.symbol,
            isResolved: request.answerNotDelivered || receiptStatus == .failed ? false : request.isResolved,
            createdAt: request.createdAt,
            isLocalExample: true, localStatus: localStatus,
            informationalSeenStatus: request.informationalSeenStatus,
            declaredMessageType: request.messageType,
            declaredMessageKind: request.messageKind,
            canNoComment: canDeclineLocally && request.informationalSeenStatus == nil,
            localSeenSelected: localSeenSelected,
            hasUserAction: finished || receiptStatus == .pendingOrAccepted ||
                request.lifecycleStatus == .answered || request.lifecycleStatus == .noComment,
            hasFailedResponse: receiptStatus == .failed,
            isRetracted: viewModel.isRetracted(key),
            chatUnread: message.hasChat ? message.chatUnread && !chatRead : nil,
            initials: message.initials,
            emphasis: emphasis,
            messageType: message.kind.designMessageType,
            tier: message.tier)
    }

    var localSeenSelected: Bool {
        guard finished, !noCommentSelected,
              let request = viewModel.request(for: key) else { return false }
        return request.informationalSeenStatus == .available
    }

    var canDeclineLocally: Bool {
        guard !finished, !viewModel.isReadOnly,
              let request = viewModel.request(for: key),
              request.inboxStateIsCurrent, !viewModel.isRetracted(key), request.lifecycleStatus == .open,
              request.intentReceipt == nil, request.informationalSeenStatus == nil else { return false }
        return true
    }

    var noCommentSelected: Bool {
        viewModel.draft(for: key)?.noCommentSelected ?? false
    }

    func declineLocally() {
        guard canDeclineLocally else { return }
        viewModel.selectNoComment(for: key)
        finished = true
    }

    var clearedFromList: Bool {
        viewModel.isRetracted(key) && viewModel.isRetractionCleared(key)
    }

    func clearRetractedLocally() {
        viewModel.clearRetracted(key)
    }

    var canMarkSeenLocally: Bool {
        guard let request = viewModel.request(for: key),
              !viewModel.isRetracted(key),
              request.lifecycleStatus == .open,
              request.intentReceipt == nil,
              request.informationalSeenStatus == .available else { return false }
        return !finished
    }

    var canFinishLocally: Bool {
        guard let request = viewModel.request(for: key),
              !viewModel.isRetracted(key),
              request.lifecycleStatus == .open,
              request.intentReceipt == nil else { return false }
        if request.draft.noCommentSelected { return true }
        if request.informationalSeenStatus != nil || message.kind == .instructions { return true }
        if message.kind == .multipleChoice {
            if ownAnswer {
                return request.draft.inputs[ExactText("answer")]?.textByActionID[ExactText("own")]?.rawValue
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            return !choices.isEmpty
        }
        switch request.projection {
        case let .sender(sender):
            var hasAnswerInput = false
            for input in sender.inputs {
                switch input.kind {
                case let .response(actions):
                    hasAnswerInput = true
                    guard let selected = request.draft.inputs[input.id]?.selectedActionID,
                          let action = actions.first(where: { $0.id == selected }) else { return false }
                    if action.kind == .text,
                       request.draft.inputs[input.id]?.textByActionID[selected]?.rawValue
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        return false
                    }
                case .text:
                    if input.id.rawValue == "value" {
                        hasAnswerInput = true
                        guard let rawValue = request.draft.inputs[input.id]?.text?.rawValue,
                              let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                              (7...90).contains(value) else { return false }
                    }
                case .point:
                    hasAnswerInput = true
                    guard request.draft.inputs[input.id]?.effectivePoint != nil else { return false }
                }
            }
            return hasAnswerInput
        case let .compatibility(actions):
            guard let selected = request.draft.compatibility.selectedActionID,
                  let action = actions.first(where: { $0.id == selected }) else { return false }
            return action.kind != .text || request.draft.compatibility.textByActionID[selected]?.rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .unsupported:
            return false
        }
    }

    func finishLocally() {
        guard canFinishLocally else { return }
        finished = true
    }

    var isClosed: Bool {
        guard let status = viewModel.request(for: key)?.lifecycleStatus else { return false }
        return status != .open && status != .pending
    }
    var choices: Set<String> {
        get {
            if message.kind == .multipleChoice {
                return Set(message.options.compactMap {
                    draft?.inputs[ExactText($0.id)]?.selectedActionID == ExactText("yes") ? $0.id : nil
                })
            }
            guard let id = draft?.inputs[ExactText("answer")]?.selectedActionID?.rawValue, id != "own" else { return [] }
            return [id]
        }
        set {
            if message.kind == .multipleChoice {
                for option in message.options {
                    viewModel.selectAction(ExactText(newValue.contains(option.id) ? "yes" : "no"),
                        input: ExactText(option.id), for: key)
                }
            } else if let id = newValue.first {
                viewModel.selectAction(ExactText(id), input: ExactText("answer"), for: key)
            }
        }
    }
    var ownAnswer: Bool {
        get { draft?.inputs[ExactText("answer")]?.selectedActionID == ExactText("own") }
        set {
            if newValue {
                viewModel.selectAction(ExactText("own"), input: ExactText("answer"), for: key)
            } else if message.kind == .multipleChoice && ownAnswer {
                viewModel.selectAction(ExactText("options"), input: ExactText("answer"), for: key)
            }
        }
    }
    var text: String {
        get {
            if ownAnswer { return draft?.inputs[ExactText("answer")]?.textByActionID[ExactText("own")]?.rawValue ?? "" }
            return draft?.inputs[ExactText("note")]?.text?.rawValue ?? ""
        }
        set {
            viewModel.updateText(newValue, input: ExactText(ownAnswer ? "answer" : "note"),
                action: ownAnswer ? ExactText("own") : nil, for: key)
        }
    }
    var number: Double {
        get { Double(draft?.inputs[ExactText("value")]?.text?.rawValue ?? "") ?? 30 }
        set { viewModel.updateText(String(newValue), input: ExactText("value"), action: nil, for: key) }
    }
    private struct AnnotationDraft: Codable {
        var marks: [SampleMark] = []
        var strokes: [[SampleMark]] = []
        var actions: [AnnotationAction] = []
    }
    private var annotations: AnnotationDraft {
        get {
            guard let value = draft?.inputs[ExactText("annotation")]?.text?.rawValue,
                  let data = value.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(AnnotationDraft.self, from: data) else { return AnnotationDraft() }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue), let text = String(data: data, encoding: .utf8) else { return }
            let mark = newValue.marks.last ?? newValue.strokes.last?.last
            viewModel.updateLocalExampleAnnotation(text, point: mark.map {
                PointValue(x: PointTransform.quantize($0.x), y: PointTransform.quantize($0.y))
            }, for: key)
        }
    }
    var marks: [SampleMark] {
        get { annotations.marks }
        set { annotations.marks = newValue }
    }
    var strokes: [[SampleMark]] {
        get { annotations.strokes }
        set { annotations.strokes = newValue }
    }
    private(set) var annotationActions: [AnnotationAction] {
        get { annotations.actions }
        set { annotations.actions = newValue }
    }
    var finished = false {
        didSet {
            if finished && !noCommentSelected && message.kind == .instructions {
                viewModel.selectAction(ExactText("done"), input: ExactText("answer"), for: key)
            }
        }
    }
    var chatRead = false
    private var conversationRevision: UInt64 { viewModel.conversation(for: key)?.currentRevision ?? 1 }
    var chatDraft: String {
        get { viewModel.conversationDraft(for: key, revision: conversationRevision).text.rawValue }
        set { viewModel.updateConversation(for: key, revision: conversationRevision, text: newValue) }
    }
    var attachments: [String] {
        get { viewModel.conversationDraft(for: key, revision: conversationRevision).files.map { $0.name.rawValue } }
        set {
            viewModel.updateConversation(for: key, revision: conversationRevision, files: [])
            for name in newValue { viewModel.addLocalAttachment(name, for: key, revision: conversationRevision) }
        }
    }
    var chat: [SampleChatLine] {
        (viewModel.conversation(for: key)?.turns ?? []).map {
            SampleChatLine(id: $0.id.rawValue, text: $0.text.rawValue, fromPerson: $0.author == .person,
                attachmentNames: $0.files.map { $0.name.rawValue })
        }
    }

    func addMark(_ mark: SampleMark) {
        var value = annotations
        value.marks.append(mark)
        value.actions.append(.mark(mark.id))
        annotations = value
    }

    func addStroke(_ stroke: [SampleMark]) {
        guard !stroke.isEmpty else { return }
        var value = annotations
        value.strokes.append(stroke)
        value.actions.append(.stroke)
        annotations = value
    }

    func removeMark(_ id: UUID) {
        var value = annotations
        value.marks.removeAll { $0.id == id }
        value.actions.removeAll { $0 == .mark(id) }
        annotations = value
    }

    func undoAnnotation() {
        var value = annotations
        guard let action = value.actions.popLast() else { return }
        switch action {
        case let .mark(id): value.marks.removeAll { $0.id == id }
        case .stroke: if !value.strokes.isEmpty { value.strokes.removeLast() }
        }
        annotations = value
    }

    func choose(_ id: String, multiple: Bool) {
        if multiple {
            if choices.contains(id) { choices.remove(id) } else { choices.insert(id) }
        } else { choices = [id] }
        ownAnswer = false
        finished = false
    }

    func sendLocalChat() {
        viewModel.sendDiscussion(for: key, revision: conversationRevision)
    }
}

@MainActor @Observable
final class SampleLibrary {
    private(set) var fixture: SampleFixtureDomain?
    private(set) var loadError: String?
    private(set) var responses: [String: SampleResponse] = [:]
    private var reorderedIDs: [String] = []
    var selectedID: String?
    var lastViewedID: String?

    var messages: [SampleMessage] {
        guard let fixture else { return [] }
        let catalog = Dictionary(uniqueKeysWithValues: SampleCatalog.messages.map { ($0.id, $0) })
        let projected = fixture.viewModel.presentation.requests.compactMap { request -> SampleMessage? in
            guard let metadata = catalog[request.key.messageID.rawValue] else { return nil }
            return SampleMessage(id: request.key.messageID.rawValue, kind: metadata.kind,
                sender: metadata.sender, initials: metadata.initials,
                title: request.title?.rawValue ?? "", body: request.body?.rawValue ?? "",
                options: metadata.options, deadline: metadata.deadline, missed: metadata.missed,
                revised: metadata.revised, chatUnread: metadata.chatUnread, hasChat: metadata.hasChat,
                fixtureCreatedAtMilliseconds: metadata.fixtureCreatedAtMilliseconds,
                declaredMessageType: metadata.declaredMessageType,
                declaredMessageKind: metadata.declaredMessageKind)
        }
        guard !reorderedIDs.isEmpty else { return projected }
        let byID = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
        return reorderedIDs.compactMap { byID[$0] }
    }

    func populate() {
        do {
            let fixture = try self.fixture ?? SampleFixtureDomain()
            try fixture.populate()
            self.fixture = fixture
            for message in messages where responses[message.id] == nil {
                let response = SampleResponse(viewModel: fixture.viewModel, key: fixture.key(for: message), message: message)
                if message.kind == .value,
                   fixture.viewModel.request(for: response.key)?.draft.inputs[ExactText("value")]?.text?.rawValue.isEmpty != false {
                    response.number = 30
                }
                responses[message.id] = response
            }
            loadError = nil
        } catch {
            loadError = "Local examples could not be loaded."
        }
    }

    /// Composition happens after domain projection, before ordinary inbox rendering.
    func inboxItems(appendingTo requests: [InboxRequestRow]) -> [InboxItem] {
        requests.map(InboxItem.request) + messages.compactMap { message in
            guard let response = responses[message.id], !response.clearedFromList else { return nil }
            return InboxItem.example(message, response)
        }
    }

    func select(_ id: String?) {
        select(id, departingFrom: selectedID)
    }

    func select(_ id: String?, departingFrom previousID: String?) {
        let previousKey = previousID.flatMap { responses[$0]?.key }
        let nextKey = id.flatMap { responses[$0]?.key }
        fixture?.viewModel.navigateMessage(from: previousKey, to: nextKey)
        UIDiagnostics.shared.record("samples.select \(previousID ?? "nil")->\(id ?? "nil") selectedID=\(selectedID ?? "nil") requests=\(fixture?.viewModel.presentation.requests.count ?? -1) messages=\(messages.count)")
        selectedID = id
        if let id {
            lastViewedID = id
            if let response = responses[id] { fixture?.viewModel.selectRequest(response.key) }
        }
    }

    func neighbor(of id: String, direction: Int) -> SampleMessage? {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages.indices.contains(index + direction) else { return nil }
        return messages[index + direction]
    }

    func demonstrateReorder() {
        guard messages.count > 1 else { return }
        let ids = messages.map(\.id)
        reorderedIDs = Array(ids.dropFirst()) + [ids[0]]
        // Selection remains identity-bound even when its position changes.
    }
}

enum SampleCatalog {
    static var messages: [SampleMessage] {
        var messages = standardMessages
        #if DEBUG
        var acceptanceMessages: [SampleMessage] = []
        if ProcessInfo.processInfo.arguments.contains("--harklight-data-detector-acceptance") {
            acceptanceMessages.append(dataDetectorAcceptanceMessage)
        }
        if ProcessInfo.processInfo.arguments.contains("--harklight-message-kind-acceptance") {
            if let requestIndex = messages.firstIndex(where: { $0.id == "sample-note-0" }) {
                messages[requestIndex].declaredMessageType = .request
                messages[requestIndex].declaredMessageKind = .blocker
            }
            acceptanceMessages.append(messageKindAcceptanceMessage)
        }
        return messages + acceptanceMessages
        #endif
        return messages
    }

    private static let standardMessages: [SampleMessage] = (0..<3).flatMap { variation in
        SampleKind.allCases.enumerated().map { index, kind in
            let context = ["studio", "garden", "library"][variation]
            let content = content(for: kind, context: context)
            return SampleMessage(id: "sample-\(kind.rawValue)-\(variation)", kind: kind,
                                 sender: content.sender, initials: String(content.sender.split(separator: " ").compactMap(\.first)).uppercased(),
                                 title: content.title, body: content.body, options: content.options,
                                 deadline: index.isMultiple(of: 3) ? (variation == 1 ? "Due yesterday" : "By 5 PM") : nil,
                                 missed: variation == 1 && index.isMultiple(of: 3), revised: variation == 2,
                                 chatUnread: variation == 0 && index.isMultiple(of: 2), hasChat: variation != 1,
                                 tier: variation == 0 && kind == .approval ? .top
                                    : variation == 0 && kind == .pictureChoice ? .low : .middle,
                                 fixtureCreatedAtMilliseconds: 1_790_000_000_000
                                    + (variation * SampleKind.allCases.count + index) * 60_000)
        }
    }

    #if DEBUG
    private static let dataDetectorAcceptanceMessage = SampleMessage(
        id: "sample-data-detector-acceptance",
        kind: .information,
        sender: "Calendar assistant",
        initials: "CA",
        title: "Detector acceptance",
        body: "Select this sentence to verify that copying remains available.\n\nhttps://example.invalid/detector-acceptance\n\nNovember 4, 2027 at 2:00 PM.",
        options: [],
        deadline: nil,
        missed: false,
        revised: false,
        chatUnread: false,
        hasChat: false,
        fixtureCreatedAtMilliseconds: 1_790_000_000_000)

    private static let messageKindAcceptanceMessage = SampleMessage(
        id: "sample-message-kind-success",
        kind: .completed,
        sender: "Release assistant",
        initials: "RA",
        title: "Release package is ready",
        body: "The reviewed package is available and the handoff is complete.",
        options: [],
        deadline: nil,
        missed: false,
        revised: false,
        chatUnread: false,
        hasChat: false,
        fixtureCreatedAtMilliseconds: 1_790_000_060_000,
        declaredMessageType: .fyi,
        declaredMessageKind: .success)
    #endif

    private struct Content {
        let sender: String
        let title: String
        let body: String
        var options: [SampleOption] = []
    }

    private static func content(for kind: SampleKind, context: String) -> Content {
        switch kind {
        case .approval:
            Content(sender: "Project assistant", title: "Archive the old \(context) sketches?",
                    body: "The new collection is ready. Choose what happens to the earlier sketches. The sketches remain useful as a record of the original ideas, and nothing will be removed until you decide. Archiving keeps them available without filling the active collection. Keeping them here lets you compare both versions while the new layout settles. Deleting them clears space after you have confirmed you no longer need the old drafts.", options: [
                        .init(id: "archive", title: "Archive", detail: "Keep a copy out of the active collection.", role: .suggested),
                        .init(id: "delete", title: "Delete", detail: "Remove the earlier sketches.", role: .destructive),
                        .init(id: "keep", title: "Keep here", detail: "Leave both collections visible.")])
        case .textChoice:
            Content(sender: "Planning assistant", title: "Which approach for the \(context)?",
                    body: "We can take a small first step or prepare the whole space. A small start gives us feedback before we commit the rest of the layout. Planning everything first settles the complete arrangement before anything moves. Pick an approach, or describe your own.", options: [
                        .init(id: "small", title: "Start small", detail: "Try one area, then adjust based on what we learn."),
                        .init(id: "whole", title: "Plan the whole space", detail: "Resolve the layout before moving anything.", role: .suggested)])
        case .pictureChoice:
            Content(sender: "Design assistant", title: "Which cover for the \(context) journal?",
                    body: "Three covers use the same text but give the journal very different first impressions. Select a picture; tap it again or hold to enlarge. You can still change the cover before the journal is shared.", options: pictures)
        case .instructions:
            Content(sender: "Setup assistant", title: "Prepare the \(context) display",
                    body: "1. Place the display on its stand.\n\n2. Adjust the angle so the page is easy to read.\n\n3. Check the light, then mark this done.")
        case .review:
            Content(sender: "Writing assistant", title: "Review the \(context) welcome text",
                    body: "Read the proposed wording below, then choose whether to keep it.", options: [
                        .init(id: "accept", title: "Keep the revision", detail: "Use the shorter introduction.", role: .suggested),
                        .init(id: "revise", title: "Request changes", detail: "Explain what should change.")])
        case .multipleChoice:
            Content(sender: "Publishing assistant", title: "Where should the \(context) update go?",
                    body: "Select every place that fits. The same note can appear in more than one place.", options: [
                        .init(id: "email", title: "Email", detail: "The regular readers."),
                        .init(id: "board", title: "Notice board", detail: "A short printed copy."),
                        .init(id: "journal", title: "Journal", detail: "Keep a longer record.")])
        case .value:
            Content(sender: "Planning assistant", title: "Keep \(context) drafts for how long?",
                    body: "Longer keeps more history. Shorter leaves a smaller collection. Slide or type a number of days.")
        case .point:
            Content(sender: "Design assistant", title: "Where should the \(context) title go?",
                    body: "Mark a spot on the cover. Draw or add a note if the placement needs explaining.")
        case .colorChoice:
            Content(sender: "Design assistant", title: "Accent color for the \(context)",
                    body: "Choose the accent used alongside the journal's neutral text.", options: [
                        .init(id: "blue", title: "Harbor blue", detail: "Quiet and cool.", role: .suggested),
                        .init(id: "orange", title: "Warm amber", detail: "A warmer accent."),
                        .init(id: "green", title: "Meadow green", detail: "A natural accent.")])
        case .soundChoice:
            Content(sender: "Setup assistant", title: "Which \(context) reminder sound?",
                    body: "Compare the sound descriptions. Audio playback is a placeholder in these local examples.", options: [
                        .init(id: "bell", title: "Soft bell", detail: "One clear note."),
                        .init(id: "chime", title: "Chime", detail: "Three light notes.", role: .suggested),
                        .init(id: "quiet", title: "Silent", detail: "A visual reminder only.")])
        case .note:
            Content(sender: "Writing assistant", title: "A note for the \(context) journal?",
                    body: "Write a short introduction in your own words. The text stays in this local example.")
        case .error:
            Content(sender: "Collection assistant", title: "The \(context) preview could not be opened",
                    body: "The original pages are safe. Only the preview needs to be rebuilt.")
        case .warning:
            Content(sender: "Collection assistant", title: "The \(context) collection is nearly full",
                    body: "There is room for a few more pages. Consider archiving earlier drafts when convenient.")
        case .information:
            Content(sender: "Calendar assistant", title: "The \(context) review moved to Thursday",
                    body: "The new time is 2 PM. The agenda and location are unchanged.")
        case .completed:
            Content(sender: "Collection assistant", title: "The \(context) journal is ready",
                    body: "All pages are collected, the index is complete, and a copy is saved.")
        }
    }

    static let pictures: [SampleOption] = [
        .init(id: "night", title: "Night sky", detail: "A dark sky above the hills."),
        .init(id: "harbor", title: "Harbor", detail: "Still water in the evening."),
        .init(id: "meadow", title: "Meadow", detail: "Open fields in daylight.")
    ]
}
