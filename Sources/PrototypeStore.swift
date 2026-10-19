import Observation
import Foundation
import AttentionDomain

enum DemoTerminalScenario: String, CaseIterable, Identifiable, Sendable {
    case ownOperationAccepted
    case answerOutcomeUnconfirmed
    case cleared
    case expired
    case superseded

    var id: String { rawValue }

    var simulationTitle: LocalizedStringResource {
        switch self {
        case .ownOperationAccepted: return "Simulate accepted answer for this submission"
        case .answerOutcomeUnconfirmed: return "Simulate an unconfirmed answer outcome"
        case .cleared: return "Simulate request cleared"
        case .expired: return "Simulate request expired"
        case .superseded: return "Simulate request superseded"
        }
    }

    var state: TerminalState {
        switch self {
        case .ownOperationAccepted, .answerOutcomeUnconfirmed: return .answered
        case .cleared: return .cleared
        case .expired: return .expired
        case .superseded: return .superseded
        }
    }
}

@MainActor
@Observable
final class PrototypeStore {
    static let defaultCaptureLimit = 65_536

    let fixtures: FixtureSet
    let loadError: String?
    let captureLimitBytes: Int
    private(set) var selectedRequestKey: RequestKey?
    private(set) var persistenceError: String?
    private(set) var snapshot: AttentionStoreSnapshot?
    private(set) var presentationStore: LivePresentationStore?

    @ObservationIgnored private let domainStore: AttentionDomainStore?
    @ObservationIgnored private let profileContext: ProfileContext
    @ObservationIgnored private let port: AttentionDomainPort?
    @ObservationIgnored private var selectors: [RequestKey: BoundDocumentSelector] = [:]

    var sessions: [RequestKey: RequestSession] { snapshot?.fixtureSessions ?? [:] }

    init(fixtures: FixtureSet,
         loadError: String? = nil,
         captureLimitBytes: Int = defaultCaptureLimit,
         persistence: (any AttentionStatePersistence)? = nil,
         resetFixtureAtLaunch: Bool = false) {
        self.fixtures = fixtures
        self.captureLimitBytes = max(0, captureLimitBytes)
        self.selectedRequestKey = fixtures.requests.first?.key

        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:attention-client-m2"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("fictional-sample-device"))
        let profile = ProfileContext(identity: identity, transportMode: .fixture)
        self.profileContext = profile

        var createdStore: AttentionDomainStore?
        var createdPort: AttentionDomainPort?
        var createdPresentation: LivePresentationStore?
        var initialSnapshot: AttentionStoreSnapshot?
        var initializationError: String?
        do {
            let store = try AttentionDomainStore(context: profile,
                                                 persistence: persistence ?? MemoryAttentionStatePersistence(),
                                                 maximumWireFrameBytes: max(0, captureLimitBytes))
            let requests = fixtures.requests.map { StoredRequest(key: $0.key, originalPayload: $0.originalPayload) }
            if resetFixtureAtLaunch {
                try store.resetFixtureState(requests, context: profile)
            } else {
                try store.registerFixtureRequests(requests, context: profile)
            }
            createdStore = store
            createdPort = AttentionDomainPort(store: store)
            createdPresentation = try LivePresentationStore(
                localFixtureStore: store,
                context: profile)
            initialSnapshot = try store.snapshot(context: profile)
        } catch {
            initializationError = error.localizedDescription
        }
        self.domainStore = createdStore
        self.port = createdPort
        self.presentationStore = createdPresentation
        self.snapshot = initialSnapshot
        self.loadError = loadError ?? initializationError.map { "Local durable state could not be opened: \($0)" }
    }

    static func loadFromBundle(_ bundle: Bundle = .main) -> PrototypeStore {
        do {
            return PrototypeStore(fixtures: try FixtureSet.loadBundled(from: bundle),
                                  persistence: try FileAttentionStatePersistence.applicationSupport(),
                                  resetFixtureAtLaunch: ProcessInfo.processInfo.arguments.contains("--reset-attention-fixture"))
        } catch {
            let empty = FixtureSet(accountScope: ExactText("fictional-sample-account"),
                                  requests: [],
                                  legacyValueConformanceVectors: [],
                                  legacyTextConformanceVectors: [],
                                  validSubmissions: [],
                                  invalidSubmissions: [],
                                  pointVectors: [],
                                  terminalContexts: [],
                                  additionalCases: [])
            return PrototypeStore(fixtures: empty, loadError: "The bundled fixture or local durable store could not be opened.")
        }
    }

