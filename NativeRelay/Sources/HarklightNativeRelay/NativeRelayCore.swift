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

/// Opt-in server-owned inbox ordering on the attached event stream.
public protocol AuthenticatedInboxPrioritizationSession: AuthenticatedInboxEventStreamSession {
    var supportsInboxPrioritization: Bool { get }
    func inboxViewRequest(_ request: Data, ref: String) async throws -> Data
}

public typealias InboxOrderViewObserver = @MainActor @Sendable (InboxOrderView?) -> Void

public extension AuthenticatedInstallationSession {
    var relayEndpointHost: String { authenticatedIdentity.trustedRelayAuthority.rawValue }
}

public protocol AuthenticatedConversationSession: AuthenticatedInstallationSession {
    func openConversation(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws
    func acknowledgeConversation(_ request: Data) async throws
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
    private let inboxPrioritizationWire: InboxPrioritizationWire
    private let onProgress: @Sendable (NativeRelayProgressEvent) -> Void
    private let onDiagnostic: NativeClientDiagnosticSink
    private let onInboxOrderViewChange: InboxOrderViewObserver
    private let attemptID: UUID?
    private var inboxOrderView: InboxOrderView?
    private var inboxOrderRequestAttempted = false
    private var inboxOrderSupportDisabled = false
    private var isRefreshingInboxOrder = false
    private var pendingInboxOrderRevision: String?
    private var inboxPageFetchTask: Task<InboxPageResponse?, any Error>?
    private var active = true
    private var busy = false
    private var activeInboxReplay: ReplayProgress?
    private var inboxBootstrapped = false
    private var activeInboxStartupID: String?
    private var postCheckpointInboxConsumerTask: Task<Void, Never>?
    private var postCheckpointInboxFailure: (any Error)?
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
                onDiagnostic: @escaping NativeClientDiagnosticSink = { _ in },
                initialInboxOrderView: InboxOrderView? = nil,
                onInboxOrderViewChange: @escaping InboxOrderViewObserver = { _ in }) throws {
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
        self.inboxOrderView = initialInboxOrderView
        self.onInboxOrderViewChange = onInboxOrderViewChange
        self.wire = try RelayWire(profile: context)
        self.inboxWire = try InboxPagingWire(profile: context)
        self.inboxPrioritizationWire = try InboxPrioritizationWire(profile: context)
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
        pendingInboxOrderRevision = nil
        resumePostCheckpointWaiters(throwing: NativeRelayCoreError.inactive)
    }

    /// Foreground and push-triggered reconnects both start from C's durable
    /// cursor. A server reply is never itself a durable cursor or ACK.
    @discardableResult
    public func resyncAndDrainOutbox() async throws -> UInt64 {
        guard !busy else { throw NativeRelayCoreError.inactive }
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
        if let viewSession = session as? any AuthenticatedInboxPrioritizationSession,
           viewSession.supportsInboxPrioritization,
           viewSession.supportsPostCheckpointInboxEvents,
           !inboxOrderSupportDisabled,
           !inboxOrderRequestAttempted {
            inboxOrderRequestAttempted = true
            try await refreshInboxOrder(using: viewSession, force: true)
        }
        onProgress(.postAckDrainBegan)
        do {
            inspectedConversationMetadata = true
            let acceptedBeforeDrain = Set(try store.acceptedOperationsAwaitingTerminalReplay(context: context)
                .map(\.operationID))
            let pendingBeforeDrain = try store.snapshot(context: context).outbox
            let attempted: Int
            do {
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
                let acceptedAfterDrain = try store.acceptedOperationsAwaitingTerminalReplay(context: context)
                let trackingSubmissions = Array(acceptedReplaySubmissions.values)
                if let eventStream = pagingSession as? any AuthenticatedInboxEventStreamSession,
                   eventStream.supportsPostCheckpointInboxEvents {
                    let terminalSequence = (acceptedAfterDrain + newlyAccepted)
                        .compactMap(Self.acceptedTerminalSequence).max()
                    if let terminalSequence {
                        try await waitForPostCheckpointAcknowledgement(through: terminalSequence)
                    }
                    completeAcceptedOperationReplayDiagnostics(trackingSubmissions)
                    high = try store.snapshot(context: context).cursor
                } else {
                    high = try await replayInboxAndAcknowledge(
                        since: high,
                        trackingAcceptedOperations: acceptedAfterDrain + newlyAccepted,
                        using: pagingSession)
                }
            }
            if try !store.conversationSnapshot(context: context).threads.isEmpty,
               let conversationSession = session as? any AuthenticatedConversationSession {
                try await replayConversationAndAcknowledge(using: conversationSession)
            }
            let durableCursor = try store.snapshot(context: context).cursor
            try validate()
            onProgress(.postAckDrainFinished(.completed))
            return max(high, durableCursor)
        } catch {
            let transition = NativeDiagnosticCauseCode.failureTransition(for: error)
            onProgress(.postAckDrainFinished(transition))
            diagnose(.relay, .postAckDrain, transition, error: error)
            throw error
        }
    }

