import AttentionDomain
import Foundation

/// Where the client API v2 is served: the same scheme, host and port as the
/// device relay URL the app already holds, with every path from the root
/// (spec r2.5 section 2). `wss` becomes `https`.
public enum ClientAPIv2Endpoint {
    public static func baseURL(fromRelayURL relay: URL) -> URL? {
        guard var components = URLComponents(url: relay, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["wss", "https"].contains(scheme),
              components.host?.isEmpty == false else { return nil }
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// One account's client API v2 connection: the local model and its saved
/// cursor, the outbox, Sync over the change feed, and the answer-screen
/// rules from `GET /v2/me`. Every change to the model is published into the
/// app's repository through `ServerModelV2Presentation`, so the existing
/// screens show v2 data under the v2 rules.
///
/// A model is published only once it holds a full baseline (a cursor), so
/// the first publish is a complete inbox, never a partial one.
public final class ClientAPIv2Connection: @unchecked Sendable {
    public let model: ServerModelV2Store
    public let presentation: ServerModelV2Presentation
    public let outbox: ActionOutbox
    public let sync: ChangeFeedSync
    private let transport: any ClientAPITransport
    private let modelWriter: ServerModelSyncWriter
    private let repository: ClientRepository
    private let context: ProfileContext
    private let errors: any ErrorLogging
    private let meURL: URL?
    private let onPublished: @Sendable () -> Void
    private let meWaitBeforeRetry: @Sendable (Int) async throws -> Void
    private let lock = NSLock()

    /// `directory` holds the model, outbox and last `/v2/me` for this
    /// account; nil keeps everything in memory (tests and previews).
    public init(transport: any ClientAPITransport, repository: ClientRepository, context: ProfileContext,
                directory: URL?, errors: any ErrorLogging,
                waitBeforeRetry: @escaping @Sendable (Int) async throws -> Void = ChangeFeedSync.backoff,
                outboxWaitBeforeRetry: @escaping @Sendable (Int, TimeInterval?) async throws -> Void = ActionOutbox.backoff,
                meWaitBeforeRetry: @escaping @Sendable (Int) async throws -> Void = ChangeFeedSync.backoff,
                onLiveState: @escaping @Sendable (ChangeFeedSync.LiveState) -> Void = { _ in },
                onRejected: @escaping @Sendable (OutboxEntry, APIError) async -> Void = { _, _ in },
                onPublished: @escaping @Sendable () -> Void = {}) throws {
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let model = ServerModelV2Store(fileURL: directory?.appendingPathComponent("server-model-v2.json"))
        meURL = directory?.appendingPathComponent("me-v2.json")
        let savedMe = meURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONValue.parse($0) }.flatMap { try? APIMe(json: $0) }
        self.model = model
        self.presentation = ServerModelV2Presentation(savedMe: savedMe)
        self.transport = transport
        self.repository = repository
        self.context = context
        self.errors = errors
        self.onPublished = onPublished
        self.meWaitBeforeRetry = meWaitBeforeRetry
        let persistence: any OutboxPersisting = directory.map {
            FileOutboxPersistence(url: $0.appendingPathComponent("outbox-v2.json"))
        } ?? MemoryOutbox()
        let relay = PublishRelay()
        let modelWriter = ServerModelSyncWriter(store: model, transport: transport, errors: errors)
        self.modelWriter = modelWriter
        let writer = PublishingSyncWriter(inner: modelWriter, publish: { relay.connection?.publishModel() })
        let outcomes = PublishingOutcomes(inner: ServerModelOutboxOutcomes(store: model, onRejected: { entry, error in
            relay.connection?.recordReply(entry, disposition: .rejected(ExactText(error.token.rawValue)))
            await onRejected(entry, error)
        }, onApplied: { entry, result in
            if let turn = result.entry?.entryID {
                relay.connection?.recordReply(entry, disposition: .acceptedPendingReplay(operation: entry.id, turn: turn))
            }
        }), publish: { relay.connection?.publishModel() })
        self.outbox = try ActionOutbox(persistence: persistence, transport: transport, outcomes: outcomes,
                                       errors: errors, waitBeforeRetry: outboxWaitBeforeRetry)
        self.sync = ChangeFeedSync(transport: transport, model: writer, errors: errors,
                                   waitBeforeRetry: waitBeforeRetry, onLiveState: { state in
                                       // Each time the feed is live again, send what the outbox holds.
                                       if state == .live { relay.connection?.sendSavedWrites() }
                                       onLiveState(state)
                                   })
        relay.connection = self
    }

    /// Reads `GET /v2/me` (answerable even while the account is paused),
    /// saves it with the model and puts its rules in force.
    @discardableResult
    public func refreshMe() async throws -> APIMe {
        let response = try await transport.send(.get("/v2/me"))
        let me = try APIMe(json: JSONValue.parse(response.body))
        if let meURL {
            do {
                try response.body.write(to: meURL, options: .atomic)
                errors.resolve(concern: .snapshot, operation: "me_save")
            } catch {
                errors.report(ErrorLogReport(concern: .snapshot, connectionRole: .request, operation: "me_save",
                    phase: "save", reason: .from(error: error), initiator: .unknown, retryable: true))
            }
        }
        presentation.apply(me)
        errors.resolve(concern: .snapshot, operation: "me")
        publishModel()
        return me
    }

    /// Reads `/v2/me` until it succeeds, waiting longer after each failure:
    /// until it is read on a first run nothing can be published.
    func readMeUntilRead() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await refreshMe()
                return
            } catch {
                errors.report(ErrorLogReport(concern: .snapshot, connectionRole: .request, operation: "me",
                    phase: "read", reason: .api(error), initiator: .forFailure(error),
                    retryable: !((error as? APIError)?.isPermanent ?? false),
                    correlation: .request((error as? APIError)?.requestID), httpStatus: (error as? APIError)?.status))
                attempt += 1
                do { try await meWaitBeforeRetry(attempt) } catch { return }
            }
        }
    }

    /// Sends every saved write that is still pending, once, under its saved
    /// key; refused ones stay failed until the person retries.
    func sendSavedWrites() {
        let outbox = self.outbox
        Task { await outbox.flush() }
    }

    /// Foreground: shows the saved model at once, reads `/v2/me`, then
    /// follows the change feed until cancelled or stopped by the server.
    public func runForeground() async {
        publishModel()
        sendSavedWrites()
        // `/v2/me` is retried alongside the feed until it is read.
        let me = Task { await readMeUntilRead() }
        await sync.runForeground()
        me.cancel()
    }

    /// Push or background refresh: applies every batch from the cursor.
    public func catchUp() async throws {
        sendSavedWrites()
        try await sync.catchUp()
    }

    /// Applies a push's change batch only when its revision is newer than
    /// the durable position. The push revision is a hint, never a cursor.
    @discardableResult
    public func catchUp(forPushRevision revision: Rev) async throws -> Bool {
        let before = model.heldCursor
        if let persisted = model.persistedCursor(), persisted >= revision { return false }
        try await catchUp()
        return model.heldCursor != before
    }

    private func recordReply(_ entry: OutboxEntry, disposition: ConversationDraft.Disposition) {
        guard entry.operation == "reply" else { return }
        do {
            let threads = try repository.conversationSnapshot(context: context).threads
            guard let pair = threads.first(where: { _, thread in
                thread.queuedMessages?.contains { $0.operationID == entry.id } == true
            }) else { return }
            try repository.recordQueuedChatMessage(entry.id, in: pair.key, disposition: disposition, context: context)
        } catch {
            errors.report(ErrorLogReport(concern: .actions, connectionRole: .request,
                operation: "reply", phase: "overlay", reason: .from(error: error),
                initiator: .unknown, retryable: true))
        }
    }

    public func submitQueuedReply(_ message: ConversationDraft) async throws {
        guard let operation = message.operationID, message.files.isEmpty,
              message.binding.request.accountScope == context.identity.personID else { return }
        let reply = ClientAPIWrites.reply(itemID: message.binding.request.messageID, text: message.text)
        try await outbox.submit(target: reply.target, operation: reply.operation, write: reply.write,
                                idempotencyKey: operation)
    }

    public func loadEntriesIfNeeded(itemID: ExactText) async throws {
        guard model.snapshot.items[itemID] != nil,
              !model.snapshot.loadedEntryItems.contains(itemID) else { return }
        try await modelWriter.loadEntries(of: itemID)
        publishModel()
    }

    /// Publishes the model into the repository when it holds a full
    /// baseline and the answer-screen rules are known.
    public func publishModel() {
        lock.withLock {
            guard model.heldCursor != nil, presentation.hasRules,
                  let cached = try? presentation.cachedState(model.snapshot, identity: context.identity) else { return }
            do {
                try repository.restoreCachedServerState(cached, context: context)
            } catch {
                errors.report(ErrorLogReport(concern: .snapshot, connectionRole: .request, operation: "publish",
                    phase: "restore", reason: Self.restoreFailure(error), initiator: .unknown, retryable: true))
                return
            }
        }
        onPublished()
    }
}

