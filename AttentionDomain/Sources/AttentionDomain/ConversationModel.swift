import Foundation

/// A question version is independent of either replay stream's cursor.
public struct ConversationBinding: Equatable, Hashable, Codable, Sendable {
    public let request: RequestKey
    public let revision: UInt64

    public init(request: RequestKey, revision: UInt64) {
        self.request = request
        self.revision = revision
    }
}

public enum ConversationAuthor: String, Codable, Sendable {
    case person, origin, agent, server
}

public enum ConversationAvailability: Equatable, Codable, Sendable {
    case unsupported(reason: ExactText)
    case listening
    case notListening(lastDetachedAt: ExactText?)
    case gone
}

public enum ConversationFileTransfer: Equatable, Codable, Sendable {
    case unknown
    case transferred
    case notTransferred(reason: ExactText)
}

public enum ConversationFileUse: Equatable, Codable, Sendable {
    case unknown
    case used
    case unusable(reason: ExactText?)
}

/// The identity and digest describe the original bytes, never a thumbnail or transcoding.
public struct ConversationFile: Equatable, Codable, Identifiable, Sendable {
    public let id: ExactText
    public let name: ExactText
    public let byteCount: UInt64
    public let sha256: ExactText
    public let content: Content

    public enum Content: Equatable, Codable, Sendable {
        case inline(Data)
        case uploaded(ExactText)
        /// Account-owned local copy retained while upload or submission is unconfirmed.
        case localFile(ExactText)
    }

    public init(id: ExactText, name: ExactText, byteCount: UInt64, sha256: ExactText, content: Content) {
        self.id = id
        self.name = name
        self.byteCount = byteCount
        self.sha256 = sha256
        self.content = content
    }
}

/// Keeps exact conversation bytes outside the whole-account state file while
/// the domain state retains their account-owned local reference and identity.
public protocol ConversationFileReferenceStore: Sendable {
    func retainInlineContent(of file: ConversationFile) throws -> ConversationFile
}

public struct ConversationTurn: Equatable, Codable, Identifiable, Sendable {
    /// The server's origin-feed entry identity is the turn identity everywhere.
    public let id: ExactText
    public let binding: ConversationBinding
    public let author: ConversationAuthor
    public let sessionHandle: ExactText
    public let text: ExactText
    public let inReplyTo: ExactText?
    public let operationID: UUID?
    public let files: [ConversationFile]
    /// Origin-device projections deliberately omit person-authored content.
    public let contentRedacted: Bool?
    public let kind: Kind?
    public let resultStatus: ExactText?
    /// The per-account conversation feed sequence that delivered this turn.
    /// Older saved turns are reconstructed from the event journal on load.
    public var conversationSequence: UInt64?

    public enum Kind: String, Codable, Sendable { case discussion, reply, revision, result, terminal }

    public init(id: ExactText, binding: ConversationBinding, author: ConversationAuthor,
                sessionHandle: ExactText, text: ExactText, inReplyTo: ExactText? = nil,
                operationID: UUID? = nil, files: [ConversationFile] = [],
                contentRedacted: Bool? = nil, kind: Kind? = nil, resultStatus: ExactText? = nil,
                conversationSequence: UInt64? = nil) {
        self.id = id
        self.binding = binding
        self.author = author
        self.sessionHandle = sessionHandle
        self.text = text
        self.inReplyTo = inReplyTo
        self.operationID = operationID
        self.files = files
        self.contentRedacted = contentRedacted
        self.kind = kind
        self.resultStatus = resultStatus
        self.conversationSequence = conversationSequence
    }
}

/// Closed, payload-free labels for conversation validation details that may be
/// included in a support report. These identify client checks, not server data.
public enum ConversationValidationEventKind: String, Codable, Sendable {
    case request
    case discussion
    case reply
    case revision
    case result
    case receipt
    case acted
    case availability
    case fileTransfer = "file_transfer"
    case fileUse = "file_use"
    case turn
    case terminal
    case attentionTier = "attention_tier"
    case readPosition = "read_position"
    case retraction
    case readPositionSnapshot = "read_position_snapshot"
}

/// Stable names for the exact validation guard that rejected a conversation
/// event. Raw source text and values never enter the diagnostic.
public enum ConversationValidationGuardID: String, Codable, Sendable {
    case eventRevisionBinding = "event_revision_binding"
    case readPositionEventShape = "read_position_event_shape"
    case initialRevisionBinding = "initial_revision_binding"
    case requestSessionHandlePresent = "request_session_handle_present"
    case initialRequestRevision = "initial_request_revision"
    case revisionSessionHandlePresent = "revision_session_handle_present"
    case redactedRevisionBinding = "redacted_revision_binding"
    case loadedThreadFactNotAllowed = "loaded_thread_fact_not_allowed"
    case turnBinding = "turn_binding"
    case mergedTurnRequestBinding = "merged_turn_request_binding"
    case availabilitySessionHandle = "availability_session_handle"
    case availabilityRecordSessionHandle = "availability_record_session_handle"
    case actorPresent = "actor_present"
    case referencedTurnExists = "referenced_turn_exists"
    case referencedFileExists = "referenced_file_exists"
    case readPositionSnapshotEntry = "read_position_snapshot_entry"
}

/// Only booleans derived from presence, equality, or shape checks are retained.
/// Nil means a fact does not apply to the rejecting guard.
public struct ConversationValidationFacts: Equatable, Codable, Sendable {
    public let revisionIsZero: Bool?
    public let revisionIsOne: Bool?
    public let eventIdentifierPresent: Bool?
    public let readPositionPositive: Bool?
    public let sessionHandlePresent: Bool?
    public let sessionHandleMatchesThread: Bool?
    public let turnBindingMatchesEvent: Bool?
    public let turnRequestMatchesThread: Bool?
    public let turnIdentifierPresent: Bool?
    public let contentRedactedPresent: Bool?
    public let contentRedactedIsTrue: Bool?
    public let authorIsOrigin: Bool?
    public let revisionIsNext: Bool?
    public let actorPresent: Bool?
    public let referencedTurnPresent: Bool?
    public let referencedFilePresent: Bool?
    public let requestKeyIsUnique: Bool?

