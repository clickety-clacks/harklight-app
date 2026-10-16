import AttentionDomain
import SwiftUI

@MainActor
struct LiveContentView: View {
    let store: LivePresentationStore
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            LiveRequestList(store: store)
        } detail: {
            NavigationStack {
                if let request = store.selectedRequest {
                    LiveRequestDetail(request: request, store: store)
                        .id(request.key)
                } else {
                    ContentUnavailableView("Select a request", systemImage: "tray")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let observationError = store.observationError {
                    Label(observationError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                if let notificationWarning = store.notificationWarning {
                    Label(notificationWarning, systemImage: "bell.slash")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                if let connectionWarning = store.connectionWarning {
                    Label(connectionWarning, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                if let pushRegistrationWarning = store.pushRegistrationWarning {
                    Label(pushRegistrationWarning, systemImage: "bell.badge")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
    }
}

@MainActor
private struct LiveRequestList: View {
    let store: LivePresentationStore

    var body: some View {
        List(selection: Binding(get: { store.selectedRequestKey },
                                set: { store.selectRequest($0) })) {
            Section("Open") {
                ForEach(store.openRequests, id: \.key) { request in
                    LiveRequestRow(request: request).tag(request.key)
                }
            }
            if !store.resolvedRequests.isEmpty {
                Section("Resolved") {
                    ForEach(store.resolvedRequests, id: \.key) { request in
                        LiveRequestRow(request: request).tag(request.key)
                    }
                }
            }
        }
        .navigationTitle("Requests")
    }
}

private struct LiveRequestRow: View {
    let request: PresentedRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.title?.rawValue ?? request.key.senderID.rawValue)
                .font(.headline)
            Text(LiveLifecycleTitle(request.lifecycleStatus).label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LiveRequestDetail: View {
    let request: PresentedRequest
    let store: LivePresentationStore

    var canAnswer: Bool {
        guard request.lifecycleStatus == .open, request.intentReceipt == nil else { return false }
        switch request.projection {
        case .sender: return true
        case let .compatibility(actions): return !actions.isEmpty
        case .unsupported: return false
        }
    }

    private var submitLabel: String {
        if case let .sender(sender) = request.projection { return sender.submissionLabel.rawValue }
        return "Send answer"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(request.title?.rawValue ?? request.key.senderID.rawValue)
                        .font(.title2.bold())
                    Spacer()
                    Text(LiveLifecycleTitle(request.lifecycleStatus).label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
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
                if canAnswer {
                    Button(submitLabel) { store.submitFromUser(request.key) }
                        .buttonStyle(.borderedProminent)
                } else if request.lifecycleStatus == .pending {
                    Button("Retry delivery") { store.retryPendingDelivery() }
                        .buttonStyle(.bordered)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Request")
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

    private var draft: InputDraft? { store.request(for: request.key)?.draft.inputs[input.id] }

    var body: some View {
        switch input.kind {
        case let .response(actions):
            VStack(alignment: .leading, spacing: 10) {
                Text(input.label.rawValue).font(.headline)
                if layout == .cards {
                    AdaptiveGridLayout(maxColumns: 2, minimumItemWidth: 138, spacing: 10) {
                        ForEach(actions, id: \.id) { action in actionButton(action) }
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(actions, id: \.id) { action in actionButton(action) }
                    }
                }
                if let selected = draft?.selectedActionID,
                   let action = actions.first(where: { $0.id == selected }),
                   action.kind == .text {
                    TextEditor(text: Binding(
                        get: { store.request(for: request.key)?.draft.inputs[input.id]?.textByActionID[selected]?.rawValue ?? "" },
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
                    get: { store.request(for: request.key)?.draft.inputs[input.id]?.text?.rawValue ?? "" },
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
                Text(action.label.rawValue)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3)))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .disabled(readOnly)
    }

    private func pointBinding(horizontal: Bool) -> Binding<Int> {
        Binding(
            get: {
                let point = store.request(for: request.key)?.draft.inputs[input.id]?.effectivePoint
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
        store.request(for: request.key)?.draft.compatibility.selectedActionID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(actions, id: \.id) { action in
                Button(action.label.rawValue) {
                    store.selectAction(action.id, input: nil, for: request.key)
                }
                .buttonStyle(.bordered)
                .accessibilityValue(selected == action.id ? "Selected" : "Not selected")
                .disabled(readOnly)
            }
            if let selected,
               let action = actions.first(where: { $0.id == selected }),
               action.kind == .text {
                TextEditor(text: Binding(
                    get: { store.request(for: request.key)?.draft.compatibility.textByActionID[selected]?.rawValue ?? "" },
                    set: { store.updateCompatibilityText($0, action: selected, for: request.key) }
                ))
                .frame(minHeight: 120)
                .accessibilityLabel(action.label.rawValue)
                .disabled(readOnly)
            }
        }
    }
}

private struct LiveLifecycleTitle {
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
