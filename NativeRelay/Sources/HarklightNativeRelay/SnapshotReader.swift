import AttentionDomain
import Foundation

/// Where the Snapshot Reader (and later Actions) get a connection for one
/// request. Requests never depend on the stream connection's health.
public protocol RequestConnectionSource: Sendable {
    /// True only for the thin fallback, where every request rides the one
    /// stream connection because the server cannot accept a second one.
    var sharesStreamConnection: Bool { get }
    func requestConnection() async throws -> any AuthenticatedInboxPagingSession
}

/// THIN FALLBACK: remove once self-hosted servers and hosted both run a build with
/// connection roles. Until then the server closes a device's other
/// connections whenever one opens, so every request shares the stream
/// connection. The components are the same; only the connection is shared.
struct SharedStreamConnection: RequestConnectionSource {
    let session: any AuthenticatedInstallationSession
    var sharesStreamConnection: Bool { true }

    func requestConnection() async throws -> any AuthenticatedInboxPagingSession {
        guard let paging = session as? any AuthenticatedInboxPagingSession else {
            throw NativeRelayCoreError.inboxPagingUnavailable
        }
        return paging
    }
}

/// Set once when the owning core is deactivated; read by its components
/// without an actor hop, so no component writes after deactivation.
final class ComponentActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    func deactivate() {
        lock.lock(); defer { lock.unlock() }
        active = false
    }
}

public enum InboxSnapshotReadOutcome: Equatable, Sendable {
    /// A newer server view was stored for the UI.
    case updated(revision: ExactText)
    /// The held view is current.
    case unchanged(revision: ExactText)
    /// The server does not offer the view on this connection.
    case unsupported
    /// The read failed and was reported to the Error Log. The held view is
    /// kept, unchanged, for the UI to show as stale.
    case failed
    case inactive
}

