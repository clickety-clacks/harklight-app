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
    func correlatedRequest(_ request: Data, ref: String) async throws -> Data
    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult
}

/// Opt-in FORMAT17 v25 enrolled-device paging. Keeping this separate prevents
/// an older transport from silently falling back to an unbounded `resync`.
public protocol AuthenticatedInboxPagingSession: AuthenticatedInstallationSession {
    func inboxRequest(_ request: Data, ref: String) async throws -> Data
    func attachInboxReplay(_ request: Data, ref: String,
                           consume: @Sendable (Data) async throws -> Void) async throws
}

/// Receives events that the relay sends after the first replay barrier on the
/// same authenticated connection. These frames remain unacknowledged until the
/// core durably applies them.
public protocol AuthenticatedInboxEventStreamSession: AuthenticatedInboxPagingSession, AuthenticatedLiveEventSession {
    var supportsPostCheckpointInboxEvents: Bool { get }
    func nextPostCheckpointInboxEvent() async throws -> Data
}

public extension AuthenticatedInboxEventStreamSession {
    func nextLiveEvent() async throws -> Data {
        try await nextPostCheckpointInboxEvent()
    }
}

public extension AuthenticatedInstallationSession {
    var relayEndpointHost: String { authenticatedIdentity.trustedRelayAuthority.rawValue }
}

/// Route A's legacy sync connection also carries post-replay delivery and
/// lifecycle events. This interface does not imply paged inbox support.
public protocol AuthenticatedLiveEventSession: AuthenticatedInstallationSession {
    func nextLiveEvent() async throws -> Data
}

public protocol AuthenticatedConversationSession: AuthenticatedInstallationSession {
    func openConversation(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws
    func acknowledgeConversation(_ request: Data) async throws
    func sendConversationReadPosition(_ frame: Data, operationID: UUID) async -> ConversationReadPositionResult
}

public extension AuthenticatedConversationSession {
    /// Older test or transport adapters do not claim support for the additive
    /// account read-position operation until they implement its response path.
    func sendConversationReadPosition(_ frame: Data, operationID: UUID) async -> ConversationReadPositionResult {
        .unresolved
    }
}

/// A post-checkpoint signal asks the core to replay from its durable cursor.
/// It includes every origin reply received since the last signal was consumed,
/// so replayed backlog cannot borrow a later fetch time.
public struct LiveConversationReplyArrival: Equatable, Sendable {
    public let conversationSequence: UInt64
    public let request: RequestKey
    public let turnID: ExactText
    public let receivedAtMilliseconds: UInt64

    public init?(event: ConversationEvent, receivedAtMilliseconds: UInt64) {
        guard case let .turn(turn) = event.fact,
              turn.kind == .reply, turn.author == .origin else { return nil }
        conversationSequence = event.sequence
        request = event.binding.request
        turnID = turn.id
        self.receivedAtMilliseconds = receivedAtMilliseconds
    }
}

public struct LiveConversationSignal: Equatable, Sendable {
    public let replyArrivals: [LiveConversationReplyArrival]

