import Foundation

public struct AccountScope: Equatable, Hashable, Codable, Sendable {
    public let relayAuthority: ExactText
    public let personID: ExactText

    public init(relayAuthority: ExactText, personID: ExactText) {
        self.relayAuthority = relayAuthority
        self.personID = personID
    }
}

/// Issued by the native account/profile owner. H treats this as opaque trusted context.
public struct PortContext: Equatable, Codable, Sendable {
    public let trustedAccount: AccountScope
    public let deviceProfileID: ExactText
    public let deviceGeneration: ExactText

    public init(trustedAccount: AccountScope, deviceProfileID: ExactText, deviceGeneration: ExactText) {
        self.trustedAccount = trustedAccount
        self.deviceProfileID = deviceProfileID
        self.deviceGeneration = deviceGeneration
    }
}

public struct BoundDocumentSelector: Equatable, Codable, Sendable {
    public let request: RequestKey
    public let opaqueDocumentID: ExactText
    public let opaqueSubmissionID: ExactText

    public init(request: RequestKey, opaqueDocumentID: ExactText, opaqueSubmissionID: ExactText) {
        self.request = request
        self.opaqueDocumentID = opaqueDocumentID
        self.opaqueSubmissionID = opaqueSubmissionID
    }
}

/// Typed edits only. The sender's literal values and the final answer remain in C's descriptor.
public enum TypedInputRecord: Equatable, Codable, Sendable {
    case responseValue(input: ExactText, action: ExactText)
    case responseText(input: ExactText, action: ExactText, text: ExactText)
    case text(input: ExactText, text: ExactText)
    case point(input: ExactText, point: PointValue)
    case compatibilityValue(action: ExactText)
    case compatibilityText(action: ExactText, text: ExactText)
}

public struct SubmitIntent: Equatable, Sendable {
    public let context: PortContext
    public let selector: BoundDocumentSelector
    public let intentID: UUID
    public let inputs: [TypedInputRecord]

    public init(context: PortContext,
                selector: BoundDocumentSelector,
                intentID: UUID,
                inputs: [TypedInputRecord]) {
        self.context = context
        self.selector = selector
        self.intentID = intentID
        self.inputs = inputs
    }
}

public enum LocalIntentState: Equatable, Sendable {
    case durable
    case queuedForRelay
    case accepted(sequence: UInt64?)
    case terminalUnconfirmed
    case repairRequired
}

public enum RelayOutcome: Equatable, Sendable {
    case unknown
    case accepted(sequence: UInt64?)
    case terminal(state: TerminalState, authorizedAnswer: JSONValue?, sequence: UInt64?)
}

public struct IntentReceipt: Equatable, Sendable {
    public let context: PortContext
    public let selector: BoundDocumentSelector
    public let intentID: UUID
    public let opID: UUID
    public let inputs: [TypedInputRecord]
    public let exactAnswer: JSONValue
    public let localState: LocalIntentState
    public let relayOutcome: RelayOutcome?

    /// Serialize this exact UTF-8 JSON string across the host boundary; do not bridge it as JS numbers.
    public var exactAnswerJSON: String { exactAnswer.jsonString }

    public init(context: PortContext,
                selector: BoundDocumentSelector,
                intentID: UUID,
                opID: UUID,
                inputs: [TypedInputRecord],
                exactAnswer: JSONValue,
                localState: LocalIntentState,
                relayOutcome: RelayOutcome?) {
        self.context = context
        self.selector = selector
        self.intentID = intentID
        self.opID = opID
        self.inputs = inputs
        self.exactAnswer = exactAnswer
        self.localState = localState
        self.relayOutcome = relayOutcome
    }
}

public enum ApplyEventResult: Equatable, Sendable {
    case committed(contiguousCursor: UInt64, publishable: PresentationSnapshot?)
    case compatibleRepeat(contiguousCursor: UInt64, classificationChanged: Bool)
    case gap(expected: UInt64)
    case conflict
    case repairRequired
}

public enum AppLifecycleStatus: String, Equatable, Codable, Sendable {
    case open
    case pending
    case answered
    case cleared
    case expired
    case superseded
}

public struct ReceiptPresentationFacts: Equatable, Sendable {
    public let evidenceLabel: String
    public let ownOutcome: OwnOutcome
    public let originalOperationUncertainty: Bool

    public init(evidenceLabel: String, ownOutcome: OwnOutcome, originalOperationUncertainty: Bool) {
        self.evidenceLabel = evidenceLabel
        self.ownOutcome = ownOutcome
        self.originalOperationUncertainty = originalOperationUncertainty
    }
}

