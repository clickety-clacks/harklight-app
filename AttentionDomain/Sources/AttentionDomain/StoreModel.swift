import Foundation

public enum AttentionTransportMode: String, Codable, Sendable {
    case fixture
    case relay
}

public struct ProfileIdentity: Equatable, Hashable, Codable, Sendable {
    public let trustedRelayAuthority: ExactText
    public let personID: ExactText
    public let deviceID: ExactText

    public init(trustedRelayAuthority: ExactText, personID: ExactText, deviceID: ExactText) {
        self.trustedRelayAuthority = trustedRelayAuthority
        self.personID = personID
        self.deviceID = deviceID
    }
}

public struct ProfileContext: Equatable, Codable, Sendable {
    public let identity: ProfileIdentity
    public let generation: UUID
    public let transportMode: AttentionTransportMode

    public init(identity: ProfileIdentity,
                generation: UUID = UUID(),
                transportMode: AttentionTransportMode) {
        self.identity = identity
        self.generation = generation
        self.transportMode = transportMode
    }
}

public struct CompatibilityDraft: Equatable, Codable, Sendable {
    public var selectedActionID: ExactText?
    public var textByActionID: [ExactText: ExactText]

    public init(selectedActionID: ExactText? = nil,
                textByActionID: [ExactText: ExactText] = [:]) {
        self.selectedActionID = selectedActionID
        self.textByActionID = textByActionID
    }

    public var hasEdits: Bool {
        selectedActionID != nil || textByActionID.values.contains(where: { !$0.rawValue.isEmpty })
    }
}

public struct RequestDraft: Equatable, Codable, Sendable {
    public var inputs: [ExactText: InputDraft]
    public var compatibility: CompatibilityDraft

    public init(inputs: [ExactText: InputDraft], compatibility: CompatibilityDraft = CompatibilityDraft()) {
        self.inputs = inputs
        self.compatibility = compatibility
    }

    public init(interface: RequestInterface) {
        switch interface {
        case let .sender(document):
            inputs = Dictionary(uniqueKeysWithValues: document.inputs.map { ($0.id, InputDraft.initial(for: $0)) })
        case .compatibility, .unsupported:
            inputs = [:]
        }
        compatibility = CompatibilityDraft()
    }

    public var hasEdits: Bool {
        compatibility.hasEdits || inputs.values.contains { draft in
            draft.selectedActionID != nil || draft.point != nil ||
                draft.textByActionID.values.contains(where: { !$0.rawValue.isEmpty }) ||
                (draft.text.map { !$0.rawValue.isEmpty } ?? false) ||
                draft.horizontalText != nil || draft.verticalText != nil
        }
    }
}

public struct InputSubmission: Equatable, Codable, Sendable {
    public let inputID: ExactText
    public let actionID: ExactText?
    public let text: ExactText?
    public let point: PointValue?

    public init(inputID: ExactText,
                actionID: ExactText? = nil,
                text: ExactText? = nil,
                point: PointValue? = nil) {
        self.inputID = inputID
        self.actionID = actionID
        self.text = text
        self.point = point
    }
}

public enum TypedSubmission: Equatable, Codable, Sendable {
    case senderInputs([InputSubmission])
    case compatibility(actionID: ExactText, text: ExactText?)
}

public enum IntentDisposition: Equatable, Codable, Sendable {
    case pending
    case accepted(sequence: UInt64?)
    case lost
    case terminal(state: TerminalState, sequence: UInt64, authorizedAnswer: JSONValue?)
    case refusedByRetraction(retractedAtMilliseconds: UInt64)
    case repairRequired
}

public struct Submission: Equatable, Codable, Sendable {
    public let requestRevision: UInt64?
    public let requestKey: RequestKey
    public let answer: JSONValue
    public let intentID: UUID
    public let operationID: UUID
    public let operation: JSONValue
    public let typedInputs: [TypedInputRecord]
    public let opaqueDocumentID: ExactText
    public let opaqueSubmissionID: ExactText
    public let descriptorFingerprint: String
    public let contentFingerprint: String
    public var disposition: IntentDisposition

    public var wireFrame: Data {
        Data((operation.jsonString + "\n").utf8)
    }

