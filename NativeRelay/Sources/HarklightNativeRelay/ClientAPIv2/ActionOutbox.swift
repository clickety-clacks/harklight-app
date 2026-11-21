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

    public var id: UUID { idempotencyKey }

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
    /// Applies the write's response (the changed resources at their new `rev`)
    /// through the version gate. A replayed response counts as the original.
    func accepted(_ entry: OutboxEntry, response: APIResponse) async
    /// A definitive refusal, shown on the item the person acted on.
    func rejected(_ entry: OutboxEntry, error: APIError) async
}

/// Actions (design section 4) over the r2 API: the durable outbox. Writes
/// never wait for, or depend on, Sync or the change feed.
public actor ActionOutbox {
    private let persistence: any OutboxPersisting
    private let transport: any ClientAPITransport
    private let outcomes: any OutboxOutcomeHandling
    private let errors: any ErrorLogging
    private let waitBeforeRetry: @Sendable (_ attempt: Int, _ retryAfter: TimeInterval?) async throws -> Void
    private var entries: [OutboxEntry]
    private var sendingTargets: Set<String> = []
    private var resendRequested: Set<String> = []
    private var retryTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Set when the server refused this device's authentication or the account
    /// is paused; nothing is sent, and queued operations are kept until
    /// re-enrolment or the end of the pause.
    public private(set) var unauthorized = false

    public init(persistence: any OutboxPersisting, transport: any ClientAPITransport,
                outcomes: any OutboxOutcomeHandling, errors: any ErrorLogging,
                waitBeforeRetry: @escaping @Sendable (_ attempt: Int, _ retryAfter: TimeInterval?) async throws -> Void
                    = ActionOutbox.backoff) throws {
        self.persistence = persistence
        self.transport = transport
        self.outcomes = outcomes
        self.errors = errors
        self.waitBeforeRetry = waitBeforeRetry
        entries = try persistence.load()
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
        guard entries.contains(where: { $0.id == key && $0.failure != nil }) else { return }
        remove(key)
    }

    /// Records the intent durably, minting its key once, and sends it. If the
    /// record cannot be saved, nothing is sent and the error is thrown.
    @discardableResult
    /// `idempotencyKey` is the operation id minted when the person acted, when
    /// the app already saved one (for example a queued chat message).
    public func submit(target: String, operation: String, write: FrozenWrite,
                       idempotencyKey: UUID = UUID(), now: Date = Date()) async throws -> OutboxEntry {
        if let existing = entries.first(where: { $0.idempotencyKey == idempotencyKey }) { return existing }
        let entry = OutboxEntry(idempotencyKey: idempotencyKey, target: target, operation: operation, write: write,
                                createdAt: now, outcomeUnknown: false, attempts: 0)
        var next = entries
        next.append(entry)
        try persistence.save(next)
        entries = next
        startSending(entry.target)
        return entry
    }

    /// Sends everything queued, each target in order and targets in parallel,
    /// and returns once every target has stopped (empty or waiting to retry).
    public func flush() async {
        let targets = Set(pending.map(\.target))
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask { await self.send(target) }
            }
        }
    }

    /// Clears the refusal after the device is enrolled again.
    public func resumeAfterReenrolment() async {
        unauthorized = false
        await flush()
    }

    private func startSending(_ target: String) {
        Task { await self.send(target) }
    }

    private func send(_ target: String) async {
        guard !unauthorized else { return }
        guard sendingTargets.insert(target).inserted else {
            resendRequested.insert(target)
            return
        }
        defer { sendingTargets.remove(target) }
        // A retry waiting for its time is replaced by this send. A retry that
        // is itself calling send removed its own entry first, so it is never
        // cancelled here.
        retryTasks.removeValue(forKey: target)?.task.cancel()
        repeat {
            resendRequested.remove(target)
            while let entry = entries.first(where: { $0.target == target && $0.failure == nil }) {
                guard await sendOne(entry) else { return }
            }
        } while resendRequested.contains(target)
    }

    /// Returns false when the target must wait (its head operation is kept).
    private func sendOne(_ entry: OutboxEntry) async -> Bool {
        noteAttempt(entry.idempotencyKey)
        do {
            let response = try await transport.send(entry.request)
            await outcomes.accepted(entry, response: response)
            remove(entry.idempotencyKey)
            errors.resolve(concern: .actions, operation: entry.operation)
            return true
        } catch let error as APIError where error.token == .accountPaused {
            // Kept until the pause ends; nothing is refused or dropped.
            unauthorized = true
            report(entry, phase: "send", error: error, initiator: .serverClosed, retryable: false)
            return false
        } catch let error where ChangeFeedSync.isRevocation(error) {
            unauthorized = true
            report(entry, phase: "send", error: error, initiator: .deviceRevoked, retryable: false)
            return false
        } catch let error as APIError where error.isPermanent || (error.isOutsideContractClientError &&
                    noteOutsideContractFailure(entry.idempotencyKey) >= Self.outsideContractAttempts) {
            // A contract refusal is definitive at once. A 4xx outside the
            // contract (no contract body) is retried a few times, then given
            // up, so it cannot block that item's later writes forever. Either
            // way the write stays visible as failed.
            await outcomes.rejected(entry, error: error)
            update(entry.idempotencyKey) {
                $0.failure = OutboxFailure(status: error.status, token: error.token.rawValue)
            }
            report(entry, phase: "send", error: error, initiator: .unknown, retryable: false)
            return true
        } catch {
            // Unknown outcome or retry later: keep the operation and its key.
            markOutcomeUnknown(entry.idempotencyKey, transportFailure: !(error is APIError))
            report(entry, phase: "send", error: error, initiator: .forFailure(error), retryable: true)
            scheduleRetry(entry.target, attempt: entries.first { $0.id == entry.id }?.attempts ?? 1,
                          retryAfter: (error as? APIError)?.retryAfter)
            return false
        }
    }

    private func scheduleRetry(_ target: String, attempt: Int, retryAfter: TimeInterval?) {
        retryTasks[target]?.task.cancel()
        let wait = waitBeforeRetry
        let id = UUID()
        let task = Task {
            do { try await wait(attempt, retryAfter) } catch { return }
            guard await self.takeRetry(target, id: id) else { return }
            await self.send(target)
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
            correlation: .request((error as? APIError)?.requestID, operationID: entry.idempotencyKey),
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
