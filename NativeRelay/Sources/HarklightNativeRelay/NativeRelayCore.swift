import AttentionDomain
import Foundation

/// Only the native enrollment/profile owner may supply a session. Its device
/// certificate and relay peer must already have been authenticated by TLS.
public protocol AuthenticatedInstallationSession: AnyObject, Sendable {
    var authenticatedIdentity: ProfileIdentity { get }
    /// Host authenticated for this transport. This can differ from the stable
    /// profile authority only after an explicit, approved endpoint migration.
    var relayEndpointHost: String { get }
    /// Delivers bounded individual server frames through `resynced` without
    /// retaining the whole replay in the transport.
    func resync(_ request: Data,
                consume: @Sendable (Data) async throws -> Void) async throws
    func acknowledge(_ request: Data) async throws
    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult
}

public extension AuthenticatedInstallationSession {
    var relayEndpointHost: String { authenticatedIdentity.trustedRelayAuthority.rawValue }
}

public protocol AuthenticatedConversationSession: AuthenticatedInstallationSession {
    func openConversation(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws
    func acknowledgeConversation(_ request: Data) async throws
}

public protocol AuthenticatedConversationFileSession: AuthenticatedConversationSession {
    func conversationFileLimits(originURL: URL) async throws -> ConversationFileLimits
    func uploadConversationFile(_ file: ConversationFile, from source: URL, binding: ConversationBinding,
                                operationID: UUID, limits: ConversationFileLimits, originURL: URL) async throws -> ConversationFile
    func sendDiscussion(_ frame: Data, operationID: UUID) async -> DiscussionOperationResult
}

public protocol AuthenticatedConversationCleanupSession: AuthenticatedConversationFileSession {
    func discardConversationUploads(_ cleanup: ConversationUploadCleanup,
                                    originURL: URL) async throws -> ConversationUploadDiscardResult
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
    private let onProgress: @Sendable (NativeRelayProgressEvent) -> Void
    private var active = true
    private var busy = false
    private var activeReplay: ReplayProgress?
    private var conversationReplay: ConversationReplayProgress?
    private var inspectedConversationMetadata = false
    private var discoveredOriginURL: URL?
    private var activeCleanupRequests: Set<UUID> = []

    public func conversationOriginURL() throws -> URL? {
        try validate()
        return discoveredOriginURL
    }

    /// Independent of the send/replay busy flag: departure can fence an upload
    /// while it is awaiting HTTP. This method never submits a discussion.
    public func discardAbandonedUploads(for request: RequestKey) async throws {
        try validate()
        let pending = (try store.conversationSnapshot(context: context).threads[request]?.uploadCleanups ?? [:]).values
            .filter { if case .acknowledged = $0.outcome { return false }; return true }
        for cleanup in pending {
            // Foreground replay and explicit navigation may retry the same
            // durable cleanup together. Keep one request in flight so a late
            // duplicate cannot fence a newly reselected upload after success.
            guard activeCleanupRequests.insert(cleanup.id).inserted else { continue }
            defer { activeCleanupRequests.remove(cleanup.id) }
            do {
                guard let endpoint = discoveredOriginURL,
                      let transport = session as? any AuthenticatedConversationCleanupSession else {
                    throw NativeRelayCoreError.inactive
                }
                let result = try await transport.discardConversationUploads(cleanup, originURL: endpoint)
                try validate()
                try store.recordConversationCleanup(cleanup.id, request: request,
                    outcome: .acknowledged(result), context: context)
            } catch {
                try store.recordConversationCleanup(cleanup.id, request: request,
                    outcome: .unknown(ExactText(String(describing: error))), context: context)
                throw error
            }
        }
    }

    private func validateUploadOperation(_ binding: ConversationBinding, operation: UUID) throws {
        let thread = try store.conversationSnapshot(context: context).threads[binding.request]
        guard thread?.uploadGroups?[operation]?.cleanupID == nil else { throw ConversationError.pendingSubmission }
    }