public enum ProjectedActionKind: Equatable, Sendable {
    case value
    case text
}

public struct ProjectedAction: Equatable, Sendable {
    public let id: ExactText
    public let label: ExactText
    public let kind: ProjectedActionKind
    public let illustrationID: ExactText?

    public init(id: ExactText,
                label: ExactText,
                kind: ProjectedActionKind,
                illustrationID: ExactText? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.illustrationID = illustrationID
    }
}

/// A C-admitted scene. Result-point paths are replaced with authorized integer coordinates.
public enum ProjectedSceneKind: Equatable, Sendable {
    case stack(SceneAxis, [ProjectedSceneNode])
    case grid(columns: Int, [ProjectedSceneNode])
    case text(ExactText, SceneTextStyle)
    case illustration(ExactText)
    case input(ExactText, InputLayout)
    case resultPoint(illustrationID: ExactText, label: ExactText, point: PointValue)
}

public struct ProjectedSceneNode: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ProjectedSceneKind

    public init(id: String, kind: ProjectedSceneKind) {
        self.id = id
        self.kind = kind
    }
}

public enum ProjectedInputKind: Equatable, Sendable {
    case response([ProjectedAction])
    case text
    case point(illustrationID: ExactText)
}

public struct ProjectedInput: Equatable, Sendable {
    public let id: ExactText
    public let label: ExactText
    public let kind: ProjectedInputKind

    public init(id: ExactText, label: ExactText, kind: ProjectedInputKind) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

public struct AdmittedSenderProjection: Equatable, Sendable {
    public let scene: ProjectedSceneNode
    public let inputs: [ProjectedInput]
    public let illustrations: [SenderIllustration]
    public let submissionLabel: ExactText

    public init(scene: ProjectedSceneNode,
                inputs: [ProjectedInput],
                illustrations: [SenderIllustration],
                submissionLabel: ExactText) {
        self.scene = scene
        self.inputs = inputs
        self.illustrations = illustrations
        self.submissionLabel = submissionLabel
    }
}

public enum AdmittedRequestProjection: Equatable, Sendable {
    case sender(AdmittedSenderProjection)
    case compatibility([ProjectedAction])
    case unsupported(UnsupportedInterfaceReason)
}

public struct PresentedRequest: Equatable, Sendable {
    public let key: RequestKey
    /// Durable order assigned by C at first acceptance; consumers preserve this order.
    public let acceptanceOrder: UInt64
    public let title: ExactText?
    public let body: ExactText?
    /// A UTF-8 JSON string for inert inspection. H must not parse it to render answers.
    public let originalContentJSON: String
    public let selector: BoundDocumentSelector?
    public let draft: RequestDraft
    public let lifecycleStatus: AppLifecycleStatus
    public let receiptFacts: ReceiptPresentationFacts?
    public let intentReceipt: IntentReceipt?
    public let projection: AdmittedRequestProjection

    public init(key: RequestKey,
                acceptanceOrder: UInt64,
                title: ExactText?,
                body: ExactText?,
                originalContentJSON: String,
                selector: BoundDocumentSelector?,
                draft: RequestDraft,
                lifecycleStatus: AppLifecycleStatus,
                receiptFacts: ReceiptPresentationFacts?,
                intentReceipt: IntentReceipt?,
                projection: AdmittedRequestProjection) {
        self.key = key
        self.acceptanceOrder = acceptanceOrder
        self.title = title
        self.body = body
        self.originalContentJSON = originalContentJSON
        self.selector = selector
        self.draft = draft
        self.lifecycleStatus = lifecycleStatus
        self.receiptFacts = receiptFacts
        self.intentReceipt = intentReceipt
        self.projection = projection
    }
}

public struct PresentationSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let cursor: UInt64
    public let replayBarrier: UInt64?
    public let repairIssues: [StoreRepairIssue]
    public let requests: [PresentedRequest]

    public init(revision: UInt64,
                cursor: UInt64,
                replayBarrier: UInt64?,
                repairIssues: [StoreRepairIssue],
                requests: [PresentedRequest]) {
        self.revision = revision
        self.cursor = cursor
        self.replayBarrier = replayBarrier
        self.repairIssues = repairIssues
        self.requests = requests
    }
}

/// Shared synchronous semantic port. The store and this object are created by the native trusted owner.
public final class AttentionDomainPort: @unchecked Sendable {
    public let context: PortContext
    private let profileContext: ProfileContext
    private let store: AttentionDomainStore

