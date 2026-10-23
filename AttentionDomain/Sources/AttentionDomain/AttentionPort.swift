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
    public let requestRevision: UInt64
    public let opaqueDocumentID: ExactText
    public let opaqueSubmissionID: ExactText

    public init(request: RequestKey,
                requestRevision: UInt64 = 1,
                opaqueDocumentID: ExactText,
                opaqueSubmissionID: ExactText) {
        self.request = request
        self.requestRevision = requestRevision
        self.opaqueDocumentID = opaqueDocumentID
        self.opaqueSubmissionID = opaqueSubmissionID
    }

    private enum CodingKeys: String, CodingKey {
        case request, requestRevision, opaqueDocumentID, opaqueSubmissionID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        request = try values.decode(RequestKey.self, forKey: .request)
        requestRevision = try values.decodeIfPresent(UInt64.self, forKey: .requestRevision) ?? 1
        opaqueDocumentID = try values.decode(ExactText.self, forKey: .opaqueDocumentID)
        opaqueSubmissionID = try values.decode(ExactText.self, forKey: .opaqueSubmissionID)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(request, forKey: .request)
        try values.encode(requestRevision, forKey: .requestRevision)
        try values.encode(opaqueDocumentID, forKey: .opaqueDocumentID)
        try values.encode(opaqueSubmissionID, forKey: .opaqueSubmissionID)
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
    case refusedByRetraction(retractedAtMilliseconds: UInt64)
    case terminalUnconfirmed
    case notDelivered
    case unsupported
    case repairRequired
}

public enum RelayOutcome: Equatable, Sendable {
    case unknown
    case accepted(sequence: UInt64?)
    case terminal(state: TerminalState, authorizedAnswer: JSONValue?, sequence: UInt64?)
    case refusedByRetraction(retractedAtMilliseconds: UInt64)
    case unsupported
}

public struct IntentReceipt: Equatable, Sendable {
    public let context: PortContext
    public let selector: BoundDocumentSelector
    public let intentID: UUID
    public let opID: UUID
    public let inputs: [TypedInputRecord]
    public let exactAnswer: JSONValue
    public let answerKind: SubmissionAnswerKind?
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
                answerKind: SubmissionAnswerKind? = nil,
                localState: LocalIntentState,
                relayOutcome: RelayOutcome?) {
        self.context = context
        self.selector = selector
        self.intentID = intentID
        self.opID = opID
        self.inputs = inputs
        self.exactAnswer = exactAnswer
        self.answerKind = answerKind
        self.localState = localState
        self.relayOutcome = relayOutcome
    }
}

public enum ApplyEventResult: Equatable, Sendable {
    case committed(contiguousCursor: UInt64, publishable: PresentationSnapshot?)
    case compatibleRepeat(contiguousCursor: UInt64, classificationChanged: Bool)
    case deferred(contiguousCursor: UInt64)
    case gap(expected: UInt64)
    case conflict
    case repairRequired
}

public enum AppLifecycleStatus: String, Equatable, Codable, Sendable {
    case open
    case pending
    case answered
    case noComment = "no_comment"
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

public enum InformationalSeenStatus: Equatable, Sendable {
    case available
    case pending
    case confirmed
    case resolvedWithoutSeen
}

public struct PresentedRequest: Equatable, Sendable {
    public let key: RequestKey
    /// The exact sender-authored version represented by this projection.
    public let requestRevision: UInt64
    /// Durable order assigned by C at first acceptance; consumers preserve this order.
    public let acceptanceOrder: UInt64
    public let title: ExactText?
    public let body: ExactText?
    /// Sender-authored creation time, if the original message supplied one.
    /// It never changes the server-assigned inbox order.
    public let createdAt: Date?
    /// A UTF-8 JSON string for inert inspection. H must not parse it to render answers.
    public let originalContentJSON: String
    public let selector: BoundDocumentSelector?
    public let draft: RequestDraft
    public let lifecycleStatus: AppLifecycleStatus
    public let receiptFacts: ReceiptPresentationFacts?
    public let intentReceipt: IntentReceipt?
    public let projection: AdmittedRequestProjection
    public let informationalSeenStatus: InformationalSeenStatus?
    public let attentionTier: AttentionTier
    /// The relay explicitly rejected No comment; other answer methods remain usable.
    public let noCommentUnavailable: Bool
    /// The relay explicitly rejected the latest answer operation.
    public let answerNotDelivered: Bool
    /// A server-declined stale answer whose newer revision is now available.
    public let staleAnswerRevision: StaleAnswerRevision?
    /// Whether lifecycle and Seen state were established by the accepted
    /// bounded snapshot, a receipt, or later contiguous relay activity.
    public let inboxStateIsCurrent: Bool

