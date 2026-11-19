import AttentionDomain
import Foundation

/// Sync's writer over the v2 local model. A batch of feed changes and the
/// cursor are saved together; a change that cannot be read is reported to the
/// Error Log and skipped, so the item it describes is degraded (left as it
/// was) rather than stopping Sync. A rebaseline reads the full inbox.
public final class ServerModelSyncWriter: SyncModelWriting, @unchecked Sendable {
    private let store: ServerModelV2Store
    private let transport: any ClientAPITransport
    private let errors: any ErrorLogging
    private let pageLimit: Int

    public init(store: ServerModelV2Store, transport: any ClientAPITransport, errors: any ErrorLogging,
                pageLimit: Int = 200) {
        self.store = store
        self.transport = transport
        self.errors = errors
        self.pageLimit = pageLimit
    }

    public func heldCursor() throws -> Rev? { store.heldCursor }

    public func apply(_ changes: [FeedChange], cursor: Rev) async throws {
        let errors = errors
        try store.apply(changes.map { ServerModelV2Store.Change(rev: $0.rev, kind: $0.kind.name, data: $0.data) },
                        cursor: cursor) { change, error in
            errors.report(ErrorLogReport(concern: .sync, connectionRole: .stream, operation: "apply_change",
                phase: change.kind, reason: .app("decode_failed"), initiator: .unknown, retryable: false))
            _ = error
        }
    }

    /// Reads every inbox page. The cursor is the first page's position: later
    /// pages may reflect later changes, and the feed from the first position
    /// delivers those again, harmlessly.
    public func rebaseline() async throws -> Rev {
        var items: [APIItem] = []
        var first: APIInboxPage?
        var page: String?
        repeat {
            var query = ["limit": String(pageLimit)]
            if let page { query["page"] = page }
            let response = try await transport.send(.get("/v2/inbox", query: query))
            let decoded = try APIInboxPage(json: JSONValue.parse(response.body))
            if first == nil { first = decoded }
            items += decoded.items
            page = decoded.nextPage?.rawValue
        } while page != nil
        guard let first else { throw FeedDecodingError.invalidBatch }
        try store.rebaseline(items: items, counts: first.counts, position: first.position)
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