    public init(requestKey: RequestKey,
                answer: JSONValue,
                intentID: UUID,
                operationID: UUID,
                operation: JSONValue,
                typedInputs: [TypedInputRecord] = [],
                opaqueDocumentID: ExactText = ExactText(""),
                opaqueSubmissionID: ExactText = ExactText(""),
                descriptorFingerprint: String,
                contentFingerprint: String,
                disposition: IntentDisposition = .pending,
                requestRevision: UInt64? = nil) {
        self.requestRevision = requestRevision
        self.requestKey = requestKey
        self.answer = answer
        self.intentID = intentID
        self.operationID = operationID
        self.operation = operation
        self.typedInputs = typedInputs
        self.opaqueDocumentID = opaqueDocumentID
        self.opaqueSubmissionID = opaqueSubmissionID
        self.descriptorFingerprint = descriptorFingerprint
        self.contentFingerprint = contentFingerprint
        self.disposition = disposition
    }
}

public enum OwnOutcome: String, Equatable, Codable, Sendable {
    case accepted
    case refused
    case unconfirmed
    case notApplicable
}

public struct FixtureTerminal: Equatable, Codable, Sendable {
    public let state: TerminalState
    public let evidenceLabel: String
    public let authorizedAnswer: JSONValue?
    public let ownOutcome: OwnOutcome

    public init(state: TerminalState,
                evidenceLabel: String,
                authorizedAnswer: JSONValue?,
                ownOutcome: OwnOutcome) {
        self.state = state
        self.evidenceLabel = evidenceLabel
        self.authorizedAnswer = authorizedAnswer
        self.ownOutcome = ownOutcome
    }
}

public enum FixtureLifecycle: Equatable, Codable, Sendable {
    case open
    case pending(Submission)
    case terminal(FixtureTerminal, Submission)
}

public struct RequestSession: Equatable, Codable, Sendable {
    public var draft: RequestDraft
    public var lifecycle: FixtureLifecycle

    public init(draft: RequestDraft, lifecycle: FixtureLifecycle = .open) {
        self.draft = draft
        self.lifecycle = lifecycle
    }
}

public enum RemoteDeliveryClassification: String, Equatable, Codable, Sendable {
    case message
    case knock
}

public struct RemoteRequestState: Equatable, Codable, Sendable {
    public let state: TerminalState?
    public let authorizedOriginAnswer: JSONValue?
    public let classification: RemoteDeliveryClassification?
    public let eventSequence: UInt64?

    public init(state: TerminalState? = nil,
                authorizedOriginAnswer: JSONValue? = nil,
                classification: RemoteDeliveryClassification? = nil,
                eventSequence: UInt64? = nil) {
        self.state = state
        self.authorizedOriginAnswer = authorizedOriginAnswer
        self.classification = classification
        self.eventSequence = eventSequence
    }

    public var isTerminal: Bool { state != nil }
}

public struct StoredRequest: Equatable, Codable, Sendable {
    public let key: RequestKey
    public let originalPayload: JSONValue
    /// Native durable order assigned when C first accepts this item.
    public let acceptanceOrder: UInt64?

    public init(key: RequestKey, originalPayload: JSONValue) {
        self.key = key
        self.originalPayload = originalPayload
        self.acceptanceOrder = nil
    }

    init(key: RequestKey, originalPayload: JSONValue, acceptanceOrder: UInt64) {
        self.key = key
        self.originalPayload = originalPayload
        self.acceptanceOrder = acceptanceOrder
    }

    func assigningAcceptanceOrder(_ acceptanceOrder: UInt64) -> StoredRequest {
        StoredRequest(key: key, originalPayload: originalPayload, acceptanceOrder: acceptanceOrder)
    }

    public var answerDescription: JSONValue? {
        let members = originalPayload.objectMembers?.filter { $0.key == ExactText("answer_ui") } ?? []
        return members.count == 1 ? members[0].value : nil
    }

    /// This is the one explicit informational convention supported by Spirit
    /// v19. Labels, body text, missing descriptors and unrelated values never
    /// imply that a message can be acknowledged as Seen.
    public var hasExplicitInformationalSeenAction: Bool {
        guard let description = answerDescription,
              description.hasExactlyKeys(["schema", "actions"]),
              description.uniqueValue(named: "schema")?.stringValue?.rawValue == "attention-client.actions/1",
              let actions = description.uniqueValue(named: "actions")?.arrayValues,
              actions.count == 1,
              let action = actions.first,
              action.hasExactlyKeys(["id", "label", "kind", "value"]),
              action.uniqueValue(named: "id")?.stringValue?.rawValue == "seen",
              action.uniqueValue(named: "label")?.stringValue?.rawValue == "Seen",
              action.uniqueValue(named: "kind")?.stringValue?.rawValue == "value",
              let value = action.uniqueValue(named: "value"),
              value.hasExactlyKeys(["acknowledgment"]),
              value.uniqueValue(named: "acknowledgment")?.stringValue?.rawValue == "seen" else {
            return false
        }
        return true
    }

