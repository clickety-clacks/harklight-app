import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

public protocol PendingActionPersistence: AnyObject, Sendable {
    func load(identity: ProfileIdentity) throws -> Data?
    func commit(_ data: Data, identity: ProfileIdentity) throws
}

public final class MemoryPendingActionPersistence: PendingActionPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var failNextWrite = false

    public init() {}

    public func failNextCommit() {
        lock.lock()
        defer { lock.unlock() }
        failNextWrite = true
    }

    public func load(identity: ProfileIdentity) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return files[identity.storageKey]
    }

    public func commit(_ data: Data, identity: ProfileIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        if failNextWrite {
            failNextWrite = false
            throw AttentionStoreError.persistence("Injected durable-write failure.")
        }
        files[identity.storageKey] = data
    }
}

public final class FilePendingActionPersistence: PendingActionPersistence, @unchecked Sendable {
    public let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    public static func applicationSupport() throws -> FilePendingActionPersistence {
        guard let supportURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else {
            throw AttentionStoreError.persistence("Application Support is unavailable.")
        }
        return FilePendingActionPersistence(directoryURL: supportURL.appendingPathComponent("Attention", isDirectory: true))
    }

    public func load(identity: ProfileIdentity) throws -> Data? {
        let retired = directoryURL.appendingPathComponent("\(identity.storageKey).plist")
        let url = fileURL(for: identity)
        if fileManager.fileExists(atPath: retired.path) {
            if !fileManager.fileExists(atPath: url.path) {
                // One-time transfer of user input only. The decoder has no
                // server-record fields and cannot restore the retired cache.
                let input = try PropertyListDecoder().decode(RetiredUnsentInput.self,
                    from: Data(contentsOf: retired))
                if input.profileIdentity == identity {
                    var pending = ClientSessionState(profileIdentity: identity)
                    pending.intents = input.intents ?? [:]
                    pending.intentByRequest = input.intentByRequest ?? [:]
                    pending.drafts = input.drafts ?? [:]
                    pending.pendingConversations = input.conversation?.threads ?? [:]
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    try commit(encoder.encode(PersistedPendingActions(state: pending)), identity: identity)
                }
            }
            // Delete only after the separate queue was committed. A restart
            // after that commit uses the new queue and never imports twice.
            try fileManager.removeItem(at: retired)
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 64 * 1_048_576 else {
                throw AttentionStoreError.persistence("The profile store exceeds its recovery size limit.")
            }
            return data
        } catch let error as AttentionStoreError {
            throw error
        } catch {
            throw AttentionStoreError.persistence(error.localizedDescription)
        }
    }

    public func commit(_ data: Data, identity: ProfileIdentity) throws {
        let target = fileURL(for: identity)
        let temporary = directoryURL.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fileManager.createDirectory(at: directoryURL,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try data.write(to: temporary, options: [.atomic])
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            try setPrivateAttributes(at: temporary)

            #if canImport(Darwin)
            let renameResult = temporary.path.withCString { source in
                target.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renameResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let directoryDescriptor = directoryURL.path.withCString { open($0, O_RDONLY) }
            if directoryDescriptor >= 0 {
                defer { _ = close(directoryDescriptor) }
                guard fsync(directoryDescriptor) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            #else
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: target)
            }
            #endif
        } catch let error as AttentionStoreError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw AttentionStoreError.persistence(error.localizedDescription)
        }
    }

    private func fileURL(for identity: ProfileIdentity) -> URL {
        directoryURL.appendingPathComponent("\(identity.storageKey).pending-actions.plist", isDirectory: false)
    }

    private func setPrivateAttributes(at url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }
}

public final class ClientRepository: @unchecked Sendable {
    // Serialize writers while presentation readers can keep using the last
    // committed state during a durable write.
    private let writerLock = NSRecursiveLock()
    private let lock = NSRecursiveLock()
    private let context: ProfileContext
    private let persistence: any PendingActionPersistence
    private let conversationFileReferences: (any ConversationFileReferenceStore)?
    private let maximumWireFrameBytes: Int
    private var state: ClientSessionState
    // Accepted answers leave the outbox but remain unresolved until their exact
    // terminal sequence has been replayed. Keep only those operations in a
    // request-keyed in-memory index so reconnects do not rescan settled history.
    private var acceptedAwaitingTerminalReplay: [RequestKey: Submission] = [:]
    private var selectorBindings: [UUID: SelectorBinding] = [:]
    private var changeObservers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var isInvalidated = false

    var profileContext: ProfileContext { context }
    public var requiresConfirmedServerProjection: Bool { context.transportMode == .relay }

    public init(context: ProfileContext,
                persistence: any PendingActionPersistence,
                maximumWireFrameBytes: Int = 65_536,
                conversationFileReferences: (any ConversationFileReferenceStore)? = nil) throws {
        self.context = context
        self.persistence = persistence
        self.conversationFileReferences = conversationFileReferences
        self.maximumWireFrameBytes = max(0, maximumWireFrameBytes)
        state = ClientSessionState(profileIdentity: context.identity)
        if let bytes = try persistence.load(identity: context.identity) {
            let queue = try PropertyListDecoder().decode(PersistedPendingActions.self, from: bytes)
            guard queue.version == 1, queue.profileIdentity == context.identity else {
                throw AttentionStoreError.persistence("The pending actions do not belong to this account.")
            }
            state.intents = queue.operations
            state.intentByRequest = queue.activeOperations
            state.fencedIntents = queue.cancelledOperations
            state.drafts = queue.answerDrafts
            state.pendingMessageOpens = queue.messageOpens
            state.pendingConversations = queue.conversations
            state.pendingReadPositions = queue.readPositions
        }
    }

    /// Replaces the disposable server cache. Pending user requests stay in the
    /// separate queue and cannot supply a missing server request or revision.
    public func restoreCachedServerState(_ cached: CachedAttentionServerState,
                                         context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else {
            throw AttentionStoreError.fixtureOnlyOperation
        }
        guard cached.identity == context.identity else { throw AttentionStoreError.wrongAccount }
        let keys = Set(cached.requests.keys)
            .union(cached.remoteStates.keys)
            .union(cached.conversations.keys)
        guard keys.allSatisfy({ $0.accountScope == context.identity.personID }) else {
            throw AttentionStoreError.wrongAccount
        }
        var next = state
        next.requests = cached.requests
        next.remoteStates = cached.remoteStates
        next.cursor = cached.cursor
        next.replayBarrier = nil
        next.replayPublishedRequests = nil
        next.replayPublishedStates = nil
        next.replayPublishedIntents = nil
        next.replayPublishedInboxCurrentKeys = nil
        next.appliedEvents = [:]
        next.inboxCheckpoint = nil
        next.inboxCandidate = nil
        next.cachedInboxCurrentKeys = cached.currentRequestKeys
        next.inboxView = cached.inboxView
        next.pendingRelayOverlays = nil
        next.inboxReferences = nil

        var conversation = ConversationState()
        conversation.cursor = cached.conversationCursor
        conversation.threads = cached.conversations
        conversation.chatReadPositions = cached.chatReadPositions
        conversation.chatReadPositionSupport = cached.chatReadPositions != nil
        next.server.conversation = conversation
        try commit(next)
        acceptedAwaitingTerminalReplay = Self.acceptedAwaitingTerminalReplay(in: state)
    }

    public func invalidate() {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        isInvalidated = true
        selectorBindings.removeAll()
    }

    public func registerFixtureRequests(_ requests: [StoredRequest], context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        var next = state
        var changed = false
        var acceptanceOrder = next.requests.values.compactMap(\.acceptanceOrder).max() ?? 0
        for request in requests {
            try validate(request.key, in: context.identity)
            if let existing = next.requests[request.key], let order = existing.acceptanceOrder {
                next.requests[request.key] = request.assigningAcceptanceOrder(order)
                changed = true
                continue
            }
            acceptanceOrder += 1
            next.requests[request.key] = request.assigningAcceptanceOrder(acceptanceOrder)
            let draft = RequestDraft(interface: request.interface)
            next.drafts[request.key] = draft
            next.fixtureSessions[request.key] = RequestSession(draft: draft)
            next.remoteStates[request.key] = RemoteRequestState()
            changed = true
        }
        if changed { try commit(next) }
    }

    public func resetFixtureState(_ requests: [StoredRequest], context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        var next = ClientSessionState(profileIdentity: context.identity)
        for (index, request) in requests.enumerated() {
            try validate(request.key, in: context.identity)
            next.requests[request.key] = request.assigningAcceptanceOrder(UInt64(index) + 1)
            let draft = RequestDraft(interface: request.interface)
            next.drafts[request.key] = draft
            next.fixtureSessions[request.key] = RequestSession(draft: draft)
            next.remoteStates[request.key] = RemoteRequestState()
        }
        selectorBindings.removeAll()
        try commit(next)
    }

    public func selector(for requestKey: RequestKey,
                         requestRevision requestedRevision: UInt64? = nil,
                         context suppliedContext: ProfileContext) throws -> BoundDocumentSelector {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        try validate(requestKey, in: context.identity)
        let thread = state.conversation?.threads[requestKey]
        let requestRevision = requestedRevision ?? thread?.currentRevision ?? 1
        guard requestRevision > 0 else { throw AttentionStoreError.requestMissing }
        let request: StoredRequest
        if let thread {
            guard requestRevision == thread.currentRevision,
                  thread.redactedRevisions?.contains(requestRevision) != true else {
                throw AttentionStoreError.selectorExpired
            }
            guard let payload = thread.revisions[requestRevision] else { throw AttentionStoreError.requestMissing }
            guard let acceptanceOrder = state.requests[requestKey]?.acceptanceOrder else {
                throw AttentionStoreError.missingAcceptanceOrder
            }
            request = StoredRequest(key: requestKey, originalPayload: payload)
                .assigningAcceptanceOrder(acceptanceOrder)
        } else {
            guard requestRevision == 1 else { throw AttentionStoreError.requestMissing }
            guard let original = state.requests[requestKey] else { throw AttentionStoreError.requestMissing }
            request = original
        }
        let id = UUID()
        let submissionID = UUID()
        selectorBindings[id] = SelectorBinding(requestRevision: requestRevision,
                                               requestKey: requestKey,
                                               profileGeneration: context.generation,
                                               descriptorFingerprint: fingerprint(request.answerDescription?.canonicalJSON ?? ""),
                                               submissionFingerprint: fingerprint(submissionSignature(for: requestInterface(for: request))),
                                               opaqueSubmissionID: ExactText(submissionID.uuidString.lowercased()))
        return BoundDocumentSelector(request: requestKey,
                                     requestRevision: requestRevision,
                                     opaqueDocumentID: ExactText(id.uuidString.lowercased()),
                                     opaqueSubmissionID: ExactText(submissionID.uuidString.lowercased()))
    }

    public func saveDraft(_ draft: RequestDraft,
                          selector: BoundDocumentSelector,
                          context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let request = try boundRequest(selector, context: suppliedContext)
        let interface = requestInterface(for: request)
        guard validateDraft(draft, for: interface) else { throw AttentionStoreError.invalidDraft }
        guard state.remoteStates[request.key]?.isTerminal != true,
              state.intentByRequest[request.key] == nil else {
            throw AttentionStoreError.requestClosed
        }
        var next = state
        storeAnswerDraft(draft, for: request.key, revision: selector.requestRevision, in: &next)
        if suppliedContext.transportMode == .fixture,
           var session = next.fixtureSessions[request.key], case .open = session.lifecycle {
            session.draft = draft
            next.fixtureSessions[request.key] = session
        }
        try commit(next)
    }

