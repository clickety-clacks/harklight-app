import Foundation

// The Error Log: one durable, redacted record of failures that no concern can
// clear. Concerns call `report` and `resolve` on `ErrorLogging`; nothing can
// delete a record. Reading or copying a record never consumes it.
//
// Public surface for other components: `ErrorLogging`, `ErrorLogReport`,
// `ErrorLogReason`, `ErrorLogCorrelation` and the vocabulary enums. The store,
// display rules and copy format below are used by the UI only.

// MARK: - Vocabulary

public enum ErrorLogConcern: String, Codable, Sendable, CaseIterable {
    case snapshot
    case sync
    case actions
}

public enum ErrorLogConnectionRole: String, Codable, Sendable {
    case stream
    case request
}

/// Who ended a connection or operation. Required on any cancel, abort or close.
public enum ErrorLogInitiator: String, Codable, Sendable, CaseIterable {
    case user
    case appLifecycle = "app_lifecycle"
    case osNetwork = "os_network"
    case supersededByNewStream = "superseded_by_new_stream"
    case deviceRevoked = "device_revoked"
    case serverClosed = "server_closed"
    case timeout
    case unknown

    /// Maps a server close-reason token to an initiator: the change feed's
    /// `closing` reasons (`revoked`, `server_shutdown`, `idle_timeout`) and the
    /// earlier stream-close tokens. Anything unrecognised is `serverClosed`.
    /// The token itself is kept separately as `ErrorLogReason.serverReason`.
    public init(serverCloseReason token: String) {
        switch token {
        case "superseded_by_new_stream": self = .supersededByNewStream
        case "device_revoked", "revoked": self = .deviceRevoked
        default: self = .serverClosed
        }
    }
}

/// App version, build number and short commit, as shown in a copied record.
public struct ErrorLogBuild: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let commit: String

    private enum CodingKeys: String, CodingKey { case version, build, commit }

    /// Decoding goes through the same redaction as `init`.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try values.decode(String.self, forKey: .version),
                  build: try values.decode(String.self, forKey: .build),
                  commit: try values.decode(String.self, forKey: .commit))
    }

    public init(version: String, build: String, commit: String) {
        self.version = ErrorLogRedactor.buildField(version)
        self.build = ErrorLogRedactor.buildField(build)
        self.commit = ErrorLogRedactor.buildField(commit == "unavailable" ? commit : String(commit.prefix(7)))
    }

    public static let unavailable = ErrorLogBuild(version: "unavailable", build: "unavailable",
                                                  commit: "unavailable")
}

/// Safe identifiers only. Each is a UUID or a server-issued token that passed
/// the safe-ID check; nothing else can be stored here.
public struct ErrorLogCorrelation: Codable, Equatable, Sendable {
    public var attemptID: UUID?
    public var transportAttemptID: UUID?
    public var serverConnectionID: String?
    public var clientOperationID: UUID?
    /// The server's `Request-Id` response header (opaque, safe to log).
    public var requestID: String?

    public init(attemptID: UUID? = nil, transportAttemptID: UUID? = nil,
                serverConnectionID: String? = nil, clientOperationID: UUID? = nil,
                requestID: String? = nil) {
        self.attemptID = attemptID
        self.transportAttemptID = transportAttemptID
        self.serverConnectionID = serverConnectionID.flatMap(ErrorLogRedactor.safeID)
        self.clientOperationID = clientOperationID
        self.requestID = requestID.flatMap(ErrorLogRedactor.safeID)
    }

    public static let none = ErrorLogCorrelation()

    var isEmpty: Bool {
        attemptID == nil && transportAttemptID == nil && serverConnectionID == nil &&
            clientOperationID == nil && requestID == nil
    }
}

/// What failed, as a domain and code. Built only through the constructors
/// below, so no free-form text can reach the log.
public struct ErrorLogReason: Codable, Equatable, Sendable {
    public let domain: String
    public let code: String

    private init(domain: String, code: String) {
        self.domain = domain
        self.code = code
    }