    public var interface: RequestInterface {
        guard let members = originalPayload.objectMembers?.filter({ $0.key == ExactText("answer_ui") }),
              members.count <= 1 else {
            return .unsupported(.unfamiliar)
        }
        return RequestInterface.recognize(members.first?.value)
    }
}

public enum RelayEventBody: Equatable, Codable, Sendable {
    case delivery(StoredRequest, RemoteDeliveryClassification)
    case originReference(RequestKey)
    case terminal(RequestKey, TerminalState, JSONValue?)
}

public struct RelayEvent: Equatable, Codable, Sendable {
    public let sequence: UInt64
    public let body: RelayEventBody
    public let conversation: RelayConversationMetadata?

    public init(sequence: UInt64, body: RelayEventBody, conversation: RelayConversationMetadata? = nil) {
        self.sequence = sequence
        self.body = body
        self.conversation = conversation
    }

    public func hasSameSemanticContent(as other: RelayEvent) -> Bool {
        guard sequence == other.sequence else { return false }
        switch (body, other.body) {
        case let (.delivery(left, _), .delivery(right, _)):
            return left.key == right.key && left.originalPayload.semanticallyEquals(right.originalPayload)
        case let (.originReference(left), .originReference(right)):
            return left == right
        case let (.terminal(leftKey, leftState, leftAnswer), .terminal(rightKey, rightState, rightAnswer)):
            return leftKey == rightKey && leftState == rightState && optionalJSONEquals(leftAnswer, rightAnswer)
        default:
            return false
        }
    }

    private func optionalJSONEquals(_ left: JSONValue?, _ right: JSONValue?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (.some(left), .some(right)): return left.semanticallyEquals(right)
        default: return false
        }
    }
}

/// Additive ordinary-stream metadata initializes or closes a conversation without
/// borrowing a conversation sequence number or changing the sender's message JSON.
public struct RelayConversationMetadata: Equatable, Codable, Sendable {
    public let revision: UInt64
    public let sessionHandle: ExactText?
    public let eventID: ExactText?
    public let availability: ConversationAvailability?
    public let listeningSupport: JSONValue?
    public let author: ConversationAuthor?
    public let terminalReason: ExactText?
    public let retractedAtMilliseconds: UInt64?
    public let files: [ConversationFile]?

    public init(revision: UInt64, sessionHandle: ExactText? = nil, eventID: ExactText? = nil,
                availability: ConversationAvailability? = nil, listeningSupport: JSONValue? = nil,
                author: ConversationAuthor? = nil, files: [ConversationFile]? = nil,
                terminalReason: ExactText? = nil, retractedAtMilliseconds: UInt64? = nil) {
        self.revision = revision
        self.sessionHandle = sessionHandle
        self.eventID = eventID
        self.availability = availability
        self.listeningSupport = listeningSupport
        self.author = author
        self.terminalReason = terminalReason
        self.retractedAtMilliseconds = retractedAtMilliseconds
        self.files = files
    }

    func canEnrich(_ old: RelayConversationMetadata) -> Bool {
        revision == old.revision && (old.sessionHandle == nil || old.sessionHandle == sessionHandle) &&
        (old.eventID == nil || old.eventID == eventID) && (old.availability == nil || old.availability == availability) &&
        (old.listeningSupport == nil || old.listeningSupport == listeningSupport) &&
        (old.author == nil || old.author == author) && (old.files == nil || old.files == files) &&
        (old.terminalReason == nil || old.terminalReason == terminalReason) &&
        (old.retractedAtMilliseconds == nil || old.retractedAtMilliseconds == retractedAtMilliseconds)
    }
}

public enum StoreRepairIssue: Equatable, Codable, Sendable {
    case eventGap(expected: UInt64, received: UInt64)
    case missingOriginContent(sequence: UInt64, requestKey: RequestKey)
    case conflictingEvent(sequence: UInt64)
}

