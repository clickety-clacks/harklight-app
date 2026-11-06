import Observation
import Foundation
import AttentionDomain
import HarklightNativeRelay

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

struct NativeServerRetractionFixture: Decodable {
    let fixture_version: Int
    let fixture_id: String
    let server_commit: String
    let producer_commit: String
    let host: String
    let person_id: String
    let reader_device_id: String
    let sender_id: String
    let message_id: String
    let native_retraction: Retraction
}

extension NativeServerRetractionFixture {
    struct Retraction: Decodable {
        let retracted_at_ms: UInt64
        let relay_high_water: UInt64
        let conversation_high_water: UInt64
        let delivery_event_json: String
        let lifecycle_event_json: String
        let conversation_event_json: [String]
        let retraction_event_id: String
        let retraction_conversation_seq: UInt64
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
    private(set) var serverRetractionTestStatus: String?
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
         resetFixtureAtLaunch: Bool = false,
         serverRetractionFixture: NativeServerRetractionFixture? = nil,
         seedServerRetractionFixture: Bool = false,
         expireServerRetractionAtLaunch: Bool = false) {
        self.fixtures = fixtures
        self.captureLimitBytes = max(0, captureLimitBytes)
        self.selectedRequestKey = fixtures.requests.first?.key

        let identity = ProfileIdentity(
            trustedRelayAuthority: ExactText(serverRetractionFixture?.host ?? "fixture-only:attention-client-m2"),
            personID: serverRetractionFixture.map { ExactText($0.person_id) } ?? fixtures.accountScope,
            deviceID: ExactText(serverRetractionFixture?.reader_device_id ?? "fictional-sample-device"))
        let profile = ProfileContext(
            identity: identity,
            transportMode: serverRetractionFixture == nil ? .fixture : .relay)
        self.profileContext = profile

        var createdStore: AttentionDomainStore?
        var createdPort: AttentionDomainPort?
        var createdPresentation: LivePresentationStore?
        var initialSnapshot: AttentionStoreSnapshot?
        var initializationError: String?
        var serverRetractionTestStatus: String?
        do {
            let store = try AttentionDomainStore(context: profile,
                                                 persistence: persistence ?? MemoryAttentionStatePersistence(),
                                                 maximumWireFrameBytes: max(0, captureLimitBytes))
            let requests = fixtures.requests.map { StoredRequest(key: $0.key, originalPayload: $0.originalPayload) }
            if serverRetractionFixture == nil {
                if resetFixtureAtLaunch {
                    try store.resetFixtureState(requests, context: profile)
                } else {
                    try store.registerFixtureRequests(requests, context: profile)
                }
            }
#if DEBUG
            if seedServerRetractionFixture {
                guard resetFixtureAtLaunch, let serverRetractionFixture else {
                    throw ConversationError.missingRequest
                }
                try Self.seedServerRetractionFixture(serverRetractionFixture, in: store, context: profile)
            }
            if resetFixtureAtLaunch,
               ProcessInfo.processInfo.arguments.contains("--harklight-test-retraction-expiry-relaunch") {
                try Self.seedRetractionExpiryRelaunchFixture(in: store, fixtures: fixtures, context: profile)
            }
#endif
            createdStore = store
            createdPort = AttentionDomainPort(store: store)
            if serverRetractionFixture == nil {
                createdPresentation = try LivePresentationStore(
                    localFixtureStore: store,
                    context: profile)
            } else {
                createdPresentation = try LivePresentationStore(
                    disconnectedStore: store,
                    context: profile)
            }
#if DEBUG
            if let serverRetractionFixture,
               let presentation = createdPresentation {
                let key = RequestKey(accountScope: profile.identity.personID,
                                     senderID: ExactText(serverRetractionFixture.sender_id),
                                     messageID: ExactText(serverRetractionFixture.message_id))
                guard let retractionDate = presentation.retractionDate(key) else {
                    throw ConversationError.missingRequest
                }
                if expireServerRetractionAtLaunch {
                    presentation.refreshRetractionVisibility(
                        at: retractionDate.addingTimeInterval(86_401))
                }
                let phase = expireServerRetractionAtLaunch ? "after_process_relaunch" : "first_process"
                serverRetractionTestStatus = try Self.recordServerRetractionReadback(
                    serverRetractionFixture, requestKey: key, in: store,
                    presentation: presentation, context: profile, phase: phase)
            }
#endif
            initialSnapshot = try store.snapshot(context: profile)
        } catch {
            initializationError = error.localizedDescription
        }
        self.domainStore = createdStore
        self.port = createdPort
        self.presentationStore = createdPresentation
        self.snapshot = initialSnapshot
        self.serverRetractionTestStatus = serverRetractionTestStatus
        self.loadError = loadError ?? initializationError.map { "Local durable state could not be opened: \($0)" }
    }

#if DEBUG
    private static func seedServerRetractionFixture(_ fixture: NativeServerRetractionFixture,
                                                    in store: AttentionDomainStore,
                                                    context: ProfileContext) throws {
        let retraction = fixture.native_retraction
        let relayWire = try RelayWire(profile: context)
        let delivery = try relayWire.decodeEvent(Data(retraction.delivery_event_json.utf8))
        guard case let .delivery(request, _) = delivery.body,
              request.key.senderID.rawValue == fixture.sender_id,
              request.key.messageID.rawValue == fixture.message_id else {
            throw ConversationError.missingRequest
        }
        try store.apply(delivery, context: context)

        let port = AttentionDomainPort(store: store)
        guard let selector = try port.inspect(context: port.context, request: request.key)
                .requests.first?.selector,
              var answerDraft = try store.snapshot(context: context).drafts[request.key] else {
            throw ConversationError.missingRequest
        }
        answerDraft.compatibility.selectedActionID = ExactText("keep")
        try store.saveDraft(answerDraft, selector: selector, context: context)
        let conversationWire = try ConversationWire(profile: context)
        let conversationEvents = try retraction.conversation_event_json.map {
            try conversationWire.decodeEvent(Data($0.utf8))
        }
        guard conversationEvents.count >= 3 else { throw ConversationError.missingRequest }
        for event in conversationEvents.dropLast() {
            try store.applyConversation(event, context: context)
        }

        let lifecycle = try relayWire.decodeEvent(Data(retraction.lifecycle_event_json.utf8))
        guard lifecycle.conversation?.retractedAtMilliseconds == retraction.retracted_at_ms else {
            throw ConversationError.missingRequest
        }
        try store.apply(lifecycle, context: context)
        if let retractionEvent = conversationEvents.last {
            try store.applyConversation(retractionEvent, context: context)
        }

        let snapshot = try store.snapshot(context: context)
        let conversation = try store.conversationSnapshot(context: context)
        guard let thread = conversation.threads[request.key],
              snapshot.requests.contains(where: { $0.key == request.key }),
              snapshot.drafts[request.key]?.compatibility.selectedActionID == ExactText("keep"),
              thread.turns.count >= 2,
              thread.turns.contains(where: { $0.text.rawValue == "What should I check first?" }),
              thread.turns.contains(where: { $0.text.rawValue == "Check the exact bytes." }),
              thread.retraction?.retractedAtMilliseconds == retraction.retracted_at_ms,
              thread.terminal == .cleared else {
            throw ConversationError.missingRequest
        }
    }