    init(revisionIsZero: Bool? = nil,
         revisionIsOne: Bool? = nil,
         eventIdentifierPresent: Bool? = nil,
         readPositionPositive: Bool? = nil,
         sessionHandlePresent: Bool? = nil,
         sessionHandleMatchesThread: Bool? = nil,
         turnBindingMatchesEvent: Bool? = nil,
         turnRequestMatchesThread: Bool? = nil,
         turnIdentifierPresent: Bool? = nil,
         contentRedactedPresent: Bool? = nil,
         contentRedactedIsTrue: Bool? = nil,
         authorIsOrigin: Bool? = nil,
         revisionIsNext: Bool? = nil,
         actorPresent: Bool? = nil,
         referencedTurnPresent: Bool? = nil,
         referencedFilePresent: Bool? = nil,
         requestKeyIsUnique: Bool? = nil) {
        self.revisionIsZero = revisionIsZero
        self.revisionIsOne = revisionIsOne
        self.eventIdentifierPresent = eventIdentifierPresent
        self.readPositionPositive = readPositionPositive
        self.sessionHandlePresent = sessionHandlePresent
        self.sessionHandleMatchesThread = sessionHandleMatchesThread
        self.turnBindingMatchesEvent = turnBindingMatchesEvent
        self.turnRequestMatchesThread = turnRequestMatchesThread
        self.turnIdentifierPresent = turnIdentifierPresent
        self.contentRedactedPresent = contentRedactedPresent
        self.contentRedactedIsTrue = contentRedactedIsTrue
        self.authorIsOrigin = authorIsOrigin
        self.revisionIsNext = revisionIsNext
        self.actorPresent = actorPresent
        self.referencedTurnPresent = referencedTurnPresent
        self.referencedFilePresent = referencedFilePresent
        self.requestKeyIsUnique = requestKeyIsUnique
    }
}

public struct ConversationValidationRejection: Equatable, Codable, Sendable {
    public let guardID: ConversationValidationGuardID
    public let eventKind: ConversationValidationEventKind
    public let facts: ConversationValidationFacts

    init(guardID: ConversationValidationGuardID,
         eventKind: ConversationValidationEventKind,
         facts: ConversationValidationFacts) {
        self.guardID = guardID
        self.eventKind = eventKind
        self.facts = facts
    }
}

struct ConversationValidationRejectionError: Error, Sendable {
    let rejection: ConversationValidationRejection
}

public struct ConversationTurnFacts: Equatable, Codable, Sendable {
    public var delivered = false
    public var actedBy: ExactText?
    public var fileTransfers: [ExactText: ConversationFileTransfer] = [:]
    public var fileUses: [ExactText: ConversationFileUse] = [:]

    public init() {}
}

public struct ConversationDraft: Equatable, Codable, Sendable {
    public let binding: ConversationBinding
    public var text: ExactText
    public var files: [ConversationFile]
    public var disposition: Disposition

    public enum Disposition: Equatable, Codable, Sendable {
        case saved
        case submitting(UUID)
        case outcomeUnknown(UUID)
        case acceptedPendingReplay(operation: UUID, turn: ExactText)
        case rejected(ExactText)
    }

    public init(binding: ConversationBinding, text: ExactText = ExactText(""),
                files: [ConversationFile] = [], disposition: Disposition = .saved) {
        self.binding = binding
        self.text = text
        self.files = files
        self.disposition = disposition
    }
}

/// Upload identity is independent of turn and cursor identity. Keep attempts even
/// after a rejected draft is edited, so departure can account for every group.
public struct ConversationUploadGroup: Equatable, Codable, Sendable {
    public let operationID: UUID
    public let binding: ConversationBinding
    public var originals: [ConversationFile]
    public var uploaded: [ConversationFile]
    public var cleanupID: UUID?
}

public struct ConversationUploadCleanup: Equatable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let binding: ConversationBinding
    public let uploadOperations: [UUID]
    public var outcome: Outcome

    public enum Outcome: Equatable, Codable, Sendable {
        case pending
        case unknown(ExactText)
        /// Acknowledges request-scope cleanup, not deletion of a particular file.
        case acknowledged(ConversationUploadDiscardResult)
    }
}

public struct ConversationUploadDiscardResult: Equatable, Codable, Sendable {
    public enum State: String, Codable, Sendable { case discarded, committed }
    public let state: State
    public let discarded: UInt64

    public init(state: State, discarded: UInt64) {
        self.state = state
        self.discarded = discarded
    }
}

/// Each projection entry carries exactly one fact. Receipt, action and file use are never inferred.
public struct ConversationEvent: Equatable, Codable, Sendable {
    public let sequence: UInt64
    public let binding: ConversationBinding
    public let fact: Fact
    public let retractedAtMilliseconds: UInt64?

    public enum Fact: Equatable, Codable, Sendable {
        case request(sessionHandle: ExactText, payload: JSONValue)
        /// One server revision frame, one transaction and one sequence number.
        case revision(ConversationTurn, payload: JSONValue)
        case redactedRevision(ConversationTurn)
        case turn(ConversationTurn)
        case delivered(turn: ExactText)
        case acted(turn: ExactText, by: ExactText)
        case availability(sessionHandle: ExactText, ConversationAvailability)
        case availabilityRecord(sessionHandle: ExactText, state: ConversationAvailability, support: JSONValue?)
        case fileTransfer(turn: ExactText, file: ExactText, ConversationFileTransfer)
        case fileUse(turn: ExactText, file: ExactText, ConversationFileUse)
        case terminal(turn: ExactText, author: ConversationAuthor, state: TerminalState)
        case attentionTier(eventID: ExactText, origin: ExactText, tier: AttentionTier, sessionHandle: ExactText?)
        /// Account read state is keyed by RequestKey and deliberately has no revision binding.
        case readPosition(eventID: ExactText, readThroughConversationSequence: UInt64)
        /// Reference to the same ordinary terminal, never another ordinary event.
        case retraction(turn: ExactText, terminalSequence: UInt64)
    }

    public init(sequence: UInt64,
                binding: ConversationBinding,
                fact: Fact,
                retractedAtMilliseconds: UInt64? = nil) {
        self.sequence = sequence
        self.binding = binding
        self.fact = fact
        self.retractedAtMilliseconds = retractedAtMilliseconds
    }