    public func submitDiscussion(_ binding: ConversationBinding,
        retainedFile: @Sendable (ConversationFile) async throws -> URL) async throws -> DiscussionOperationResult {
        guard !busy else { throw NativeRelayCoreError.inactive }
        busy = true
        defer { busy = false }
        try validate()
        guard let transport = session as? any AuthenticatedConversationFileSession,
              let draft = try store.conversationSnapshot(context: context).threads[binding.request]?.drafts[binding.revision] else {
            throw ConversationError.missingRequest
        }
        if case let .acceptedPendingReplay(_, turn) = draft.disposition {
            try await replayConversationAndAcknowledge(using: transport)
            return .accepted(turnID: turn)
        }
        guard !draft.text.rawValue.isEmpty else { throw ConversationError.emptyDraft }
        let wasUncertain: Bool
        switch draft.disposition {
        case .submitting, .outcomeUnknown: wasUncertain = true
        default: wasUncertain = false
        }
        let operation = try store.prepareDiscussion(binding, context: context)
        guard let frozen = try store.conversationSnapshot(context: context).threads[binding.request]?.drafts[binding.revision] else {
            throw ConversationError.missingRequest
        }
        let frame: Data
        do {
            var prepared: [ConversationFile] = []
            var limits: ConversationFileLimits?
            if !frozen.files.isEmpty {
                guard let endpoint = discoveredOriginURL else {
                    throw ConversationError.uploadRequired(frozen.files[0].name)
                }
                let published = try await transport.conversationFileLimits(originURL: endpoint)
                try validate()
                limits = published
                let tiers = try published.tiers(for: frozen.files)
                for (file, tier) in zip(frozen.files, tiers) {
                    if case .uploaded = file.content { prepared.append(file); continue }
                    if tier == .upload {
                        try store.registerConversationUpload(file, binding: binding, operation: operation, context: context)
                        let source = try await retainedFile(file)
                        try validateUploadOperation(binding, operation: operation)
                        let uploaded = try await transport.uploadConversationFile(file, from: source, binding: binding,
                            operationID: operation, limits: published, originURL: endpoint)
                        try validate()
                        try store.recordConversationUpload(uploaded, binding: binding, operation: operation, context: context)
                        prepared.append(uploaded)
                    } else {
                        let bytes: Data
                        if case let .inline(inline) = file.content { bytes = inline }
                        else {
                            let source = try await retainedFile(file)
                            bytes = try Data(contentsOf: source)
                        }
                        prepared.append(ConversationFile(id: file.id, name: file.name, byteCount: file.byteCount,
                            sha256: file.sha256, content: .inline(bytes)))
                    }
                }
            }
            frame = try ConversationWire(profile: context, endpointHost: session.relayEndpointHost).discussion(frozen, operationID: operation,
                preparedFiles: prepared, limits: limits)
        } catch {
            // No discussion frame has been sent by this attempt. A previous
            // ambiguous attempt must still keep its exact operation frozen.
            // Keep all original bytes/draft; unreferenced uploads do not submit a turn.
            let names = frozen.files.map { $0.name.rawValue }.joined(separator: ", ")
            try store.markDiscussionOutcome(binding, operation: operation,
                rejection: wasUncertain ? nil : ExactText("Not delivered: " + (names.isEmpty ? "the discussion" : names) + " could not be prepared (\(error)). Draft retained."),
                context: context)
            throw error
        }
        try validate()
        try validateUploadOperation(binding, operation: operation)
        let result = await transport.sendDiscussion(frame, operationID: operation)
        try validate()
        switch result {
        case let .accepted(turn):
            try store.markDiscussionAccepted(binding, operation: operation, turn: turn, context: context)
            // The accepted turn is durable even if replay temporarily fails. A later
            // refresh joins it; the send response cannot move a replay cursor.
            try? await replayConversationAndAcknowledge(using: transport)
        case let .rejected(reason):
            try store.markDiscussionOutcome(binding, operation: operation, rejection: reason, context: context)
        case .unresolved:
            try store.markDiscussionOutcome(binding, operation: operation, rejection: nil, context: context)
        }
        return result
    }

    private struct ConversationReplayProgress {
        var expected: UInt64
        let durableCursor: UInt64
        var accepted = false
        var high: UInt64?
    }

    private struct ReplayProgress {
        var expected: UInt64
        let durableCursor: UInt64
        let retained: Set<RequestKey>
        var accepted = false
        var high: UInt64?
    }