    public func previewSubmission(_ typedSubmission: TypedSubmission,
                                  draft: RequestDraft,
                                  selector: BoundDocumentSelector,
                                  context suppliedContext: ProfileContext) throws -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let request = try boundRequest(selector, context: suppliedContext)
        return try compose(typedSubmission, draft: draft, for: request)
    }

    @discardableResult
    public func submit(intentID: UUID,
                       typedSubmission: TypedSubmission,
                       typedInputs: [TypedInputRecord] = [],
                       draft: RequestDraft,
                       selector: BoundDocumentSelector,
                       context suppliedContext: ProfileContext,
                       persistAnswerDraft: Bool = true) throws -> Submission {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let request = try boundRequest(selector, context: suppliedContext)
        guard state.replayBarrier == nil else { throw AttentionStoreError.replayAlreadyActive }
        guard isUUIDv4(intentID) else { throw AttentionStoreError.invalidSubmission }
        let interface = requestInterface(for: request)
        guard validateDraft(draft, for: interface) else { throw AttentionStoreError.invalidDraft }
        let answer = try compose(typedSubmission, draft: draft, for: request)
        let descriptorFingerprint = fingerprint(request.answerDescription?.canonicalJSON ?? "")
        let normalizedInputs = normalizedSubmission(typedSubmission, interface: interface)
        var fingerprintParts = [
            request.key.accountScope.rawValue,
            request.key.senderID.rawValue,
            request.key.messageID.rawValue,
            descriptorFingerprint,
            normalizedInputs.canonicalJSON,
            answer.canonicalJSON
        ]
        fingerprintParts += ["request_revision", String(selector.requestRevision)]
        let contentFingerprint = fingerprint(fingerprintParts.joined(separator: "\u{0}"))

        if let existing = state.intents[intentID] {
            guard existing.requestKey == request.key,
                  existing.descriptorFingerprint == descriptorFingerprint,
                  existing.contentFingerprint == contentFingerprint,
                  existing.answer.semanticallyEquals(answer) else {
                throw AttentionStoreError.intentConflict
            }
            return existing
        }

        // A durable fence wins over a submit that entered the HTTP handler late.
        // A lookup miss alone cannot establish this ordering.
        if state.fencedIntents?[intentID] != nil {
            throw AttentionStoreError.intentConflict
        }

        if let activeID = state.intentByRequest[request.key] {
            throw AttentionStoreError.competingIntent(activeID)
        }
        guard state.remoteStates[request.key]?.isTerminal != true else { throw AttentionStoreError.requestClosed }
        let operationID = UUID()
        let operation = relayAnswerOperation(request: request, answer: answer, operationID: operationID,
                                             requestRevision: selector.requestRevision)
        let frame = Data((operation.jsonString + "\n").utf8)
        guard frame.count <= maximumWireFrameBytes else { throw AttentionStoreError.answerTooLarge }
        let submission = Submission(requestKey: request.key,
                                   answer: answer,
                                   intentID: intentID,
                                   operationID: operationID,
                                   operation: operation,
                                   typedInputs: typedInputs,
                                   opaqueDocumentID: selector.opaqueDocumentID,
                                   opaqueSubmissionID: selector.opaqueSubmissionID,
                                   descriptorFingerprint: descriptorFingerprint,
                                   contentFingerprint: contentFingerprint,
                                   requestRevision: selector.requestRevision)

        var next = state
        if persistAnswerDraft {
            storeAnswerDraft(draft, for: request.key, revision: selector.requestRevision, in: &next)
        } else {
            discardAnswerDraft(for: request.key, revision: selector.requestRevision, in: &next)
        }
        next.intents[intentID] = submission
        next.intentByRequest[request.key] = intentID
        if suppliedContext.transportMode == .fixture {
            next.outboxOrder.append(intentID)
        }
        if suppliedContext.transportMode == .fixture {
            let sessionDraft = persistAnswerDraft ? draft : RequestDraft(interface: interface)
            next.fixtureSessions[request.key] = RequestSession(draft: sessionDraft,
                                                               lifecycle: .pending(submission))
        }
        try commit(next)
        return submission
    }

    /// Persists the agreed payload-free answer frame. The local placeholder
    /// answer is never serialized onto the wire; `answerKind` is authoritative.
    @discardableResult
    public func submitNoComment(intentID: UUID,
                                selector: BoundDocumentSelector,
                                context suppliedContext: ProfileContext,
                                discardDraft: Bool = false) throws -> Submission {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let request = try boundRequest(selector, context: suppliedContext)
        guard suppliedContext.transportMode == .relay || suppliedContext.transportMode == .fixture,
              state.replayBarrier == nil,
              isUUIDv4(intentID) else { throw AttentionStoreError.invalidSubmission }
        let descriptorFingerprint = fingerprint(request.answerDescription?.canonicalJSON ?? "")
        var fingerprintParts = [
            request.key.accountScope.rawValue,
            request.key.senderID.rawValue,
            request.key.messageID.rawValue,
            descriptorFingerprint,
            "no_comment"
        ]
        let requestRevision = selector.requestRevision
        fingerprintParts += ["request_revision", String(requestRevision)]
        let wireRevision = requestRevision
        let contentFingerprint = fingerprint(fingerprintParts.joined(separator: "\u{0}"))

        if let existing = state.intents[intentID] {
            guard existing.requestKey == request.key,
                  existing.isNoComment,
                  existing.descriptorFingerprint == descriptorFingerprint,
                  existing.contentFingerprint == contentFingerprint else {
                throw AttentionStoreError.intentConflict
            }
            return existing
        }
        if state.fencedIntents?[intentID] != nil { throw AttentionStoreError.intentConflict }
        if let activeID = state.intentByRequest[request.key] {
            throw AttentionStoreError.competingIntent(activeID)
        }
        guard state.remoteStates[request.key]?.isTerminal != true else { throw AttentionStoreError.requestClosed }
        let operationID = UUID()
        let operation = JSONValue.object([
            JSONMember("type", .string(ExactText("answer_no_comment"))),
            JSONMember("request_id", .string(request.key.messageID)),
            JSONMember("request_revision", .number(JSONNumber(lexeme: String(wireRevision))))
        ])
        let frame = Data((operation.jsonString + "\n").utf8)
        guard frame.count <= maximumWireFrameBytes else { throw AttentionStoreError.answerTooLarge }
        let interface = requestInterface(for: request)
        let draft = discardDraft ? RequestDraft(interface: interface) :
            (state.conversation?.threads[request.key]?.answerDrafts?[requestRevision] ??
                (state.conversation?.threads[request.key]?.currentRevision == requestRevision
                    ? state.drafts[request.key] : nil) ?? RequestDraft(interface: interface))
        let submission = Submission(requestKey: request.key,
                                    answer: .null,
                                    answerKind: .noComment,
                                    intentID: intentID,
                                    operationID: operationID,
                                    operation: operation,
                                    opaqueDocumentID: selector.opaqueDocumentID,
                                    opaqueSubmissionID: selector.opaqueSubmissionID,
                                    descriptorFingerprint: descriptorFingerprint,
                                    contentFingerprint: contentFingerprint,
                                    requestRevision: requestRevision)
        var next = state
        next.intents[intentID] = submission
        next.intentByRequest[request.key] = intentID
        if suppliedContext.transportMode == .fixture {
            next.outboxOrder.append(intentID)
        }
        if discardDraft {
            discardAnswerDraft(for: request.key, revision: requestRevision, in: &next)
        }
        if suppliedContext.transportMode == .fixture {
            next.fixtureSessions[request.key] = RequestSession(draft: draft, lifecycle: .pending(submission))
        }
        try commit(next)
        return submission
    }

    public func lookupIntent(_ intentID: UUID, context suppliedContext: ProfileContext) throws -> Submission? {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        return state.intents[intentID]
    }

    /// Atomically proves that this intent did not commit and can never commit
    /// later in this profile. If submit won first, return its exact receipt.
    @discardableResult
    public func fenceUncommittedIntent(_ intentID: UUID,
                                       requestKey: RequestKey,
                                       context suppliedContext: ProfileContext) throws -> Submission? {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        try validate(requestKey, in: suppliedContext.identity)
        guard isUUIDv4(intentID), state.requests[requestKey] != nil else {
            throw AttentionStoreError.invalidSubmission
        }
        if let existing = state.intents[intentID] {
            guard existing.requestKey == requestKey else { throw AttentionStoreError.intentConflict }
            return existing
        }
        if let fencedKey = state.fencedIntents?[intentID] {
            guard fencedKey == requestKey else { throw AttentionStoreError.intentConflict }
            return nil
        }
        var next = state
        var fences = next.fencedIntents ?? [:]
        fences[intentID] = requestKey
        next.fencedIntents = fences
        try commit(next)
        return nil
    }

    public func retryOperation(_ intentID: UUID, context suppliedContext: ProfileContext) throws -> Submission? {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        guard state.outboxOrder.contains(intentID) else { return nil }
        return state.intents[intentID]
    }

    /// Persist a message-open observation before any relay send. Reopening the
    /// same content revision while its first report is pending reuses the
    /// original operation ID and exact identity.
    @discardableResult
    public func enqueueMessageOpen(_ requestKey: RequestKey,
                                   requestRevision: UInt64,
                                   context suppliedContext: ProfileContext) throws -> PendingMessageOpen {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        try validate(requestKey, in: suppliedContext.identity)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        guard requestRevision > 0 else { throw AttentionStoreError.invalidSubmission }

        let pending = state.pendingMessageOpens ?? []
        if let existing = pending.first(where: {
            $0.requestKey == requestKey && $0.requestRevision == requestRevision
        }) {
            return existing
        }

        var operationID = UUID()
        while pending.contains(where: { $0.operationID == operationID }) { operationID = UUID() }
        let operation = PendingMessageOpen(requestKey: requestKey,
                                           requestRevision: requestRevision,
                                           operationID: operationID)
        var next = state
        next.pendingMessageOpens = pending + [operation]
        try commit(next)
        return operation
    }

    /// Retire only the exact pending operation that received durable success
    /// or an explicit permanent rejection from the relay.
    @discardableResult
    public func retireMessageOpen(_ operationID: UUID,
                                  context suppliedContext: ProfileContext) throws -> Bool {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        let pending = state.pendingMessageOpens ?? []
        guard pending.contains(where: { $0.operationID == operationID }) else { return false }
        var next = state
        next.pendingMessageOpens = pending.filter { $0.operationID != operationID }
        try commit(next)
        return true
    }

    /// Queues one answer operation only for an explicit user retry. The exact
    /// operation and id are reused; no background refresh calls this method.
    @discardableResult
    public func queueOriginalOperationForUserTap(_ intentID: UUID,
                                                 context suppliedContext: ProfileContext) throws -> Submission {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var submission = state.intents[intentID],
              state.intentByRequest[submission.requestKey] == intentID else {
            throw AttentionStoreError.intentMissing
        }
        let currentKeys = state.inboxCheckpoint.flatMap { $0.checkpointAccepted ? $0.currentKeys : nil }
        guard state.requests[submission.requestKey] != nil,
              currentKeys?.contains(submission.requestKey) == true,
              state.remoteStates[submission.requestKey]?.isTerminal != true else {
            throw AttentionStoreError.requestClosed
        }
        let currentRevision = state.conversation?.threads[submission.requestKey]?.currentRevision ?? 1
        guard (submission.requestRevision ?? 1) == currentRevision else {
            throw AttentionStoreError.intentConflict
        }
        switch submission.disposition {
        case .pending, .lost:
            submission.disposition = .pending
        default:
            throw AttentionStoreError.intentConflict
        }
        var next = state
        next.intents[intentID] = submission
        if !next.outboxOrder.contains(intentID) { next.outboxOrder.append(intentID) }
        try commit(next)
        return submission
    }

    /// Retains the exact answer operation for a later explicit Retry tap.
    public func recordUnresolvedOperation(_ intentID: UUID,
                                          operationID: UUID,
                                          context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var submission = state.intents[intentID],
              submission.operationID == operationID,
              state.intentByRequest[submission.requestKey] == intentID else {
            throw AttentionStoreError.intentConflict
        }
        switch submission.disposition {
        case .pending, .lost:
            submission.disposition = .lost
        default:
            throw AttentionStoreError.intentConflict
        }
        var next = state
        next.intents[intentID] = submission
        next.outboxOrder.removeAll { $0 == intentID }
        try commit(next)
    }

    /// Drops an operation that was prepared locally but rejected before any
    /// send call opened, leaving its separately stored draft available.
    public func discardUnsentOperation(_ intentID: UUID,
                                       context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              let submission = state.intents[intentID],
              submission.disposition == .pending,
              !state.outboxOrder.contains(intentID) else {
            throw AttentionStoreError.intentConflict
        }
        var next = state
        next.intents.removeValue(forKey: intentID)
        next.intentByRequest.removeValue(forKey: submission.requestKey)
        next.outboxOrder.removeAll { $0 == intentID }
        try commit(next)
    }

    public func recordAcceptedOperation(_ intentID: UUID,
                                        operationID: UUID,
                                        terminalSequence: UInt64,
                                        context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        guard var intent = state.intents[intentID] else { throw AttentionStoreError.intentMissing }
        guard intent.operationID == operationID else { throw AttentionStoreError.intentConflict }
        intent.disposition = .accepted(sequence: terminalSequence)
        var next = state
        next.intents[intentID] = intent
        next.outboxOrder.removeAll(where: { $0 == intentID })
        if var published = next.replayPublishedIntents {
            published[intentID] = intent
            next.replayPublishedIntents = published
        }
        try commit(next)
        refreshAcceptedReplayIndex(for: intent.requestKey)
    }

    /// A server that cannot parse the agreed No comment frame leaves the
    /// request unanswered and releases it for ordinary answer methods.
    public func recordNoCommentUnsupported(_ intentID: UUID,
                                           operationID: UUID,
                                           context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var intent = state.intents[intentID], intent.operationID == operationID,
              intent.isNoComment,
              state.intentByRequest[intent.requestKey] == intentID else {
            throw AttentionStoreError.intentConflict
        }
        switch intent.disposition {
        case .pending, .lost:
            intent.disposition = .unsupported
        case .unsupported:
            return
        default:
            throw AttentionStoreError.intentConflict
        }
        var next = state
        next.intents[intentID] = intent
        next.outboxOrder.removeAll(where: { $0 == intentID })
        next.intentByRequest.removeValue(forKey: intent.requestKey)
        if var published = next.replayPublishedIntents {
            published[intentID] = intent
            next.replayPublishedIntents = published
        }
        try commit(next)
    }

    /// A correlated relay error proves this operation was not delivered. Retain
    /// the receipt for history while releasing its active request/outbox lock.
    public func recordAnswerNotDelivered(_ intentID: UUID,
                                         operationID: UUID,
                                         context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var intent = state.intents[intentID],
              intent.operationID == operationID,
              state.intentByRequest[intent.requestKey] == intentID else {
            throw AttentionStoreError.intentConflict
        }
        switch intent.disposition {
        case .pending, .lost:
            intent.disposition = .failed
        case .failed:
            return
        default:
            throw AttentionStoreError.intentConflict
        }
        var next = state
        next.intents[intentID] = intent
        next.outboxOrder.removeAll(where: { $0 == intentID })
        next.intentByRequest.removeValue(forKey: intent.requestKey)
        if var published = next.replayPublishedIntents {
            published[intentID] = intent
            next.replayPublishedIntents = published
        }
        try commit(next)
    }

    /// Persists a correlated stale-revision refusal and releases the request
    /// lock so an answer against the refreshed version can be submitted.
    public func recordAnswerStaleRevision(_ intentID: UUID,
                                          operationID: UUID,
                                          currentRevision: UInt64,
                                          context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var intent = state.intents[intentID],
              intent.operationID == operationID,
              currentRevision > (intent.requestRevision ?? 1) else {
            throw AttentionStoreError.intentConflict
        }
        switch intent.disposition {
        case .pending, .lost:
            intent.disposition = .staleRevision(currentRevision: currentRevision)
        case let .staleRevision(previous) where previous == currentRevision:
            return
        default:
            throw AttentionStoreError.intentConflict
        }
        var next = state
        next.intents[intentID] = intent
        next.outboxOrder.removeAll(where: { $0 == intentID })
        if next.intentByRequest[intent.requestKey] == intentID {
            next.intentByRequest.removeValue(forKey: intent.requestKey)
        }
        if var published = next.replayPublishedIntents {
            published[intentID] = intent
            next.replayPublishedIntents = published
        }
        try commit(next)
    }

    /// Persists the server's definite answer refusal without advancing either replay cursor.
    public func recordAnswerRefusedByRetraction(_ intentID: UUID,
                                                operationID: UUID,
                                                retractedAtMilliseconds: UInt64,
                                                context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        guard var intent = state.intents[intentID], intent.operationID == operationID,
              state.intentByRequest[intent.requestKey] == intentID else {
            throw AttentionStoreError.intentConflict
        }
        intent.disposition = .refusedByRetraction(retractedAtMilliseconds: retractedAtMilliseconds)
        var next = state
        next.intents[intentID] = intent
        next.outboxOrder.removeAll(where: { $0 == intentID })
        var remote = next.remoteStates[intent.requestKey] ?? RemoteRequestState()
        remote.state = .cleared
        next.remoteStates[intent.requestKey] = remote
        if var conversation = next.conversation, var thread = conversation.threads[intent.requestKey] {
            try thread.recordReportedRetraction(at: retractedAtMilliseconds)
            conversation.threads[intent.requestKey] = thread
            next.conversation = conversation
        }

        if var published = next.replayPublishedIntents {
            published[intentID] = intent
            next.replayPublishedIntents = published
        }
        try commit(next)
        refreshAcceptedReplayIndex(for: intent.requestKey)
    }

    public func recordClosedOperation(_ intentID: UUID,
                                      operationID: UUID,
                                      sequence: UInt64,
                                      state terminalState: TerminalState,
                                      authorizedOriginAnswer: JSONValue?,
                                      context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        guard var intent = state.intents[intentID] else { throw AttentionStoreError.intentMissing }
        guard intent.operationID == operationID else { throw AttentionStoreError.intentConflict }
        let effectiveAuthorizedAnswer = authorizedOriginAnswer
        intent.disposition = .terminal(state: terminalState,
                                       sequence: sequence,
                                       authorizedAnswer: effectiveAuthorizedAnswer)
        var next = state
        next.intents[intentID] = intent
        next.outboxOrder.removeAll(where: { $0 == intentID })
        var remote = next.remoteStates[intent.requestKey] ?? RemoteRequestState()
        remote.state = terminalState
        remote.authorizedOriginAnswer = effectiveAuthorizedAnswer
        remote.eventSequence = sequence
        next.remoteStates[intent.requestKey] = remote
        if var published = next.replayPublishedIntents {
            published[intentID] = intent
            next.replayPublishedIntents = published
        }
        if var publishedStates = next.replayPublishedStates {
            publishedStates[intent.requestKey] = next.remoteStates[intent.requestKey]
            next.replayPublishedStates = publishedStates
        }
        try commit(next)
        refreshAcceptedReplayIndex(for: intent.requestKey)
    }

    public func recordFixtureTerminal(_ terminal: FixtureTerminal,
                                      for requestKey: RequestKey,
                                      context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        guard var session = state.fixtureSessions[requestKey] else { throw AttentionStoreError.requestMissing }
        guard case let .pending(submission) = session.lifecycle else { throw AttentionStoreError.requestClosed }
        session.lifecycle = .terminal(terminal, submission)
        var next = state
        next.fixtureSessions[requestKey] = session
        try commit(next)
    }

    public func apply(_ event: RelayEvent, context suppliedContext: ProfileContext) throws -> UInt64 {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        let event = try Self.externalizingConversationFiles(in: event,
            using: conversationFileReferences,
            allowInlinePersistence: persistence is MemoryPendingActionPersistence)

        if event.sequence > state.cursor {
            let expected = state.cursor + 1
            guard event.sequence == expected else {
                try recordRepair(.eventGap(expected: expected, received: event.sequence))
                throw AttentionStoreError.eventGap(expected: expected, received: event.sequence)
            }
            if let barrier = state.replayBarrier, event.sequence > barrier {
                try recordRepair(.eventGap(expected: barrier, received: event.sequence))
                throw AttentionStoreError.eventGap(expected: barrier, received: event.sequence)
            }
        }

        var next = state
        switch event.body {
        case let .delivery(request, classification):
            try validate(request.key, in: context.identity)
            next.requests[request.key] = request.assigningAcceptanceOrder(event.sequence)
            let reference = next.inboxReferences?.removeValue(forKey: request.key)
            let previous = next.remoteStates[request.key] ?? reference
            var remoteState = previous?.state ?? next.conversation?.threads[request.key]?.terminal
            if event.conversation?.retractedAtMilliseconds != nil {
                remoteState = .cleared
            }
            var updated = previous ?? RemoteRequestState()
            updated.state = remoteState
            updated.authorizedOriginAnswer = previous?.authorizedOriginAnswer
            updated.classification = classification
            updated.eventSequence = event.sequence
            try updateAttentionTier(event.attentionTier, sequence: event.sequence, feed: .relay,
                                    origin: event.origin, in: &updated)
            next.remoteStates[request.key] = updated
        case let .originReference(requestKey):
            try validate(requestKey, in: context.identity)
            guard next.requests[requestKey] != nil else {
                try recordRepair(.missingOriginContent(sequence: event.sequence, requestKey: requestKey))
                throw AttentionStoreError.missingOriginContent(requestKey)
            }
            var updated = next.remoteStates[requestKey] ?? RemoteRequestState()
            updated.classification = nil
            updated.eventSequence = event.sequence
            try updateAttentionTier(event.attentionTier, sequence: event.sequence, feed: .relay,
                                    origin: event.origin, in: &updated)
            next.remoteStates[requestKey] = updated
        case let .terminal(requestKey, terminalState, authorizedOriginAnswer):
            try validate(requestKey, in: context.identity)
            guard next.requests[requestKey] != nil else {
                try recordRepair(.missingOriginContent(sequence: event.sequence, requestKey: requestKey))
                throw AttentionStoreError.missingOriginContent(requestKey)
            }
            let previous = next.remoteStates[requestKey] ?? RemoteRequestState()
            let effectiveAuthorizedAnswer = authorizedOriginAnswer ?? previous.authorizedOriginAnswer
            var updated = previous
            updated.state = terminalState
            updated.authorizedOriginAnswer = effectiveAuthorizedAnswer
            updated.accountAnswerOutcome = event.accountAnswerOutcome ?? previous.accountAnswerOutcome
            updated.eventSequence = event.sequence
            next.remoteStates[requestKey] = updated
            if terminalState == .superseded {
                try recordSupersedesOriginTarget(for: requestKey, terminalEvent: event, in: &next)
            }
            if let intentID = next.intentByRequest[requestKey], var intent = next.intents[intentID] {
                if preservesOperationResult(intent.disposition) {
                    // A later lifecycle event does not erase evidence that this exact operation won.
                } else {
                    intent.disposition = .terminal(state: terminalState,
                                                   sequence: event.sequence,
                                                   authorizedAnswer: effectiveAuthorizedAnswer)
                    next.intents[intentID] = intent
                }
                next.outboxOrder.removeAll(where: { $0 == intentID })
            }
        case let .attentionTierChange(requestKey):
            try validate(requestKey, in: context.identity)
            let isRequest = next.requests[requestKey] != nil
            guard isRequest || next.inboxReferences?[requestKey] != nil else {
                try recordRepair(.missingOriginContent(sequence: event.sequence, requestKey: requestKey))
                throw AttentionStoreError.missingOriginContent(requestKey)
            }
            var updated = isRequest
                ? (next.remoteStates[requestKey] ?? RemoteRequestState())
                : (next.inboxReferences?[requestKey] ?? RemoteRequestState())
            try updateAttentionTier(event.attentionTier, sequence: event.sequence, feed: .relay,
                                    origin: event.origin, in: &updated)
            if isRequest {
                next.remoteStates[requestKey] = updated
            } else {
                var references = next.inboxReferences ?? [:]
                references[requestKey] = updated
                next.inboxReferences = references
            }
        }
        try applyOrdinaryConversationMetadata(event, to: &next)
        if case let .delivery(request, _) = event.body {
            refreshEditableDraft(for: request.key, additionalFiles: Set(event.conversation?.files?.map(\.name) ?? []), in: &next)
        }
        if case let .terminal(key, _, _) = event.body {
            dropUnsentAnswer(for: key, in: &next)
        }
        if let requestKey = Self.requestKey(in: event) {
            Self.markInboxCurrent(requestKey, at: event.sequence, in: &next)
        }
        next.appliedEvents[event.sequence] = event
        next.cursor = max(next.cursor, event.sequence)
        next.repairIssues.removeAll { issue in
            switch issue {
            case let .eventGap(_, received): return received <= event.sequence + 1
            case let .missingOriginContent(sequence, _): return sequence == event.sequence
            }
        }
        try commit(next)
        if case let .terminal(requestKey, _, _) = event.body {
            refreshAcceptedReplayIndex(for: requestKey)
        }
        return state.cursor
    }

    /// Commits only the ordinary relay cursor for a sequenced update this
    /// client does not understand. No request state is fabricated or changed.
    @discardableResult
    public func advanceRelayCursor(overIgnoredUpdateAt sequence: UInt64,
                                   context suppliedContext: ProfileContext) throws -> UInt64 {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        if sequence <= state.cursor { return state.cursor }
        guard state.cursor < UInt64.max, sequence == state.cursor + 1 else {
            let expected = state.cursor == UInt64.max ? UInt64.max : state.cursor + 1
            try recordRepair(.eventGap(expected: expected, received: sequence))
            throw AttentionStoreError.eventGap(expected: expected, received: sequence)
        }
        if let barrier = state.replayBarrier, sequence > barrier {
            try recordRepair(.eventGap(expected: barrier, received: sequence))
            throw AttentionStoreError.eventGap(expected: barrier, received: sequence)
        }
        var next = state
        next.cursor = sequence
        next.repairIssues.removeAll { issue in
            switch issue {
            case let .eventGap(_, received): return sequence == UInt64.max || received <= sequence + 1
            case let .missingOriginContent(received, _): return received == sequence
            }
        }
        try commit(next)
        return state.cursor
    }

    private func applyOrdinaryConversationMetadata(_ event: RelayEvent,
                                                   terminalReceiptTarget: ExactText? = nil,
                                                   restoredTurns: [UInt64: ConversationEvent] = [:],
                                                   skippingHeldEvents: [UInt64: ConversationEvent] = [:],
                                                   onHeldEventFailure: ((ConversationEvent, ConversationValidationRejection?) -> Void)? = nil,
                                                   to next: inout ClientSessionState) throws {
        var conversation = next.conversation ?? ConversationState()
        switch event.body {
        case .delivery, .originReference:
            guard let metadata = event.conversation else { return }
            let request: StoredRequest
            switch event.body {
            case let .delivery(delivered, _): request = delivered
            case let .originReference(key):
                guard let retained = next.requests[key] else { throw AttentionStoreError.missingOriginContent(key) }
                request = retained.acceptanceOrder == nil ? retained.assigningAcceptanceOrder(event.sequence) : retained
                next.requests[key] = request
            default: throw ConversationError.invalidBinding
            }
            guard metadata.revision == 1, let handle = metadata.sessionHandle, !handle.rawValue.isEmpty else {
                throw ConversationError.invalidBinding
            }
            var thread: ConversationThread
            if let prior = conversation.threads[request.key] {
                thread = prior
                thread.sessionHandle = handle
                thread.revisions[1] = request.originalPayload
                thread.redactedRevisions?.remove(1)
            } else {
                thread = ConversationThread(request: request.key, sessionHandle: handle,
                    revision: 1, payload: request.originalPayload)
                if let availability = metadata.availability {
                    thread.availability = availability
                    thread.latestAvailabilityObservation = ConversationAvailabilityObservation(state: availability)
                }
                thread.listeningSupport = metadata.listeningSupport
                thread.terminal = next.remoteStates[request.key]?.state
                // The paired page terminal proves this receipt target before
                // its visible turn is appended after the held history.
                thread.terminalTurn = terminalReceiptTarget
                var preparedTurns: [UInt64: ConversationEvent] = [:]
                for (sequence, target) in restoredTurns where target.binding.request == request.key {
                    let prepared = try Self.externalizingConversationFiles(in: target,
                        using: conversationFileReferences,
                        allowInlinePersistence: persistence is MemoryPendingActionPersistence)
                    if case let .turn(turn) = prepared.fact { try validateConversationFiles(turn.files) }
                    preparedTurns[sequence] = prepared
                }
                try conversation.applyHeldEvents(to: &thread, restoredTurns: preparedTurns,
                    skipping: skippingHeldEvents, onFailure: onHeldEventFailure)
                for (sequence, ignored) in skippingHeldEvents
                    where ignored.binding.request == request.key {
                    conversation.events.removeValue(forKey: sequence)
                }
            }
            thread.listeningSupport = metadata.listeningSupport
            // Delivery hydrates the original request; it is not a new terminal
            // fact. Held server conversation events applied above may already
            // retract it. Fresh inbox snapshots rebuild this cache separately.
            if let reported = metadata.retractedAtMilliseconds { try thread.recordReportedRetraction(at: reported) }
            if let id = metadata.eventID, !thread.turns.contains(where: { $0.id == id }) {
                try validateConversationFiles(metadata.files ?? [])
                thread.turns.append(ConversationTurn(id: id, binding: ConversationBinding(request: request.key, revision: 1),
                    author: .origin, sessionHandle: handle, text: ExactText(""), files: metadata.files ?? [], kind: .revision))
                thread.facts[id, default: ConversationTurnFacts()] = thread.facts[id] ?? ConversationTurnFacts()
            }
            conversation.threads[request.key] = thread
        case let .terminal(key, terminal, _):
            guard var thread = conversation.threads[key] else { return }
            thread.terminal = terminal
            if let author = event.conversation?.author { thread.terminalAuthor = author }
            if let eventID = event.conversation?.eventID {
                thread.terminalTurn = eventID
                if let author = event.conversation?.author, let revision = event.conversation?.revision,
                   !thread.turns.contains(where: { $0.id == eventID }) {
                    thread.turns.append(ConversationTurn(id: eventID,
                        binding: ConversationBinding(request: key, revision: revision), author: author,
                        sessionHandle: thread.sessionHandle, text: ExactText(""), files: event.conversation?.files ?? [], kind: .terminal))
                    thread.facts[eventID, default: ConversationTurnFacts()] = thread.facts[eventID] ?? ConversationTurnFacts()
                }
            }
            if event.conversation?.terminalReason == ExactText("retracted") {
                guard terminal == .cleared,
                      let retractedAtMilliseconds = event.conversation?.retractedAtMilliseconds else {
                    throw ConversationError.invalidBinding
                }
                if event.conversation?.revision == nil {
                    // An inbox snapshot terminal carries the time; the conversation stream carries the retraction turn.
                    try thread.recordReportedRetraction(at: retractedAtMilliseconds)
                } else {
                    guard event.conversation?.author == .origin, let id = event.conversation?.eventID,
                          let revision = event.conversation?.revision else { throw ConversationError.invalidBinding }
                    try thread.recordRetraction(turn: id, sequence: event.sequence, revision: revision,
                        retractedAtMilliseconds: retractedAtMilliseconds)
                }
                if let saved = next.drafts[key] {
                    var archived = thread.answerDrafts ?? [:]
                    archived[thread.currentRevision] = saved
                    thread.answerDrafts = archived
                }
            }
            if conversation.chatReadPositionSupport == true {
                thread.accountReadThroughConversationSequence = conversation.chatReadPositions?[key] ?? 0
            }
            for revision in thread.drafts.keys {
                guard var draft = thread.drafts[revision] else { continue }
                if case .saved = draft.disposition {
                    draft.disposition = .rejected(ExactText("Not delivered: request closed"))
                    thread.drafts[revision] = draft
                }
            }
            conversation.threads[key] = thread
        case .attentionTierChange:
            return
        }
        next.conversation = conversation
    }

    private func applyInboxSnapshotItem(_ item: InboxSnapshotItem,
                                        highWater: UInt64,
                                        restoredTurns: [UInt64: ConversationEvent] = [:],
                                        skippingHeldEvents: [UInt64: ConversationEvent] = [:],
                                        onHeldEventFailure: ((ConversationEvent, ConversationValidationRejection?) -> Void)? = nil,
                                        to next: inout ClientSessionState) throws {
        let acceptance = item.acceptance
        let key = item.key
        guard acceptance.sequence > 0, acceptance.sequence <= highWater,
              key.accountScope == context.identity.personID else {
            throw AttentionStoreError.inboxPageConflict
        }
        let classification: RemoteDeliveryClassification?
        switch acceptance.body {
        case let .delivery(request, value):
            guard request.key == key else { throw AttentionStoreError.inboxPageConflict }
            try validate(request.key, in: context.identity)
            classification = value
            next.requests[key] = request.assigningAcceptanceOrder(acceptance.sequence)
            if let reference = next.inboxReferences?.removeValue(forKey: key), next.remoteStates[key] == nil {
                next.remoteStates[key] = reference
            }
        case .originReference:
            classification = nil
            if let existing = next.requests[key] {
                next.requests[key] = existing.assigningAcceptanceOrder(acceptance.sequence)
            }
        case .terminal:
            throw AttentionStoreError.inboxPageConflict
        case .attentionTierChange:
            throw AttentionStoreError.inboxPageConflict
        }
        let hasContent = next.requests[key] != nil
        let previous = hasContent ? next.remoteStates[key] : next.inboxReferences?[key]
        if let terminal = item.terminal {
            guard case let .terminal(terminalKey, terminalState, answer) = terminal.body,
                  terminalKey == key,
                  terminal.sequence > acceptance.sequence,
                  terminal.sequence <= highWater else { throw AttentionStoreError.inboxPageConflict }
            if (previous?.eventSequence ?? 0) <= highWater {
                let current = RemoteRequestState(state: terminalState,
                    authorizedOriginAnswer: answer,
                    accountAnswerOutcome: terminal.accountAnswerOutcome,
                    classification: classification,
                    eventSequence: terminal.sequence,
                    attentionTier: previous?.attentionTier,
                    attentionTierSequence: previous?.attentionTierSequence,
                    attentionTierFeed: previous?.attentionTierFeed,
                    attentionTierOrigin: previous?.attentionTierOrigin,
                    supersedesOriginTarget: previous?.supersedesOriginTarget,
                    supersededByMessageKeys: previous?.supersededByMessageKeys)
                if hasContent {
                    next.remoteStates[key] = current
                    try applyOrdinaryConversationMetadata(acceptance,
                        terminalReceiptTarget: terminal.conversation?.eventID,
                        restoredTurns: restoredTurns, skippingHeldEvents: skippingHeldEvents,
                        onHeldEventFailure: onHeldEventFailure, to: &next)
                    try applyOrdinaryConversationMetadata(terminal, to: &next)
                } else {
                    var references = next.inboxReferences ?? [:]
                    references[key] = current
                    next.inboxReferences = references
                }
            }
        } else {
            if (previous?.eventSequence ?? 0) <= highWater {
                let current = RemoteRequestState(state: nil,
                    authorizedOriginAnswer: nil,
                    accountAnswerOutcome: nil,
                    classification: classification,
                    eventSequence: acceptance.sequence,
                    attentionTier: previous?.attentionTier,
                    attentionTierSequence: previous?.attentionTierSequence,
                    attentionTierFeed: previous?.attentionTierFeed,
                    attentionTierOrigin: previous?.attentionTierOrigin,
                    supersedesOriginTarget: previous?.supersedesOriginTarget,
                    supersededByMessageKeys: previous?.supersededByMessageKeys)
                if hasContent {
                    next.remoteStates[key] = current
                } else {
                    var references = next.inboxReferences ?? [:]
                    references[key] = current
                    next.inboxReferences = references
                }
            }
        }
        var tierState = hasContent
            ? (next.remoteStates[key] ?? RemoteRequestState())
            : (next.inboxReferences?[key] ?? RemoteRequestState())
        try updateAttentionTier(item.attentionTier, sequence: highWater, feed: .relay,
                                origin: acceptance.origin, allowSameSequenceReplacement: true,
                                in: &tierState)
        if hasContent {
            next.remoteStates[key] = tierState
        } else {
            var references = next.inboxReferences ?? [:]
            references[key] = tierState
            next.inboxReferences = references
        }
        if hasContent {
            try applyOrdinaryConversationMetadata(acceptance, restoredTurns: restoredTurns,
                skippingHeldEvents: skippingHeldEvents, onHeldEventFailure: onHeldEventFailure, to: &next)
        }

        if hasContent {
            refreshEditableDraft(for: key, additionalFiles: Set(acceptance.conversation?.files?.map(\.name) ?? []), in: &next)
        }

        let pending = (next.pendingRelayOverlays ?? [:]).values
            .filter { Self.requestKey(in: $0) == key }
            .sorted { $0.sequence < $1.sequence }
        for event in pending where next.requests[key] != nil || next.inboxReferences?[key] != nil {
            try applyInboxProjection(event, to: &next)
            next.appliedEvents[event.sequence] = event
            next.pendingRelayOverlays?.removeValue(forKey: event.sequence)
        }
    }

    /// Applies a terminal/reference fact without claiming that its sequence was contiguous.
    /// Missing message content is kept as exact pending work until a later page hydrates G.
    private func recordInboxTerminalProjection(_ event: RelayEvent,
                                               into next: inout ClientSessionState) throws {
        guard let key = Self.requestKey(in: event),
              key.accountScope == context.identity.personID,
              event.sequence > 0 else { throw AttentionStoreError.inboxPageConflict }
        switch event.body {
        case .delivery:
            throw AttentionStoreError.inboxPageConflict
        case .originReference, .attentionTierChange, .terminal:
            break
        }
        try validate(key, in: context.identity)
        guard next.requests[key] != nil || next.inboxReferences?[key] != nil else {
            next.pendingRelayOverlays = next.pendingRelayOverlays ?? [:]
            next.pendingRelayOverlays?[event.sequence] = event
            return
        }
        try applyInboxProjection(event, to: &next)
        next.appliedEvents[event.sequence] = event
        next.pendingRelayOverlays?.removeValue(forKey: event.sequence)
    }

    private func applyInboxProjection(_ event: RelayEvent,
                                      to next: inout ClientSessionState) throws {
        guard let key = Self.requestKey(in: event),
              next.requests[key] != nil || next.inboxReferences?[key] != nil else {
            throw AttentionStoreError.inboxPageConflict
        }
        let hasContent = next.requests[key] != nil
        let previous = hasContent ? next.remoteStates[key] : next.inboxReferences?[key]
        let currentPrevious = previous ?? RemoteRequestState()
        switch event.body {
        case let .terminal(_, terminalState, answer):
            if event.sequence < (currentPrevious.eventSequence ?? 0) { return }
            var updated = RemoteRequestState(state: terminalState,
                authorizedOriginAnswer: answer ?? currentPrevious.authorizedOriginAnswer,
                accountAnswerOutcome: event.accountAnswerOutcome ?? currentPrevious.accountAnswerOutcome,
                classification: currentPrevious.classification,
                eventSequence: event.sequence,
                attentionTier: currentPrevious.attentionTier,
                attentionTierSequence: currentPrevious.attentionTierSequence,
                attentionTierFeed: currentPrevious.attentionTierFeed,
                attentionTierOrigin: currentPrevious.attentionTierOrigin,
                supersedesOriginTarget: currentPrevious.supersedesOriginTarget,
                supersededByMessageKeys: currentPrevious.supersededByMessageKeys)
            if hasContent {
                next.remoteStates[key] = updated
                try applyOrdinaryConversationMetadata(event, to: &next)
            } else {
                var references = next.inboxReferences ?? [:]
                references[key] = updated
                next.inboxReferences = references
            }
            if terminalState == .superseded {
                try recordSupersedesOriginTarget(for: key, terminalEvent: event, in: &next)
            }
        case .originReference:
            if event.sequence < (currentPrevious.eventSequence ?? 0) { return }
            var updated = currentPrevious
            updated.classification = nil
            updated.eventSequence = event.sequence
            try updateAttentionTier(event.attentionTier, sequence: event.sequence, feed: .relay,
                                    origin: event.origin, in: &updated)
            if hasContent {
                next.remoteStates[key] = updated
                try applyOrdinaryConversationMetadata(event, to: &next)
            } else {
                var references = next.inboxReferences ?? [:]
                references[key] = updated
                next.inboxReferences = references
            }
        case .attentionTierChange:
            var updated = currentPrevious
            try updateAttentionTier(event.attentionTier, sequence: event.sequence, feed: .relay,
                                    origin: event.origin, in: &updated)
            if hasContent {
                next.remoteStates[key] = updated
            } else {
                var references = next.inboxReferences ?? [:]
                references[key] = updated
                next.inboxReferences = references
            }
        case .delivery:
            throw AttentionStoreError.inboxPageConflict
        }
    }

    /// The accepted forward event precedes its superseded lifecycle events.
    /// Several targets can be superseded by one forward, so walk back across
    /// that event's adjacent superseded terminals when resolving later targets.
    private func recordSupersedesOriginTarget(for target: RequestKey,
                                              terminalEvent: RelayEvent,
                                              in next: inout ClientSessionState) throws {
        guard let replacementKey = Self.supersedingReplacementKey(
            for: target, before: terminalEvent.sequence,
            requests: next.requests, appliedEvents: next.appliedEvents,
            pendingEvents: next.pendingRelayOverlays ?? [:]) else { return }

        if var targetState = next.remoteStates[target] {
            var replacements = targetState.supersededByMessageKeys ?? []
            if !replacements.contains(replacementKey) {
                replacements.append(replacementKey)
            }
            targetState.supersededByMessageKeys = replacements
            next.remoteStates[target] = targetState
        } else if var references = next.inboxReferences,
                  var targetState = references[target] {
            var replacements = targetState.supersededByMessageKeys ?? []
            if !replacements.contains(replacementKey) {
                replacements.append(replacementKey)
            }
            targetState.supersededByMessageKeys = replacements
            references[target] = targetState
            next.inboxReferences = references
        }

        guard let replacement = next.requests[replacementKey],
              replacement.supersedesMessageIDs.contains(target.messageID) else { return }
        var replacementState = next.remoteStates[replacementKey] ?? RemoteRequestState()
        if let originTarget = Self.firstSupersededOriginTarget(for: replacement, in: next) {
            // A single forward may supersede several open targets. Its first
            // superseded terminal establishes the inbox origin; later
            // terminals add their own forward links without conflicting.
            replacementState.supersedesOriginTarget = originTarget
        }
        next.remoteStates[replacementKey] = replacementState
    }

    /// Older account files and paged inbox projections may lack the inverse
    /// relationship field. Reconstruct it from retained terminal and accepted
    /// request identities so older messages can show their forward link.
    private static func backfillSupersededByMessageKeys(
        in state: inout ClientSessionState,
        affectedTargets: Set<RequestKey>? = nil,
        additionalEvents: [UInt64: RelayEvent] = [:]
    ) {
        let targetKeys: Set<RequestKey>
        if let affectedTargets {
            targetKeys = affectedTargets
        } else {
            targetKeys = Set(state.remoteStates.compactMap { key, remote in
                remote.state == .superseded ? key : nil
            } + (state.inboxReferences ?? [:]).compactMap { key, remote in
                remote.state == .superseded ? key : nil
            })
        }
        guard !targetKeys.isEmpty else { return }

        var terminalSequences: [RequestKey: UInt64] = [:]
        for target in targetKeys {
            let remote = state.remoteStates[target] ?? state.inboxReferences?[target]
            if remote?.state == .superseded, let sequence = remote?.eventSequence, sequence > 0 {
                terminalSequences[target] = sequence
            }
        }
        guard !terminalSequences.isEmpty else { return }

        // Build the inverse lookup once, then visit only superseded targets
        // touched by this load/page. The former per-terminal scan repeated a
        // full request scan and could grow as O(superseded × request history).
        var acceptanceSequences: [RequestKey: UInt64] = [:]
        for (sequence, event) in state.appliedEvents.merging(additionalEvents, uniquingKeysWith: { _, new in new }) {
            switch event.body {
            case let .delivery(request, _):
                acceptanceSequences[request.key] = min(acceptanceSequences[request.key] ?? sequence, sequence)
            case let .originReference(key):
                acceptanceSequences[key] = min(acceptanceSequences[key] ?? sequence, sequence)
            case .terminal, .attentionTierChange:
                break
            }
        }

        var replacementsByTarget: [RequestKey: [(UInt64, RequestKey)]] = [:]
        for request in state.requests.values {
            guard let acceptanceSequence = request.acceptanceOrder ?? acceptanceSequences[request.key] else {
                continue
            }
            for messageID in request.supersedesMessageIDs {
                let target = RequestKey(accountScope: request.key.accountScope,
                                        senderID: request.key.senderID,
                                        messageID: messageID)
                guard terminalSequences[target] != nil else { continue }
                replacementsByTarget[target, default: []].append((acceptanceSequence, request.key))
            }
        }
        for target in replacementsByTarget.keys {
            replacementsByTarget[target]?.sort {
                if $0.0 != $1.0 { return $0.0 < $1.0 }
                return $0.1.messageID.rawValue < $1.1.messageID.rawValue
            }
        }

        var affectedReplacementKeys = Set<RequestKey>()
        for (target, sequence) in terminalSequences {
            var replacementOrders = (replacementsByTarget[target] ?? []).filter { $0.0 < sequence }
            if replacementOrders.isEmpty,
               let inferred = supersedingReplacementKey(
                    for: target, before: sequence,
                    requests: state.requests, appliedEvents: state.appliedEvents,
                    pendingEvents: state.pendingRelayOverlays ?? [:],
                    replacementIndex: replacementsByTarget,
                    additionalEvents: additionalEvents) {
                replacementOrders.append((acceptanceSequences[inferred] ?? sequence - 1, inferred))
            }
            var seen = Set<RequestKey>()
            let replacementKeys = replacementOrders.compactMap { pair in
                seen.insert(pair.1).inserted ? pair.1 : nil
            }
            affectedReplacementKeys.formUnion(replacementKeys)

            if var targetState = state.remoteStates[target] {
                var replacements = targetState.supersededByMessageKeys ?? []
                for replacementKey in replacementKeys where !replacements.contains(replacementKey) {
                    replacements.append(replacementKey)
                }
                targetState.supersededByMessageKeys = replacements
                state.remoteStates[target] = targetState
            } else if var references = state.inboxReferences,
                      var targetState = references[target] {
                var replacements = targetState.supersededByMessageKeys ?? []
                for replacementKey in replacementKeys where !replacements.contains(replacementKey) {
                    replacements.append(replacementKey)
                }
                targetState.supersededByMessageKeys = replacements
                references[target] = targetState
                state.inboxReferences = references
            }
        }

        // Inbox pages can arrive in display order rather than terminal-event
        // order. Recompute each affected forward request's slot from the
        // earliest superseded target currently known, allowing an older page
        // to refine an origin first learned from a newer page.
        for replacementKey in affectedReplacementKeys {
            guard let replacement = state.requests[replacementKey],
                  let acceptanceSequence = replacement.acceptanceOrder ?? acceptanceSequences[replacementKey],
                  let originTarget = firstSupersededOriginTarget(
                    for: replacement, after: acceptanceSequence, in: state) else { continue }
            var replacementState = state.remoteStates[replacementKey] ?? RemoteRequestState()
            replacementState.supersedesOriginTarget = originTarget
            state.remoteStates[replacementKey] = replacementState
        }
    }

    private static func firstSupersededOriginTarget(
        for replacement: StoredRequest,
        after acceptanceSequence: UInt64? = nil,
        in state: ClientSessionState
    ) -> RequestKey? {
        let acceptance = acceptanceSequence ?? replacement.acceptanceOrder
        var first: (sequence: UInt64, root: RequestKey)?
        for messageID in replacement.supersedesMessageIDs {
            let target = RequestKey(accountScope: replacement.key.accountScope,
                                    senderID: replacement.key.senderID,
                                    messageID: messageID)
            guard let targetState = state.remoteStates[target] ?? state.inboxReferences?[target],
                  targetState.state == .superseded,
                  let sequence = targetState.eventSequence,
                  acceptance.map({ sequence > $0 }) ?? true else { continue }
            let root = targetState.supersedesOriginTarget ?? target
            if let current = first, sequence >= current.sequence { continue }
            first = (sequence, root)
        }
        return first?.root
    }

    private static func supersedeTargets(in items: [InboxSnapshotItem]) -> Set<RequestKey> {
        var targets = Set<RequestKey>()
        for item in items {
            if let terminal = item.terminal,
               case let .terminal(target, .superseded, _) = terminal.body {
                targets.insert(target)
            }
            if case let .delivery(request, _) = item.acceptance.body {
                for messageID in request.supersedesMessageIDs {
                    targets.insert(RequestKey(accountScope: request.key.accountScope,
                                              senderID: request.key.senderID,
                                              messageID: messageID))
                }
            }
        }
        return targets
    }

    private static func events(in items: [InboxSnapshotItem]) -> [UInt64: RelayEvent] {
        var events: [UInt64: RelayEvent] = [:]
        for item in items {
            events[item.acceptance.sequence] = item.acceptance
            if let terminal = item.terminal { events[terminal.sequence] = terminal }
        }
        return events
    }

    private static func supersedingReplacementKey(
        for target: RequestKey,
        before terminalSequence: UInt64,
        requests: [RequestKey: StoredRequest],
        appliedEvents: [UInt64: RelayEvent],
        pendingEvents: [UInt64: RelayEvent],
        replacementIndex: [RequestKey: [(UInt64, RequestKey)]]? = nil,
        additionalEvents: [UInt64: RelayEvent] = [:]
    ) -> RequestKey? {
        func latestAcceptedReplacement() -> RequestKey? {
            if let replacementIndex {
                guard let indexed = replacementIndex[target] else { return nil }
                return indexed.last(where: { $0.0 < terminalSequence })?.1
            }
            return requests.values.compactMap { request -> (UInt64, RequestKey)? in
                guard request.key.accountScope == target.accountScope,
                      request.key.senderID == target.senderID,
                      request.supersedesMessageIDs.contains(target.messageID),
                      let acceptanceOrder = request.acceptanceOrder,
                      acceptanceOrder < terminalSequence else { return nil }
                return (acceptanceOrder, request.key)
            }.max { $0.0 < $1.0 }?.1
        }

        guard terminalSequence > 1 else { return nil }
        var sequence = terminalSequence - 1
        while sequence > 0 {
            guard let previousEvent = appliedEvents[sequence] ?? additionalEvents[sequence] ?? pendingEvents[sequence] else {
                return latestAcceptedReplacement()
            }
            switch previousEvent.body {
            case let .delivery(request, _):
                guard request.key.accountScope == target.accountScope,
                      request.key.senderID == target.senderID,
                      request.supersedesMessageIDs.contains(target.messageID) else {
                    return latestAcceptedReplacement()
                }
                return request.key
            case let .originReference(key):
                guard key.accountScope == target.accountScope,
                      key.senderID == target.senderID else { return latestAcceptedReplacement() }
                if let replacement = requests[key],
                   !replacement.supersedesMessageIDs.contains(target.messageID) {
                    return latestAcceptedReplacement()
                }
                return key
            case let .terminal(_, state, _) where state == .superseded:
                sequence -= 1
            case .terminal, .attentionTierChange:
                return latestAcceptedReplacement()
            }
        }
        return latestAcceptedReplacement()
    }

    private func updateAttentionTier(_ tier: AttentionTier,
                                     sequence: UInt64,
                                     feed: AttentionTierFeed,
                                     origin: ExactText?,
                                     allowSameSequenceReplacement: Bool = false,
                                     in state: inout RemoteRequestState) throws {
        switch (state.attentionTierFeed, feed) {
        case (.some(.conversation), .relay):
            // Conversation changes may arrive before the ordinary delivery.
            return
        case (.some(.relay), .conversation):
            // The two cursors are independent; the conversation fact is the change to apply.
            break
        case (.some(.relay), .relay), (.some(.conversation), .conversation):
            if let previousSequence = state.attentionTierSequence {
                if sequence < previousSequence { return }
                if sequence == previousSequence {
                    state.attentionTier = tier
                    if let origin { state.attentionTierOrigin = origin }
                    return
                }
            }
        case (.none, _):
            break
        }

        state.attentionTier = tier
        state.attentionTierSequence = sequence
        state.attentionTierFeed = feed
        if let origin { state.attentionTierOrigin = origin }
    }

    private func refreshAcceptedReplayIndexes(for requestKeys: some Sequence<RequestKey>) {
        for key in requestKeys { refreshAcceptedReplayIndex(for: key) }
    }

    private static func requestKey(in event: RelayEvent) -> RequestKey? {
        switch event.body {
        case let .delivery(request, _): request.key
        case let .originReference(key), let .terminal(key, _, _), let .attentionTierChange(key): key
        }
    }

    private static func markInboxCurrent(_ key: RequestKey,
                                         at sequence: UInt64,
                                         in next: inout ClientSessionState) {
        guard var checkpoint = next.inboxCheckpoint,
              checkpoint.checkpointAccepted,
              let highWater = checkpoint.highWater,
              sequence > highWater else { return }
        var current = checkpoint.currentKeys
        current.insert(key)
        checkpoint.freshKeys = current
        next.inboxCheckpoint = checkpoint
    }

    private static func acceptedSequence(_ submission: Submission) -> UInt64 {
        guard case let .accepted(sequence) = submission.disposition else { return .max }
        return sequence ?? .max
    }

    private static func isAccepted(_ submission: Submission) -> Bool {
        if case .accepted = submission.disposition { return true }
        return false
    }

    private static func resultSequence(_ result: JSONValue) -> UInt64? {
        guard let raw = result.uniqueValue(named: "seq"),
              case let .number(number) = raw else { return nil }
        return UInt64(number.lexeme)
    }

    private static func recordInboxOperationFailure(_ submission: Submission,
                                                    in state: inout ClientSessionState) {
        var failed = submission
        failed.disposition = .failed
        state.intents[submission.intentID] = failed
        state.outboxOrder.removeAll(where: { $0 == submission.intentID })
        if state.intentByRequest[submission.requestKey] == submission.intentID {
            state.intentByRequest.removeValue(forKey: submission.requestKey)
        }
        if var published = state.replayPublishedIntents {
            published[submission.intentID] = failed
            state.replayPublishedIntents = published
        }
    }

    public func applyRelayEvent(_ event: RelayEvent,
                                context suppliedContext: ProfileContext) -> ApplyEventResult {
        if let result = deferUnloadedContiguousFact(event, context: suppliedContext) {
            return result
        }
        let prior = try? snapshot(context: suppliedContext)
        let wasRepeat = event.sequence <= (prior?.cursor ?? 0)
        let priorClassification: RemoteDeliveryClassification?
        if case let .delivery(request, _) = event.body {
            priorClassification = prior?.remoteStates[request.key]?.classification
        } else {
            priorClassification = nil
        }

        do {
            let cursor = try apply(event, context: suppliedContext)
            if wasRepeat {
                let changed: Bool
                if case let .delivery(_, classification) = event.body {
                    changed = priorClassification != classification
                } else {
                    changed = false
                }
                return .compatibleRepeat(contiguousCursor: cursor, classificationChanged: changed)
            }
            guard try snapshot(context: suppliedContext).replayBarrier == nil else {
                return .committed(contiguousCursor: cursor, publishable: nil)
            }
            let port = AttentionDomainPort(store: self)
            let published = try port.observe(context: port.context)
            return .committed(contiguousCursor: cursor, publishable: published)
        } catch let error as AttentionStoreError {
            switch error {
            case let .eventGap(expected, _):
                return .gap(expected: expected)
            default:
                return .repairRequired
            }
        } catch {
            return .repairRequired
        }
    }

    private func deferUnloadedContiguousFact(_ event: RelayEvent,
                                             context suppliedContext: ProfileContext) -> ApplyEventResult? {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        do {
            try validate(suppliedContext)
            guard suppliedContext.transportMode == .relay,
                  event.sequence == state.cursor + 1,
                  let key = Self.requestKey(in: event),
                  key.accountScope == context.identity.personID,
                  state.requests[key] == nil else { return nil }
            switch event.body {
            case .terminal, .originReference, .attentionTierChange: break
            case .delivery: return nil
            }
            if let barrier = state.replayBarrier, event.sequence > barrier { return .gap(expected: barrier) }
            var next = state
            var overlays = next.pendingRelayOverlays ?? [:]
            overlays[event.sequence] = event
            next.pendingRelayOverlays = overlays
            Self.markInboxCurrent(key, at: event.sequence, in: &next)
            next.cursor = max(next.cursor, event.sequence)
            try commit(next)
            return .deferred(contiguousCursor: state.cursor)
        } catch let error as AttentionStoreError {
            if case let .eventGap(expected, _) = error { return .gap(expected: expected) }
            return .repairRequired
        } catch {
            return .repairRequired
        }
    }

    public func beginReplay(through highWaterSequence: UInt64,
                            context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        if let activeBarrier = state.replayBarrier {
            if activeBarrier == highWaterSequence { return }
            guard highWaterSequence == UInt64.max else { throw AttentionStoreError.replayAlreadyActive }
            // A prior bounded client may have crashed with a finite barrier.
            // Preserve its last published view while streaming the remainder.
            var promoted = state
            promoted.replayBarrier = UInt64.max
            try commit(promoted)
            return
        }
        guard highWaterSequence >= state.cursor else {
            throw AttentionStoreError.replayIncomplete(expected: highWaterSequence, actual: state.cursor)
        }
        var next = state
        next.replayBarrier = highWaterSequence
        next.replayPublishedRequests = state.requests
        next.replayPublishedStates = state.remoteStates
        next.replayPublishedIntents = state.intents
        // A replay barrier publishes the last accepted inbox view while fresh
        // state is checked. A recoverable candidate must not dim every row.
        next.replayPublishedInboxCurrentKeys = state.inboxCheckpoint.flatMap {
            $0.checkpointAccepted ? $0.currentKeys : nil
        }
        try commit(next)
    }

    public func finishReplay(at resyncedSequence: UInt64,
                             context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard let barrier = state.replayBarrier else { throw AttentionStoreError.replayNotActive }
        guard (barrier == resyncedSequence || barrier == UInt64.max),
              state.cursor == resyncedSequence else {
            throw AttentionStoreError.replayIncomplete(expected: barrier, actual: state.cursor)
        }
        var next = state
        next.replayBarrier = nil
        next.replayPublishedRequests = nil
        next.replayPublishedStates = nil
        next.replayPublishedIntents = nil
        next.replayPublishedInboxCurrentKeys = nil
        try commit(next)
    }

    public func resolveOriginReference(sequence: UInt64,
                                       request: StoredRequest,
                                       context suppliedContext: ProfileContext) throws -> UInt64 {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        try validate(request.key, in: context.identity)
        guard sequence == state.cursor + 1,
              state.repairIssues.contains(.missingOriginContent(sequence: sequence, requestKey: request.key)) else {
            throw AttentionStoreError.missingOriginContent(request.key)
        }
        var next = state
        next.requests[request.key] = request.assigningAcceptanceOrder(sequence)
        if next.drafts[request.key] == nil {
            next.drafts[request.key] = RequestDraft(interface: requestInterface(for: request))
        }
        next.appliedEvents[sequence] = RelayEvent(sequence: sequence, body: .originReference(request.key))
        var remote = next.remoteStates[request.key] ?? RemoteRequestState()
        remote.classification = nil
        remote.eventSequence = sequence
        next.remoteStates[request.key] = remote
        next.cursor = sequence
        next.repairIssues.removeAll { $0 == .missingOriginContent(sequence: sequence, requestKey: request.key) }
        try commit(next)
        return state.cursor
    }

    /// Exact operation originals that must be covered before a new paging checkpoint.
    /// The ordinary outbox and accepted-awaiting-terminal index are disjoint by design.
    public func inboxOperationInventory(context suppliedContext: ProfileContext) throws -> [Submission] {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        var seen = Set<UUID>()
        var inventory: [Submission] = []
        for id in state.outboxOrder {
            guard let submission = state.intents[id], seen.insert(submission.operationID).inserted else { continue }
            inventory.append(submission)
        }
        return inventory
    }

    public func beginInboxCandidate(startupID: String,
                                    since: UInt64,
                                    batches: [InboxReceiptBatch],
                                    context suppliedContext: ProfileContext) throws -> InboxPagingCheckpoint {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        if let existing = state.inboxCandidate {
            guard existing.since == state.cursor else { throw AttentionStoreError.inboxCheckpointIncomplete }
            return existing
        }
        guard !startupID.isEmpty, since == state.cursor else {
            throw AttentionStoreError.inboxCheckpointIncomplete
        }
        let inventory = try inboxOperationInventory(context: suppliedContext)
        let expected = inventory.map(\.operationID)
        let submitted = batches.flatMap(\.operationIDs)
        guard Set(submitted).count == submitted.count,
              Set(submitted) == Set(expected),
              Set(batches.map(\.batchID)).count == batches.count,
              batches.allSatisfy({ !$0.batchID.isEmpty && !$0.operationIDs.isEmpty && $0.results == nil }) else {
            throw AttentionStoreError.inboxCheckpointIncomplete
        }
        let candidate = InboxPagingCheckpoint(startupID: startupID, since: since, batches: batches)
        var next = state
        // Starting a request is not a server update. Keep the last accepted
        // cache available if the transport fails before returning a snapshot.
        next.inboxCandidate = candidate
        try commit(next)
        return candidate
    }

    public func discardInboxCandidate(context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard let candidate = state.inboxCandidate else { return }
        guard !candidate.checkpointRequestStarted else { throw AttentionStoreError.inboxCheckpointPending }
        var next = state
        next.inboxCandidate = nil
        try commit(next)
    }

    /// A server `snapshot_replaced` refusal proves the saved continuation no
    /// longer names the current generation. Retain every receipt/overlay and
    /// operation record, but allow a new bounded candidate from the durable C.
    public func discardReplacedInboxCandidate(snapshotID: String,
                                              context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard let candidate = state.inboxCandidate,
              candidate.snapshotID == snapshotID else {
            throw AttentionStoreError.inboxCheckpointIncomplete
        }
        var next = state
        next.inboxCandidate = nil
        try commit(next)
    }

    public func saveInboxInitialPage(snapshotID: String,
                                     highWater: UInt64,
                                     items: [InboxSnapshotItem],
                                     nextCursor: String?,
                                     receiptCursor: String?,
                                     context suppliedContext: ProfileContext) throws {
        var validationRejection: ConversationValidationRejection?
        try saveInboxInitialPage(snapshotID: snapshotID, highWater: highWater, items: items,
            nextCursor: nextCursor, receiptCursor: receiptCursor, context: suppliedContext,
            validationRejection: &validationRejection)
    }

    public func saveInboxInitialPage(snapshotID: String,
                                     highWater: UInt64,
                                     items: [InboxSnapshotItem],
                                     nextCursor: String?,
                                     receiptCursor: String?,
                                     context suppliedContext: ProfileContext,
                                     validationRejection: inout ConversationValidationRejection?,
                                     restoredTurns: [UInt64: ConversationEvent] = [:],
                                     skippingHeldEvents: [UInt64: ConversationEvent] = [:],
                                     onHeldEventFailure: ((ConversationEvent, ConversationValidationRejection?) -> Void)? = nil) throws {
        validationRejection = nil
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var candidate = state.inboxCandidate,
              !snapshotID.isEmpty,
              highWater >= candidate.since,
              items.count <= 20 else { throw AttentionStoreError.inboxCheckpointIncomplete }
        let keys = items.map(\.key)
        guard Set(keys).count == keys.count,
              keys.allSatisfy({ $0.accountScope == context.identity.personID }) else {
            throw AttentionStoreError.inboxPageConflict
        }
        if candidate.hasInitialPage {
            guard candidate.snapshotID == snapshotID,
                  candidate.highWater == highWater,
                  candidate.nextCursor == nextCursor,
                  candidate.receiptCursor == receiptCursor,
                  candidate.loadedKeys == Set(keys),
                  candidate.sourceOrder == nil || candidate.sourceOrder == keys else {
                throw AttentionStoreError.inboxPageConflict
            }
            if candidate.sourceOrder == nil {
                candidate.sourceOrder = keys
                var next = state
                next.inboxCandidate = candidate
                try commit(next)
            }
            return
        }
        var next = state
        // The actual server response replaces the disposable projection,
        // including an empty snapshot. User intents remain in their own queue.
        next.server = ServerProjectionCache()
        next.cursor = candidate.since
        do {
            for item in items {
                try applyInboxSnapshotItem(item, highWater: highWater, restoredTurns: restoredTurns,
                    skippingHeldEvents: skippingHeldEvents, onHeldEventFailure: onHeldEventFailure, to: &next)
            }
            Self.backfillSupersededByMessageKeys(in: &next,
                affectedTargets: Self.supersedeTargets(in: items),
                additionalEvents: Self.events(in: items))
        } catch let error as ConversationValidationRejectionError {
            validationRejection = error.rejection
            throw ConversationError.invalidBinding
        }
        candidate.snapshotID = snapshotID
        candidate.highWater = highWater
        candidate.nextCursor = nextCursor
        candidate.receiptCursor = receiptCursor
        candidate.sourceOrder = keys
        candidate.hasInitialPage = true
        candidate.loadedKeys = Set(keys)
        candidate.freshKeys = Set(keys)
        candidate.receiptLastSequence = candidate.since
        candidate.checkpointEligible = false
        candidate.checkpointRequestStarted = false
        candidate.checkpointAccepted = false
        next.inboxCandidate = candidate
        try commit(next)
        refreshAcceptedReplayIndexes(for: keys)
    }

    /// Replaces the unsequenced, server-reported ordering view without moving
    /// the ordinary relay cursor. A failed view fetch clears only this cache.
    public func setInboxView(_ view: InboxView?,
                             context suppliedContext: ProfileContext) throws {
        try replaceInboxView(view, context: suppliedContext, fixture: false)
    }

    /// Installs a server-style ordering view in an in-memory local fixture.
    /// Relay profiles must use `setInboxView` with the fetched Server result.
    public func setFixtureInboxView(_ view: InboxView?,
                                    context suppliedContext: ProfileContext) throws {
        guard persistence is MemoryPendingActionPersistence else {
            throw AttentionStoreError.fixtureOnlyOperation
        }
        try replaceInboxView(view, context: suppliedContext, fixture: true)
    }

    private func replaceInboxView(_ view: InboxView?,
                                  context suppliedContext: ProfileContext,
                                  fixture: Bool) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == (fixture ? .fixture : .relay) else {
            throw AttentionStoreError.fixtureOnlyOperation
        }
        if let view {
            let keys = view.entries.map(\.key)
            guard Set(keys).count == keys.count,
                  keys.allSatisfy({ $0.accountScope == context.identity.personID }) else {
                throw AttentionStoreError.inboxPageConflict
            }
        }
        guard state.inboxView != view else { return }
        var next = state
        next.inboxView = view
        try commit(next)
    }

    public func saveInboxOlderPage(snapshotID: String,
                                   highWater: UInt64,
                                   cursor: String,
                                   items: [InboxSnapshotItem],
                                   nextCursor: String?,
                                   context suppliedContext: ProfileContext) throws {
        var validationRejection: ConversationValidationRejection?
        try saveInboxOlderPage(snapshotID: snapshotID, highWater: highWater, cursor: cursor,
            items: items, nextCursor: nextCursor, context: suppliedContext,
            validationRejection: &validationRejection)
    }

    public func saveInboxOlderPage(snapshotID: String,
                                   highWater: UInt64,
                                   cursor: String,
                                   items: [InboxSnapshotItem],
                                   nextCursor: String?,
                                   context suppliedContext: ProfileContext,
                                   validationRejection: inout ConversationValidationRejection?,
                                     restoredTurns: [UInt64: ConversationEvent] = [:],
                                     skippingHeldEvents: [UInt64: ConversationEvent] = [:],
                                     onHeldEventFailure: ((ConversationEvent, ConversationValidationRejection?) -> Void)? = nil) throws {
        validationRejection = nil
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var checkpoint = state.inboxCheckpoint,
              checkpoint.checkpointAccepted,
              checkpoint.snapshotID == snapshotID,
              checkpoint.highWater == highWater,
              checkpoint.hasInitialPage,
              checkpoint.nextCursor == cursor,
              items.count <= 20,
              (items.count > 0 || nextCursor == nil) else {
            throw AttentionStoreError.inboxPageConflict
        }
        let keys = items.map(\.key)
        guard Set(keys).count == keys.count,
              keys.allSatisfy({ $0.accountScope == context.identity.personID }),
              keys.allSatisfy({ !checkpoint.loadedKeys.contains($0) }),
              nextCursor != cursor else { throw AttentionStoreError.inboxPageConflict }
        var next = state
        do {
            for item in items {
                try applyInboxSnapshotItem(item, highWater: highWater, restoredTurns: restoredTurns,
                    skippingHeldEvents: skippingHeldEvents, onHeldEventFailure: onHeldEventFailure, to: &next)
            }
            Self.backfillSupersededByMessageKeys(in: &next,
                affectedTargets: Self.supersedeTargets(in: items),
                additionalEvents: Self.events(in: items))
        } catch let error as ConversationValidationRejectionError {
            validationRejection = error.rejection
            throw ConversationError.invalidBinding
        }
        let previousSourceOrder: [RequestKey]
        if let sourceOrder = checkpoint.sourceOrder {
            previousSourceOrder = sourceOrder
        } else {
            previousSourceOrder = checkpoint.loadedKeys.sorted { left, right in
                let leftOrder = state.requests[left]?.acceptanceOrder ??
                    state.remoteStates[left]?.eventSequence ?? state.inboxReferences?[left]?.eventSequence ?? 0
                let rightOrder = state.requests[right]?.acceptanceOrder ??
                    state.remoteStates[right]?.eventSequence ?? state.inboxReferences?[right]?.eventSequence ?? 0
                if leftOrder != rightOrder { return leftOrder > rightOrder }
                if left.senderID.rawValue != right.senderID.rawValue {
                    return left.senderID.rawValue < right.senderID.rawValue
                }
                return left.messageID.rawValue < right.messageID.rawValue
            }
        }
        checkpoint.sourceOrder = previousSourceOrder + keys
        checkpoint.loadedKeys.formUnion(keys)
        checkpoint.freshKeys = checkpoint.currentKeys.union(keys)
        checkpoint.nextCursor = nextCursor
        next.inboxCheckpoint = checkpoint
        dropAnswersInvalidatedBySnapshot(checkpoint, in: &next)
        try commit(next, allowingCommittedReads: true)
        refreshAcceptedReplayIndexes(for: keys)
    }

    public func appendInboxReceiptBatches(_ batches: [InboxReceiptBatch],
                                         context suppliedContext: ProfileContext) throws {
        guard !batches.isEmpty else { return }
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var candidate = state.inboxCandidate,
              candidate.hasInitialPage,
              !candidate.checkpointRequestStarted else { throw AttentionStoreError.inboxCheckpointPending }
        let existingIDs = Set(candidate.batches.flatMap(\.operationIDs))
        let newIDs = batches.flatMap(\.operationIDs)
        let inventoryIDs = Set(try inboxOperationInventory(context: suppliedContext).map(\.operationID))
        guard Set(newIDs).count == newIDs.count,
              Set(newIDs).isDisjoint(with: existingIDs),
              Set(newIDs).isSubset(of: inventoryIDs),
              Set(batches.map(\.batchID)).count == batches.count,
              batches.allSatisfy({ !$0.batchID.isEmpty && !$0.operationIDs.isEmpty && $0.results == nil }) else {
            throw AttentionStoreError.inboxCheckpointIncomplete
        }
        candidate.batches.append(contentsOf: batches)
        candidate.checkpointEligible = false
        var next = state
        next.inboxCandidate = candidate
        try commit(next)
    }

    public func saveInboxReceiptBatch(_ batchID: String,
                                      results: [InboxOperationReceipt],
                                      missingOperationIDs: [UUID] = [],
                                      context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var candidate = state.inboxCandidate,
              candidate.hasInitialPage,
              !candidate.checkpointRequestStarted,
              let index = candidate.batches.firstIndex(where: { $0.batchID == batchID }) else {
            throw AttentionStoreError.inboxCheckpointIncomplete
        }
        let batch = candidate.batches[index]
        let resultIDs = results.map(\.operationID)
        let resultIDSet = Set(resultIDs)
        let missingIDSet = Set(missingOperationIDs)
        let orderedResultIDs = batch.operationIDs.filter { resultIDSet.contains($0) }
        guard resultIDSet.count == resultIDs.count,
              missingIDSet.count == missingOperationIDs.count,
              resultIDSet.isDisjoint(with: missingIDSet),
              orderedResultIDs == resultIDs,
              resultIDSet.union(missingIDSet) == Set(batch.operationIDs),
              Set(batch.operationIDs).count == batch.operationIDs.count else {
            throw AttentionStoreError.inboxPageConflict
        }
        if let existing = batch.results {
            guard existing == results,
                  (batch.missingOperationIDs ?? []) == missingOperationIDs else {
                throw AttentionStoreError.inboxPageConflict
            }
            return
        }
        var next = state
        var touchedKeys = Set<RequestKey>()
        var refreshedKeys = Set<RequestKey>()
        for receipt in results {
            guard let submission = next.intents.values.first(where: { $0.operationID == receipt.operationID }) else {
                throw AttentionStoreError.inboxCheckpointIncomplete
            }
            touchedKeys.insert(submission.requestKey)
            switch receipt.status {
            case .committed:
                guard let result = receipt.result,
                      let sequence = Self.resultSequence(result),
                      let terminal = receipt.terminal,
                      case let .terminal(key, _, _) = terminal.body,
                      key == submission.requestKey,
                      terminal.sequence == sequence,
                      case let .bool(duplicate)? = result.uniqueValue(named: "duplicate") else {
                    throw AttentionStoreError.inboxPageConflict
                }
                if submission.isNoComment {
                    guard result.uniqueValue(named: "terminal_kind")?.stringValue?.rawValue == "no_comment",
                          case let .terminal(_, .noComment, _) = terminal.body,
                          terminal.accountAnswerOutcome == .noComment else {
                        throw AttentionStoreError.inboxPageConflict
                    }
                } else {
                    guard duplicate,
                          terminal.sequence <= (candidate.highWater ?? 0) else {
                        throw AttentionStoreError.inboxPageConflict
                    }
                }
                if case let .accepted(priorSequence) = submission.disposition {
                    guard priorSequence == sequence else { throw AttentionStoreError.inboxPageConflict }
                } else {
                    var accepted = submission
                    accepted.disposition = .accepted(sequence: sequence)
                    next.intents[submission.intentID] = accepted
                    next.outboxOrder.removeAll(where: { $0 == submission.intentID })
                    if var published = next.replayPublishedIntents {
                        published[submission.intentID] = accepted
                        next.replayPublishedIntents = published
                    }
                }
                try recordInboxTerminalProjection(terminal, into: &next)
                touchedKeys.insert(submission.requestKey)
                refreshedKeys.insert(submission.requestKey)
            case .operationConflict:
                guard receipt.result == nil, receipt.terminal == nil, receipt.reason == nil,
                      !Self.isAccepted(submission) else { throw AttentionStoreError.inboxPageConflict }
                Self.recordInboxOperationFailure(submission, in: &next)
            case .notCommittedAtSnapshot:
                guard receipt.result == nil, receipt.reason == nil,
                      !Self.isAccepted(submission) else {
                    throw AttentionStoreError.inboxPageConflict
                }
                if let terminal = receipt.terminal {
                    guard case let .terminal(key, _, _) = terminal.body,
                          key == submission.requestKey,
                          terminal.sequence <= (candidate.highWater ?? 0) else {
                        throw AttentionStoreError.inboxPageConflict
                    }
                    try recordInboxTerminalProjection(terminal, into: &next)
                    touchedKeys.insert(submission.requestKey)
                    refreshedKeys.insert(submission.requestKey)
                }
            case .refused:
                guard receipt.result == nil, receipt.terminal == nil,
                      let reason = receipt.reason,
                      InboxOperationRefusalReason(rawValue: reason) != nil,
                      !Self.isAccepted(submission) else {
                    throw AttentionStoreError.inboxPageConflict
                }
                Self.recordInboxOperationFailure(submission, in: &next)
            }
        }
        candidate.batches[index].results = results
        candidate.batches[index].missingOperationIDs = missingOperationIDs
        for operationID in missingOperationIDs {
            guard let submission = next.intents.values.first(where: { $0.operationID == operationID }) else {
                throw AttentionStoreError.inboxCheckpointIncomplete
            }
            touchedKeys.insert(submission.requestKey)
            switch submission.disposition {
            case .pending, .accepted, .lost:
                break
            default:
                throw AttentionStoreError.inboxPageConflict
            }
        }
        candidate.freshKeys = candidate.currentKeys.union(refreshedKeys)
        next.inboxCandidate = candidate
        try commit(next)
        refreshAcceptedReplayIndexes(for: touchedKeys)
    }

    public func saveInboxReceiptChunk(snapshotID: String,
                                      cursor: String,
                                      events: [RelayEvent],
                                      nextCursor: String?,
                                      context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var candidate = state.inboxCandidate,
              !candidate.checkpointRequestStarted,
              candidate.snapshotID == snapshotID,
              candidate.highWater != nil,
              candidate.receiptCursor == cursor,
              nextCursor != cursor,
              let highWater = candidate.highWater else { throw AttentionStoreError.inboxPageConflict }
        var priorSequence = candidate.receiptLastSequence ?? candidate.since
        var touchedKeys = Set<RequestKey>()
        var next = state
        for event in events {
            guard event.sequence > priorSequence, event.sequence <= highWater,
                  event.sequence > candidate.since else {
                throw AttentionStoreError.inboxPageConflict
            }
            switch event.body {
            case let .terminal(key, _, _):
                guard key.accountScope == context.identity.personID else { throw AttentionStoreError.wrongAccount }
                touchedKeys.insert(key)
                try recordInboxTerminalProjection(event, into: &next)
            default:
                throw AttentionStoreError.inboxPageConflict
            }
            priorSequence = event.sequence
        }
        if !events.isEmpty { candidate.receiptLastSequence = priorSequence }
        candidate.freshKeys = candidate.currentKeys.union(touchedKeys)
        candidate.receiptCursor = nextCursor
        next.inboxCandidate = candidate
        try commit(next)
        refreshAcceptedReplayIndexes(for: touchedKeys)
    }

    /// Durably freezes the exact manifest immediately before the distinct server checkpoint ACK.
    public func prepareInboxCheckpointAcknowledgement(context suppliedContext: ProfileContext) throws -> InboxPagingCheckpoint {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var candidate = state.inboxCandidate,
              candidate.hasInitialPage,
              candidate.snapshotID != nil,
              candidate.highWater != nil,
              candidate.receiptCursor == nil,
              candidate.batches.allSatisfy({ $0.results != nil }) else {
            throw AttentionStoreError.inboxCheckpointIncomplete
        }
        let operationIDs = candidate.batches.flatMap(\.operationIDs)
        let inventoryIDs = try inboxOperationInventory(context: suppliedContext).map(\.operationID)
        guard Set(operationIDs).count == operationIDs.count,
              Set(inventoryIDs).isSubset(of: Set(operationIDs)) else {
            throw AttentionStoreError.inboxCheckpointIncomplete
        }
        candidate.checkpointEligible = true
        candidate.checkpointRequestStarted = true
        var next = state
        next.inboxCandidate = candidate
        try commit(next)
        return candidate
    }

    /// This is the only local operation that promotes a checkpoint H to the event cursor.
    @discardableResult
    public func acceptInboxCheckpoint(snapshotID: String,
                                      highWater: UInt64,
                                      context suppliedContext: ProfileContext) throws -> UInt64 {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay,
              var candidate = state.inboxCandidate,
              candidate.checkpointEligible,
              candidate.checkpointRequestStarted,
              candidate.snapshotID == snapshotID,
              candidate.highWater == highWater,
              state.cursor == candidate.since else { throw AttentionStoreError.inboxCheckpointIncomplete }
        candidate.checkpointAccepted = true
        var next = state
        next.inboxCheckpoint = candidate
        dropAnswersInvalidatedBySnapshot(candidate, in: &next)
        next.inboxCandidate = nil
        next.cachedInboxCurrentKeys = nil
        next.cursor = highWater
        next.replayBarrier = nil
        next.replayPublishedRequests = nil
        next.replayPublishedStates = nil
        next.replayPublishedIntents = nil
        next.replayPublishedInboxCurrentKeys = nil
        try commit(next)
        return state.cursor
    }

    public func snapshot(context suppliedContext: ProfileContext) throws -> AttentionStoreSnapshot {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let publishedRequests = (state.replayPublishedRequests ?? state.requests).mapValues { original in
            effectiveRequest(for: original.key) ?? original
        }
        let visibleDrafts: [RequestKey: RequestDraft]
        let visibleSessions: [RequestKey: RequestSession]
        if state.replayPublishedRequests == nil {
            // Outside replay, these maps are already scoped to accepted requests.
            // A partial replay view is the only snapshot that needs to filter them.
            visibleDrafts = state.drafts
            visibleSessions = state.fixtureSessions
        } else {
            let visibleKeys = Set(publishedRequests.keys)
            visibleDrafts = state.drafts.filter { visibleKeys.contains($0.key) }
            visibleSessions = state.fixtureSessions.filter { visibleKeys.contains($0.key) }
        }
        let sortedOutbox = state.outboxOrder.compactMap { state.intents[$0] }
        var inboxCurrentKeys: Set<RequestKey>?
        if state.replayBarrier != nil {
            inboxCurrentKeys = state.replayPublishedInboxCurrentKeys
        } else if state.inboxCandidate != nil,
                  let checkpoint = state.inboxCheckpoint, checkpoint.checkpointAccepted {
            // A failed candidate remains durable for recovery. It must not erase
            // the last accepted current-message set while that recovery waits.
            inboxCurrentKeys = checkpoint.currentKeys
        } else if state.inboxCandidate != nil {
            // Before the first accepted snapshot, keep the messages actionable
            // until freshness is known instead of presenting them as dimmed.
            inboxCurrentKeys = nil
        } else if let checkpoint = state.inboxCheckpoint, checkpoint.checkpointAccepted {
            inboxCurrentKeys = checkpoint.currentKeys
        } else {
            inboxCurrentKeys = nil
        }
        if state.inboxCheckpoint == nil && state.inboxCandidate == nil {
            inboxCurrentKeys = state.cachedInboxCurrentKeys
        }
        let inboxSourceOrder = state.inboxCheckpoint.flatMap {
            $0.checkpointAccepted ? $0.sourceOrder : nil
        }
        return AttentionStoreSnapshot(requests: publishedRequests,
                                      drafts: visibleDrafts,
                                      intents: state.replayPublishedIntents ?? state.intents,
                                      outbox: sortedOutbox,
                                      remoteStates: state.replayPublishedStates ?? state.remoteStates,
                                      fixtureSessions: visibleSessions,
                                      revision: state.revision,
                                      cursor: state.cursor,
                                      replayBarrier: state.replayBarrier,
                                      repairIssues: state.repairIssues,
                                      conversationThreads: state.conversation?.threads ?? [:],
                                      inboxCheckpoint: state.inboxCheckpoint,
                                      inboxCandidate: state.inboxCandidate,
                                      inboxSourceOrder: inboxSourceOrder,
                                      inboxView: state.inboxView,
                                      inboxCurrentKeys: inboxCurrentKeys,
                                      pendingRelayOverlays: state.pendingRelayOverlays ?? [:],
                                      inboxReferences: state.inboxReferences ?? [:],
                                      pendingMessageOpens: state.pendingMessageOpens ?? [])
    }

    /// Returns only the contiguous relay cursor after validating the profile.
    /// Unlike `snapshot(context:)`, this does not project retained presentation history.
    public func relayCursor(context suppliedContext: ProfileContext) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else {
            throw AttentionStoreError.fixtureOnlyOperation
        }
        return state.cursor
    }

    /// Checks that a caller still owns the active profile without materializing
    /// the retained request, draft, fixture, conversation, or outbox projections.
    public func validateContext(context suppliedContext: ProfileContext) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
    }

    /// Returns only accepted original operations whose exact terminal sequence
    /// has not yet been observed. The store builds this small index at load and
    /// updates it with the same durable mutations that accept or replay events.
    public func acceptedOperationsAwaitingTerminalReplay(context suppliedContext: ProfileContext) throws -> [Submission] {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        return acceptedAwaitingTerminalReplay.values.sorted {
            $0.operationID.uuidString < $1.operationID.uuidString
        }
    }

    public func conversationSnapshot(context suppliedContext: ProfileContext) throws -> ConversationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let conversation = state.conversation ?? ConversationState()
        let pending = (conversation.pendingChatReadPositions ?? [:]).values.sorted {
            if $0.request.senderID != $1.request.senderID {
                return $0.request.senderID.rawValue < $1.request.senderID.rawValue
            }
            return $0.request.messageID.rawValue < $1.request.messageID.rawValue
        }
        return ConversationSnapshot(cursor: conversation.cursor, threads: conversation.threads,
            chatReadPositions: conversation.chatReadPositions,
            chatReadPositionSupport: conversation.chatReadPositionSupport,
            pendingChatReadPositions: pending)
    }

    /// Re-validates an already-accounted redacted revision without applying or
    /// persisting it. Replay may ignore it only when the normal profile/request
    /// checks pass and the exact redacted-revision guard still rejects it.
    public func redactedRevisionRejectionForAccountedRedelivery(
        _ event: ConversationEvent,
        context suppliedContext: ProfileContext
    ) throws -> ConversationValidationRejection? {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else {
            throw AttentionStoreError.fixtureOnlyOperation
        }
        try validate(event.binding.request, in: context.identity)
        guard case let .redactedRevision(turn) = event.fact else { return nil }
        try validateConversationFiles(turn.files)
        let conversation = state.conversation ?? ConversationState()
        return try conversation.redactedRevisionRejectionForAccountedRedelivery(event)
    }

    /// Restores only a missing receipt target from authenticated conversation
    /// history. The receipt is retried through normal application afterwards.
    public func restoreReferencedConversationTurn(_ event: ConversationEvent,
                                                 for receipt: ConversationEvent,
                                                 origin: ExactText? = nil,
                                                 context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else {
            throw AttentionStoreError.fixtureOnlyOperation
        }
        try validate(event.binding.request, in: context.identity)
        try validate(receipt.binding.request, in: context.identity)
        let event = try Self.externalizingConversationFiles(in: event,
            using: conversationFileReferences,
            allowInlinePersistence: persistence is MemoryPendingActionPersistence)
        guard case let .turn(turn) = event.fact else { throw ConversationError.conflict }
        try validateConversationFiles(turn.files)
        var next = state
        var conversation = next.conversation ?? ConversationState()
        let savedOrigin = next.remoteStates[event.binding.request]?.attentionTierOrigin ??
            next.inboxReferences?[event.binding.request]?.attentionTierOrigin
        do {
            try conversation.restoreReferencedTurn(event, for: receipt,
                sameOriginFeed: origin != nil && origin == savedOrigin)
        } catch is ConversationValidationRejectionError {
            throw ConversationError.invalidBinding
        }
        guard conversation != next.conversation else { return }
        next.conversation = conversation
        try commit(next)
    }

    /// The conversation cursor commits in the same account transaction as its fact.
    /// Neither it nor its ACK can advance ordinary delivery/lifecycle replay.
    @discardableResult
    public func applyConversation(_ event: ConversationEvent,
                                 context suppliedContext: ProfileContext,
                                 locallyReceivedAtMilliseconds: UInt64? = nil) throws -> UInt64 {
        var validationRejection: ConversationValidationRejection?
        return try applyConversation(event, context: suppliedContext,
            validationRejection: &validationRejection,
            locallyReceivedAtMilliseconds: locallyReceivedAtMilliseconds)
    }

    /// The optional output reports which unchanged validation guard rejected
    /// an event; callers still receive the same ConversationError.
    @discardableResult
    public func applyConversation(_ event: ConversationEvent,
                                  context suppliedContext: ProfileContext,
                                  validationRejection: inout ConversationValidationRejection?,
                                  locallyReceivedAtMilliseconds: UInt64? = nil) throws -> UInt64 {
        validationRejection = nil
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let event = try Self.externalizingConversationFiles(in: event,
            using: conversationFileReferences,
            allowInlinePersistence: persistence is MemoryPendingActionPersistence)
        try validate(event.binding.request, in: context.identity)
        switch event.fact {
        case let .turn(turn), let .revision(turn, _), let .redactedRevision(turn): try validateConversationFiles(turn.files)
        default: break
        }
        var next = state
        var conversation = next.conversation ?? ConversationState()
        do {
            try conversation.apply(event)
        } catch let error as ConversationValidationRejectionError {
            validationRejection = error.rejection
            throw ConversationError.invalidBinding
        }
        if let locallyReceivedAtMilliseconds,
           case let .turn(turn) = event.fact,
           turn.kind == .reply, turn.author == .origin,
           var thread = conversation.threads[event.binding.request] {
            var facts = thread.facts[turn.id] ?? ConversationTurnFacts()
            if facts.localLiveArrivalAtMilliseconds == nil {
                facts.localLiveArrivalAtMilliseconds = locallyReceivedAtMilliseconds
                thread.facts[turn.id] = facts
                conversation.threads[event.binding.request] = thread
            }
        }
        let key = event.binding.request
        if case let .attentionTier(_, origin, tier, sessionHandle) = event.fact {
            if let sessionHandle { conversation.threads[key]?.sessionHandle = sessionHandle }
            let hasRequest = next.requests[key] != nil
            var remote: RemoteRequestState
            if hasRequest {
                remote = next.remoteStates[key] ?? RemoteRequestState()
            } else {
                var references = next.inboxReferences ?? [:]
                remote = references.removeValue(forKey: key) ??
                    next.remoteStates.removeValue(forKey: key) ?? RemoteRequestState()
                next.inboxReferences = references
            }
            try updateAttentionTier(tier, sequence: event.sequence, feed: .conversation,
                                    origin: origin, in: &remote)
            if hasRequest {
                next.remoteStates[key] = remote
            } else {
                var references = next.inboxReferences ?? [:]
                references[key] = remote
                next.inboxReferences = references
            }
        }
        if let previous = state.conversation?.threads[key],
           let current = conversation.threads[key], current.currentRevision != previous.currentRevision {
            var archived = previous.answerDrafts ?? [:]
            if let draft = state.drafts[key] { archived[previous.currentRevision] = draft }
            conversation.threads[key]?.answerDrafts = archived
            if next.requests[key] != nil {
                let freshRequest = StoredRequest(key: key, originalPayload: current.currentQuestionPayload)
                let fresh = RequestDraft(interface: requestInterface(for: freshRequest, in: conversation))
                next.drafts[key] = fresh
                if var fixture = next.fixtureSessions[key], case .open = fixture.lifecycle {
                    fixture.draft = fresh
                    next.fixtureSessions[key] = fixture
                }
            }
            if current.terminal == nil, let id = next.intentByRequest[key], var intent = next.intents[id] {
                // An authoritative newer open question proves an earlier final answer did not close it.
                intent.disposition = .lost
                next.intents[id] = intent
                next.intentByRequest.removeValue(forKey: key)
                next.outboxOrder.removeAll { $0 == id }
            }
        }
        if case let .terminal(_, _, terminal) = event.fact, next.requests[key] != nil {
            let previous = next.remoteStates[key] ?? RemoteRequestState()
            var updated = previous
            updated.state = terminal
            next.remoteStates[key] = updated
            next.outboxOrder.removeAll { next.intents[$0]?.requestKey == key }
        }
        if case let .retraction(_, sequence) = event.fact, next.requests[key] != nil {
            // This projection references the one ordinary terminal. It closes
            // action locally without advancing or fabricating its ordinary cursor.
            let previous = next.remoteStates[key] ?? RemoteRequestState()
            var updated = previous
            updated.state = .cleared
            updated.eventSequence = sequence
            next.remoteStates[key] = updated
            if let saved = next.drafts[key], let revision = conversation.threads[key]?.currentRevision {
                var archived = conversation.threads[key]?.answerDrafts ?? [:]
                archived[revision] = saved
                conversation.threads[key]?.answerDrafts = archived
            }
            if let id = next.intentByRequest[key], var intent = next.intents[id] {
                if preservesOperationResult(intent.disposition) {
                    // Keep the exact answer receipt that predates this conversation fact.
                } else {
                    intent.disposition = .terminal(state: .cleared, sequence: sequence,
                        authorizedAnswer: previous.authorizedOriginAnswer)
                    next.intents[id] = intent
                }
            }
            next.outboxOrder.removeAll { next.intents[$0]?.requestKey == key }
        }
        next.conversation = conversation
        if next.remoteStates[key]?.isTerminal == true {
            dropUnsentAnswer(for: key, in: &next)
        } else {
            refreshEditableDraft(for: key, in: &next)
        }
        try commit(next, allowingCommittedReads: true)
        return conversation.cursor
    }

    /// Retains the receive time from a live reply frame when replay already
    /// committed that reply before the frame's wake was processed.
    /// Returns false while replay has not reached the signaled sequence yet.
    @discardableResult
    public func recordLocalLiveReplyArrival(request: RequestKey,
                                            turnID: ExactText,
                                            conversationSequence: UInt64,
                                            receivedAtMilliseconds: UInt64,
                                            context suppliedContext: ProfileContext) throws -> Bool {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        try validate(request, in: context.identity)

        guard var conversation = state.conversation,
              conversation.cursor >= conversationSequence else { return false }
        guard var thread = conversation.threads[request],
              let turn = thread.turns.first(where: { $0.id == turnID }),
              turn.kind == .reply, turn.author == .origin,
              turn.conversationSequence == conversationSequence else { return true }

        var facts = thread.facts[turnID] ?? ConversationTurnFacts()
        guard facts.localLiveArrivalAtMilliseconds == nil else { return true }
        facts.localLiveArrivalAtMilliseconds = receivedAtMilliseconds
        thread.facts[turnID] = facts
        conversation.threads[request] = thread
        var next = state
        next.conversation = conversation
        try commit(next)
        return true
    }

    /// Persists the conversation sequence for an ignored, well-formed update
    /// so replay can continue without creating an artificial request thread.
    @discardableResult
    public func advanceConversationCursor(overIgnoredUpdateAt sequence: UInt64,
                                          context suppliedContext: ProfileContext) throws -> UInt64 {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        var conversation = state.conversation ?? ConversationState()
        if sequence <= conversation.cursor { return conversation.cursor }
        guard conversation.cursor < UInt64.max, sequence == conversation.cursor + 1 else {
            let expected = conversation.cursor == UInt64.max ? UInt64.max : conversation.cursor + 1
            throw ConversationError.gap(expected: expected, received: sequence)
        }
        conversation.cursor = sequence
        var next = state
        next.conversation = conversation
        try commit(next)
        return state.conversation?.cursor ?? 0
    }

    public func finishConversationReplay(at highWater: UInt64, context suppliedContext: ProfileContext) throws {
        try finishConversationReplay(at: highWater, chatReadPositions: nil, context: suppliedContext)
    }

    public func finishConversationReplay(at highWater: UInt64,
                                         chatReadPositions: [AccountConversationReadPosition]?,
                                         context suppliedContext: ProfileContext) throws {
        var validationRejection: ConversationValidationRejection?
        try finishConversationReplay(at: highWater, chatReadPositions: chatReadPositions,
            context: suppliedContext, validationRejection: &validationRejection)
    }

    public func finishConversationReplay(at highWater: UInt64,
                                         chatReadPositions: [AccountConversationReadPosition]?,
                                         context suppliedContext: ProfileContext,
                                         validationRejection: inout ConversationValidationRejection?) throws {
        validationRejection = nil
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let actual = state.conversation?.cursor ?? 0
        guard highWater == actual else {
            throw AttentionStoreError.replayIncomplete(expected: highWater, actual: actual)
        }
        for position in chatReadPositions ?? [] {
            guard position.request.accountScope == context.identity.personID,
                  position.readThroughConversationSequence > 0 else {
                throw AttentionStoreError.wrongAccount
            }
        }
        var conversation = state.conversation ?? ConversationState()
        do {
            try conversation.mergeChatReadPositions(chatReadPositions)
        } catch let error as ConversationValidationRejectionError {
            validationRejection = error.rejection
            throw ConversationError.invalidBinding
        }
        guard conversation != (state.conversation ?? ConversationState()) else { return }
        var next = state
        next.conversation = conversation
        try commit(next)
    }

    private func preservesOperationResult(_ disposition: IntentDisposition) -> Bool {
        switch disposition {
        case .accepted, .refusedByRetraction, .staleRevision: true
        default: false
        }
    }

    public func saveConversationDraft(_ draft: ConversationDraft, context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let draft = try Self.externalizingConversationFiles(in: draft,
            using: conversationFileReferences,
            allowInlinePersistence: persistence is MemoryPendingActionPersistence)
        try validate(draft.binding.request, in: context.identity)
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[draft.binding.request],
              thread.revisions[draft.binding.revision] != nil else { throw ConversationError.missingRequest }
        // Saving user input does not send it or make cached closure authoritative.
        // Delivery still validates the current server projection separately.
        guard context.transportMode == .relay || thread.allowsDiscussion else { throw ConversationError.closed }
        if let previous = thread.drafts[draft.binding.revision] {
            switch previous.disposition {
            case .submitting, .outcomeUnknown, .acceptedPendingReplay: throw ConversationError.pendingSubmission
            default: break
            }
        }
        guard case .saved = draft.disposition else { throw ConversationError.invalidBinding }
        try validateConversationFiles(draft.files)
        thread.drafts[draft.binding.revision] = draft
        conversation.threads[draft.binding.request] = thread
        next.conversation = conversation
        try commit(next)
    }

    /// Updates only the text of an existing draft. Its files were normalized
    /// when they entered the store, so editing text must not walk them again.
    @discardableResult
    public func updateConversationDraftText(_ text: ExactText, for binding: ConversationBinding,
                                           context suppliedContext: ProfileContext) throws -> ConversationDraft {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        try validate(binding.request, in: context.identity)
        var next = state
        guard var conversation = next.conversation,
              var thread = conversation.threads[binding.request],
              thread.revisions[binding.revision] != nil else { throw ConversationError.missingRequest }
        // Saving user input does not send it or make cached closure authoritative.
        // Delivery still validates the current server projection separately.
        guard context.transportMode == .relay || thread.allowsDiscussion else { throw ConversationError.closed }
        var draft = thread.drafts[binding.revision] ?? ConversationDraft(binding: binding)
        guard draft.binding == binding else { throw ConversationError.invalidBinding }
        switch draft.disposition {
        case .submitting, .outcomeUnknown, .acceptedPendingReplay:
            throw ConversationError.pendingSubmission
        case .saved, .rejected:
            break
        }
        draft.text = text
        draft.disposition = .saved
        thread.drafts[binding.revision] = draft
        conversation.threads[binding.request] = thread
        next.conversation = conversation
        try commit(next)
        return draft
    }

    /// Records that Chat has shown the request's latest agent reply.
    @discardableResult
    public func markConversationRead(_ request: RequestKey,
                                     context suppliedContext: ProfileContext) throws -> PendingConversationReadPosition? {
        try markConversationReadUpdate(request, through: nil, context: suppliedContext).pendingPosition
    }

    /// Records that Chat has shown a specific reply, without advancing beyond it.
    @discardableResult
    public func markConversationRead(_ request: RequestKey,
                                     through turnID: ExactText,
                                     context suppliedContext: ProfileContext) throws -> PendingConversationReadPosition? {
        try markConversationReadUpdate(request, through: turnID, context: suppliedContext).pendingPosition
    }

    /// Marks a specific visible reply read and returns its updated local thread
    /// and commit revision for efficient client projection refresh.
    public func markConversationReadAndProject(_ request: RequestKey,
                                               through turnID: ExactText,
                                               context suppliedContext: ProfileContext) throws -> ConversationReadUpdate {
        try markConversationReadUpdate(request, through: turnID, context: suppliedContext)
    }

    private func markConversationReadUpdate(_ request: RequestKey,
                                            through requestedTurnID: ExactText?,
                                            context suppliedContext: ProfileContext) throws -> ConversationReadUpdate {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        try validate(request, in: context.identity)
        let previousRevision = state.revision
        var next = state
        guard var conversation = next.conversation,
              let thread = conversation.threads[request] else { throw ConversationError.missingRequest }
        let turn: ConversationTurn?
        if let requestedTurnID {
            turn = thread.turns.first {
                $0.id == requestedTurnID && $0.kind == .reply && $0.author != .person
            }
        } else {
            turn = thread.latestAgentReply
        }
        guard let turn else {
            return ConversationReadUpdate(pendingPosition: nil, thread: thread,
                previousRevision: previousRevision, revision: state.revision, didCommit: false)
        }

        let pending = conversation.prepareReadPosition(for: request, operationID: UUID(),
            position: turn.conversationSequence ?? 0)
        if conversation == (state.conversation ?? ConversationState()) {
            return ConversationReadUpdate(pendingPosition: pending,
                thread: conversation.threads[request], previousRevision: previousRevision,
                revision: state.revision, didCommit: false)
        }
        next.conversation = conversation
        try commit(next)
        return ConversationReadUpdate(pendingPosition: pending,
            thread: state.conversation?.threads[request], previousRevision: previousRevision,
            revision: state.revision, didCommit: true)
    }

    public func acceptConversationReadPosition(_ pending: PendingConversationReadPosition,
                                               serverPosition: UInt64,
                                               context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        try validate(pending.request, in: context.identity)
        var next = state
        guard var conversation = next.conversation else { throw ConversationError.missingRequest }
        try conversation.acceptReadPosition(pending, serverPosition: serverPosition)
        next.conversation = conversation
        try commit(next)
    }

    public func appendFixtureDiscussion(_ binding: ConversationBinding, context suppliedContext: ProfileContext,
                                        simulatedAcceptanceObservedAtMilliseconds: UInt64? = nil) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        var next = state
        guard var conversation = next.conversation, let thread = conversation.threads[binding.request],
              let draft = thread.drafts[binding.revision] else { throw ConversationError.missingRequest }
        guard thread.allowsDiscussion else { throw ConversationError.closed }
        guard !draft.text.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.files.isEmpty else {
            throw ConversationError.emptyDraft
        }
        let turn = ConversationTurn(id: ExactText(UUID().uuidString.lowercased()), binding: binding,
            author: .person, sessionHandle: thread.sessionHandle, text: draft.text, files: draft.files)
        try conversation.apply(ConversationEvent(sequence: conversation.cursor + 1, binding: binding, fact: .turn(turn)))
        if let simulatedAcceptanceObservedAtMilliseconds,
           var acceptedThread = conversation.threads[binding.request] {
            acceptedThread.facts[turn.id, default: ConversationTurnFacts()].acceptedAtMilliseconds =
                simulatedAcceptanceObservedAtMilliseconds
            conversation.threads[binding.request] = acceptedThread
        }
        conversation.threads[binding.request]?.drafts.removeValue(forKey: binding.revision)
        next.conversation = conversation
        try commit(next)
    }

    /// A typed local upload example, with no delivery operation or transport.
    public func stageFixtureConversationUpload(_ file: ConversationFile, binding: ConversationBinding,
        text: ExactText, context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        let file = try Self.externalizingConversationFiles(in: file,
            using: conversationFileReferences,
            allowInlinePersistence: persistence is MemoryPendingActionPersistence)
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[binding.request],
              thread.revisions[binding.revision] != nil else { throw ConversationError.missingRequest }
        try validateConversationFiles([file])
        let operation = UUID()
        let uploaded = ConversationFile(id: file.id, name: file.name, byteCount: file.byteCount,
            sha256: file.sha256, content: .uploaded(ExactText(UUID().uuidString.lowercased())))
        thread.drafts[binding.revision] = ConversationDraft(binding: binding, text: text, files: [file],
            disposition: .rejected(ExactText("Local example · upload not submitted")))
        let group = ConversationUploadGroup(operationID: operation, binding: binding,
            originals: [file], uploaded: [uploaded], cleanupID: nil)
        thread.uploadGroups = (thread.uploadGroups ?? [:]).merging([operation: group]) { _, new in new }
        conversation.threads[binding.request] = thread
        next.conversation = conversation
        try commit(next)
    }

    /// Freeze a durable operation before transport. Local examples may edit drafts,
    /// but cannot enter this submission path or acquire a delivery operation.
    public func prepareDiscussion(_ binding: ConversationBinding, context suppliedContext: ProfileContext) throws -> UUID {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[binding.request],
              var draft = thread.drafts[binding.revision] else { throw ConversationError.missingRequest }
        guard thread.allowsDiscussion else { throw ConversationError.closed }
        guard !draft.text.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.files.isEmpty else {
            throw ConversationError.emptyDraft
        }
        guard !(thread.uploadCleanups ?? [:]).values.contains(where: {
            guard $0.binding == binding else { return false }
            if case .acknowledged = $0.outcome { return false }; return true
        }) else { throw ConversationError.pendingSubmission }
        let unready = Set((thread.uploadGroups ?? [:]).values.filter { $0.cleanupID != nil }
            .flatMap { $0.originals.map(\.id) })
        guard !draft.files.contains(where: { unready.contains($0.id) }) else { throw ConversationError.pendingSubmission }
        let operation: UUID
        switch draft.disposition {
        case let .submitting(id), let .outcomeUnknown(id), let .acceptedPendingReplay(id, _):
            guard thread.uploadGroups?[id]?.cleanupID == nil else { throw ConversationError.pendingSubmission }
            operation = id
        case .saved, .rejected:
            operation = UUID()
            draft.disposition = .submitting(operation)
        }
        // Register planned upload-tier files before awaiting limits or disk/HTTP.
        // Departure during that preparation must fence this original operation too.
        let tiers = try ConversationFileLimits(inlineDecodedBytes: 262_144, uploadCap: nil).tiers(for: draft.files)
        let uploads = zip(draft.files, tiers).filter { $0.1 == .upload }.map { $0.0 }
        if !uploads.isEmpty, thread.uploadGroups?[operation] == nil {
            let group = ConversationUploadGroup(operationID: operation, binding: binding,
                originals: uploads, uploaded: [], cleanupID: nil)
            thread.uploadGroups = (thread.uploadGroups ?? [:]).merging([operation: group]) { _, new in new }
        }
        thread.drafts[binding.revision] = draft
        conversation.threads[binding.request] = thread
        next.conversation = conversation
        try commit(next)
        return operation
    }

    /// Called before starting an upload, not after its response: navigation may
    /// happen while the transfer is suspended or its result is unknown.
    public func registerConversationUpload(_ file: ConversationFile, binding: ConversationBinding,
        operation: UUID, context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[binding.request],
              let draft = thread.drafts[binding.revision] else { throw ConversationError.missingRequest }
        switch draft.disposition {
        case let .submitting(id), let .outcomeUnknown(id):
            guard id == operation else { throw ConversationError.conflict }
        default: throw ConversationError.pendingSubmission
        }
        guard draft.files.contains(file) else { throw ConversationError.fileMismatch }
        var group = thread.uploadGroups?[operation] ?? ConversationUploadGroup(operationID: operation,
            binding: binding, originals: [], uploaded: [], cleanupID: nil)
        guard group.binding == binding, group.cleanupID == nil else { throw ConversationError.pendingSubmission }
        if !group.originals.contains(file) { group.originals.append(file) }
        thread.uploadGroups = (thread.uploadGroups ?? [:]).merging([operation: group]) { _, new in new }
        conversation.threads[binding.request] = thread
        next.conversation = conversation
        try commit(next)
    }

    public func recordConversationUpload(_ file: ConversationFile, binding: ConversationBinding,
        operation: UUID, context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[binding.request],
              var group = thread.uploadGroups?[operation], group.binding == binding,
              let original = group.originals.first(where: { $0.id == file.id }),
              original.name == file.name, original.byteCount == file.byteCount,
              original.sha256 == file.sha256, case .uploaded = file.content else { throw ConversationError.fileMismatch }
        if let prior = group.uploaded.first(where: { $0.id == file.id }), prior != file { throw ConversationError.conflict }
        if !group.uploaded.contains(file) { group.uploaded.append(file) }
        thread.uploadGroups?[operation] = group
        conversation.threads[binding.request] = thread
        next.conversation = conversation
        try commit(next)
        // Retain the actual returned reference, but never promote an abandoned
        // transfer to readiness or continue its submission.
        guard group.cleanupID == nil else { throw ConversationError.pendingSubmission }
    }

    /// Explicit navigation only. Neither replay nor connection lifecycle calls
    /// this mutation. Each revision gets one stable cleanup command across all
    /// its uncommitted upload groups; retries preserve that command identity.
    public func abandonConversationUploads(for request: RequestKey,
        context suppliedContext: ProfileContext) throws -> [ConversationUploadCleanup] {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[request] else { return [] }
        let committed = Set(thread.turns.compactMap(\.operationID))
        let groups = (thread.uploadGroups ?? [:]).values.filter { $0.cleanupID == nil && !committed.contains($0.operationID) }
        guard !groups.isEmpty else {
            return (thread.uploadCleanups ?? [:]).values.filter {
                if case .acknowledged = $0.outcome { return false }; return true
            }
        }
        for revision in Set(groups.map { $0.binding.revision }) {
            let operations = groups.filter { $0.binding.revision == revision }.map(\.operationID)
                .sorted { $0.uuidString < $1.uuidString }
            let cleanup = ConversationUploadCleanup(id: UUID(), binding: ConversationBinding(request: request, revision: revision),
                uploadOperations: operations, outcome: .pending)
            thread.uploadCleanups = (thread.uploadCleanups ?? [:]).merging([cleanup.id: cleanup]) { _, new in new }
            for operation in operations { thread.uploadGroups?[operation]?.cleanupID = cleanup.id }
        }
        conversation.threads[request] = thread
        next.conversation = conversation
        try commit(next)
        return (thread.uploadCleanups ?? [:]).values.filter {
            if case .acknowledged = $0.outcome { return false }; return true
        }
    }

    public func recordConversationCleanup(_ id: UUID, request: RequestKey,
        outcome: ConversationUploadCleanup.Outcome, context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[request],
              var cleanup = thread.uploadCleanups?[id] else { throw ConversationError.missingRequest }
        // A late failure must not undo an already acknowledged cleanup.
        if case .acknowledged = cleanup.outcome { return }
        cleanup.outcome = outcome
        thread.uploadCleanups?[id] = cleanup
        if case .acknowledged = outcome { thread.settleAbandonedDraft(revision: cleanup.binding.revision) }
        conversation.threads[request] = thread
        next.conversation = conversation
        try commit(next)
    }

    public func markDiscussionOutcome(_ binding: ConversationBinding, operation: UUID,
                                      rejection: ExactText?, context suppliedContext: ProfileContext) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[binding.request],
              var draft = thread.drafts[binding.revision] else { throw ConversationError.missingRequest }
        switch draft.disposition {
        case let .submitting(savedID) where savedID == operation,
             let .outcomeUnknown(savedID) where savedID == operation: break
        default: throw ConversationError.conflict
        }
        // Rejection and unknown outcomes retain text, selected files and addressed revision.
        draft.disposition = rejection.map { .rejected($0) } ?? .outcomeUnknown(operation)
        thread.drafts[binding.revision] = draft
        thread.settleAbandonedDraft(revision: binding.revision)
        conversation.threads[binding.request] = thread
        next.conversation = conversation
        try commit(next)
    }

    public func markDiscussionAccepted(_ binding: ConversationBinding, operation: UUID, turn: ExactText,
                                        context suppliedContext: ProfileContext,
                                        acceptanceObservedAtMilliseconds: UInt64? = nil) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .relay, !turn.rawValue.isEmpty else { throw ConversationError.invalidBinding }
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[binding.request],
              var draft = thread.drafts[binding.revision] else { throw ConversationError.missingRequest }
        switch draft.disposition {
        case let .submitting(id), let .outcomeUnknown(id):
            guard id == operation else { throw ConversationError.conflict }
        case let .acceptedPendingReplay(id, priorTurn):
            guard id == operation, priorTurn == turn else { throw ConversationError.conflict }
        default: throw ConversationError.conflict
        }
        var facts = thread.facts[turn] ?? ConversationTurnFacts()
        if facts.acceptedAtMilliseconds == nil {
            let observedAt = acceptanceObservedAtMilliseconds ??
                UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
            facts.acceptedAtMilliseconds = observedAt
        }
        thread.facts[turn] = facts
        draft.disposition = .acceptedPendingReplay(operation: operation, turn: turn)
        thread.drafts[binding.revision] = draft
        conversation.threads[binding.request] = thread
        next.conversation = conversation
        try commit(next)
    }

    private func validateConversationFiles(_ files: [ConversationFile]) throws {
        guard Set(files.map(\.id)).count == files.count else { throw ConversationError.fileMismatch }
        for file in files {
            guard !file.id.rawValue.isEmpty, !file.name.rawValue.isEmpty else { throw ConversationError.fileMismatch }
            if case let .inline(bytes) = file.content {
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard UInt64(bytes.count) == file.byteCount, digest == file.sha256.rawValue else {
                    throw ConversationError.fileMismatch
                }
            }
        }
    }

    public func revisions(context suppliedContext: ProfileContext,
                          after _: UInt64) throws -> AsyncStream<UInt64> {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            changeObservers[id] = continuation
            continuation.yield(state.revision)
            continuation.onTermination = { [weak self] _ in
                self?.removeObserver(id)
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        changeObservers.removeValue(forKey: id)
    }

    private func firstDeliverySequence(for requestKey: RequestKey,
                                       in events: [UInt64: RelayEvent]) -> UInt64? {
        events.compactMap { sequence, event in
            guard case let .delivery(request, _) = event.body,
                  request.key == requestKey else { return nil }
            return sequence
        }.min()
    }

    private func storeAnswerDraft(_ draft: RequestDraft,
                                  for request: RequestKey,
                                  revision: UInt64,
                                  in proposedState: inout ClientSessionState) {
        guard var conversation = proposedState.conversation,
              var thread = conversation.threads[request] else {
            proposedState.drafts[request] = draft
            return
        }
        if thread.currentRevision == revision {
            proposedState.drafts[request] = draft
        } else {
            var drafts = thread.answerDrafts ?? [:]
            drafts[revision] = draft
            thread.answerDrafts = drafts
            conversation.threads[request] = thread
            proposedState.conversation = conversation
        }
    }

    private func discardAnswerDraft(for request: RequestKey,
                                     revision: UInt64,
                                     in proposedState: inout ClientSessionState) {
        guard var conversation = proposedState.conversation,
              var thread = conversation.threads[request] else {
            proposedState.drafts.removeValue(forKey: request)
            return
        }
        var drafts = thread.answerDrafts ?? [:]
        drafts.removeValue(forKey: revision)
        thread.answerDrafts = drafts.isEmpty ? nil : drafts
        if thread.currentRevision == revision {
            proposedState.drafts.removeValue(forKey: request)
        }
        // The active revision's draft is stored separately in `drafts`;
        // older revisions live in the thread's archived answer drafts.
        conversation.threads[request] = thread
        proposedState.conversation = conversation
    }

    private func boundRequest(_ selector: BoundDocumentSelector,
                              context suppliedContext: ProfileContext) throws -> StoredRequest {
        guard selector.request.accountScope == context.identity.personID,
              let id = UUID(uuidString: selector.opaqueDocumentID.rawValue),
              let binding = selectorBindings[id],
              binding.profileGeneration == context.generation,
              binding.requestKey == selector.request,
              binding.requestRevision == selector.requestRevision,
              binding.opaqueSubmissionID == selector.opaqueSubmissionID else {
            throw AttentionStoreError.selectorExpired
        }
        if let thread = state.conversation?.threads[selector.request] {
            guard selector.requestRevision == thread.currentRevision,
                  thread.redactedRevisions?.contains(selector.requestRevision) != true,
                  let payload = thread.revisions[selector.requestRevision],
                  let acceptanceOrder = state.requests[selector.request]?.acceptanceOrder else {
                throw AttentionStoreError.selectorExpired
            }
            let request = StoredRequest(key: selector.request, originalPayload: payload)
                .assigningAcceptanceOrder(acceptanceOrder)
            let descriptor = fingerprint(request.answerDescription?.canonicalJSON ?? "")
            guard descriptor == binding.descriptorFingerprint,
                  fingerprint(submissionSignature(for: requestInterface(for: request))) == binding.submissionFingerprint else {
                throw AttentionStoreError.selectorExpired
            }
            return request
        }
        guard selector.requestRevision == 1,
              let request = state.requests[selector.request] else { throw AttentionStoreError.requestMissing }
        let currentFingerprint = fingerprint(request.answerDescription?.canonicalJSON ?? "")
        guard currentFingerprint == binding.descriptorFingerprint,
              fingerprint(submissionSignature(for: requestInterface(for: request))) == binding.submissionFingerprint else {
            throw AttentionStoreError.selectorExpired
        }
        return request
    }

    private func requestInterface(for request: StoredRequest) -> RequestInterface {
        requestInterface(for: request, in: state.conversation)
    }

    private func requestInterface(for request: StoredRequest,
                                  in conversation: ConversationState?) -> RequestInterface {
        request.interface(deliveredFileNames: Self.deliveredFileNames(for: request.key, in: conversation))
    }

    private static func deliveredFileNames(for request: RequestKey,
                                           in conversation: ConversationState?) -> Set<ExactText> {
        guard let thread = conversation?.threads[request] else { return [] }
        return Set(thread.turns
            .filter { $0.author == .origin && $0.kind == .revision && $0.binding.revision == 1 }
            .flatMap(\.files)
            .map(\.name))
    }

    private func effectiveRequest(for key: RequestKey) -> StoredRequest? {
        guard let original = state.requests[key] else { return nil }
        guard let thread = state.conversation?.threads[key] else { return original }
        let currentPayload: JSONValue
        if let members = thread.currentQuestionPayload.objectMembers {
            // Supersedes belongs to the original delivery. A later question
            // revision may replace message content, but cannot replace the
            // relationship carried by that delivery.
            var currentMembers = members.filter { $0.key != ExactText("supersedes") }
            if let supersedes = original.originalPayload.uniqueValue(named: "supersedes") {
                currentMembers.append(JSONMember("supersedes", supersedes))
            }
            currentPayload = .object(currentMembers)
        } else {
            currentPayload = thread.currentQuestionPayload
        }
        let current = StoredRequest(key: key, originalPayload: currentPayload)
        return original.acceptanceOrder.map { current.assigningAcceptanceOrder($0) } ?? current
    }

    private func validate(_ suppliedContext: ProfileContext) throws {
        guard !isInvalidated,
              suppliedContext.identity == context.identity,
              suppliedContext.generation == context.generation,
              suppliedContext.transportMode == context.transportMode else {
            throw AttentionStoreError.staleProfile
        }
    }

    private func validate(_ requestKey: RequestKey, in identity: ProfileIdentity) throws {
        guard requestKey.accountScope == identity.personID else { throw AttentionStoreError.wrongAccount }
    }

    private func commit(_ proposed: ClientSessionState,
                        allowingCommittedReads: Bool = true) throws {
        var next = proposed
        next.revision = state.revision &+ 1
        let queue = PersistedPendingActions(state: next)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(queue)
        if allowingCommittedReads { lock.unlock() }
        do {
            try persistence.commit(bytes, identity: context.identity)
        } catch {
            if allowingCommittedReads { lock.lock() }
            throw error
        }
        if allowingCommittedReads { lock.lock() }
        state = next
        for observer in Array(changeObservers.values) { observer.yield(state.revision) }
    }

    private func refreshAcceptedReplayIndex(for requestKey: RequestKey) {
        guard let intentID = state.intentByRequest[requestKey],
              let submission = state.intents[intentID],
              Self.isAcceptedAwaitingTerminalReplay(submission, appliedEvents: state.appliedEvents) else {
            acceptedAwaitingTerminalReplay.removeValue(forKey: requestKey)
            return
        }
        acceptedAwaitingTerminalReplay[requestKey] = submission
    }

    private static func acceptedAwaitingTerminalReplay(in state: ClientSessionState) -> [RequestKey: Submission] {
        var result: [RequestKey: Submission] = [:]
        for submission in state.intents.values where
            isAcceptedAwaitingTerminalReplay(submission, appliedEvents: state.appliedEvents) {
            result[submission.requestKey] = submission
        }
        return result
    }

    private static func isAcceptedAwaitingTerminalReplay(_ submission: Submission,
                                                          appliedEvents: [UInt64: RelayEvent]) -> Bool {
        guard case let .accepted(expectedSequence) = submission.disposition else { return false }
        guard let expectedSequence,
              let event = appliedEvents[expectedSequence],
              case let .terminal(requestKey, _, _) = event.body,
              requestKey == submission.requestKey else { return true }
        return false
    }

    private static func externalizingConversationFiles(in file: ConversationFile,
        using references: (any ConversationFileReferenceStore)?, allowInlinePersistence: Bool) throws -> ConversationFile {
        guard case .inline = file.content else { return file }
        guard let references else {
            guard allowInlinePersistence else {
                throw AttentionStoreError.persistence("Account-owned conversation file storage is required for durable inline content.")
            }
            return file
        }
        let stored = try references.retainInlineContent(of: file)
        guard stored.id == file.id, stored.name == file.name, stored.byteCount == file.byteCount,
              stored.sha256 == file.sha256, case .localFile = stored.content else {
            throw ConversationError.fileMismatch
        }
        return stored
    }

    private static func externalizingConversationFiles(in turn: ConversationTurn,
        using references: (any ConversationFileReferenceStore)?, allowInlinePersistence: Bool) throws -> ConversationTurn {
        ConversationTurn(id: turn.id, binding: turn.binding, author: turn.author,
            sessionHandle: turn.sessionHandle, text: turn.text, inReplyTo: turn.inReplyTo,
            operationID: turn.operationID,
            files: try turn.files.map { try externalizingConversationFiles(in: $0, using: references, allowInlinePersistence: allowInlinePersistence) },
            contentRedacted: turn.contentRedacted, kind: turn.kind, resultStatus: turn.resultStatus,
            conversationSequence: turn.conversationSequence, deliveryAcks: turn.deliveryAcks)
    }

    private static func externalizingConversationFiles(in draft: ConversationDraft,
        using references: (any ConversationFileReferenceStore)?, allowInlinePersistence: Bool) throws -> ConversationDraft {
        ConversationDraft(binding: draft.binding, text: draft.text,
            files: try draft.files.map { try externalizingConversationFiles(in: $0, using: references, allowInlinePersistence: allowInlinePersistence) },
            disposition: draft.disposition)
    }

    private static func externalizingConversationFiles(in event: ConversationEvent,
        using references: (any ConversationFileReferenceStore)?, allowInlinePersistence: Bool) throws -> ConversationEvent {
        let fact: ConversationEvent.Fact
        switch event.fact {
        case let .turn(turn):
            fact = .turn(try externalizingConversationFiles(in: turn, using: references, allowInlinePersistence: allowInlinePersistence))
        case let .revision(turn, payload):
            fact = .revision(try externalizingConversationFiles(in: turn, using: references, allowInlinePersistence: allowInlinePersistence), payload: payload)
        case let .redactedRevision(turn):
            fact = .redactedRevision(try externalizingConversationFiles(in: turn, using: references, allowInlinePersistence: allowInlinePersistence))
        default: fact = event.fact
        }
        return ConversationEvent(sequence: event.sequence, binding: event.binding, fact: fact,
                                 retractedAtMilliseconds: event.retractedAtMilliseconds)
    }

    private static func externalizingConversationFiles(in event: RelayEvent,
        using references: (any ConversationFileReferenceStore)?, allowInlinePersistence: Bool) throws -> RelayEvent {
        let metadata = try event.conversation.map { old in
            RelayConversationMetadata(revision: old.revision, sessionHandle: old.sessionHandle,
                eventID: old.eventID, availability: old.availability, listeningSupport: old.listeningSupport,
                author: old.author,
                files: try old.files.map { files in
                    try files.map { try externalizingConversationFiles(in: $0, using: references, allowInlinePersistence: allowInlinePersistence) }
                },
                terminalReason: old.terminalReason, retractedAtMilliseconds: old.retractedAtMilliseconds)
        }
        return RelayEvent(sequence: event.sequence, body: event.body, conversation: metadata,
                          origin: event.origin,
                          accountAnswerOutcome: event.accountAnswerOutcome,
                          attentionTier: event.attentionTierWasProvided ? event.attentionTier : nil)
    }

    private static func externalizingConversationFiles(in checkpoint: InboxPagingCheckpoint,
        using references: (any ConversationFileReferenceStore)?, allowInlinePersistence: Bool) throws -> InboxPagingCheckpoint {
        var next = checkpoint
        next.batches = try checkpoint.batches.map { batch in
            var updated = batch
            updated.results = try batch.results.map { results in
                try results.map { receipt in
                    InboxOperationReceipt(operationID: receipt.operationID, status: receipt.status,
                        result: receipt.result,
                        terminal: try receipt.terminal.map {
                            try externalizingConversationFiles(in: $0, using: references,
                                                              allowInlinePersistence: allowInlinePersistence)
                        }, reason: receipt.reason)
                }
            }
            return updated
        }
        return next
    }

    private static func externalizingConversationFiles(in thread: ConversationThread,
        using references: (any ConversationFileReferenceStore)?, allowInlinePersistence: Bool) throws -> ConversationThread {
        var next = thread
        next.turns = try thread.turns.map { try externalizingConversationFiles(in: $0, using: references, allowInlinePersistence: allowInlinePersistence) }
        next.drafts = try thread.drafts.mapValues { try externalizingConversationFiles(in: $0, using: references, allowInlinePersistence: allowInlinePersistence) }
        if let groups = thread.uploadGroups {
            next.uploadGroups = try groups.mapValues { group in
                var copy = group
                copy.originals = try group.originals.map { try externalizingConversationFiles(in: $0, using: references, allowInlinePersistence: allowInlinePersistence) }
                copy.uploaded = try group.uploaded.map { try externalizingConversationFiles(in: $0, using: references, allowInlinePersistence: allowInlinePersistence) }
                return copy
            }
        }
        return next
    }


    private func recordRepair(_ issue: StoreRepairIssue) throws {
        guard !state.repairIssues.contains(issue) else { return }
        var next = state
        next.repairIssues.append(issue)
        try commit(next)
    }

    private func dropUnsentAnswer(for key: RequestKey, in next: inout ClientSessionState) {
        let ids = next.intents.compactMap { id, operation -> UUID? in
            guard operation.requestKey == key else { return nil }
            switch operation.disposition {
            case .pending, .lost: return id
            default: return nil
            }
        }
        for id in ids { next.intents.removeValue(forKey: id) }
        next.intentByRequest.removeValue(forKey: key)
        next.outboxOrder.removeAll { ids.contains($0) }
        next.drafts.removeValue(forKey: key)
        next.pendingConversations[key]?.answerDrafts = nil
    }

    private func dropAnswersInvalidatedBySnapshot(_ checkpoint: InboxPagingCheckpoint,
                                                       in next: inout ClientSessionState) {
        guard checkpoint.checkpointAccepted else { return }
        let queuedKeys = Set(next.drafts.keys).union(next.intentByRequest.keys)
        for key in queuedKeys {
            let terminal = next.remoteStates[key]?.isTerminal == true || next.inboxReferences?[key]?.isTerminal == true
            let absent = checkpoint.nextCursor == nil && !checkpoint.currentKeys.contains(key)
            if terminal || absent { dropUnsentAnswer(for: key, in: &next) }
        }
    }

    /// Editor input is local work, never a constraint on an incoming server
    /// projection. Recreate an incompatible editor from the current question;
    /// already queued operations retain their exact bytes for the send check.
    private func refreshEditableDraft(for key: RequestKey, additionalFiles: Set<ExactText> = [],
                                      in next: inout ClientSessionState) {
        guard let original = next.requests[key] else { return }
        let payload = next.conversation?.threads[key]?.currentQuestionPayload ?? original.originalPayload
        let request = StoredRequest(key: key, originalPayload: payload)
        let files = Self.deliveredFileNames(for: key, in: next.conversation).union(additionalFiles)
        let interface = request.interface(deliveredFileNames: files)
        if let draft = next.drafts[key], validateDraft(draft, for: interface) { return }
        next.drafts[key] = RequestDraft(interface: interface)
    }

    private func validateDraft(_ draft: RequestDraft, for interface: RequestInterface) -> Bool {
        switch interface {
        case let .sender(document):
            guard draft.inputs.count == document.inputs.count,
                  Set(draft.inputs.keys) == Set(document.inputs.map(\.id)),
                  !draft.compatibility.hasEdits else { return false }
            for input in document.inputs {
                guard let value = draft.inputs[input.id] else { return false }
                switch input.kind {
                case let .response(actions):
                    guard value.text == nil, value.point == nil,
                          value.horizontalText == nil, value.verticalText == nil,
                          value.textByActionID.keys.allSatisfy({ id in
                              actions.contains(where: { $0.id == id && $0.kind == .text })
                          }),
                          value.selectedActionID.map({ id in actions.contains(where: { $0.id == id }) }) ?? true else { return false }
                case .text:
                    guard value.text != nil, value.selectedActionID == nil, value.point == nil,
                          value.horizontalText == nil, value.verticalText == nil,
                          value.textByActionID.isEmpty else { return false }
                case .point:
                    guard value.selectedActionID == nil, value.text == nil, value.textByActionID.isEmpty else { return false }
                    if value.point == nil {
                        guard value.horizontalText == nil, value.verticalText == nil else { return false }
                    } else if value.horizontalText == nil || value.verticalText == nil {
                        return false
                    }
                }
            }
            return true
        case let .compatibility(form):
            guard draft.inputs.isEmpty,
                  draft.compatibility.textByActionID.keys.allSatisfy({ id in form.action(withID: id)?.kind == .text }),
                  draft.compatibility.selectedActionID.map({ form.action(withID: $0) != nil }) ?? true else { return false }
            return true
        case .unsupported:
            return draft.inputs.isEmpty && !draft.compatibility.hasEdits
        }
    }

    private func compose(_ typedSubmission: TypedSubmission,
                        draft: RequestDraft,
                        for request: StoredRequest) throws -> JSONValue {
        switch (requestInterface(for: request), typedSubmission) {
        case let (.sender(document), .senderInputs(inputs)):
            guard inputs.count == document.inputs.count,
                  Set(inputs.map(\.inputID)).count == inputs.count,
                  Set(inputs.map(\.inputID)) == Set(document.inputs.map(\.id)) else {
                throw AttentionStoreError.invalidSubmission
            }
            var composedDrafts = Dictionary(uniqueKeysWithValues: document.inputs.map {
                ($0.id, InputDraft.initial(for: $0))
            })
            for input in inputs {
                guard let descriptor = document.input(withID: input.inputID), var inputDraft = composedDrafts[input.inputID] else {
                    throw AttentionStoreError.invalidSubmission
                }
                switch descriptor.kind {
                case let .response(actions):
                    guard let actionID = input.actionID,
                          let action = actions.first(where: { $0.id == actionID }),
                          input.point == nil else { throw AttentionStoreError.invalidSubmission }
                    inputDraft.selectedActionID = actionID
                    switch action.kind {
                    case .value:
                        guard input.text == nil else { throw AttentionStoreError.invalidSubmission }
                    case .text:
                        guard let text = input.text else { throw AttentionStoreError.invalidSubmission }
                        inputDraft.textByActionID[actionID] = text
                    }
                case .text:
                    guard input.actionID == nil, input.point == nil, let text = input.text else {
                        throw AttentionStoreError.invalidSubmission
                    }
                    inputDraft.text = text
                case .point:
                    guard input.actionID == nil, input.text == nil, let point = input.point,
                          (0...1000).contains(point.x), (0...1000).contains(point.y) else {
                        throw AttentionStoreError.invalidSubmission
                    }
                    inputDraft.point = point
                    inputDraft.horizontalText = ExactText(String(point.x))
                    inputDraft.verticalText = ExactText(String(point.y))
                }
                composedDrafts[input.inputID] = inputDraft
            }
            guard typedMatchesDraft(inputs, draft: draft, document: document),
                  let answer = document.compose(drafts: composedDrafts, maximumBytes: maximumWireFrameBytes) else {
                throw AttentionStoreError.invalidSubmission
            }
            return answer
        case let (.compatibility(form), .compatibility(actionID, text)):
            guard draft.inputs.isEmpty, draft.compatibility.selectedActionID == actionID,
                  let action = form.action(withID: actionID),
                  let answer = AnswerComposer.compose(action: action, editedText: text ?? ExactText("")) else {
                throw AttentionStoreError.invalidSubmission
            }
            switch action.kind {
            case .value:
                guard text == nil else { throw AttentionStoreError.invalidSubmission }
            case .text:
                guard text != nil else { throw AttentionStoreError.invalidSubmission }
            }
            // The informational descriptor identifies Seen; the device protocol
            // represents that action with a null answer, not the descriptor value.
            if request.hasExplicitInformationalSeenAction { return .null }
            return answer
        default:
            throw AttentionStoreError.unsupportedInterface
        }
    }

    private func typedMatchesDraft(_ submissions: [InputSubmission],
                                   draft: RequestDraft,
                                   document: SenderDocument) -> Bool {
        for submission in submissions {
            guard let descriptor = document.input(withID: submission.inputID),
                  let saved = draft.inputs[submission.inputID] else { return false }
            switch descriptor.kind {
            case let .response(actions):
                guard saved.selectedActionID == submission.actionID,
                      let actionID = submission.actionID,
                      let action = actions.first(where: { $0.id == actionID }) else { return false }
                if case .text = action.kind {
                    guard saved.textByActionID[actionID] == submission.text, submission.point == nil else { return false }
                } else {
                    guard submission.text == nil, submission.point == nil else { return false }
                }
            case .text:
                guard saved.text == submission.text, submission.text != nil,
                      submission.actionID == nil, submission.point == nil else { return false }
            case .point:
                guard saved.effectivePoint == submission.point, submission.point != nil,
                      submission.actionID == nil, submission.text == nil else { return false }
            }
        }
        return true
    }

    private func normalizedSubmission(_ submission: TypedSubmission, interface: RequestInterface) -> JSONValue {
        switch (submission, interface) {
        case let (.senderInputs(inputs), .sender(document)):
            let inputOrder = Dictionary(uniqueKeysWithValues: document.inputs.enumerated().map { ($1.id, $0) })
            let sorted = inputs.sorted { (inputOrder[$0.inputID] ?? .max) < (inputOrder[$1.inputID] ?? .max) }
            return .array(sorted.map { item in
                .object([
                    JSONMember("input", .string(item.inputID)),
                    JSONMember("action", item.actionID.map(JSONValue.string) ?? .null),
                    JSONMember("text", item.text.map(JSONValue.string) ?? .null),
                    JSONMember("point", item.point?.jsonValue ?? .null)
                ])
            })
        case let (.compatibility(actionID, text), .compatibility):
            return .object([
                JSONMember("action", .string(actionID)),
                JSONMember("text", text.map(JSONValue.string) ?? .null)
            ])
        default:
            return .null
        }
    }

    private func relayAnswerOperation(request: StoredRequest, answer: JSONValue, operationID: UUID, requestRevision: UInt64) -> JSONValue {
        let members = [
            JSONMember("v", .number(JSONNumber(lexeme: "1"))),
            JSONMember("type", .string(ExactText("answer"))),
            JSONMember("op_id", .string(ExactText(operationID.uuidString.lowercased()))),
            JSONMember("sender_id", .string(request.key.senderID)),
            JSONMember("message_id", .string(request.key.messageID)),
            JSONMember("answer", answer),
            JSONMember("request_revision", .number(JSONNumber(lexeme: String(requestRevision))))
        ]
        return .object(members)
    }

    private func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func submissionSignature(for interface: RequestInterface) -> String {
        func constructor(_ value: ResultConstructor) -> JSONValue {
            switch value {
            case let .literal(literal):
                return .object([JSONMember("literal", literal)])
            case let .input(id):
                return .object([JSONMember("input", .string(id))])
            case let .array(values):
                return .array(values.map(constructor))
            case let .object(members):
                return .object(members.map { JSONMember(key: $0.name, value: constructor($0.value)) })
            }
        }

        let signature: JSONValue
        switch interface {
        case let .sender(document):
            signature = constructor(document.result)
        case let .compatibility(form):
            signature = .array(form.actions.map { action in
                .object([
                    JSONMember("id", .string(action.id)),
                    JSONMember("kind", .string(ExactText(action.kind == .value ? "value" : "text"))),
                    JSONMember("value", action.value ?? .null)
                ])
            })
        case .unsupported:
            signature = .null
        }
        return signature.canonicalJSON
    }

    private func isUUIDv4(_ value: UUID) -> Bool {
        let bytes = withUnsafeBytes(of: value.uuid) { Array($0) }
        return bytes.count == 16 && bytes[6] >> 4 == 4 && bytes[8] >> 6 == 2
    }
}

