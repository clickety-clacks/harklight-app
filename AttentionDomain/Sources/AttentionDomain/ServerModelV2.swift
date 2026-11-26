import Foundation

/// What the client holds of the server under the client API v2: items,
/// their entries, counts and settings. Every resource is version-gated by its
/// `rev` (one write rule for snapshots, writes and the feed), so their order
/// never matters and duplicates are harmless. The person's own pending work
/// (drafts, outbox) lives elsewhere.
public struct ServerModelV2: Equatable, Codable, Sendable {
    public internal(set) var items: [ExactText: APIItem] = [:]
    public internal(set) var entries: [ExactText: [ExactText: APIEntry]] = [:]
    public internal(set) var sharedServerID: ExactText?
    public internal(set) var sharedContinuation: ExactText?
    public internal(set) var counts: APICounts?
    public internal(set) var settings: APISettings?
    public internal(set) var pushPrincipal: APIPushPrincipal?
    /// A local permission decision masks the binding even if the server has
    /// not acknowledged removal or the feed repeats its last settings.
    public internal(set) var pushRoutingDisabled: Bool?
    public var routablePushBindingID: ExactText? {
        pushRoutingDisabled == true ? nil : settings?.push?.bindingID
    }
    public internal(set) var accountPaused: Bool?
    public internal(set) var gate = RevGate()
    /// Items whose entries were read (the person opened them). Feed entries
    /// of other items are not kept; opening an item reads its entries.
    public internal(set) var loadedEntryItems: Set<ExactText> = []
    /// Each held item's arrival number, assigned when the item is first held
    /// and never reused, so the new-messages area can compare it with a
    /// remembered high-water mark even after other items are removed. A
    /// removed item's number is dropped; if it comes back, it gets a new one.
    public internal(set) var arrivalOrder: [ExactText: UInt64] = [:]
    public internal(set) var lastArrival: UInt64 = 0

    /// Per-account projection bookkeeping. Nil identifies pre-contract caches,
    /// including caches written by an older App against an advertising Server.
    public internal(set) var handoffCaptionsEnabled: Bool?
    public internal(set) var handoffCaptionEntries: Set<ExactText>?

    public func needsHandoffCaptionRefresh(_ entry: APIEntry) -> Bool {
        entry.author == "person" && entry.kind == "reply" &&
            handoffCaptionEntries?.contains(entry.entryID) != true
    }

    public var handoffCaptionRefreshItems: [ExactText] {
        guard handoffCaptionsEnabled == true else { return [] }
        return orderedItems.compactMap { item in
            (entries[item.itemID] ?? [:]).values.contains(where: needsHandoffCaptionRefresh)
                ? item.itemID : nil
        }
    }

    public init() {}

    /// Items with agent chat replies whose newest reply is not held yet: the
    /// app reads their entries so reply rows can show the reply.
    public var itemsNeedingEntries: [ExactText] {
        orderedItems.compactMap { item in
            guard item.chat.replyGroup != nil, let last = item.chat.lastOriginReply,
                  entries[item.itemID]?[last] == nil else { return nil }
            return item.itemID
        }
    }

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

    mutating func discardSharedItem(_ itemID: ExactText) {
        items[itemID] = nil
        arrivalOrder[itemID] = nil
        gate.forget(Self.itemKey(itemID))
        for entryID in (entries.removeValue(forKey: itemID) ?? [:]).keys { forgetEntry(entryID) }
        loadedEntryItems.remove(itemID)
    }

    private static func itemKey(_ id: ExactText) -> String { "item:\(id.rawValue)" }
    static func itemGateKey(_ id: ExactText) -> String { itemKey(id) }
    private static func entryKey(_ id: ExactText) -> String { "entry:\(id.rawValue)" }

    /// Applies an item through the gate, for tests and previews outside the store.
    @discardableResult
    public mutating func putForTesting(_ item: APIItem) -> Bool { put(item) }

    /// Applies an entry as a feed change, for tests and previews outside the store.
    @discardableResult
    public mutating func putForTesting(_ entry: APIEntry) -> Bool { put(entry, fromFeed: true) }