    public static func posix(_ code: Int) -> Self { Self(domain: "POSIX", code: String(code)) }
    public static func urlError(_ code: Int) -> Self { Self(domain: "URLError", code: String(code)) }
    public static func cocoa(_ code: Int) -> Self { Self(domain: "Cocoa", code: String(code)) }
    public static func osStatus(_ code: Int) -> Self { Self(domain: "OSStatus", code: String(code)) }

    /// A reason token the server sent. Kept only if it is on the allowlist;
    /// anything else becomes `other`, so free-form server text is never stored.
    public static func serverReason(_ token: String) -> Self {
        Self(domain: "server_reason",
             code: ErrorLogRedactor.allowedServerReasons.contains(token) ? token : "other")
    }

    /// A token chosen by the app itself, such as `decode_failed`. It must look
    /// like a lowercase identifier; anything else becomes `other`.
    public static func app(_ token: String) -> Self {
        Self(domain: "app", code: ErrorLogRedactor.identifier(token) ?? "other")
    }

    /// Classifies a system error by domain and numeric code only. The error's
    /// message, userInfo and underlying errors are never read.
    public static func from(error: Error) -> Self {
        if error is CancellationError { return .app("cancelled") }
        let value = error as NSError
        switch value.domain {
        case NSURLErrorDomain: return .urlError(value.code)
        case NSPOSIXErrorDomain: return .posix(value.code)
        case NSCocoaErrorDomain: return .cocoa(value.code)
        case "NSOSStatusErrorDomain": return .osStatus(value.code)
        default: return .app("other")
        }
    }
}

/// What a concern hands to `report`. The log adds the record id, build,
/// timestamps and count, and redacts every field.
public struct ErrorLogReport: Sendable {
    public var concern: ErrorLogConcern
    public var connectionRole: ErrorLogConnectionRole
    public var operation: String
    public var phase: String
    public var reason: ErrorLogReason
    public var initiator: ErrorLogInitiator
    public var retryable: Bool
    public var correlation: ErrorLogCorrelation
    /// The HTTP status of the failed response, when there was one.
    public var httpStatus: Int?
    public var occurredAt: Date?

    public init(concern: ErrorLogConcern,
                connectionRole: ErrorLogConnectionRole,
                operation: String,
                phase: String,
                reason: ErrorLogReason,
                initiator: ErrorLogInitiator = .unknown,
                retryable: Bool,
                correlation: ErrorLogCorrelation = .none,
                httpStatus: Int? = nil,
                occurredAt: Date? = nil) {
        self.concern = concern
        self.connectionRole = connectionRole
        self.operation = operation
        self.phase = phase
        self.reason = reason
        self.initiator = initiator
        self.retryable = retryable
        self.correlation = correlation
        self.httpStatus = httpStatus.flatMap(ErrorLogRedactor.httpStatus)
        self.occurredAt = occurredAt
    }
}

/// The stable interface other components depend on. Both calls are
/// synchronous, never throw and never block on the network; a failing log
/// write is absorbed (the log keeps records in memory).
public protocol ErrorLogging: Sendable {
    func report(_ report: ErrorLogReport)
    /// Marks every unresolved record of `concern` at `operation` resolved by the
    /// concern's next success. The records and all their fields are kept.
    func resolve(concern: ErrorLogConcern, operation: String, resolvedBy: String?)
}

public extension ErrorLogging {
    func resolve(concern: ErrorLogConcern, operation: String) {
        resolve(concern: concern, operation: operation, resolvedBy: nil)
    }
}

/// For components that have no log to report to (tests, previews).
public struct NoopErrorLog: ErrorLogging {
    public init() {}
    public func report(_ report: ErrorLogReport) {}
    public func resolve(concern: ErrorLogConcern, operation: String, resolvedBy: String?) {}
}

// MARK: - Record

public struct ErrorLogRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public internal(set) var lastAt: Date
    public internal(set) var count: Int
    public let build: ErrorLogBuild
    public let concern: ErrorLogConcern
    public let connectionRole: ErrorLogConnectionRole
    public let operation: String
    public internal(set) var phase: String
    public internal(set) var domain: String
    public let code: String
    public internal(set) var initiator: ErrorLogInitiator
    public internal(set) var retryable: Bool
    public internal(set) var correlation: ErrorLogCorrelation
    public internal(set) var httpStatus: Int?
    public internal(set) var resolvedAt: Date?
    public internal(set) var resolvedBy: String?

    public var isResolved: Bool { resolvedAt != nil }
}