    func canEnrich(_ old: ConversationEvent) -> Bool {
        sequence == old.sequence && binding == old.binding && fact == old.fact &&
            (old.retractedAtMilliseconds == nil || old.retractedAtMilliseconds == retractedAtMilliseconds)
    }

    var requiresLoadedThread: Bool {
        switch fact {
        case .request, .attentionTier, .readPosition: return false
        case .revision: return binding.revision > 1
        default: return true
        }
    }
}

extension ConversationEvent.Fact {
    var diagnosticKind: ConversationValidationEventKind {
        switch self {
        case .request: .request
        case .revision: .revision
        case .redactedRevision: .revision
        case let .turn(turn):
            switch turn.kind {
            case .some(.discussion): .discussion
            case .some(.reply): .reply
            case .some(.revision): .revision
            case .some(.result): .result
            case .some(.terminal): .terminal
            case nil: .turn
            }
        case .delivered: .receipt
        case .acted: .acted
        case .availability: .availability
        case .availabilityRecord: .availability
        case .fileTransfer: .fileTransfer
        case .fileUse: .fileUse
        case .terminal: .terminal
        case .attentionTier: .attentionTier
        case .readPosition: .readPosition
        case .retraction: .retraction
        }
    }
}

private func conversationValidationRejection(
    _ guardID: ConversationValidationGuardID,
    eventKind: ConversationValidationEventKind,
    facts: ConversationValidationFacts = ConversationValidationFacts()
) -> ConversationValidationRejectionError {
    ConversationValidationRejectionError(rejection: ConversationValidationRejection(
        guardID: guardID, eventKind: eventKind, facts: facts))
}

public struct ConversationThread: Equatable, Codable, Sendable {
    public let request: RequestKey
    public let sessionHandle: ExactText
    public var revisions: [UInt64: JSONValue]
    public var currentRevision: UInt64
    public var turns: [ConversationTurn] = []
    public var facts: [ExactText: ConversationTurnFacts] = [:]
    public var drafts: [UInt64: ConversationDraft] = [:]
    public var answerDrafts: [UInt64: RequestDraft]?
    public var availability: ConversationAvailability = .unsupported(reason: ExactText("No listening support recorded"))
    public var terminal: TerminalState?
    public var terminalTurn: ExactText?
    public var listeningSupport: JSONValue?
    public var redactedRevisions: Set<UInt64>?
    public var terminalAuthor: ConversationAuthor?
    public var retraction: ConversationRetraction?
    /// Retraction time a delivery or inbox snapshot reported before the retraction turn arrived.
    public var reportedRetractedAtMilliseconds: UInt64?
    public var uploadGroups: [UUID: ConversationUploadGroup]?
    public var uploadCleanups: [UUID: ConversationUploadCleanup]?
    /// The latest agent reply that was on screen in this request's Chat.
    public var readThroughTurn: ExactText?
    /// Account-wide cursor when this server has supplied the read-position map.
    /// nil preserves the legacy local turn marker on older servers.
    public var accountReadThroughConversationSequence: UInt64?

    public var latestAgentReply: ConversationTurn? {
        turns.last { $0.kind == .reply && $0.author != .person }
    }
    /// An agent reply arrived after Chat last showed this request's replies.
    public var hasUnreadAgentReply: Bool {
        guard let latest = latestAgentReply else { return false }
        if let accountReadThroughConversationSequence,
           let latestSequence = latest.conversationSequence {
            return latestSequence > accountReadThroughConversationSequence
        }
        return latest.id != readThroughTurn
    }

    public var isRetracted: Bool { retraction != nil || reportedRetractedAtMilliseconds != nil }

    /// Answering the request ends its answer flow, not its separate Chat.
    public var allowsDiscussion: Bool {
        guard !isRetracted else { return false }
        guard let terminal else { return true }
        return terminal == .answered || terminal == .noComment
    }

    public var revisionNumbers: [UInt64] { Set(revisions.keys).union(redactedRevisions ?? []).sorted() }
    /// Accepted sender facts remain available under their original request,
    /// revision and turn identities. Draft edits and replay do not create one.
    public var acceptedUpdates: [ConversationTurn] {
        turns.filter { $0.kind == .revision && $0.author == .origin && $0.binding.revision > 1 }
    }
    public var currentContentRedacted: Bool { redactedRevisions?.contains(currentRevision) == true }
    public var currentQuestionPayload: JSONValue {
        revisions[currentRevision] ?? .object([
            JSONMember("title", .string(ExactText("Question content unavailable on this device"))),
            JSONMember("body", .string(ExactText("The originating device's projection omits this question version. Earlier drafts remain inspectable."))),
            JSONMember("answer_ui", .string(ExactText("Content redacted")))
        ])
    }

    mutating func settleAbandonedDraft(revision: UInt64) {
        guard var draft = drafts[revision] else { return }
        switch draft.disposition {
        case .saved, .rejected: break
        default: return // Keep ambiguous and accepted operations exact for replay.
        }
        let abandoned = (uploadGroups ?? [:]).values.filter { group in
            guard group.binding.revision == revision, let id = group.cleanupID,
                  let cleanup = uploadCleanups?[id], case let .acknowledged(result) = cleanup.outcome,
                  result.state == .discarded else { return false }
            return true
        }
        let ids = Set(abandoned.flatMap { $0.originals.map(\.id) })
        guard !ids.isEmpty else { return }
        draft.files.removeAll { ids.contains($0.id) }
        draft.disposition = .rejected(ExactText("Not delivered. Reselect files to upload again; text draft retained."))
        drafts[revision] = draft
    }

    mutating func orderTurns(using projectionSequences: [ExactText: UInt64]) {
        // Keep rows without a conversation-projection sequence in their existing
        // slots. Reorder only entries whose server sequence is known.
        let sequencedIndexes = turns.indices.filter { projectionSequences[turns[$0].id] != nil }
        let sequencedTurns = sequencedIndexes.map { turns[$0] }.sorted {
            let left = projectionSequences[$0.id]!
            let right = projectionSequences[$1.id]!
            return left == right ? false : left < right
        }
        for (index, turn) in zip(sequencedIndexes, sequencedTurns) {
            var sequenced = turn
            sequenced.conversationSequence = projectionSequences[turn.id] ?? turn.conversationSequence
            turns[index] = sequenced
        }
    }