    @discardableResult
    mutating func put(_ item: APIItem) -> Bool {
        guard gate.admit(Self.itemKey(item.itemID), rev: item.rev) else { return false }
        items[item.itemID] = item
        if arrivalOrder[item.itemID] == nil {
            lastArrival += 1
            arrivalOrder[item.itemID] = lastArrival
        }
        return true
    }

    @discardableResult
    mutating func remove(_ itemID: ExactText, rev: UInt64, at now: Date) -> Bool {
        guard gate.admitRemoval(Self.itemKey(itemID), rev: rev, at: now) else { return false }
        items[itemID] = nil
        arrivalOrder[itemID] = nil
        for entryID in (entries[itemID] ?? [:]).keys { forgetEntry(entryID) }
        entries[itemID] = nil
        loadedEntryItems.remove(itemID)
        return true
    }

    @discardableResult
    mutating func put(_ entry: APIEntry, fromFeed: Bool = false, refreshingCaption: Bool = false) -> Bool {
        // Entries of a removed item are not kept, nor feed entries of an item
        // whose entries were never read.
        guard !gate.isRemoved(Self.itemKey(entry.itemID)) else { return false }
        // Items with agent chat replies keep their feed entries so their reply
        // rows can show the reply; other unopened items wait for the read on
        // open. Only a full entries page marks an item loaded.
        if fromFeed, !loadedEntryItems.contains(entry.itemID),
           items[entry.itemID]?.chat.replyGroup == nil { return false }
        let sameRevisionRefresh = refreshingCaption && handoffCaptionsEnabled == true &&
            needsHandoffCaptionRefresh(entry) && entries[entry.itemID]?[entry.entryID]?.rev == entry.rev
        guard sameRevisionRefresh || gate.admit(Self.entryKey(entry.entryID), rev: entry.rev) else { return false }
        entries[entry.itemID, default: [:]][entry.entryID] = entry
        if handoffCaptionsEnabled == true {
            if handoffCaptionEntries == nil { handoffCaptionEntries = [] }
            handoffCaptionEntries?.insert(entry.entryID)
        } else {
            handoffCaptionEntries?.remove(entry.entryID)
        }
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
        handoffCaptionEntries?.remove(entryID)
        gate.forget(Self.entryKey(entryID))
    }

    /// After `410`: the full inbox (every page) at its first page's position.
    /// Items it does not list are gone; all cached entries are dropped and are
    /// fetched again when an item is opened.
    /// `keeping` lists items the inbox named but the client could not read:
    /// their last-known copy stays rather than disappearing.
    mutating func rebaseline(items fresh: [APIItem], keeping unreadable: Set<ExactText> = [], counts: APICounts,
                             position: UInt64, at now: Date, resetsHistory: Bool) {
        if resetsHistory {
            gate = RevGate()
            settings = nil
        }
        let listed = Set(fresh.map(\.itemID)).union(unreadable)
        for itemID in Array(items.keys) where !listed.contains(itemID) {
            items[itemID] = nil
            gate.forget(Self.itemKey(itemID))
        }
        // Arrival numbers are kept only for held items (review L-18);
        // `lastArrival` never goes back, so a number is never reused.
        arrivalOrder = arrivalOrder.filter { items[$0.key] != nil }
        for (_, byID) in entries { for entryID in byID.keys { forgetEntry(entryID) } }
        entries = [:]
        loadedEntryItems = []
        // New items get arrival numbers in the order they first reached the person.
        for item in fresh.sorted(by: { ($0.createdAtMs ?? 0, $0.itemID.rawValue) < ($1.createdAtMs ?? 0, $1.itemID.rawValue) }) {
            put(item)
        }
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
    /// 2: arrival order. An older file is discarded with its cursor.
    public static let formatVersion = 2

    private struct Stored: Codable {
        let version: Int
        let cursor: UInt64?
        let generation: UInt64?
        let model: ServerModelV2
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private var model: ServerModelV2
    private var cursor: UInt64?
    private var generation: UInt64 = 0
    private var sealed = false
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
            generation = stored.generation ?? 0
        } else {
            model = ServerModelV2()
            cursor = nil
        }
    }