    var openRequests: [FixtureRequest] {
        fixtures.requests.filter { request in
            guard let session = sessions[request.key] else { return false }
            if case .terminal = session.lifecycle { return false }
            return true
        }
    }

    var resolvedRequests: [FixtureRequest] {
        fixtures.requests.filter { request in
            guard let session = sessions[request.key] else { return false }
            if case .terminal = session.lifecycle { return true }
            return false
        }
    }

    func request(for key: RequestKey) -> FixtureRequest? {
        fixtures.requests.first(where: { $0.key == key })
    }

    func session(for key: RequestKey) -> RequestSession? {
        sessions[key]
    }

    func statusLabel(for key: RequestKey) -> String {
        guard let lifecycle = sessions[key]?.lifecycle else { return "Open" }
        switch lifecycle {
        case .open: return "Open"
        case .pending: return "Pending"
        case let .terminal(terminal, _): return terminal.state.rawValue.capitalized
        }
    }

    func selectRequest(_ key: RequestKey?) {
        guard let key else {
            selectedRequestKey = nil
            return
        }
        guard request(for: key) != nil else { return }
        selectedRequestKey = key
    }

    func inputDraft(for key: RequestKey, inputID: ExactText) -> InputDraft? {
        sessions[key]?.draft.inputs[inputID]
    }

    func compatibilityActionSelected(for key: RequestKey) -> ExactText? {
        sessions[key]?.draft.compatibility.selectedActionID
    }

    func selectAction(_ actionID: ExactText, inputID: ExactText?, for key: RequestKey) {
        guard let request = request(for: key), var session = sessions[key], case .open = session.lifecycle else { return }
        switch request.interface {
        case let .sender(document):
            guard let inputID, let input = document.input(withID: inputID),
                  case let .response(actions) = input.kind,
                  let action = actions.first(where: { $0.id == actionID }) else { return }
            var draft = session.draft.inputs[inputID] ?? InputDraft.initial(for: input)
            draft.selectedActionID = actionID
            if case .text = action.kind, draft.textByActionID[actionID] == nil {
                draft.textByActionID[actionID] = ExactText("")
            }
            session.draft.inputs[inputID] = draft
        case let .compatibility(form):
            guard inputID == nil, form.action(withID: actionID) != nil else { return }
            session.draft.compatibility.selectedActionID = actionID
            if form.action(withID: actionID)?.kind == .text,
               session.draft.compatibility.textByActionID[actionID] == nil {
                session.draft.compatibility.textByActionID[actionID] = ExactText("")
            }
        case .unsupported:
            return
        }
        persistDraft(session.draft, for: key)
    }

    func textDraft(for key: RequestKey, inputID: ExactText?, actionID: ExactText?) -> ExactText {
        guard let request = request(for: key), let session = sessions[key] else { return ExactText("") }
        if let inputID, let input = session.draft.inputs[inputID] {
            if let actionID { return input.textByActionID[actionID] ?? ExactText("") }
            return input.text ?? ExactText("")
        }
        if case .compatibility = request.interface, let actionID {
            return session.draft.compatibility.textByActionID[actionID] ?? ExactText("")
        }
        return ExactText("")
    }

    func updateText(_ text: String, for key: RequestKey, inputID: ExactText?, actionID: ExactText?) {
        guard let request = request(for: key), var session = sessions[key], case .open = session.lifecycle else { return }
        if case let .sender(document) = request.interface, let inputID,
           let descriptor = document.input(withID: inputID), var draft = session.draft.inputs[inputID] {
            switch descriptor.kind {
            case .text where actionID == nil:
                draft.text = ExactText(text)
            case let .response(actions) where actionID != nil:
                guard let action = actions.first(where: { $0.id == actionID }), case .text = action.kind,
                      draft.selectedActionID == actionID else { return }
                draft.textByActionID[action.id] = ExactText(text)
            default:
                return
            }
            session.draft.inputs[inputID] = draft
        } else if case let .compatibility(form) = request.interface,
                  inputID == nil, let actionID, form.action(withID: actionID)?.kind == .text,
                  session.draft.compatibility.selectedActionID == actionID {
            session.draft.compatibility.textByActionID[actionID] = ExactText(text)
        } else {
            return
        }
        persistDraft(session.draft, for: key)
    }