    public init(store: AttentionDomainStore) {
        self.store = store
        self.profileContext = store.profileContext
        self.context = PortContext(
            trustedAccount: AccountScope(relayAuthority: store.profileContext.identity.trustedRelayAuthority,
                                         personID: store.profileContext.identity.personID),
            deviceProfileID: store.profileContext.identity.deviceID,
            deviceGeneration: ExactText(store.profileContext.generation.uuidString.lowercased())
        )
    }

    public func conversations(context suppliedContext: PortContext) throws -> ConversationSnapshot {
        try validate(suppliedContext)
        return try store.conversationSnapshot(context: profileContext)
    }

    public func saveConversationDraft(_ draft: ConversationDraft, context suppliedContext: PortContext) throws {
        try validate(suppliedContext)
        try store.saveConversationDraft(draft, context: profileContext)
    }

    public func prepareDiscussion(_ binding: ConversationBinding, context suppliedContext: PortContext) throws -> UUID {
        try validate(suppliedContext)
        return try store.prepareDiscussion(binding, context: profileContext)
    }

    public func observe(context suppliedContext: PortContext) throws -> PresentationSnapshot {
        try validate(suppliedContext)
        return try presentation(from: store.snapshot(context: profileContext), selectorFor: nil)
    }

    public func inspect(context suppliedContext: PortContext, request key: RequestKey) throws -> PresentationSnapshot {
        try validate(suppliedContext)
        let selector = try store.selector(for: key, context: profileContext)
        return try presentation(from: store.snapshot(context: profileContext), selectorFor: [key: selector])
            .filtering(to: key)
    }

    public func saveDraft(context suppliedContext: PortContext,
                          selector: BoundDocumentSelector,
                          completeDraft: RequestDraft) throws {
        try validate(suppliedContext)
        try store.saveDraft(completeDraft, selector: selector, context: profileContext)
    }

    public func cancelDraft(context suppliedContext: PortContext, selector: BoundDocumentSelector) throws {
        try validate(suppliedContext)
        let snapshot = try store.snapshot(context: profileContext)
        guard let request = snapshot.requests[selector.request] else { throw AttentionStoreError.requestMissing }
        try store.saveDraft(RequestDraft(interface: request.interface), selector: selector, context: profileContext)
    }

    public func preview(context suppliedContext: PortContext,
                        selector: BoundDocumentSelector,
                        inputs: [TypedInputRecord]) throws -> JSONValue {
        try validate(suppliedContext)
        let snapshot = try store.snapshot(context: profileContext)
        guard let request = snapshot.requests[selector.request] else { throw AttentionStoreError.requestMissing }
        let (typedSubmission, draft) = try makeSubmission(inputs, for: request.interface)
        return try store.previewSubmission(typedSubmission,
                                           draft: draft,
                                           selector: selector,
                                           context: profileContext)
    }

    public func submit(_ intent: SubmitIntent) throws -> IntentReceipt {
        try validate(intent.context)
        let snapshot = try store.snapshot(context: profileContext)
        guard let request = snapshot.requests[intent.selector.request] else { throw AttentionStoreError.requestMissing }
        let (typedSubmission, draft) = try makeSubmission(intent.inputs, for: request.interface)
        let stored = try store.submit(intentID: intent.intentID,
                                      typedSubmission: typedSubmission,
                                      typedInputs: intent.inputs,
                                      draft: draft,
                                      selector: intent.selector,
                                      context: profileContext)
        return receipt(stored, context: context)
    }

    public func lookupIntent(context suppliedContext: PortContext, intentID: UUID) throws -> IntentReceipt? {
        try validate(suppliedContext)
        guard let stored = try store.lookupIntent(intentID, context: profileContext) else { return nil }
        return receipt(stored, context: context)
    }

    /// Returns the original receipt if it committed first. A nil result means
    /// the missing intent ID was durably fenced against any late submit.
    public func fenceUncommittedIntent(context suppliedContext: PortContext,
                                      requestKey: RequestKey,
                                      intentID: UUID) throws -> IntentReceipt? {
        try validate(suppliedContext)
        guard let stored = try store.fenceUncommittedIntent(intentID,
                                                            requestKey: requestKey,
                                                            context: profileContext) else { return nil }
        return receipt(stored, context: context)
    }