// MARK: - Redaction

/// Allowlist redaction. Credentials, tokens, URLs, message text, file names,
/// display names and free-form server text have no field to live in; every
/// string that does reach a record passes through here.
public enum ErrorLogRedactor {
    /// Reason tokens the server may send. Anything else is stored as `other`.
    public static let allowedServerReasons: Set<String> = [
        "unreachable", "timeout", "unauthorized", "server_error", "decode_failed", "unsupported",
        "wrong_connection_role", "retry_later", "stale_revision", "cursor_expired", "storage_unavailable",
        "superseded_by_new_stream", "device_revoked", "rejected", "unresolved", "ack_refused",
        "apply_failed", "stream_closed", "superseded", "not_found", "invalid_request", "rate_limited",
        "internal_error", "unavailable", "forbidden", "conflict",
        // Client API error tokens.
        "not_found", "invalid_field", "stale_request", "already_answered", "already_retracted",
        "idempotency_conflict", "precondition_failed", "payload_too_large",
        // Change-feed `closing` reasons.
        "revoked", "server_shutdown", "idle_timeout", "account_paused"
    ]

    /// A real HTTP status code, or nil.
    static func httpStatus(_ value: Int) -> Int? { (100...599).contains(value) ? value : nil }

    /// A lowercase snake_case token, at most 48 characters, with no long digit
    /// or hex runs. Returns nil when the text does not fit.
    static func identifier(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= 48,
              let first = text.utf8.first, (97...122).contains(first),
              text.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 })
        else { return nil }
        var digitRun = 0
        var hexRun = 0
        for byte in text.utf8 {
            digitRun = (48...57).contains(byte) ? digitRun + 1 : 0
            hexRun = ((48...57).contains(byte) || (97...102).contains(byte)) ? hexRun + 1 : 0
            if digitRun >= 8 || hexRun >= 16 { return nil }
        }
        return text
    }

    static func operationToken(_ text: String) -> String { identifier(text) ?? "other" }

    /// A server-issued opaque identifier such as a `Request-Id`: up to 128
    /// characters (the contract's OpaqueId maximum) of letters, digits and
    /// `- _ . : ~ = + /`. Whitespace, `?`, `#`, `&`, `@` and `%` are refused, so
    /// a URL with a query, an address or a sentence cannot pass as an id.
    static func safeID(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= 128,
              text.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                      [45, 95, 46, 58, 126, 61, 43, 47].contains($0)
              }) else { return nil }
        return text
    }

    /// A short id the app itself supplies (such as an attempt UUID): letters,
    /// digits, `-`, `_`, at most 64 characters.
    static func simpleID(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= 64,
              text.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                      $0 == 45 || $0 == 95
              }) else { return nil }
        return text
    }

    /// Build fields are version-like text: digits, letters, dots and dashes.
    static func buildField(_ text: String) -> String {
        guard !text.isEmpty, text.utf8.count <= 40,
              text.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                      $0 == 45 || $0 == 46 || $0 == 95
              }) else { return "unavailable" }
        return text
    }

    /// The numeric-domain codes must be integers; everything else was already
    /// shaped by `ErrorLogReason`'s constructors. This guards decoded files.
    static func reasonCode(domain: String, code: String) -> String {
        switch domain {
        case "POSIX", "URLError", "Cocoa", "OSStatus":
            return Int(code) != nil ? code : "other"
        case "server_reason":
            return allowedServerReasons.contains(code) || code == "other" ? code : "other"
        default:
            return identifier(code) ?? "other"
        }
    }

    static func domainToken(_ domain: String) -> String {
        ["POSIX", "URLError", "Cocoa", "OSStatus", "server_reason", "app"].contains(domain) ? domain : "app"
    }
}

// MARK: - Store

