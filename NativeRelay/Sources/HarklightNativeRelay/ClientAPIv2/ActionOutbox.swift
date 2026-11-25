import Foundation

/// One user mutation exactly as it will be sent, frozen at intent.
public struct FrozenWrite: Codable, Equatable, Sendable {
    public let method: APIRequest.Method
    public let path: String
    public let body: Data?
    public let contentType: String?
    public let ifMatch: String?

    public init(method: APIRequest.Method, path: String, body: Data? = nil, contentType: String? = nil,
                ifMatch: String? = nil) {
        self.method = method
        self.path = path
        self.body = body
        self.contentType = contentType ?? (body == nil ? nil : "application/json")
        self.ifMatch = ifMatch
    }
}

public struct OutboxEntry: Codable, Equatable, Sendable, Identifiable {
    /// Sent as `Idempotency-Key`. Never changes, across retries and launches.
    public let idempotencyKey: UUID
    /// Operations on the same target (an item, or the settings) are sent in
    /// intent order; different targets in parallel.
    public let target: String
    /// The Error Log operation name, for example `mark_seen` or `answer`.
    public let operation: String
    public let write: FrozenWrite
    public let createdAt: Date
    /// True once a send ended without a known outcome; the resend uses the
    /// same key, so the server applies it at most once.
    public internal(set) var outcomeUnknown: Bool
    public internal(set) var attempts: Int
    /// Answers outside the contract (a 4xx without a contract body) so far;
    /// transient failures do not count. Optional for saved outboxes.
    public internal(set) var outsideContractFailures: Int? = nil
    /// Set when the server refused the write. The write stays in the outbox,
    /// shown as failed, until the app discards it; it is never dropped silently.
    public internal(set) var failure: OutboxFailure? = nil
    /// The repository's stable answer intent, distinct from the HTTP key.
    public internal(set) var answerIntentID: UUID? = nil

    /// The server may already have committed this write. Wait for an explicit
    /// retry or a foreground transition, keeping this exact request and key.
    public internal(set) var waitsForInternalErrorRetry: Bool? = nil

    public var id: UUID { idempotencyKey }

    /// Seen and read-position reports are independently monotonic facts. A
    /// slow reply must not hold either report for the same item.
    var sendingLane: String {
        switch operation {
        case "mark_seen", "read_position": "\(operation):\(target)"
        default: target
        }
    }

    /// The item an `item:<id>` target is about, for the Error Log.
    var resourceID: String? {
        target.hasPrefix("item:") ? String(target.dropFirst("item:".count)) : nil
    }

    var request: APIRequest {
        APIRequest(method: write.method, path: write.path, body: write.body, contentType: write.contentType,
                   idempotencyKey: idempotencyKey, ifMatch: write.ifMatch)
    }
}

public struct OutboxFailure: Codable, Equatable, Sendable {
    public let status: Int
    public let token: String
}

public protocol OutboxPersisting: Sendable {
    func load() throws -> [OutboxEntry]
    func save(_ entries: [OutboxEntry]) throws
}

/// What the app does with an operation's outcome. Both calls run before the
/// operation leaves the outbox.
public protocol OutboxOutcomeHandling: Sendable {
    /// The model generation at the start of this HTTP attempt.
    var modelGeneration: UInt64 { get }
    /// Applies the write's response (the changed resources at their new `rev`)
    /// through the version gate. A replayed response counts as the original.
    func accepted(_ entry: OutboxEntry, response: APIResponse, generation: UInt64) async
    /// A definitive refusal, shown on the item the person acted on.
    func rejected(_ entry: OutboxEntry, error: APIError) async
    /// The outcome is ambiguous and the saved write is waiting for deliberate retry.
    func pausedForInternalError(_ entry: OutboxEntry)
}

public extension OutboxOutcomeHandling {
    func pausedForInternalError(_ entry: OutboxEntry) {}
}

private struct ProtectedWriteOutcome: OutboxOutcomeHandling {
    var modelGeneration: UInt64 { 0 }
    func accepted(_ entry: OutboxEntry, response: APIResponse, generation: UInt64) async {}
    func rejected(_ entry: OutboxEntry, error: APIError) async {}
}