    public func retryIntent(context suppliedContext: PortContext, intentID: UUID) throws -> IntentReceipt? {
        try validate(suppliedContext)
        guard let stored = try store.retryOperation(intentID, context: profileContext) else { return nil }
        return receipt(stored, context: context)
    }

    /// Emits the newest committed snapshot first, then every later durable revision.
    public func snapshots(context suppliedContext: PortContext,
                          afterRevision: UInt64 = 0) throws -> AsyncThrowingStream<PresentationSnapshot, Error> {
        try validate(suppliedContext)
        let revisions = try store.revisions(context: profileContext, after: afterRevision)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lastRevision = afterRevision
                    var hasEmitted = false
                    for await revision in revisions {
                        try Task.checkCancellation()
                        let snapshot = try self.observe(context: suppliedContext)
                        guard !hasEmitted || snapshot.revision > lastRevision else { continue }
                        hasEmitted = true
                        lastRevision = snapshot.revision
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func validate(_ suppliedContext: PortContext) throws {
        guard suppliedContext == context else { throw AttentionStoreError.staleProfile }
    }

    private func receipt(_ stored: Submission, context: PortContext) -> IntentReceipt {
        let selector = BoundDocumentSelector(request: stored.requestKey,
                                             opaqueDocumentID: stored.opaqueDocumentID,
                                             opaqueSubmissionID: stored.opaqueSubmissionID)
        let localState: LocalIntentState
        let relayOutcome: RelayOutcome?
        switch stored.disposition {
        case .pending:
            localState = contextTransport == .relay ? .queuedForRelay : .durable
            relayOutcome = contextTransport == .relay ? .unknown : nil
        case let .accepted(sequence):
            localState = .accepted(sequence: sequence)
            relayOutcome = .accepted(sequence: sequence)
        case .lost:
            localState = .terminalUnconfirmed
            relayOutcome = .unknown
        case let .terminal(state, sequence, authorizedAnswer):
            localState = .terminalUnconfirmed
            relayOutcome = .terminal(state: state, authorizedAnswer: authorizedAnswer, sequence: sequence)
        case .repairRequired:
            localState = .repairRequired
            relayOutcome = .unknown
        }
        return IntentReceipt(context: context,
                             selector: selector,
                             intentID: stored.intentID,
                             opID: stored.operationID,
                             inputs: stored.typedInputs,
                             exactAnswer: stored.answer,
                             localState: localState,
                             relayOutcome: relayOutcome)
    }

    private var contextTransport: AttentionTransportMode { profileContext.transportMode }

    private func makeSubmission(_ records: [TypedInputRecord],
                                for interface: RequestInterface) throws -> (TypedSubmission, RequestDraft) {
        switch interface {
        case let .sender(document):
            var submissions: [InputSubmission] = []
            var draft = RequestDraft(interface: interface)
            for record in records {
                switch record {
                case let .responseValue(input, action):
                    submissions.append(InputSubmission(inputID: input, actionID: action))
                    draft.inputs[input]?.selectedActionID = action
                case let .responseText(input, action, text):
                    submissions.append(InputSubmission(inputID: input, actionID: action, text: text))
                    draft.inputs[input]?.selectedActionID = action
                    draft.inputs[input]?.textByActionID[action] = text
                case let .text(input, text):
                    submissions.append(InputSubmission(inputID: input, text: text))
                    draft.inputs[input]?.text = text
                case let .point(input, point):
                    submissions.append(InputSubmission(inputID: input, point: point))
                    draft.inputs[input]?.point = point
                    draft.inputs[input]?.horizontalText = ExactText(String(point.x))
                    draft.inputs[input]?.verticalText = ExactText(String(point.y))
                case .compatibilityValue, .compatibilityText:
                    throw AttentionStoreError.invalidSubmission
                }
            }
            guard records.count == document.inputs.count else { throw AttentionStoreError.invalidSubmission }
            return (.senderInputs(submissions), draft)
        case .compatibility(_):
            guard records.count == 1 else { throw AttentionStoreError.invalidSubmission }
            var draft = RequestDraft(interface: interface)
            switch records[0] {
            case let .compatibilityValue(action):
                draft.compatibility.selectedActionID = action
                return (.compatibility(actionID: action, text: nil), draft)
            case let .compatibilityText(action, text):
                draft.compatibility.selectedActionID = action
                draft.compatibility.textByActionID[action] = text
                return (.compatibility(actionID: action, text: text), draft)
            default:
                throw AttentionStoreError.invalidSubmission
            }
        case .unsupported:
            throw AttentionStoreError.unsupportedInterface
        }
    }

    private func presentation(from snapshot: AttentionStoreSnapshot,
                              selectorFor selectors: [RequestKey: BoundDocumentSelector]?) throws -> PresentationSnapshot {
        let orderedRequests = try snapshot.requests.values.map { request -> (order: UInt64, request: StoredRequest) in
            guard let order = request.acceptanceOrder else {
                throw AttentionStoreError.missingAcceptanceOrder
            }
            return (order, request)
        }.sorted { left, right in
            if left.order != right.order { return left.order < right.order }
            if left.request.key.senderID.rawValue != right.request.key.senderID.rawValue {
                return left.request.key.senderID.rawValue < right.request.key.senderID.rawValue
            }
            return left.request.key.messageID.rawValue < right.request.key.messageID.rawValue
        }
        guard Set(orderedRequests.map(\.order)).count == orderedRequests.count else {
            throw AttentionStoreError.duplicateAcceptanceOrder
        }
        let requests = try orderedRequests.map { item in
            try present(item.request,
                        acceptanceOrder: item.order,
                        draft: snapshot.drafts[item.request.key] ?? RequestDraft(interface: item.request.interface),
                        session: snapshot.fixtureSessions[item.request.key],
                        remote: snapshot.remoteStates[item.request.key],
                        submission: snapshot.intents.values.first(where: { $0.requestKey == item.request.key }),
                        selector: selectors?[item.request.key])
        }
        return PresentationSnapshot(revision: snapshot.revision,
                                    cursor: snapshot.cursor,
                                    replayBarrier: snapshot.replayBarrier,
                                    repairIssues: snapshot.repairIssues,
                                    requests: requests)
    }

    private func present(_ request: StoredRequest,
                         acceptanceOrder: UInt64,
                         draft: RequestDraft,
                         session: RequestSession?,
                         remote: RemoteRequestState?,
                         submission: Submission?,
                         selector: BoundDocumentSelector?) throws -> PresentedRequest {
        let status: AppLifecycleStatus
        let receiptFacts: ReceiptPresentationFacts?
        switch session?.lifecycle {
        case .some(.open):
            status = .open
            receiptFacts = nil
        case .some(.pending(_)):
            status = .pending
            receiptFacts = ReceiptPresentationFacts(evidenceLabel: "Local fixture intent is durable; relay delivery is not claimed.",
                                                    ownOutcome: .unconfirmed,
                                                    originalOperationUncertainty: true)
        case let .some(.terminal(terminal, _)):
            status = AppLifecycleStatus(rawValue: terminal.state.rawValue) ?? .open
            receiptFacts = ReceiptPresentationFacts(evidenceLabel: terminal.evidenceLabel,
                                                    ownOutcome: terminal.ownOutcome,
                                                    originalOperationUncertainty: terminal.ownOutcome == .unconfirmed)
        case .none:
            if let terminal = remote?.state {
                status = AppLifecycleStatus(rawValue: terminal.rawValue) ?? .open
                let hasAcceptedIntent = submission.map { value in
                    if case .accepted = value.disposition { return true }
                    return false
                } ?? false
                receiptFacts = ReceiptPresentationFacts(evidenceLabel: "Relay lifecycle evidence is recorded; original operation outcome is shown separately.",
                                                        ownOutcome: hasAcceptedIntent ? .accepted : .unconfirmed,
                                                        originalOperationUncertainty: !hasAcceptedIntent)
            } else if let submission {
                status = .pending
                if case .accepted = submission.disposition {
                    receiptFacts = ReceiptPresentationFacts(evidenceLabel: "The relay accepted your original answer; the request outcome is still pending.",
                                                            ownOutcome: .accepted,
                                                            originalOperationUncertainty: false)
                } else {
                    receiptFacts = ReceiptPresentationFacts(evidenceLabel: "Your answer is saved on this device. Relay acceptance is not yet confirmed.",
                                                            ownOutcome: .unconfirmed,
                                                            originalOperationUncertainty: true)
                }
            } else {
                status = .open
                receiptFacts = nil
            }
        }

        let projection: AdmittedRequestProjection
        switch request.interface {
        case let .sender(document):
            let scene: SceneNode
            let terminalState: TerminalState?
            let authorizedAnswer: JSONValue?
            if let terminal = session?.lifecycle.terminalValue {
                terminalState = terminal.state
                authorizedAnswer = terminal.authorizedAnswer
                scene = document.terminalScene(state: terminal.state, authorizedAnswer: terminal.authorizedAnswer)
            } else if let remoteState = remote?.state {
                if let originAnswer = remote?.authorizedOriginAnswer {
                    authorizedAnswer = originAnswer
                } else if let submission, case .accepted = submission.disposition {
                    authorizedAnswer = submission.answer
                } else {
                    authorizedAnswer = nil
                }
                terminalState = remoteState
                scene = document.terminalScene(state: remoteState, authorizedAnswer: authorizedAnswer)
            } else {
                terminalState = nil
                authorizedAnswer = nil
                scene = document.open
            }
            let admittedScene: ProjectedSceneNode
            if let projected = projectScene(from: scene, document: document, authorizedAnswer: authorizedAnswer) {
                admittedScene = projected
            } else if let terminalState,
                      let neutral = projectScene(from: document.terminalScene(state: terminalState,
                                                                              authorizedAnswer: nil),
                                                  document: document,
                                                  authorizedAnswer: nil) {
                admittedScene = neutral
            } else {
                throw AttentionStoreError.invalidProjection
            }
            let inputs = document.inputs.map { input in
                let kind: ProjectedInputKind
                switch input.kind {
                case let .response(actions):
                    kind = .response(actions.map { action in
                        ProjectedAction(id: action.id,
                                        label: action.label,
                                        kind: action.kind.isValue ? .value : .text,
                                        illustrationID: action.illustrationID)
                    })
                case .text:
                    kind = .text
                case let .point(illustrationID):
                    kind = .point(illustrationID: illustrationID)
                }
                return ProjectedInput(id: input.id, label: input.label, kind: kind)
            }
            projection = .sender(AdmittedSenderProjection(scene: admittedScene,
                                                          inputs: inputs,
                                                          illustrations: document.illustrations,
                                                          submissionLabel: document.submissionLabel))
        case let .compatibility(form):
            projection = .compatibility(form.actions.map { action in
                ProjectedAction(id: action.id,
                                label: action.label,
                                kind: action.kind == .value ? .value : .text)
            })
        case let .unsupported(reason):
            projection = .unsupported(reason)
        }

        return PresentedRequest(key: request.key,
                                acceptanceOrder: acceptanceOrder,
                                title: request.originalPayload.uniqueValue(named: "title")?.stringValue,
                                body: request.originalPayload.uniqueValue(named: "body")?.stringValue,
                                originalContentJSON: request.originalPayload.canonicalJSON,
                                selector: selector,
                                draft: draft,
                                lifecycleStatus: status,
                                receiptFacts: receiptFacts,
                                intentReceipt: submission.map { receipt($0, context: context) },
                                projection: projection)
    }

    private func projectScene(from node: SceneNode,
                              document: SenderDocument,
                              authorizedAnswer: JSONValue?) -> ProjectedSceneNode? {
        let kind: ProjectedSceneKind
        switch node.kind {
        case let .stack(axis, children):
            let projected = children.compactMap {
                projectScene(from: $0, document: document, authorizedAnswer: authorizedAnswer)
            }
            guard projected.count == children.count else { return nil }
            kind = .stack(axis, projected)
        case let .grid(columns, children):
            let projected = children.compactMap {
                projectScene(from: $0, document: document, authorizedAnswer: authorizedAnswer)
            }
            guard projected.count == children.count else { return nil }
            kind = .grid(columns: columns, projected)
        case let .text(text, style):
            kind = .text(text, style)
        case let .illustration(id):
            kind = .illustration(id)
        case let .input(id, layout):
            kind = .input(id, layout)
        case let .resultPoint(illustrationID, label, _):
            guard let authorizedAnswer,
                  let point = document.resultPoint(in: node, answer: authorizedAnswer) else { return nil }
            kind = .resultPoint(illustrationID: illustrationID, label: label, point: point)
        }
        return ProjectedSceneNode(id: node.id, kind: kind)
    }
}

private extension PresentationSnapshot {
    func filtering(to key: RequestKey) -> PresentationSnapshot {
        PresentationSnapshot(revision: revision,
                             cursor: cursor,
                             replayBarrier: replayBarrier,
                             repairIssues: repairIssues,
                             requests: requests.filter { $0.key == key })
    }
}

private extension FixtureLifecycle {
    var terminalValue: FixtureTerminal? {
        if case let .terminal(terminal, _) = self { return terminal }
        return nil
    }
}

private extension SenderActionKind {
    var isValue: Bool {
        if case .value = self { return true }
        return false
    }
}