/// Persistent store for error records.
///
/// Records are kept in memory and written to a file in the background: a
/// change schedules one write on a private queue (repeated changes within the
/// write delay share it), so callers never wait on disk. `flush()` forces the
/// pending write and is called when the app goes to the background.
///
/// A file this store could not read is never overwritten. A file that is
/// unreadable for now (for example before first unlock) is retried on later
/// writes and merged with what is in memory; a file that is corrupt or from an
/// unknown version is moved aside, and the move is the only thing done to it.
/// If the file cannot be written the log carries on in memory and tries again.
///
/// Retention keeps the last `minimumRetainedCount` records or every record
/// from the last `retentionInterval`, whichever is more, and evicts resolved
/// records first. `maximumRetainedCount` bounds a flapping failure that
/// resolves and fails again many times inside the window.
public final class ErrorLogStore: ErrorLogging, @unchecked Sendable {
    public enum PersistenceStatus: Equatable, Sendable {
        case new
        case saved
        /// The file could not be read or written; records are held in memory.
        case memoryFallback(cause: String)
    }

    public static let minimumRetainedCount = 100
    public static let maximumRetainedCount = 500
    public static let retentionInterval: TimeInterval = 14 * 24 * 3600

    private struct StoredFile: Codable {
        let version: Int
        let records: [ErrorLogRecord]
    }

    private enum LoadResult {
        case absent
        case loaded([ErrorLogRecord])
        /// Present but not readable right now; may become readable.
        case unreadable
        /// Present and readable but not a log this build can use.
        case unusable(cause: String)
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private let build: ErrorLogBuild
    private let now: @Sendable () -> Date
    private let writeDelay: TimeInterval
    private let writeQueue = DispatchQueue(label: "harklight.error-log.write", qos: .utility)
    private var stored: [ErrorLogRecord] = []
    private var status: PersistenceStatus = .new
    private var changeHandler: (@Sendable () -> Void)?
    /// True while the file on disk has not been read into `stored`.
    private var fileNeedsReading = false
    private var writeScheduled = false
    private var lastWriteStarted = Date.distantPast

    public init(fileURL: URL?, build: ErrorLogBuild, writeDelay: TimeInterval = 0.3,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.build = build
        self.now = now
        self.writeDelay = writeDelay
        loadAtStart()
    }

    public static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Harklight", isDirectory: true)
            .appendingPathComponent("error-log-v1.json", isDirectory: false)
    }

    // MARK: Reading (never consumes)

    /// Every record, newest first by last occurrence.
    public var records: [ErrorLogRecord] {
        lock.lock(); defer { lock.unlock() }
        return stored.sorted { $0.lastAt > $1.lastAt }
    }

