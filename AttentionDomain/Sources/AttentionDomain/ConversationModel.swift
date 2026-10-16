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
    case person, origin, server
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

    public init(id: ExactText, binding: ConversationBinding, author: ConversationAuthor,
                sessionHandle: ExactText, text: ExactText, inReplyTo: ExactText? = nil,
                operationID: UUID? = nil, files: [ConversationFile] = []) {
        self.id = id
        self.binding = binding
        self.author = author
        self.sessionHandle = sessionHandle
        self.text = text
        self.inReplyTo = inReplyTo
        self.operationID = operationID
        self.files = files
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

/// Each projection entry carries exactly one fact. Receipt, action and file use are never inferred.
public struct ConversationEvent: Equatable, Codable, Sendable {
    public let sequence: UInt64
    public let binding: ConversationBinding
    public let fact: Fact

    public enum Fact: Equatable, Codable, Sendable {
        case request(sessionHandle: ExactText, payload: JSONValue)
        case turn(ConversationTurn)
        case delivered(turn: ExactText)
        case acted(turn: ExactText, by: ExactText)
        case availability(sessionHandle: ExactText, ConversationAvailability)
        case fileTransfer(turn: ExactText, file: ExactText, ConversationFileTransfer)
        case fileUse(turn: ExactText, file: ExactText, ConversationFileUse)
        case terminal(turn: ExactText, author: ConversationAuthor, state: TerminalState)
    }

    public init(sequence: UInt64, binding: ConversationBinding, fact: Fact) {
        self.sequence = sequence
        self.binding = binding
        self.fact = fact
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
    public var availability: ConversationAvailability = .unsupported(reason: ExactText("No listening support recorded"))
    public var terminal: TerminalState?
    public var terminalTurn: ExactText?

    init(request: RequestKey, sessionHandle: ExactText, revision: UInt64, payload: JSONValue) {
        self.request = request
        self.sessionHandle = sessionHandle
        self.revisions = [revision: payload]
        self.currentRevision = revision
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
            guard events[event.sequence] == event else { throw ConversationError.conflict }
            return
        }
        guard cursor < UInt64.max, event.sequence == cursor + 1 else {
            throw ConversationError.gap(expected: cursor == UInt64.max ? cursor : cursor + 1, received: event.sequence)
        }
        let binding = event.binding
        if case let .request(handle, payload) = event.fact {
            guard !handle.rawValue.isEmpty else { throw ConversationError.invalidBinding }
            if var thread = threads[binding.request] {
                guard thread.sessionHandle == handle else { throw ConversationError.conflict }
                if let old = thread.revisions[binding.revision] {
                    guard old == payload else { throw ConversationError.conflict }
                } else {
                    guard thread.terminal == nil, binding.revision == thread.currentRevision + 1 else {
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
        } else {
            guard var thread = threads[binding.request], thread.revisions[binding.revision] != nil else {
                throw ConversationError.missingRequest
            }
            switch event.fact {
            case .request: break
            case let .turn(turn):
                guard turn.binding == binding, turn.sessionHandle == thread.sessionHandle,
                      !turn.id.rawValue.isEmpty else { throw ConversationError.invalidBinding }
                if let old = thread.turns.first(where: { $0.id == turn.id }) {
                    guard old == turn else { throw ConversationError.conflict }
                } else {
                    guard thread.terminal == nil else { throw ConversationError.closed }
                    thread.turns.append(turn)
                    thread.facts[turn.id] = ConversationTurnFacts()
                }
                // Only an exact accepted operation clears its frozen draft.
                if let draft = thread.drafts[binding.revision], let operationID = turn.operationID {
                    switch draft.disposition {
                    case let .submitting(savedID) where savedID == operationID,
                         let .outcomeUnknown(savedID) where savedID == operationID:
                        guard draft.text == turn.text, draft.files == turn.files else { throw ConversationError.conflict }
                        thread.drafts.removeValue(forKey: binding.revision)
                    default: break
                    }
                }
            case let .availability(handle, availability):
                guard handle == thread.sessionHandle else { throw ConversationError.invalidBinding }
                thread.availability = availability
            case let .terminal(turn, _, state):
                if let terminal = thread.terminal {
                    guard terminal == state, thread.terminalTurn == turn else { throw ConversationError.conflict }
                }
                thread.terminal = state
                thread.terminalTurn = turn
                for revision in thread.drafts.keys {
                    guard var draft = thread.drafts[revision] else { continue }
                    // Ambiguous submissions stay reconcilable with their original operation identity.
                    if case .saved = draft.disposition {
                        draft.disposition = .rejected(ExactText("Not delivered: request closed"))
                        thread.drafts[revision] = draft
                    }
                }
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

    private func requireTurn(_ id: ExactText, binding: ConversationBinding, in thread: ConversationThread) throws {
        guard thread.turns.contains(where: { $0.id == id && $0.binding.request == binding.request }) else {
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
