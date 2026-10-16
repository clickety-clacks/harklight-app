import SwiftUI
import AttentionDomain

@MainActor
struct ContentView: View {
    let store: PrototypeStore
    let samples: SampleLibrary
    @AccessibilityFocusState private var accessibilityFocus: AttentionAccessibilityFocus?

    var body: some View {
        if let loadError = store.loadError {
            ContentUnavailableView(loadError, systemImage: "exclamationmark.triangle")
        } else {
            HarklightInbox(
                requests: (store.openRequests + store.resolvedRequests).map {
                    InboxRequestRow(key: $0.key, title: $0.title.rawValue, sender: $0.key.senderID.rawValue,
                                    status: store.statusLabel(for: $0.key), bodyText: $0.body?.rawValue ?? "")
                }, samples: samples, selectRequest: { store.selectRequest($0) },
                requestDetail: { key, context in
                    RequestDetailView(store: store, requestKey: key,
                                      accessibilityFocus: $accessibilityFocus, context: context)
                },
                warnings: [store.persistenceError].compactMap { $0 })
        }
    }
}

private enum AttentionAccessibilityFocus: Hashable {
    case requestHeading
    case requestStatus
    case requestDetailsHeading
    case demoHeading
    case demoOutcomeStatus
}

@MainActor
private struct RequestDetailView: View {
    let store: PrototypeStore
    let requestKey: RequestKey
    let accessibilityFocus: AccessibilityFocusState<AttentionAccessibilityFocus?>.Binding
    let context: InboxCardContext

    var body: some View {
        if let request = store.request(for: requestKey),
           let session = store.session(for: requestKey) {
            RequestDetailContent(request: request,
                                session: session,
                                store: store,
                                accessibilityFocus: accessibilityFocus, context: context)
        } else {
            ContentUnavailableView("Request unavailable", systemImage: "questionmark.folder")
        }
    }
}

@MainActor
private struct RequestDetailContent: View {
    let request: FixtureRequest
    let session: RequestSession
    let store: PrototypeStore
    let accessibilityFocus: AccessibilityFocusState<AttentionAccessibilityFocus?>.Binding
    let context: InboxCardContext
    @State private var instructionsExpanded = false
    @State private var isShowingRequestDetails = false

    private var status: RequestStatusPresentation {
        RequestStatusPresentation(lifecycle: session.lifecycle)
    }

    private var isOpen: Bool {
        if case .open = session.lifecycle { return true }
        return false
    }

    private var receiptJSON: String? {
        switch session.lifecycle {
        case .open:
            return nil
        case let .pending(submission), let .terminal(_, submission):
            return submission.answer.jsonString
        }
    }

    var body: some View {
        MessageCardSurface(context: context) {
            VStack(alignment: .leading, spacing: 20) {
                RequestOverviewSection(title: request.title.rawValue, sender: request.key.senderID.rawValue,
                                       status: status,
                                       accessibilityFocus: accessibilityFocus,
                                       onShowDetails: { isShowingRequestDetails = true })

                switch request.interface {
                case let .sender(document):
                    if let messageBody = request.body?.rawValue {
                        MessageInstructionsDisclosure(messageBody: messageBody,
                                                      isExpanded: $instructionsExpanded)
                    }
                    switch session.lifecycle {
                    case .open:
                        SenderSceneView(document: document,
                                        scene: document.open,
                                        requestKey: request.key,
                                        store: store,
                                        readOnly: false,
                                        authorizedAnswer: nil)
                    case .pending:
                        SenderSceneView(document: document,
                                        scene: document.open,
                                        requestKey: request.key,
                                        store: store,
                                        readOnly: true,
                                        authorizedAnswer: nil)
                    case let .terminal(terminal, _):
                        SenderSceneView(document: document,
                                        scene: document.terminalScene(state: terminal.state,
                                                                      authorizedAnswer: terminal.authorizedAnswer),
                                        requestKey: request.key,
                                        store: store,
                                        readOnly: true,
                                        authorizedAnswer: terminal.authorizedAnswer)
                    }
                case let .compatibility(form):
                    if let messageBody = request.body?.rawValue {
                        DirectMessageInstructions(messageBody: messageBody)
                    }
                    if case .open = session.lifecycle {
                        CompatibilityFormView(form: form, requestKey: request.key, store: store)
                    }
                case let .unsupported(reason):
                    if let messageBody = request.body?.rawValue {
                        DirectMessageInstructions(messageBody: messageBody)
                    }
                    UnsupportedInterfaceSection(reason: reason,
                                                accountScope: request.key.accountScope,
                                                senderID: request.key.senderID,
                                                messageID: request.key.messageID,
                                                onShowDetails: { isShowingRequestDetails = true },
                                                onReturnToList: { store.selectRequest(nil) })
                }



            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Send answer", systemImage: "checkmark") { store.sendSelectedAnswer(for: request.key) }
                    .labelStyle(.iconOnly).disabled(!store.canSend(for: request.key))
                    .accessibilityIdentifier("send-answer")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Cancel draft", systemImage: "arrow.uturn.backward") { store.cancelDraft(for: request.key) }
                    .labelStyle(.iconOnly).disabled(!session.draft.hasEdits)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingRequestDetails) {
            RequestDetailsView(request: request,
                               status: status,
                               payloadJSON: request.originalPayload.jsonString,
                               receiptJSON: receiptJSON,
                               accessibilityFocus: accessibilityFocus,
                               onReturnToRequest: { isShowingRequestDetails = false })
        }
        .onChange(of: isShowingRequestDetails) { _, isShowing in
            if isShowing {
                accessibilityFocus.wrappedValue = .requestDetailsHeading
            } else {
                Task { @MainActor in
                    await Task.yield()
                    accessibilityFocus.wrappedValue = .requestStatus
                }
            }
        }
        .onAppear {
            accessibilityFocus.wrappedValue = .requestHeading
        }
    }
}

private struct RequestOverviewSection: View {
    let title: String
    let sender: String
    let status: RequestStatusPresentation
    let accessibilityFocus: AccessibilityFocusState<AttentionAccessibilityFocus?>.Binding
    let onShowDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MessageHeading(sender: sender, initials: String(sender.prefix(2)).uppercased(), title: title)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused(accessibilityFocus, equals: .requestHeading)
                .accessibilityIdentifier("request-heading")
            statusButton
        }
    }

    private var statusButton: some View {
        Button(action: onShowDetails) {
            HStack(spacing: 6) {
                Text(status.badgeTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "info.circle")
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: Capsule())
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.75))
            .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(status.accessibleName))
        .accessibilityHint("Opens the outcome, original message, and exact identity details.")
        .accessibilityIdentifier("request-status-details")
        .accessibilityFocused(accessibilityFocus, equals: .requestStatus)
    }
}

