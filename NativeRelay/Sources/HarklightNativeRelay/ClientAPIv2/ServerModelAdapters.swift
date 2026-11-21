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
    private var rebaselinedForUnreadable = false

    public init(store: ServerModelV2Store, transport: any ClientAPITransport, errors: any ErrorLogging,
                pageLimit: Int = 200) {
        self.store = store
        self.transport = transport
        self.errors = errors
        self.pageLimit = pageLimit
    }

    public func heldCursor() throws -> Rev? { store.heldCursor }

    public func apply(_ changes: [FeedChange], cursor: Rev) async throws {
        try store.apply(changes.map { ServerModelV2Store.Change(rev: $0.rev, kind: $0.kind.name, data: $0.data) },
                        cursor: cursor) { change, error in
            try self.unreadable(change, error)
        }
    }

    private func unreadable(_ change: ServerModelV2Store.Change, _ error: any Error) throws {
        if case .unknownKind = error as? ClientAPIModelError {
            report(change, reason: "unknown_kind", retryable: false)
            return
        }
        let firstTime = lock.withLock { () -> Bool in
            defer { rebaselinedForUnreadable = true }
            return !rebaselinedForUnreadable
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
        try store.rebaseline(items: items, keeping: unreadable, counts: first.counts, position: first.position)
        return first.position
    }
}

/// Applies each write's response to the v2 local model at once, so the
/// person sees the outcome without waiting for the feed (which later delivers
/// the same change as a no-op).
public final class ServerModelOutboxOutcomes: OutboxOutcomeHandling, @unchecked Sendable {
    private let store: ServerModelV2Store
    private let onRejected: @Sendable (OutboxEntry, APIError) async -> Void
    private let onUnreadableResponse: @Sendable (OutboxEntry, any Error) -> Void

    public init(store: ServerModelV2Store,
                onRejected: @escaping @Sendable (OutboxEntry, APIError) async -> Void,
                onUnreadableResponse: @escaping @Sendable (OutboxEntry, any Error) -> Void = { _, _ in }) {
        self.store = store
        self.onRejected = onRejected
        self.onUnreadableResponse = onUnreadableResponse
    }

    public func accepted(_ entry: OutboxEntry, response: APIResponse) async {
        // A file upload answers FileCreated, not a WriteResult.
        guard !response.body.isEmpty, entry.write.path != "/v2/files" else { return }
        do {
            try store.apply(APIWriteResult(json: JSONValue.parse(response.body)))
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