    public init(replyArrivals: [LiveConversationReplyArrival]) {
        self.replyArrivals = replyArrivals
    }
}

/// After the projection is opened, the relay pushes new conversation entries
/// on the same connection. The transport preserves the exact live reply event
/// and its receive time while the core replays and ACKs from its durable cursor.
public protocol AuthenticatedConversationEventSession: AuthenticatedConversationSession {
    func nextLiveConversationSignal() async throws -> LiveConversationSignal
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
    case refusedByRetraction(operationID: UUID, retractedAtMilliseconds: UInt64)
    case staleRevision(operationID: UUID, currentRevision: UInt64)
    case unsupported(operationID: UUID)
    case operationConflict(operationID: UUID)
    case failed(operationID: UUID)
    case notTransmitted(operationID: UUID)
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
    case inboxPagingUnavailable
    case inboxPagingBusy
}

/// The first native relay seam. C is the only durable owner of events, cursor,
/// drafts, intents, receipts and outbox; this object holds no shadow journal.
public actor NativeRelayCore {
    private struct OperationReplayDiagnosticState: Equatable {
        let transition: NativeDiagnosticTransition
        let causeCode: String?
        let request: RequestKey
        let revision: UInt64?
        let receipt: NativeDiagnosticReceiptState?
    }

    private struct InboxSequenceWaiter {
        let target: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let store: AttentionDomainStore
    private let context: ProfileContext
    private let session: any AuthenticatedInstallationSession
    private let wire: RelayWire
    private let inboxWire: InboxPagingWire
    private let onProgress: @Sendable (NativeRelayProgressEvent) -> Void
    private let onDiagnostic: NativeClientDiagnosticSink
    private let attemptID: UUID?
    private var active = true
    private var busy = false
    private var postAckFailureDetails: NativePostAckFailureDetails?
    private var activeInboxReplay: ReplayProgress?
    private var inboxBootstrapped = false
    private var activeInboxStartupID: String?
    private var postCheckpointInboxConsumerTask: Task<Void, Never>?
    private var postCheckpointInboxFailure: (any Error)?
    private var inboxViewRequestedOnConnection = false
    private var inboxViewUnsupportedForConnection = false
    private var inboxViewFetchInProgress = false
    private var pendingInboxViewRevision: ExactText?
    private var inboxViewNoticeTask: Task<Void, Never>?
    private var latestInboxViewNotice: ExactText?
    private var messageOpenUnsupportedForConnection = false
    private var pendingMessageOpenDrainRequested = false
    private var postCheckpointAcknowledgementGateOpen = false
    private var postCheckpointAcknowledgedCursor: UInt64?
    private var pendingPostCheckpointAcknowledgement: UInt64?
    private var postCheckpointAcknowledgementTask: Task<Void, Never>?
    private var postCheckpointAcknowledgementWaiters: [InboxSequenceWaiter] = []
    private var pendingInboxPageWaiters: [CheckedContinuation<Bool, Error>] = []
    // A core owns one authenticated connection; a new connection probes again.
    public private(set) var conversationsUnavailable = false
    private var conversationReplay: ConversationReplayProgress?
    private var pendingLiveReplyArrivals: [UInt64: LiveConversationReplyArrival] = [:]
    // A failed receipt must not refetch full history on every later replay on
    // this connection. Keep attempts for the core's lifetime, without storing
    // rejection records or changing the durable conversation cursor.
    private var conversationRecoveryAttempts: Set<UInt64> = []
    private var liveConversationConsumerTask: Task<Void, Never>?
    private var pendingLiveConversationReplay = false
    private var conversationReadPositionSupportForSession = false
    private var pendingConversationReadPositionDrain = false
    private var inspectedConversationMetadata = false
    private var discoveredOriginURL: URL?
    private var activeCleanupRequests: Set<UUID> = []
    // This cache contains only accepted operations that still await their exact
    // terminal replay. Removing a terminal entry keeps memory bounded by current
    // outstanding work, not the account's retained history.
    private var operationReplayDiagnosticStates: [UUID: OperationReplayDiagnosticState] = [:]
    private var acceptedReplaySubmissions: [UUID: Submission] = [:]

    public func conversationOriginURL() throws -> URL? {
        try validate()
        return discoveredOriginURL
    }

    /// Independent of the send/replay busy flag: departure can fence an upload
    /// while it is awaiting HTTP. This method never submits a discussion.
    public func discardAbandonedUploads(for request: RequestKey) async throws {
        try validate()
        let pending = (try await store.currentConversationSnapshot(context: context).threads[request]?.uploadCleanups ?? [:]).values
            .filter { if case .acknowledged = $0.outcome { return false }; return true }
        for cleanup in pending {
            // Foreground replay and explicit navigation may retry the same
            // durable cleanup together. Keep one request in flight so a late
            // duplicate cannot fence a newly reselected upload after success.
            guard activeCleanupRequests.insert(cleanup.id).inserted else { continue }
            defer { activeCleanupRequests.remove(cleanup.id) }
            diagnose(.upload, .uploadCleanup, .began, operationID: cleanup.id,
                     request: request, revision: cleanup.binding.revision)
            do {
                guard let endpoint = discoveredOriginURL,
                      let transport = session as? any AuthenticatedConversationCleanupSession else {
                    throw NativeRelayCoreError.inactive
                }
                let result = try await transport.discardConversationUploads(cleanup, originURL: endpoint)
                try validate()
                try await store.recordConversationCleanup(cleanup.id, request: request,
                    outcome: .acknowledged(result), context: context)
                diagnose(.upload, .uploadCleanup, .completed, operationID: cleanup.id,
                         request: request, revision: cleanup.binding.revision)
            } catch {
                let cleanupError = error
                diagnose(.upload, .uploadCleanup, NativeDiagnosticCauseCode.failureTransition(for: error),
                         error: error, operationID: cleanup.id, request: request,
                         revision: cleanup.binding.revision, receipt: .unknown)
                do {
                    try await store.recordConversationCleanup(cleanup.id, request: request,
                        outcome: .unknown(ExactText(String(describing: cleanupError))), context: context)
                } catch {
                    diagnose(.localStore, .uploadCleanup, .failed, error: error,
                             operationID: cleanup.id, request: request,
                             revision: cleanup.binding.revision, receipt: .unknown)
                    throw error
                }
                throw cleanupError
            }
        }
    }

    public func submitDiscussion(_ binding: ConversationBinding,
        retainedFile: @Sendable (ConversationFile) async throws -> URL,
        persistDraft: @Sendable (ConversationDraft?) async throws -> Void) async throws -> DiscussionOperationResult {
        diagnose(.conversation, .discussionSubmission, .began, request: binding.request,
                 revision: binding.revision)
        guard !busy else { throw NativeRelayCoreError.inactive }
        busy = true
        defer { releaseBusy() }
        try validate()
        guard !conversationsUnavailable else { throw InstallationTransportError.conversationsUnavailable }
        guard let transport = session as? any AuthenticatedConversationFileSession,
              let draft = try await store.currentConversationSnapshot(context: context).threads[binding.request]?.drafts[binding.revision] else {
            throw ConversationError.missingRequest
        }
        if case let .acceptedPendingReplay(_, turn) = draft.disposition {
            try await replayConversationRouteA(using: transport)
            return .accepted(turnID: turn)
        }
        guard !draft.text.rawValue.isEmpty else { throw ConversationError.emptyDraft }
        let wasUncertain = draft.currentAttemptUnsettled || draft.earlierVersionMayHaveBeenSent
        let operation = try await store.prepareDiscussion(binding, context: context)
        guard let frozen = try await store.currentConversationSnapshot(context: context).threads[binding.request]?.drafts[binding.revision] else {
            throw ConversationError.missingRequest
        }
        try await persistDraft(frozen)
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
                        let source = try await retainedFile(file)
                        diagnose(.upload, .uploadTransfer, .began, operationID: operation,
                                 request: binding.request, revision: binding.revision)
                        let uploaded = try await transport.uploadConversationFile(file, from: source, binding: binding,
                            operationID: operation, limits: published, originURL: endpoint)
                        try validate()
                        let savedDraft = try await store.recordUploadedConversationFile(uploaded,
                            binding: binding, operation: operation, context: context)
                        try await persistDraft(savedDraft)
                        diagnose(.upload, .uploadTransfer, .completed, operationID: operation,
                                 request: binding.request, revision: binding.revision)
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
            let transmittingDraft = try await store.markDiscussionTransmissionStarting(
                binding, operation: operation, context: context)
            try await persistDraft(transmittingDraft)
        } catch {
            // No discussion frame has been sent by this attempt. A previous
            // ambiguous attempt must still keep its exact operation frozen.
            // Uploads are not tracked for cleanup; a failed pre-send upload leaves
            // the draft available for Mike's next explicit Send.
            let names = frozen.files.map { $0.name.rawValue }.joined(separator: ", ")
            diagnose(.conversation, .discussionPreparation,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                     operationID: operation, request: binding.request, revision: binding.revision,
                     receipt: wasUncertain ? .unknown : .pendingUnconfirmed)
            do {
                try await store.markDiscussionOutcome(binding, operation: operation,
                    rejection: ExactText("Not delivered: " + (names.isEmpty ? "the discussion" : names) + " could not be prepared (\(error)). Draft retained."),
                    preserveUnsettled: wasUncertain,
                    context: context)
                let savedDraft = try await store.currentConversationSnapshot(context: context)
                    .threads[binding.request]?.drafts[binding.revision]
                try await persistDraft(savedDraft)
            } catch {
                diagnose(.localStore, .discussionPreparation, .failed, error: error,
                         operationID: operation, request: binding.request,
                         revision: binding.revision, receipt: .unknown)
                throw error
            }
            throw error
        }
        try validate()
        let result = await transport.sendDiscussion(frame, operationID: operation)
        try validate()
        switch result {
        case let .accepted(turn):
            try await store.markDiscussionAccepted(binding, operation: operation, turn: turn, context: context)
            diagnose(.conversation, .discussionSubmission, .accepted, operationID: operation,
                     request: binding.request, revision: binding.revision,
                     receipt: .acceptedAwaitingReplay)
            // The accepted turn is durable even if replay temporarily fails. A later
            // refresh joins it; the send response cannot move a replay cursor.
            do { try await replayConversationRouteA(using: transport) }
            catch {
                diagnose(.conversation, .conversationReplay,
                         NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                         operationID: operation, request: binding.request,
                         revision: binding.revision, receipt: .acceptedAwaitingReplay)
            }
        case let .rejected(reason):
            try await store.markDiscussionOutcome(binding, operation: operation, rejection: reason, context: context)
            diagnose(.conversation, .discussionSubmission, .rejected, operationID: operation,
                     request: binding.request, revision: binding.revision, receipt: .pendingUnconfirmed)
        case .operationConflict:
            try await store.markDiscussionConflict(binding, operation: operation, context: context)
            diagnose(.conversation, .discussionSubmission, .rejected,
                     causeCode: NativeDiagnosticCauseCode.serverReason("operation_conflict"),
                     operationID: operation, request: binding.request,
                     revision: binding.revision, receipt: .pendingUnconfirmed)
        case .unresolved:
            try await store.markDiscussionOutcome(binding, operation: operation, rejection: nil, context: context)
            diagnose(.conversation, .discussionSubmission, .unresolved, operationID: operation,
                     request: binding.request, revision: binding.revision, receipt: .unknown)
        }
        let latestDraft = try await store.currentConversationSnapshot(context: context)
            .threads[binding.request]?.drafts[binding.revision]
        if let latestDraft,
           latestDraft.text.rawValue.isEmpty, latestDraft.files.isEmpty,
           latestDraft.operationID == nil {
            try? await persistDraft(nil)
        } else {
            try? await persistDraft(latestDraft)
        }
        return result
    }

    private struct ConversationReplayProgress {
        var expected: UInt64
        let durableCursor: UInt64
        var accepted = false
        var high: UInt64?
        var recoveryReceipt: ConversationEvent?
        var recoveryRejection: ConversationValidationRejection?
        var recoveryOrigin: ExactText?
        var recoveryHandle: ExactText?
        var historyOnly = false
        var historyTarget: ConversationEvent?
        var historyUnusable = false
    }

    private struct ConversationReplayValidationFailure: Error, Sendable {
        let rejection: ConversationValidationRejection
    }

    private struct ReplayProgress {
        var expected: UInt64
        let durableCursor: UInt64
        var accepted = false
        var high: UInt64?
    }

    public init(store: AttentionDomainStore,
                context: ProfileContext,
                session: any AuthenticatedInstallationSession,
                attemptID: UUID? = nil,
                onProgress: @escaping @Sendable (NativeRelayProgressEvent) -> Void = { _ in },
                onDiagnostic: @escaping NativeClientDiagnosticSink = { _ in }) async throws {
        guard context.transportMode == .relay else { throw NativeRelayCoreError.fixtureProfile }
        guard session.authenticatedIdentity == context.identity else {
            throw NativeRelayCoreError.wrongInstallation
        }
        self.store = store
        self.context = context
        self.session = session
        self.onProgress = onProgress
        self.attemptID = attemptID
        self.onDiagnostic = onDiagnostic
        self.wire = try RelayWire(profile: context)
        self.inboxWire = try InboxPagingWire(profile: context)
        _ = try await store.snapshot(context: context)
    }

    public func deactivate() {
        active = false
        inboxViewNoticeTask?.cancel()
        inboxViewNoticeTask = nil
        latestInboxViewNotice = nil
        postCheckpointInboxConsumerTask?.cancel()
        postCheckpointInboxConsumerTask = nil
        postCheckpointAcknowledgementTask?.cancel()
        postCheckpointAcknowledgementTask = nil
        liveConversationConsumerTask?.cancel()
        liveConversationConsumerTask = nil
        pendingLiveConversationReplay = false
        conversationReadPositionSupportForSession = false
        resumePostCheckpointWaiters(throwing: NativeRelayCoreError.inactive)
    }

    /// Returns details for the most recent failed Route A fetch without
    /// changing the error thrown by `resyncAndDrainOutbox()`.
    public func takePostAckFailureDetails() -> NativePostAckFailureDetails? {
        defer { postAckFailureDetails = nil }
        return postAckFailureDetails
    }

    /// Foreground and push-triggered reconnects both start from C's durable
    /// cursor. A server reply is never itself a durable cursor or ACK.
    @discardableResult
    public func resyncAndDrainOutbox() async throws -> UInt64 {
        guard !busy else { throw NativeRelayCoreError.inactive }
        postAckFailureDetails = nil
        busy = true
        defer { releaseBusy() }
        try validate()
        diagnose(.relay, .ordinaryReplay, .began)
        do {
            try await store.beginRouteAReplay(context: context)
            activeInboxReplay = ReplayProgress(expected: 0, durableCursor: 0)
            onProgress(.nativeSyncReplayRequested)
            try await session.resync(wire.resync(since: 0)) { frame in
                try await self.consumeRouteAInboxReplay(frame)
            }
            guard let high = activeInboxReplay?.high else { throw NativeRelayCoreError.invalidReplay }
            activeInboxReplay = nil
            onProgress(.nativeSyncResynced)

            if let eventStream = session as? any AuthenticatedLiveEventSession {
                startPostCheckpointInboxConsumer(from: eventStream, baseline: high)
            }

            // Route A's unsequenced ordering view is fetched on the same relay
            // socket after the complete replay barrier. It never starts paging.
            await refreshInboxView(using: session)

            if let conversationSession = session as? any AuthenticatedConversationSession {
                try await replayConversationRouteA(using: conversationSession)
            } else {
                try await store.finishRouteAConversationReplay(context: context)
            }

            try validate()
            diagnose(.relay, .ordinaryReplay, .completed)
            return high
        } catch {
            activeInboxReplay = nil
            diagnose(.relay, .ordinaryReplay,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            throw error
        }
    }

    /// Sends exactly one operation as the direct result of a user action.
    /// This deliberately does not inspect or drain any operation list.
    public func sendOriginalOperation(operationID: UUID) async throws -> OriginalOperationResult {
        guard !busy else { throw NativeRelayCoreError.inactive }
        try validate()
        let submissions = try await store.snapshot(context: context).intents.values
        guard let submission = submissions.first(where: { $0.operationID == operationID }) else {
            return .unresolved
        }
        guard submission.operationID == operationID else {
            throw NativeRelayCoreError.mismatchedOperationResult
        }
        busy = true
        defer { releaseBusy() }
        diagnose(.answer, .originalOperationDelivery, .began,
                 operationID: operationID, request: submission.requestKey,
                 revision: submission.requestRevision, receipt: .pendingUnconfirmed)

        let result = try await session.sendOriginalOperation(submission.wireFrame,
                                                              operationID: operationID)
        try validate()
        switch result {
        case let .accepted(returnedID, terminalSequence):
            guard returnedID == operationID, terminalSequence > 0 else {
                throw NativeRelayCoreError.mismatchedOperationResult
            }
            try await store.recordAcceptedOperation(submission.intentID, operationID: returnedID,
                terminalSequence: terminalSequence, context: context)
            diagnose(.answer, .originalOperationDelivery, .accepted,
                     operationID: returnedID, request: submission.requestKey,
                     revision: submission.requestRevision, receipt: .acceptedAwaitingReplay)
        case let .refusedByRetraction(returnedID, timestamp):
            guard returnedID == operationID else { throw NativeRelayCoreError.mismatchedOperationResult }
            try await store.recordAnswerRefusedByRetraction(submission.intentID, operationID: returnedID,
                retractedAtMilliseconds: timestamp, context: context)
        case let .staleRevision(returnedID, currentRevision):
            guard returnedID == operationID, currentRevision > (submission.requestRevision ?? 1) else {
                throw NativeRelayCoreError.mismatchedOperationResult
            }
            try await store.recordAnswerStaleRevision(submission.intentID, operationID: returnedID,
                currentRevision: currentRevision, context: context)
        case let .unsupported(returnedID):
            guard returnedID == operationID, submission.isNoComment else {
                throw NativeRelayCoreError.mismatchedOperationResult
            }
            try await store.recordNoCommentUnsupported(submission.intentID, operationID: returnedID,
                context: context)
        case let .operationConflict(returnedID), let .failed(returnedID):
            guard returnedID == operationID else { throw NativeRelayCoreError.mismatchedOperationResult }
            try await store.recordAnswerNotDelivered(submission.intentID, operationID: returnedID,
                context: context)
        case .notTransmitted:
            break
        case .unresolved:
            break
        }
        return result
    }

    /// Reports one deliberate detail open. This operation is never persisted
    /// or retried when the relay is unavailable or its reply is uncertain.
    public func reportMessageOpen(_ operation: PendingMessageOpen) async -> MessageOpenOperationResult {
        guard !busy else { return .unresolved }
        busy = true
        defer { releaseBusy() }
        do {
            try validate()
            let wire = MessageOpenWire()
            let response = try await session.correlatedRequest(
                wire.request(for: operation), ref: MessageOpenWire.requestRef)
            try validate()
            let result = wire.decodeResult(response, for: operation)
            switch result {
            case .confirmed:
                diagnose(.relay, .messageOpen, .completed,
                    operationID: operation.operationID, request: operation.requestKey,
                    revision: operation.requestRevision, receipt: .terminal)
            case let .permanentlyRejected(reason):
                diagnose(.relay, .messageOpen, .rejected, causeCode: reason,
                    operationID: operation.operationID, request: operation.requestKey,
                    revision: operation.requestRevision, receipt: .terminal)
            case .unsupported:
                diagnose(.relay, .messageOpen, .unresolved, causeCode: "message_open_unsupported",
                    operationID: operation.operationID, request: operation.requestKey,
                    revision: operation.requestRevision, receipt: .pendingUnconfirmed)
            case .unresolved:
                diagnose(.relay, .messageOpen, .unresolved,
                    causeCode: "message_open_confirmation_unresolved",
                    operationID: operation.operationID, request: operation.requestKey,
                    revision: operation.requestRevision, receipt: .unknown)
            }
            return result
        } catch {
            diagnose(.relay, .messageOpen,
                NativeDiagnosticCauseCode.unresolvedTransition(for: error), error: error,
                operationID: operation.operationID, request: operation.requestKey,
                revision: operation.requestRevision, receipt: .unknown)
            return .unresolved
        }
    }

    private func consumeRouteAInboxReplay(_ frame: Data) async throws {
        try validate()
        guard var replay = activeInboxReplay, replay.high == nil else {
            throw NativeRelayCoreError.invalidReplay
        }
        if !replay.accepted {
            guard try wire.isResyncAccepted(frame) else { throw NativeRelayCoreError.invalidReplay }
            try await store.beginReplay(through: UInt64.max, context: context)
            replay.accepted = true
            activeInboxReplay = replay
            return
        }
        if let high = try? wire.decodeResynced(frame) {
            guard high == replay.expected else { throw NativeRelayCoreError.invalidReplay }
            try await store.finishReplay(at: high, context: context)
            replay.high = high
            activeInboxReplay = replay
            return
        }
        switch try wire.decodeUpdate(frame) {
        case let .event(event):
            guard replay.expected < UInt64.max, event.sequence == replay.expected + 1 else {
                throw NativeRelayCoreError.invalidReplay
            }
            switch await store.applyRelayEvent(event, context: context) {
            case .committed, .compatibleRepeat:
                break
            case let .deferred(cursor) where cursor == event.sequence:
                break
            case .gap, .conflict, .repairRequired, .deferred:
                throw NativeRelayCoreError.eventRejected
            }
            replay.expected = event.sequence
        case let .ignored(sequence):
            guard replay.expected < UInt64.max, sequence == replay.expected + 1 else {
                throw NativeRelayCoreError.invalidReplay
            }
            _ = try await store.advanceRelayCursor(overIgnoredUpdateAt: sequence, context: context)
            replay.expected = sequence
        case .viewChanged, .ignoredUnsequenced:
            break
        }
        activeInboxReplay = replay
    }

    private func replayConversationRouteA(using transport: any AuthenticatedConversationSession) async throws {
        try await store.beginRouteAConversationReplay(context: context)
        guard !conversationsUnavailable else {
            try await store.finishRouteAConversationReplay(context: context)
            return
        }
        diagnose(.conversation, .conversationReplay, .began)
        do {
            let wire = try ConversationWire(profile: context, endpointHost: transport.relayEndpointHost)
            _ = try await replayConversation(since: 0, using: transport, wire: wire)
            await flushCommittedLiveReplyArrivals()
            try await store.finishRouteAConversationReplay(context: context)
            diagnose(.conversation, .conversationReplay, .completed)
        } catch InstallationTransportError.conversationsUnavailable {
            conversationsUnavailable = true
            discoveredOriginURL = nil
            try await store.finishRouteAConversationReplay(context: context)
            return
        } catch {
            diagnose(.conversation, .conversationReplay,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            throw error
        }
        if liveConversationConsumerTask == nil,
           let events = transport as? any AuthenticatedConversationEventSession {
            liveConversationConsumerTask = Task { [weak self] in
                await self?.consumeLiveConversationSignals(from: events)
            }
        }
    }

    /// A page request originates from downward scrolling or from loading the
    /// held server view. Coalesce queued demand while another relay operation
    /// owns the socket, then return only after the page is durably saved.
    @discardableResult
    public func fetchNextInboxPage() async throws -> Bool {
        false
    }

    private func bootstrapInbox(using transport: any AuthenticatedInboxPagingSession,
                                trackingAcceptedOperations accepted: [Submission]) async throws -> UInt64 {
        let snapshot = try await store.snapshot(context: context)
        if let candidate = snapshot.inboxCandidate {
            let isCurrentStartup = activeInboxStartupID == candidate.startupID
            if candidate.checkpointRequestStarted {
                do {
                    try await recoverInboxCheckpoint(candidate, using: transport)
                    if isCurrentStartup, let checkpoint = try await store.snapshot(context: context).inboxCheckpoint,
                       checkpoint.checkpointAccepted, let high = checkpoint.highWater {
                        return try await replayInboxAndAcknowledge(
                            since: high,
                            trackingAcceptedOperations: accepted,
                            using: transport)
                    }
                } catch InboxPagingWireError.serverRefused("snapshot_replaced") {
                    guard let snapshotID = candidate.snapshotID else { throw NativeRelayCoreError.invalidReplay }
                    try await store.discardReplacedInboxCandidate(snapshotID: snapshotID, context: context)
                }
            } else if isCurrentStartup {
                return try await completeInboxCandidate(candidate, using: transport,
                    trackingAcceptedOperations: accepted)
            } else {
                // A prior launch may have persisted page/receipt work before it
                // requested the checkpoint. Keep that work and originals, then
                // capture this launch's one fresh bounded B2 snapshot.
                try await store.discardInboxCandidate(context: context)
            }
        }
        return try await createInboxCheckpoint(using: transport,
                                               trackingAcceptedOperations: accepted)
    }

    private func recoverInboxCheckpoint(_ candidate: InboxPagingCheckpoint,
                                        using transport: any AuthenticatedInboxPagingSession) async throws {
        guard candidate.checkpointEligible, candidate.checkpointRequestStarted,
              let snapshotID = candidate.snapshotID,
              let highWater = candidate.highWater else { throw NativeRelayCoreError.invalidReplay }
        let statusRef = Self.inboxRef("status")
        let statusReply = try await transport.inboxRequest(
            inboxWire.inboxCheckpointStatus(snapshotID: snapshotID, since: candidate.since,
                candidateHighWater: highWater, ref: statusRef), ref: statusRef)
        let accepted = try inboxWire.decodeCheckpointStatus(statusReply, ref: statusRef,
            snapshotID: snapshotID, highWater: highWater)
        if !accepted { try await acknowledgeInboxCheckpoint(candidate, using: transport) }
        _ = try await store.acceptInboxCheckpoint(snapshotID: snapshotID, highWater: highWater,
                                            context: context)
    }

    private func createInboxCheckpoint(using transport: any AuthenticatedInboxPagingSession,
                                       trackingAcceptedOperations accepted: [Submission]) async throws -> UInt64 {
        let cursor = try await store.snapshot(context: context).cursor
        let inventory = try await store.inboxOperationInventory(context: context)
        let candidate = try await store.beginInboxCandidate(startupID: UUID().uuidString.lowercased(),
            since: cursor, batches: Self.makeInboxBatches(inventory), context: context)
        activeInboxStartupID = candidate.startupID

        return try await completeInboxCandidate(candidate, using: transport,
                                                trackingAcceptedOperations: accepted)
    }

    private func completeInboxCandidate(_ candidate: InboxPagingCheckpoint,
                                        using transport: any AuthenticatedInboxPagingSession,
                                        trackingAcceptedOperations accepted: [Submission]) async throws -> UInt64 {
        if !candidate.hasInitialPage {
            let startRef = Self.inboxRef("start")
            let startReply = try await transport.inboxRequest(
                inboxWire.inboxStart(startupID: candidate.startupID, since: candidate.since,
                                     ref: startRef), ref: startRef)
            try validate()
            let firstPage = try inboxWire.decodeStart(startReply, ref: startRef)
            try await saveInboxPageRecoveringHeldEvents(firstPage.items) { restored, skipped, onFailure in
                var rejection: ConversationValidationRejection?
                try await store.saveInboxInitialPage(snapshotID: firstPage.snapshotID,
                    highWater: firstPage.highWater, items: firstPage.items,
                    nextCursor: firstPage.nextCursor, receiptCursor: firstPage.receiptCursor,
                    context: context, validationRejection: &rejection, restoredTurns: restored,
                    skippingHeldEvents: skipped)
            }
        }

        let eligible = try await prepareInboxCandidate(using: transport)
        try await acknowledgeInboxCheckpoint(eligible, using: transport)
        guard let snapshotID = eligible.snapshotID, let highWater = eligible.highWater else {
            throw NativeRelayCoreError.invalidReplay
        }
        let high = try await store.acceptInboxCheckpoint(snapshotID: snapshotID, highWater: highWater,
                                                   context: context)
        return try await replayInboxAndAcknowledge(since: high,
            trackingAcceptedOperations: accepted, using: transport)
    }

    /// Retry only the page's rejected held facts. The store publishes restored
    /// targets, skipped facts and page checkpoint in the same transaction.
    private func saveInboxPageRecoveringHeldEvents(_ items: [InboxSnapshotItem],
        save: ([UInt64: ConversationEvent], [UInt64: ConversationEvent],
               ((ConversationEvent, ConversationValidationRejection?) -> Void)?) async throws -> Void) async throws {
        var restored: [UInt64: ConversationEvent] = [:]
        var skipped: [UInt64: ConversationEvent] = [:]
        var historyOpened = false
        var attempted: Set<UInt64> = []
        while true {
            var heldFailure: (ConversationEvent, ConversationValidationRejection?)?
            do {
                try await save(restored, skipped) { event, rejection in heldFailure = (event, rejection) }
            } catch {
                guard let (event, rejection) = heldFailure,
                      isUnusableConversationMessage(error), skipped[event.sequence] == nil else { throw error }
                diagnose(.conversation, .inboxPage, .observed, error: error,
                    conversationSequence: event.sequence, conversationValidationRejection: rejection,
                    request: event.binding.request, revision: event.binding.revision)
                if rejection?.guardID == .referencedTurnExists,
                   case .delivered = event.fact,
                   !conversationRecoveryAttempts.contains(event.sequence),
                   attempted.insert(event.sequence).inserted,
                   let transport = session as? any AuthenticatedConversationSession,
                   let acceptance = items.first(where: { $0.key == event.binding.request })?.acceptance,
                   let origin = acceptance.origin, let handle = acceptance.conversation?.sessionHandle {
                    historyOpened = true
                    if let target = try await fetchHeldReceiptTarget(event, rejection: rejection!,
                        origin: origin, handle: handle, using: transport) {
                        restored[event.sequence] = target
                        continue
                    }
                }
                restored.removeValue(forKey: event.sequence)
                skipped[event.sequence] = event
                continue
            }
            // A failed page commit is retryable: only a committed outcome
            // consumes the lifetime recovery attempt for these held facts.
            conversationRecoveryAttempts.formUnion(attempted)
            // The page's transaction is durable. Only now advertise its skips.
            for event in skipped.values.sorted(by: { $0.sequence < $1.sequence }) {
                diagnose(.conversation, .conversationReplay, .observed,
                    causeCode: "conversation_message_skipped", conversationSequence: event.sequence,
                    request: event.binding.request, revision: event.binding.revision)
            }
            if historyOpened, let transport = session as? any AuthenticatedConversationSession {
                // Reset session stream position from the committed cursor and
                // consume every uncommitted suffix before acknowledging it.
                try await replayConversationAndAcknowledge(using: transport)
            }
            return
        }
    }

    private func fetchHeldReceiptTarget(_ receipt: ConversationEvent,
        rejection: ConversationValidationRejection, origin: ExactText, handle: ExactText,
        using transport: any AuthenticatedConversationSession) async throws -> ConversationEvent? {
        let wire = try ConversationWire(profile: context, endpointHost: transport.relayEndpointHost)
        conversationReplay = ConversationReplayProgress(expected: 0,
            durableCursor: try await store.currentConversationSnapshot(context: context).cursor,
            recoveryReceipt: receipt, recoveryRejection: rejection,
            recoveryOrigin: origin, recoveryHandle: handle, historyOnly: true)
        defer { conversationReplay = nil }
        do {
            try await transport.openConversation(wire.open(since: 0)) { frame in
                try await self.consumeConversationReplay(frame)
            }
        } catch InstallationTransportError.serverRejected { return nil }
          catch InstallationTransportError.conversationsUnavailable { return nil }
        guard let history = conversationReplay, history.high != nil else {
            throw NativeRelayCoreError.invalidReplay
        }
        return history.historyUnusable ? nil : history.historyTarget
    }

    private func prepareInboxCandidate(using transport: any AuthenticatedInboxPagingSession) async throws -> InboxPagingCheckpoint {
        while true {
            try await reconcilePendingInboxBatches(using: transport)
            try await drainInboxReceiptCursor(using: transport)
            let candidate = try await currentInboxCandidate()
            let covered = Set(candidate.batches.flatMap(\.operationIDs))
            let inventory = try await store.inboxOperationInventory(context: context)
            let missing = inventory.filter { !covered.contains($0.operationID) }
            if !missing.isEmpty {
                try await store.appendInboxReceiptBatches(Self.makeInboxBatches(missing), context: context)
                continue
            }
            do {
                return try await store.prepareInboxCheckpointAcknowledgement(context: context)
            } catch AttentionStoreError.inboxCheckpointIncomplete {
                let refreshed = try await store.inboxOperationInventory(context: context)
                let refreshedMissing = refreshed.filter { !covered.contains($0.operationID) }
                guard !refreshedMissing.isEmpty else { throw AttentionStoreError.inboxCheckpointIncomplete }
                try await store.appendInboxReceiptBatches(Self.makeInboxBatches(refreshedMissing), context: context)
            }
        }
    }

    private func reconcilePendingInboxBatches(using transport: any AuthenticatedInboxPagingSession) async throws {
        while true {
            let candidate = try await currentInboxCandidate()
            guard let snapshotID = candidate.snapshotID,
                  let highWater = candidate.highWater else { throw NativeRelayCoreError.invalidReplay }
            guard let batch = candidate.batches.first(where: { $0.results == nil }) else { return }
            let snapshot = try await store.snapshot(context: context)
            let submissionsByOperation = Dictionary(uniqueKeysWithValues:
                snapshot.intents.values.map { ($0.operationID, $0) })
            let submissions = try batch.operationIDs.map { operationID -> Submission in
                guard let submission = submissionsByOperation[operationID] else {
                    throw AttentionStoreError.inboxCheckpointIncomplete
                }
                return submission
            }
            let ref = Self.inboxRef("reconcile")
            let reconciliationOperations = try submissions.map {
                try inboxWire.reconciliationOperation(for: $0)
            }
            let noCommentSubmissions = submissions.filter(\.isNoComment)
            for submission in noCommentSubmissions {
                diagnose(.answer, .noReplyResponseReceive, .began,
                         operationIDSource: .localSubmission,
                         operationID: submission.operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .pendingUnconfirmed)
            }
            let reply: Data
            do {
                reply = try await transport.inboxRequest(
                    inboxWire.inboxReconcile(snapshotID: snapshotID, batchID: batch.batchID,
                        operations: reconciliationOperations, ref: ref), ref: ref)
            } catch {
                for submission in noCommentSubmissions {
                    diagnose(.answer, .noReplyResponseReceive, .unresolved,
                             noReplyResponseClass: .noResponse,
                             operationIDSource: .localSubmission,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                }
                throw error
            }
            let responseReceivedAt = NativeClientDiagnosticEvent.nowMilliseconds()
            for submission in noCommentSubmissions {
                diagnose(.answer, .noReplyResponseReceive, .completed,
                         noReplyResponseClass: .frameReceived,
                         operationIDSource: .localSubmission,
                         occurredAtMilliseconds: responseReceivedAt,
                         operationID: submission.operationID, request: submission.requestKey,
                         revision: submission.requestRevision)
            }
            try validate()
            let reconciliation: InboxReconciliationResponse
            do {
                reconciliation = try inboxWire.decodeReconciliation(reply, ref: ref,
                    snapshotID: snapshotID, highWater: highWater,
                    batchID: batch.batchID,
                    operationIDs: batch.operationIDs,
                    noCommentOperationIDs: Set(noCommentSubmissions.map(\.operationID)))
            } catch {
                for submission in noCommentSubmissions {
                    diagnose(.answer, .noReplyResponseDecode, .failed,
                             error: error,
                             noReplyResponseClass: .unparseableFrame,
                             operationIDSource: .localSubmission,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                }
                throw error
            }
            let receiptsByID = Dictionary(uniqueKeysWithValues:
                reconciliation.receipts.map { ($0.operationID, $0) })
            let missing = Set(reconciliation.missingOperationIDs)
            for submission in noCommentSubmissions {
                if let receipt = receiptsByID[submission.operationID] {
                    let responseClass = Self.noReplyResponseClass(for: receipt.status)
                    let sequence = receipt.terminal?.sequence
                    diagnose(.answer, .noReplyResponseDecode, .completed,
                             noReplyResponseClass: responseClass,
                             operationIDSource: .pagingWireOperationID,
                             terminalSequence: sequence, lifecycleSequence: sequence,
                             operationID: receipt.operationID, request: submission.requestKey,
                             revision: submission.requestRevision,
                             receipt: Self.noReplyReceiptState(for: receipt.status))
                    if let terminal = receipt.terminal {
                        diagnose(.answer, .noReplyLifecycleApply, .began,
                                 noReplyResponseClass: Self.noReplyTerminalClass(for: terminal),
                                 operationIDSource: .pagingWireOperationID,
                                 terminalSequence: terminal.sequence,
                                 lifecycleSequence: terminal.sequence,
                                 operationID: receipt.operationID, request: submission.requestKey,
                                 revision: submission.requestRevision, receipt: .terminal)
                    }
                } else if missing.contains(submission.operationID) {
                    diagnose(.answer, .noReplyResponseDecode, .completed,
                             noReplyResponseClass: .missingReceipt,
                             operationIDSource: .localSubmission,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                } else {
                    diagnose(.answer, .noReplyResponseDecode, .unresolved,
                             noReplyResponseClass: .missingReceipt,
                             operationIDSource: .localSubmission,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                }
                diagnose(.answer, .noReplyOperationApply, .began,
                         operationIDSource: .localSubmission,
                         operationID: submission.operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .pendingUnconfirmed)
            }
            do {
                try await store.saveInboxReceiptBatch(batch.batchID,
                    results: reconciliation.receipts,
                    missingOperationIDs: reconciliation.missingOperationIDs,
                    context: context)
            } catch {
                for submission in noCommentSubmissions {
                    diagnose(.answer, .noReplyOperationApply, .failed, error: error,
                             operationIDSource: .localSubmission,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                }
                throw error
            }
            for submission in noCommentSubmissions {
                if let receipt = receiptsByID[submission.operationID] {
                    let applied: NativeDiagnosticTransition = switch receipt.status {
                    case .committed: .completed
                    case .operationConflict, .refused: .rejected
                    case .notCommittedAtSnapshot: .unresolved
                    }
                    diagnose(.answer, .noReplyOperationApply, applied,
                             noReplyResponseClass: Self.noReplyResponseClass(for: receipt.status),
                             operationIDSource: .pagingWireOperationID,
                             terminalSequence: receipt.terminal?.sequence,
                             lifecycleSequence: receipt.terminal?.sequence,
                             operationID: receipt.operationID, request: submission.requestKey,
                             revision: submission.requestRevision,
                             receipt: Self.noReplyReceiptState(for: receipt.status))
                    if let terminal = receipt.terminal {
                        diagnose(.answer, .noReplyLifecycleApply, .completed,
                                 noReplyResponseClass: Self.noReplyTerminalClass(for: terminal),
                                 operationIDSource: .pagingWireOperationID,
                                 terminalSequence: terminal.sequence,
                                 lifecycleSequence: terminal.sequence,
                                 operationID: receipt.operationID, request: submission.requestKey,
                                 revision: submission.requestRevision, receipt: .terminal)
                    }
                } else if missing.contains(submission.operationID) {
                    diagnose(.answer, .noReplyOperationApply, .unresolved,
                             noReplyResponseClass: .missingReceipt,
                             operationIDSource: .localSubmission,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                } else {
                    diagnose(.answer, .noReplyOperationApply, .unresolved,
                             noReplyResponseClass: .missingReceipt,
                             operationIDSource: .localSubmission,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                }
            }
        }
    }

    private static func noReplyResponseClass(for status: InboxOperationReceiptStatus)
        -> NativeDiagnosticNoReplyResponseClass {
        switch status {
        case .committed: .committedReceipt
        case .operationConflict: .operationConflictReceipt
        case .notCommittedAtSnapshot: .notCommittedReceipt
        case .refused: .refusedReceipt
        }
    }

    private static func noReplyReceiptState(for status: InboxOperationReceiptStatus)
        -> NativeDiagnosticReceiptState {
        switch status {
        case .committed, .refused: .terminal
        case .operationConflict: .unknown
        case .notCommittedAtSnapshot: .pendingUnconfirmed
        }
    }

    private static func noReplyTerminalClass(for event: RelayEvent)
        -> NativeDiagnosticNoReplyResponseClass {
        guard case let .terminal(_, state, _) = event.body else { return .terminalOther }
        switch state {
        case .noComment:
            return NativeDiagnosticNoReplyResponseClass.terminalNoComment
        case .answered:
            return NativeDiagnosticNoReplyResponseClass.terminalAnswered
        default:
            return NativeDiagnosticNoReplyResponseClass.terminalOther
        }
    }

    private func drainInboxReceiptCursor(using transport: any AuthenticatedInboxPagingSession) async throws {
        while true {
            let candidate = try await currentInboxCandidate()
            guard let snapshotID = candidate.snapshotID,
                  let highWater = candidate.highWater,
                  let cursor = candidate.receiptCursor else { return }
            let ref = Self.inboxRef("receipts")
            let reply = try await transport.inboxRequest(
                inboxWire.inboxReceipts(snapshotID: snapshotID, cursor: cursor, ref: ref), ref: ref)
            let responseReceivedAt = NativeClientDiagnosticEvent.nowMilliseconds()
            try validate()
            let page = try inboxWire.decodeReceipts(reply, ref: ref,
                snapshotID: snapshotID, highWater: highWater)
            guard !page.events.isEmpty || page.nextCursor == nil else {
                throw InboxPagingWireError.invalidFrame
            }
            let noCommentSubmissions = Dictionary(grouping:
                try await store.snapshot(context: context).intents.values.filter(\.isNoComment),
                by: \.requestKey)
            let lifecycleEvents: [(event: RelayEvent,
                                   request: RequestKey,
                                   submission: Submission?,
                                   responseClass: NativeDiagnosticNoReplyResponseClass)] = page.events.compactMap { event in
                guard case let .terminal(key, _, _) = event.body else { return nil }
                let matching = noCommentSubmissions[key] ?? []
                guard !matching.isEmpty || Self.noReplyTerminalClass(for: event) == .terminalNoComment else {
                    return nil
                }
                let submission = matching.count == 1 ? matching.first : nil
                return (event, key, submission, Self.noReplyTerminalClass(for: event))
            }
            for lifecycle in lifecycleEvents {
                let operationIDSource: NativeDiagnosticOperationIDSource? =
                    lifecycle.submission == nil ? nil : .localRequestCorrelation
                diagnose(.answer, .noReplyResponseReceive, .completed,
                         noReplyResponseClass: .frameReceived,
                         operationIDSource: operationIDSource,
                         lifecycleSequence: lifecycle.event.sequence,
                         occurredAtMilliseconds: responseReceivedAt,
                         operationID: lifecycle.submission?.operationID,
                         request: lifecycle.request,
                         revision: lifecycle.submission?.requestRevision)
                diagnose(.answer, .noReplyResponseDecode, .completed,
                         noReplyResponseClass: lifecycle.responseClass,
                         operationIDSource: operationIDSource,
                         lifecycleSequence: lifecycle.event.sequence,
                         operationID: lifecycle.submission?.operationID,
                         request: lifecycle.request,
                         revision: lifecycle.submission?.requestRevision)
                diagnose(.answer, .noReplyLifecycleApply, .began,
                         noReplyResponseClass: lifecycle.responseClass,
                         operationIDSource: operationIDSource,
                         lifecycleSequence: lifecycle.event.sequence,
                         operationID: lifecycle.submission?.operationID,
                         request: lifecycle.request,
                         revision: lifecycle.submission?.requestRevision)
            }
            do {
                try await store.saveInboxReceiptChunk(snapshotID: snapshotID, cursor: cursor,
                    events: page.events, nextCursor: page.nextCursor, context: context)
            } catch {
                for lifecycle in lifecycleEvents {
                    diagnose(.answer, .noReplyLifecycleApply, .failed, error: error,
                             noReplyResponseClass: lifecycle.responseClass,
                             operationIDSource: lifecycle.submission == nil ? nil : .localRequestCorrelation,
                             lifecycleSequence: lifecycle.event.sequence,
                             operationID: lifecycle.submission?.operationID,
                             request: lifecycle.request,
                             revision: lifecycle.submission?.requestRevision)
                }
                throw error
            }
            for lifecycle in lifecycleEvents {
                diagnose(.answer, .noReplyLifecycleApply, .completed,
                         noReplyResponseClass: lifecycle.responseClass,
                         operationIDSource: lifecycle.submission == nil ? nil : .localRequestCorrelation,
                         lifecycleSequence: lifecycle.event.sequence,
                         operationID: lifecycle.submission?.operationID,
                         request: lifecycle.request,
                         revision: lifecycle.submission?.requestRevision,
                         receipt: .terminal)
            }
        }
    }

    private func acknowledgeInboxCheckpoint(_ candidate: InboxPagingCheckpoint,
                                            using transport: any AuthenticatedInboxPagingSession) async throws {
        guard let snapshotID = candidate.snapshotID, let highWater = candidate.highWater else {
            throw NativeRelayCoreError.invalidReplay
        }
        let ref = Self.inboxRef("checkpoint")
        let reply = try await transport.inboxRequest(
            inboxWire.inboxCheckpointAck(snapshotID: snapshotID, highWater: highWater,
                batchIDs: candidate.batches.map(\.batchID), ref: ref), ref: ref)
        try validate()
        try inboxWire.decodeCheckpointAck(reply, ref: ref,
                                          snapshotID: snapshotID, highWater: highWater)
    }

    private func currentInboxCandidate() async throws -> InboxPagingCheckpoint {
        guard let candidate = try await store.snapshot(context: context).inboxCandidate else {
            throw AttentionStoreError.inboxCheckpointIncomplete
        }
        return candidate
    }

    private static func makeInboxBatches(_ submissions: [Submission]) -> [InboxReceiptBatch] {
        let batchSize = 8
        return stride(from: 0, to: submissions.count, by: batchSize).map { start in
            let slice = submissions[start..<min(start + batchSize, submissions.count)]
            return InboxReceiptBatch(batchID: UUID().uuidString.lowercased(),
                                     operationIDs: slice.map(\.operationID))
        }
    }

    private static func inboxRef(_ operation: String) -> String {
        "native-inbox-\(operation)-\(UUID().uuidString.lowercased())"
    }

    private func replayInboxAndAcknowledge(since cursor: UInt64,
                                           trackingAcceptedOperations submissions: [Submission] = [],
                                           using transport: any AuthenticatedInboxPagingSession) async throws -> UInt64 {
        for submission in submissions where operationReplayDiagnosticStates[submission.operationID] == nil {
            diagnoseOperationReplay(.began, submission: submission, receipt: .acceptedAwaitingReplay)
        }
        onProgress(.nativeSyncReplayRequested)
        diagnose(.relay, .ordinaryReplay, .began)
        do {
            let replayStart = try await store.snapshot(context: context).cursor
            guard replayStart == cursor else { throw NativeRelayCoreError.invalidReplay }
            let checkpointHighWater = try await currentInboxCheckpointHighWater()
            let high = try await replayInbox(since: replayStart, using: transport)
            onProgress(.nativeSyncResynced)
            let eventStream = transport as? any AuthenticatedInboxEventStreamSession
            if let eventStream, eventStream.supportsPostCheckpointInboxEvents {
                // Start draining after resynced(K), before awaiting ACK(K), so
                // a bounded transport handoff cannot block that correlated
                // reply behind a burst of later live events. The consumer may
                // persist H+1 onward now, but its ACK pump stays gated until K.
                startPostCheckpointInboxConsumer(from: eventStream, baseline: checkpointHighWater)
            }
            // The accepted checkpoint is a lower bound for replay. A replay
            // that reaches only its starting cursor adds no event and must not
            // repeat the ordinary ACK for that already durable sequence.
            if high > replayStart {
                try await session.acknowledge(wire.acknowledge(high))
                onProgress(.nativeSyncAcknowledged)
                diagnose(.relay, .acknowledgement, .completed)
            }
            if let eventStream, eventStream.supportsPostCheckpointInboxEvents {
                openPostCheckpointAcknowledgementGate(through: high)
            }
            diagnose(.relay, .ordinaryReplay, .completed)
            await completeAcceptedOperationReplayDiagnostics(submissions)
            return high
        } catch {
            failPostCheckpointInbox(error)
            diagnose(.relay, .ordinaryReplay,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            let outstanding = try? await store.acceptedOperationsAwaitingTerminalReplay(context: context)
            let ids = outstanding.map { Set($0.map(\.operationID)) }
            for submission in submissions {
                diagnoseOperationReplay(NativeDiagnosticCauseCode.failureTransition(for: error),
                    causeCode: NativeDiagnosticCauseCode.forError(error), submission: submission,
                    receipt: ids.map { $0.contains(submission.operationID) ? .acceptedAwaitingReplay : .terminal } ?? .unknown)
            }
            throw error
        }
    }

    private func currentInboxCheckpointHighWater() async throws -> UInt64 {
        guard let checkpoint = try await store.snapshot(context: context).inboxCheckpoint,
              checkpoint.checkpointAccepted,
              let highWater = checkpoint.highWater else {
            throw NativeRelayCoreError.invalidReplay
        }
        return highWater
    }

    private func startPostCheckpointInboxConsumer(
        from eventStream: any AuthenticatedLiveEventSession,
        baseline: UInt64
    ) {
        guard postCheckpointInboxConsumerTask == nil else { return }
        postCheckpointInboxFailure = nil
        postCheckpointAcknowledgementGateOpen = false
        postCheckpointAcknowledgedCursor = baseline
        postCheckpointInboxConsumerTask = Task { [weak self] in
            guard let self else { return }
            await self.consumePostCheckpointInboxEvents(from: eventStream)
        }
    }

    private func consumePostCheckpointInboxEvents(
        from eventStream: any AuthenticatedLiveEventSession
    ) async {
        do {
            while !Task.isCancelled {
                let frame = try await eventStream.nextLiveEvent()
                let update = try wire.decodeUpdate(frame)
                if case let .viewChanged(revision) = update {
                    scheduleInboxViewRefresh(using: eventStream, noticedRevision: revision)
                    continue
                }
                if case .ignoredUnsequenced = update { continue }
                let previousCursor = try await validatedRelayCursor()
                let sequence: UInt64
                switch update {
                case let .event(event):
                    sequence = event.sequence
                    if sequence <= previousCursor { continue }
                    guard previousCursor < UInt64.max, sequence == previousCursor + 1 else {
                        throw NativeRelayCoreError.invalidReplay
                    }
                    switch await store.applyRelayEvent(event, context: context) {
                    case .committed, .compatibleRepeat:
                        break
                    case let .deferred(contiguousCursor) where contiguousCursor == event.sequence:
                        break
                    case .gap, .conflict, .repairRequired, .deferred:
                        throw NativeRelayCoreError.eventRejected
                    }
                case let .ignored(ignoredSequence):
                    sequence = ignoredSequence
                    if sequence <= previousCursor { continue }
                    guard previousCursor < UInt64.max, sequence == previousCursor + 1 else {
                        throw NativeRelayCoreError.invalidReplay
                    }
                    _ = try await store.advanceRelayCursor(overIgnoredUpdateAt: ignoredSequence, context: context)
                    diagnose(.relay, .ordinaryReplay, .observed, causeCode: "unknown_update_kind")
                case .viewChanged:
                    continue
                case .ignoredUnsequenced:
                    continue
                }
                _ = sequence
            }
        } catch {
            guard !Task.isCancelled else { return }
            failPostCheckpointInbox(error)
            diagnose(.relay, .ordinaryReplay,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
        }
    }

    private func scheduleInboxViewRefresh(using transport: any AuthenticatedInstallationSession,
                                         noticedRevision: ExactText) {
        guard active, !inboxViewUnsupportedForConnection else { return }
        latestInboxViewNotice = noticedRevision
        guard inboxViewNoticeTask == nil else { return }
        // View replies share the socket reader with ordinary events. Keep its
        // bounded inbox mailbox draining while a view request waits for a reply.
        inboxViewNoticeTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshNoticedInboxViews(using: transport)
        }
    }

    private func refreshNoticedInboxViews(using transport: any AuthenticatedInstallationSession) async {
        defer { inboxViewNoticeTask = nil }
        while active, !Task.isCancelled, let revision = latestInboxViewNotice {
            latestInboxViewNotice = nil
            await refreshInboxView(using: transport, noticedRevision: revision)
        }
    }

    private func refreshInboxView(using transport: any AuthenticatedInstallationSession,
                                  noticedRevision: ExactText? = nil) async {
        guard !inboxViewUnsupportedForConnection else { return }
        let heldRevision = (try? await store.snapshot(context: context).inboxView?.revision) ?? nil
        if let noticedRevision, heldRevision == noticedRevision { return }
        if inboxViewFetchInProgress {
            pendingInboxViewRevision = noticedRevision
            return
        }
        inboxViewFetchInProgress = true
        defer { inboxViewFetchInProgress = false }

        var noticeToResolve = noticedRevision
        while active {
            let knownRevision = (try? await store.snapshot(context: context).inboxView?.revision) ?? nil
            if let noticeToResolve, noticeToResolve == knownRevision { break }
            pendingInboxViewRevision = nil
            let ref = Self.inboxRef("view")
            do {
                let reply = try await transport.correlatedRequest(
                    inboxWire.viewGet(knownRevision: knownRevision, ref: ref), ref: ref)
                guard active else { return }
                switch inboxWire.decodeViewGet(reply, ref: ref, knownRevision: knownRevision) {
                case let .updated(view):
                    try await store.setInboxView(view, context: context)
                case .unchanged:
                    break
                case .unsupported:
                    inboxViewUnsupportedForConnection = true
                    try? await store.setInboxView(nil, context: context)
                case .unavailable:
                    try? await store.setInboxView(nil, context: context)
                }
                if inboxViewUnsupportedForConnection { break }
            } catch {
                try? await store.setInboxView(nil, context: context)
                break
            }
            let pending = pendingInboxViewRevision
            pendingInboxViewRevision = nil
            let currentRevision = (try? await store.snapshot(context: context).inboxView?.revision) ?? nil
            guard let pending, pending != currentRevision else {
                break
            }
            noticeToResolve = pending
        }
    }

    private func scheduleInboxViewPageLoad() {
        Task { [weak self] in
            await self?.loadPagesUntilInboxViewIsHeld()
        }
    }

    private func loadPagesUntilInboxViewIsHeld() async {
        while active {
            guard let snapshot = try? await store.snapshot(context: context),
                  let view = snapshot.inboxView,
                  let checkpoint = snapshot.inboxCheckpoint,
                  checkpoint.checkpointAccepted,
                  checkpoint.hasInitialPage else { return }
            if Set(view.entries.map(\.key)).isSubset(of: Set(snapshot.requests.keys)) { return }
            if checkpoint.loadedKeys.contains(where: { snapshot.remoteStates[$0]?.isTerminal == true }) {
                return
            }
            guard checkpoint.nextCursor != nil else { return }
            let loadedBefore = checkpoint.loadedKeys
            guard (try? await fetchNextInboxPage()) == true else { return }
            guard let next = try? await store.snapshot(context: context),
                  let nextCheckpoint = next.inboxCheckpoint else { return }
            let newlyLoaded = nextCheckpoint.loadedKeys.subtracting(loadedBefore)
            if newlyLoaded.contains(where: { next.remoteStates[$0]?.isTerminal == true }) { return }
            if nextCheckpoint.loadedKeys == loadedBefore,
               nextCheckpoint.nextCursor == checkpoint.nextCursor { return }
        }
    }

    private func openPostCheckpointAcknowledgementGate(through sequence: UInt64) {
        postCheckpointAcknowledgedCursor = max(postCheckpointAcknowledgedCursor ?? 0, sequence)
        postCheckpointAcknowledgementGateOpen = true
        resumePostCheckpointAcknowledgementWaiters(through: postCheckpointAcknowledgedCursor ?? sequence)
        startPostCheckpointAcknowledgementPumpIfNeeded()
    }

    private func queuePostCheckpointAcknowledgement(through sequence: UInt64) {
        guard postCheckpointInboxFailure == nil,
              sequence > (postCheckpointAcknowledgedCursor ?? 0) else { return }
        pendingPostCheckpointAcknowledgement = max(pendingPostCheckpointAcknowledgement ?? 0, sequence)
        startPostCheckpointAcknowledgementPumpIfNeeded()
    }

    private func startPostCheckpointAcknowledgementPumpIfNeeded() {
        guard postCheckpointAcknowledgementGateOpen,
              postCheckpointAcknowledgementTask == nil,
              pendingPostCheckpointAcknowledgement != nil,
              postCheckpointInboxFailure == nil else { return }
        postCheckpointAcknowledgementTask = Task { [weak self] in
            guard let self else { return }
            await self.drainPostCheckpointAcknowledgements()
        }
    }

    private func drainPostCheckpointAcknowledgements() async {
        do {
            while postCheckpointAcknowledgementGateOpen,
                  let sequence = pendingPostCheckpointAcknowledgement {
                pendingPostCheckpointAcknowledgement = nil
                guard sequence > (postCheckpointAcknowledgedCursor ?? 0) else { continue }
                try await session.acknowledge(wire.acknowledge(sequence))
                postCheckpointAcknowledgedCursor = sequence
                onProgress(.nativeSyncAcknowledged)
                diagnose(.relay, .acknowledgement, .completed)
                resumePostCheckpointAcknowledgementWaiters(through: sequence)
            }
            postCheckpointAcknowledgementTask = nil
            startPostCheckpointAcknowledgementPumpIfNeeded()
        } catch {
            postCheckpointAcknowledgementTask = nil
            failPostCheckpointInbox(error)
            diagnose(.relay, .acknowledgement,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
        }
    }

    private func waitForPostCheckpointAcknowledgement(through sequence: UInt64) async throws {
        try throwPostCheckpointInboxFailureIfPresent()
        if (postCheckpointAcknowledgedCursor ?? 0) >= sequence { return }
        try await withCheckedThrowingContinuation { continuation in
            postCheckpointAcknowledgementWaiters.append(
                InboxSequenceWaiter(target: sequence, continuation: continuation))
            startPostCheckpointAcknowledgementPumpIfNeeded()
        }
    }

    private func resumePostCheckpointAcknowledgementWaiters(through sequence: UInt64) {
        let ready = postCheckpointAcknowledgementWaiters.filter { $0.target <= sequence }
        postCheckpointAcknowledgementWaiters.removeAll { $0.target <= sequence }
        ready.forEach { $0.continuation.resume() }
    }

    private func resumePostCheckpointWaiters(throwing error: any Error) {
        let waiters = postCheckpointAcknowledgementWaiters
        postCheckpointAcknowledgementWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(throwing: error) }
    }

    private func failPostCheckpointInbox(_ error: any Error) {
        guard postCheckpointInboxFailure == nil else { return }
        postCheckpointInboxFailure = error
        postCheckpointInboxConsumerTask?.cancel()
        postCheckpointInboxConsumerTask = nil
        resumePostCheckpointWaiters(throwing: error)
    }

    private func throwPostCheckpointInboxFailureIfPresent() throws {
        if let postCheckpointInboxFailure { throw postCheckpointInboxFailure }
    }

    private static func acceptedTerminalSequence(_ submission: Submission) -> UInt64? {
        guard case let .accepted(sequence) = submission.disposition else { return nil }
        return sequence
    }

    private func completeAcceptedOperationReplayDiagnostics(_ submissions: [Submission]) async {
        guard !submissions.isEmpty else { return }
        let outstanding = try? await store.acceptedOperationsAwaitingTerminalReplay(context: context)
        let ids = outstanding.map { Set($0.map(\.operationID)) }
        for submission in submissions {
            let settled = ids.map { !$0.contains(submission.operationID) } ?? false
            diagnoseOperationReplay(settled ? .completed : .unresolved,
                causeCode: settled ? nil : (outstanding == nil ? "original_operation_state_unavailable" :
                    "original_operation_terminal_not_observed"),
                submission: submission,
                receipt: settled ? .terminal : (outstanding == nil ? .unknown : .acceptedAwaitingReplay))
            if settled { acceptedReplaySubmissions.removeValue(forKey: submission.operationID) }
        }
    }

    private func replayInbox(since cursor: UInt64,
                             using transport: any AuthenticatedInboxPagingSession) async throws -> UInt64 {
        try validate()
        let snapshot = try await store.snapshot(context: context)
        guard let checkpoint = snapshot.inboxCheckpoint,
              checkpoint.checkpointAccepted,
              let snapshotID = checkpoint.snapshotID,
              let highWater = checkpoint.highWater,
              cursor == snapshot.cursor,
              cursor >= highWater else { throw NativeRelayCoreError.invalidReplay }
        activeInboxReplay = ReplayProgress(expected: cursor, durableCursor: snapshot.cursor)
        defer { activeInboxReplay = nil }
        let ref = Self.inboxRef("replay")
        try await transport.attachInboxReplay(
            inboxWire.inboxReplayAttach(snapshotID: snapshotID, since: cursor, ref: ref), ref: ref) { frame in
                try await self.consumeInboxReplay(frame, ref: ref,
                                                   snapshotID: snapshotID, highWater: highWater)
            }
        try validate()
        guard let high = activeInboxReplay?.high else { throw NativeRelayCoreError.invalidReplay }
        return high
    }

    private func consumeInboxReplay(_ frame: Data, ref: String,
                                    snapshotID: String, highWater: UInt64) async throws {
        try validate()
        guard var replay = activeInboxReplay, replay.high == nil else {
            throw NativeRelayCoreError.invalidReplay
        }
        if !replay.accepted {
            guard try inboxWire.isReplayAccepted(frame, ref: ref,
                                                 snapshotID: snapshotID, highWater: highWater) else {
                throw NativeRelayCoreError.invalidReplay
            }
            try await store.beginReplay(through: UInt64.max, context: context)
            replay.accepted = true
            activeInboxReplay = replay
            return
        }
        if let high = try? wire.decodeResynced(frame) {
            guard high >= replay.durableCursor, high == replay.expected else {
                throw NativeRelayCoreError.invalidReplay
            }
            try await store.finishReplay(at: high, context: context)
            replay.high = high
            activeInboxReplay = replay
            return
        }
        switch try wire.decodeUpdate(frame) {
        case let .event(event):
            guard replay.expected < UInt64.max, event.sequence == replay.expected + 1 else {
                throw NativeRelayCoreError.invalidReplay
            }
            switch await store.applyRelayEvent(event, context: context) {
            case .committed, .compatibleRepeat:
                break
            case let .deferred(cursor) where cursor == event.sequence:
                break
            case .gap, .conflict, .repairRequired, .deferred:
                throw NativeRelayCoreError.eventRejected
            }
            replay.expected = event.sequence
        case let .ignored(sequence):
            guard replay.expected < UInt64.max, sequence == replay.expected + 1 else {
                throw NativeRelayCoreError.invalidReplay
            }
            _ = try await store.advanceRelayCursor(overIgnoredUpdateAt: sequence, context: context)
            replay.expected = sequence
            diagnose(.relay, .ordinaryReplay, .observed, causeCode: "unknown_update_kind")
        case .viewChanged, .ignoredUnsequenced:
            activeInboxReplay = replay
            return
        }
        activeInboxReplay = replay
    }

    private func replayConversationAndAcknowledge(using transport: any AuthenticatedConversationSession) async throws {
        guard !conversationsUnavailable else { return }
        diagnose(.conversation, .conversationReplay, .began)
        let wire = try ConversationWire(profile: context, endpointHost: transport.relayEndpointHost)
        do {
            var high = try await replayConversation(since: store.currentConversationSnapshot(context: context).cursor,
                using: transport, wire: wire)
            await flushCommittedLiveReplyArrivals()
            do { try await transport.acknowledgeConversation(wire.acknowledge(high)) }
            catch InstallationTransportError.acknowledgementBehind {
                diagnose(.conversation, .acknowledgement, .retrying,
                         error: InstallationTransportError.acknowledgementBehind)
                high = try await replayConversation(since: 0, using: transport, wire: wire)
                await flushCommittedLiveReplyArrivals()
                try await transport.acknowledgeConversation(wire.acknowledge(high))
            }
            diagnose(.conversation, .acknowledgement, .completed)
            diagnose(.conversation, .conversationReplay, .completed)
        } catch InstallationTransportError.conversationsUnavailable {
            conversationsUnavailable = true
            discoveredOriginURL = nil
            // Ordinary replay and answer delivery already succeeded. The missing
            // optional projection must not undo their connection confirmation.
            return
        } catch let failure as ConversationReplayValidationFailure {
            diagnose(.conversation, .conversationReplay, .failed,
                     error: ConversationError.invalidBinding,
                     conversationValidationRejection: failure.rejection)
            throw ConversationError.invalidBinding
        } catch {
            diagnose(.conversation, .conversationReplay,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            throw error
        }
        // The relay pushes later entries only once this device has opened the
        // projection, so start listening for them after the first open.
        if liveConversationConsumerTask == nil,
           let events = transport as? any AuthenticatedConversationEventSession {
            liveConversationConsumerTask = Task { [weak self] in
                await self?.consumeLiveConversationSignals(from: events)
            }
        }
    }

    /// Sends one debounced read mark from the open chat. The operation exists
    /// only for this call; a missing reply is discarded and never replayed.
    public func reportConversationReadPosition(_ request: RequestKey,
                                               through turnID: ExactText) async {
        guard active, conversationReadPositionSupportForSession,
              let transport = session as? any AuthenticatedConversationSession else { return }
        while busy && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !Task.isCancelled, !busy else { return }
        busy = true
        defer { releaseBusy() }
        do {
            try validate()
            let snapshot = try await store.currentConversationSnapshot(context: context)
            guard snapshot.chatReadPositionSupport == true,
                  let turn = snapshot.threads[request]?.turns.first(where: {
                      $0.id == turnID && $0.kind == .reply && $0.author == .origin
                  }), let sequence = turn.conversationSequence, sequence > 0 else { return }
            let pending = PendingConversationReadPosition(request: request,
                operationID: UUID(), readThroughConversationSequence: sequence)
            let wire = try ConversationWire(profile: context, endpointHost: transport.relayEndpointHost)
            let frame = try wire.conversationReadPosition(pending)
            diagnose(.conversation, .conversationReadPosition, .began,
                     operationID: pending.operationID, request: request)
            let result = await transport.sendConversationReadPosition(frame, operationID: pending.operationID)
            try validate()
            switch result {
            case let .accepted(position, eventSequence, eventID, duplicate):
                guard position >= sequence, (eventSequence == nil) == (eventID == nil) else {
                    diagnose(.conversation, .conversationReadPosition, .unresolved,
                             causeCode: "read_position_response_mismatch",
                             operationID: pending.operationID, request: request)
                    return
                }
                diagnose(.conversation, .conversationReadPosition, .completed,
                         causeCode: duplicate ? "duplicate_read_position" : nil,
                         operationID: pending.operationID, request: request)
                if eventSequence != nil { try await replayConversationRouteA(using: transport) }
            case let .rejected(reason):
                diagnose(.conversation, .conversationReadPosition, .rejected,
                         causeCode: "read_position_\(reason.rawValue)",
                         operationID: pending.operationID, request: request)
            case .unresolved:
                diagnose(.conversation, .conversationReadPosition, .unresolved,
                         operationID: pending.operationID, request: request)
            }
        } catch {
            diagnose(.conversation, .conversationReadPosition,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                     request: request)
        }
    }

    private func consumeLiveConversationSignals(from events: any AuthenticatedConversationEventSession) async {
        while !Task.isCancelled {
            let signal: LiveConversationSignal
            do { signal = try await events.nextLiveConversationSignal() }
            catch { return }
            for arrival in signal.replyArrivals {
                await retainLiveReplyArrival(arrival)
            }
            await replayLiveConversation()
        }
    }

    private func retainLiveReplyArrival(_ arrival: LiveConversationReplyArrival) async {
        if pendingLiveReplyArrivals[arrival.conversationSequence] == nil {
            pendingLiveReplyArrivals[arrival.conversationSequence] = arrival
        }
        await flushCommittedLiveReplyArrivals()
    }

    private func flushCommittedLiveReplyArrivals() async {
        let cursor: UInt64
        do {
            cursor = try await store.currentConversationSnapshot(context: context).cursor
        } catch {
            diagnose(.conversation, .conversationReplay,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            return
        }
        for sequence in pendingLiveReplyArrivals.keys.sorted() where sequence <= cursor {
            guard let arrival = pendingLiveReplyArrivals[sequence] else { continue }
            do {
                let isResolved = try await store.recordLocalLiveReplyArrival(
                    request: arrival.request, turnID: arrival.turnID,
                    conversationSequence: arrival.conversationSequence,
                    receivedAtMilliseconds: arrival.receivedAtMilliseconds,
                    context: context)
                if isResolved { pendingLiveReplyArrivals.removeValue(forKey: sequence) }
            } catch {
                diagnose(.conversation, .conversationReplay,
                         NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                         conversationSequence: sequence)
            }
        }
    }

    /// A live entry is applied the same way as any other: replay from C's
    /// durable conversation cursor, commit, then ACK. While another operation
    /// owns the socket, run once after it releases.
    private func replayLiveConversation() async {
        guard active, liveConversationConsumerTask != nil,
              let transport = session as? any AuthenticatedConversationSession else { return }
        guard !busy else {
            pendingLiveConversationReplay = true
            return
        }
        busy = true
        defer { releaseBusy() }
        // A failure leaves the durable cursor unchanged; the next live entry,
        // foreground or push resync replays from it.
        try? await replayConversationRouteA(using: transport)
        await flushCommittedLiveReplyArrivals()
    }

    private func replayConversation(since cursor: UInt64, using transport: any AuthenticatedConversationSession,
                                    wire: ConversationWire) async throws -> UInt64 {
        try validate()
        defer { conversationReplay = nil }
        var since = cursor
        while true {
            conversationReplay = ConversationReplayProgress(expected: since,
                durableCursor: try await store.currentConversationSnapshot(context: context).cursor)
            try await transport.openConversation(wire.open(since: since)) { frame in
                try await self.consumeConversationReplay(frame)
            }
            try validate()
            guard let replay = conversationReplay, let high = replay.high else {
                throw NativeRelayCoreError.invalidReplay
            }
            guard let receipt = replay.recoveryReceipt, let rejection = replay.recoveryRejection else {
                return high
            }
            // The first response is fully drained, but the failed receipt and
            // its suffix have not advanced the store or been acknowledged.
            conversationRecoveryAttempts.insert(receipt.sequence)
            conversationReplay = ConversationReplayProgress(expected: 0,
                durableCursor: try await store.currentConversationSnapshot(context: context).cursor,
                recoveryReceipt: receipt, recoveryRejection: rejection,
                recoveryOrigin: replay.recoveryOrigin, recoveryHandle: replay.recoveryHandle,
                historyOnly: true)
            do {
                try await transport.openConversation(wire.open(since: 0)) { frame in
                    try await self.consumeConversationReplay(frame)
                }
            } catch InstallationTransportError.serverRejected {
                try await skipConversationMessage(receipt.sequence, error: InstallationTransportError.serverRejected,
                    event: receipt, rejection: rejection)
                since = try await store.currentConversationSnapshot(context: context).cursor
                continue
            } catch InstallationTransportError.conversationsUnavailable {
                try await skipConversationMessage(receipt.sequence, error: InstallationTransportError.conversationsUnavailable,
                    event: receipt, rejection: rejection)
                since = try await store.currentConversationSnapshot(context: context).cursor
                continue
            }
            try validate()
            guard let history = conversationReplay, history.high != nil else {
                throw NativeRelayCoreError.invalidReplay
            }
            if let target = history.historyTarget, !history.historyUnusable {
                do {
                    try await store.restoreReferencedConversationTurn(target, for: receipt,
                        origin: replay.recoveryOrigin, context: context)
                } catch {
                    guard isUnusableConversationMessage(error) else { throw error }
                    try await skipConversationMessage(receipt.sequence, error: error,
                        event: receipt, rejection: rejection)
                }
            } else {
                try await skipConversationMessage(receipt.sequence, error: ConversationError.invalidBinding,
                    event: receipt, rejection: rejection)
            }
            // History open moves the socket's stream position. Replay from the
            // durable cursor so neither the drained suffix nor events
            // arriving during recovery are mistaken for committed progress.
            since = try await store.currentConversationSnapshot(context: context).cursor
        }
    }

    private func consumeConversationReplay(_ frame: Data) async throws {
        try validate()
        guard var replay = conversationReplay, replay.high == nil else { throw NativeRelayCoreError.invalidReplay }
        let wire = try ConversationWire(profile: context, endpointHost: session.relayEndpointHost)
        if !replay.accepted {
            guard try wire.isOpenAccepted(frame) else { throw NativeRelayCoreError.invalidReplay }
            discoveredOriginURL = try wire.originEndpoint(frame)
            replay.accepted = true
        } else if let snapshot = try? wire.decodeResyncedSnapshot(frame) {
            let high = snapshot.highWater
            let durableCursor = try await store.currentConversationSnapshot(context: context).cursor
            guard high >= replay.durableCursor,
                  high == replay.expected else { throw NativeRelayCoreError.invalidReplay }
            if replay.historyOnly || replay.recoveryReceipt != nil {
                replay.high = high
                conversationReplay = replay
                return
            }
            guard high == durableCursor else { throw NativeRelayCoreError.invalidReplay }
            var validationRejection: ConversationValidationRejection?
            do {
                try await store.finishConversationReplay(at: high,
                    chatReadPositions: snapshot.chatReadPositions, context: context,
                    validationRejection: &validationRejection)
            } catch {
                if let validationRejection {
                    throw ConversationReplayValidationFailure(rejection: validationRejection)
                }
                throw error
            }
            conversationReadPositionSupportForSession = snapshot.chatReadPositions != nil
            if snapshot.hasInvalidChatReadPositions {
                diagnose(.conversation, .conversationReadPosition, .observed,
                         causeCode: "invalid_chat_read_positions")
            }
            replay.high = high
        } else {
            let update: ConversationWireUpdate
            do {
                update = try wire.decodeUpdate(frame)
            } catch {
                let sequence = try wire.sequenceForUnusableUpdate(frame)
                guard replay.expected < UInt64.max, sequence == replay.expected + 1 else {
                    throw NativeRelayCoreError.invalidReplay
                }
                if replay.historyOnly {
                    let value = try JSONValue.parse(frame)
                    if let receipt = replay.recoveryReceipt,
                       case let .delivered(targetID) = receipt.fact,
                       value.uniqueValue(named: "event_id")?.stringValue == targetID,
                       value.uniqueValue(named: "sender_id")?.stringValue == receipt.binding.request.senderID,
                       value.uniqueValue(named: "message_id")?.stringValue == receipt.binding.request.messageID {
                        replay.historyUnusable = true
                    }
                    diagnose(.conversation, .conversationReplay, .observed, error: error,
                        conversationSequence: sequence)
                } else if replay.recoveryReceipt == nil {
                    try await skipConversationMessage(sequence, error: error)
                }
                replay.expected = sequence
                conversationReplay = replay
                return
            }
            switch update {
            case let .event(event):
                guard replay.expected < UInt64.max, event.sequence == replay.expected + 1 else {
                    throw NativeRelayCoreError.invalidReplay
                }
                if replay.historyOnly {
                    if let receipt = replay.recoveryReceipt,
                       case let .delivered(targetID) = receipt.fact,
                       case let .turn(turn) = event.fact,
                       turn.id == targetID, event.binding.request == receipt.binding.request {
                        let value = try JSONValue.parse(frame)
                        if value.uniqueValue(named: "origin")?.stringValue != replay.recoveryOrigin ||
                            turn.sessionHandle != replay.recoveryHandle ||
                            (replay.historyTarget != nil && replay.historyTarget != event) {
                            replay.historyUnusable = true
                            diagnose(.conversation, .conversationReplay, .observed,
                                error: ConversationError.conflict, conversationSequence: event.sequence)
                        } else {
                            replay.historyTarget = event
                        }
                    }
                    replay.expected = event.sequence
                    conversationReplay = replay
                    return
                }
                if replay.recoveryReceipt != nil {
                    replay.expected = event.sequence
                    conversationReplay = replay
                    return
                }
                var validationRejection: ConversationValidationRejection?
                do {
                    let liveArrival = pendingLiveReplyArrivals[event.sequence]
                    let locallyReceivedAtMilliseconds: UInt64?
                    if case let .turn(turn) = event.fact,
                       turn.kind == .reply, turn.author == .origin,
                       liveArrival?.request == event.binding.request,
                       liveArrival?.turnID == turn.id {
                        locallyReceivedAtMilliseconds = liveArrival?.receivedAtMilliseconds
                    } else {
                        locallyReceivedAtMilliseconds = nil
                    }
                    _ = try await store.applyConversation(event, context: context,
                        validationRejection: &validationRejection,
                        locallyReceivedAtMilliseconds: locallyReceivedAtMilliseconds)
                    if let liveArrival,
                       try await store.recordLocalLiveReplyArrival(
                           request: liveArrival.request, turnID: liveArrival.turnID,
                           conversationSequence: liveArrival.conversationSequence,
                           receivedAtMilliseconds: liveArrival.receivedAtMilliseconds,
                           context: context) {
                        pendingLiveReplyArrivals.removeValue(forKey: event.sequence)
                    }
                } catch {
                    guard isUnusableConversationMessage(error) else { throw error }
                    if let validationRejection,
                       validationRejection.guardID == .referencedTurnExists,
                       validationRejection.eventKind == .receipt,
                       case .delivered = event.fact,
                       !conversationRecoveryAttempts.contains(event.sequence) {
                        let value = try JSONValue.parse(frame)
                        if let origin = value.uniqueValue(named: "origin")?.stringValue,
                           let handle = value.uniqueValue(named: "session_handle")?.stringValue {
                            replay.recoveryReceipt = event
                            replay.recoveryRejection = validationRejection
                            replay.recoveryOrigin = origin
                            replay.recoveryHandle = handle
                            replay.expected = event.sequence
                            conversationReplay = replay
                            return
                        }
                    }
                    try await skipConversationMessage(event.sequence, error: error,
                        event: event, rejection: validationRejection)
                }
                replay.expected = event.sequence
            case let .ignored(sequence):
                guard replay.expected < UInt64.max, sequence == replay.expected + 1 else {
                    throw NativeRelayCoreError.invalidReplay
                }
                if !replay.historyOnly && replay.recoveryReceipt == nil {
                    _ = try await store.advanceConversationCursor(overIgnoredUpdateAt: sequence, context: context)
                }
                replay.expected = sequence
                diagnose(.conversation, .conversationReplay, .observed, causeCode: "unknown_update_kind")
            }
        }
        conversationReplay = replay
    }

    /// Message rejection can be accounted for; a failed durable write, stale
    /// session, or missing sequence cannot be represented as successful progress.
    private func isUnusableConversationMessage(_ error: Error) -> Bool {
        if let error = error as? ConversationError {
            if case .gap = error { return false }
            return true
        }
        if let error = error as? AttentionStoreError {
            switch error {
            case .staleProfile, .fixtureOnlyOperation, .persistence, .eventGap,
                 .replayAlreadyActive, .replayNotActive, .replayIncomplete,
                 .inboxCheckpointPending, .inboxCheckpointIncomplete, .inboxStateUnrefreshed:
                return false
            default:
                return true
            }
        }
        return false
    }

    private func skipConversationMessage(_ sequence: UInt64, error: Error,
                                         event: ConversationEvent? = nil,
                                         rejection: ConversationValidationRejection? = nil) async throws {
        diagnose(.conversation, .conversationReplay, .observed, error: error,
            conversationSequence: sequence, conversationValidationRejection: rejection,
            request: event?.binding.request, revision: event?.binding.revision)
        // The existing cursor commit is the skip's durable accounting. If it
        // fails, propagate the error and never ACK this sequence.
        _ = try await store.advanceConversationCursor(overIgnoredUpdateAt: sequence, context: context)
        diagnose(.conversation, .conversationReplay, .observed,
            causeCode: "conversation_message_skipped", conversationSequence: sequence,
            request: event?.binding.request, revision: event?.binding.revision)
    }

    private func diagnoseOperationReplay(_ transition: NativeDiagnosticTransition,
                                        causeCode: String? = nil,
                                        submission: Submission,
                                        receipt: NativeDiagnosticReceiptState?) {
        let state = OperationReplayDiagnosticState(transition: transition,
                                                   causeCode: causeCode,
                                                   request: submission.requestKey,
                                                   revision: submission.requestRevision,
                                                   receipt: receipt)
        guard operationReplayDiagnosticStates[submission.operationID] != state else { return }
        if receipt == .terminal {
            operationReplayDiagnosticStates.removeValue(forKey: submission.operationID)
        } else {
            operationReplayDiagnosticStates[submission.operationID] = state
        }
        diagnose(.answer, .ordinaryReplay, transition, causeCode: causeCode,
                 operationID: submission.operationID, request: submission.requestKey,
                 revision: submission.requestRevision, receipt: receipt)
    }

    private func diagnoseNoReplyApplyFailure(_ error: Error, for submission: Submission) {
        guard submission.isNoComment else { return }
        diagnose(.answer, .noReplyOperationApply, .failed, error: error,
                 operationIDSource: .localSubmission,
                 operationID: submission.operationID, request: submission.requestKey,
                 revision: submission.requestRevision, receipt: .unknown)
    }

    private func retainReplayDiagnostics(for submissions: [Submission]) {
        let outstanding = Set(submissions.map(\.operationID))
        operationReplayDiagnosticStates = operationReplayDiagnosticStates.filter {
            outstanding.contains($0.key)
        }
        acceptedReplaySubmissions = Dictionary(uniqueKeysWithValues:
            submissions.map { ($0.operationID, $0) })
    }

    /// An uncertain result leaves the exact original C operation in the outbox.
    @discardableResult
    public func sendPendingOriginalOperations() async throws -> Int {
        guard !busy else { throw NativeRelayCoreError.inactive }
        busy = true
        defer { releaseBusy() }
        return try await drainPending()
    }

    /// Sends only durable message-open outbox entries. Unsupported or uncertain
    /// replies leave the original operation queued and never fail inbox sync.
    @discardableResult
    public func sendPendingMessageOpens() async -> Int {
        guard let pagingSession = session as? any AuthenticatedInboxPagingSession else { return 0 }
        guard !busy else { return 0 }
        busy = true
        defer { releaseBusy() }
        return await drainPendingMessageOpens(using: pagingSession)
    }

    private func releaseBusy() {
        busy = false
        if pendingLiveConversationReplay {
            pendingLiveConversationReplay = false
            Task { await replayLiveConversation() }
        }
    }

    private func drainPending() async throws -> Int {
        try validate()
        let pending = try await store.snapshot(context: context).outbox
        var attempted = 0
        for submission in pending {
            try validate()
            if submission.isNoComment {
                diagnose(.answer, .noReplyOriginalOperation, .began,
                         operationIDSource: .localSubmission,
                         operationID: submission.operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .pendingUnconfirmed)
            }
            diagnose(.answer, .originalOperationDelivery, .began,
                     operationID: submission.operationID, request: submission.requestKey,
                     revision: submission.requestRevision, receipt: .pendingUnconfirmed)
            let result: OriginalOperationResult
            do {
                result = try await session.sendOriginalOperation(submission.wireFrame,
                                                                 operationID: submission.operationID)
            } catch {
                diagnose(.answer, .originalOperationDelivery,
                         NativeDiagnosticCauseCode.unresolvedTransition(for: error), error: error,
                         operationID: submission.operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .unknown)
                if submission.isNoComment {
                    diagnose(.answer, .noReplyOriginalOperation, .unresolved,
                             error: error,
                             operationIDSource: .localSubmission,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                }
                throw error
            }
            if submission.isNoComment {
                diagnose(.answer, .noReplyOperationApply, .began,
                         operationIDSource: .localSubmission,
                         operationID: submission.operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .pendingUnconfirmed)
            }
            do {
                try validate()
            } catch {
                if submission.isNoComment {
                    diagnose(.answer, .noReplyOperationApply, .failed, error: error,
                             operationIDSource: .localSubmission,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                }
                throw error
            }
            attempted += 1
            switch result {
            case let .accepted(operationID, terminalSequence):
                guard operationID == submission.operationID, terminalSequence > 0 else {
                    diagnose(.answer, .originalOperationDelivery, .unresolved,
                             error: NativeRelayCoreError.mismatchedOperationResult,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                    diagnoseNoReplyApplyFailure(NativeRelayCoreError.mismatchedOperationResult,
                                                for: submission)
                    throw NativeRelayCoreError.mismatchedOperationResult
                }
                do {
                    try await store.recordAcceptedOperation(submission.intentID,
                                                      operationID: operationID,
                                                      terminalSequence: terminalSequence,
                                                      context: context)
                } catch {
                    diagnose(.localStore, .originalOperationDelivery, .failed, error: error,
                             operationID: operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                    diagnoseNoReplyApplyFailure(error, for: submission)
                    throw error
                }
                diagnose(.answer, .originalOperationDelivery, .accepted,
                         operationID: operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .acceptedAwaitingReplay)
            case let .refusedByRetraction(operationID, retractedAtMilliseconds):
                guard operationID == submission.operationID else {
                    diagnose(.answer, .originalOperationDelivery, .unresolved,
                             error: NativeRelayCoreError.mismatchedOperationResult,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                    diagnoseNoReplyApplyFailure(NativeRelayCoreError.mismatchedOperationResult,
                                                for: submission)
                    throw NativeRelayCoreError.mismatchedOperationResult
                }
                do {
                    try await store.recordAnswerRefusedByRetraction(submission.intentID,
                        operationID: operationID,
                        retractedAtMilliseconds: retractedAtMilliseconds,
                        context: context)
                } catch {
                    diagnose(.localStore, .originalOperationDelivery, .failed, error: error,
                             operationID: operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                    diagnoseNoReplyApplyFailure(error, for: submission)
                    throw error
                }
                diagnose(.answer, .originalOperationDelivery, .rejected,
                         causeCode: NativeDiagnosticCauseCode.serverReason("retracted"),
                         operationID: operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .terminal)
            case let .staleRevision(operationID, currentRevision):
                guard operationID == submission.operationID,
                      currentRevision > (submission.requestRevision ?? 1) else {
                    diagnose(.answer, .originalOperationDelivery, .unresolved,
                             error: NativeRelayCoreError.mismatchedOperationResult,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                    diagnoseNoReplyApplyFailure(NativeRelayCoreError.mismatchedOperationResult,
                                                for: submission)
                    throw NativeRelayCoreError.mismatchedOperationResult
                }
                do {
                    try await store.recordAnswerStaleRevision(submission.intentID,
                        operationID: operationID, currentRevision: currentRevision, context: context)
                } catch {
                    diagnose(.localStore, .originalOperationDelivery, .failed, error: error,
                             operationID: operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                    diagnoseNoReplyApplyFailure(error, for: submission)
                    throw error
                }
                diagnose(.answer, .originalOperationDelivery, .rejected,
                         causeCode: "conversation_stale_revision", operationID: operationID,
                         request: submission.requestKey, revision: submission.requestRevision,
                         receipt: .terminal)
            case let .unsupported(operationID):
                guard operationID == submission.operationID, submission.isNoComment else {
                    diagnose(.answer, .originalOperationDelivery, .unresolved,
                             error: NativeRelayCoreError.mismatchedOperationResult,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                    diagnoseNoReplyApplyFailure(NativeRelayCoreError.mismatchedOperationResult,
                                                for: submission)
                    throw NativeRelayCoreError.mismatchedOperationResult
                }
                do {
                    try await store.recordNoCommentUnsupported(submission.intentID,
                                                         operationID: operationID,
                                                         context: context)
                } catch {
                    diagnose(.localStore, .originalOperationDelivery, .failed, error: error,
                             operationID: operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                    diagnoseNoReplyApplyFailure(error, for: submission)
                    throw error
                }
                diagnose(.answer, .originalOperationDelivery, .rejected,
                         causeCode: "no_comment_unsupported", operationID: operationID,
                         request: submission.requestKey, revision: submission.requestRevision,
                         receipt: .pendingUnconfirmed)
            case let .operationConflict(operationID):
                guard operationID == submission.operationID else {
                    throw NativeRelayCoreError.mismatchedOperationResult
                }
                try await store.recordAnswerNotDelivered(submission.intentID, operationID: operationID,
                                                   context: context)
                diagnose(.answer, .originalOperationDelivery, .rejected,
                         causeCode: NativeDiagnosticCauseCode.serverReason("operation_conflict"),
                         operationID: operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .terminal)
            case .notTransmitted:
                diagnose(.answer, .originalOperationDelivery, .unresolved,
                         operationID: submission.operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .unknown)
            case let .failed(operationID):
                guard operationID == submission.operationID else {
                    diagnose(.answer, .originalOperationDelivery, .unresolved,
                             error: NativeRelayCoreError.mismatchedOperationResult,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                    diagnoseNoReplyApplyFailure(NativeRelayCoreError.mismatchedOperationResult,
                                                for: submission)
                    throw NativeRelayCoreError.mismatchedOperationResult
                }
                do {
                    try await store.recordAnswerNotDelivered(submission.intentID,
                                                       operationID: operationID,
                                                       context: context)
                } catch {
                    diagnose(.localStore, .originalOperationDelivery, .failed, error: error,
                             operationID: operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
                    diagnoseNoReplyApplyFailure(error, for: submission)
                    throw error
                }
                diagnose(.answer, .originalOperationDelivery, .rejected,
                         causeCode: "answer_not_delivered", operationID: operationID,
                         request: submission.requestKey, revision: submission.requestRevision,
                         receipt: .terminal)
            case .unresolved:
                diagnose(.answer, .originalOperationDelivery, .unresolved,
                         operationID: submission.operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .unknown)
            }
            if submission.isNoComment {
                let applied: NativeDiagnosticTransition
                let receipt: NativeDiagnosticReceiptState
                let terminalSequence: UInt64?
                switch result {
                case let .accepted(_, sequence):
                    applied = .completed
                    receipt = .acceptedAwaitingReplay
                    terminalSequence = sequence
                case .refusedByRetraction, .staleRevision, .operationConflict, .failed:
                    applied = .rejected
                    receipt = .terminal
                    terminalSequence = nil
                case .unsupported:
                    applied = .rejected
                    receipt = .pendingUnconfirmed
                    terminalSequence = nil
                case .unresolved:
                    applied = .unresolved
                    receipt = .unknown
                    terminalSequence = nil
                case .notTransmitted:
                    applied = .unresolved
                    receipt = .unknown
                    terminalSequence = nil
                }
                diagnose(.answer, .noReplyOperationApply, applied,
                         operationIDSource: .localSubmission,
                         terminalSequence: terminalSequence,
                         operationID: submission.operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: receipt)
            }
        }
        return attempted
    }

    private func drainPendingMessageOpens(using pagingSession: any AuthenticatedInboxPagingSession) async -> Int {
        guard !messageOpenUnsupportedForConnection,
              let pending = try? await store.snapshot(context: context).pendingMessageOpens else { return 0 }
        let wire = MessageOpenWire()
        var retired = 0
        for operation in pending {
            guard !messageOpenUnsupportedForConnection else { break }
            do {
                try validate()
                let response = try await pagingSession.inboxRequest(
                    wire.request(for: operation), ref: MessageOpenWire.requestRef)
                switch wire.decodeResult(response, for: operation) {
                case .confirmed:
                    _ = try await store.retireMessageOpen(operation.operationID, context: context)
                    retired += 1
                case let .permanentlyRejected(reason):
                    diagnose(.relay, .messageOpen, .rejected,
                             causeCode: NativeDiagnosticCauseCode.serverReason(reason),
                             operationIDSource: .localRequestCorrelation,
                             operationID: operation.operationID,
                             request: operation.requestKey, revision: operation.requestRevision,
                             receipt: .terminal)
                    _ = try await store.retireMessageOpen(operation.operationID, context: context)
                    retired += 1
                case .unsupported:
                    messageOpenUnsupportedForConnection = true
                    diagnose(.relay, .messageOpen, .unresolved,
                             causeCode: "message_open_unsupported",
                             operationIDSource: .localRequestCorrelation,
                             operationID: operation.operationID,
                             request: operation.requestKey, revision: operation.requestRevision,
                             receipt: .pendingUnconfirmed)
                case .unresolved:
                    // The operation may have committed even though this client
                    // cannot prove it. Keep its original ID and retry later.
                    diagnose(.relay, .messageOpen, .unresolved,
                             causeCode: "message_open_confirmation_unresolved",
                             operationIDSource: .localRequestCorrelation,
                             operationID: operation.operationID,
                             request: operation.requestKey, revision: operation.requestRevision,
                             receipt: .pendingUnconfirmed)
                    return retired
                }
            } catch {
                // Open reporting is additive. A transport/storage uncertainty
                // must not turn a successful inbox catch-up into a failure.
                diagnose(.relay, .messageOpen, .unresolved, error: error,
                         operationIDSource: .localRequestCorrelation,
                         operationID: operation.operationID,
                         request: operation.requestKey, revision: operation.requestRevision,
                         receipt: .pendingUnconfirmed)
                return retired
            }
        }
        return retired
    }

    private func diagnose(_ area: NativeDiagnosticArea,
                          _ phase: NativeDiagnosticPhase,
                          _ transition: NativeDiagnosticTransition,
                          error: Error? = nil,
                          causeCode: String? = nil,
                          postAckFailureStep: NativeDiagnosticPostAckStep? = nil,
                          postAckFailureErrorCode: String? = nil,
                          noReplyResponseClass: NativeDiagnosticNoReplyResponseClass? = nil,
                          operationIDSource: NativeDiagnosticOperationIDSource? = nil,
                          terminalSequence: UInt64? = nil,
                          lifecycleSequence: UInt64? = nil,
                          noReplyRoute: NativeDiagnosticNoReplyRoute? = nil,
                          conversationSequence: UInt64? = nil,
                          conversationValidationRejection: ConversationValidationRejection? = nil,
                          occurredAtMilliseconds: Int64? = nil,
                          operationID: UUID? = nil,
                          request: RequestKey? = nil,
                          revision: UInt64? = nil,
                          receipt: NativeDiagnosticReceiptState? = nil) {
        onDiagnostic(NativeClientDiagnosticEvent(area: area, phase: phase, transition: transition,
            causeCode: causeCode ?? error.map { NativeDiagnosticCauseCode.forError($0) },
            postAckFailureStep: postAckFailureStep,
            postAckFailureErrorCode: postAckFailureErrorCode,
            noReplyResponseClass: noReplyResponseClass,
            operationIDSource: operationIDSource,
            terminalSequence: terminalSequence,
            lifecycleSequence: lifecycleSequence,
            noReplyRoute: noReplyRoute,
            conversationSequence: conversationSequence,
            conversationValidationRejection: conversationValidationRejection,
            attemptID: attemptID, transportAttemptID: attemptID,
            operationID: operationID, request: request,
            requestRevision: revision, receiptState: receipt,
            occurredAtMilliseconds: occurredAtMilliseconds ?? NativeClientDiagnosticEvent.nowMilliseconds()))
    }

    private func diagnoseInboxPageValidationFailure(_ rejection: ConversationValidationRejection) {
        diagnose(.relay, .inboxPage, .failed, error: ConversationError.invalidBinding,
            conversationValidationRejection: rejection)
    }

    private func validatedRelayCursor() async throws -> UInt64 {
        guard active else { throw NativeRelayCoreError.inactive }
        guard session.authenticatedIdentity == context.identity else {
            throw NativeRelayCoreError.wrongInstallation
        }
        return try await store.relayCursor(context: context)
    }

    private func validate() throws {
        guard active else { throw NativeRelayCoreError.inactive }
        guard session.authenticatedIdentity == context.identity else {
            throw NativeRelayCoreError.wrongInstallation
        }
    }
}