private struct SelectorBinding {
    let requestRevision: UInt64
    let requestKey: RequestKey
    let profileGeneration: UUID
    let descriptorFingerprint: String
    let submissionFingerprint: String
    let opaqueSubmissionID: ExactText
}

private struct ClientSessionState {
    let profileIdentity: ProfileIdentity
    var server = ServerProjectionCache()
    var revision: UInt64 = 0
    var drafts: [RequestKey: RequestDraft] = [:]
    var fixtureSessions: [RequestKey: RequestSession] = [:]
    var intents: [UUID: Submission] = [:]
    var fencedIntents: [UUID: RequestKey]? = nil
    var intentByRequest: [RequestKey: UUID] = [:]
    var outboxOrder: [UUID] = []
    var replayPublishedIntents: [UUID: Submission]?
    var pendingMessageOpens: [PendingMessageOpen]?
    var pendingConversations: [RequestKey: PendingConversationActions] = [:]
    var pendingReadPositions: [RequestKey: PendingConversationReadPosition] = [:]
    var requests: [RequestKey: StoredRequest] {
        get { server.requests }
        set { server.requests = newValue }
    }
    var remoteStates: [RequestKey: RemoteRequestState] {
        get { server.remoteStates }
        set { server.remoteStates = newValue }
    }
    var appliedEvents: [UInt64: RelayEvent] {
        get { server.appliedEvents }
        set { server.appliedEvents = newValue }
    }
    var cursor: UInt64 {
        get { server.cursor }
        set { server.cursor = newValue }
    }
    var replayBarrier: UInt64? {
        get { server.replayBarrier }
        set { server.replayBarrier = newValue }
    }
    var replayPublishedRequests: [RequestKey: StoredRequest]? {
        get { server.replayPublishedRequests }
        set { server.replayPublishedRequests = newValue }
    }
    var replayPublishedStates: [RequestKey: RemoteRequestState]? {
        get { server.replayPublishedStates }
        set { server.replayPublishedStates = newValue }
    }
    var replayPublishedInboxCurrentKeys: Set<RequestKey>? {
        get { server.replayPublishedInboxCurrentKeys }
        set { server.replayPublishedInboxCurrentKeys = newValue }
    }
    var repairIssues: [StoreRepairIssue] {
        get { server.repairIssues }
        set { server.repairIssues = newValue }
    }
    var inboxCheckpoint: InboxPagingCheckpoint? {
        get { server.inboxCheckpoint }
        set { server.inboxCheckpoint = newValue }
    }
    var inboxCandidate: InboxPagingCheckpoint? {
        get { server.inboxCandidate }
        set { server.inboxCandidate = newValue }
    }
    var inboxView: InboxView? {
        get { server.inboxView }
        set { server.inboxView = newValue }
    }
    var cachedInboxCurrentKeys: Set<RequestKey>? {
        get { server.cachedInboxCurrentKeys }
        set { server.cachedInboxCurrentKeys = newValue }
    }
    var pendingRelayOverlays: [UInt64: RelayEvent]? {
        get { server.pendingRelayOverlays }
        set { server.pendingRelayOverlays = newValue }
    }
    var inboxReferences: [RequestKey: RemoteRequestState]? {
        get { server.inboxReferences }
        set { server.inboxReferences = newValue }
    }
    var conversation: ConversationState? {
        get {
            guard var value = server.conversation else { return nil }
            value.pendingChatReadPositions = pendingReadPositions
            for key in Array(value.threads.keys) {
                guard let queued = pendingConversations[key] else { continue }
                value.threads[key]?.drafts = queued.drafts
                value.threads[key]?.answerDrafts = queued.answerDrafts
                value.threads[key]?.uploadGroups = queued.uploadGroups
                value.threads[key]?.uploadCleanups = queued.uploadCleanups
            }
            return value
        }
        set {
            guard var value = newValue else {
                server.conversation = nil
                return
            }
            pendingReadPositions = value.pendingChatReadPositions ?? [:]
            value.pendingChatReadPositions = nil
            for key in Array(value.threads.keys) {
                guard var thread = value.threads[key] else { continue }
                if server.conversation?.threads[key] == nil,
                   let queued = pendingConversations[key] {
                    // Input can precede the first server thread after upgrade
                    // or restart. Hydrating that thread must not empty its queue.
                    thread.drafts = queued.drafts
                    thread.answerDrafts = queued.answerDrafts
                    thread.uploadGroups = queued.uploadGroups
                    thread.uploadCleanups = queued.uploadCleanups
                    // Held server history may already prove an exact operation
                    // accepted before the thread's original delivery arrives.
                    for turn in thread.turns where turn.kind != .result {
                        guard let operation = turn.operationID,
                              let draft = thread.drafts[turn.binding.revision] else { continue }
                        switch draft.disposition {
                        case let .submitting(id) where id == operation,
                             let .outcomeUnknown(id) where id == operation,
                             let .acceptedPendingReplay(id, _) where id == operation:
                            thread.drafts.removeValue(forKey: turn.binding.revision)
                        default: break
                        }
                    }
                }
                pendingConversations[key] = PendingConversationActions(thread: thread)
                thread.drafts = [:]
                thread.answerDrafts = nil
                thread.uploadGroups = nil
                thread.uploadCleanups = nil
                value.threads[key] = thread
            }
            server.conversation = value
        }
    }
    init(profileIdentity: ProfileIdentity) { self.profileIdentity = profileIdentity }
}

