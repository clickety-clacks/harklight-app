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
    public let files: ClientAPIFiles
    public let push: ClientAPIPush
    private let transport: any ClientAPITransport
    private let foregroundOnlyWrites: Bool
    private let modelWriter: ServerModelSyncWriter
    private let repository: ClientRepository
    private let context: ProfileContext
    private let errors: any ErrorLogging
    private let meURL: URL?
    private let onPublished: @Sendable () -> Void
    private let onMe: @Sendable (APIMe) -> Void
    private let onPriorityLevelsChanged: @Sendable () -> Void
    private let meWaitBeforeRetry: @Sendable (Int) async throws -> Void
    private let replyWaitBeforeRetry: @Sendable (Int) async throws -> Void
    private let replyUploads: QueuedReplyUploads?
    private var replySignal: AsyncStream<Void>.Continuation?
    private var queuedReplySignal: AsyncStream<Void>.Continuation?
    private var checkingReplyItems: Set<ExactText> = []
    private var priorityLevelsETag: (value: String, revision: UInt64, generation: UInt64)?
    private var priorityLevelsEnabledFromServer = false
    private var settingsSignal: AsyncStream<Void>.Continuation?
    private var settingsReadID: UUID?
    private let lock = NSLock()

    /// `directory` holds the model, outbox and last `/v2/me` for this
    /// account; nil keeps everything in memory (tests and previews).
    public init(transport: any ClientAPITransport, repository: ClientRepository, context: ProfileContext,
                directory: URL?, errors: any ErrorLogging, foregroundOnlyWrites: Bool = false,
                waitBeforeRetry: @escaping @Sendable (Int) async throws -> Void = ChangeFeedSync.backoff,
                outboxWaitBeforeRetry: @escaping @Sendable (Int, TimeInterval?) async throws -> Void = ActionOutbox.backoff,
                meWaitBeforeRetry: @escaping @Sendable (Int) async throws -> Void = ChangeFeedSync.backoff,
                replyWaitBeforeRetry: @escaping @Sendable (Int) async throws -> Void = ChangeFeedSync.backoff,
                retainedUploadURL: (@Sendable (ConversationFile) throws -> URL)? = nil,
                onLiveState: @escaping @Sendable (ChangeFeedSync.LiveState) -> Void = { _ in },
                onShow: @escaping @Sendable (Data) async -> Void = { _ in },
                onRejected: @escaping @Sendable (OutboxEntry, APIError) async -> Void = { _, _ in },
                onMe: @escaping @Sendable (APIMe) -> Void = { _ in },
                onPriorityLevelsChanged: @escaping @Sendable () -> Void = {},
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
        let files = ClientAPIFiles(transport: transport)
        self.files = files
        self.replyUploads = try retainedUploadURL.map { try QueuedReplyUploads(directory: directory, files: files, source: $0) }
        self.foregroundOnlyWrites = foregroundOnlyWrites
        self.repository = repository
        self.context = context
        self.errors = errors
        self.onPublished = onPublished
        self.onMe = onMe
        self.onPriorityLevelsChanged = onPriorityLevelsChanged
        self.meWaitBeforeRetry = meWaitBeforeRetry
        self.replyWaitBeforeRetry = replyWaitBeforeRetry
        let persistence: any OutboxPersisting = directory.map {
            FileOutboxPersistence(url: $0.appendingPathComponent("outbox-v2.json"))
        } ?? MemoryOutbox()
        let relay = PublishRelay()
        self.push = ClientAPIPush(transport: transport, model: model,
                                  onSettingsChanged: { relay.connection?.publishModel() })
        let modelWriter = ServerModelSyncWriter(store: model, transport: transport, errors: errors)
        self.modelWriter = modelWriter
        let writer = PublishingSyncWriter(inner: modelWriter, publish: { relay.connection?.publishModel() })
        let outcomes = PublishingOutcomes(inner: ServerModelOutboxOutcomes(store: model, onRejected: { entry, error in
            relay.connection?.recordReply(entry, disposition: .rejected(ExactText(error.token.rawValue)))
            if entry.operation == "priority_levels" {
                await relay.connection?.rejectPriorityLevels(entry, error: error)
            }
            await onRejected(entry, error)
        }, onAcceptedResult: { entry, result in
            if let responseEntry = result.entry {
                relay.connection?.recordReply(entry, disposition: .acceptedPendingReplay(
                    operation: entry.id, turn: responseEntry.entryID))
                await relay.connection?.finishReplyUploads(entry.id)
            }
            if entry.operation == "priority_levels" {
                await relay.connection?.confirmPriorityLevels(entry, settings: result.settings)
            }
        }), publish: { relay.connection?.publishModel() })
        self.outbox = try ActionOutbox(persistence: persistence, transport: transport, outcomes: outcomes,
            errors: errors, startsPaused: foregroundOnlyWrites, canSend: { entry in
                entry.operation != "priority_levels" || relay.connection?.priorityLevelsEditingEnabled == true
            }, waitBeforeRetry: outboxWaitBeforeRetry)
        self.sync = ChangeFeedSync(transport: transport, model: writer, errors: errors,
                                   waitBeforeRetry: waitBeforeRetry, onLiveState: { state in
                                       // Each time the feed is live again, send what the outbox holds.
                                       if state == .live, !foregroundOnlyWrites {
                                           relay.connection?.sendSavedWrites()
                                       }
                                       if state == .live {
                                           relay.connection?.signalAcceptedReplyCheck()
                                           relay.connection?.signalQueuedReplies()
                                       }
                                       onLiveState(state)
                                   }, onShow: onShow)
        relay.connection = self
    }

    /// Reads `GET /v2/me` (answerable even while the account is paused),
    /// saves it with the model and puts its rules in force.
    @discardableResult
    public func refreshMe() async throws -> APIMe {
        let response = try await transport.send(.get("/v2/me"))
        try Task.checkCancellation()
        let me = try APIMe(json: JSONValue.parse(response.body))
        let principal = me.pushPrincipal.flatMap {
            $0.personID == context.identity.personID && $0.deviceID == context.identity.deviceID ? $0 : nil
        }
        do {
            try model.savePushPrincipal(principal)
            errors.resolve(concern: .snapshot, operation: "push_identity")
        } catch {
            errors.report(ErrorLogReport(concern: .snapshot, connectionRole: .request,
                operation: "push_identity", phase: "save", reason: .api(error),
                initiator: .unknown, retryable: true, correlation: .request(response.requestID)))
        }
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
        let editingEnabled = me.features["priority_level_editing"] == true
        lock.withLock {
            priorityLevelsEnabledFromServer = editingEnabled
            if !editingEnabled {
                priorityLevelsETag = nil
                settingsReadID = nil
            }
        }
        onMe(me)
        signalQueuedReplies()
        if editingEnabled {
            await recoverPendingPriorityLevels()
            await outbox.wake(operation: "priority_levels")
        }
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
            } catch where Task.isCancelled {
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
        Task { await outbox.flush() }
    }

    /// Foreground: shows the saved model at once, reads `/v2/me`, then
    /// follows the change feed until cancelled or stopped by the server.
    public func runForeground() async {
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (settings, settingsContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (queued, queuedContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            replySignal = continuation
            settingsSignal = settingsContinuation
            queuedReplySignal = queuedContinuation
            priorityLevelsEnabledFromServer = false
        }
        defer {
            lock.withLock {
                replySignal = nil
                settingsSignal = nil
                queuedReplySignal = nil
                priorityLevelsEnabledFromServer = false
            }
            continuation.finish()
            settingsContinuation.finish()
            queuedContinuation.finish()
        }
        publishModel()
        continuation.yield(())
        queuedContinuation.yield(())
        await outbox.resumeSending()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.readMeUntilRead() }
            group.addTask { await self.reconcileAcceptedRepliesWhileForeground(signals) }
            group.addTask {
                for await _ in settings { await self.refreshPriorityLevels() }
            }
            group.addTask { await self.sendQueuedRepliesWhileForeground(queued) }
            group.addTask { await self.outbox.flush() }
            await sync.runForeground()
            group.cancelAll()
            if foregroundOnlyWrites { await outbox.pauseSending() }
        }
    }

    /// Push or background refresh: applies every batch from the cursor.
    public func catchUp() async throws {
        if !foregroundOnlyWrites { sendSavedWrites() }
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

    public func matchPush(_ payload: JSONValue) -> ClientAPIPushHint? {
        guard let attention = payload.uniqueValue(named: "attention"),
              attention.uniqueValue(named: "v")?.integerValue == 2,
              attention.uniqueValue(named: "type")?.stringValue?.rawValue == "sync",
              let locator = attention.uniqueValue(named: "locator"),
              locator.uniqueValue(named: "v")?.integerValue == 2 else { return nil }
        let held = model.snapshot
        guard let principal = held.pushPrincipal,
              let device = principal.deviceID,
              let binding = held.settings?.push?.bindingID,
              !binding.rawValue.isEmpty,
              principal.personID == context.identity.personID, device == context.identity.deviceID,
              attention.uniqueValue(named: "server")?.stringValue == principal.serverID,
              locator.uniqueValue(named: "person_id")?.stringValue == principal.personID,
              locator.uniqueValue(named: "device_id")?.stringValue == device,
              locator.uniqueValue(named: "binding_id")?.stringValue == binding else {
            errors.report(ErrorLogReport(concern: .sync, connectionRole: .request,
                operation: "push_wake", phase: "match", reason: .app("push_identity_mismatch"),
                initiator: .unknown, retryable: false,
                correlation: ErrorLogCorrelation(resourceID: context.identity.deviceID.rawValue)))
            return nil
        }
        guard let item = locator.uniqueValue(named: "item_id")?.stringValue, !item.rawValue.isEmpty,
              case let .number(rev)? = locator.uniqueValue(named: "rev"),
              let revision = Rev(rev.lexeme), revision > 0 else { return nil }
        return ClientAPIPushHint(serverID: principal.serverID, personID: principal.personID,
            deviceID: device, bindingID: binding, itemID: item, revision: revision,
            target: locator.uniqueValue(named: "target")?.stringValue?.rawValue)
    }

    public func catchUp(forPush payload: JSONValue) async throws -> Bool {
        guard let hint = matchPush(payload) else { return false }
        return try await catchUp(forPushRevision: hint.revision)
    }

    private func missingAcceptedReplyItems() -> Set<ExactText> {
        let snapshot = model.snapshot
        guard let queued = try? repository.queuedChatMessages(context: context) else { return [] }
        return Set(queued.compactMap { message in
            guard case let .acceptedPendingReplay(_, turn) = message.disposition else { return nil }
            let item = message.binding.request.messageID
            guard snapshot.items[item] != nil, snapshot.entries[item]?[turn] == nil else { return nil }
            return item
        })
    }

    private func signalAcceptedReplyCheck() {
        lock.withLock { _ = replySignal?.yield(()) }
    }

    private func reconcileAcceptedRepliesWhileForeground(_ signals: AsyncStream<Void>) async {
        for await _ in signals {
            var attempt = 0
            while !Task.isCancelled {
                let items = missingAcceptedReplyItems()
                guard !items.isEmpty else { break }
                for item in items { await checkAcceptedReply(itemID: item) }
                guard !missingAcceptedReplyItems().isEmpty else { break }
                attempt += 1
                do { try await replyWaitBeforeRetry(attempt) } catch { return }
            }
        }
    }

    public func checkAcceptedReply(itemID: ExactText) async {
        guard !Task.isCancelled, missingAcceptedReplyItems().contains(itemID),
              lock.withLock({ checkingReplyItems.insert(itemID).inserted }) else { return }
        defer { lock.withLock { _ = checkingReplyItems.remove(itemID) } }
        do {
            try await modelWriter.loadEntries(of: itemID)
            publishModel()
        } catch where Task.isCancelled || error is CancellationError {
            return
        } catch {
            let api = error as? APIError
            errors.report(ErrorLogReport(concern: .snapshot, connectionRole: .request,
                operation: "confirm_reply", phase: "entries", reason: .api(error),
                initiator: .forFailure(error), retryable: true,
                correlation: ErrorLogCorrelation(requestID: api?.requestID, resourceID: itemID.rawValue),
                httpStatus: api?.status))
        }
    }

    private func recordReply(_ entry: OutboxEntry, disposition: ConversationDraft.Disposition) {
        guard entry.operation == "reply" else { return }
        do {
            guard let message = try repository.queuedChatMessages(context: context)
                .first(where: { $0.operationID == entry.id }) else { return }
            try repository.recordQueuedChatMessage(entry.id, in: message.binding.request,
                                                   disposition: disposition, context: context)
        } catch {
            errors.report(ErrorLogReport(concern: .actions, connectionRole: .request,
                operation: "reply", phase: "overlay", reason: .from(error: error),
                initiator: .unknown, retryable: true))
        }
    }

    public func signalQueuedReplies() {
        lock.withLock { queuedReplySignal?.yield(()) }
    }

    /// A saved intent is enough to wake delivery. A deliberate Retry may
    /// also re-arm an already frozen, refused outbox write.
    public func queuedReplyWasSaved(_ message: ConversationDraft) async throws {
        if let operation = message.operationID,
           let prior = await outbox.failedWrites.first(where: { $0.id == operation }) {
            try await outbox.submit(target: prior.target, operation: prior.operation, write: prior.write,
                                    idempotencyKey: operation)
        }
        signalQueuedReplies()
    }

    public func queuedReplyWasEdited(_ operation: UUID) async {
        await outbox.discardFailed(operation)
        signalQueuedReplies()
    }

    public func cancelQueuedAttachmentReply(_ operation: UUID, request: RequestKey) async throws {
        guard let replyUploads, request.accountScope == context.identity.personID else {
            throw ConversationError.missingRequest
        }
        try await replyUploads.cancelBeforeHandOff(operation) { [repository, context] in
            try repository.editQueuedChatMessage(operation, in: request, allowUnsentAttachment: true, context: context)
        }
        signalQueuedReplies()
    }

    private func sendQueuedRepliesWhileForeground(_ signals: AsyncStream<Void>) async {
        let (cleanup, cleanupSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await withTaskGroup(of: Void.self) { group in
            var items: [ExactText: AsyncStream<Void>.Continuation] = [:]
            group.addTask {
                await self.retryOnReplySignals(cleanup) { await self.discardAbandonedReplyUploads() }
            }
            for await _ in signals {
                do {
                    let queued = try repository.queuedChatMessages(context: context)
                    for item in Set(queued.map { $0.binding.request.messageID }) {
                        if let signal = items[item] {
                            signal.yield(())
                            continue
                        }
                        let (work, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                        items[item] = signal
                        signal.yield(())
                        group.addTask {
                            await self.retryOnReplySignals(work) {
                                let retry = await self.recoverQueuedReplies(for: item)
                                cleanupSignal.yield(())
                                return retry
                            }
                        }
                    }
                } catch {
                    reportReplyRecovery(error)
                }
                cleanupSignal.yield(())
            }
            for signal in items.values { signal.finish() }
            cleanupSignal.finish()
            group.cancelAll()
        }
    }

    private func retryOnReplySignals(_ signals: AsyncStream<Void>,
                                     retryWork: () async -> Bool) async {
        for await _ in signals {
            var attempt = 0
            while !Task.isCancelled, await retryWork() {
                attempt += 1
                do { try await replyWaitBeforeRetry(attempt) } catch { return }
            }
        }
    }

    private func recoverQueuedReplies(for item: ExactText) async -> Bool {
        do {
            let messages = try repository.queuedChatMessages(context: context)
                .filter { $0.binding.request.messageID == item }
                .sorted { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }
            for message in messages {
                try Task.checkCancellation()
                guard let operation = message.operationID else { continue }
                switch message.disposition {
                case .submitting, .outcomeUnknown:
                    if !message.files.isEmpty, !presentation.hasRules {
                        // Reading /me wakes this item when its rules are available.
                        return false
                    }
                    do {
                        try await submitQueuedReply(message, retryRefused: false)
                    } catch ConversationError.missingRequest {
                        // A local cancellation retired this saved intent.
                    } catch where Task.isCancelled {
                        return false
                    } catch {
                        let permanent = error is ConversationError || error is QueuedReplyError ||
                            (error as? APIError)?.isPermanent == true
                        reportUpload(error, operation: "stage_reply_upload", item: item, retryable: !permanent)
                        if permanent {
                            let reason: String
                            if case .retainedAttachmentUnavailable? = error as? ConversationError {
                                reason = "attachment_unavailable"
                            } else if case .uploadCapExceeded? = error as? ConversationError {
                                reason = APIErrorToken.payloadTooLarge.rawValue
                            } else {
                                reason = (error as? APIError)?.token.rawValue ?? "attachment_failed"
                            }
                            try repository.recordQueuedChatMessage(operation, in: message.binding.request,
                                disposition: .rejected(ExactText(reason)), context: context)
                        } else {
                            return true
                        }
                    }
                case .saved, .acceptedPendingReplay, .rejected:
                    continue
                }
            }
            return false
        } catch is CancellationError {
            return false
        } catch {
            reportReplyRecovery(error)
            return true
        }
    }

    private func discardAbandonedReplyUploads() async -> Bool {
        guard let replyUploads else { return false }
        let active = await outbox.pending.map(\.id)
        let failures = await replyUploads.discardAbandoned(keeping: Set(active)) { [repository, context] operation in
            try repository.queuedChatMessages(context: context).contains {
                $0.operationID == operation
            }
        }
        for failure in failures {
            reportUpload(failure.error, operation: "discard_reply_upload", item: failure.item,
                         retryable: failure.retryable)
        }
        return failures.contains(where: \.retryable)
    }

    private func reportReplyRecovery(_ error: any Error) {
        errors.report(ErrorLogReport(concern: .actions, connectionRole: .request,
            operation: "reply", phase: "restore", reason: .from(error: error),
            initiator: .unknown, retryable: true))
    }

    private func reportUpload(_ error: any Error, operation: String, item: ExactText, retryable: Bool) {
        let api = error as? APIError
        let reason: ErrorLogReason = (error as? ConversationError) == .retainedAttachmentUnavailable
            ? .app("attachment_unavailable") : .api(error)
        errors.report(ErrorLogReport(concern: .actions, connectionRole: .request,
            operation: operation, phase: "reply_files", reason: reason,
            initiator: .forFailure(error), retryable: retryable,
            correlation: ErrorLogCorrelation(requestID: api?.requestID, resourceID: item.rawValue),
            httpStatus: api?.status))
    }

    private func finishReplyUploads(_ operation: UUID) async {
        do {
            try await replyUploads?.accepted(operation)
        } catch {
            errors.report(ErrorLogReport(concern: .actions, connectionRole: .request,
                operation: "finish_reply_upload", phase: "save", reason: .from(error: error),
                initiator: .unknown, retryable: true))
        }
    }

    public enum QueuedReplyError: Error { case attachmentsUnavailable }

    public func submitQueuedReply(_ message: ConversationDraft, retryRefused: Bool = true) async throws {
        guard let operation = message.operationID,
              message.binding.request.accountScope == context.identity.personID else { return }
        let handles: [UploadHandle]
        if message.files.isEmpty {
            handles = []
        } else {
            let pending = await outbox.pending
            let failed = await outbox.failedWrites
            if let saved = (pending + failed).first(where: { $0.id == operation }) {
                try await outbox.submit(target: saved.target, operation: saved.operation, write: saved.write,
                                        idempotencyKey: operation, retryRefused: retryRefused)
                return
            }
            guard let replyUploads else { throw QueuedReplyError.attachmentsUnavailable }
            let stillQueued: @Sendable () throws -> Bool = { [repository, context] in
                try repository.queuedChatMessages(context: context).contains {
                    $0.operationID == operation
                }
            }
            handles = try await replyUploads.prepare(message, operation: operation, cap: presentation.uploadCap,
                                                      stillQueued: stillQueued)
            try Task.checkCancellation()
            guard try await replyUploads.handOff(operation, stillQueued: stillQueued) else { return }
        }
        let reply = ClientAPIWrites.reply(itemID: message.binding.request.messageID, text: message.text, fileIDs: handles)
        try await outbox.submit(target: reply.target, operation: reply.operation, write: reply.write,
                                idempotencyKey: operation, retryRefused: retryRefused)
    }

    private var priorityLevelsEditingEnabled: Bool {
        lock.withLock { priorityLevelsEnabledFromServer }
    }

    public var priorityLevelsCanSave: Bool {
        lock.withLock { currentPriorityLevelsETag() != nil }
    }

    /// Caller holds the connection lock.
    private func currentPriorityLevelsETag() -> String? {
        let position = model.settingsPosition
        guard priorityLevelsEnabledFromServer, let tag = priorityLevelsETag,
              tag.generation == position.generation, tag.revision == position.revision else { return nil }
        return tag.value
    }

    public var priorityLevelsEditorWasOpened: Bool {
        (try? repository.snapshot(context: context).priorityLevels.editorWasOpened) == true
    }

    public func refreshPriorityLevels() async {
        guard priorityLevelsEditingEnabled, !Task.isCancelled else { return }
        let readID = UUID()
        let generation = model.syncPosition.generation
        lock.withLock { settingsReadID = readID }
        var response: APIResponse?
        do {
            let read = try await transport.send(.get("/v2/settings"))
            response = read
            try Task.checkCancellation()
            let result = try APIWriteResult(json: JSONValue.parse(read.body))
            guard let tag = read.etag, !tag.isEmpty, let settings = result.settings,
                  let levels = settings.priorityLevels else {
                throw ClientAPIModelError.invalid("settings.priority_levels")
            }
            let current = try lock.withLock { () throws -> Bool in
                guard priorityLevelsEnabledFromServer, settingsReadID == readID else { return false }
                try model.apply(result, generation: generation)
                let position = model.settingsPosition
                guard position.generation == generation, position.revision == settings.rev else { return false }
                try repository.recordPriorityLevelsRead(levels, context: context)
                priorityLevelsETag = (tag, settings.rev, generation)
                return true
            }
            if current {
                errors.resolve(concern: .snapshot, operation: "priority_levels")
                onPriorityLevelsChanged()
            }
        } catch is CancellationError {
            return
        } catch is ServerModelV2Store.SupersededGeneration {
            return
        } catch {
            let api = error as? APIError
            errors.report(ErrorLogReport(concern: .snapshot, connectionRole: .request,
                operation: "priority_levels", phase: "read", reason: .api(error),
                initiator: .forFailure(error), retryable: true,
                correlation: .request(api?.requestID ?? response?.requestID),
                httpStatus: api?.status ?? response?.status))
        }
    }

    public func savePriorityLevels(_ levels: [PriorityLevel]) async throws {
        let operation = try lock.withLock {
            guard let tag = currentPriorityLevelsETag() else {
                throw ClientAPIModelError.invalid("settings.etag")
            }
            return try repository.beginPriorityLevelsSave(levels, context: context, ifMatch: tag)
        }
        onPriorityLevelsChanged()
        try await submitPriorityLevels(operation)
    }

    private func submitPriorityLevels(_ operation: PendingPriorityLevelsSave) async throws {
        guard let write = ClientAPIWrites.priorityLevels(operation) else { return }
        try await outbox.submit(target: write.target, operation: write.operation,
            write: write.write, idempotencyKey: operation.operationID, retryRefused: false)
    }

    private func recoverPendingPriorityLevels() async {
        do {
            guard let operation = try repository.snapshot(context: context).priorityLevels.pendingSave else { return }
            guard operation.ifMatch != nil else {
                if try repository.rejectPriorityLevelsSave(operation.operationID, reason: "unconfirmed", context: context) {
                    onPriorityLevelsChanged()
                }
                return
            }
            let refused = await outbox.failedWrites.first(where: { $0.id == operation.operationID })
            if let failure = refused?.failure {
                if try repository.rejectPriorityLevelsSave(operation.operationID, reason: failure.token, context: context) {
                    await outbox.discardFailed(operation.operationID)
                    onPriorityLevelsChanged()
                }
                if failure.status == 412 { await refreshPriorityLevels() }
                return
            }
            try await submitPriorityLevels(operation)
        } catch {
            reportPriorityLevelsPersistence(error, phase: "restore")
        }
    }

    private func invalidatePriorityLevelsETag() {
        lock.withLock {
            priorityLevelsETag = nil
            settingsReadID = nil
        }
    }

    private func rejectPriorityLevels(_ entry: OutboxEntry, error: APIError) async {
        if error.status == 412 { invalidatePriorityLevelsETag() }
        do {
            if try repository.rejectPriorityLevelsSave(entry.id, reason: error.token.rawValue, context: context) {
                await outbox.discardFailed(entry.id)
            }
        } catch {
            reportPriorityLevelsPersistence(error, phase: "reject")
        }
        onPriorityLevelsChanged()
        if error.status == 412 { await refreshPriorityLevels() }
    }

    private func confirmPriorityLevels(_ entry: OutboxEntry, settings: APISettings?) async {
        invalidatePriorityLevelsETag()
        do {
            guard let levels = settings?.priorityLevels,
                  try repository.confirmPriorityLevelsSave(entry.id, levels: levels, context: context) else {
                throw ClientAPIModelError.invalid("settings.priority_levels")
            }
        } catch {
            reportPriorityLevelsPersistence(error, phase: "confirm")
        }
        onPriorityLevelsChanged()
        await refreshPriorityLevels()
    }

    private func reportPriorityLevelsPersistence(_ error: any Error, phase: String) {
        errors.report(ErrorLogReport(concern: .actions, connectionRole: .request,
            operation: "priority_levels", phase: phase, reason: .api(error),
            initiator: .unknown, retryable: true))
    }

    public func resolveShowItem(itemID: ExactText) async throws -> APIItem? {
        if let held = model.snapshot.items[itemID] { return held }
        let generation = model.syncPosition.generation
        let path = "/v2/items/" + ServerModelSyncWriter.pathSegment(itemID)
        let response = try await transport.send(.get(path))
        let result = try APIWriteResult(json: JSONValue.parse(response.body))
        guard result.item?.itemID == itemID else { throw FeedDecodingError.invalidBatch }
        try model.apply(result, generation: generation)
        publishModel()
        return model.snapshot.items[itemID]
    }

    public func loadEntriesIfNeeded(itemID: ExactText) async throws {
        guard model.snapshot.items[itemID] != nil,
              !model.snapshot.loadedEntryItems.contains(itemID) else { return }
        try await modelWriter.loadEntries(of: itemID)
        publishModel()
    }

    /// Publishes the model into the repository when it holds a full
    /// baseline and the answer-screen rules are known.
    private func hasAcceptedRepliesAwaitingEntries() -> Bool {
        guard let messages = try? repository.queuedChatMessages(context: context) else { return true }
        return messages.contains {
            if case .acceptedPendingReplay = $0.disposition { return true }
            return false
        }
    }

    public func publishModel() {
        lock.withLock {
            if priorityLevelsEnabledFromServer, priorityLevelsETag != nil, currentPriorityLevelsETag() == nil {
                priorityLevelsETag = nil
                settingsSignal?.yield(())
            }
            guard model.heldCursor != nil, presentation.hasRules,
                  let cached = try? presentation.cachedState(model.snapshot, identity: context.identity) else { return }
            do {
                let awaitingEntries = hasAcceptedRepliesAwaitingEntries()
                try repository.restoreCachedServerState(cached, context: context, mergePriorityLevels: true)
                if awaitingEntries, !hasAcceptedRepliesAwaitingEntries() {
                    errors.resolve(concern: .snapshot, operation: "confirm_reply")
                }
            } catch {
                errors.report(ErrorLogReport(concern: .snapshot, connectionRole: .request, operation: "publish",
                    phase: "restore", reason: Self.restoreFailure(error), initiator: .unknown, retryable: true))
                return
            }
        }
        onPublished()
        signalAcceptedReplyCheck()
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
