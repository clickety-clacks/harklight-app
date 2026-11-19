import AttentionDomain
import Foundation

/// Actions (live-connection design, section 4) for the account-wide
/// acknowledgments that need no wait on Sync: Mark Seen (message opened) and
/// chat read positions. Each operation was persisted with its operation ID
/// and frozen payload when the person acted; this component sends it on a
/// request connection, records the outcome and keeps an unresolved one
/// queued with the same ID. It never waits on replay, ACK or the outbox drain.
actor PendingActions {
    static let markSeenOperation = "mark_seen"
    static let readPositionOperation = "read_position"

    private let store: ClientRepository
    private let context: ProfileContext
    private let connections: any RequestConnectionSource
    private let errors: any ErrorLogging
    private let activity: ComponentActivity
    private let attemptID: UUID?
    private let onDiagnostic: NativeClientDiagnosticSink
    /// THIN FALLBACK (remove with SharedStreamConnection): the shared
    /// connection accepts read positions only once it has opened the
    /// conversation projection. This reports that now and never waits; a
    /// position left queued is sent when that connection's replay completes.
    private let sharedConnectionAcceptsReadPositions: @Sendable () async -> Bool

    private var messageOpensUnsupported = false
    private var markSeenSend: Task<Int, Never>?
    private var markSeenRequestedAgain = false
    private var readPositionSend: Task<Bool, Never>?
    private var readPositionsRequestedAgain = false

    init(store: ClientRepository, context: ProfileContext, connections: any RequestConnectionSource,
         errors: any ErrorLogging, activity: ComponentActivity, attemptID: UUID?,
         onDiagnostic: @escaping NativeClientDiagnosticSink,
         sharedConnectionAcceptsReadPositions: @escaping @Sendable () async -> Bool) {
        self.store = store
        self.context = context
        self.connections = connections
        self.errors = errors
        self.activity = activity
        self.attemptID = attemptID
        self.onDiagnostic = onDiagnostic
        self.sharedConnectionAcceptsReadPositions = sharedConnectionAcceptsReadPositions
    }

    // MARK: Mark Seen

    /// Sends every durable message-open report. A call made while a send is
    /// in flight joins it, and that send covers the reports queued since.
    /// Returns how many reports the send settled.
    func sendMessageOpens() async -> Int {
        guard activity.isActive else { return 0 }
        if let markSeenSend {
            markSeenRequestedAgain = true
            return await markSeenSend.value
        }
        let send = Task {
            var settled = 0
            repeat {
                markSeenRequestedAgain = false
                settled += await sendMessageOpensOnce()
            } while markSeenRequestedAgain && activity.isActive && !messageOpensUnsupported
            markSeenSend = nil
            return settled
        }
        markSeenSend = send
        return await send.value
    }

    private func sendMessageOpensOnce() async -> Int {
        guard !messageOpensUnsupported,
              let pending = try? store.snapshot(context: context).pendingMessageOpens,
              !pending.isEmpty else { return 0 }
        guard let connection = try? await requestConnection() else { return 0 }
        let wire = MessageOpenWire()
        var settled = 0
        for operation in pending {
            guard activity.isActive, !messageOpensUnsupported else { break }
            let correlation = correlation(operation.operationID)
            do {
                let response = try await connection.inboxRequest(
                    wire.request(for: operation), ref: MessageOpenWire.requestRef)
                switch wire.decodeResult(response, for: operation) {
                case .confirmed:
                    _ = try store.retireMessageOpen(operation.operationID, context: context)
                    errors.resolve(concern: .actions, operation: Self.markSeenOperation)
                    settled += 1
                case let .permanentlyRejected(reason):
                    diagnose(.relay, .messageOpen, .rejected,
                             causeCode: NativeDiagnosticCauseCode.serverReason(reason), operation: operation,
                             receipt: .terminal)
                    report(.markSeen, phase: "send", reason: .serverReason(reason), retryable: false,
                           correlation: correlation)
                    _ = try store.retireMessageOpen(operation.operationID, context: context)
                    settled += 1
                case .unsupported:
                    messageOpensUnsupported = true
                    diagnose(.relay, .messageOpen, .unresolved, causeCode: "message_open_unsupported",
                             operation: operation, receipt: .pendingUnconfirmed)
                    report(.markSeen, phase: "send", reason: .app("unsupported"), retryable: false,
                           correlation: correlation)
                case .unresolved:
                    // The operation may have committed even though this client
                    // cannot prove it. Keep its original ID and retry later.
                    diagnose(.relay, .messageOpen, .unresolved,
                             causeCode: "message_open_confirmation_unresolved", operation: operation,
                             receipt: .pendingUnconfirmed)
                    report(.markSeen, phase: "confirm", reason: .app("unresolved"), retryable: true,
                           correlation: correlation)
                    return settled
                }
            } catch {
                // Uncertain: keep the operation and its ID for the next send.
                diagnose(.relay, .messageOpen, .unresolved, error: error, operation: operation,
                         receipt: .pendingUnconfirmed)
                report(.markSeen, phase: "send", reason: .relay(error), initiator: .forFailure(error),
                       retryable: true, correlation: correlation)
                return settled
            }
        }
        return settled
    }

    // MARK: Chat read positions

    /// Sends every queued chat read position. The server keeps the maximum,
    /// so a position can never move backward. Returns true when an accepted
    /// position created conversation events that Sync should apply.
    func sendReadPositions() async -> Bool {
        guard activity.isActive else { return false }
        if let readPositionSend {
            readPositionsRequestedAgain = true
            return await readPositionSend.value
        }
        let send = Task {
            var createdEvents = false
            repeat {
                readPositionsRequestedAgain = false
                createdEvents = await sendReadPositionsOnce() || createdEvents
            } while readPositionsRequestedAgain && activity.isActive
            readPositionSend = nil
            return createdEvents
        }
        readPositionSend = send
        return await send.value
    }

    private func sendReadPositionsOnce() async -> Bool {
        guard let snapshot = try? store.conversationSnapshot(context: context),
              snapshot.chatReadPositionSupport == true,
              !snapshot.pendingChatReadPositions.isEmpty else { return false }
        if connections.sharesStreamConnection, !(await sharedConnectionAcceptsReadPositions()) {
            // Sent once this connection's conversation replay opens it.
            return false
        }
        guard let transport = try? await requestConnection() as? any AuthenticatedConversationSession,
              let wire = try? ConversationWire(profile: context, endpointHost: transport.relayEndpointHost) else {
            return false
        }
        var createdEvents = false
        for pending in snapshot.pendingChatReadPositions {
            guard activity.isActive else { break }
            let correlation = correlation(pending.operationID)
            let frame: Data
            do { frame = try wire.conversationReadPosition(pending) } catch { continue }
            diagnose(.conversation, .conversationReadPosition, .began,
                     operationID: pending.operationID, request: pending.request)
            switch await transport.sendConversationReadPosition(frame, operationID: pending.operationID) {
            case let .accepted(position, eventSequence, eventID, duplicate):
                guard position >= pending.readThroughConversationSequence,
                      (eventSequence == nil) == (eventID == nil) else {
                    diagnose(.conversation, .conversationReadPosition, .unresolved,
                             causeCode: "read_position_response_mismatch",
                             operationID: pending.operationID, request: pending.request)
                    report(.readPosition, phase: "confirm", reason: .app("response_mismatch"),
                           retryable: true, correlation: correlation)
                    continue
                }
                do {
                    try store.acceptConversationReadPosition(pending, serverPosition: position, context: context)
                } catch {
                    report(.readPosition, phase: "apply", reason: .relay(error), retryable: true,
                           correlation: correlation)
                    continue
                }
                diagnose(.conversation, .conversationReadPosition, .completed,
                         causeCode: duplicate ? "duplicate_read_position" : nil,
                         operationID: pending.operationID, request: pending.request)
                errors.resolve(concern: .actions, operation: Self.readPositionOperation)
                createdEvents = createdEvents || eventSequence != nil
            case let .rejected(reason):
                diagnose(.conversation, .conversationReadPosition, .rejected,
                         causeCode: "read_position_\(reason.rawValue)",
                         operationID: pending.operationID, request: pending.request)
                let retryable = reason.rawValue == "storage_unavailable"
                report(.readPosition, phase: "send", reason: .serverReason(reason.rawValue),
                       retryable: retryable, correlation: correlation)
                // A stated refusal is definitive for this operation. Retire it
                // so later sends stop repeating it; the Server's own read
                // position arrives with the next conversation replay.
                if !retryable {
                    try? store.retireConversationReadPosition(pending, context: context)
                }
            case .unresolved:
                diagnose(.conversation, .conversationReadPosition, .unresolved,
                         operationID: pending.operationID, request: pending.request)
                report(.readPosition, phase: "send", reason: .app("unresolved"), retryable: true,
                       correlation: correlation)
            }
        }
        return createdEvents
    }

    // MARK: Helpers

    private func requestConnection() async throws -> any AuthenticatedInboxPagingSession {
        guard activity.isActive else { throw NativeRelayCoreError.inactive }
        return try await connections.requestConnection()
    }

    private enum Operation {
        case markSeen
        case readPosition

        var name: String {
            switch self {
            case .markSeen: PendingActions.markSeenOperation
            case .readPosition: PendingActions.readPositionOperation
            }
        }
    }

    private func correlation(_ operationID: UUID) -> ErrorLogCorrelation {
        ErrorLogCorrelation(attemptID: attemptID, transportAttemptID: attemptID, clientOperationID: operationID)
    }

    private func report(_ operation: Operation, phase: String, reason: ErrorLogReason,
                        initiator: ErrorLogInitiator = .unknown, retryable: Bool,
                        correlation: ErrorLogCorrelation) {
        errors.report(ErrorLogReport(concern: .actions,
            connectionRole: connections.sharesStreamConnection ? .stream : .request,
            operation: operation.name, phase: phase, reason: reason, initiator: initiator,
            retryable: retryable, correlation: correlation))
    }

    private func diagnose(_ area: NativeDiagnosticArea, _ phase: NativeDiagnosticPhase,
                          _ transition: NativeDiagnosticTransition, error: (any Error)? = nil,
                          causeCode: String? = nil, operation: PendingMessageOpen,
                          receipt: NativeDiagnosticReceiptState) {
        onDiagnostic(NativeClientDiagnosticEvent(area: area, phase: phase, transition: transition,
            causeCode: causeCode ?? error.map { NativeDiagnosticCauseCode.forError($0) },
            operationIDSource: .localRequestCorrelation,
            attemptID: attemptID, transportAttemptID: attemptID,
            operationID: operation.operationID, request: operation.requestKey,
            requestRevision: operation.requestRevision, receiptState: receipt))
    }

    private func diagnose(_ area: NativeDiagnosticArea, _ phase: NativeDiagnosticPhase,
                          _ transition: NativeDiagnosticTransition, causeCode: String? = nil,
                          operationID: UUID, request: RequestKey) {
        onDiagnostic(NativeClientDiagnosticEvent(area: area, phase: phase, transition: transition,
            causeCode: causeCode, attemptID: attemptID, transportAttemptID: attemptID,
            operationID: operationID, request: request))
    }
}
