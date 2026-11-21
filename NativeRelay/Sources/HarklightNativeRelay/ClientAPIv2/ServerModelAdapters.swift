import AttentionDomain
import Foundation

/// Sync's writer over the v2 local model. A batch of feed changes and the
/// cursor are saved together. A change that cannot be read is handled by kind:
/// - an unknown (future) kind is reported and skipped;
/// - an unreadable change of a known kind may be real data the client would
///   otherwise lose, so the first one asks Sync to rebaseline from the full
///   inbox; if one recurs after that, it is reported and skipped, leaving the
///   item as it was, so Sync never wedges.
/// A rebaseline reads the full inbox.
public final class ServerModelSyncWriter: SyncModelWriting, @unchecked Sendable {
    private let store: ServerModelV2Store
    private let transport: any ClientAPITransport
    private let errors: any ErrorLogging
    private let pageLimit: Int
    private let lock = NSLock()
    /// Set once a rebaseline asked for by an unreadable change has succeeded;
    /// until then the next unreadable change asks again.
    private var rebaselinedForUnreadable = false
    private var unreadableRebaselineRequested = false

    public init(store: ServerModelV2Store, transport: any ClientAPITransport, errors: any ErrorLogging,
                pageLimit: Int = 200) {
        self.store = store
        self.transport = transport
        self.errors = errors
        self.pageLimit = pageLimit
    }

    public func syncPosition() throws -> (revision: Rev?, generation: UInt64) { store.syncPosition }

    public func apply(_ changes: [FeedChange], cursor: Rev, generation: UInt64) async throws {
        try store.apply(changes.map { ServerModelV2Store.Change(rev: $0.rev, kind: $0.kind.name, data: $0.data) },
                        cursor: cursor, generation: generation) { change, error in
            try self.unreadable(change, error)
        }
    }

    private func unreadable(_ change: ServerModelV2Store.Change, _ error: any Error) throws {
        if case .unknownKind = error as? ClientAPIModelError {
            report(change, reason: "unknown_kind", retryable: false)
            return
        }
        let firstTime = lock.withLock { () -> Bool in
            guard !rebaselinedForUnreadable else { return false }
            unreadableRebaselineRequested = true
            return true
        }
        if firstTime {
            report(change, reason: "decode_failed_rebaselining", retryable: true)
            throw SyncNeedsRebaseline()
        }
        report(change, reason: "decode_failed", retryable: false)
    }

    private func report(_ change: ServerModelV2Store.Change, reason: String, retryable: Bool) {
        errors.report(ErrorLogReport(concern: .sync, connectionRole: .stream, operation: "apply_change",
            phase: change.kind, reason: .app(reason), initiator: .unknown, retryable: retryable))
    }

    /// Reads every inbox page. The cursor is the first page's position: later
    /// pages may reflect later changes, and the feed from the first position
    /// delivers those again, harmlessly.
    public func rebaseline() async throws -> Rev {
        let expected = store.syncPosition
        var items: [APIItem] = []
        var unreadable: Set<ExactText> = []
        var first: APIInboxPage?
        var page: String?
        var seenPages: Set<String> = []
        repeat {
            var query = ["limit": String(pageLimit)]
            if let page {
                // A repeated page cursor would loop forever.
                guard seenPages.insert(page).inserted else { throw FeedDecodingError.outOfOrder }
                query["page"] = page
            }
            let response = try await transport.send(.get("/v2/inbox", query: query))
            let decoded = try APIInboxPage(json: JSONValue.parse(response.body))
            if first == nil { first = decoded }
            items += decoded.items
            for resource in decoded.unreadable {
                // Reported and skipped; its last-known copy, if any, stays.
                errors.report(ErrorLogReport(concern: .sync, connectionRole: .request, operation: "rebaseline",
                    phase: "item", reason: .app("decode_failed"), initiator: .unknown, retryable: false))
                if let id = resource.id { unreadable.insert(id) }
            }
            page = decoded.nextPage?.rawValue
        } while page != nil
        guard let first else { throw FeedDecodingError.invalidBatch }
        let result = try store.rebaseline(items: items, keeping: unreadable, counts: first.counts,
                                          position: first.position, ifUnchangedFrom: expected)
        guard result.installed else { throw SyncSnapshotSuperseded(position: result.position) }
        lock.withLock {
            if unreadableRebaselineRequested { rebaselinedForUnreadable = true }
        }
        return result.position
    }