    public var isResolved: Bool {
        lifecycleStatus != .open && lifecycleStatus != .pending
    }

    public init(key: RequestKey,
                requestRevision: UInt64 = 1,
                acceptanceOrder: UInt64,
                title: ExactText?,
                body: ExactText?,
                createdAt: Date? = nil,
                originalContentJSON: String,
                selector: BoundDocumentSelector?,
                draft: RequestDraft,
                lifecycleStatus: AppLifecycleStatus,
                receiptFacts: ReceiptPresentationFacts?,
                intentReceipt: IntentReceipt?,
                projection: AdmittedRequestProjection,
                informationalSeenStatus: InformationalSeenStatus? = nil,
                attentionTier: AttentionTier = .middle,
                noCommentUnavailable: Bool = false,
                answerNotDelivered: Bool = false,
                staleAnswerRevision: StaleAnswerRevision? = nil,
                inboxStateIsCurrent: Bool = true) {
        self.key = key
        self.requestRevision = requestRevision
        self.acceptanceOrder = acceptanceOrder
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.originalContentJSON = originalContentJSON
        self.selector = selector
        self.draft = draft
        self.lifecycleStatus = lifecycleStatus
        self.receiptFacts = receiptFacts
        self.intentReceipt = intentReceipt
        self.projection = projection
        self.informationalSeenStatus = informationalSeenStatus
        self.attentionTier = attentionTier
        self.noCommentUnavailable = noCommentUnavailable
        self.answerNotDelivered = answerNotDelivered
        self.staleAnswerRevision = staleAnswerRevision
        self.inboxStateIsCurrent = inboxStateIsCurrent
    }
}

public struct StaleAnswerRevision: Equatable, Sendable {
    public let operationID: UUID
    public let submittedRevision: UInt64
    public let currentRevision: UInt64

