import Foundation

// Resources of the Harklight client API v2 (docs/client-api-v2.md, accepted
// edff7e9, with contract rulings rounds 2-4). Decoded from exact JSON: unknown
// members are ignored, and the sender's message content passes through
// unchanged.

public enum ClientAPIModelError: Error, Equatable {
    case invalid(String)
    case unknownKind(String)
}

/// The identifier on an attached file's FileRef, usable for download.
public struct FileDownloadID: Hashable, Codable, Sendable {
    public let value: ExactText

    public init(_ value: ExactText) { self.value = value }

    // Keep the representation of an already persisted FileRef unchanged.
    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(ExactText.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// The handle returned for a staged upload, usable for attachment or discard.
public struct UploadHandle: Hashable, Codable, Sendable {
    public let value: ExactText

    fileprivate init(_ value: ExactText) { self.value = value }
}

public struct APIFileCreated: Equatable, Sendable {
    public let handle: UploadHandle
    public let name: ExactText
    public let size: UInt64
    public let sha256: String
}

public struct APIFileRef: Equatable, Codable, Sendable {
    public let fileID: FileDownloadID
    public let name: ExactText
    public let size: UInt64
    public let sha256: String
    public let contentType: String?
}

public struct APIChat: Equatable, Codable, Sendable {
    /// Informational only; it gates nothing (chat is never closed by rule).
    public let available: Bool?
    public let started: Bool
    public let readPosition: ExactText?
    public let lastOriginReply: ExactText?
    /// Server-computed count of agent replies after the read position.
    public let unreadReplies: Int?
    /// earlier_chat_replies or earlier_chat_replies_unknown; present only
    /// while there are unread replies (the inbox draws a reply row).
    public let replyGroup: String?
    /// Where that reply row sorts, in `Rank.key`'s space.
    public let replyRankKey: ExactText?
    /// The reply row's priority: the highest level among its unseen replies,
    /// with the row's score and due time (contract round 7).
    public let replyPriority: APIPriority?
}

/// A priority as the server's view gives it: a level, with an optional score
/// and due time.
public struct APIPriority: Equatable, Codable, Sendable {
    /// now, high, normal or low.
    public let level: String?
    public let score: JSONNumber?
    public let dueAtMs: UInt64?
}

public struct APIAvailability: Equatable, Codable, Sendable {
    /// listening, not_listening, gone or unsupported. Information, never a block.
    public let state: String
    public let lastDetachedAtMs: UInt64?
}

/// The person-facing answer outcome, shown on every client of the person
/// (round 4 item 3). `value` is present only for `default`.
public struct APIAnswer: Equatable, Codable, Sendable {
    /// seen, reply, default, no_comment, choice or result.
    public let kind: String
    public let text: ExactText?
    /// Any JSON. Nil when absent; a present `null` is `.null` (round 16).
    public let value: JSONValue?
    /// For `choice` (round 15): the matched action's id and label.
    public let id: ExactText?
    public let label: ExactText?
}

public struct APITerminal: Equatable, Codable, Sendable {
    /// answered, cleared, expired, superseded or retracted.
    public let state: String
    public let atMs: UInt64
    /// Answered by any client of this person, not only this device.
    public let byThisPerson: Bool
    public let answer: APIAnswer?

    public var isNoComment: Bool { answer?.kind == "no_comment" }
}

public struct APIOriginResult: Equatable, Codable, Sendable {
    public let status: ExactText
    public let resultRef: ExactText?
    public let revision: UInt64
}

public struct APIRank: Equatable, Codable, Sendable {
    /// Sort ascending, byte-wise, for the server's inbox order.
    public let key: ExactText
    public let score: JSONNumber?
    public let dueAtMs: UInt64?
    /// current or resolved; the History heading is drawn for resolved.
    public let section: String?
    /// common or earlier_messages, for current items in free order; common
    /// has no heading.
    public let group: String?
    /// now, high, normal or low (round 15): the urgency the marks are drawn
    /// from in every order. Always present for current items.
    public var level: String? = nil
}

public struct APIItem: Equatable, Codable, Sendable {
    public let itemID: ExactText
    public let rev: UInt64
    public let sender: ExactText
    public let requestRevision: UInt64
    /// The sender's current message content, unchanged.
    public let message: JSONValue
    public let files: [APIFileRef]
    public let seen: Bool
    /// `message` or `knock` when this client is a recipient, not the origin.
    public let recipientAs: String?
    public let chat: APIChat
    public let availability: APIAvailability?
    public let terminal: APITerminal?
    public let result: APIOriginResult?
    public let rank: APIRank
    /// When the item was accepted; display only (contract round 8).
    public let createdAtMs: UInt64?
    /// Today's per-person arrival counter; the new-messages area orders by it.
    /// Absent for items from before free order, which are earlier messages.
    public let arrival: UInt64?
}

public struct APIEntryDelivery: Equatable, Codable, Sendable {
    public let delivered: Bool?
    public let acted: Bool?
}

public struct APIEntry: Equatable, Codable, Sendable {
    public let entryID: ExactText
    public let itemID: ExactText
    public let rev: UInt64
    /// Immutable creation order within the item; entries sort by it.
    public let position: UInt64
    /// reply, lifecycle (a retraction), revision or availability. Answers are
    /// read from Item.terminal, receipts from `delivery`.
    public let kind: String
    /// person, origin or server.
    public let author: String
    /// Absent on entries from before the cut-over; order by `position`.
    public let atMs: UInt64?
    public let requestRevision: UInt64
    public let text: ExactText?
    public let files: [APIFileRef]
    public let inReplyTo: ExactText?
    /// active, withdrawn or retracted; entries are never removed.
    public let state: String?
    public let terminal: APITerminal?
    public let availability: APIAvailability?
    public let delivery: APIEntryDelivery?
    /// For a `result` entry: the origin's result fact (contract round 7).
    public let result: APIOriginResult?
    /// For an agent reply: its priority from the server's view (round 7).
    public let priority: APIPriority?
}

public struct APICounts: Equatable, Codable, Sendable {
    public let unresolved: Int

    public init(unresolved: Int) { self.unresolved = unresolved }
}

/// Settings are kept as the server sent them; priority levels and push are
/// read from them where used.
public struct APISettings: Equatable, Codable, Sendable {
    public let rev: UInt64
    public let body: JSONValue
}

// MARK: Decoding

fileprivate struct Reader {
    let value: JSONValue
    let context: String

    init(_ value: JSONValue, _ context: String) throws {
        guard case .object = value, value.hasUniqueObjectKeys else {
            throw ClientAPIModelError.invalid(context)
        }
        self.value = value
        self.context = context
    }

    private func member(_ name: String) -> JSONValue? {
        guard let found = value.uniqueValue(named: name), found != .null else { return nil }
        return found
    }

    func string(_ name: String) throws -> ExactText {
        guard let text = member(name)?.stringValue else { throw ClientAPIModelError.invalid("\(context).\(name)") }
        return text
    }

    func optionalString(_ name: String) throws -> ExactText? {
        guard let found = member(name) else { return nil }
        guard let text = found.stringValue else { throw ClientAPIModelError.invalid("\(context).\(name)") }
        return text
    }

    func unsigned(_ name: String) throws -> UInt64 {
        guard let found = try optionalUnsigned(name) else { throw ClientAPIModelError.invalid("\(context).\(name)") }
        return found
    }

    func optionalUnsigned(_ name: String) throws -> UInt64? {
        guard let found = member(name) else { return nil }
        guard let integer = found.integerValue, integer >= 0 else {
            throw ClientAPIModelError.invalid("\(context).\(name)")
        }
        return UInt64(integer)
    }

    func bool(_ name: String) throws -> Bool {
        guard let found = try optionalBool(name) else { throw ClientAPIModelError.invalid("\(context).\(name)") }
        return found
    }

    func optionalBool(_ name: String) throws -> Bool? {
        guard let found = member(name) else { return nil }
        guard case let .bool(flag) = found else { throw ClientAPIModelError.invalid("\(context).\(name)") }
        return flag
    }

    func object(_ name: String) throws -> Reader {
        guard let found = member(name) else { throw ClientAPIModelError.invalid("\(context).\(name)") }
        return try Reader(found, "\(context).\(name)")
    }

    func optionalObject(_ name: String) throws -> Reader? {
        guard let found = member(name) else { return nil }
        return try Reader(found, "\(context).\(name)")
    }

    func raw(_ name: String) -> JSONValue? { member(name) }

    /// A member as sent, `null` included: nil only when it is absent.
    func present(_ name: String) -> JSONValue? { value.uniqueValue(named: name) }

    func array(_ name: String) throws -> [JSONValue] {
        guard let found = member(name) else { return [] }
        guard let values = found.arrayValues else { throw ClientAPIModelError.invalid("\(context).\(name)") }
        return values
    }
}

extension APIFileCreated {
    public init(json: JSONValue) throws {
        let reader = try Reader(json, "file_created")
        handle = try UploadHandle(reader.string("file_id"))
        name = try reader.string("name")
        size = try reader.unsigned("size")
        sha256 = try reader.string("sha256").rawValue
    }
}

extension APIFileRef {
    fileprivate init(_ reader: Reader) throws {
        fileID = try FileDownloadID(reader.string("file_id"))
        name = try reader.string("name")
        size = try reader.unsigned("size")
        sha256 = try reader.string("sha256").rawValue
        contentType = try reader.optionalString("content_type")?.rawValue
    }

    fileprivate static func list(_ values: [JSONValue], _ context: String) throws -> [APIFileRef] {
        try values.map { try APIFileRef(Reader($0, context)) }
    }
}

extension APIPriority {
    fileprivate init(_ reader: Reader) throws {
        level = try reader.optionalString("level")?.rawValue
        if let raw = reader.raw("score") {
            guard case let .number(number) = raw else { throw ClientAPIModelError.invalid("priority.score") }
            score = number
        } else {
            score = nil
        }
        dueAtMs = try reader.optionalUnsigned("due_at_ms")
    }
}

extension APIAvailability {
    fileprivate init(_ reader: Reader) throws {
        state = try reader.string("state").rawValue
        lastDetachedAtMs = try reader.optionalUnsigned("last_detached_at_ms")
    }
}

extension APIAnswer {
    fileprivate init(_ reader: Reader) throws {
        kind = try reader.string("kind").rawValue
        text = try reader.optionalString("text")
        value = reader.present("value")
        id = try reader.optionalString("id")
        label = try reader.optionalString("label")
    }
}

extension APITerminal {
    fileprivate init(_ reader: Reader) throws {
        state = try reader.string("state").rawValue
        atMs = try reader.unsigned("at_ms")
        byThisPerson = try reader.optionalBool("by_this_person") ?? false
        answer = try reader.optionalObject("answer").map(APIAnswer.init)
    }
}

extension APIItem {
    public init(json: JSONValue) throws {
        let reader = try Reader(json, "item")
        itemID = try reader.string("item_id")
        rev = try reader.unsigned("rev")
        sender = try reader.string("sender")
        requestRevision = try reader.unsigned("request_revision")
        guard let message = reader.raw("message"), case .object = message else {
            throw ClientAPIModelError.invalid("item.message")
        }
        self.message = message
        files = try APIFileRef.list(reader.array("files"), "item.files")
        seen = try reader.bool("seen")
        recipientAs = try reader.optionalString("as")?.rawValue
        let chat = try reader.object("chat")
        self.chat = APIChat(available: try chat.optionalBool("available"), started: try chat.bool("started"),
                            readPosition: try chat.optionalString("read_position"),
                            lastOriginReply: try chat.optionalString("last_origin_reply"),
                            unreadReplies: try chat.optionalUnsigned("unread_replies").map { Int($0) },
                            replyGroup: try chat.optionalString("reply_group")?.rawValue,
                            replyRankKey: try chat.optionalString("reply_rank_key"),
                            replyPriority: try chat.optionalObject("reply_priority").map(APIPriority.init))
        availability = try reader.optionalObject("availability").map(APIAvailability.init)
        terminal = try reader.optionalObject("terminal").map(APITerminal.init)
        result = try reader.optionalObject("result").map { result in
            APIOriginResult(status: try result.string("status"), resultRef: try result.optionalString("result_ref"),
                            revision: try result.unsigned("revision"))
        }
        let rank = try reader.object("rank")
        let score: JSONNumber?
        if let raw = rank.raw("score") {
            guard case let .number(number) = raw else { throw ClientAPIModelError.invalid("item.rank.score") }
            score = number
        } else {
            score = nil
        }
        self.rank = APIRank(key: try rank.string("key"), score: score,
                            dueAtMs: try rank.optionalUnsigned("due_at_ms"),
                            section: try rank.optionalString("section")?.rawValue,
                            group: try rank.optionalString("group")?.rawValue,
                            level: try rank.optionalString("level")?.rawValue)
        createdAtMs = try reader.optionalUnsigned("created_at_ms")
        arrival = try reader.optionalUnsigned("arrival")
        guard rev >= 1 else { throw ClientAPIModelError.invalid("item.rev") }
    }
}

extension APIEntry {
    public init(json: JSONValue) throws {
        let reader = try Reader(json, "entry")
        entryID = try reader.string("entry_id")
        itemID = try reader.string("item_id")
        rev = try reader.unsigned("rev")
        position = try reader.unsigned("position")
        kind = try reader.string("kind").rawValue
        author = try reader.string("author").rawValue
        atMs = try reader.optionalUnsigned("at_ms")
        requestRevision = try reader.unsigned("request_revision")
        text = try reader.optionalString("text")
        files = try APIFileRef.list(reader.array("files"), "entry.files")
        inReplyTo = try reader.optionalString("in_reply_to")
        state = try reader.optionalString("state")?.rawValue
        terminal = try reader.optionalObject("terminal").map(APITerminal.init)
        availability = try reader.optionalObject("availability").map(APIAvailability.init)
        delivery = try reader.optionalObject("delivery").map { delivery in
            APIEntryDelivery(delivered: try delivery.optionalBool("delivered"), acted: try delivery.optionalBool("acted"))
        }
        result = try reader.optionalObject("result").map { result in
            APIOriginResult(status: try result.string("status"), resultRef: try result.optionalString("result_ref"),
                            revision: try result.unsigned("revision"))
        }
        priority = try reader.optionalObject("priority").map(APIPriority.init)
        guard rev >= 1, position >= 1 else { throw ClientAPIModelError.invalid("entry.rev") }
    }
}

extension APICounts {
    public init(json: JSONValue) throws {
        let reader = try Reader(json, "counts")
        let unresolved = try reader.unsigned("unresolved")
        self.unresolved = Int(unresolved)
    }
}

extension APISettings {
    public init(json: JSONValue) throws {
        let reader = try Reader(json, "settings")
        rev = try reader.unsigned("rev")
        body = json
    }

    /// A malformed or missing table leaves the other settings usable.
    public var priorityLevels: [PriorityLevel]? {
        guard let rows = body.uniqueValue(named: "priority_levels")?.arrayValues else { return nil }
        if rows.isEmpty { return [] }
        var drafts: [PriorityLevelDraftRow] = []
        for row in rows {
            guard row.hasUniqueObjectKeys, let name = row.uniqueValue(named: "name")?.stringValue,
                  case let .number(bound)? = row.uniqueValue(named: "lower_bound"),
                  let bounce = row.uniqueValue(named: "bounce_after_days") else { return nil }
            let days: String
            switch bounce {
            case .null: days = ""
            case let .number(value): days = value.lexeme
            default: return nil
            }
            drafts.append(PriorityLevelDraftRow(name: name.rawValue, lowerBound: bound.lexeme,
                                                bounceAfterDays: days))
        }
        return PriorityLevelsTableValidation.levels(from: drafts)
    }
}

/// `{rev, items, counts, next_page?}`
/// A resource in a page that could not be read. It is reported and skipped,
/// so one bad item never stops a whole page (or a rebaseline).
public struct APIUnreadableResource: Equatable, Sendable {
    /// The resource's id when even that much could be read.
    public let id: ExactText?

    static func from(_ value: JSONValue, idMember: String) -> Self {
        Self(id: value.uniqueValue(named: idMember)?.stringValue)
    }
}

public struct APIInboxPage: Equatable, Sendable {
    public let position: UInt64
    public let items: [APIItem]
    /// Items in the page that could not be read.
    public let unreadable: [APIUnreadableResource]
    public let counts: APICounts
    public let nextPage: ExactText?

    public init(json: JSONValue) throws {
        let reader = try Reader(json, "inbox")
        position = try reader.unsigned("rev")
        var items: [APIItem] = []
        var unreadable: [APIUnreadableResource] = []
        for value in try reader.array("items") {
            if let item = try? APIItem(json: value) { items.append(item) }
            else { unreadable.append(.from(value, idMember: "item_id")) }
        }
        self.items = items
        self.unreadable = unreadable
        counts = try APICounts(json: reader.raw("counts") ?? .null)
        nextPage = try reader.optionalString("next_page")
    }
}

/// `{rev, entries, older}`
public struct APIEntriesPage: Equatable, Sendable {
    public let position: UInt64
    public let entries: [APIEntry]
    /// Entries in the page that could not be read.
    public let unreadable: [APIUnreadableResource]
    public let older: Bool

    public init(json: JSONValue) throws {
        let reader = try Reader(json, "entries")
        position = try reader.unsigned("rev")
        var entries: [APIEntry] = []
        var unreadable: [APIUnreadableResource] = []
        for value in try reader.array("entries") {
            if let entry = try? APIEntry(json: value) { entries.append(entry) }
            else { unreadable.append(.from(value, idMember: "entry_id")) }
        }
        self.entries = entries
        self.unreadable = unreadable
        older = try reader.bool("older")
    }
}

/// `{rev, item?, entry?, settings?}`: what a write changed.
public struct APIWriteResult: Equatable, Sendable {
    public let position: UInt64
    public let item: APIItem?
    public let entry: APIEntry?
    public let settings: APISettings?

    public init(json: JSONValue) throws {
        let reader = try Reader(json, "write")
        position = try reader.unsigned("rev")
        item = try reader.raw("item").map(APIItem.init(json:))
        entry = try reader.raw("entry").map(APIEntry.init(json:))
        settings = try reader.raw("settings").map(APISettings.init(json:))
    }
}

/// `GET /v2/items/{item_id}/revisions/{n}`: `{rev, revision: {request_revision, message, files}}`.
public struct APIRevision: Equatable, Sendable {
    public let position: UInt64
    public let requestRevision: UInt64
    /// That revision's message, unchanged.
    public let message: JSONValue
    public let files: [APIFileRef]

    public init(json: JSONValue) throws {
        let reader = try Reader(json, "revision")
        position = try reader.unsigned("rev")
        let revision = try reader.object("revision")
        requestRevision = try revision.unsigned("request_revision")
        guard let message = revision.raw("message"), case .object = message else {
            throw ClientAPIModelError.invalid("revision.message")
        }
        self.message = message
        files = try APIFileRef.list(revision.array("files"), "revision.files")
    }
}

/// `GET /v2/me`: the principal's facts. Members not used yet are kept raw.
public enum APIUploadCap: Equatable, Sendable {
    case bytes(UInt64)
    case unlimited
}

public struct APIMe: Equatable, Sendable {
    /// active or paused.
    public let accountState: String?
    /// Server-controlled client features still behind a flag at 0.2.
    public let features: [String: Bool]
    /// `limits.answer_ui_limits`, or nil when it is missing or incomplete.
    public let answerUILimits: SenderDocumentLimits?
    /// Nil while the server has not supplied a usable file limit.
    public let uploadCap: APIUploadCap?
    public let body: JSONValue

    public init(json: JSONValue) throws {
        let reader = try Reader(json, "me")
        accountState = try reader.optionalObject("account").flatMap { try $0.optionalString("state")?.rawValue }
        var features: [String: Bool] = [:]
        if let raw = reader.raw("features"), case let .object(members) = raw {
            for member in members { if case let .bool(on) = member.value { features[member.key.rawValue] = on } }
        }
        self.features = features
        answerUILimits = reader.raw("limits")?.uniqueValue(named: "answer_ui_limits")
            .flatMap(SenderDocumentLimits.init(answerUILimits:))
        let cap = reader.raw("limits")?.uniqueValue(named: "upload_cap_bytes_per_file")
        if cap == .string(ExactText("none")) {
            uploadCap = .unlimited
        } else if let bytes = cap?.integerValue, bytes >= 0 {
            uploadCap = .bytes(UInt64(bytes))
        } else {
            uploadCap = nil
        }
        body = json
    }
}