    mutating func merge(_ turn: ConversationTurn, event: ConversationEvent) throws {
        guard turn.binding.request == request, turn.sessionHandle == sessionHandle,
              !turn.id.rawValue.isEmpty else {
            throw conversationValidationRejection(.mergedTurnRequestBinding,
                eventKind: event.fact.diagnosticKind,
                facts: ConversationValidationFacts(
                    sessionHandlePresent: !turn.sessionHandle.rawValue.isEmpty,
                    sessionHandleMatchesThread: turn.sessionHandle == sessionHandle,
                    turnRequestMatchesThread: turn.binding.request == request,
                    turnIdentifierPresent: !turn.id.rawValue.isEmpty))
        }
        if let index = turns.firstIndex(where: { $0.id == turn.id }) {
            guard turns[index] == turn else { throw ConversationError.conflict }
            return
        } else {
            turns.append(turn)
        }
        facts[turn.id] = facts[turn.id] ?? ConversationTurnFacts()
    }

    mutating func recordReportedRetraction(at retractedAtMilliseconds: UInt64) throws {
        guard terminal == nil || terminal == .cleared,
              [retraction?.retractedAtMilliseconds, reportedRetractedAtMilliseconds]
                .allSatisfy({ $0 == nil || $0 == retractedAtMilliseconds }) else { throw ConversationError.conflict }
        terminal = .cleared
        reportedRetractedAtMilliseconds = retractedAtMilliseconds
    }

    mutating func recordRetraction(turn: ExactText,
                                   sequence: UInt64,
                                   revision: UInt64,
                                   retractedAtMilliseconds: UInt64? = nil) throws {
        guard !turn.rawValue.isEmpty, sequence > 0, revision > 0,
              terminal == nil || terminal == .cleared,
              terminalTurn == nil || terminalTurn == turn,
              reportedRetractedAtMilliseconds == nil || retractedAtMilliseconds == nil ||
                reportedRetractedAtMilliseconds == retractedAtMilliseconds else { throw ConversationError.conflict }
        let existing = retraction
        guard existing == nil || (existing?.turn == turn && existing?.terminalSequence == sequence &&
              existing?.revision == revision &&
              (existing?.retractedAtMilliseconds == nil || retractedAtMilliseconds == nil ||
               existing?.retractedAtMilliseconds == retractedAtMilliseconds)) else {
            throw ConversationError.conflict
        }
        let fact = ConversationRetraction(turn: turn, terminalSequence: sequence, revision: revision,
            retractedAtMilliseconds: existing?.retractedAtMilliseconds ?? retractedAtMilliseconds)
        guard retraction == nil || retraction == fact else { throw ConversationError.conflict }
        retraction = fact
        terminal = .cleared
        terminalTurn = turn
        terminalAuthor = .origin
        if !turns.contains(where: { $0.id == turn }) {
            turns.append(ConversationTurn(id: turn, binding: ConversationBinding(request: request, revision: revision),
                author: .origin, sessionHandle: sessionHandle, text: ExactText(""), kind: .terminal))
            facts[turn] = ConversationTurnFacts()
        }
        for revision in drafts.keys {
            if var draft = drafts[revision], case .saved = draft.disposition {
                draft.disposition = .rejected(ExactText("Not delivered: request retracted"))
                drafts[revision] = draft
            }
        }
    }

    init(request: RequestKey, sessionHandle: ExactText, revision: UInt64, payload: JSONValue) {
        self.request = request
        self.sessionHandle = sessionHandle
        self.revisions = [revision: payload]
        self.currentRevision = revision
    }
}

public struct ConversationRetraction: Equatable, Codable, Sendable {
    public let turn: ExactText
    public let terminalSequence: UInt64
    public let revision: UInt64
    public let retractedAtMilliseconds: UInt64?

    public init(turn: ExactText,
                terminalSequence: UInt64,
                revision: UInt64,
                retractedAtMilliseconds: UInt64? = nil) {
        self.turn = turn
        self.terminalSequence = terminalSequence
        self.revision = revision
        self.retractedAtMilliseconds = retractedAtMilliseconds
    }
}

public enum ConversationError: Error, Equatable, Sendable {
    case invalidBinding
    case missingRequest
    case conflict
    case gap(expected: UInt64, received: UInt64)
    case closed
    case staleRevision(current: UInt64)
    case pendingSubmission
    case emptyDraft
    case fileMismatch
    case uploadRequired(ExactText)
    case uploadCapExceeded(file: ExactText, cap: UInt64)
}

/// Stored alongside existing account state, but with a wholly independent replay cursor.
public struct AccountConversationReadPosition: Equatable, Codable, Sendable {
    public let request: RequestKey
    public let readThroughConversationSequence: UInt64

    public init(request: RequestKey, readThroughConversationSequence: UInt64) {
        self.request = request
        self.readThroughConversationSequence = readThroughConversationSequence
    }
}

public struct PendingConversationReadPosition: Equatable, Codable, Sendable {
    public let request: RequestKey
    public let operationID: UUID
    public let readThroughConversationSequence: UInt64

    public init(request: RequestKey, operationID: UUID, readThroughConversationSequence: UInt64) {
        self.request = request
        self.operationID = operationID
        self.readThroughConversationSequence = readThroughConversationSequence
    }
}

struct ConversationState: Codable, Equatable {
    var cursor: UInt64 = 0
    var events: [UInt64: ConversationEvent] = [:]
    var threads: [RequestKey: ConversationThread] = [:]
    /// nil means no server read map has been observed in this saved state.
    var chatReadPositions: [RequestKey: UInt64]? = nil
    var chatReadPositionSupport: Bool? = nil
    var pendingChatReadPositions: [RequestKey: PendingConversationReadPosition]? = nil

