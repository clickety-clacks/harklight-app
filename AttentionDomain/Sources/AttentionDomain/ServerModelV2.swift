import Foundation

/// What the client holds of the server under the client API v2: items,
/// their entries, counts and settings. Every resource is version-gated by its
/// `rev` (one write rule for snapshots, writes and the feed), so their order
/// never matters and duplicates are harmless. The person's own pending work
/// (drafts, outbox) lives elsewhere.
public struct ServerModelV2: Equatable, Codable, Sendable {
    public internal(set) var items: [ExactText: APIItem] = [:]
    public internal(set) var entries: [ExactText: [ExactText: APIEntry]] = [:]
    public internal(set) var counts: APICounts?
    public internal(set) var settings: APISettings?
    public internal(set) var gate = RevGate()
    /// Items whose entries were read (the person opened them). Feed entries
    /// of other items are not kept; opening an item reads its entries.
    public internal(set) var loadedEntryItems: Set<ExactText> = []

    public init() {}

    /// The inbox in the server's order: `rank.key` ascending, byte-wise.
    public var orderedItems: [APIItem] {
        items.values.sorted {
            let lhs = Array($0.rank.key.rawValue.utf8), rhs = Array($1.rank.key.rawValue.utf8)
            if lhs != rhs { return lhs.lexicographicallyPrecedes(rhs) }
            return Array($0.itemID.rawValue.utf8).lexicographicallyPrecedes(Array($1.itemID.rawValue.utf8))
        }
    }

    /// An item's entries by creation order.
    public func orderedEntries(of itemID: ExactText) -> [APIEntry] {
        (entries[itemID] ?? [:]).values.sorted { $0.position < $1.position }
    }

    /// True when an agent reply is newer than the person's read position. The
    /// server's count decides when present; otherwise entry positions do.
    public func hasUnreadReplies(_ item: APIItem) -> Bool {
        if let count = item.chat.unreadReplies { return count > 0 }
        guard let last = item.chat.lastOriginReply else { return false }
        guard let read = item.chat.readPosition else { return true }
        let held = entries[item.itemID] ?? [:]
        guard let lastPosition = held[last]?.position, let readPosition = held[read]?.position else {
            return last != read
        }
        return lastPosition > readPosition
    }

    // MARK: Writes through the gate

    private static func itemKey(_ id: ExactText) -> String { "item:\(id.rawValue)" }
    private static func entryKey(_ id: ExactText) -> String { "entry:\(id.rawValue)" }

    @discardableResult
    mutating func put(_ item: APIItem) -> Bool {
        guard gate.admit(Self.itemKey(item.itemID), rev: item.rev) else { return false }
        items[item.itemID] = item
        return true
    }

    @discardableResult
    mutating func remove(_ itemID: ExactText, rev: UInt64, at now: Date) -> Bool {
        guard gate.admitRemoval(Self.itemKey(itemID), rev: rev, at: now) else { return false }
        items[itemID] = nil
        for entryID in (entries[itemID] ?? [:]).keys { forgetEntry(entryID) }
        entries[itemID] = nil
        loadedEntryItems.remove(itemID)
        return true
    }

    @discardableResult
    mutating func put(_ entry: APIEntry, fromFeed: Bool = false) -> Bool {
        // Entries of a removed item are not kept, nor feed entries of an item
        // whose entries were never read.
        guard !gate.isRemoved(Self.itemKey(entry.itemID)) else { return false }
        if fromFeed, !loadedEntryItems.contains(entry.itemID) { return false }
        loadedEntryItems.insert(entry.itemID)
        guard gate.admit(Self.entryKey(entry.entryID), rev: entry.rev) else { return false }
        entries[entry.itemID, default: [:]][entry.entryID] = entry
        return true
    }

    mutating func put(_ counts: APICounts, rev: UInt64) {
        guard gate.admit("counts", rev: rev) else { return }
        self.counts = counts
    }

    mutating func put(_ settings: APISettings) {
        guard gate.admit("settings", rev: settings.rev) else { return }
        self.settings = settings
    }

    private mutating func forgetEntry(_ entryID: ExactText) {
        gate.forget(Self.entryKey(entryID))
    }

    /// After `410`: the full inbox (every page) at its first page's position.
    /// Items it does not list are gone; all cached entries are dropped and are
    /// fetched again when an item is opened.
    mutating func rebaseline(items fresh: [APIItem], counts: APICounts, position: UInt64, at now: Date) {
        let listed = Set(fresh.map(\.itemID))
        for itemID in Array(items.keys) where !listed.contains(itemID) {
            items[itemID] = nil
            gate.forget(Self.itemKey(itemID))
        }
        for (_, byID) in entries { for entryID in byID.keys { forgetEntry(entryID) } }
        entries = [:]
        loadedEntryItems = []
        for item in fresh { put(item) }
        gate.forget("counts")
        put(counts, rev: position)
        gate.pruneTombstones(now: now)
    }
}