extension ClientAPIv2Connection {
    /// The cause of a failed publish, by the error's case name only (never
    /// its message): for example `restore_wrong_account`.
    static func restoreFailure(_ error: any Error) -> ErrorLogReason {
        guard error is AttentionStoreError else { return .from(error: error) }
        let name = String(describing: error).prefix { $0.isLetter || $0.isNumber }
        let snake = name.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result.append("_") }
            result.append(contentsOf: character.lowercased())
        }
        return .app("restore_" + snake)
    }
}

/// Lets the components built before the connection reach it.
private final class PublishRelay: @unchecked Sendable {
    weak var connection: ClientAPIv2Connection?
}

/// Publishes after every batch and rebaseline Sync saves.
private final class PublishingSyncWriter: SyncModelWriting, @unchecked Sendable {
    private let inner: ServerModelSyncWriter
    private let publish: @Sendable () -> Void
    init(inner: ServerModelSyncWriter, publish: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.publish = publish
    }
    func syncPosition() throws -> (revision: Rev?, generation: UInt64) { try inner.syncPosition() }
    func apply(_ changes: [FeedChange], cursor: Rev, generation: UInt64) async throws {
        try await inner.apply(changes, cursor: cursor, generation: generation)
        publish()
    }
    func rebaseline() async throws -> Rev {
        let rev = try await inner.rebaseline()
        publish()
        return rev
    }
}

/// Publishes after a write's result is applied to the model.
private final class PublishingOutcomes: OutboxOutcomeHandling, @unchecked Sendable {
    private let inner: ServerModelOutboxOutcomes
    private let publish: @Sendable () -> Void
    init(inner: ServerModelOutboxOutcomes, publish: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.publish = publish
    }
    var modelGeneration: UInt64 { inner.modelGeneration }

    func accepted(_ entry: OutboxEntry, response: APIResponse, generation: UInt64) async {
        await inner.accepted(entry, response: response, generation: generation)
        publish()
    }
    func rejected(_ entry: OutboxEntry, error: APIError) async {
        await inner.rejected(entry, error: error)
    }
}

/// An outbox that lives only in memory, for tests and previews.
private final class MemoryOutbox: OutboxPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [OutboxEntry] = []
    func load() throws -> [OutboxEntry] { lock.withLock { entries } }
    func save(_ next: [OutboxEntry]) throws { lock.withLock { entries = next } }
}