/// Read once during upgrade, then delete the source file. Deliberately omits
/// every server-owned field from the retired store's schema.
private struct RetiredUnsentInput: Decodable {
    let profileIdentity: ProfileIdentity
    let drafts: [RequestKey: RequestDraft]?
    let intents: [UUID: Submission]?
    let intentByRequest: [RequestKey: UUID]?
    let conversation: ConversationInput?

    struct ConversationInput: Decodable {
        // Decode only user input from each historical thread. Request content,
        // accepted turns, read positions and the conversation cursor are ignored.
        let threads: [RequestKey: PendingConversationActions]
    }
}

/// Only unsent/uncertain local requests cross a process restart. No Server
/// question, terminal, revision, read position or replay cursor is encoded here.
private struct PersistedPendingActions: Codable {
    let version: Int
    let profileIdentity: ProfileIdentity
    let operations: [UUID: Submission]
    let activeOperations: [RequestKey: UUID]
    // Local cancellation of an unsent operation belongs to the send queue.
    // It must survive restart so a late submit cannot recreate that operation.
    let cancelledOperations: [UUID: RequestKey]?
    let answerDrafts: [RequestKey: RequestDraft]
    let messageOpens: [PendingMessageOpen]?
    let conversations: [RequestKey: PendingConversationActions]
    let readPositions: [RequestKey: PendingConversationReadPosition]

