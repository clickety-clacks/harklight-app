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

    public enum Kind: String, Codable, Sendable { case discussion, reply, revision, result, terminal }

    public init(id: ExactText, binding: ConversationBinding, author: ConversationAuthor,
                sessionHandle: ExactText, text: ExactText, inReplyTo: ExactText? = nil,
                operationID: UUID? = nil, files: [ConversationFile] = [],
                contentRedacted: Bool? = nil, kind: Kind? = nil, resultStatus: ExactText? = nil) {
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
    }
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
    public var uploadGroups: [UUID: ConversationUploadGroup]?
    public var uploadCleanups: [UUID: ConversationUploadCleanup]?

    public var isRetracted: Bool { retraction != nil }

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

    mutating func orderTurns() {
        if turns.allSatisfy({ UInt64($0.id.rawValue) != nil }) {
            turns.sort { UInt64($0.id.rawValue)! < UInt64($1.id.rawValue)! }
        }
    }

    mutating func merge(_ turn: ConversationTurn) throws {
        guard turn.binding.request == request, turn.sessionHandle == sessionHandle,
              !turn.id.rawValue.isEmpty else { throw ConversationError.invalidBinding }
        if let index = turns.firstIndex(where: { $0.id == turn.id }) {
            guard turns[index] == turn else { throw ConversationError.conflict }
            return
        } else {
            turns.append(turn)
        }
        facts[turn.id] = facts[turn.id] ?? ConversationTurnFacts()
        orderTurns()
    }

    mutating func recordRetraction(turn: ExactText,
                                   sequence: UInt64,
                                   revision: UInt64,
                                   retractedAtMilliseconds: UInt64? = nil) throws {
        guard !turn.rawValue.isEmpty, sequence > 0, revision > 0,
              terminal == nil || terminal == .cleared,
              terminalTurn == nil || terminalTurn == turn else { throw ConversationError.conflict }
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
            orderTurns()
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
struct ConversationState: Codable {
    var cursor: UInt64 = 0
    var events: [UInt64: ConversationEvent] = [:]
    var threads: [RequestKey: ConversationThread] = [:]

    mutating func apply(_ event: ConversationEvent) throws {
        guard event.binding.revision > 0 else { throw ConversationError.invalidBinding }
        if event.sequence <= cursor {
            guard let previous = events[event.sequence], event.canEnrich(previous) else {
                throw ConversationError.conflict
            }
            if previous != event {
                guard case let .retraction(turn, terminalSequence) = event.fact,
                      var thread = threads[event.binding.request] else { throw ConversationError.conflict }
                try thread.recordRetraction(turn: turn, sequence: terminalSequence,
                    revision: event.binding.revision,
                    retractedAtMilliseconds: event.retractedAtMilliseconds)
                threads[event.binding.request] = thread
                events[event.sequence] = event
            }
            return
        }
        guard cursor < UInt64.max, event.sequence == cursor + 1 else {
            throw ConversationError.gap(expected: cursor == UInt64.max ? cursor : cursor + 1, received: event.sequence)
        }
        let binding = event.binding
        if case let .redactedRevision(turn) = event.fact {
            guard var thread = threads[binding.request], turn.contentRedacted == true,
                  turn.sessionHandle == thread.sessionHandle, turn.author == .origin,
                  binding.revision == thread.currentRevision + 1 else { throw ConversationError.invalidBinding }
            thread.redactedRevisions = (thread.redactedRevisions ?? []).union([binding.revision])
            thread.currentRevision = binding.revision
            threads[binding.request] = thread
        }
        let question: (ExactText, JSONValue)?
        switch event.fact {
        case let .request(handle, payload): question = (handle, payload)
        case let .revision(turn, payload): question = (turn.sessionHandle, payload)
        default: question = nil
        }
        if let (handle, payload) = question {
            guard !handle.rawValue.isEmpty else { throw ConversationError.invalidBinding }
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
                guard binding.revision == 1 else { throw ConversationError.invalidBinding }
                threads[binding.request] = ConversationThread(request: binding.request,
                    sessionHandle: handle, revision: binding.revision, payload: payload)
            }
        }
        // A revision also carries its immutable turn, but never consumes a second sequence.
        let appliesTurn: Bool
        if case .revision = event.fact { appliesTurn = true } else { appliesTurn = question == nil }
        if appliesTurn {
            guard var thread = threads[binding.request], thread.revisionNumbers.contains(binding.revision) else {
                throw ConversationError.missingRequest
            }
            switch event.fact {
            case .request: break
            case let .turn(turn), let .revision(turn, _), let .redactedRevision(turn):
                guard turn.binding == binding, turn.sessionHandle == thread.sessionHandle,
                      !turn.id.rawValue.isEmpty else { throw ConversationError.invalidBinding }
                // Ordinary replay can close the request before its result turn
                // arrives. The exact matching identity enriches one retained
                // row; authoritative historical entries remain applicable.
                try thread.merge(turn)
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
                guard handle == thread.sessionHandle else { throw ConversationError.invalidBinding }
                thread.availability = availability
            case let .availabilityRecord(handle, availability, support):
                guard handle == thread.sessionHandle else { throw ConversationError.invalidBinding }
                thread.availability = availability
                thread.listeningSupport = support
            case let .terminal(turn, author, state):
                if let terminal = thread.terminal {
                    guard terminal == state, thread.terminalTurn == turn else { throw ConversationError.conflict }
                }
                thread.terminal = state
                thread.terminalTurn = turn
                thread.terminalAuthor = author
                for revision in thread.drafts.keys {
                    guard var draft = thread.drafts[revision] else { continue }
                    // Ambiguous submissions stay reconcilable with their original operation identity.
                    if case .saved = draft.disposition {
                        draft.disposition = .rejected(ExactText("Not delivered: request closed"))
                        thread.drafts[revision] = draft
                    }
                }
            case let .retraction(turn, sequence):
                try thread.recordRetraction(turn: turn, sequence: sequence, revision: binding.revision,
                    retractedAtMilliseconds: event.retractedAtMilliseconds)
            case let .delivered(turn):
                try requireTurn(turn, binding: binding, in: thread)
                thread.facts[turn, default: ConversationTurnFacts()].delivered = true
            case let .acted(turn, by):
                try requireTurn(turn, binding: binding, in: thread)
                guard !by.rawValue.isEmpty else { throw ConversationError.invalidBinding }
                if let old = thread.facts[turn]?.actedBy, old != by { throw ConversationError.conflict }
                thread.facts[turn, default: ConversationTurnFacts()].actedBy = by
            case let .fileTransfer(turn, file, outcome):
                try requireFile(file, turn: turn, binding: binding, in: thread)
                let old = thread.facts[turn]?.fileTransfers[file] ?? .unknown
                guard old == .unknown || old == outcome else { throw ConversationError.conflict }
                thread.facts[turn, default: ConversationTurnFacts()].fileTransfers[file] = outcome
            case let .fileUse(turn, file, outcome):
                try requireFile(file, turn: turn, binding: binding, in: thread)
                let old = thread.facts[turn]?.fileUses[file] ?? .unknown
                guard old == .unknown || old == outcome else { throw ConversationError.conflict }
                thread.facts[turn, default: ConversationTurnFacts()].fileUses[file] = outcome
            }
            threads[binding.request] = thread
        }
        events[event.sequence] = event
        cursor = event.sequence
    }

    static func sameOriginalFiles(_ left: [ConversationFile], _ right: [ConversationFile]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy {
            $0.name == $1.name && $0.byteCount == $1.byteCount && $0.sha256 == $1.sha256
        }
    }

    private func requireTurn(_ id: ExactText, binding: ConversationBinding, in thread: ConversationThread) throws {
        guard thread.terminalTurn == id || thread.turns.contains(where: { $0.id == id && $0.binding.request == binding.request }) else {
            throw ConversationError.invalidBinding
        }
    }

    private func requireFile(_ file: ExactText, turn: ExactText, binding: ConversationBinding,
                             in thread: ConversationThread) throws {
        try requireTurn(turn, binding: binding, in: thread)
        guard thread.turns.first(where: { $0.id == turn })?.files.contains(where: { $0.id == file }) == true else {
            throw ConversationError.invalidBinding
        }
    }
}

public struct ConversationSnapshot: Sendable {
    public let cursor: UInt64
    public let threads: [RequestKey: ConversationThread]

    public init(cursor: UInt64, threads: [RequestKey: ConversationThread]) {
        self.cursor = cursor
        self.threads = threads
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
