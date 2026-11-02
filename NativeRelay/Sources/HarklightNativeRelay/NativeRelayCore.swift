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
public protocol AuthenticatedInboxEventStreamSession: AuthenticatedInboxPagingSession {
    var supportsPostCheckpointInboxEvents: Bool { get }
    func nextPostCheckpointInboxEvent() async throws -> Data
}

public extension AuthenticatedInstallationSession {
    var relayEndpointHost: String { authenticatedIdentity.trustedRelayAuthority.rawValue }
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

/// After the projection is opened, the relay pushes new conversation entries
/// on the same connection. The transport only reports that one arrived; the
/// core then replays from its durable conversation cursor and ACKs.
public protocol AuthenticatedConversationEventSession: AuthenticatedConversationSession {
    func nextLiveConversationSignal() async throws
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
    case failed(operationID: UUID)
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
    private var postCheckpointAcknowledgementGateOpen = false
    private var postCheckpointAcknowledgedCursor: UInt64?
    private var pendingPostCheckpointAcknowledgement: UInt64?
    private var postCheckpointAcknowledgementTask: Task<Void, Never>?
    private var postCheckpointAcknowledgementWaiters: [InboxSequenceWaiter] = []
    private var pendingInboxPageWaiters: [CheckedContinuation<Bool, Error>] = []
    // A core owns one authenticated connection; a new connection probes again.
    public private(set) var conversationsUnavailable = false
    private var conversationReplay: ConversationReplayProgress?
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
        let pending = (try store.conversationSnapshot(context: context).threads[request]?.uploadCleanups ?? [:]).values
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
                try store.recordConversationCleanup(cleanup.id, request: request,
                    outcome: .acknowledged(result), context: context)
                diagnose(.upload, .uploadCleanup, .completed, operationID: cleanup.id,
                         request: request, revision: cleanup.binding.revision)
            } catch {
                let cleanupError = error
                diagnose(.upload, .uploadCleanup, NativeDiagnosticCauseCode.failureTransition(for: error),
                         error: error, operationID: cleanup.id, request: request,
                         revision: cleanup.binding.revision, receipt: .unknown)
                do {
                    try store.recordConversationCleanup(cleanup.id, request: request,
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

    private func validateUploadOperation(_ binding: ConversationBinding, operation: UUID) throws {
        let thread = try store.conversationSnapshot(context: context).threads[binding.request]
        guard thread?.uploadGroups?[operation]?.cleanupID == nil else { throw ConversationError.pendingSubmission }
    }

    public func submitDiscussion(_ binding: ConversationBinding,
        retainedFile: @Sendable (ConversationFile) async throws -> URL) async throws -> DiscussionOperationResult {
        diagnose(.conversation, .discussionSubmission, .began, request: binding.request,
                 revision: binding.revision)
        guard !busy else { throw NativeRelayCoreError.inactive }
        busy = true
        defer { releaseBusy() }
        try validate()
        guard !conversationsUnavailable else { throw InstallationTransportError.conversationsUnavailable }
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
                        diagnose(.upload, .uploadTransfer, .began, operationID: operation,
                                 request: binding.request, revision: binding.revision)
                        let uploaded = try await transport.uploadConversationFile(file, from: source, binding: binding,
                            operationID: operation, limits: published, originURL: endpoint)
                        try validate()
                        try store.recordConversationUpload(uploaded, binding: binding, operation: operation, context: context)
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
        } catch {
            // No discussion frame has been sent by this attempt. A previous
            // ambiguous attempt must still keep its exact operation frozen.
            // Keep all original bytes/draft; unreferenced uploads do not submit a turn.
            let names = frozen.files.map { $0.name.rawValue }.joined(separator: ", ")
            diagnose(.conversation, .discussionPreparation,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                     operationID: operation, request: binding.request, revision: binding.revision,
                     receipt: wasUncertain ? .unknown : .pendingUnconfirmed)
            do {
                try store.markDiscussionOutcome(binding, operation: operation,
                    rejection: wasUncertain ? nil : ExactText("Not delivered: " + (names.isEmpty ? "the discussion" : names) + " could not be prepared (\(error)). Draft retained."),
                    context: context)
            } catch {
                diagnose(.localStore, .discussionPreparation, .failed, error: error,
                         operationID: operation, request: binding.request,
                         revision: binding.revision, receipt: .unknown)
                throw error
            }
            throw error
        }
        try validate()
        try validateUploadOperation(binding, operation: operation)
        let result = await transport.sendDiscussion(frame, operationID: operation)
        try validate()
        switch result {
        case let .accepted(turn):
            try store.markDiscussionAccepted(binding, operation: operation, turn: turn, context: context)
            diagnose(.conversation, .discussionSubmission, .accepted, operationID: operation,
                     request: binding.request, revision: binding.revision,
                     receipt: .acceptedAwaitingReplay)
            // The accepted turn is durable even if replay temporarily fails. A later
            // refresh joins it; the send response cannot move a replay cursor.
            do { try await replayConversationAndAcknowledge(using: transport) }
            catch {
                diagnose(.conversation, .conversationReplay,
                         NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                         operationID: operation, request: binding.request,
                         revision: binding.revision, receipt: .acceptedAwaitingReplay)
            }
        case let .rejected(reason):
            try store.markDiscussionOutcome(binding, operation: operation, rejection: reason, context: context)
            diagnose(.conversation, .discussionSubmission, .rejected, operationID: operation,
                     request: binding.request, revision: binding.revision, receipt: .pendingUnconfirmed)
        case .unresolved:
            try store.markDiscussionOutcome(binding, operation: operation, rejection: nil, context: context)
            diagnose(.conversation, .discussionSubmission, .unresolved, operationID: operation,
                     request: binding.request, revision: binding.revision, receipt: .unknown)
        }
        return result
    }

    private struct ConversationReplayProgress {
        var expected: UInt64
        let durableCursor: UInt64
        var accepted = false
        var high: UInt64?
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
                onDiagnostic: @escaping NativeClientDiagnosticSink = { _ in }) throws {
        guard context.transportMode == .relay else { throw NativeRelayCoreError.fixtureProfile }
        guard session.authenticatedIdentity == context.identity else {
            throw NativeRelayCoreError.wrongInstallation
        }
        _ = try store.snapshot(context: context)
        self.store = store
        self.context = context
        self.session = session
        self.onProgress = onProgress
        self.attemptID = attemptID
        self.onDiagnostic = onDiagnostic
        self.wire = try RelayWire(profile: context)
        self.inboxWire = try InboxPagingWire(profile: context)
    }

    public func deactivate() {
        active = false
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

    /// Returns details for the most recent failed post-ACK drain without
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
        try throwPostCheckpointInboxFailureIfPresent()
        guard let pagingSession = session as? any AuthenticatedInboxPagingSession else {
            throw NativeRelayCoreError.inboxPagingUnavailable
        }
        let acceptedBeforeReplay = try store.acceptedOperationsAwaitingTerminalReplay(context: context)
        retainReplayDiagnostics(for: acceptedBeforeReplay)
        var high: UInt64
        if inboxBootstrapped {
            if let eventStream = pagingSession as? any AuthenticatedInboxEventStreamSession,
               eventStream.supportsPostCheckpointInboxEvents {
                startPostCheckpointInboxConsumer(from: eventStream,
                    baseline: try currentInboxCheckpointHighWater())
                high = try store.snapshot(context: context).cursor
            } else {
                high = try await replayInboxAndAcknowledge(
                    since: store.snapshot(context: context).cursor,
                    trackingAcceptedOperations: acceptedBeforeReplay,
                    using: pagingSession)
            }
        } else {
            high = try await bootstrapInbox(using: pagingSession,
                                            trackingAcceptedOperations: acceptedBeforeReplay)
            inboxBootstrapped = true
        }
        onProgress(.postAckDrainBegan)
        var failedStep = NativeDiagnosticPostAckStep.readAcceptedOperationsBeforeDrain
        do {
            inspectedConversationMetadata = true
            let acceptedBeforeDrain = Set(try store.acceptedOperationsAwaitingTerminalReplay(context: context)
                .map(\.operationID))
            failedStep = .readOutboxBeforeDrain
            let pendingBeforeDrain = try store.snapshot(context: context).outbox
            let attempted: Int
            do {
                failedStep = .drainPendingOperations
                attempted = try await drainPending()
            } catch {
                // A later operation may fail after an earlier operation was
                // accepted. Record that the accepted operation's terminal replay
                // was not reached, without attributing the later operation's
                // transport error to it.
                let acceptedAfterInterruptedDrain = (try? store.acceptedOperationsAwaitingTerminalReplay(context: context)) ?? []
                for submission in acceptedAfterInterruptedDrain where !acceptedBeforeDrain.contains(submission.operationID) {
                    diagnoseOperationReplay(.unresolved,
                             causeCode: "follow_on_replay_not_reached",
                             submission: submission, receipt: .acceptedAwaitingReplay)
                }
                throw error
            }
            if attempted > 0 {
                failedStep = .readOutboxAfterDrain
                let afterDrain = try store.snapshot(context: context)
                let newlyAccepted = pendingBeforeDrain.compactMap { pending -> Submission? in
                    guard let recorded = afterDrain.intents[pending.intentID],
                          case .accepted = recorded.disposition else { return nil }
                    return recorded
                }
                for submission in newlyAccepted {
                    acceptedReplaySubmissions[submission.operationID] = submission
                    if operationReplayDiagnosticStates[submission.operationID] == nil {
                        diagnoseOperationReplay(.began, submission: submission,
                                                receipt: .acceptedAwaitingReplay)
                    }
                }
                failedStep = .readAcceptedOperationsAfterDrain
                let acceptedAfterDrain = try store.acceptedOperationsAwaitingTerminalReplay(context: context)
                let trackingSubmissions = Array(acceptedReplaySubmissions.values)
                if let eventStream = pagingSession as? any AuthenticatedInboxEventStreamSession,
                   eventStream.supportsPostCheckpointInboxEvents {
                    let terminalSequence = (acceptedAfterDrain + newlyAccepted)
                        .compactMap(Self.acceptedTerminalSequence).max()
                    if let terminalSequence {
                        failedStep = .waitForAcceptedOperationAcknowledgement
                        try await waitForPostCheckpointAcknowledgement(through: terminalSequence)
                    }
                    completeAcceptedOperationReplayDiagnostics(trackingSubmissions)
                    failedStep = .readInboxCursorAfterAcknowledgement
                    high = try store.snapshot(context: context).cursor
                } else {
                    failedStep = .replayInboxAfterDrain
                    high = try await replayInboxAndAcknowledge(
                        since: high,
                        trackingAcceptedOperations: acceptedAfterDrain + newlyAccepted,
                        using: pagingSession)
                }
            }
            failedStep = .readConversationState
            let conversationThreads = try store.conversationSnapshot(context: context).threads
            if !conversationThreads.isEmpty,
               let conversationSession = session as? any AuthenticatedConversationSession {
                failedStep = .replayConversationsAndAcknowledge
                try await replayConversationAndAcknowledge(using: conversationSession)
            }
            if !inboxViewRequestedOnConnection {
                inboxViewRequestedOnConnection = true
                await refreshInboxView(using: pagingSession)
            }
            failedStep = .readFinalRelayCursor
            let durableCursor = try store.snapshot(context: context).cursor
            failedStep = .validateRelayState
            try validate()
            onProgress(.postAckDrainFinished(.completed))
            return max(high, durableCursor)
        } catch {
            let errorCode = NativeDiagnosticCauseCode.forPostAckError(error)
            let details = NativePostAckFailureDetails(step: failedStep, errorCode: errorCode)
            postAckFailureDetails = details
            let transition = NativeDiagnosticCauseCode.failureTransition(for: error)
            onProgress(.postAckDrainFinished(transition))
            diagnose(.relay, .postAckDrain, transition, error: error,
                     postAckFailureStep: details.step,
                     postAckFailureErrorCode: details.errorCode)
            throw error
        }
    }

    /// A page request originates from downward scrolling or from loading the
    /// held server view. Coalesce queued demand while another relay operation
    /// owns the socket, then return only after the page is durably saved.
    @discardableResult
    public func fetchNextInboxPage() async throws -> Bool {
        guard let pagingSession = session as? any AuthenticatedInboxPagingSession else {
            throw NativeRelayCoreError.inboxPagingUnavailable
        }
        guard !busy else {
            return try await withCheckedThrowingContinuation { continuation in
                pendingInboxPageWaiters.append(continuation)
            }
        }
        busy = true
        defer { releaseBusy() }
        do {
            try validate()
            try throwPostCheckpointInboxFailureIfPresent()
            let checkpoint = try store.snapshot(context: context).inboxCheckpoint
            guard let checkpoint, checkpoint.checkpointAccepted,
                  checkpoint.hasInitialPage,
                  let snapshotID = checkpoint.snapshotID,
                  let highWater = checkpoint.highWater,
                  let cursor = checkpoint.nextCursor else {
                return false
            }
            let ref = Self.inboxRef("page")
            let reply = try await pagingSession.inboxRequest(
                inboxWire.inboxPage(snapshotID: snapshotID, cursor: cursor, ref: ref), ref: ref)
            try validate()
            let page = try inboxWire.decodePage(reply, ref: ref,
                                                snapshotID: snapshotID, highWater: highWater)
            var validationRejection: ConversationValidationRejection?
            do {
                try store.saveInboxOlderPage(snapshotID: snapshotID, highWater: highWater,
                    cursor: cursor, items: page.items, nextCursor: page.nextCursor, context: context,
                    validationRejection: &validationRejection)
            } catch {
                if let validationRejection {
                    diagnoseInboxPageValidationFailure(validationRejection)
                    throw ConversationError.invalidBinding
                }
                throw error
            }
            return true
        } catch {
            throw error
        }
    }

    private func bootstrapInbox(using transport: any AuthenticatedInboxPagingSession,
                                trackingAcceptedOperations accepted: [Submission]) async throws -> UInt64 {
        let snapshot = try store.snapshot(context: context)
        if let candidate = snapshot.inboxCandidate {
            let isCurrentStartup = activeInboxStartupID == candidate.startupID
            if candidate.checkpointRequestStarted {
                do {
                    try await recoverInboxCheckpoint(candidate, using: transport)
                    if isCurrentStartup, let checkpoint = try store.snapshot(context: context).inboxCheckpoint,
                       checkpoint.checkpointAccepted, let high = checkpoint.highWater {
                        return try await replayInboxAndAcknowledge(
                            since: high,
                            trackingAcceptedOperations: accepted,
                            using: transport)
                    }
                } catch InboxPagingWireError.serverRefused("snapshot_replaced") {
                    guard let snapshotID = candidate.snapshotID else { throw NativeRelayCoreError.invalidReplay }
                    try store.discardReplacedInboxCandidate(snapshotID: snapshotID, context: context)
                }
            } else if isCurrentStartup {
                return try await completeInboxCandidate(candidate, using: transport,
                    trackingAcceptedOperations: accepted)
            } else {
                // A prior launch may have persisted page/receipt work before it
                // requested the checkpoint. Keep that work and originals, then
                // capture this launch's one fresh bounded B2 snapshot.
                try store.discardInboxCandidate(context: context)
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
        _ = try store.acceptInboxCheckpoint(snapshotID: snapshotID, highWater: highWater,
                                            context: context)
    }

    private func createInboxCheckpoint(using transport: any AuthenticatedInboxPagingSession,
                                       trackingAcceptedOperations accepted: [Submission]) async throws -> UInt64 {
        let cursor = try store.snapshot(context: context).cursor
        let inventory = try store.inboxOperationInventory(context: context)
        let candidate = try store.beginInboxCandidate(startupID: UUID().uuidString.lowercased(),
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
            var validationRejection: ConversationValidationRejection?
            do {
                try store.saveInboxInitialPage(snapshotID: firstPage.snapshotID,
                    highWater: firstPage.highWater, items: firstPage.items,
                    nextCursor: firstPage.nextCursor, receiptCursor: firstPage.receiptCursor,
                    context: context, validationRejection: &validationRejection)
            } catch {
                if let validationRejection {
                    diagnoseInboxPageValidationFailure(validationRejection)
                    throw ConversationError.invalidBinding
                }
                throw error
            }
        }

        let eligible = try await prepareInboxCandidate(using: transport)
        try await acknowledgeInboxCheckpoint(eligible, using: transport)
        guard let snapshotID = eligible.snapshotID, let highWater = eligible.highWater else {
            throw NativeRelayCoreError.invalidReplay
        }
        let high = try store.acceptInboxCheckpoint(snapshotID: snapshotID, highWater: highWater,
                                                   context: context)
        return try await replayInboxAndAcknowledge(since: high,
            trackingAcceptedOperations: accepted, using: transport)
    }

    private func prepareInboxCandidate(using transport: any AuthenticatedInboxPagingSession) async throws -> InboxPagingCheckpoint {
        while true {
            try await reconcilePendingInboxBatches(using: transport)
            try await drainInboxReceiptCursor(using: transport)
            let candidate = try currentInboxCandidate()
            let covered = Set(candidate.batches.flatMap(\.operationIDs))
            let inventory = try store.inboxOperationInventory(context: context)
            let missing = inventory.filter { !covered.contains($0.operationID) }
            if !missing.isEmpty {
                try store.appendInboxReceiptBatches(Self.makeInboxBatches(missing), context: context)
                continue
            }
            do {
                return try store.prepareInboxCheckpointAcknowledgement(context: context)
            } catch AttentionStoreError.inboxCheckpointIncomplete {
                let refreshed = try store.inboxOperationInventory(context: context)
                let refreshedMissing = refreshed.filter { !covered.contains($0.operationID) }
                guard !refreshedMissing.isEmpty else { throw AttentionStoreError.inboxCheckpointIncomplete }
                try store.appendInboxReceiptBatches(Self.makeInboxBatches(refreshedMissing), context: context)
            }
        }
    }

    private func reconcilePendingInboxBatches(using transport: any AuthenticatedInboxPagingSession) async throws {
        while true {
            let candidate = try currentInboxCandidate()
            guard let snapshotID = candidate.snapshotID,
                  let highWater = candidate.highWater else { throw NativeRelayCoreError.invalidReplay }
            guard let batch = candidate.batches.first(where: { $0.results == nil }) else { return }
            let snapshot = try store.snapshot(context: context)
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
                try store.saveInboxReceiptBatch(batch.batchID,
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
            let candidate = try currentInboxCandidate()
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
                try store.snapshot(context: context).intents.values.filter(\.isNoComment),
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
                try store.saveInboxReceiptChunk(snapshotID: snapshotID, cursor: cursor,
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

    private func currentInboxCandidate() throws -> InboxPagingCheckpoint {
        guard let candidate = try store.snapshot(context: context).inboxCandidate else {
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
            let replayStart = try store.snapshot(context: context).cursor
            guard replayStart == cursor else { throw NativeRelayCoreError.invalidReplay }
            let checkpointHighWater = try currentInboxCheckpointHighWater()
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
            completeAcceptedOperationReplayDiagnostics(submissions)
            return high
        } catch {
            failPostCheckpointInbox(error)
            diagnose(.relay, .ordinaryReplay,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            let outstanding = try? store.acceptedOperationsAwaitingTerminalReplay(context: context)
            let ids = outstanding.map { Set($0.map(\.operationID)) }
            for submission in submissions {
                diagnoseOperationReplay(NativeDiagnosticCauseCode.failureTransition(for: error),
                    causeCode: NativeDiagnosticCauseCode.forError(error), submission: submission,
                    receipt: ids.map { $0.contains(submission.operationID) ? .acceptedAwaitingReplay : .terminal } ?? .unknown)
            }
            throw error
        }
    }

    private func currentInboxCheckpointHighWater() throws -> UInt64 {
        guard let checkpoint = try store.snapshot(context: context).inboxCheckpoint,
              checkpoint.checkpointAccepted,
              let highWater = checkpoint.highWater else {
            throw NativeRelayCoreError.invalidReplay
        }
        return highWater
    }

    private func startPostCheckpointInboxConsumer(
        from eventStream: any AuthenticatedInboxEventStreamSession,
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
        from eventStream: any AuthenticatedInboxEventStreamSession
    ) async {
        do {
            while !Task.isCancelled {
                let frame = try await eventStream.nextPostCheckpointInboxEvent()
                let update = try wire.decodeUpdate(frame)
                if case let .viewChanged(revision) = update {
                    await refreshInboxView(using: eventStream, noticedRevision: revision)
                    continue
                }
                if case .ignoredUnsequenced = update { continue }
                let previousCursor = try validatedRelayCursor()
                let durableCursor: UInt64
                let sequence: UInt64
                switch update {
                case let .event(event):
                    sequence = event.sequence
                    switch store.applyRelayEvent(event, context: context) {
                    case let .committed(contiguousCursor, _),
                         let .compatibleRepeat(contiguousCursor, _):
                        durableCursor = contiguousCursor
                    case let .deferred(contiguousCursor) where contiguousCursor == event.sequence:
                        durableCursor = contiguousCursor
                    case .gap, .conflict, .repairRequired, .deferred:
                        throw NativeRelayCoreError.eventRejected
                    }
                case let .ignored(ignoredSequence):
                    sequence = ignoredSequence
                    durableCursor = try store.advanceRelayCursor(
                        overIgnoredUpdateAt: ignoredSequence, context: context)
                    diagnose(.relay, .ordinaryReplay, .observed, causeCode: "unknown_update_kind")
                case .viewChanged:
                    continue
                case .ignoredUnsequenced:
                    continue
                }
                if sequence > previousCursor {
                    guard previousCursor < UInt64.max,
                          sequence == previousCursor + 1,
                          durableCursor == sequence else {
                        throw NativeRelayCoreError.invalidReplay
                    }
                } else if durableCursor != previousCursor {
                    throw NativeRelayCoreError.invalidReplay
                }

                if let acknowledged = postCheckpointAcknowledgedCursor,
                   durableCursor > acknowledged {
                    queuePostCheckpointAcknowledgement(through: durableCursor)
                }
                completeAcceptedOperationReplayDiagnostics(
                    Array(acceptedReplaySubmissions.values))
            }
        } catch {
            guard !Task.isCancelled else { return }
            failPostCheckpointInbox(error)
            diagnose(.relay, .ordinaryReplay,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
        }
    }

    private func refreshInboxView(using transport: any AuthenticatedInboxPagingSession,
                                  noticedRevision: ExactText? = nil) async {
        guard !inboxViewUnsupportedForConnection else { return }
        let heldRevision = (try? store.snapshot(context: context).inboxView?.revision) ?? nil
        if let noticedRevision, heldRevision == noticedRevision { return }
        if inboxViewFetchInProgress {
            pendingInboxViewRevision = noticedRevision
            return
        }
        inboxViewFetchInProgress = true
        defer { inboxViewFetchInProgress = false }

        var noticeToResolve = noticedRevision
        while active {
            let knownRevision = (try? store.snapshot(context: context).inboxView?.revision) ?? nil
            if let noticeToResolve, noticeToResolve == knownRevision { break }
            pendingInboxViewRevision = nil
            let ref = Self.inboxRef("view")
            do {
                let reply = try await transport.inboxRequest(
                    inboxWire.viewGet(knownRevision: knownRevision, ref: ref), ref: ref)
                switch inboxWire.decodeViewGet(reply, ref: ref, knownRevision: knownRevision) {
                case let .updated(view):
                    try store.setInboxView(view, context: context)
                    scheduleInboxViewPageLoad()
                case .unchanged:
                    scheduleInboxViewPageLoad()
                case .unsupported:
                    inboxViewUnsupportedForConnection = true
                    try? store.setInboxView(nil, context: context)
                case .unavailable:
                    try? store.setInboxView(nil, context: context)
                }
                if inboxViewUnsupportedForConnection { break }
            } catch {
                try? store.setInboxView(nil, context: context)
                break
            }
            let pending = pendingInboxViewRevision
            pendingInboxViewRevision = nil
            let currentRevision = (try? store.snapshot(context: context).inboxView?.revision) ?? nil
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
            guard let snapshot = try? store.snapshot(context: context),
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
            guard let next = try? store.snapshot(context: context),
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

    private func completeAcceptedOperationReplayDiagnostics(_ submissions: [Submission]) {
        guard !submissions.isEmpty else { return }
        let outstanding = try? store.acceptedOperationsAwaitingTerminalReplay(context: context)
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
        let snapshot = try store.snapshot(context: context)
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
                                    snapshotID: String, highWater: UInt64) throws {
        try validate()
        guard var replay = activeInboxReplay, replay.high == nil else {
            throw NativeRelayCoreError.invalidReplay
        }
        if !replay.accepted {
            guard try inboxWire.isReplayAccepted(frame, ref: ref,
                                                 snapshotID: snapshotID, highWater: highWater) else {
                throw NativeRelayCoreError.invalidReplay
            }
            try store.beginReplay(through: UInt64.max, context: context)
            replay.accepted = true
            activeInboxReplay = replay
            return
        }
        if let high = try? wire.decodeResynced(frame) {
            guard high >= replay.durableCursor, high == replay.expected else {
                throw NativeRelayCoreError.invalidReplay
            }
            try store.finishReplay(at: high, context: context)
            replay.high = high
            activeInboxReplay = replay
            return
        }
        switch try wire.decodeUpdate(frame) {
        case let .event(event):
            guard replay.expected < UInt64.max, event.sequence == replay.expected + 1 else {
                throw NativeRelayCoreError.invalidReplay
            }
            switch store.applyRelayEvent(event, context: context) {
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
            _ = try store.advanceRelayCursor(overIgnoredUpdateAt: sequence, context: context)
            replay.expected = sequence
            diagnose(.relay, .ordinaryReplay, .observed, causeCode: "unknown_update_kind")
        case .viewChanged, .ignoredUnsequenced:
            activeInboxReplay = replay
            return
        }
        activeInboxReplay = replay
    }

    private func replayConversationAndAcknowledge(using transport: any AuthenticatedConversationSession,
                                                 drainReadPositions: Bool = true) async throws {
        guard !conversationsUnavailable else { return }
        diagnose(.conversation, .conversationReplay, .began)
        let wire = try ConversationWire(profile: context, endpointHost: transport.relayEndpointHost)
        do {
            var high = try await replayConversation(since: store.conversationSnapshot(context: context).cursor,
                using: transport, wire: wire)
            do { try await transport.acknowledgeConversation(wire.acknowledge(high)) }
            catch InstallationTransportError.acknowledgementBehind {
                diagnose(.conversation, .acknowledgement, .retrying,
                         error: InstallationTransportError.acknowledgementBehind)
                high = try await replayConversation(since: 0, using: transport, wire: wire)
                try await transport.acknowledgeConversation(wire.acknowledge(high))
            }
            if drainReadPositions,
               try await sendPendingConversationReadPositions(using: transport) {
                high = try await replayConversation(since: store.conversationSnapshot(context: context).cursor,
                    using: transport, wire: wire)
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

    /// Chat read updates are account state, separate from this device's replay
    /// ACK. The saved operation remains queued until its idempotent reply arrives.
    public func sendPendingConversationReadPositions() async {
        guard active else { return }
        guard !busy else {
            pendingConversationReadPositionDrain = true
            return
        }
        guard let transport = session as? any AuthenticatedConversationSession else { return }
        busy = true
        defer { releaseBusy() }
        do {
            if try await sendPendingConversationReadPositions(using: transport) {
                try await replayConversationAndAcknowledge(using: transport, drainReadPositions: false)
            }
        } catch {
            diagnose(.conversation, .conversationReadPosition,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
        }
    }

    private func sendPendingConversationReadPositions(
        using transport: any AuthenticatedConversationSession
    ) async throws -> Bool {
        guard conversationReadPositionSupportForSession else { return false }
        let snapshot = try store.conversationSnapshot(context: context)
        guard snapshot.chatReadPositionSupport == true else { return false }
        let wire = try ConversationWire(profile: context, endpointHost: transport.relayEndpointHost)
        var createdConversationEvents = false
        for pending in snapshot.pendingChatReadPositions {
            try validate()
            let frame = try wire.conversationReadPosition(pending)
            diagnose(.conversation, .conversationReadPosition, .began,
                     operationID: pending.operationID, request: pending.request)
            let result = await transport.sendConversationReadPosition(frame, operationID: pending.operationID)
            switch result {
            case let .accepted(position, eventSequence, eventID, duplicate):
                guard position >= pending.readThroughConversationSequence,
                      (eventSequence == nil) == (eventID == nil) else {
                    diagnose(.conversation, .conversationReadPosition, .unresolved,
                             causeCode: "read_position_response_mismatch",
                             operationID: pending.operationID, request: pending.request)
                    continue
                }
                try store.acceptConversationReadPosition(pending, serverPosition: position, context: context)
                diagnose(.conversation, .conversationReadPosition, .completed,
                         causeCode: duplicate ? "duplicate_read_position" : nil,
                         operationID: pending.operationID, request: pending.request)
                createdConversationEvents = createdConversationEvents || eventSequence != nil
            case let .rejected(reason):
                diagnose(.conversation, .conversationReadPosition, .rejected,
                         causeCode: "read_position_\(reason.rawValue)",
                         operationID: pending.operationID, request: pending.request)
            case .unresolved:
                diagnose(.conversation, .conversationReadPosition, .unresolved,
                         operationID: pending.operationID, request: pending.request)
            }
        }
        return createdConversationEvents
    }

    private func consumeLiveConversationSignals(from events: any AuthenticatedConversationEventSession) async {
        while !Task.isCancelled {
            do { try await events.nextLiveConversationSignal() }
            catch { return }
            await replayLiveConversation()
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
        try? await replayConversationAndAcknowledge(using: transport)
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
        } else if let snapshot = try? wire.decodeResyncedSnapshot(frame) {
            let high = snapshot.highWater
            let durableCursor = try store.conversationSnapshot(context: context).cursor
            guard high >= replay.durableCursor,
                  high == replay.expected,
                  high == durableCursor else { throw NativeRelayCoreError.invalidReplay }
            var validationRejection: ConversationValidationRejection?
            do {
                try store.finishConversationReplay(at: high,
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
            switch try wire.decodeUpdate(frame) {
            case let .event(event):
                guard replay.expected < UInt64.max, event.sequence == replay.expected + 1 else {
                    throw NativeRelayCoreError.invalidReplay
                }
                if event.sequence <= replay.durableCursor,
                   try store.conversationSequenceWasAccountedWithoutEvent(at: event.sequence,
                       context: context) {
                    replay.expected = event.sequence
                    conversationReplay = replay
                    return
                }
                var validationRejection: ConversationValidationRejection?
                do {
                    _ = try store.applyConversation(event, context: context,
                        validationRejection: &validationRejection)
                } catch {
                    if let validationRejection {
                        guard validationRejection.guardID == .redactedRevisionBinding,
                              validationRejection.eventKind == .revision,
                              case .redactedRevision = event.fact else {
                            throw ConversationReplayValidationFailure(rejection: validationRejection)
                        }
                        diagnose(.conversation, .conversationReplay, .observed,
                            causeCode: NativeDiagnosticCauseCode.forError(ConversationError.invalidBinding),
                            conversationSequence: event.sequence,
                            conversationValidationRejection: validationRejection,
                            request: event.binding.request, revision: event.binding.revision)
                        let durableCursor = try store.advanceConversationCursor(
                            overIgnoredUpdateAt: event.sequence, context: context)
                        guard durableCursor >= event.sequence else { throw ConversationError.conflict }
                        replay.expected = event.sequence
                        conversationReplay = replay
                        return
                    }
                    throw error
                }
                replay.expected = event.sequence
            case let .ignored(sequence):
                guard replay.expected < UInt64.max, sequence == replay.expected + 1 else {
                    throw NativeRelayCoreError.invalidReplay
                }
                _ = try store.advanceConversationCursor(overIgnoredUpdateAt: sequence, context: context)
                replay.expected = sequence
                diagnose(.conversation, .conversationReplay, .observed, causeCode: "unknown_update_kind")
            }
        }
        conversationReplay = replay
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

    private func releaseBusy() {
        busy = false
        if pendingLiveConversationReplay {
            pendingLiveConversationReplay = false
            Task { await replayLiveConversation() }
        }
        if pendingConversationReadPositionDrain {
            pendingConversationReadPositionDrain = false
            Task { await sendPendingConversationReadPositions() }
        }
        if !pendingInboxPageWaiters.isEmpty {
            let waiters = pendingInboxPageWaiters
            pendingInboxPageWaiters.removeAll()
            Task {
                do {
                    let result = try await fetchNextInboxPage()
                    for waiter in waiters { waiter.resume(returning: result) }
                } catch {
                    for waiter in waiters { waiter.resume(throwing: error) }
                }
            }
        }
    }

    private func drainPending() async throws -> Int {
        try validate()
        let pending = try store.snapshot(context: context).outbox
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
                    try store.recordAcceptedOperation(submission.intentID,
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
                    try store.recordAnswerRefusedByRetraction(submission.intentID,
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
                    try store.recordAnswerStaleRevision(submission.intentID,
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
                    try store.recordNoCommentUnsupported(submission.intentID,
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
                    try store.recordAnswerNotDelivered(submission.intentID,
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
                case .refusedByRetraction, .staleRevision, .failed:
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

    private func validatedRelayCursor() throws -> UInt64 {
        guard active else { throw NativeRelayCoreError.inactive }
        guard session.authenticatedIdentity == context.identity else {
            throw NativeRelayCoreError.wrongInstallation
        }
        return try store.relayCursor(context: context)
    }

    private func validate() throws {
        _ = try validatedRelayCursor()
    }
}