private struct RequestStatusPresentation {
    let badgeTitle: LocalizedStringResource
    let accessibleName: LocalizedStringResource
    let outcomeDetails: LocalizedStringResource

    init(lifecycle: FixtureLifecycle) {
        switch lifecycle {
        case .open:
            badgeTitle = LocalizedStringResource("Open", comment: "Compact app-owned lifecycle badge for a request with no submitted answer.")
            accessibleName = LocalizedStringResource("Open. No answer has been submitted.", comment: "Accessible name for the Open lifecycle badge and its current answer status.")
            outcomeDetails = "No answer has been submitted. Any current draft remains a draft."
        case .pending:
            badgeTitle = LocalizedStringResource("Pending", comment: "Compact app-owned lifecycle badge for a locally saved answer.")
            accessibleName = LocalizedStringResource("Pending. The answer is saved locally in this fixture; no relay is connected.", comment: "Accessible name for the Pending lifecycle badge and its fixture-only answer status.")
            outcomeDetails = "The answer is saved locally in this fictional fixture. No relay is connected, so relay delivery or source use is not established."
        case let .terminal(terminal, _):
            switch terminal.state {
            case .answered:
                badgeTitle = LocalizedStringResource("Answered", comment: "Compact request lifecycle badge; this state alone does not mean this device's answer was accepted.")
            case .cleared:
                badgeTitle = LocalizedStringResource("Cleared", comment: "Compact app-owned lifecycle badge for a cleared request.")
            case .expired:
                badgeTitle = LocalizedStringResource("Expired", comment: "Compact app-owned lifecycle badge for an expired request.")
            case .superseded:
                badgeTitle = LocalizedStringResource("Superseded", comment: "Compact app-owned lifecycle badge for a superseded request.")
            }
            accessibleName = Self.terminalAccessibleName(state: terminal.state,
                                                         outcome: terminal.ownOutcome)
            outcomeDetails = Self.terminalOutcomeDetails(for: terminal.ownOutcome)
        }
    }