    public init(operationID: UUID, submittedRevision: UInt64, currentRevision: UInt64) {
        self.operationID = operationID
        self.submittedRevision = submittedRevision
        self.currentRevision = currentRevision
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

    public func inspectAnswerDraft(context suppliedContext: PortContext, request key: RequestKey,
                                   revision: UInt64) throws -> PresentedRequest? {
        try validate(suppliedContext)
        let snapshot = try store.snapshot(context: profileContext)
        guard let thread = snapshot.conversationThreads[key], let payload = thread.revisions[revision],
              let draft = thread.answerDrafts?[revision], let stored = snapshot.requests[key] else { return nil }
        return try present(StoredRequest(key: key, originalPayload: payload), acceptanceOrder: stored.acceptanceOrder ?? 0,
            draft: draft, session: nil, remote: nil, submission: nil, selector: nil,
            requestRevision: revision)
    }

    public func saveConversationDraft(_ draft: ConversationDraft, context suppliedContext: PortContext) throws {
        try validate(suppliedContext)
        try store.saveConversationDraft(draft, context: profileContext)
    }

    @discardableResult
    public func updateConversationDraftText(_ text: ExactText, for binding: ConversationBinding,
                                            context suppliedContext: PortContext) throws -> ConversationDraft {
        try validate(suppliedContext)
        return try store.updateConversationDraftText(text, for: binding, context: profileContext)
    }

    public func markConversationRead(_ request: RequestKey, context suppliedContext: PortContext) throws {
        try validate(suppliedContext)
        try store.markConversationRead(request, context: profileContext)
    }

    public func appendFixtureDiscussion(_ binding: ConversationBinding, context suppliedContext: PortContext) throws {
        try validate(suppliedContext)
        try store.appendFixtureDiscussion(binding, context: profileContext)
    }

    public func abandonConversationUploads(for request: RequestKey, context suppliedContext: PortContext) throws -> [ConversationUploadCleanup] {
        try validate(suppliedContext)
        return try store.abandonConversationUploads(for: request, context: profileContext)
    }

    public func markConversationCleanupUnknown(for request: RequestKey, reason: ExactText, context suppliedContext: PortContext) throws {
        try validate(suppliedContext)
        let pending = try store.conversationSnapshot(context: profileContext).threads[request]?.uploadCleanups ?? [:]
        for cleanup in pending.values {
            if case .acknowledged = cleanup.outcome { continue }
            try store.recordConversationCleanup(cleanup.id, request: request, outcome: .unknown(reason), context: profileContext)
        }
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
        try inspect(context: suppliedContext, request: key, revision: nil)
    }

    public func inspect(context suppliedContext: PortContext,
                        request key: RequestKey,
                        revision: UInt64) throws -> PresentationSnapshot {
        try inspect(context: suppliedContext, request: key, revision: Optional(revision))
    }

    private func inspect(context suppliedContext: PortContext,
                         request key: RequestKey,
                         revision requestedRevision: UInt64?) throws -> PresentationSnapshot {
        try validate(suppliedContext)
        let snapshot = try store.snapshot(context: profileContext)
        let revision = requestedRevision ?? snapshot.conversationThreads[key]?.currentRevision ?? 1
        if snapshot.conversationThreads[key]?.redactedRevisions?.contains(revision) == true {
            return try presentation(from: snapshot, selectorFor: nil).filtering(to: key)
        }
        let selector = try store.selector(for: key, requestRevision: revision, context: profileContext)
        return try presentation(from: store.snapshot(context: profileContext), selectorFor: [key: selector])
            .filtering(to: key)
    }

    private func request(for selector: BoundDocumentSelector,
                         in snapshot: AttentionStoreSnapshot) -> StoredRequest? {
        guard let accepted = snapshot.requests[selector.request] else { return nil }
        guard let thread = snapshot.conversationThreads[selector.request] else {
            return selector.requestRevision == 1 ? accepted : nil
        }
        guard let payload = thread.revisions[selector.requestRevision],
              thread.redactedRevisions?.contains(selector.requestRevision) != true else { return nil }
        let request = StoredRequest(key: selector.request, originalPayload: payload)
        return accepted.acceptanceOrder.map { request.assigningAcceptanceOrder($0) } ?? request
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
        guard let request = request(for: selector, in: snapshot) else { throw AttentionStoreError.requestMissing }
        try store.saveDraft(RequestDraft(interface: request.interface), selector: selector, context: profileContext)
    }

    public func preview(context suppliedContext: PortContext,
                        selector: BoundDocumentSelector,
                        inputs: [TypedInputRecord]) throws -> JSONValue {
        try validate(suppliedContext)
        let snapshot = try store.snapshot(context: profileContext)
        guard let request = request(for: selector, in: snapshot) else { throw AttentionStoreError.requestMissing }
        let (typedSubmission, draft) = try makeSubmission(inputs, for: request.interface)
        return try store.previewSubmission(typedSubmission,
                                           draft: draft,
                                           selector: selector,
                                           context: profileContext)
    }

    public func submit(_ intent: SubmitIntent) throws -> IntentReceipt {
        try validate(intent.context)
        let snapshot = try store.snapshot(context: profileContext)
        guard let request = request(for: intent.selector, in: snapshot) else { throw AttentionStoreError.requestMissing }
        let (typedSubmission, draft) = try makeSubmission(intent.inputs, for: request.interface)
        let stored = try store.submit(intentID: intent.intentID,
                                      typedSubmission: typedSubmission,
                                      typedInputs: intent.inputs,
                                      draft: draft,
                                      selector: intent.selector,
                                      context: profileContext)
        return receipt(stored, context: context)
    }

    @discardableResult
    public func submitNoComment(context suppliedContext: PortContext,
                                selector: BoundDocumentSelector,
                                intentID: UUID) throws -> IntentReceipt {
        try validate(suppliedContext)
        let stored = try store.submitNoComment(intentID: intentID,
                                               selector: selector,
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
                                             requestRevision: stored.requestRevision ?? 1,
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
        case .failed:
            localState = .notDelivered
            relayOutcome = .unknown
        case .staleRevision:
            localState = .notDelivered
            relayOutcome = .unknown
        case let .terminal(state, sequence, authorizedAnswer):
            localState = .terminalUnconfirmed
            relayOutcome = .terminal(state: state, authorizedAnswer: authorizedAnswer, sequence: sequence)
        case let .refusedByRetraction(retractedAtMilliseconds):
            localState = .refusedByRetraction(retractedAtMilliseconds: retractedAtMilliseconds)
            relayOutcome = .refusedByRetraction(retractedAtMilliseconds: retractedAtMilliseconds)
        case .unsupported:
            localState = .unsupported
            relayOutcome = .unsupported
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
                             answerKind: stored.answerKind,
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
            let session = snapshot.fixtureSessions[item.request.key]
            let thread = snapshot.conversationThreads[item.request.key]
            let conversationRevision = thread?.currentRevision ?? 1
            let presentedRevision = selectors?[item.request.key]?.requestRevision ?? conversationRevision
            let matchesCurrentRevision: (Submission) -> Bool = { candidate in
                guard candidate.requestKey == item.request.key else { return false }
                return (candidate.requestRevision ?? 1) == conversationRevision
            }
            let currentIntents = snapshot.intents.values.filter(matchesCurrentRevision)
            let projectedRequest: StoredRequest
            if let selector = selectors?[item.request.key], selector.requestRevision != conversationRevision,
               let payload = thread?.revisions[selector.requestRevision] {
                let historical = StoredRequest(key: item.request.key, originalPayload: payload)
                projectedRequest = historical.assigningAcceptanceOrder(item.order)
            } else {
                projectedRequest = item.request
            }
            let currentDraft: RequestDraft
            if presentedRevision == conversationRevision {
                currentDraft = snapshot.drafts[item.request.key] ??
                    thread?.answerDrafts?[presentedRevision] ?? RequestDraft(interface: projectedRequest.interface)
            } else {
                currentDraft = thread?.answerDrafts?[presentedRevision] ??
                    RequestDraft(interface: projectedRequest.interface)
            }
            let hasUnsupportedNoComment = currentIntents.contains { candidate in
                guard candidate.isNoComment else { return false }
                if case .unsupported = candidate.disposition { return true }
                return false
            }
            let hasFailedAnswer = currentIntents.contains { candidate in
                switch candidate.disposition {
                case .failed, .staleRevision: true
                default: false
                }
            }
            let submission = currentIntents.first { candidate in
                if candidate.isNoComment, case .unsupported = candidate.disposition { return false }
                return switch candidate.disposition {
                case .failed, .staleRevision: false
                default: true
                }
            }
                ?? session?.lifecycle.submissionValue.flatMap { value in
                    matchesCurrentRevision(value) ? value : nil
                }
            // A newer saved attempt supersedes the earlier unsupported result
            // while its own delivery outcome is pending.
            let noCommentUnavailable = hasUnsupportedNoComment && submission == nil
            let answerNotDelivered = hasFailedAnswer && submission == nil && !noCommentUnavailable &&
                snapshot.remoteStates[item.request.key]?.isTerminal != true
            let staleAnswerRevision = snapshot.intents.values.compactMap { candidate -> StaleAnswerRevision? in
                guard candidate.requestKey == item.request.key,
                      case let .staleRevision(currentRevision) = candidate.disposition,
                      conversationRevision >= currentRevision else { return nil }
                let submittedRevision = candidate.requestRevision ?? 1
                return StaleAnswerRevision(operationID: candidate.operationID,
                                           submittedRevision: submittedRevision,
                                           currentRevision: currentRevision)
            }.sorted { $0.currentRevision < $1.currentRevision }.last
            return try present(projectedRequest,
                        acceptanceOrder: item.order,
                        draft: currentDraft,
                        session: session,
                        remote: snapshot.remoteStates[item.request.key],
                        submission: submission,
                        selector: selectors?[item.request.key],
                        requestRevision: presentedRevision,
                        staleAnswerRevision: staleAnswerRevision,
                        noCommentUnavailable: noCommentUnavailable,
                        answerNotDelivered: answerNotDelivered,
                        inboxStateIsCurrent: snapshot.inboxCurrentKeys.map {
                            $0.contains(item.request.key)
                        } ?? true)
        }
        let displayRequests = requests.sorted { left, right in
            if left.inboxStateIsCurrent != right.inboxStateIsCurrent {
                return left.inboxStateIsCurrent
            }
            if left.isResolved != right.isResolved { return !left.isResolved }
            if left.acceptanceOrder != right.acceptanceOrder {
                return left.acceptanceOrder > right.acceptanceOrder
            }
            if left.key.senderID.rawValue != right.key.senderID.rawValue {
                return left.key.senderID.rawValue < right.key.senderID.rawValue
            }
            return left.key.messageID.rawValue < right.key.messageID.rawValue
        }
        var sourceOrderedRequests = displayRequests
        if let sourceOrder = snapshot.inboxSourceOrder {
            var sourceRank: [RequestKey: Int] = [:]
            for (index, key) in sourceOrder.enumerated() where sourceRank[key] == nil {
                sourceRank[key] = index
            }
            let pagePositions = displayRequests.indices.filter {
                sourceRank[displayRequests[$0].key] != nil
            }
            let pageRows = pagePositions.map { displayRequests[$0] }.sorted {
                sourceRank[$0.key, default: .max] < sourceRank[$1.key, default: .max]
            }
            for (position, row) in zip(pagePositions, pageRows) {
                sourceOrderedRequests[position] = row
            }
        }
        return PresentationSnapshot(revision: snapshot.revision,
                                    cursor: snapshot.cursor,
                                    replayBarrier: snapshot.replayBarrier,
                                    repairIssues: snapshot.repairIssues,
                                    requests: sourceOrderedRequests)
    }

    private func present(_ request: StoredRequest,
                         acceptanceOrder: UInt64,
                         draft: RequestDraft,
                         session: RequestSession?,
                         remote: RemoteRequestState?,
                         submission: Submission?,
                         selector: BoundDocumentSelector?,
                         requestRevision: UInt64 = 1,
                         staleAnswerRevision: StaleAnswerRevision? = nil,
                         noCommentUnavailable: Bool = false,
                         answerNotDelivered: Bool = false,
                         inboxStateIsCurrent: Bool = true) throws -> PresentedRequest {
        let status: AppLifecycleStatus
        let receiptFacts: ReceiptPresentationFacts?
        switch session?.lifecycle {
        case .some(.open) where remote?.isTerminal != true:
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
        case .some(.open), .none:
            if let submission, case .refusedByRetraction = submission.disposition {
                status = .cleared
                receiptFacts = ReceiptPresentationFacts(
                    evidenceLabel: "The relay refused this answer after the sender retracted the request. The answer was not accepted.",
                    ownOutcome: .refused,
                    originalOperationUncertainty: false)
            } else if let terminal = remote?.state {
                status = AppLifecycleStatus(rawValue: terminal.rawValue) ?? .open
                let hasAcceptedIntent = submission.map { value in
                    if case .accepted = value.disposition { return true }
                    return false
                } ?? false
                let evidenceLabel = terminal == .noComment
                    ? "The sender recorded your No comment answer."
                    : "Relay lifecycle evidence is recorded; original operation outcome is shown separately."
                receiptFacts = ReceiptPresentationFacts(evidenceLabel: evidenceLabel,
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
            if let submission, case .refusedByRetraction = submission.disposition {
                terminalState = .cleared
                authorizedAnswer = nil
                scene = document.terminalScene(state: .cleared, authorizedAnswer: nil)
            } else if let terminal = session?.lifecycle.terminalValue {
                terminalState = terminal.state
                authorizedAnswer = terminal.authorizedAnswer
                scene = document.terminalScene(state: terminal.state, authorizedAnswer: terminal.authorizedAnswer)
            } else if let remoteState = remote?.state {
                if let originAnswer = remote?.authorizedOriginAnswer {
                    authorizedAnswer = originAnswer
                } else if let submission, !submission.isNoComment, case .accepted = submission.disposition {
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
                                requestRevision: requestRevision,
                                acceptanceOrder: acceptanceOrder,
                                title: request.originalPayload.uniqueValue(named: "title")?.stringValue,
                                body: request.originalPayload.uniqueValue(named: "body")?.stringValue,
                                createdAt: request.createdAt,
                                originalContentJSON: request.originalPayload.canonicalJSON,
                                selector: selector,
                                draft: draft,
                                lifecycleStatus: status,
                                receiptFacts: receiptFacts,
                                intentReceipt: submission.map { receipt($0, context: context) },
                                projection: projection,
                                informationalSeenStatus: informationalSeenStatus(for: request,
                                    status: status, remote: remote, submission: submission),
                                attentionTier: remote?.attentionTier ?? .middle,
                                noCommentUnavailable: noCommentUnavailable,
                                answerNotDelivered: answerNotDelivered,
                                staleAnswerRevision: staleAnswerRevision,
                                inboxStateIsCurrent: inboxStateIsCurrent)
    }

    private func informationalSeenStatus(for request: StoredRequest,
                                         status: AppLifecycleStatus,
                                         remote: RemoteRequestState?,
                                         submission: Submission?) -> InformationalSeenStatus? {
        guard request.hasExplicitInformationalSeenAction else { return nil }
        let seenValue = JSONValue.object([
            JSONMember("acknowledgment", .string(ExactText("seen")))
        ])
        if Self.isConfirmedSeenOutcome(status: status, remote: remote, requestKey: request.key,
                                       submission: submission, seenValue: seenValue) {
            return .confirmed
        }
        if submission?.isNoComment == true { return .resolvedWithoutSeen }
        if status == .open || status == .pending {
            return submission?.answer.semanticallyEquals(seenValue) == true ? .pending : .available
        }
        return .resolvedWithoutSeen
    }

    private static func isConfirmedSeenOutcome(status: AppLifecycleStatus,
                                               remote: RemoteRequestState?,
                                               requestKey: RequestKey,
                                               submission: Submission?,
                                               seenValue: JSONValue) -> Bool {
        guard status == .answered,
              remote?.state == .answered,
              let terminalSequence = remote?.eventSequence else { return false }
        if let authorizedOriginAnswer = remote?.authorizedOriginAnswer {
            return authorizedOriginAnswer.semanticallyEquals(seenValue)
        }
        // Receiving devices get an answer-free lifecycle. Their local original
        // operation is authoritative only when its accepted terminal sequence
        // is the exact terminal now projected for this same request and answer.
        guard let submission,
              submission.requestKey == requestKey,
              submission.answer.semanticallyEquals(seenValue),
              case let .accepted(acceptedSequence) = submission.disposition,
              let acceptedSequence else { return false }
        return acceptedSequence == terminalSequence
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
    var submissionValue: Submission? {
        switch self {
        case .open:
            nil
        case let .pending(submission), let .terminal(_, submission):
            submission
        }
    }

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