/// Snapshot Reader (design section 2): fetches current state for display on
/// request connections. It never waits on Sync, the stream, a checkpoint, an
/// ACK or Actions, and a failed read never removes the held snapshot.
///
/// Owns the held inbox view (in the local store), whether the connection
/// supports it, and coalescing of in-flight reads.
actor SnapshotReader {
    static let readInboxOperation = "read_inbox"

    private let store: ClientRepository
    private let context: ProfileContext
    private let inboxWire: InboxPagingWire
    private let connections: any RequestConnectionSource
    private let errors: any ErrorLogging
    private let activity: ComponentActivity
    private let correlation: ErrorLogCorrelation
    private let persist: @Sendable () async throws -> Void

    private var inboxUnsupported = false
    private var inFlightInboxRead: Task<InboxSnapshotReadOutcome, Never>?
    private var pendingNoticedRevision: ExactText?
    /// True until a read on this connection reached the server and was
    /// answered; a failed read leaves it true so the next drain retries.
    private(set) var needsInboxRead = true

    init(store: ClientRepository, context: ProfileContext, inboxWire: InboxPagingWire,
         connections: any RequestConnectionSource, errors: any ErrorLogging,
         activity: ComponentActivity, correlation: ErrorLogCorrelation,
         persist: @escaping @Sendable () async throws -> Void) {
        self.store = store
        self.context = context
        self.inboxWire = inboxWire
        self.connections = connections
        self.errors = errors
        self.activity = activity
        self.correlation = correlation
        self.persist = persist
    }

    /// Reads the server inbox view. A `noticedRevision` (from a change notice)
    /// is skipped when it is already held. Calls made while a read is in
    /// flight share its outcome; a newer notice is read once it finishes.
    func readInbox(noticedRevision: ExactText? = nil) async -> InboxSnapshotReadOutcome {
        guard activity.isActive else { return .inactive }
        guard !inboxUnsupported else { return .unsupported }
        if let noticedRevision, heldInboxView()?.revision == noticedRevision {
            return .unchanged(revision: noticedRevision)
        }
        if let inFlightInboxRead {
            if let noticedRevision { pendingNoticedRevision = noticedRevision }
            return await inFlightInboxRead.value
        }
        let read = Task { await self.readInboxUntilNoticesAreHeld(noticedRevision) }
        inFlightInboxRead = read
        return await read.value
    }

    private func readInboxUntilNoticesAreHeld(_ firstNotice: ExactText?) async -> InboxSnapshotReadOutcome {
        defer { inFlightInboxRead = nil }
        var notice = firstNotice
        while true {
            pendingNoticedRevision = nil
            let held = heldInboxView()
            let outcome: InboxSnapshotReadOutcome
            if let notice, notice == held?.revision {
                outcome = .unchanged(revision: notice)
            } else {
                outcome = await readInboxOnce(held: held)
            }
            switch outcome {
            case .updated, .unchanged: break
            case .unsupported, .failed, .inactive: return outcome
            }
            guard let pending = pendingNoticedRevision,
                  pending != heldInboxView()?.revision else { return outcome }
            notice = pending
        }
    }

    private func readInboxOnce(held: InboxView?) async -> InboxSnapshotReadOutcome {
        let knownRevision = held?.revision
        let ref = "native-inbox-view-\(UUID().uuidString.lowercased())"
        let reply: Data
        do {
            let connection = try await connections.requestConnection()
            reply = try await connection.inboxRequest(
                inboxWire.viewGet(knownRevision: knownRevision, ref: ref), ref: ref)
        } catch {
            report(phase: "request", reason: .relay(error), initiator: .forFailure(error), retryable: true)
            return activity.isActive ? .failed : .inactive
        }
        guard activity.isActive else { return .inactive }
        let outcome: InboxSnapshotReadOutcome
        do {
            switch inboxWire.decodeViewGet(reply, ref: ref, knownRevision: knownRevision) {
            case let .updated(view):
                try store.setInboxView(view, context: context)
                outcome = .updated(revision: view.revision)
            case let .unchanged(revision):
                outcome = .unchanged(revision: revision)
            case .unsupported:
                // The server states it has no view, which is not a failed
                // read: the inbox falls back to its local order.
                inboxUnsupported = true
                try store.setInboxView(nil, context: context)
                outcome = .unsupported
            case .unavailable:
                report(phase: "decode", reason: .app("view_unavailable"), initiator: .unknown, retryable: true)
                return .failed
            }
        } catch {
            report(phase: "apply", reason: .relay(error), initiator: .unknown, retryable: false)
            return .failed
        }
        needsInboxRead = false
        // Save only when the reply changed the held view.
        if heldInboxView() != held { try? await persist() }
        errors.resolve(concern: .snapshot, operation: Self.readInboxOperation)
        return outcome
    }

    private func heldInboxView() -> InboxView? {
        (try? store.snapshot(context: context).inboxView) ?? nil
    }

    private func report(phase: String, reason: ErrorLogReason, initiator: ErrorLogInitiator, retryable: Bool) {
        errors.report(ErrorLogReport(concern: .snapshot,
            connectionRole: connections.sharesStreamConnection ? .stream : .request,
            operation: Self.readInboxOperation, phase: phase, reason: reason, initiator: initiator,
            retryable: retryable, correlation: correlation))
    }
}

extension ErrorLogReason {
    /// A system error keeps its domain and numeric code; the relay's own
    /// errors keep their fixed cause token instead of becoming `other`.
    static func relay(_ error: any Error) -> Self {
        let reason = from(error: error)
        return reason == .app("other") ? .app(NativeDiagnosticCauseCode.forError(error)) : reason
    }
}

extension ErrorLogInitiator {
    /// The client cannot see who ended a cancelled or aborted connection, so
    /// it says `unknown` rather than guessing; only a timeout is known.
    static func forFailure(_ error: any Error) -> Self {
        let value = error as NSError
        if value.domain == NSURLErrorDomain, value.code == NSURLErrorTimedOut { return .timeout }
        if value.domain == NSPOSIXErrorDomain, value.code == Int(POSIXErrorCode.ETIMEDOUT.rawValue) { return .timeout }
        return .unknown
    }
}