/// Actions (design section 4) over the r2 API: the durable outbox. Writes
/// never wait for, or depend on, Sync or the change feed.
public actor ActionOutbox {
    private let persistence: any OutboxPersisting
    private let transport: any ClientAPITransport
    private let outcomes: any OutboxOutcomeHandling
    private let errors: any ErrorLogging
    private let waitBeforeRetry: @Sendable (_ attempt: Int, _ retryAfter: TimeInterval?) async throws -> Void
    private let canSend: @Sendable (OutboxEntry) -> Bool
    private let onEntriesChanged: @Sendable ([OutboxEntry], [OutboxEntry]) -> Void
    private var entries: [OutboxEntry] {
        didSet { onEntriesChanged(oldValue, entries) }
    }
    private var sendingTasks: [String: Task<Void, Never>] = [:]
    private var sendingPaused: Bool
    private var closed = false
    private var resendRequested: Set<String> = []
    private var retryTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Set when the server refused this device's authentication or the account
    /// is paused; nothing is sent, and queued operations are kept until
    /// re-enrolment or the end of the pause.
    public private(set) var unauthorized = false

    public init(persistence: any OutboxPersisting, transport: any ClientAPITransport,
                outcomes: any OutboxOutcomeHandling, errors: any ErrorLogging,
                startsPaused: Bool = false, canSend: @escaping @Sendable (OutboxEntry) -> Bool = { _ in true },
                excludingSavedKeys: Set<UUID> = [],
                onEntriesChanged: @escaping @Sendable ([OutboxEntry], [OutboxEntry]) -> Void = { _, _ in },
                waitBeforeRetry: @escaping @Sendable (_ attempt: Int, _ retryAfter: TimeInterval?) async throws -> Void
                    = ActionOutbox.backoff) throws {
        self.persistence = persistence
        self.transport = transport
        self.outcomes = outcomes
        self.errors = errors
        self.waitBeforeRetry = waitBeforeRetry
        self.canSend = canSend
        self.onEntriesChanged = onEntriesChanged
        sendingPaused = startsPaused
        let saved = try persistence.load()
        let admitted = saved.filter { !excludingSavedKeys.contains($0.id) }
        if admitted.count != saved.count { try persistence.save(admitted) }
        entries = admitted
    }

    public static let backoff: @Sendable (Int, TimeInterval?) async throws -> Void = { attempt, retryAfter in
        let seconds = retryAfter ?? Double(min(60, 1 << min(attempt, 6)))
        try await Task.sleep(for: .seconds(seconds))
    }

    /// The pending overlay: operations not yet accepted or refused.
    public var pending: [OutboxEntry] { entries.filter { $0.failure == nil } }

    /// Writes the server refused, kept so the person sees them as failed.
    public var failedWrites: [OutboxEntry] { entries.filter { $0.failure != nil } }

    /// Removes a failed write once the app has shown or replaced it.
    public func discardFailed(_ key: UUID) {
        guard !closed else { return }
        guard let discarded = entries.first(where: { $0.id == key && $0.failure != nil }) else { return }
        remove(key)
        resolveIfNoFailedWrite(discarded.operation, resolvedBy: "discarded")
    }

    /// A refusal stays unresolved in the Error Log while any write of that
    /// operation is still held as failed (review L-17).
    private func resolveIfNoFailedWrite(_ operation: String, resolvedBy: String? = nil) {
        guard !entries.contains(where: {
            $0.operation == operation && ($0.failure != nil || $0.waitsForInternalErrorRetry == true)
        }) else { return }
        errors.resolve(concern: .actions, operation: operation, resolvedBy: resolvedBy)
    }

    /// Records the intent durably, minting its key once, and sends it. If the
    /// record cannot be saved, nothing is sent and the error is thrown.
    @discardableResult
    /// `idempotencyKey` is the operation id minted when the person acted, when
    /// the app already saved one (for example a queued chat message).
    public func submit(target: String, operation: String, write: FrozenWrite,
                       idempotencyKey: UUID = UUID(), now: Date = Date(),
                       retryRefused: Bool = true, answerIntentID: UUID? = nil,
                       replacingPausedWrite: UUID? = nil,
                       stillPending: @Sendable () throws -> Bool = { true }) async throws -> OutboxEntry {
        guard !closed else { throw CancellationError() }
        if let existing = entries.first(where: { $0.idempotencyKey == idempotencyKey }) {
            // Handing a pending write over again queues it once. Handing over
            // a refused one is the person's Retry: the server stores only
            // successes, so the same key is evaluated again.
            guard retryRefused, existing.failure != nil || existing.waitsForInternalErrorRetry == true
            else { return existing }
            var next = entries
            guard let index = next.firstIndex(where: { $0.id == existing.id }) else { return existing }
            next[index].failure = nil
            next[index].outsideContractFailures = nil
            next[index].waitsForInternalErrorRetry = nil
            try persistence.save(next)
            entries = next
            startSending(existing.sendingLane)
            return next[index]
        }
        guard try stillPending() else { throw CancellationError() }
        let entry = OutboxEntry(idempotencyKey: idempotencyKey, target: target, operation: operation, write: write,
                                createdAt: now, outcomeUnknown: false, attempts: 0, answerIntentID: answerIntentID)
        var next = entries
        if let replacingPausedWrite {
            guard let index = next.firstIndex(where: {
                $0.id == replacingPausedWrite && $0.target == target && $0.operation == operation &&
                    $0.waitsForInternalErrorRetry == true
            }) else { throw CancellationError() }
            next[index] = entry
        } else {
            next.append(entry)
        }
        try persistence.save(next)
        entries = next
        startSending(entry.sendingLane)
        return entry
    }

    /// Sends everything queued, each target in order and targets in parallel,
    /// and returns once every target has stopped (empty or waiting to retry).
    public func flush() async {
        let tasks = Set(pending.map(\.sendingLane)).compactMap { startSending($0) }
        for task in tasks { await task.value }
    }

    func retryInternalErrors(operation: String? = nil, id: UUID? = nil) async {
        var retryLanes = Set<String>()
        for entry in entries where entry.waitsForInternalErrorRetry == true &&
            (operation == nil || entry.operation == operation) && (id == nil || entry.id == id) {
            update(entry.id) { $0.waitsForInternalErrorRetry = nil }
            retryLanes.insert(entry.sendingLane)
        }
        let tasks = retryLanes.compactMap { startSending($0) }
        for task in tasks { await task.value }
    }

    func wake(operation: String) {
        for target in Set(pending.filter { $0.operation == operation }.map(\.sendingLane)) {
            startSending(target)
        }
    }

    public func resumeSending() {
        guard !closed else { return }
        sendingPaused = false
    }

    public func close() async {
        closed = true
        await pauseSending()
    }

    public func pauseSending() async {
        sendingPaused = true
        for retry in retryTasks.values { retry.task.cancel() }
        retryTasks.removeAll()
        let tasks = Array(sendingTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    /// Clears the refusal after the device is enrolled again.
    public func resumeAfterReenrolment() async {
        unauthorized = false
        await flush()
    }

    /// The enrollment has already persisted the complete intent in Keychain.
    /// Use the same send and refusal handling without copying it to the file
    /// outbox. The caller owns the lifetime of this attempt and future replay.
    static func attemptProtectedWrite(_ write: FrozenWrite, key: UUID, operation: String,
                                      transport: any ClientAPITransport,
                                      errors: any ErrorLogging) async throws -> APIResponse {
        let outbox = try ActionOutbox(persistence: MemoryOutbox(), transport: transport,
                                      outcomes: ProtectedWriteOutcome(), errors: errors, startsPaused: true)
        let entry = try await outbox.submit(target: "push", operation: operation, write: write, idempotencyKey: key)
        try Task.checkCancellation()
        return try await outbox.sendOne(entry).result.get()
    }

    @discardableResult
    private func startSending(_ target: String) -> Task<Void, Never>? {
        guard !sendingPaused, !unauthorized else { return nil }
        guard sendingTasks[target] == nil else {
            resendRequested.insert(target)
            return nil
        }
        let task = Task { await self.send(target) }
        sendingTasks[target] = task
        return task
    }

    private func send(_ target: String) async {
        defer { sendingTasks[target] = nil }
        guard !sendingPaused, !unauthorized, !Task.isCancelled else { return }
        // A retry waiting for its time is replaced by this send. A retry that
        // is itself calling send removed its own entry first, so it is never
        // cancelled here.
        retryTasks.removeValue(forKey: target)?.task.cancel()
        repeat {
            resendRequested.remove(target)
            while !sendingPaused, !Task.isCancelled,
                  let entry = entries.first(where: { $0.sendingLane == target && $0.failure == nil }) {
                guard entry.waitsForInternalErrorRetry != true, canSend(entry) else { return }
                guard await sendOne(entry).continueDraining else { return }
            }
        } while resendRequested.contains(target)
    }

    /// The target waits when its head operation is kept for a retry.
    private func sendOne(_ entry: OutboxEntry) async
        -> (continueDraining: Bool, result: Result<APIResponse, any Error>) {
        noteAttempt(entry.idempotencyKey)
        do {
            let generation = outcomes.modelGeneration
            let response = try await transport.send(entry.request)
            await outcomes.accepted(entry, response: response, generation: generation)
            remove(entry.idempotencyKey)
            resolveIfNoFailedWrite(entry.operation)
            return (true, .success(response))
        } catch let error as APIError where error.token == .internalError {
            update(entry.idempotencyKey) {
                $0.waitsForInternalErrorRetry = true
                $0.outcomeUnknown = true
            }
            report(entry, phase: "send", error: error, initiator: .serverClosed, retryable: false)
            outcomes.pausedForInternalError(entry)
            return (false, .failure(error))
        } catch let error as APIError where error.token == .accountPaused {
            // Kept until the pause ends; nothing is refused or dropped.
            unauthorized = true
            report(entry, phase: "send", error: error, initiator: .serverClosed, retryable: false)
            return (false, .failure(error))
        } catch let error where ChangeFeedSync.isRevocation(error) {
            unauthorized = true
            report(entry, phase: "send", error: error, initiator: .deviceRevoked, retryable: false)
            return (false, .failure(error))
        } catch let error as APIError where error.isPermanent || (error.isOutsideContractClientError &&
                    noteOutsideContractFailure(entry.idempotencyKey) >= Self.outsideContractAttempts) {
            // A contract refusal is definitive at once. A 4xx outside the
            // contract (no contract body) is retried a few times, then given
            // up, so it cannot block that item's later writes forever. Either
            // way the write stays visible as failed. The failure and its Error
            // Log record exist before the app is told, so a refusal the person
            // sees always has its record, and a Retry handed over at once
            // finds the write already failed.
            update(entry.idempotencyKey) {
                $0.failure = OutboxFailure(status: error.status, token: error.token.rawValue)
            }
            report(entry, phase: "send", error: error, initiator: .unknown, retryable: false)
            await outcomes.rejected(entry, error: error)
            return (true, .failure(error))
        } catch where Task.isCancelled {
            markOutcomeUnknown(entry.idempotencyKey, transportFailure: true)
            return (false, .failure(error))
        } catch {
            // Unknown outcome or retry later: keep the operation and its key.
            markOutcomeUnknown(entry.idempotencyKey, transportFailure: !(error is APIError))
            report(entry, phase: "send", error: error, initiator: .forFailure(error), retryable: true)
            scheduleRetry(entry.sendingLane, attempt: entries.first { $0.id == entry.id }?.attempts ?? 1,
                          retryAfter: (error as? APIError)?.retryAfter)
            return (false, .failure(error))
        }
    }

    private func scheduleRetry(_ target: String, attempt: Int, retryAfter: TimeInterval?) {
        guard !sendingPaused else { return }
        retryTasks[target]?.task.cancel()
        let wait = waitBeforeRetry
        let id = UUID()
        let task = Task {
            do { try await wait(attempt, retryAfter) } catch { return }
            guard await self.takeRetry(target, id: id) else { return }
            self.startSending(target)
        }
        retryTasks[target] = (id, task)
    }

    /// The retry whose time has come leaves the table before sending, so the
    /// send does not cancel the task it runs in.
    private func takeRetry(_ target: String, id: UUID) -> Bool {
        guard retryTasks[target]?.id == id else { return false }
        retryTasks[target] = nil
        return true
    }

    /// Tries before a 4xx answer outside the contract counts as a refusal.
    static let outsideContractAttempts = 3

    /// Counts one more answer outside the contract and returns the total.
    private func noteOutsideContractFailure(_ key: UUID) -> Int {
        update(key) { $0.outsideContractFailures = ($0.outsideContractFailures ?? 0) + 1 }
        return entries.first { $0.id == key }?.outsideContractFailures ?? 0
    }

    private func noteAttempt(_ key: UUID) {
        update(key) { $0.attempts += 1 }
    }

    private func markOutcomeUnknown(_ key: UUID, transportFailure: Bool) {
        guard transportFailure else { return }
        update(key) { $0.outcomeUnknown = true }
    }

    private func update(_ key: UUID, _ change: (inout OutboxEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == key }) else { return }
        var next = entries
        change(&next[index])
        // A failed save keeps the in-memory state; the key is unchanged either way.
        try? persistence.save(next)
        entries = next
    }

    private func remove(_ key: UUID) {
        let next = entries.filter { $0.id != key }
        try? persistence.save(next)
        entries = next
    }

    private func report(_ entry: OutboxEntry, phase: String, error: any Error, initiator: ErrorLogInitiator,
                        retryable: Bool) {
        errors.report(ErrorLogReport(concern: .actions, connectionRole: .request, operation: entry.operation,
            phase: phase, reason: .api(error), initiator: initiator, retryable: retryable,
            correlation: ErrorLogCorrelation(clientOperationID: entry.idempotencyKey,
                                             requestID: (error as? APIError)?.requestID,
                                             resourceID: entry.resourceID),
            httpStatus: (error as? APIError)?.status))
    }
}

/// The outbox in one JSON file, written atomically.
public final class FileOutboxPersistence: OutboxPersisting, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func load() throws -> [OutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([OutboxEntry].self, from: Data(contentsOf: url))
    }

    public func save(_ entries: [OutboxEntry]) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: [.atomic])
    }
}