    private static func recordServerRetractionReadback(
        _ fixture: NativeServerRetractionFixture,
        requestKey: RequestKey,
        in store: AttentionDomainStore,
        presentation: LivePresentationStore,
        context: ProfileContext,
        phase: String
    ) throws -> String {
        let snapshot = try store.snapshot(context: context)
        let conversation = try store.conversationSnapshot(context: context)
        guard let thread = conversation.threads[requestKey],
              snapshot.requests.contains(where: { $0.key == requestKey }),
              snapshot.drafts[requestKey]?.compatibility.selectedActionID == ExactText("keep"),
              thread.turns.count >= 2,
              thread.turns.contains(where: { $0.text.rawValue == "What should I check first?" }),
              thread.turns.contains(where: { $0.text.rawValue == "Check the exact bytes." }),
              thread.retraction?.retractedAtMilliseconds == fixture.native_retraction.retracted_at_ms,
              thread.terminal == .cleared,
              let retractionDate = presentation.retractionDate(requestKey),
              let expiryDate = LivePresentationStore.retractionExpiryDate(for: retractionDate) else {
            throw ConversationError.missingRequest
        }

        let readback: [String: Any] = [
            "fixture_id": fixture.fixture_id,
            "server_commit": fixture.server_commit,
            "producer_commit": fixture.producer_commit,
            "phase": phase,
            "retracted_at_ms": fixture.native_retraction.retracted_at_ms,
            "expiry_at_ms": UInt64(expiryDate.timeIntervalSince1970 * 1_000),
            "visibility_time_ms": UInt64(presentation.retractionVisibilityTime.timeIntervalSince1970 * 1_000),
            "expired_in_presentation": LivePresentationStore.isRetractionExpired(
                retractionDate: retractionDate, at: presentation.retractionVisibilityTime),
            "request_retained": true,
            "answer_draft_action_id": "keep",
            "conversation_turn_count": thread.turns.count,
            "conversation_turn_texts": thread.turns.map { $0.text.rawValue },
            "conversation_retraction_retained": true,
            "conversation_terminal": "cleared"
        ]
        let data = try JSONSerialization.data(withJSONObject: readback, options: [.sortedKeys])
        let directory = try FileAttentionStatePersistence.applicationSupport().directoryURL
        try FileManager.default.createDirectory(at: directory,
                                               withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("native-server-retraction-readback.json"),
                       options: .atomic)
        return "Server retraction persisted: \(phase)"
    }