    /// Reconstruct old persisted turn arrays from the conversation sequence
    /// journal. Turn IDs are identities and are not chronological ordering keys.
    mutating func orderTurnsFromProjectionEvents() {
        // `conversationSequence` was added after turns and projection events
        // were already persisted. Fill it from the containing journal entry so
        // replaying an already-saved event compares equal to its older copy.
        var normalizedEvents: [UInt64: ConversationEvent] = [:]
        for (sequence, event) in events {
            let fact: ConversationEvent.Fact
            switch event.fact {
            case let .turn(original):
                var turn = original
                turn.conversationSequence = sequence
                fact = .turn(turn)
            case let .revision(original, payload):
                var turn = original
                turn.conversationSequence = sequence
                fact = .revision(turn, payload: payload)
            case let .redactedRevision(original):
                var turn = original
                turn.conversationSequence = sequence
                fact = .redactedRevision(turn)
            default:
                fact = event.fact
            }
            normalizedEvents[sequence] = ConversationEvent(sequence: event.sequence,
                binding: event.binding, fact: fact,
                retractedAtMilliseconds: event.retractedAtMilliseconds)
        }
        events = normalizedEvents

        var turnSequences: [RequestKey: [ExactText: UInt64]] = [:]
        var retractionSequences: [RequestKey: [ExactText: UInt64]] = [:]
        for event in events.values {
            switch event.fact {
            case let .turn(turn), let .revision(turn, _), let .redactedRevision(turn):
                let key = event.binding.request
                let old = turnSequences[key]?[turn.id]
                turnSequences[key, default: [:]][turn.id] = min(old ?? event.sequence, event.sequence)
            case let .terminal(turn, _, _):
                let key = event.binding.request
                let old = turnSequences[key]?[turn]
                turnSequences[key, default: [:]][turn] = min(old ?? event.sequence, event.sequence)
            case let .retraction(turn, _):
                let key = event.binding.request
                let old = retractionSequences[key]?[turn]
                retractionSequences[key, default: [:]][turn] = min(old ?? event.sequence, event.sequence)
            default:
                continue
            }
        }

        var orderedThreads: [RequestKey: ConversationThread] = [:]
        for (request, existing) in threads {
            var thread = existing
            var sequences = turnSequences[request] ?? [:]
            for (turn, sequence) in retractionSequences[request] ?? [:] where sequences[turn] == nil {
                sequences[turn] = sequence
            }
            thread.orderTurns(using: sequences)
            orderedThreads[request] = thread
        }
        threads = orderedThreads
        applySavedReadPositionSupport()
    }

    mutating func apply(_ event: ConversationEvent) throws {
        let isReadPosition: Bool
        if case .readPosition = event.fact { isReadPosition = true }
        else { isReadPosition = false }
        guard isReadPosition ? event.binding.revision == 0 : event.binding.revision > 0 else {
            throw conversationValidationRejection(.eventRevisionBinding,
                eventKind: event.fact.diagnosticKind,
                facts: ConversationValidationFacts(revisionIsZero: event.binding.revision == 0))
        }
        if event.sequence <= cursor {
            guard let previous = events[event.sequence], event.canEnrich(previous) else {
                throw ConversationError.conflict
            }
            if previous != event {
                guard case let .retraction(turn, terminalSequence) = event.fact else { throw ConversationError.conflict }
                if var thread = threads[event.binding.request] {
                    try thread.recordRetraction(turn: turn, sequence: terminalSequence,
                        revision: event.binding.revision,
                        retractedAtMilliseconds: event.retractedAtMilliseconds)
                    threads[event.binding.request] = thread
                }
                events[event.sequence] = event
            }
            return
        }
        guard cursor < UInt64.max, event.sequence == cursor + 1 else {
            throw ConversationError.gap(expected: cursor == UInt64.max ? cursor : cursor + 1, received: event.sequence)
        }
        if case let .readPosition(eventID, position) = event.fact {
            guard event.binding.revision == 0, !eventID.rawValue.isEmpty, position > 0 else {
                throw conversationValidationRejection(.readPositionEventShape,
                    eventKind: event.fact.diagnosticKind,
                    facts: ConversationValidationFacts(revisionIsZero: event.binding.revision == 0,
                        eventIdentifierPresent: !eventID.rawValue.isEmpty,
                        readPositionPositive: position > 0))
            }
            mergeReadPosition(event.binding.request, position: position)
            events[event.sequence] = event
            cursor = event.sequence
            return
        }
        let binding = event.binding
        if threads[binding.request] == nil && event.requiresLoadedThread {
            // Keep facts for requests outside the initial inbox page. The journal
            // and cursor commit together, so the relay can be acknowledged now.
            events[event.sequence] = event
            cursor = event.sequence
            return
        }

        switch event.fact {
        case let .request(handle, payload):
            try applyRequest(handle: handle, payload: payload, binding: binding, event: event)
        case .attentionTier:
            break
        case let .revision(turn, payload) where threads[binding.request] == nil:
            guard binding.revision == 1, !turn.sessionHandle.rawValue.isEmpty else {
                throw conversationValidationRejection(.initialRevisionBinding,
                    eventKind: event.fact.diagnosticKind,
                    facts: ConversationValidationFacts(revisionIsOne: binding.revision == 1,
                        sessionHandlePresent: !turn.sessionHandle.rawValue.isEmpty))
            }
            try validateUnloadedSessionHandle(turn.sessionHandle, for: binding.request)
            var thread = ConversationThread(request: binding.request, sessionHandle: turn.sessionHandle,
                revision: binding.revision, payload: payload)
            try applyHeldEvents(to: &thread)
            applySavedReadPosition(to: &thread)
            threads[binding.request] = thread
            try applyThreadFact(event, to: &thread)
            threads[binding.request] = thread
        default:
            guard var thread = threads[binding.request] else { throw ConversationError.missingRequest }
            try applyThreadFact(event, to: &thread)
            threads[binding.request] = thread
        }
        events[event.sequence] = event
        cursor = event.sequence
    }