    init(state: ClientSessionState) {
        version = 1
        profileIdentity = state.profileIdentity
        let pending = state.intents.filter { id, operation in
            guard state.intentByRequest[operation.requestKey] == id else { return false }
            switch operation.disposition {
            case .pending, .lost: return true
            default: return false
            }
        }
        operations = pending
        activeOperations = state.intentByRequest.filter { pending[$0.value] != nil }
        cancelledOperations = state.fencedIntents
        let keys = Set(pending.values.map(\.requestKey))
        answerDrafts = state.drafts.filter { $0.value.hasEdits || keys.contains($0.key) }
        messageOpens = state.pendingMessageOpens
        conversations = state.pendingConversations
        readPositions = state.pendingReadPositions
    }
}

/// User-authored work awaiting transport. No request content, server revisions,
/// accepted turns, terminal state or read cursor is stored with this queue.
private struct PendingConversationActions: Codable {
    var drafts: [UInt64: ConversationDraft]
    var answerDrafts: [UInt64: RequestDraft]?
    var uploadGroups: [UUID: ConversationUploadGroup]?
    var uploadCleanups: [UUID: ConversationUploadCleanup]?

    init(thread: ConversationThread) {
        drafts = thread.drafts
        answerDrafts = thread.answerDrafts
        uploadGroups = thread.uploadGroups
        uploadCleanups = thread.uploadCleanups
    }
}

private extension ProfileIdentity {
    var storageKey: String {
        let identityJSON = JSONValue.array([
            .string(trustedRelayAuthority),
            .string(personID),
            .string(deviceID)
        ]).canonicalJSON
        return SHA256.hash(data: Data(identityJSON.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