    public var persistenceStatus: PersistenceStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    /// Called after every change, on whatever thread made it.
    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock(); changeHandler = handler; lock.unlock()
    }

    /// Writes any pending change now and returns when it is done.
    public func flush() {
        writeQueue.sync { self.performWrite() }
    }

    // MARK: ErrorLogging

    public func report(_ report: ErrorLogReport) {
        lock.lock()
        let at = report.occurredAt ?? now()
        let operation = ErrorLogRedactor.operationToken(report.operation)
        let phase = ErrorLogRedactor.operationToken(report.phase)
        let domain = ErrorLogRedactor.domainToken(report.reason.domain)
        let code = ErrorLogRedactor.reasonCode(domain: domain, code: report.reason.code)
        let operationID = report.correlation.clientOperationID
        // Repeats of the same (concern, operation, domain, code, client
        // operation) coalesce into the newest unresolved record. A failure after
        // a resolution is a new record.
        if let index = stored.indices.last(where: {
            let record = stored[$0]
            return !record.isResolved && record.concern == report.concern &&
                record.operation == operation && record.domain == domain && record.code == code &&
                record.correlation.clientOperationID == operationID
        }) {
            stored[index].lastAt = max(stored[index].lastAt, at)
            stored[index].count += 1
            stored[index].phase = phase
            stored[index].initiator = report.initiator
            stored[index].retryable = report.retryable
            stored[index].httpStatus = report.httpStatus ?? stored[index].httpStatus
            if !report.correlation.isEmpty { stored[index].correlation = report.correlation }
        } else {
            stored.append(ErrorLogRecord(
                id: UUID(), occurredAt: at, lastAt: at, count: 1, build: build,
                concern: report.concern, connectionRole: report.connectionRole,
                operation: operation, phase: phase, domain: domain, code: code,
                initiator: report.initiator, retryable: report.retryable,
                correlation: report.correlation, httpStatus: report.httpStatus,
                resolvedAt: nil, resolvedBy: nil))
        }
        applyRetention()
        let handler = changeHandler
        scheduleWriteLocked()
        lock.unlock()
        handler?()
    }

    public func resolve(concern: ErrorLogConcern, operation: String, resolvedBy: String?) {
        let token = ErrorLogRedactor.operationToken(operation)
        let by = resolvedBy.flatMap { ErrorLogRedactor.simpleID($0) ?? ErrorLogRedactor.identifier($0) } ?? "success"
        lock.lock()
        let at = now()
        var changed = false
        for index in stored.indices where !stored[index].isResolved &&
            stored[index].concern == concern && stored[index].operation == token {
            stored[index].resolvedAt = at
            stored[index].resolvedBy = by
            changed = true
        }
        guard changed else { lock.unlock(); return }
        applyRetention()
        let handler = changeHandler
        scheduleWriteLocked()
        lock.unlock()
        handler?()
    }

    // MARK: Retention (lock held)

    private func applyRetention() {
        let cutoff = now().addingTimeInterval(-Self.retentionInterval)
        let recent = stored.filter { $0.lastAt >= cutoff }.count
        let budget = min(max(Self.minimumRetainedCount, recent), Self.maximumRetainedCount)
        guard stored.count > budget else { return }
        // Resolved records go first, oldest first; then the oldest unresolved.
        let evictionOrder = stored.sorted { lhs, rhs in
            if lhs.isResolved != rhs.isResolved { return lhs.isResolved }
            return lhs.lastAt < rhs.lastAt
        }
        let evicted = Set(evictionOrder.prefix(stored.count - budget).map(\.id))
        stored.removeAll { evicted.contains($0.id) }
    }

    // MARK: Loading

    private func readFile(at url: URL) -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain && value.code == CocoaError.fileReadNoSuchFile.rawValue {
                return .absent
            }
            return .unreadable
        }
        guard let file = try? Self.decoder.decode(StoredFile.self, from: data) else {
            return .unusable(cause: "unreadable_format")
        }
        guard file.version == 1 else { return .unusable(cause: "unsupported_version") }
        // Re-apply the redaction rules to whatever was on disk.
        return .loaded(file.records.map(Self.sanitized))
    }

    private func loadAtStart() {
        guard let fileURL else {
            status = .memoryFallback(cause: "storage_unavailable")
            return
        }
        applyLoad(readFile(at: fileURL), url: fileURL)
    }

    /// Applies a read result. Never writes the log file itself.
    private func applyLoad(_ result: LoadResult, url: URL) {
        switch result {
        case .absent:
            fileNeedsReading = false
            if stored.isEmpty { status = .new }
        case let .loaded(records):
            fileNeedsReading = false
            let known = Set(stored.map(\.id))
            stored = (stored + records.filter { !known.contains($0.id) })
            applyRetention()
            status = .saved
        case .unreadable:
            fileNeedsReading = true
            status = .memoryFallback(cause: "read_failed")
        case let .unusable(cause):
            if quarantine(url) {
                fileNeedsReading = false
                status = .memoryFallback(cause: cause)
            } else {
                fileNeedsReading = true
                status = .memoryFallback(cause: "read_failed")
            }
        }
    }

    /// Moves a file this build cannot use aside so a later write cannot destroy
    /// it. Returns false if it could not be moved.
    private func quarantine(_ url: URL) -> Bool {
        let stamp = Int(now().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            pruneMovedAsideFiles(besides: url)
            return true
        } catch {
            return false
        }
    }

    /// Keeps only the newest few files moved aside, so a repeatedly corrupted
    /// log cannot fill the disk with copies.
    static let movedAsideFilesKept = 3

    private func pruneMovedAsideFiles(besides url: URL) {
        let prefix = "\(url.deletingPathExtension().lastPathComponent).unreadable-"
        let directory = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        // The suffix is a Unix timestamp, so newer files sort later.
        let aside = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
            }
        for name in aside.dropLast(Self.movedAsideFilesKept) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Writing

    /// Schedules one background write; changes made before it runs share it.
    private func scheduleWriteLocked() {
        guard !writeScheduled else { return }
        writeScheduled = true
        let sinceLast = Date().timeIntervalSince(lastWriteStarted)
        let delay = sinceLast >= writeDelay ? 0 : writeDelay - sinceLast
        writeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.performWrite() }
    }

    /// Runs on `writeQueue` only.
    private func performWrite() {
        lock.lock()
        guard writeScheduled else { lock.unlock(); return }
        writeScheduled = false
        lastWriteStarted = Date()
        guard let fileURL else {
            status = .memoryFallback(cause: "storage_unavailable")
            lock.unlock()
            return
        }
        let needsReading = fileNeedsReading
        lock.unlock()

        if needsReading {
            // Never write over a file we could not read: try to read it again.
            let result = readFile(at: fileURL)
            lock.lock()
            applyLoad(result, url: fileURL)
            let blocked = fileNeedsReading
            lock.unlock()
            if blocked { return }
        }

        lock.lock()
        let snapshot = stored
        lock.unlock()
        let outcome: PersistenceStatus
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try Self.encoder.encode(StoredFile(version: 1, records: snapshot))
            try data.write(to: fileURL, options: .atomic)
            outcome = .saved
        } catch {
            outcome = .memoryFallback(cause: "write_failed")
        }
        lock.lock()
        status = outcome
        let handler = changeHandler
        lock.unlock()
        handler?()
    }

    private static func sanitized(_ record: ErrorLogRecord) -> ErrorLogRecord {
        var copy = record
        let domain = ErrorLogRedactor.domainToken(record.domain)
        copy.domain = domain
        var correlation = record.correlation
        correlation.serverConnectionID = correlation.serverConnectionID.flatMap(ErrorLogRedactor.safeID)
        correlation.requestID = correlation.requestID.flatMap(ErrorLogRedactor.safeID)
        copy.correlation = correlation
        return ErrorLogRecord(
            id: copy.id, occurredAt: copy.occurredAt, lastAt: copy.lastAt, count: max(copy.count, 1),
            build: copy.build, concern: copy.concern, connectionRole: copy.connectionRole,
            operation: ErrorLogRedactor.operationToken(copy.operation),
            phase: ErrorLogRedactor.operationToken(copy.phase), domain: domain,
            code: ErrorLogRedactor.reasonCode(domain: domain, code: copy.code),
            initiator: copy.initiator, retryable: copy.retryable, correlation: copy.correlation,
            httpStatus: copy.httpStatus.flatMap(ErrorLogRedactor.httpStatus),
            resolvedAt: copy.resolvedAt,
            resolvedBy: copy.resolvedBy.flatMap { ErrorLogRedactor.simpleID($0) ?? ErrorLogRedactor.identifier($0) })
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

// MARK: - Display rules and copy format

public enum ErrorLogContextStatus: Equatable, Sendable {
    /// The newest unresolved failure for the surface.
    case failing(ErrorLogRecord)
    /// A resolved failure, shown as "last failure <time> (resolved)".
    case resolved(ErrorLogRecord)

    public var record: ErrorLogRecord {
        switch self {
        case let .failing(record), let .resolved(record): record
        }
    }
}

/// Operation names that decide which surface shows a record. Concerns should
/// report snapshot reads of a single thread as `readEntries`; every other
/// snapshot operation belongs to the inbox surface.
public enum ErrorLogOperation {
    public static let readEntries = "read_entries"
}

/// A place in the app that shows failures in context.
public enum ErrorLogSurface: Hashable, Sendable {
    /// The inbox list: snapshot failures other than a single thread's entries.
    case inbox
    /// An open thread: snapshot failures reading that thread's entries.
    case thread
    /// The live indicator: sync failures.
    case liveIndicator
    /// One item acted on (for example one reply): actions failures for that operation.
    case item(clientOperationID: UUID)
}

public enum ErrorLogDisplay {
    public static let resolvedDisplayInterval: TimeInterval = 24 * 3600

    public static func inContext(records: [ErrorLogRecord],
                                 surface: ErrorLogSurface,
                                 now: Date) -> ErrorLogContextStatus? {
        switch surface {
        case .inbox:
            return inContext(records: records.filter { $0.operation != ErrorLogOperation.readEntries },
                             concern: .snapshot, now: now)
        case .thread:
            return inContext(records: records, concern: .snapshot,
                             operation: ErrorLogOperation.readEntries, now: now)
        case .liveIndicator:
            return inContext(records: records, concern: .sync, now: now)
        case let .item(clientOperationID):
            return inContext(records: records, concern: .actions,
                             clientOperationID: clientOperationID, now: now)
        }
    }

    /// What a surface of `concern` should show. Pass `operation` or
    /// `clientOperationID` to narrow it to one item (for example one reply).
    /// A resolved failure stays for 24 hours after it was resolved.
    public static func inContext(records: [ErrorLogRecord],
                                 concern: ErrorLogConcern,
                                 operation: String? = nil,
                                 clientOperationID: UUID? = nil,
                                 now: Date) -> ErrorLogContextStatus? {
        let matching = records.filter { record in
            record.concern == concern &&
                (operation.map { record.operation == $0 } ?? true) &&
                (clientOperationID.map { record.correlation.clientOperationID == $0 } ?? true)
        }
        if let failing = matching.filter({ !$0.isResolved }).max(by: { $0.lastAt < $1.lastAt }) {
            return .failing(failing)
        }
        let recentlyResolved = matching.filter { record in
            guard let resolvedAt = record.resolvedAt else { return false }
            return now.timeIntervalSince(resolvedAt) < resolvedDisplayInterval
        }
        if let resolved = recentlyResolved.max(by: { ($0.resolvedAt ?? .distantPast) < ($1.resolvedAt ?? .distantPast) }) {
            return .resolved(resolved)
        }
        return nil
    }
}

public enum ErrorLogDetails {
    /// Plain `key: value` lines for one record, safe to paste anywhere.
    public static func text(for record: ErrorLogRecord) -> String {
        var lines = [
            "app_version: \(record.build.version)",
            "app_build: \(record.build.build)",
            "app_commit: \(record.build.commit)",
            "record_id: \(record.id.uuidString.lowercased())",
            "concern: \(record.concern.rawValue)",
            "connection_role: \(record.connectionRole.rawValue)",
            "operation: \(record.operation)",
            "phase: \(record.phase)",
            "domain: \(record.domain)",
            "code: \(record.code)",
            "initiator: \(record.initiator.rawValue)",
            "retryable: \(record.retryable ? "yes" : "no")",
            "count: \(record.count)",
            "first_at: \(timestamp(record.occurredAt))",
            "last_at: \(timestamp(record.lastAt))"
        ]
        if let status = record.httpStatus { lines.insert("http_status: \(status)", at: 10) }
        let correlation = record.correlation
        if let id = correlation.attemptID { lines.append("attempt_id: \(id.uuidString.lowercased())") }
        if let id = correlation.transportAttemptID {
            lines.append("transport_attempt_id: \(id.uuidString.lowercased())")
        }
        if let id = correlation.serverConnectionID { lines.append("server_connection_id: \(id)") }
        if let id = correlation.requestID { lines.append("request_id: \(id)") }
        if let id = correlation.clientOperationID {
            lines.append("client_operation_id: \(id.uuidString.lowercased())")
        }
        if let resolvedAt = record.resolvedAt {
            lines.append("resolved_at: \(timestamp(resolvedAt))")
            lines.append("resolved_by: \(record.resolvedBy ?? "success")")
        } else {
            lines.append("resolved: no")
        }
        return lines.joined(separator: "\n")
    }

    /// Every record, separated by a blank line, newest first.
    public static func text(for records: [ErrorLogRecord]) -> String {
        records.isEmpty ? "no_records: yes" : records.map { text(for: $0) }.joined(separator: "\n\n")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