    private mutating func applyRequest(handle: ExactText, payload: JSONValue,
                                       binding: ConversationBinding, event: ConversationEvent) throws {
        guard !handle.rawValue.isEmpty else {
            throw conversationValidationRejection(.requestSessionHandlePresent,
                eventKind: event.fact.diagnosticKind,
                facts: ConversationValidationFacts(sessionHandlePresent: !handle.rawValue.isEmpty))
        }
        if var thread = threads[binding.request] {
            guard thread.sessionHandle == handle else { throw ConversationError.conflict }
            if let old = thread.revisions[binding.revision] {
                guard old == payload else { throw ConversationError.conflict }
            } else {
                guard binding.revision == thread.currentRevision + 1 else {
                    throw ConversationError.staleRevision(current: thread.currentRevision)
                }
                thread.revisions[binding.revision] = payload
                thread.currentRevision = binding.revision
            }
            threads[binding.request] = thread
        } else {
            guard binding.revision == 1 else {
                throw conversationValidationRejection(.initialRequestRevision,
                    eventKind: event.fact.diagnosticKind,
                    facts: ConversationValidationFacts(revisionIsOne: binding.revision == 1))
            }
            try validateUnloadedSessionHandle(handle, for: binding.request)
            var thread = ConversationThread(request: binding.request, sessionHandle: handle,
                revision: binding.revision, payload: payload)
            try applyHeldEvents(to: &thread)
            applySavedReadPosition(to: &thread)
            threads[binding.request] = thread
        }
    }

    mutating func mergeChatReadPositions(_ positions: [AccountConversationReadPosition]?) throws {
        guard let positions else {
            chatReadPositionSupport = false
            for key in Array(threads.keys) {
                threads[key]?.accountReadThroughConversationSequence = nil
            }
            return
        }

        var incoming: [RequestKey: UInt64] = [:]
        for position in positions {
            guard position.readThroughConversationSequence > 0,
                  incoming[position.request] == nil else {
                throw conversationValidationRejection(.readPositionSnapshotEntry,
                    eventKind: .readPositionSnapshot,
                    facts: ConversationValidationFacts(
                        readPositionPositive: position.readThroughConversationSequence > 0,
                        requestKeyIsUnique: incoming[position.request] == nil))
            }
            incoming[position.request] = position.readThroughConversationSequence
        }
        var merged = chatReadPositions ?? [:]
        for (request, position) in incoming {
            merged[request] = max(merged[request] ?? 0, position)
        }
        var pending = pendingChatReadPositions ?? [:]
        for request in Array(pending.keys) {
            // `chatReadPositions` also holds optimistic local cursors. Only the
            // position from this server snapshot can confirm a pending write.
            let serverPosition = incoming[request] ?? 0
            if let pendingWrite = pending[request],
               pendingWrite.readThroughConversationSequence <= serverPosition {
                pending.removeValue(forKey: request)
            }
        }
        chatReadPositions = merged
        pendingChatReadPositions = pending
        chatReadPositionSupport = true
        applySavedReadPositionSupport(reconcileLocalRead: true)
    }

    mutating func prepareReadPosition(for request: RequestKey,
                                      operationID: UUID,
                                      position: UInt64) -> PendingConversationReadPosition? {
        guard chatReadPositionSupport == true, position > 0 else { return nil }
        var positions = chatReadPositions ?? [:]
        let current = positions[request] ?? 0
        if current >= position {
            if let pending = pendingChatReadPositions?[request],
               pending.readThroughConversationSequence >= position {
                return pending
            }
            return nil
        }
        positions[request] = position
        chatReadPositions = positions
        var pending = pendingChatReadPositions ?? [:]
        if let previous = pending[request], previous.readThroughConversationSequence == position {
            return previous
        }
        let saved = PendingConversationReadPosition(request: request, operationID: operationID,
            readThroughConversationSequence: position)
        pending[request] = saved
        pendingChatReadPositions = pending
        if var thread = threads[request] {
            thread.accountReadThroughConversationSequence = position
            synchronizeLocalReadThrough(in: &thread, position: position)
            threads[request] = thread
        }
        return saved
    }

    mutating func acceptReadPosition(_ pending: PendingConversationReadPosition,
                                     serverPosition: UInt64) throws {
        guard serverPosition >= pending.readThroughConversationSequence else {
            throw ConversationError.conflict
        }
        var positions = chatReadPositions ?? [:]
        positions[pending.request] = max(positions[pending.request] ?? 0, serverPosition)
        chatReadPositions = positions
        chatReadPositionSupport = true
        var queued = pendingChatReadPositions ?? [:]
        if queued[pending.request]?.operationID == pending.operationID {
            queued.removeValue(forKey: pending.request)
        }
        pendingChatReadPositions = queued
        if var thread = threads[pending.request] {
            thread.accountReadThroughConversationSequence = positions[pending.request]
            synchronizeLocalReadThrough(in: &thread, position: positions[pending.request] ?? 0)
            threads[pending.request] = thread
        }
    }

    private mutating func mergeReadPosition(_ request: RequestKey, position: UInt64) {
        var positions = chatReadPositions ?? [:]
        positions[request] = max(positions[request] ?? 0, position)
        chatReadPositions = positions
        if let pending = pendingChatReadPositions?[request],
           pending.readThroughConversationSequence <= position {
            pendingChatReadPositions?.removeValue(forKey: request)
        }
        chatReadPositionSupport = true
        applySavedReadPositionSupport(reconcileLocalRead: true)
    }

    private mutating func applySavedReadPositionSupport(reconcileLocalRead: Bool = false) {
        guard chatReadPositionSupport == true else { return }
        var positions = chatReadPositions ?? [:]
        var pending = pendingChatReadPositions ?? [:]
        for key in Array(threads.keys) {
            guard var thread = threads[key] else { continue }
            let serverPosition = positions[key] ?? 0
            if let locallyReadTurn = thread.readThroughTurn,
               let localPosition = conversationSequence(for: locallyReadTurn, in: thread),
               localPosition > serverPosition {
                if reconcileLocalRead,
                   (pending[key]?.readThroughConversationSequence ?? 0) < localPosition {
                    pending[key] = PendingConversationReadPosition(request: key, operationID: UUID(),
                        readThroughConversationSequence: localPosition)
                }
                if reconcileLocalRead { positions[key] = localPosition }
            }
            let position = positions[key] ?? 0
            thread.accountReadThroughConversationSequence = position
            synchronizeLocalReadThrough(in: &thread, position: position)
            threads[key] = thread
        }
        chatReadPositions = positions
        pendingChatReadPositions = pending
    }