    private static func terminalAccessibleName(state: TerminalState,
                                               outcome: OwnOutcome) -> LocalizedStringResource {
        switch (state, outcome) {
        case (.answered, .accepted):
            LocalizedStringResource("Answered. This fixture simulates acceptance for this submission; no relay or source result exists, and source use is not shown.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.answered, .unconfirmed):
            LocalizedStringResource("Answered. Your submission outcome is unconfirmed; the original operation outcome remains unresolved.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.answered, .notApplicable):
            LocalizedStringResource("Answered. No result for this device's submission is established.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.cleared, .accepted):
            LocalizedStringResource("Cleared. This fixture simulates acceptance for this submission; no relay or source result exists, and source use is not shown.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.cleared, .unconfirmed):
            LocalizedStringResource("Cleared. Your submission outcome is unconfirmed; the original operation outcome remains unresolved.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.cleared, .notApplicable):
            LocalizedStringResource("Cleared. No result for this device's submission is established.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.expired, .accepted):
            LocalizedStringResource("Expired. This fixture simulates acceptance for this submission; no relay or source result exists, and source use is not shown.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.expired, .unconfirmed):
            LocalizedStringResource("Expired. Your submission outcome is unconfirmed; the original operation outcome remains unresolved.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.expired, .notApplicable):
            LocalizedStringResource("Expired. No result for this device's submission is established.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.superseded, .accepted):
            LocalizedStringResource("Superseded. This fixture simulates acceptance for this submission; no relay or source result exists, and source use is not shown.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.superseded, .unconfirmed):
            LocalizedStringResource("Superseded. Your submission outcome is unconfirmed; the original operation outcome remains unresolved.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        case (.superseded, .notApplicable):
            LocalizedStringResource("Superseded. No result for this device's submission is established.", comment: "Accessible name for the request status button; this sentence combines lifecycle and this device's outcome.")
        }
    }

    private static func terminalOutcomeDetails(for outcome: OwnOutcome) -> LocalizedStringResource {
        switch outcome {
        case .accepted:
            "This fictional fixture simulates acceptance for this submission. No relay or source receipt exists, and source use is not shown."
        case .unconfirmed:
            "This fixture records a closed request without confirming this submission's result. The original operation outcome remains unconfirmed; no relay or source effect is established."
        case .notApplicable:
            "This fixture records a terminal request state. No result for this device's submission is established."
        }
    }
}

private struct MessageInstructionsDisclosure: View {
    let messageBody: String
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup("Message instructions", isExpanded: $isExpanded) {
            Text(messageBody)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityIdentifier("message-instructions-disclosure")
    }
}

private struct DirectMessageInstructions: View {
    let messageBody: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Message instructions")
                .font(.headline)
            Text(messageBody)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("message-instructions")
    }
}

private struct RequestDetailsView: View {
    let request: FixtureRequest
    let status: RequestStatusPresentation
    let payloadJSON: String
    let receiptJSON: String?
    let accessibilityFocus: AccessibilityFocusState<AttentionAccessibilityFocus?>.Binding
    let onReturnToRequest: () -> Void

    private var requestReferenceJSON: String {
        JSONValue.object([
            JSONMember("account", .string(request.key.accountScope)),
            JSONMember("sender_id", .string(request.key.senderID)),
            JSONMember("message_id", .string(request.key.messageID))
        ]).jsonString
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button("Return to request", action: onReturnToRequest)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("request-details-return")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Outcome")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused(accessibilityFocus, equals: .requestDetailsHeading)
                        .accessibilityIdentifier("request-details-outcome-heading")
                    Text(status.outcomeDetails)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("request-details-outcome")
                }

                if let receiptJSON {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your submitted answer · exact JSON")
                            .font(.headline)
                            .accessibilityIdentifier("request-details-receipt")
                        exactJSON(receiptJSON, accessibilityID: "request-details-receipt-json")
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Original message")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    IdentityDetailValue(label: "Title", value: request.title.rawValue)
                    if let messageBody = request.body {
                        IdentityDetailValue(label: "Message body",
                                            value: messageBody.rawValue.isEmpty ? "Empty" : messageBody.rawValue)
                    } else {
                        IdentityDetailValue(label: "Message body", value: "Not supplied")
                    }
                    if let answerDescription = request.answerDescription {
                        IdentityDetailValue(label: "Answer description", value: answerDescription.jsonString)
                    }
                    if let stake = request.stake {
                        IdentityDetailValue(label: "Stake", value: stake.jsonString)
                    }
                    if let byWhen = request.byWhen {
                        IdentityDetailValue(label: "By when", value: byWhen.jsonString)
                    }
                    if let createdAt = request.createdAt {
                        IdentityDetailValue(label: "Created", value: createdAt.jsonString)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Original payload")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        exactJSON(payloadJSON, accessibilityID: "request-details-original-payload")
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Identity")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    IdentityDetailValue(label: "Account", value: request.key.accountScope.rawValue)
                    IdentityDetailValue(label: "Sender ID", value: request.key.senderID.rawValue)
                    IdentityDetailValue(label: "Message ID", value: request.key.messageID.rawValue)
                    Button("Copy request reference") {
                        UIPasteboard.general.string = requestReferenceJSON
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("request-details-copy-reference")
                }

            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Request details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            accessibilityFocus.wrappedValue = .requestDetailsHeading
        }
    }

    private func exactJSON(_ value: String, accessibilityID: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier(accessibilityID)
    }
}

private struct IdentityDetailValue: View {
    let label: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                labelText
                    .fixedSize(horizontal: true, vertical: false)
                valueText
                    .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 3) {
                labelText
                valueText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labelText: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var valueText: some View {
        Text(value)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .layoutPriority(1)
            .accessibilityIdentifier("identity-value-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

@MainActor
private struct DemoControlsView: View {
    let store: PrototypeStore
    let accessibilityFocus: AccessibilityFocusState<AttentionAccessibilityFocus?>.Binding
    let onReturn: (RequestKey) -> Void
    @State private var targetKey: RequestKey?
    @State private var appliedToKey: RequestKey?

    init(store: PrototypeStore,
         initialTarget: RequestKey?,
         accessibilityFocus: AccessibilityFocusState<AttentionAccessibilityFocus?>.Binding,
         onReturn: @escaping (RequestKey) -> Void) {
        self.store = store
        self.accessibilityFocus = accessibilityFocus
        self.onReturn = onReturn
        _targetKey = State(initialValue: initialTarget)
    }

    private var targetIsPending: Bool {
        guard let targetKey,
              let session = store.session(for: targetKey),
              case .pending = session.lifecycle else { return false }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Demo controls")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused(accessibilityFocus, equals: .demoHeading)

                DemoScopeDisclosure()

                DemoTargetSection(store: store, targetKey: $targetKey)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Simulate an outcome")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("These controls apply an example result to the selected pending request.")
                        .foregroundStyle(.secondary)

                    ForEach(DemoTerminalScenario.allCases) { scenario in
                        Button(scenario.simulationTitle) {
                            guard let targetKey,
                                  store.simulateTerminal(for: targetKey, scenario: scenario) else { return }
                            appliedToKey = targetKey
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(!targetIsPending)
                        .accessibilityIdentifier("demo-scenario-\(scenario.rawValue)")
                    }
                }

                if appliedToKey == targetKey, targetKey != nil {
                    Text("Example outcome applied")
                        .font(.headline)
                        .accessibilityIdentifier("demo-outcome-status")
                        .accessibilityFocused(accessibilityFocus, equals: .demoOutcomeStatus)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Return to request") {
                guard let targetKey else { return }
                onReturn(targetKey)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            .disabled(targetKey == nil)
            .accessibilityIdentifier("demo-return-to-request")
        }
        .onChange(of: targetKey) { _, newValue in
            if appliedToKey != newValue { appliedToKey = nil }
        }
        .onChange(of: appliedToKey) { _, newValue in
            if newValue != nil { accessibilityFocus.wrappedValue = .demoOutcomeStatus }
        }
        .onAppear { accessibilityFocus.wrappedValue = .demoHeading }
        .navigationTitle("Demo controls")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DemoScopeDisclosure: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fictional data and simulated outcomes. Nothing is delivered to a relay or source.")
                .font(.headline)
            Text("Drafts and captured answers are stored locally on this device and persist across app restarts. Reinstalling the app or clearing its local data resets this fixture.")
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("demo-scope-disclosure")
    }
}

private struct DemoTargetSection: View {
    let store: PrototypeStore
    @Binding var targetKey: RequestKey?

    private var targetRequest: FixtureRequest? {
        targetKey.flatMap { store.request(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Target request")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Picker("Request", selection: $targetKey) {
                Text("Choose a request").tag(nil as RequestKey?)
                ForEach(store.fixtures.requests) { request in
                    Text(request.title.rawValue).tag(Optional(request.key))
                }
            }
            .accessibilityIdentifier("demo-target-picker")

            if let targetKey, let targetRequest {
                LabeledContent("Request", value: targetRequest.title.rawValue)
                    .textSelection(.enabled)
                LabeledContent("Sender ID", value: targetKey.senderID.rawValue)
                    .textSelection(.enabled)
                LabeledContent("Message ID", value: targetKey.messageID.rawValue)
                    .textSelection(.enabled)
                LabeledContent("Current state", value: store.statusLabel(for: targetKey))
            } else {
                Text("Choose a request to inspect its fixture state and available actions.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AppActionRow: View {
    let requestKey: RequestKey
    let hasDraft: Bool
    let store: PrototypeStore

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button("Cancel draft", role: .cancel) {
                store.cancelDraft(for: requestKey)
            }
            .buttonStyle(.bordered)
            .disabled(!hasDraft)
            .frame(maxWidth: .infinity, minHeight: 44)
            .fixedSize(horizontal: false, vertical: true)

            Button("Send answer") {
                store.sendSelectedAnswer(for: requestKey)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canSend(for: requestKey))
            .frame(maxWidth: .infinity, minHeight: 44)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("send-answer")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct SenderSceneView: View {
    let document: SenderDocument
    let scene: SceneNode
    let requestKey: RequestKey
    let store: PrototypeStore
    let readOnly: Bool
    let authorizedAnswer: JSONValue?

    var body: some View {
        SceneNodeView(document: document,
                      node: scene,
                      requestKey: requestKey,
                      store: store,
                      readOnly: readOnly,
                      authorizedAnswer: authorizedAnswer)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}

@MainActor
private struct SceneNodeView: View {
    let document: SenderDocument
    let node: SceneNode
    let requestKey: RequestKey
    let store: PrototypeStore
    let readOnly: Bool
    let authorizedAnswer: JSONValue?

    var body: some View {
        switch node.kind {
        case let .stack(axis, children):
            switch axis {
            case .vertical:
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(children) { child in
                        childView(child)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .horizontal:
                FlowLayout(spacing: 12) {
                    ForEach(children) { child in
                        childView(child)
                    }
                }
            }
        case let .grid(columns, children):
            AdaptiveGridLayout(maxColumns: columns, minimumItemWidth: 150, spacing: 12) {
                ForEach(children) { child in
                    childView(child)
                }
            }
        case let .text(value, style):
            SceneTextView(text: value.rawValue, style: style)
        case let .illustration(id):
            if let illustration = document.illustration(withID: id) {
                SenderIllustrationCanvas(illustration: illustration, point: nil)
            }
        case let .input(id, layout):
            if let input = document.input(withID: id),
               let draft = store.inputDraft(for: requestKey, inputID: id) {
                SenderInputView(document: document,
                                input: input,
                                layout: layout,
                                draft: draft,
                                requestKey: requestKey,
                                store: store,
                                readOnly: readOnly)
            }
        case let .resultPoint(illustrationID, label, _):
            if let illustration = document.illustration(withID: illustrationID),
               let point = authorizedAnswer.flatMap({ document.resultPoint(in: node, answer: $0) }) {
                VStack(alignment: .leading, spacing: 8) {
                    SenderIllustrationCanvas(illustration: illustration, point: point)
                    Text(label.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label.rawValue)
                .accessibilityValue("Horizontal \(point.x), vertical \(point.y)")
            }
        }
    }

    @ViewBuilder
    private func childView(_ child: SceneNode) -> some View {
        SceneNodeView(document: document,
                      node: child,
                      requestKey: requestKey,
                      store: store,
                      readOnly: readOnly,
                      authorizedAnswer: authorizedAnswer)
    }
}

struct SceneTextView: View {
    let text: String
    let style: SceneTextStyle

    var body: some View {
        switch style {
        case .title:
            Text(text).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        case .body:
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        case .caption:
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private struct SenderInputView: View {
    let document: SenderDocument
    let input: SenderInput
    let layout: InputLayout
    let draft: InputDraft
    let requestKey: RequestKey
    let store: PrototypeStore
    let readOnly: Bool

    var body: some View {
        switch input.kind {
        case let .response(actions):
            ResponseInputView(document: document,
                              inputID: input.id,
                              actions: actions,
                              layout: layout,
                              selectedActionID: draft.selectedActionID,
                              requestKey: requestKey,
                              store: store,
                              readOnly: readOnly)
        case .text:
            VStack(alignment: .leading, spacing: 8) {
                Text(input.label.rawValue).font(.headline)
                TextEditor(text: Binding(
                    get: { store.textDraft(for: requestKey, inputID: input.id, actionID: nil).rawValue },
                    set: { store.updateText($0, for: requestKey, inputID: input.id, actionID: nil) }
                ))
                .frame(minHeight: 120)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel(input.label.rawValue)
                .accessibilityIdentifier("text-input-\(input.id.rawValue)")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(readOnly)
            }
        case let .point(illustrationID):
            if let illustration = document.illustration(withID: illustrationID) {
                PointInputView(label: input.label.rawValue,
                               illustration: illustration,
                               point: draft.effectivePoint,
                               pointHasBeenSet: draft.hasInitializedPoint,
                               coordinateEntryInvalid: draft.hasInvalidCoordinateEntry,
                               requestKey: requestKey,
                               inputID: input.id,
                               store: store,
                               readOnly: readOnly)
            }
        }
    }
}

@MainActor
private struct ResponseInputView: View {
    let document: SenderDocument
    let inputID: ExactText
    let actions: [SenderAction]
    let layout: InputLayout
    let selectedActionID: ExactText?
    let requestKey: RequestKey
    let store: PrototypeStore
    let readOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                ForEach(actions) { action in actionButton(action) }
            }

            if let selectedActionID,
               let action = actions.first(where: { $0.id == selectedActionID }),
               case .text = action.kind {
                TextEditor(text: Binding(
                    get: { store.textDraft(for: requestKey, inputID: inputID, actionID: action.id).rawValue },
                    set: { store.updateText($0, for: requestKey, inputID: inputID, actionID: action.id) }
                ))
                .frame(minHeight: 120)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel(action.label.rawValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(readOnly)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: SenderAction) -> some View {
        let selected = selectedActionID == action.id
        Button {
            store.selectAction(action.id, inputID: inputID, for: requestKey)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if let id = action.illustrationID,
                   let illustration = document.illustration(withID: id) {
                    SenderIllustrationCanvas(illustration: illustration, point: nil)
                }
                MessageChoiceLabel(title: action.label.rawValue, detail: "",
                                   selected: selected, multiple: false, suggested: false)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(readOnly)
        .accessibilityLabel(action.label.rawValue)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
private struct PointInputView: View {
    let label: String
    let illustration: SenderIllustration
    let point: PointValue?
    let pointHasBeenSet: Bool
    let coordinateEntryInvalid: Bool
    let requestKey: RequestKey
    let inputID: ExactText
    let store: PrototypeStore
    let readOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(.headline)
            PointDiagramView(label: label,
                             illustration: illustration,
                             point: point,
                             requestKey: requestKey,
                             inputID: inputID,
                             store: store,
                             readOnly: readOnly)
                .id(requestKey)

            if let point {
                Text("Horizontal \(point.x), vertical \(point.y)")
                    .font(.subheadline.weight(.medium))
                    .accessibilityLabel("Selected point")
                    .accessibilityValue("Horizontal \(point.x), vertical \(point.y)")
            } else if pointHasBeenSet {
                Text("Correct the coordinates below")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No point selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !readOnly {
                if !pointHasBeenSet {
                    Button("Set point") {
                        store.setPoint(PointValue(x: 500, y: 500), for: requestKey, inputID: inputID)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("set-point")
                    .accessibilityHint("Sets the initial point at horizontal 500 and vertical 500.")
                } else {
                    CoordinateEditor(label: "Horizontal position",
                                     accessibilityID: "coordinate-horizontal",
                                     text: Binding(
                                        get: { store.coordinateText(for: requestKey, inputID: inputID, horizontal: true) },
                                        set: { store.updateCoordinate($0, horizontal: true, for: requestKey, inputID: inputID) }
                                     ),
                                     value: point?.x ?? 0,
                                     canStep: !coordinateEntryInvalid,
                                     step: { store.stepPoint(horizontal: true, by: $0, for: requestKey, inputID: inputID) },
                                     readOnly: readOnly)
                    CoordinateEditor(label: "Vertical position",
                                     accessibilityID: "coordinate-vertical",
                                     text: Binding(
                                        get: { store.coordinateText(for: requestKey, inputID: inputID, horizontal: false) },
                                        set: { store.updateCoordinate($0, horizontal: false, for: requestKey, inputID: inputID) }
                                     ),
                                     value: point?.y ?? 0,
                                     canStep: !coordinateEntryInvalid,
                                     step: { store.stepPoint(horizontal: false, by: $0, for: requestKey, inputID: inputID) },
                                     readOnly: readOnly)
                }
                if coordinateEntryInvalid {
                    Text("Enter whole-number coordinates from 0 to 1000.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("coordinate-entry-error")
                }
            }
        }
    }
}

@MainActor
private struct CoordinateEditor: View {
    let label: String
    let accessibilityID: String
    @Binding var text: String
    let value: Int
    let canStep: Bool
    let step: (Int) -> Void
    let readOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(label, text: $text)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
                .accessibilityIdentifier(accessibilityID)
                .disabled(readOnly)
            Stepper(value: Binding(
                get: { value },
                set: { newValue in step(newValue - value) }
            ), in: 0...1000) {
                Text(label)
            }
            .disabled(readOnly || !canStep)
        }
    }
}

@MainActor
private struct PointDiagramView: View {
    let label: String
    let illustration: SenderIllustration
    let point: PointValue?
    let requestKey: RequestKey
    let inputID: ExactText
    let store: PrototypeStore
    let readOnly: Bool
    @State private var capture = PointGestureCapture()
    @GestureState private var gestureActive = false

    var body: some View {
        GeometryReader { geometry in
            let bounds = SenderIllustrationCanvas.fittedRect(size: geometry.size,
                                                             sourceWidth: illustration.width,
                                                             sourceHeight: illustration.height)
            ZStack {
                SenderIllustrationCanvas(illustration: illustration, point: point)
                if !readOnly {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .updating($gestureActive) { _, active, _ in
                                active = true
                            }
                            .onChanged { value in
                                if let selected = capture.update(at: value.location, in: bounds) {
                                    store.setPoint(selected, for: requestKey, inputID: inputID)
                                }
                            }
                            .onEnded { value in
                                if let selected = capture.finish(at: value.location, in: bounds) {
                                    store.setPoint(selected, for: requestKey, inputID: inputID)
                                }
                            })
                }
            }
            .onChange(of: bounds) { _, newBounds in
                capture.cancelIfBoundsChanged(to: newBounds)
            }
            .onChange(of: gestureActive) { wasActive, isActive in
                if wasActive && !isActive {
                    capture.gestureDidEnd()
                }
            }
        }
        .aspectRatio(CGFloat(illustration.width) / CGFloat(illustration.height), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(illustration.label.rawValue)
        .accessibilityHint(readOnly ? "Read-only illustration." : "Tap or drag to select a point.")
    }
}

struct PointGestureCapture {
    private var capturedBounds: CGRect?
    private var isCancelled = false

    mutating func update(at location: CGPoint, in bounds: CGRect) -> PointValue? {
        guard !isCancelled else { return nil }
        let isDragging = capturedBounds != nil
        if let capturedBounds, capturedBounds != bounds {
            isCancelled = true
            return nil
        }
        guard let point = PointTransform.select(pointerX: location.x,
                                                pointerY: location.y,
                                                bounds: bounds,
                                                dragging: isDragging) else {
            isCancelled = true
            return nil
        }
        if capturedBounds == nil {
            capturedBounds = bounds
        }
        return point
    }

    mutating func finish(at location: CGPoint, in bounds: CGRect) -> PointValue? {
        defer { gestureDidEnd() }
        guard !isCancelled,
              let capturedBounds,
              capturedBounds == bounds else { return nil }
        return PointTransform.select(pointerX: location.x,
                                     pointerY: location.y,
                                     bounds: bounds,
                                     dragging: true)
    }

    mutating func cancelIfBoundsChanged(to bounds: CGRect) {
        guard let capturedBounds, capturedBounds != bounds else { return }
        isCancelled = true
    }

    mutating func gestureDidEnd() {
        self = Self()
    }
}

struct SenderIllustrationCanvas: View {
    let illustration: SenderIllustration
    let point: PointValue?

    var body: some View {
        GeometryReader { geometry in
            let rect = Self.fittedRect(size: geometry.size,
                                       sourceWidth: illustration.width,
                                       sourceHeight: illustration.height)
            Canvas { context, _ in
                context.clip(to: Path(rect))
                for primitive in illustration.primitives {
                    Self.draw(primitive, context: &context, rect: rect, sourceWidth: illustration.width, sourceHeight: illustration.height)
                }
                if let point {
                    Self.draw(point, context: &context, rect: rect)
                }
            }
        }
        .aspectRatio(CGFloat(illustration.width) / CGFloat(illustration.height), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    static func fittedRect(size: CGSize, sourceWidth: Int, sourceHeight: Int) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(sourceWidth), size.height / CGFloat(sourceHeight))
        let width = CGFloat(sourceWidth) * scale
        let height = CGFloat(sourceHeight) * scale
        return CGRect(x: (size.width - width) / 2,
                      y: (size.height - height) / 2,
                      width: width,
                      height: height)
    }

    private static func draw(_ primitive: GraphicPrimitive,
                             context: inout GraphicsContext,
                             rect: CGRect,
                             sourceWidth: Int,
                             sourceHeight: Int) {
        let scaleX = rect.width / CGFloat(sourceWidth)
        let scaleY = rect.height / CGFloat(sourceHeight)
        func x(_ value: Int) -> CGFloat { rect.minX + CGFloat(value) * scaleX }
        func y(_ value: Int) -> CGFloat { rect.minY + CGFloat(value) * scaleY }

        switch primitive {
        case let .rect(px, py, width, height, fill):
            let shape = Path(CGRect(x: x(px), y: y(py), width: CGFloat(width) * scaleX, height: CGFloat(height) * scaleY))
            context.fill(shape, with: .color(Self.color(fill)))
        case let .circle(cx, cy, radius, fill):
            let width = CGFloat(radius) * scaleX
            let height = CGFloat(radius) * scaleY
            let shape = Path(ellipseIn: CGRect(x: x(cx) - width, y: y(cy) - height, width: width * 2, height: height * 2))
            context.fill(shape, with: .color(Self.color(fill)))
        case let .line(x1, y1, x2, y2, stroke, strokeWidth):
            var path = Path()
            path.move(to: CGPoint(x: x(x1), y: y(y1)))
            path.addLine(to: CGPoint(x: x(x2), y: y(y2)))
            context.stroke(path, with: .color(Self.color(stroke)), lineWidth: CGFloat(strokeWidth) * min(scaleX, scaleY))
        case let .text(px, py, value, fill, fontSize, align):
            let anchor: UnitPoint
            switch align {
            case .start: anchor = .bottomLeading
            case .middle: anchor = .bottom
            case .end: anchor = .bottomTrailing
            }
            let text = Text(value.rawValue)
                .font(.system(size: CGFloat(fontSize) * min(scaleX, scaleY)))
                .foregroundColor(Self.color(fill))
            context.draw(text, at: CGPoint(x: x(px), y: y(py)), anchor: anchor)
        }
    }

    private static func draw(_ point: PointValue, context: inout GraphicsContext, rect: CGRect) {
        let center = CGPoint(x: rect.minX + rect.width * CGFloat(point.x) / 1000,
                             y: rect.minY + rect.height * CGFloat(point.y) / 1000)
        let radius: CGFloat = 8
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(.white))
        context.stroke(circle, with: .color(.blue), lineWidth: 2)
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - 13, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + 13, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - 13))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + 13))
        context.stroke(cross, with: .color(.blue), lineWidth: 2)
    }

    private static func color(_ value: ExactText) -> Color {
        let digits = Array(value.rawValue.utf8.dropFirst())
        guard digits.count == 6 else { return .clear }
        let parts = stride(from: 0, to: 6, by: 2).map { index in
            UInt8(String(decoding: digits[index..<(index + 2)], as: UTF8.self), radix: 16) ?? 0
        }
        return Color(red: Double(parts[0]) / 255, green: Double(parts[1]) / 255, blue: Double(parts[2]) / 255)
    }
}

struct AdaptiveGridLayout: Layout {
    let maxColumns: Int
    let minimumItemWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = max(1, proposal.width ?? minimumItemWidth * CGFloat(maxColumns))
        let columns = columnCount(width: availableWidth)
        let cellWidth = max(1, (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)) }
        var height: CGFloat = 0
        for start in stride(from: 0, to: sizes.count, by: columns) {
            let row = sizes[start..<min(start + columns, sizes.count)]
            height += row.map(\.height).max() ?? 0
            if start + columns < sizes.count { height += spacing }
        }
        return CGSize(width: availableWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columnCount(width: bounds.width)
        let cellWidth = max(1, (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)) }
        var rowY = bounds.minY
        for start in stride(from: 0, to: sizes.count, by: columns) {
            let end = min(start + columns, sizes.count)
            let rowHeight = sizes[start..<end].map(\.height).max() ?? 0
            for index in start..<end {
                let column = index - start
                let origin = CGPoint(x: bounds.minX + CGFloat(column) * (cellWidth + spacing), y: rowY)
                subviews[index].place(at: origin,
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: cellWidth, height: rowHeight))
            }
            rowY += rowHeight + spacing
        }
    }

    private func columnCount(width: CGFloat) -> Int {
        max(1, min(maxColumns, Int((width + spacing) / (minimumItemWidth + spacing))))
    }
}

struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +))
        let result = layout(subviews, width: width)
        return CGSize(width: width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews, width: max(1, bounds.width))
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + placement.origin.x,
                                              y: bounds.minY + placement.origin.y),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: placement.size.width, height: placement.size.height))
        }
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> (placements: [FlowPlacement], height: CGFloat) {
        var placements: [FlowPlacement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let itemWidth = min(width, max(44, ideal.width))
            let size = subview.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            if x > 0 && x + itemWidth > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            placements.append(FlowPlacement(origin: CGPoint(x: x, y: y), size: CGSize(width: itemWidth, height: size.height)))
            x += itemWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (placements, placements.isEmpty ? 0 : y + rowHeight)
    }
}

private struct FlowPlacement {
    let origin: CGPoint
    let size: CGSize
}

@MainActor
private struct CompatibilityFormView: View {
    let form: AnswerForm
    let requestKey: RequestKey
    let store: PrototypeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(form.actions) { action in
                let selected = store.compatibilityActionSelected(for: requestKey) == action.id
                Button {
                    store.selectAction(action.id, inputID: nil, for: requestKey)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .accessibilityHidden(true)
                        Text(action.label.rawValue)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(12)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3)))
                .accessibilityValue(selected ? "Selected" : "Not selected")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }

            if let selected = store.compatibilityActionSelected(for: requestKey),
               let action = form.action(withID: selected), action.kind == .text {
                TextEditor(text: Binding(
                    get: { store.textDraft(for: requestKey, inputID: nil, actionID: action.id).rawValue },
                    set: { store.updateText($0, for: requestKey, inputID: nil, actionID: action.id) }
                ))
                .frame(minHeight: 120)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel(action.label.rawValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
        }
    }
}

private struct UnsupportedInterfaceSection: View {
    let reason: UnsupportedInterfaceReason
    let accountScope: ExactText
    let senderID: ExactText
    let messageID: ExactText
    let onShowDetails: () -> Void
    let onReturnToList: () -> Void
    @State private var didCopyReference = false

    private var referenceJSON: String {
        JSONValue.object([
            JSONMember("account", .string(accountScope)),
            JSONMember("sender_id", .string(senderID)),
            JSONMember("message_id", .string(messageID))
        ]).jsonString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reason == .missing ? "No supported sender interface was supplied." : "This sender interface is not supported here.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Request details", action: onShowDetails).buttonStyle(.bordered)
                Button("Copy request reference") {
                    UIPasteboard.general.string = referenceJSON
                    didCopyReference = true
                }
                .buttonStyle(.bordered)
            }
            if didCopyReference {
                Text("Request reference copied.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Return to request list", action: onReturnToList).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