    public var snapshot: ServerModelV2 { lock.withLock { model } }

    public func setHandoffCaptionsEnabled(_ enabled: Bool) throws {
        try lock.withLock {
            guard (model.handoffCaptionsEnabled ?? false) != enabled else { return }
            try mutateLocked(cursor: nil, replacingCursor: false) { $0.handoffCaptionsEnabled = enabled }
        }
    }

    /// Change projection scope before issuing a new baseline. The generation
    /// fences requests begun under the previous scope, including old SSE.
    @discardableResult
    public func configureSharedMessages(serverID: ExactText?) throws -> Bool {
        try lock.withLock {
            guard model.sharedServerID != serverID else { return false }
            try mutateLocked(cursor: nil, replacingCursor: true) { model in
                for item in model.orderedItems where item.shared != nil {
                    model.discardSharedItem(item.itemID)
                }
                model.sharedServerID = serverID
                model.sharedContinuation = nil
                model.counts = nil
            }
            return true
        }
    }

    public func seal() { lock.withLock { sealed = true } }

    public func saveAccountPause(_ paused: Bool) throws {
        try mutate { $0.accountPaused = paused ? true : nil }
    }
    public var heldCursor: UInt64? { lock.withLock { cursor } }

    public var syncPosition: (revision: UInt64?, generation: UInt64) {
        lock.withLock { (cursor, generation) }
    }

    public struct SupersededGeneration: Error { public init() {} }

    /// The position in the saved model. An in-memory model cannot prove that
    /// a push revision has already been persisted.
    public func persistedCursor() -> UInt64? {
        struct Header: Decodable {
            let version: Int
            let cursor: UInt64?
        }
        return lock.withLock {
            guard let fileURL, let bytes = try? Data(contentsOf: fileURL),
                  let header = try? JSONDecoder().decode(Header.self, from: bytes),
                  header.version == Self.formatVersion else { return nil }
            return header.cursor
        }
    }

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

    /// Settings revision and history generation from the same model snapshot.
    public var settingsPosition: (revision: UInt64?, generation: UInt64) {
        lock.withLock { (model.settings?.rev, generation) }
    }

    public func savePushPrincipal(_ principal: APIPushPrincipal?) throws {
        try mutate { $0.pushPrincipal = principal }
    }

    public func setPushRoutingEnabled(_ enabled: Bool) throws {
        try mutate { $0.pushRoutingDisabled = enabled ? nil : true }
    }

    /// Applies feed changes and records `cursor`, in one save. A change that
    /// cannot be read is passed to `onUnreadable`: returning skips it, and
    /// throwing abandons the whole batch, which saves nothing.
    public func apply(_ changes: [Change], cursor newCursor: UInt64, generation expectedGeneration: UInt64? = nil,
                      onUnreadable: (Change, any Error) throws -> Void = { _, _ in }) throws {
        try mutate(cursor: newCursor, generation: expectedGeneration) { model in
            for change in changes {
                do {
                    try Self.apply(change, to: &model, now: now())
                } catch {
                    try onUnreadable(change, error)
                    Self.degrade(after: change, in: &model)
                }
            }
        }
    }