    private func conversationSequence(for turnID: ExactText,
                                      in thread: ConversationThread) -> UInt64? {
        if let sequence = thread.turns.first(where: { $0.id == turnID })?.conversationSequence {
            return sequence
        }
        return events.values.compactMap { event -> UInt64? in
            guard event.binding.request == thread.request else { return nil }
            switch event.fact {
            case let .turn(turn), let .revision(turn, _), let .redactedRevision(turn):
                return turn.id == turnID ? event.sequence : nil
            default:
                return nil
            }
        }.min()
    }

    private func applySavedReadPosition(to thread: inout ConversationThread) {
        guard chatReadPositionSupport == true else { return }
        let position = chatReadPositions?[thread.request] ?? 0
        thread.accountReadThroughConversationSequence = position
        synchronizeLocalReadThrough(in: &thread, position: position)
    }

    private func synchronizeLocalReadThrough(in thread: inout ConversationThread, position: UInt64) {
        guard position > 0,
              let turn = thread.turns.last(where: {
                  $0.kind == .reply && $0.author != .person &&
                      ($0.conversationSequence ?? 0) <= position
              }) else { return }
        thread.readThroughTurn = turn.id
    }

    private func validateUnloadedSessionHandle(_ handle: ExactText, for request: RequestKey) throws {
        for prior in events.values where prior.binding.request == request {
            guard case let .attentionTier(_, _, _, priorSessionHandle) = prior.fact,
                  let priorSessionHandle else { continue }
            guard priorSessionHandle == handle else { throw ConversationError.conflict }
        }
    }

    private func applyThreadFact(_ event: ConversationEvent, to thread: inout ConversationThread) throws {
        let binding = event.binding
        switch event.fact {
        case let .revision(turn, payload):
            guard !turn.sessionHandle.rawValue.isEmpty else {
                throw conversationValidationRejection(.revisionSessionHandlePresent,
                    eventKind: event.fact.diagnosticKind,
                    facts: ConversationValidationFacts(sessionHandlePresent: !turn.sessionHandle.rawValue.isEmpty))
            }
            guard turn.sessionHandle == thread.sessionHandle else { throw ConversationError.conflict }
            if let old = thread.revisions[binding.revision] {
                guard old == payload else { throw ConversationError.conflict }
            } else {
                guard binding.revision == thread.currentRevision + 1 else {
                    throw ConversationError.staleRevision(current: thread.currentRevision)
                }
                thread.revisions[binding.revision] = payload
                thread.currentRevision = binding.revision
            }
        case let .redactedRevision(turn):
            guard turn.contentRedacted == true, turn.sessionHandle == thread.sessionHandle,
                  turn.author == .origin, binding.revision == thread.currentRevision + 1 else {
                throw conversationValidationRejection(.redactedRevisionBinding,
                    eventKind: event.fact.diagnosticKind,
                    facts: ConversationValidationFacts(
                        sessionHandlePresent: !turn.sessionHandle.rawValue.isEmpty,
                        sessionHandleMatchesThread: turn.sessionHandle == thread.sessionHandle,
                        contentRedactedPresent: turn.contentRedacted != nil,
                        contentRedactedIsTrue: turn.contentRedacted == true,
                        authorIsOrigin: turn.author == .origin,
                        revisionIsNext: thread.currentRevision < UInt64.max &&
                            binding.revision == thread.currentRevision + 1))
            }
            thread.redactedRevisions = (thread.redactedRevisions ?? []).union([binding.revision])
            thread.currentRevision = binding.revision
        default:
            break
        }
        guard thread.revisionNumbers.contains(binding.revision) else { throw ConversationError.missingRequest }

        switch event.fact {
        case .request, .attentionTier, .readPosition:
            throw conversationValidationRejection(.loadedThreadFactNotAllowed,
                eventKind: event.fact.diagnosticKind)
        case let .turn(turn), let .revision(turn, _), let .redactedRevision(turn):
            guard turn.binding == binding, turn.sessionHandle == thread.sessionHandle,
                  !turn.id.rawValue.isEmpty else {
                throw conversationValidationRejection(.turnBinding,
                    eventKind: event.fact.diagnosticKind,
                    facts: ConversationValidationFacts(
                        sessionHandlePresent: !turn.sessionHandle.rawValue.isEmpty,
                        sessionHandleMatchesThread: turn.sessionHandle == thread.sessionHandle,
                        turnBindingMatchesEvent: turn.binding == binding,
                        turnIdentifierPresent: !turn.id.rawValue.isEmpty))
            }
            // Ordinary replay can close the request before its result turn
            // arrives. The exact matching identity enriches one retained row;
            // authoritative historical entries remain applicable.
            try thread.merge(turn, event: event)
            // Only an exact accepted operation clears its frozen draft.
            if let draft = thread.drafts[binding.revision], let operationID = turn.operationID,
               turn.kind != .result {
                if case let .acceptedPendingReplay(savedID, savedTurn) = draft.disposition,
                   savedID == operationID, savedTurn != turn.id { throw ConversationError.conflict }
                switch draft.disposition {
                case let .submitting(savedID) where savedID == operationID,
                     let .outcomeUnknown(savedID) where savedID == operationID,
                     let .acceptedPendingReplay(savedID, _) where savedID == operationID:
                    guard turn.contentRedacted != true, draft.text == turn.text,
                          Self.sameOriginalFiles(draft.files, turn.files) else { throw ConversationError.conflict }
                    thread.drafts.removeValue(forKey: binding.revision)
                default: break
                }
            }
        case let .availability(handle, availability):
            guard handle == thread.sessionHandle else {
                throw conversationValidationRejection(.availabilitySessionHandle,
                    eventKind: event.fact.diagnosticKind,
                    facts: ConversationValidationFacts(
                        sessionHandlePresent: !handle.rawValue.isEmpty,
                        sessionHandleMatchesThread: handle == thread.sessionHandle))
            }
            thread.availability = availability
        case let .availabilityRecord(handle, availability, support):
            guard handle == thread.sessionHandle else {
                throw conversationValidationRejection(.availabilityRecordSessionHandle,
                    eventKind: event.fact.diagnosticKind,
                    facts: ConversationValidationFacts(
                        sessionHandlePresent: !handle.rawValue.isEmpty,
                        sessionHandleMatchesThread: handle == thread.sessionHandle))
            }
            thread.availability = availability
            thread.listeningSupport = support
        case let .terminal(turn, author, state):
            if let terminal = thread.terminal {
                guard terminal == state, thread.terminalTurn == turn else { throw ConversationError.conflict }
            }
            thread.terminal = state
            thread.terminalTurn = turn
            thread.terminalAuthor = author
            if !thread.allowsDiscussion {
                for revision in thread.drafts.keys {
                    guard var draft = thread.drafts[revision] else { continue }
                    // Ambiguous submissions stay reconcilable with their original operation identity.
                    if case .saved = draft.disposition {
                        draft.disposition = .rejected(ExactText("Not delivered: request closed"))
                        thread.drafts[revision] = draft
                    }
                }
            }
        case let .retraction(turn, sequence):
            try thread.recordRetraction(turn: turn, sequence: sequence, revision: binding.revision,
                retractedAtMilliseconds: event.retractedAtMilliseconds)
        case let .delivered(turn):
            try requireTurn(turn, binding: binding, event: event, in: thread)
            thread.facts[turn, default: ConversationTurnFacts()].delivered = true
        case let .acted(turn, by):
            try requireTurn(turn, binding: binding, event: event, in: thread)
            guard !by.rawValue.isEmpty else {
                throw conversationValidationRejection(.actorPresent,
                    eventKind: event.fact.diagnosticKind,
                    facts: ConversationValidationFacts(actorPresent: !by.rawValue.isEmpty))
            }
            if let old = thread.facts[turn]?.actedBy, old != by { throw ConversationError.conflict }
            thread.facts[turn, default: ConversationTurnFacts()].actedBy = by
        case let .fileTransfer(turn, file, outcome):
            try requireFile(file, turn: turn, binding: binding, event: event, in: thread)
            let old = thread.facts[turn]?.fileTransfers[file] ?? .unknown
            guard old == .unknown || old == outcome else { throw ConversationError.conflict }
            thread.facts[turn, default: ConversationTurnFacts()].fileTransfers[file] = outcome
        case let .fileUse(turn, file, outcome):
            try requireFile(file, turn: turn, binding: binding, event: event, in: thread)
            let old = thread.facts[turn]?.fileUses[file] ?? .unknown
            guard old == .unknown || old == outcome else { throw ConversationError.conflict }
            thread.facts[turn, default: ConversationTurnFacts()].fileUses[file] = outcome
        }
    }