    private static func seedRetractionExpiryRelaunchFixture(in store: AttentionDomainStore,
                                                           fixtures: FixtureSet,
                                                           context: ProfileContext) throws {
        guard let request = fixtures.requests.first(where: {
            $0.key.messageID.rawValue == "facilities-01"
        }) else {
            throw ConversationError.missingRequest
        }

        let binding = ConversationBinding(request: request.key, revision: 1)
        let sessionHandle = ExactText("retraction-expiry-relaunch-fixture")
        let terminalTurn = ExactText("retraction-expiry-relaunch-terminal")
        let firstSequence = try store.conversationSnapshot(context: context).cursor + 1
        let terminalSequence = firstSequence + 1
        let retractionSequence = terminalSequence + 1
        let retractedAtMilliseconds = UInt64(
            Date().addingTimeInterval(-86_400 + 180).timeIntervalSince1970 * 1_000)

        try store.applyConversation(ConversationEvent(sequence: firstSequence, binding: binding,
            fact: .request(sessionHandle: sessionHandle, payload: request.originalPayload)), context: context)
        try store.applyConversation(ConversationEvent(sequence: terminalSequence, binding: binding,
            fact: .terminal(turn: terminalTurn, author: .origin, state: .cleared)), context: context)
        try store.applyConversation(ConversationEvent(sequence: retractionSequence, binding: binding,
            fact: .retraction(turn: terminalTurn, terminalSequence: terminalSequence),
            retractedAtMilliseconds: retractedAtMilliseconds), context: context)
    }
#endif

    static func loadFromBundle(_ bundle: Bundle = .main) -> PrototypeStore {
        do {
            let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
            let usesServerRetractionFixture = arguments.contains("--harklight-test-server-retraction") ||
                arguments.contains("--harklight-test-retraction-expiry-after-deadline")
            if usesServerRetractionFixture {
                guard let fixtureURL = bundle.url(forResource: "native-server-retraction",
                                                  withExtension: "json") else {
                    throw ConversationError.missingRequest
                }
                let fixture = try JSONDecoder().decode(
                    NativeServerRetractionFixture.self, from: Data(contentsOf: fixtureURL))
                guard fixture.fixture_version == 1,
                      fixture.server_commit == "f7a002600f8e03fbfe8c766266ac6a7f2ab2b500",
                      fixture.native_retraction.retracted_at_ms > 0 else {
                    throw ConversationError.missingRequest
                }
                let emptyFixtures = FixtureSet(
                    accountScope: ExactText(fixture.person_id), requests: [],
                    legacyValueConformanceVectors: [], legacyTextConformanceVectors: [],
                    validSubmissions: [], invalidSubmissions: [], pointVectors: [],
                    terminalContexts: [], additionalCases: [])
                return PrototypeStore(
                    fixtures: emptyFixtures,
                    persistence: try FileAttentionStatePersistence.applicationSupport(),
                    resetFixtureAtLaunch: arguments.contains("--reset-attention-fixture"),
                    serverRetractionFixture: fixture,
                    seedServerRetractionFixture: arguments.contains("--harklight-test-server-retraction") &&
                        arguments.contains("--reset-attention-fixture"),
                    expireServerRetractionAtLaunch: arguments.contains(
                        "--harklight-test-retraction-expiry-after-deadline"))
            }
#endif
            return PrototypeStore(fixtures: try FixtureSet.loadBundled(from: bundle),
                                  persistence: try FileAttentionStatePersistence.applicationSupport(),
                                  resetFixtureAtLaunch: arguments.contains("--reset-attention-fixture"))
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
        guard let session = sessions[key], case .open = session.lifecycle else { return false }
        if session.draft.noCommentSelected {
            return canSendNoCommentLocally(for: key)
        }
        guard let port, let records = typedRecords(for: key, draft: session.draft),
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
    func sendNoCommentLocally(for key: RequestKey, selectionIsLocal: Bool = false) -> Bool {
        guard canSendNoCommentLocally(for: key), let port,
              let selector = try? boundSelector(for: key) else { return false }
        if !selectionIsLocal {
            guard presentationStore?.flushPendingDraft(for: key) ?? true else { return false }
        }
        refreshSnapshot()
        do {
            _ = try port.submitNoComment(context: port.context,
                                         selector: selector,
                                         intentID: UUID(),
                                         discardDraft: selectionIsLocal)
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
                            answerDraft: RequestDraft? = nil,
                            explicitCompatibilityAction: ExactText? = nil) -> Bool {
        if answerDraft == nil {
            guard presentationStore?.flushPendingDraft(for: key) ?? true else { return false }
        }
        refreshSnapshot()
        guard let session = sessions[key], case .open = session.lifecycle else { return false }
        let draft = answerDraft ?? session.draft
        if draft.noCommentSelected {
            return sendNoCommentLocally(for: key, selectionIsLocal: answerDraft != nil)
        }
        guard let port, let records = typedRecords(for: key, draft: draft,
                                                   explicitCompatibilityAction: explicitCompatibilityAction),
              let selector = try? boundSelector(for: key) else { return false }
        do {
            let intent = SubmitIntent(context: port.context,
                                      selector: selector,
                                      intentID: UUID(),
                                      inputs: records,
                                      persistAnswerDraft: answerDraft == nil)
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