    func coordinateText(for key: RequestKey, inputID: ExactText, horizontal: Bool) -> String {
        guard let input = sessions[key]?.draft.inputs[inputID] else { return "" }
        let raw = horizontal ? input.horizontalText : input.verticalText
        if let raw { return raw.rawValue }
        let coordinate = horizontal ? input.point?.x : input.point?.y
        return coordinate.map(String.init) ?? ""
    }

    func setPoint(_ point: PointValue, for key: RequestKey, inputID: ExactText) {
        guard (0...1000).contains(point.x), (0...1000).contains(point.y),
              let request = request(for: key), case let .sender(document) = request.interface,
              document.input(withID: inputID).map({ if case .point = $0.kind { return true }; return false }) == true,
              var session = sessions[key], case .open = session.lifecycle,
              var draft = session.draft.inputs[inputID] else { return }
        draft.point = point
        draft.horizontalText = ExactText(String(point.x))
        draft.verticalText = ExactText(String(point.y))
        session.draft.inputs[inputID] = draft
        persistDraft(session.draft, for: key)
    }

    func updateCoordinate(_ text: String, horizontal: Bool, for key: RequestKey, inputID: ExactText) {
        guard let request = request(for: key), case let .sender(document) = request.interface,
              document.input(withID: inputID).map({ if case .point = $0.kind { return true }; return false }) == true,
              var session = sessions[key], case .open = session.lifecycle,
              var draft = session.draft.inputs[inputID], draft.point != nil else { return }
        if horizontal {
            draft.horizontalText = ExactText(text)
        } else {
            draft.verticalText = ExactText(text)
        }
        session.draft.inputs[inputID] = draft
        persistDraft(session.draft, for: key)
    }