    /// A missing thread means these journaled facts have not been applied yet.
    /// Threads are retained once seeded, so the first local request or delivery
    /// can apply all held facts in their original sequence.
    func applyHeldEvents(to thread: inout ConversationThread) throws {
        let held = events.values.filter {
            $0.binding.request == thread.request && $0.requiresLoadedThread
        }.sorted { $0.sequence < $1.sequence }
        for event in held {
            try applyThreadFact(event, to: &thread)
        }
    }

    static func sameOriginalFiles(_ left: [ConversationFile], _ right: [ConversationFile]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy {
            $0.name == $1.name && $0.byteCount == $1.byteCount && $0.sha256 == $1.sha256
        }
    }

    private func requireTurn(_ id: ExactText, binding: ConversationBinding,
                             event: ConversationEvent, in thread: ConversationThread) throws {
        guard thread.terminalTurn == id || thread.turns.contains(where: { $0.id == id && $0.binding.request == binding.request }) else {
            throw conversationValidationRejection(.referencedTurnExists,
                eventKind: event.fact.diagnosticKind,
                facts: ConversationValidationFacts(referencedTurnPresent: false))
        }
    }

    private func requireFile(_ file: ExactText, turn: ExactText, binding: ConversationBinding,
                             event: ConversationEvent, in thread: ConversationThread) throws {
        try requireTurn(turn, binding: binding, event: event, in: thread)
        guard thread.turns.first(where: { $0.id == turn })?.files.contains(where: { $0.id == file }) == true else {
            throw conversationValidationRejection(.referencedFileExists,
                eventKind: event.fact.diagnosticKind,
                facts: ConversationValidationFacts(referencedFilePresent: false))
        }
    }
}

public struct ConversationSnapshot: Sendable {
    public let cursor: UInt64
    public let threads: [RequestKey: ConversationThread]
    public let chatReadPositions: [RequestKey: UInt64]?
    public let chatReadPositionSupport: Bool?
    public let pendingChatReadPositions: [PendingConversationReadPosition]

    public init(cursor: UInt64, threads: [RequestKey: ConversationThread],
                chatReadPositions: [RequestKey: UInt64]? = nil,
                chatReadPositionSupport: Bool? = nil,
                pendingChatReadPositions: [PendingConversationReadPosition] = []) {
        self.cursor = cursor
        self.threads = threads
        self.chatReadPositions = chatReadPositions
        self.chatReadPositionSupport = chatReadPositionSupport
        self.pendingChatReadPositions = pendingChatReadPositions
    }
}

public struct ConversationFileLimits: Equatable, Sendable {
    public let inlineDecodedBytes: UInt64
    /// nil is the published self-hosted "none", never an invented SaaS default.
    public let uploadCap: UInt64?

    public init(inlineDecodedBytes: UInt64, uploadCap: UInt64?) {
        self.inlineDecodedBytes = inlineDecodedBytes
        self.uploadCap = uploadCap
    }

    public enum Tier: Equatable, Sendable { case inline, upload }

    /// Each submission has a fresh aggregate budget. Never split or truncate a file.
    public func tiers(for files: [ConversationFile]) throws -> [Tier] {
        var remaining = inlineDecodedBytes
        return try files.map { file in
            if file.byteCount <= remaining {
                remaining -= file.byteCount
                return .inline
            }
            if let uploadCap, file.byteCount > uploadCap {
                throw ConversationError.uploadCapExceeded(file: file.name, cap: uploadCap)
            }
            return .upload
        }
    }
}
