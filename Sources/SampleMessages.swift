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
    // Prescribed fixture emphasis, never computed from deadlines or live requests.
    let emphasis: Int
}

struct SampleMark: Identifiable, Equatable, Codable {
    var id = UUID()
    var x: Double
    var y: Double
    var note: String = ""
}

struct SampleChatLine: Identifiable, Equatable {
    let id = UUID()
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
            if finished && message.kind == .instructions {
                viewModel.selectAction(ExactText("done"), input: ExactText("answer"), for: key)
            }
        }
    }
    var deferred = false
    var chatRead = false
    var chatDraft = ""
    var attachments: [String] = []
    var chat: [SampleChatLine] = []

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
        guard !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        chat.append(SampleChatLine(text: chatDraft, fromPerson: true, attachmentNames: attachments))
        chatDraft = ""
        attachments = []
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
                sender: request.key.senderID.rawValue, initials: metadata.initials,
                title: request.title?.rawValue ?? "", body: request.body?.rawValue ?? "",
                options: metadata.options, deadline: metadata.deadline, missed: metadata.missed,
                revised: metadata.revised, chatUnread: metadata.chatUnread, hasChat: metadata.hasChat,
                emphasis: metadata.emphasis)
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
                if message.hasChat {
                    response.chat = [
                        SampleChatLine(text: "Could you explain the tradeoff?", fromPerson: true),
                        SampleChatLine(text: "The first option favors speed; the second leaves more room to revise. This is an example conversation.", fromPerson: false)
                    ]
                }
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
            responses[message.id].map { InboxItem.example(message, $0) }
        }
    }

    func select(_ id: String?) {
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
    static let messages: [SampleMessage] = (0..<3).flatMap { variation in
        SampleKind.allCases.enumerated().map { index, kind in
            let context = ["studio", "garden", "library"][variation]
            let content = content(for: kind, context: context)
            return SampleMessage(id: "sample-\(kind.rawValue)-\(variation)", kind: kind,
                                 sender: content.sender, initials: String(content.sender.split(separator: " ").compactMap(\.first)),
                                 title: content.title, body: content.body, options: content.options,
                                 deadline: index.isMultiple(of: 3) ? (variation == 1 ? "Due yesterday" : "By 5 PM") : nil,
                                 missed: variation == 1 && index.isMultiple(of: 3), revised: variation == 2,
                                 chatUnread: variation == 0 && index.isMultiple(of: 2), hasChat: variation != 1,
                                 emphasis: variation == 0 ? max(0, 3 - index / 3) : (variation == 1 ? 1 : 0))
        }
    }

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
                    body: "The new collection is ready. Choose what happens to the earlier sketches.", options: [
                        .init(id: "archive", title: "Archive", detail: "Keep a copy out of the active collection.", role: .suggested),
                        .init(id: "delete", title: "Delete", detail: "Remove the earlier sketches.", role: .destructive),
                        .init(id: "keep", title: "Keep here", detail: "Leave both collections visible.")])
        case .textChoice:
            Content(sender: "Planning assistant", title: "Which approach for the \(context)?",
                    body: "We can take a small first step or prepare the whole space. Pick an approach, or describe your own.", options: [
                        .init(id: "small", title: "Start small", detail: "Try one area, then adjust based on what we learn."),
                        .init(id: "whole", title: "Plan the whole space", detail: "Resolve the layout before moving anything.", role: .suggested)])
        case .pictureChoice:
            Content(sender: "Design assistant", title: "Which cover for the \(context) journal?",
                    body: "Three covers, the same text. Select a picture; tap it again or hold to enlarge.", options: pictures)
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