    func cancelDraft(for key: RequestKey) {
        guard let session = sessions[key], case .open = session.lifecycle,
              let port, let selector = try? boundSelector(for: key) else { return }
        do {
            try port.cancelDraft(context: port.context, selector: selector)
            refreshSnapshot()
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    func canSend(for key: RequestKey) -> Bool {
        guard let session = sessions[key], case .open = session.lifecycle,
              let port, let records = typedRecords(for: key, draft: session.draft),
              let selector = try? boundSelector(for: key),
              let answer = try? port.preview(context: port.context, selector: selector, inputs: records) else {
            return false
        }
        return answer.jsonString.utf8.count <= captureLimitBytes
    }

    func canSendNoCommentLocally(for key: RequestKey) -> Bool {
        guard let presentationStore, !presentationStore.isReadOnly,
              let request = presentationStore.request(for: key),
              request.inboxStateIsCurrent, !presentationStore.isRetracted(key),
              request.lifecycleStatus == .open, request.intentReceipt == nil,
              request.informationalSeenStatus == nil,
              !request.noCommentUnavailable else { return false }
        return true
    }

    @discardableResult
    func sendNoCommentLocally(for key: RequestKey) -> Bool {
        guard canSendNoCommentLocally(for: key), let port,
              let selector = try? boundSelector(for: key) else { return false }
        do {
            _ = try port.submitNoComment(context: port.context, selector: selector, intentID: UUID())
            refreshSnapshot()
            persistenceError = nil
            return true
        } catch {
            persistenceError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func sendSelectedAnswer(for key: RequestKey,
                            explicitCompatibilityAction: ExactText? = nil) -> Bool {
        refreshSnapshot()
        guard let session = sessions[key], case .open = session.lifecycle,
              let port, let records = typedRecords(for: key, draft: session.draft,
                                                   explicitCompatibilityAction: explicitCompatibilityAction),
              let selector = try? boundSelector(for: key) else { return false }
        do {
            let intent = SubmitIntent(context: port.context,
                                      selector: selector,
                                      intentID: UUID(),
                                      inputs: records)
            _ = try port.submit(intent)
            refreshSnapshot()
            return true
        } catch {
            persistenceError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func simulateTerminal(for key: RequestKey, scenario: DemoTerminalScenario) -> Bool {
        refreshSnapshot()
        guard let store = domainStore, let session = sessions[key],
              case let .pending(submission) = session.lifecycle else { return false }
        let terminal: FixtureTerminal
        switch scenario {
        case .ownOperationAccepted:
            terminal = FixtureTerminal(state: .answered,
                                       evidenceLabel: "simulated success for this original operation",
                                       authorizedAnswer: submission.answer,
                                       ownOutcome: .accepted)
        case .answerOutcomeUnconfirmed:
            terminal = FixtureTerminal(state: .answered,
                                       evidenceLabel: "simulated closure without this operation's result",
                                       authorizedAnswer: nil,
                                       ownOutcome: .unconfirmed)
        case .cleared, .expired, .superseded:
            terminal = FixtureTerminal(state: scenario.state,
                                       evidenceLabel: "simulated terminal lifecycle without this operation's result",
                                       authorizedAnswer: nil,
                                       ownOutcome: .unconfirmed)
        }
        do {
            try store.recordFixtureTerminal(terminal, for: key, context: profileContext)
            refreshSnapshot()
            persistenceError = nil
            return true
        } catch {
            persistenceError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func simulateResolution(for key: RequestKey) -> Bool {
        simulateTerminal(for: key, scenario: .answerOutcomeUnconfirmed)
    }

    private func persistDraft(_ draft: RequestDraft, for key: RequestKey) {
        guard let domainStore, let selector = try? boundSelector(for: key) else { return }
        do {
            try domainStore.saveDraft(draft, selector: selector, context: profileContext)
            refreshSnapshot()
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func refreshSnapshot() {
        guard let domainStore else { return }
        do {
            snapshot = try domainStore.snapshot(context: profileContext)
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    func refreshFromDurableStore() {
        refreshSnapshot()
    }

    private func boundSelector(for key: RequestKey) throws -> BoundDocumentSelector {
        if let cached = selectors[key] { return cached }
        guard let domainStore else { throw AttentionStoreError.persistence("The durable store is unavailable.") }
        let selector = try domainStore.selector(for: key, context: profileContext)
        selectors[key] = selector
        return selector
    }

    private func typedRecords(for key: RequestKey,
                              draft: RequestDraft,
                              explicitCompatibilityAction: ExactText? = nil) -> [TypedInputRecord]? {
        guard let request = request(for: key) else { return nil }
        switch request.interface {
        case let .sender(document):
            var records: [TypedInputRecord] = []
            for input in document.inputs {
                guard let inputDraft = draft.inputs[input.id] else { return nil }
                switch input.kind {
                case let .response(actions):
                    guard let actionID = inputDraft.selectedActionID,
                          let action = actions.first(where: { $0.id == actionID }) else { return nil }
                    if case .value = action.kind {
                        records.append(.responseValue(input: input.id, action: actionID))
                    } else {
                        guard let text = inputDraft.textByActionID[actionID] else { return nil }
                        records.append(.responseText(input: input.id, action: actionID, text: text))
                    }
                case .text:
                    guard let text = inputDraft.text else { return nil }
                    records.append(.text(input: input.id, text: text))
                case .point:
                    guard !inputDraft.hasInvalidCoordinateEntry,
                          let point = inputDraft.effectivePoint else { return nil }
                    records.append(.point(input: input.id, point: point))
                }
            }
            return records
        case let .compatibility(form):
            guard let actionID = explicitCompatibilityAction ?? draft.compatibility.selectedActionID,
                  let action = form.action(withID: actionID) else { return nil }
            if action.kind == .value { return [.compatibilityValue(action: actionID)] }
            guard let text = draft.compatibility.textByActionID[actionID] else { return nil }
            return [.compatibilityText(action: actionID, text: text)]
        case .unsupported:
            return nil
        }
    }
}