extension RevGate {
    /// Drops what is held for `resource`, so the next snapshot of it applies.
    mutating func forget(_ resource: String) {
        held[resource] = nil
        removedAt[resource] = nil
    }
}

/// The durable home of `ServerModelV2` and Sync's cursor, saved together in
/// one versioned file. A file of another version, or one that cannot be read,
/// is discarded with its cursor, so Sync takes a fresh snapshot rather than
/// resuming over a model it no longer holds.
public final class ServerModelV2Store: @unchecked Sendable {
    public static let formatVersion = 1

    private struct Stored: Codable {
        let version: Int
        let cursor: UInt64?
        let model: ServerModelV2
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private var model: ServerModelV2
    private var cursor: UInt64?
    private let now: @Sendable () -> Date
    /// Saves made so far; tests use it to check one write per batch.
    public private(set) var saveCount = 0

    /// `fileURL` nil keeps the model in memory (tests, previews).
    public init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.version == Self.formatVersion {
            model = stored.model
            cursor = stored.cursor
        } else {
            model = ServerModelV2()
            cursor = nil
        }
    }

    public var snapshot: ServerModelV2 { lock.withLock { model } }
    public var heldCursor: UInt64? { lock.withLock { cursor } }

    /// One feed change as Sync delivers it.
    public struct Change: Sendable {
        public let rev: UInt64
        public let kind: String
        public let data: Data
        public init(rev: UInt64, kind: String, data: Data) {
            self.rev = rev
            self.kind = kind
            self.data = data
        }
    }

    /// Kinds this client reads. A change of any other kind (a future one) is
    /// passed to `onUnreadable` as `ClientAPIModelError.unknownKind`.
    public static let knownKinds: Set<String> = ["item", "item_removed", "entry", "counts", "settings"]

    /// Applies feed changes and records `cursor`, in one save. A change that
    /// cannot be read is passed to `onUnreadable`: returning skips it, and
    /// throwing abandons the whole batch, which saves nothing.
    public func apply(_ changes: [Change], cursor newCursor: UInt64,
                      onUnreadable: (Change, any Error) throws -> Void = { _, _ in }) throws {
        try mutate(cursor: newCursor) { model in
            for change in changes {
                do {
                    try Self.apply(change, to: &model, now: now())
                } catch {
                    try onUnreadable(change, error)
                }
            }
        }
    }

    private static func apply(_ change: Change, to model: inout ServerModelV2, now: Date) throws {
        let data = try JSONValue.parse(change.data)
        switch change.kind {
        case "item": model.put(try APIItem(json: data))
        case "item_removed":
            guard let id = data.uniqueValue(named: "item_id")?.stringValue else {
                throw ClientAPIModelError.invalid("item_removed.item_id")
            }
            model.remove(id, rev: change.rev, at: now)
        case "entry": model.put(try APIEntry(json: data), fromFeed: true)
        case "counts": model.put(try APICounts(json: data), rev: change.rev)
        case "settings": model.put(try APISettings(json: data))
        default: throw ClientAPIModelError.unknownKind(change.kind)
        }
    }

    public func apply(_ page: APIInboxPage) throws {
        try mutate { model in
            for item in page.items { model.put(item) }
            model.put(page.counts, rev: page.position)
        }
    }

    /// Entries read for an item; its later feed entries are kept from now on.
    public func apply(_ page: APIEntriesPage, of itemID: ExactText) throws {
        try mutate { model in
            model.loadedEntryItems.insert(itemID)
            for entry in page.entries { model.put(entry) }
        }
    }

    public func apply(_ result: APIWriteResult) throws {
        try mutate { model in
            if let item = result.item { model.put(item) }
            if let entry = result.entry { model.put(entry) }
            if let settings = result.settings { model.put(settings) }
        }
    }

    /// Replaces the model from a full inbox and records its position as the
    /// cursor, in one save.
    public func rebaseline(items: [APIItem], counts: APICounts, position: UInt64) throws {
        try mutate(cursor: position, replacingCursor: true) { model in
            model.rebaseline(items: items, counts: counts, position: position, at: now())
        }
    }

    private func mutate(cursor newCursor: UInt64? = nil, replacingCursor: Bool = false,
                        _ change: (inout ServerModelV2) throws -> Void) throws {
        try lock.withLock {
            var next = model
            try change(&next)
            var nextCursor = cursor
            if let newCursor {
                nextCursor = replacingCursor ? newCursor : max(cursor ?? 0, newCursor)
            }
            guard next != model || nextCursor != cursor else { return }
            if let fileURL {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let stored = Stored(version: Self.formatVersion, cursor: nextCursor, model: next)
                try JSONEncoder().encode(stored).write(to: fileURL, options: [.atomic])
            }
            saveCount += 1
            model = next
            cursor = nextCursor
        }
    }
}