    /// After an unreadable change is skipped, nothing may look complete that is
    /// not: an item whose entry was skipped is read again on open, and an
    /// unreadable removal leaves a later snapshot of that item free to apply.
    private static func degrade(after change: Change, in model: inout ServerModelV2) {
        guard let value = try? JSONValue.parse(change.data),
              let itemID = value.uniqueValue(named: "item_id")?.stringValue else { return }
        switch change.kind {
        case "entry": model.loadedEntryItems.remove(itemID)
        case "item_removed": model.gate.forget(ServerModelV2.itemGateKey(itemID))
        default: break
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
    /// A page with an unreadable entry leaves the item not loaded, so its
    /// entries are read again when it is next opened.
    public func apply(_ page: APIEntriesPage, of itemID: ExactText) throws {
        try apply([page], of: itemID, complete: true)
    }

    /// Every page read for an item, in one save. The item counts as loaded
    /// only when the pages reach its oldest entry (`complete`) and none of
    /// them held an unreadable entry.
    public func apply(_ pages: [APIEntriesPage], of itemID: ExactText, complete: Bool,
                      generation: UInt64? = nil) throws {
        try mutate(generation: generation) { model in
            model.loadedEntryItems.insert(itemID)
            for page in pages { for entry in page.entries {
                model.put(entry, refreshingCaption: true)
            } }
            if !complete || pages.contains(where: { !$0.unreadable.isEmpty }) {
                model.loadedEntryItems.remove(itemID)
            }
        }
    }

    public func apply(_ result: APIWriteResult, generation: UInt64? = nil) throws {
        try mutate(generation: generation) { model in
            if let item = result.item { model.put(item) }
            if let entry = result.entry { model.put(entry) }
            if let settings = result.settings { model.put(settings) }
        }
    }

    /// Replaces the model from a full inbox and records its position as the
    /// cursor, in one save.
    public func rebaseline(items: [APIItem], keeping unreadable: Set<ExactText> = [], counts: APICounts,
                           position: UInt64, continuation: ExactText? = nil) throws {
        try lock.withLock {
            try installBaseline(items: items, keeping: unreadable, counts: counts, position: position,
                                continuation: continuation)
        }
    }

    /// Installs a snapshot only if Sync has held the same position since the
    /// read began. A reset may legitimately have a lower first-page position.
    public func rebaseline(items: [APIItem], keeping unreadable: Set<ExactText>, counts: APICounts,
                           position: UInt64, continuation: ExactText? = nil, ifUnchangedFrom expected: (revision: UInt64?, generation: UInt64))
        throws -> (position: UInt64, installed: Bool) {
        try lock.withLock {
            if generation != expected.generation || cursor != expected.revision {
                return (cursor ?? 0, false)
            }
            try installBaseline(items: items, keeping: unreadable, counts: counts, position: position,
                                continuation: continuation)
            return (position, true)
        }
    }

    private func installBaseline(items: [APIItem], keeping unreadable: Set<ExactText>, counts: APICounts,
                                 position: UInt64, continuation: ExactText?) throws {
        guard (model.sharedServerID != nil) == (continuation?.rawValue.isEmpty == false) else {
            throw ClientAPIModelError.invalid("inbox.continuation")
        }
        let resetsHistory = cursor.map { position < $0 } ?? false
        try mutateLocked(cursor: position, replacingCursor: true) { model in
            model.sharedContinuation = continuation
            model.rebaseline(items: items, keeping: unreadable, counts: counts, position: position,
                             at: now(), resetsHistory: resetsHistory)
        }
    }

    private func mutate(cursor newCursor: UInt64? = nil, replacingCursor: Bool = false, generation expectedGeneration: UInt64? = nil,
                        _ change: (inout ServerModelV2) throws -> Void) throws {
        try lock.withLock {
            if let expectedGeneration, expectedGeneration != generation { throw SupersededGeneration() }
            try mutateLocked(cursor: newCursor, replacingCursor: replacingCursor, change)
        }
    }

    private func mutateLocked(cursor newCursor: UInt64?, replacingCursor: Bool,
                              _ change: (inout ServerModelV2) throws -> Void) throws {
        guard !sealed else { throw CancellationError() }
        var next = model
        try change(&next)
        let nextCursor = replacingCursor ? newCursor : newCursor.map { max(cursor ?? 0, $0) } ?? cursor
        let nextGeneration = replacingCursor ? generation + 1 : generation
        guard next != model || nextCursor != cursor || nextGeneration != generation else { return }
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let stored = Stored(version: Self.formatVersion, cursor: nextCursor, generation: nextGeneration, model: next)
            try JSONEncoder().encode(stored).write(to: fileURL, options: [.atomic])
        }
        saveCount += 1
        model = next
        cursor = nextCursor
        generation = nextGeneration
    }
}
