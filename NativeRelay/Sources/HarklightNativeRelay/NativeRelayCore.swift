import AttentionDomain
import Foundation

/// Only the native enrollment/profile owner may supply a session. Its device
/// certificate and relay peer must already have been authenticated by TLS.
public protocol AuthenticatedInstallationSession: AnyObject, Sendable {
    var authenticatedIdentity: ProfileIdentity { get }
    /// Delivers bounded individual server frames through `resynced` without
    /// retaining the whole replay in the transport.
    func resync(_ request: Data,
                consume: @Sendable (Data) async throws -> Void) async throws
    func acknowledge(_ request: Data) async throws
    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult
}

public enum OriginalOperationResult: Equatable, Sendable {
    case accepted(operationID: UUID, terminalSequence: UInt64)
    case unresolved
}

public enum NativeRelayCoreError: Error, Equatable {
    case fixtureProfile
    case wrongInstallation
    case inactive
    case invalidReplay
    case missingOriginContent
    case eventRejected
    case mismatchedOperationResult
}

/// The first native relay seam. C is the only durable owner of events, cursor,
/// drafts, intents, receipts and outbox; this object holds no shadow journal.
public actor NativeRelayCore {
    private let store: AttentionDomainStore
    private let context: ProfileContext
    private let session: any AuthenticatedInstallationSession
    private let wire: RelayWire
    private var active = true
    private var busy = false
    private var activeReplay: ReplayProgress?

    private struct ReplayProgress {
        var expected: UInt64
        let durableCursor: UInt64
        let retained: Set<RequestKey>
        var accepted = false
        var high: UInt64?
    }

    public init(store: AttentionDomainStore,
                context: ProfileContext,
                session: any AuthenticatedInstallationSession) throws {
        guard context.transportMode == .relay else { throw NativeRelayCoreError.fixtureProfile }
        guard session.authenticatedIdentity == context.identity else {
            throw NativeRelayCoreError.wrongInstallation
        }
        _ = try store.snapshot(context: context)
        self.store = store
        self.context = context
        self.session = session
        self.wire = try RelayWire(profile: context)
    }

    public func deactivate() {
        active = false
    }

    /// Foreground and push-triggered reconnects both start from C's durable
    /// cursor. A server reply is never itself a durable cursor or ACK.
    @discardableResult
    public func resyncAndDrainOutbox() async throws -> UInt64 {
        guard !busy else { throw NativeRelayCoreError.inactive }
        busy = true
        defer { busy = false }
        try validate()
        let before = try store.snapshot(context: context).cursor
        var high = try await replayAndAcknowledge(since: before)
        let attempted = try await drainPending()
        if attempted > 0 {
            // The answer may have created a terminal event after the first
            // replay. Commit and ACK it before publishing the refreshed view;
            // an operation's receipt sequence cannot advance C's cursor.
            high = try await replayAndAcknowledge(since: store.snapshot(context: context).cursor)
        }
        return high
    }

    private func replayAndAcknowledge(since cursor: UInt64) async throws -> UInt64 {
        var high = try await replay(since: cursor)
        do {
            try await session.acknowledge(wire.acknowledge(high))
        } catch InstallationTransportError.acknowledgementBehind {
            // C may have durably committed a prior replay whose ACK never
            // reached the server. Re-present the server's complete streamed
            // history so this session may ACK contiguously from its cursor.
            high = try await replay(since: 0)
            try await session.acknowledge(wire.acknowledge(high))
        }
        return high
    }

    private func replay(since cursor: UInt64) async throws -> UInt64 {
        try validate()
        let snapshot = try store.snapshot(context: context)
        activeReplay = ReplayProgress(expected: cursor,
                                      durableCursor: snapshot.cursor,
                                      retained: Set(snapshot.requests.keys))
        defer { activeReplay = nil }
        try await session.resync(wire.resync(since: cursor)) { frame in
            try await self.consumeReplay(frame)
        }
        try validate()
        guard let high = activeReplay?.high else { throw NativeRelayCoreError.invalidReplay }
        // The caller ACKs even when C's cursor did not advance: a previous
        // ACK may have been lost after this durable local commit.
        return high
    }

    private func consumeReplay(_ frame: Data) throws {
        try validate()
        guard var replay = activeReplay, replay.high == nil else {
            throw NativeRelayCoreError.invalidReplay
        }
        if !replay.accepted {
            guard try wire.isResyncAccepted(frame) else { throw NativeRelayCoreError.invalidReplay }
            // The server sends no high-water mark before its event stream.
            // Keep C's published view behind one durable barrier until the
            // final resynced frame names the exact contiguous cursor.
            try store.beginReplay(through: UInt64.max, context: context)
            replay.accepted = true
            activeReplay = replay
            return
        }
        if let high = try? wire.decodeResynced(frame) {
            guard high >= replay.durableCursor, high == replay.expected else {
                throw NativeRelayCoreError.invalidReplay
            }
            try store.finishReplay(at: high, context: context)
            replay.high = high
            activeReplay = replay
            return
        }
        let event = try wire.decodeEvent(frame)
        guard replay.expected < UInt64.max, event.sequence == replay.expected + 1 else {
            throw NativeRelayCoreError.invalidReplay
        }
        if case let .originReference(key) = event.body, !replay.retained.contains(key) {
            throw NativeRelayCoreError.missingOriginContent
        }
        switch store.applyRelayEvent(event, context: context) {
        case .committed, .compatibleRepeat:
            break
        case .repairRequired where isOriginReference(event):
            throw NativeRelayCoreError.missingOriginContent
        case .gap, .conflict, .repairRequired:
            throw NativeRelayCoreError.eventRejected
        }
        replay.expected = event.sequence
        activeReplay = replay
    }

    /// An uncertain result leaves the exact original C operation in the outbox.
    @discardableResult
    public func sendPendingOriginalOperations() async throws -> Int {
        guard !busy else { throw NativeRelayCoreError.inactive }
        busy = true
        defer { busy = false }
        return try await drainPending()
    }

    private func drainPending() async throws -> Int {
        try validate()
        let pending = try store.snapshot(context: context).outbox
        var attempted = 0
        for submission in pending {
            try validate()
            let result = try await session.sendOriginalOperation(submission.wireFrame,
                                                                 operationID: submission.operationID)
            try validate()
            attempted += 1
            if case let .accepted(operationID, terminalSequence) = result {
                guard operationID == submission.operationID, terminalSequence > 0 else {
                    throw NativeRelayCoreError.mismatchedOperationResult
                }
                try store.recordAcceptedOperation(submission.intentID,
                                                  operationID: operationID,
                                                  terminalSequence: terminalSequence,
                                                  context: context)
            }
        }
        return attempted
    }

    private func isOriginReference(_ event: RelayEvent) -> Bool {
        if case .originReference = event.body { return true }
        return false
    }

    private func validate() throws {
        guard active else { throw NativeRelayCoreError.inactive }
        guard session.authenticatedIdentity == context.identity else {
            throw NativeRelayCoreError.wrongInstallation
        }
        _ = try store.snapshot(context: context)
    }
}