    /// Reads an opened item's entries, newest page first and then each older
    /// page, and saves them together. An entry that cannot be read is
    /// reported with its id and the page's position and skipped; the item
    /// then stays not loaded, so its entries are read again when it is next
    /// opened (review L-16).
    public func loadEntries(of itemID: ExactText) async throws {
        let generation = store.syncPosition.generation
        var pages: [APIEntriesPage] = []
        var before: ExactText?
        var seen: Set<ExactText> = []
        var complete = false
        let path = "/v2/items/\(Self.pathSegment(itemID))/entries"
        while true {
            var query = ["limit": String(pageLimit)]
            if let before {
                // A repeated cursor would loop forever.
                guard seen.insert(before).inserted else { throw FeedDecodingError.outOfOrder }
                query["before"] = before.rawValue
            }
            let response = try await transport.send(.get(path, query: query))
            let page = try APIEntriesPage(json: JSONValue.parse(response.body))
            pages.append(page)
            for resource in page.unreadable {
                errors.report(ErrorLogReport(concern: .sync, connectionRole: .request, operation: "load_entries",
                    phase: "entry", reason: .app("decode_failed"), initiator: .unknown, retryable: false,
                    correlation: ErrorLogCorrelation(resourceID: (resource.id ?? itemID).rawValue,
                                                     rev: page.position)))
            }
            guard page.older else { complete = true; break }
            // The next page is below this page's oldest readable entry. With
            // none readable, the rest cannot be reached now.
            guard let oldest = page.entries.min(by: { $0.position < $1.position }) else { break }
            before = oldest.entryID
        }
        try store.apply(pages, of: itemID, complete: complete, generation: generation)
    }

    private static func pathSegment(_ id: ExactText) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return id.rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? id.rawValue
    }
}

/// Applies each write's response to the v2 local model at once, so the
/// person sees the outcome without waiting for the feed (which later delivers
/// the same change as a no-op).
public final class ServerModelOutboxOutcomes: OutboxOutcomeHandling, @unchecked Sendable {
    private let store: ServerModelV2Store
    private let onRejected: @Sendable (OutboxEntry, APIError) async -> Void
    private let onAcceptedResult: @Sendable (OutboxEntry, APIWriteResult) -> Void
    private let onUnreadableResponse: @Sendable (OutboxEntry, any Error) -> Void

    public init(store: ServerModelV2Store,
                onRejected: @escaping @Sendable (OutboxEntry, APIError) async -> Void,
                onAcceptedResult: @escaping @Sendable (OutboxEntry, APIWriteResult) -> Void = { _, _ in },
                onUnreadableResponse: @escaping @Sendable (OutboxEntry, any Error) -> Void = { _, _ in }) {
        self.store = store
        self.onRejected = onRejected
        self.onAcceptedResult = onAcceptedResult
        self.onUnreadableResponse = onUnreadableResponse
    }

    public var modelGeneration: UInt64 { store.syncPosition.generation }

    public func accepted(_ entry: OutboxEntry, response: APIResponse, generation: UInt64) async {
        // A file upload answers FileCreated, not a WriteResult.
        guard !response.body.isEmpty, entry.write.path != "/v2/files" else { return }
        do {
            let result = try APIWriteResult(json: JSONValue.parse(response.body))
            do {
                try store.apply(result, generation: generation)
            } catch is ServerModelV2Store.SupersededGeneration {
                // The receipt settles the durable intent independently of the
                // old resource projection, which still cannot enter the model.
            }
            onAcceptedResult(entry, result)
        } catch {
            // The write took effect; the feed delivers its resources anyway.
            onUnreadableResponse(entry, error)
        }
    }

    public func rejected(_ entry: OutboxEntry, error: APIError) async {
        await onRejected(entry, error)
    }
}

extension FeedChange.Kind {
    var name: String {
        switch self {
        case .item: "item"
        case .itemRemoved: "item_removed"
        case .entry: "entry"
        case .counts: "counts"
        case .settings: "settings"
        case let .other(name): name
        }
    }
}