    public init(store: AttentionDomainStore,
                context: ProfileContext,
                session: any AuthenticatedInstallationSession,
                onProgress: @escaping @Sendable (NativeRelayProgressEvent) -> Void = { _ in }) throws {
        guard context.transportMode == .relay else { throw NativeRelayCoreError.fixtureProfile }
        guard session.authenticatedIdentity == context.identity else {
            throw NativeRelayCoreError.wrongInstallation
        }
        _ = try store.snapshot(context: context)
        self.store = store
        self.context = context
        self.session = session
        self.onProgress = onProgress
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
        let snapshot = try store.snapshot(context: context)
        // An upgraded store can have ordinary delivery history predating the
        // additive metadata. Replay enriches it without replacing drafts or cursor.
        let enrich = session is any AuthenticatedConversationSession && !inspectedConversationMetadata &&
            snapshot.conversationThreads.isEmpty && !snapshot.requests.isEmpty
        let before = enrich ? 0 : snapshot.cursor
        var high = try await replayAndAcknowledge(since: before)
        inspectedConversationMetadata = true
        let attempted = try await drainPending()
        if attempted > 0 {
            // The answer may have created a terminal event after the first
            // replay. Commit and ACK it before publishing the refreshed view;
            // an operation's receipt sequence cannot advance C's cursor.
            high = try await replayAndAcknowledge(since: store.snapshot(context: context).cursor)
        }
        if try !store.conversationSnapshot(context: context).threads.isEmpty,
           let conversationSession = session as? any AuthenticatedConversationSession {
            try await replayConversationAndAcknowledge(using: conversationSession)
        }
        return high
    }

    private func replayConversationAndAcknowledge(using transport: any AuthenticatedConversationSession) async throws {
        let wire = try ConversationWire(profile: context, endpointHost: transport.relayEndpointHost)
        var high = try await replayConversation(since: store.conversationSnapshot(context: context).cursor,
            using: transport, wire: wire)
        do { try await transport.acknowledgeConversation(wire.acknowledge(high)) }
        catch InstallationTransportError.acknowledgementBehind {
            high = try await replayConversation(since: 0, using: transport, wire: wire)
            try await transport.acknowledgeConversation(wire.acknowledge(high))
        }
    }

    private func replayConversation(since cursor: UInt64, using transport: any AuthenticatedConversationSession,
                                    wire: ConversationWire) async throws -> UInt64 {
        try validate()
        conversationReplay = ConversationReplayProgress(expected: cursor,
            durableCursor: try store.conversationSnapshot(context: context).cursor)
        defer { conversationReplay = nil }
        try await transport.openConversation(wire.open(since: cursor)) { frame in
            try await self.consumeConversationReplay(frame)
        }
        try validate()
        guard let high = conversationReplay?.high else { throw NativeRelayCoreError.invalidReplay }
        return high
    }

    private func consumeConversationReplay(_ frame: Data) throws {
        try validate()
        guard var replay = conversationReplay, replay.high == nil else { throw NativeRelayCoreError.invalidReplay }
        let wire = try ConversationWire(profile: context, endpointHost: session.relayEndpointHost)
        if !replay.accepted {
            guard try wire.isOpenAccepted(frame) else { throw NativeRelayCoreError.invalidReplay }
            discoveredOriginURL = try wire.originEndpoint(frame)
            replay.accepted = true
        } else if let high = try? wire.decodeResynced(frame) {
            guard high >= replay.durableCursor, high == replay.expected else { throw NativeRelayCoreError.invalidReplay }
            try store.finishConversationReplay(at: high, context: context)
            replay.high = high
        } else {
            let event = try wire.decodeEvent(frame)
            guard replay.expected < UInt64.max, event.sequence == replay.expected + 1 else {
                throw NativeRelayCoreError.invalidReplay
            }
            _ = try store.applyConversation(event, context: context)
            replay.expected = event.sequence
        }
        conversationReplay = replay
    }

    private func replayAndAcknowledge(since cursor: UInt64) async throws -> UInt64 {
        // This is a local intent signal only; relay admission is observed
        // later from the session's authenticated response.
        onProgress(.nativeSyncReplayRequested)
        var high = try await replay(since: cursor)
        onProgress(.nativeSyncResynced)
        do {
            try await session.acknowledge(wire.acknowledge(high))
            onProgress(.nativeSyncAcknowledged)
        } catch InstallationTransportError.acknowledgementBehind {
            // C may have durably committed a prior replay whose ACK never
            // reached the server. Re-present the server's complete streamed
            // history so this session may ACK contiguously from its cursor.
            onProgress(.nativeSyncReplayRequested)
            high = try await replay(since: 0)
            onProgress(.nativeSyncResynced)
            try await session.acknowledge(wire.acknowledge(high))
            onProgress(.nativeSyncAcknowledged)
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