public struct AttentionStoreSnapshot: Sendable {
    public let revision: UInt64
    public let requests: [RequestKey: StoredRequest]
    public let drafts: [RequestKey: RequestDraft]
    public let intents: [UUID: Submission]
    public let outbox: [Submission]
    public let remoteStates: [RequestKey: RemoteRequestState]
    public let fixtureSessions: [RequestKey: RequestSession]
    public let conversationThreads: [RequestKey: ConversationThread]
    public let cursor: UInt64
    public let replayBarrier: UInt64?
    public let repairIssues: [StoreRepairIssue]

    public init(requests: [RequestKey: StoredRequest],
                drafts: [RequestKey: RequestDraft],
                intents: [UUID: Submission],
                outbox: [Submission],
                remoteStates: [RequestKey: RemoteRequestState],
                fixtureSessions: [RequestKey: RequestSession],
                revision: UInt64,
                cursor: UInt64,
                replayBarrier: UInt64?,
                repairIssues: [StoreRepairIssue],
                conversationThreads: [RequestKey: ConversationThread] = [:]) {
        self.conversationThreads = conversationThreads
        self.requests = requests
        self.drafts = drafts
        self.intents = intents
        self.outbox = outbox
        self.remoteStates = remoteStates
        self.fixtureSessions = fixtureSessions
        self.revision = revision
        self.cursor = cursor
        self.replayBarrier = replayBarrier
        self.repairIssues = repairIssues
    }
}

public enum AttentionStoreError: Error, Equatable, LocalizedError, Sendable {
    case staleProfile
    case wrongAccount
    case requestMissing
    case requestConflict
    case selectorExpired
    case invalidDraft
    case invalidSubmission
    case unsupportedInterface
    case answerTooLarge
    case requestClosed
    case competingIntent(UUID)
    case intentConflict
    case intentMissing
    case eventGap(expected: UInt64, received: UInt64)
    case eventConflict(UInt64)
    case missingOriginContent(RequestKey)
    case replayAlreadyActive
    case replayNotActive
    case replayIncomplete(expected: UInt64, actual: UInt64)
    case fixtureOnlyOperation
    case missingAcceptanceOrder
    case duplicateAcceptanceOrder
    case invalidProjection
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .staleProfile: return "The profile session is stale; refresh the current account context."
        case .wrongAccount: return "The request is outside the current account and device profile."
        case .requestMissing: return "The request is not present in the current account snapshot."
        case .requestConflict: return "The request key is already bound to different immutable content."
        case .selectorExpired: return "The request presentation selector is stale or belongs to another profile generation."
        case .invalidDraft: return "The draft contains missing, foreign, or malformed typed input state."
        case .invalidSubmission: return "The submission does not match every declared input and selected action."
        case .unsupportedInterface: return "The complete sender interface is not supported."
        case .answerTooLarge: return "The exact encoded answer operation exceeds the supported frame limit."
        case .requestClosed: return "The request is already terminal and cannot accept a new intent."
        case let .competingIntent(id): return "A different durable intent already owns this request: \(id.uuidString)."
        case .intentConflict: return "This intent ID is already bound to different immutable content."
        case .intentMissing: return "No durable intent exists for this ID in the current profile."
        case let .eventGap(expected, received): return "Event replay has a gap: expected sequence \(expected), received \(received)."
        case let .eventConflict(sequence): return "Sequence \(sequence) was replayed with conflicting semantic content."
        case let .missingOriginContent(key): return "Origin content for \(key.senderID.rawValue)/\(key.messageID.rawValue) is missing; the cursor was not advanced."
        case .replayAlreadyActive: return "A replay barrier is already active."
        case .replayNotActive: return "There is no active replay barrier."
        case let .replayIncomplete(expected, actual): return "Replay cannot publish: barrier \(expected), applied cursor \(actual)."
        case .fixtureOnlyOperation: return "Fixture outcomes are separate from authenticated relay state."
        case .missingAcceptanceOrder: return "The accepted request is missing its durable native order."
        case .duplicateAcceptanceOrder: return "Accepted requests contain a conflicting durable native order."
        case .invalidProjection: return "The admitted sender scene could not be projected with its authorized evidence."
        case let .persistence(message): return "Durable state could not be committed: \(message)"
        }
    }
}
