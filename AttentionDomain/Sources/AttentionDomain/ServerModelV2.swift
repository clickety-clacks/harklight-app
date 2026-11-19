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
        return true
    }

    @discardableResult
    mutating func put(_ entry: APIEntry) -> Bool {
        // Entries of a removed item are not kept.
        guard !gate.isRemoved(Self.itemKey(entry.itemID)) else { return false }
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

/// The durable home of `ServerModelV2`. Every change is saved before the call
/// returns, which is what lets Sync advance its cursor afterwards.
public final class ServerModelV2Store: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL?
    private var model: ServerModelV2
    private let now: @Sendable () -> Date

    /// `fileURL` nil keeps the model in memory (tests, previews).
    public init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.fileURL = fileURL
        self.now = now
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            model = try JSONDecoder().decode(ServerModelV2.self, from: Data(contentsOf: fileURL))
        } else {
            model = ServerModelV2()
        }
    }

    public var snapshot: ServerModelV2 { lock.withLock { model } }

    /// Applies one feed change. Unknown kinds are ignored.
    public func apply(kind: String, rev: UInt64, data: JSONValue) throws {
        try mutate { model in
            switch kind {
            case "item": model.put(try APIItem(json: data))
            case "item_removed":
                guard let id = data.uniqueValue(named: "item_id")?.stringValue else {
                    throw ClientAPIModelError.invalid("item_removed.item_id")
                }
                model.remove(id, rev: rev, at: now())
            case "entry": model.put(try APIEntry(json: data))
            case "counts": model.put(try APICounts(json: data), rev: rev)
            case "settings": model.put(try APISettings(json: data))
            default: break
            }
        }
    }

    public func apply(_ page: APIInboxPage) throws {
        try mutate { model in
            for item in page.items { model.put(item) }
            model.put(page.counts, rev: page.position)
        }
    }

    public func apply(_ page: APIEntriesPage) throws {
        try mutate { model in for entry in page.entries { model.put(entry) } }
    }

    public func apply(_ result: APIWriteResult) throws {
        try mutate { model in
            if let item = result.item { model.put(item) }
            if let entry = result.entry { model.put(entry) }
            if let settings = result.settings { model.put(settings) }
        }
    }

    public func rebaseline(items: [APIItem], counts: APICounts, position: UInt64) throws {
        try mutate { model in model.rebaseline(items: items, counts: counts, position: position, at: now()) }
    }

    private func mutate(_ change: (inout ServerModelV2) throws -> Void) throws {
        try lock.withLock {
            var next = model
            try change(&next)
            if next != model, let fileURL {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(next).write(to: fileURL, options: [.atomic])
            }
            model = next
        }
    }
}