    /// A page request originates only from a deliberate downward-scroll signal.
    /// Coalesce queued scroll demand while another relay operation owns the
    /// socket, then return only after the page has been durably saved.
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
            return try await fetchNextInboxPage(using: pagingSession) != nil
        } catch {
            throw error
        }
    }

    private func fetchNextInboxPage(using pagingSession: any AuthenticatedInboxPagingSession) async throws -> InboxPageResponse? {
        if let inboxPageFetchTask {
            return try await inboxPageFetchTask.value
        }
        let task = Task { try await self.performInboxPageFetch(using: pagingSession) }
        inboxPageFetchTask = task
        do {
            let page = try await task.value
            inboxPageFetchTask = nil
            return page
        } catch {
            inboxPageFetchTask = nil
            throw error
        }
    }

    private func performInboxPageFetch(using pagingSession: any AuthenticatedInboxPagingSession) async throws -> InboxPageResponse? {
        try validate()
        try throwPostCheckpointInboxFailureIfPresent()
        let checkpoint = try store.snapshot(context: context).inboxCheckpoint
        guard let checkpoint, checkpoint.checkpointAccepted,
              checkpoint.hasInitialPage,
              let snapshotID = checkpoint.snapshotID,
              let highWater = checkpoint.highWater,
              let cursor = checkpoint.nextCursor else {
            return nil
        }
        let ref = Self.inboxRef("page")
        let reply = try await pagingSession.inboxRequest(
            inboxWire.inboxPage(snapshotID: snapshotID, cursor: cursor, ref: ref), ref: ref)
        try validate()
        let page = try inboxWire.decodePage(reply, ref: ref,
                                            snapshotID: snapshotID, highWater: highWater)
        try store.saveInboxOlderPage(snapshotID: snapshotID, highWater: highWater,
            cursor: cursor, items: page.items, nextCursor: page.nextCursor, context: context)
        return page
    }

    private func refreshInboxOrder(using viewSession: any AuthenticatedInboxPrioritizationSession,
                                   force: Bool,
                                   noticeRevision: String? = nil) async throws {
        guard active, !inboxOrderSupportDisabled else { return }
        if isRefreshingInboxOrder {
            if let noticeRevision { pendingInboxOrderRevision = noticeRevision }
            return
        }
        guard force || (noticeRevision != nil && noticeRevision != inboxOrderView?.revision) else { return }
        isRefreshingInboxOrder = true
        defer { isRefreshingInboxOrder = false }

        var shouldFetch = force || noticeRevision != inboxOrderView?.revision
        while shouldFetch {
            try validate()
            let ref = Self.inboxRef("view")
            let knownRevision = inboxOrderView?.revision
            let replyBytes = try await viewSession.inboxViewRequest(
                inboxPrioritizationWire.viewGet(knownRevision: knownRevision, ref: ref), ref: ref)
            try validate()
            let candidate: InboxOrderView
            do {
                switch try inboxPrioritizationWire.decodeViewGetReply(
                    replyBytes, ref: ref, knownRevision: knownRevision) {
                case .unsupported:
                    inboxOrderSupportDisabled = true
                    inboxOrderView = nil
                    pendingInboxOrderRevision = nil
                    await onInboxOrderViewChange(nil)
                    return
                case let .unchanged(revision):
                    guard let current = inboxOrderView, current.revision == revision else {
                        throw InboxPrioritizationWireError.invalidFrame
                    }
                    candidate = current
                case let .view(view):
                    candidate = view
                }
            } catch let error as InboxPrioritizationWireError {
                if case .serverRefused = error {
                    // A view refusal does not change the inbox or its replay cursor.
                    // Leave the ordinary local ordering active until another notice
                    // or connection gives the server another chance to answer.
                    inboxOrderView = nil
                    await onInboxOrderViewChange(nil)
                    // A notice can arrive while this request is in flight. It is
                    // already the next signal to retry after this refusal, so keep
                    // that coalesced retry instead of waiting for another change.
                    shouldFetch = pendingInboxOrderRevision != nil
                    pendingInboxOrderRevision = nil
                    if shouldFetch { continue }
                    return
                }
                throw error
            }
            try await loadInboxRows(namedBy: candidate, using: viewSession)
            try validate()
            inboxOrderView = candidate
            await onInboxOrderViewChange(candidate)

            let nextNotice = pendingInboxOrderRevision
            pendingInboxOrderRevision = nil
            shouldFetch = nextNotice != nil && nextNotice != inboxOrderView?.revision
        }
    }

    private func loadInboxRows(namedBy view: InboxOrderView,
                               using viewSession: any AuthenticatedInboxPrioritizationSession) async throws {
        while true {
            try validate()
            let snapshot = try store.snapshot(context: context)
            guard let checkpoint = snapshot.inboxCheckpoint,
                  checkpoint.checkpointAccepted else { return }
            let missing = Set(view.entries.map(\.key)).subtracting(snapshot.requests.keys)
            guard !missing.isEmpty,
                  checkpoint.nextCursor != nil,
                  !checkpoint.loadedKeys.contains(where: { snapshot.remoteStates[$0]?.isTerminal == true }) else {
                return
            }
            guard let page = try await fetchNextInboxPage(using: viewSession) else { return }
            if page.items.contains(where: { $0.terminal != nil }) { return }
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
            try store.saveInboxInitialPage(snapshotID: firstPage.snapshotID,
                highWater: firstPage.highWater, items: firstPage.items,
                nextCursor: firstPage.nextCursor, receiptCursor: firstPage.receiptCursor,
                context: context)
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
            let reply = try await transport.inboxRequest(
                inboxWire.inboxReconcile(snapshotID: snapshotID, batchID: batch.batchID,
                    operations: submissions.map(\.operation), ref: ref), ref: ref)
            try validate()
            let results = try inboxWire.decodeReconciliation(reply, ref: ref,
                snapshotID: snapshotID, highWater: highWater,
                batchID: batch.batchID,
                operationIDs: batch.operationIDs)
            try store.saveInboxReceiptBatch(batch.batchID, results: results, context: context)
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
            try validate()
            let page = try inboxWire.decodeReceipts(reply, ref: ref,
                snapshotID: snapshotID, highWater: highWater)
            guard !page.events.isEmpty || page.nextCursor == nil else {
                throw InboxPagingWireError.invalidFrame
            }
            try store.saveInboxReceiptChunk(snapshotID: snapshotID, cursor: cursor,
                events: page.events, nextCursor: page.nextCursor, context: context)
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
                if let revision = inboxPrioritizationWire.changedRevision(frame) {
                    guard let viewSession = session as? any AuthenticatedInboxPrioritizationSession,
                          viewSession.supportsInboxPrioritization,
                          viewSession.supportsPostCheckpointInboxEvents,
                          !inboxOrderSupportDisabled,
                          revision != inboxOrderView?.revision else {
                        continue
                    }
                    Task { [weak self] in
                        await self?.refreshInboxOrderAfterNotice(revision, using: viewSession)
                    }
                    continue
                }
                let previousCursor = try validatedRelayCursor()
                let event = try wire.decodeEvent(frame)
                let result = store.applyRelayEvent(event, context: context)
                let durableCursor: UInt64
                switch result {
                case let .committed(contiguousCursor, _),
                     let .compatibleRepeat(contiguousCursor, _):
                    durableCursor = contiguousCursor
                case let .deferred(contiguousCursor) where contiguousCursor == event.sequence:
                    durableCursor = contiguousCursor
                case .gap, .conflict, .repairRequired, .deferred:
                    throw NativeRelayCoreError.eventRejected
                }
                if event.sequence > previousCursor {
                    guard previousCursor < UInt64.max,
                          event.sequence == previousCursor + 1,
                          durableCursor == event.sequence else {
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

    private func refreshInboxOrderAfterNotice(
        _ revision: String,
        using viewSession: any AuthenticatedInboxPrioritizationSession
    ) async {
        guard active, revision != inboxOrderView?.revision else { return }
        inboxOrderRequestAttempted = true
        do {
            try await refreshInboxOrder(using: viewSession, force: true,
                                        noticeRevision: revision)
        } catch {
            failPostCheckpointInbox(error)
            diagnose(.relay, .ordinaryReplay,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
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
        let event = try wire.decodeEvent(frame)
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
        activeInboxReplay = replay
    }

    private func replayConversationAndAcknowledge(using transport: any AuthenticatedConversationSession) async throws {
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
            diagnose(.conversation, .acknowledgement, .completed)
            diagnose(.conversation, .conversationReplay, .completed)
        } catch InstallationTransportError.conversationsUnavailable {
            conversationsUnavailable = true
            discoveredOriginURL = nil
            // Ordinary replay and answer delivery already succeeded. The missing
            // optional projection must not undo their connection confirmation.
            return
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
        guard !pendingInboxPageWaiters.isEmpty else { return }
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

    private func drainPending() async throws -> Int {
        try validate()
        let pending = try store.snapshot(context: context).outbox
        var attempted = 0
        for submission in pending {
            try validate()
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
                throw error
            }
            try validate()
            attempted += 1
            switch result {
            case let .accepted(operationID, terminalSequence):
                guard operationID == submission.operationID, terminalSequence > 0 else {
                    diagnose(.answer, .originalOperationDelivery, .unresolved,
                             error: NativeRelayCoreError.mismatchedOperationResult,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
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
                    throw error
                }
                diagnose(.answer, .originalOperationDelivery, .rejected,
                         causeCode: NativeDiagnosticCauseCode.serverReason("retracted"),
                         operationID: operationID, request: submission.requestKey,
                         revision: submission.requestRevision, receipt: .terminal)
            case let .unsupported(operationID):
                guard operationID == submission.operationID, submission.isNoComment else {
                    diagnose(.answer, .originalOperationDelivery, .unresolved,
                             error: NativeRelayCoreError.mismatchedOperationResult,
                             operationID: submission.operationID, request: submission.requestKey,
                             revision: submission.requestRevision, receipt: .unknown)
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
        }
        return attempted
    }

    private func diagnose(_ area: NativeDiagnosticArea,
                          _ phase: NativeDiagnosticPhase,
                          _ transition: NativeDiagnosticTransition,
                          error: Error? = nil,
                          causeCode: String? = nil,
                          operationID: UUID? = nil,
                          request: RequestKey? = nil,
                          revision: UInt64? = nil,
                          receipt: NativeDiagnosticReceiptState? = nil) {
        onDiagnostic(NativeClientDiagnosticEvent(area: area, phase: phase, transition: transition,
            causeCode: causeCode ?? error.map { NativeDiagnosticCauseCode.forError($0) },
            attemptID: attemptID, transportAttemptID: attemptID,
            operationID: operationID, request: request,
            requestRevision: revision, receiptState: receipt))
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
