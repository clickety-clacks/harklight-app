import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

public protocol AttentionStatePersistence: AnyObject, Sendable {
    func load(identity: ProfileIdentity) throws -> Data?
    func commit(_ data: Data, identity: ProfileIdentity) throws
}

public final class MemoryAttentionStatePersistence: AttentionStatePersistence, @unchecked Sendable {
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

public final class FileAttentionStatePersistence: AttentionStatePersistence, @unchecked Sendable {
    public let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    public static func applicationSupport() throws -> FileAttentionStatePersistence {
        guard let supportURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else {
            throw AttentionStoreError.persistence("Application Support is unavailable.")
        }
        return FileAttentionStatePersistence(directoryURL: supportURL.appendingPathComponent("Attention", isDirectory: true))
    }

    public func load(identity: ProfileIdentity) throws -> Data? {
        let url = fileURL(for: identity)
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
        directoryURL.appendingPathComponent("\(identity.storageKey).plist", isDirectory: false)
    }

    private func setPrivateAttributes(at url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }
}

public final class AttentionDomainStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let context: ProfileContext
    private let persistence: any AttentionStatePersistence
    private let conversationFileReferences: (any ConversationFileReferenceStore)?
    private let maximumWireFrameBytes: Int
    private var state: PersistedAttentionState
    private var selectorBindings: [UUID: SelectorBinding] = [:]
    private var changeObservers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var isInvalidated = false

    var profileContext: ProfileContext { context }

    public init(context: ProfileContext,
                persistence: any AttentionStatePersistence,
                maximumWireFrameBytes: Int = 65_536,
                conversationFileReferences: (any ConversationFileReferenceStore)? = nil) throws {
        self.context = context
        self.persistence = persistence
        self.conversationFileReferences = conversationFileReferences
        self.maximumWireFrameBytes = max(0, maximumWireFrameBytes)
        if let data = try persistence.load(identity: context.identity) {
            let loaded = try PropertyListDecoder().decode(PersistedAttentionState.self, from: data)
            guard loaded.profileIdentity == context.identity else { throw AttentionStoreError.wrongAccount }
            guard loaded.schemaVersion == PersistedAttentionState.currentSchemaVersion else {
                throw AttentionStoreError.persistence("Unsupported local state schema \(loaded.schemaVersion).")
            }
            let requestKeys = Set(loaded.requests.keys)
            let validRequestScope = requestKeys.allSatisfy { $0.accountScope == context.identity.personID }
            let validDrafts = loaded.drafts.keys.allSatisfy { requestKeys.contains($0) }
            let validSessions = loaded.fixtureSessions.keys.allSatisfy { requestKeys.contains($0) }
            let validRemoteStates = loaded.remoteStates.keys.allSatisfy { requestKeys.contains($0) }
            let validIntents = loaded.intents.allSatisfy { entry in
                entry.key == entry.value.intentID && requestKeys.contains(entry.value.requestKey) &&
                    entry.value.requestKey.accountScope == context.identity.personID
            }
            let validIntentIndex = loaded.intentByRequest.allSatisfy { entry in
                loaded.intents[entry.value]?.requestKey == entry.key
            } && Set(loaded.intentByRequest.values).count == loaded.intentByRequest.count
            let validFences = (loaded.fencedIntents ?? [:]).allSatisfy { entry in
                entry.value.accountScope == context.identity.personID && loaded.intents[entry.key] == nil
            }
            let validOutbox = Set(loaded.outboxOrder).count == loaded.outboxOrder.count &&
                loaded.outboxOrder.allSatisfy { loaded.intents[$0] != nil }
            guard validRequestScope, validDrafts, validSessions, validRemoteStates,
                  validIntents, validIntentIndex, validFences, validOutbox else {
                throw AttentionStoreError.persistence("The profile store contains cross-account or inconsistent request state.")
            }
            guard (loaded.conversation?.threads.keys.allSatisfy { $0.accountScope == context.identity.personID } ?? true),
                  (loaded.conversation?.events.values.allSatisfy { $0.binding.request.accountScope == context.identity.personID } ?? true) else {
                throw AttentionStoreError.persistence("The conversation store contains a different account's requests.")
            }
            self.state = try Self.externalizingConversationFiles(in: loaded,
                using: conversationFileReferences,
                allowInlinePersistence: persistence is MemoryAttentionStatePersistence)
        } else {
            self.state = PersistedAttentionState(profileIdentity: context.identity)
        }
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        isInvalidated = true
        selectorBindings.removeAll()
    }

    public func registerFixtureRequests(_ requests: [StoredRequest], context suppliedContext: ProfileContext) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        var next = state
        var changed = false
        var acceptanceOrder = next.requests.values.compactMap(\.acceptanceOrder).max() ?? 0
        for request in requests {
            try validate(request.key, in: context.identity)
            if let existing = next.requests[request.key] {
                guard existing.originalPayload.semanticallyEquals(request.originalPayload) else {
                    throw AttentionStoreError.requestConflict
                }
                if existing.acceptanceOrder == nil {
                    acceptanceOrder += 1
                    next.requests[request.key] = existing.assigningAcceptanceOrder(acceptanceOrder)
                    changed = true
                }
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
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        var next = PersistedAttentionState(profileIdentity: context.identity)
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

    public func selector(for requestKey: RequestKey, context suppliedContext: ProfileContext) throws -> BoundDocumentSelector {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        try validate(requestKey, in: context.identity)
        guard state.conversation?.threads[requestKey]?.currentContentRedacted != true else {
            throw AttentionStoreError.unsupportedInterface
        }
        guard let request = effectiveRequest(for: requestKey) else { throw AttentionStoreError.requestMissing }
        let id = UUID()
        let submissionID = UUID()
        selectorBindings[id] = SelectorBinding(requestRevision: state.conversation?.threads[requestKey]?.currentRevision,
                                               requestKey: requestKey,
                                               profileGeneration: context.generation,
                                               descriptorFingerprint: fingerprint(request.answerDescription?.canonicalJSON ?? ""),
                                               submissionFingerprint: fingerprint(submissionSignature(for: request.interface)),
                                               opaqueSubmissionID: ExactText(submissionID.uuidString.lowercased()))
        return BoundDocumentSelector(request: requestKey,
                                     opaqueDocumentID: ExactText(id.uuidString.lowercased()),
                                     opaqueSubmissionID: ExactText(submissionID.uuidString.lowercased()))
    }

    public func saveDraft(_ draft: RequestDraft,
                          selector: BoundDocumentSelector,
                          context suppliedContext: ProfileContext) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let request = try boundRequest(selector, context: suppliedContext)
        let interface = request.interface
        guard validateDraft(draft, for: interface) else { throw AttentionStoreError.invalidDraft }
        guard state.remoteStates[request.key]?.isTerminal != true,
              state.intentByRequest[request.key] == nil else {
            throw AttentionStoreError.requestClosed
        }
        var next = state
        next.drafts[request.key] = draft
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
                       context suppliedContext: ProfileContext) throws -> Submission {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let request = try boundRequest(selector, context: suppliedContext)
        guard state.replayBarrier == nil else { throw AttentionStoreError.replayAlreadyActive }
        guard isUUIDv4(intentID) else { throw AttentionStoreError.invalidSubmission }
        guard validateDraft(draft, for: request.interface) else { throw AttentionStoreError.invalidDraft }
        let answer = try compose(typedSubmission, draft: draft, for: request)
        let descriptorFingerprint = fingerprint(request.answerDescription?.canonicalJSON ?? "")
        let normalizedInputs = normalizedSubmission(typedSubmission, interface: request.interface)
        var fingerprintParts = [
            request.key.accountScope.rawValue,
            request.key.senderID.rawValue,
            request.key.messageID.rawValue,
            descriptorFingerprint,
            normalizedInputs.canonicalJSON,
            answer.canonicalJSON
        ]
        if let revision = state.conversation?.threads[request.key]?.currentRevision {
            fingerprintParts += ["request_revision", String(revision)]
        }
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
                                             requestRevision: state.conversation?.threads[request.key]?.currentRevision)
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
                                   requestRevision: state.conversation?.threads[request.key]?.currentRevision)

        var next = state
        next.drafts[request.key] = draft
        next.intents[intentID] = submission
        next.intentByRequest[request.key] = intentID
        next.outboxOrder.append(intentID)
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

    public func recordAcceptedOperation(_ intentID: UUID,
                                        operationID: UUID,
                                        terminalSequence: UInt64,
                                        context suppliedContext: ProfileContext) throws {
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
    }

    public func recordClosedOperation(_ intentID: UUID,
                                      operationID: UUID,
                                      sequence: UInt64,
                                      state terminalState: TerminalState,
                                      authorizedOriginAnswer: JSONValue?,
                                      context suppliedContext: ProfileContext) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        guard var intent = state.intents[intentID] else { throw AttentionStoreError.intentMissing }
        guard intent.operationID == operationID else { throw AttentionStoreError.intentConflict }
        if let old = state.remoteStates[intent.requestKey]?.state, old != terminalState {
            throw AttentionStoreError.eventConflict(sequence)
        }
        let effectiveAuthorizedAnswer = authorizedOriginAnswer ?? state.remoteStates[intent.requestKey]?.authorizedOriginAnswer
        if case .accepted = intent.disposition {
            // A later closed response cannot erase confirmed success for this exact operation.
        } else {
            intent.disposition = .terminal(state: terminalState,
                                           sequence: sequence,
                                           authorizedAnswer: effectiveAuthorizedAnswer)
        }
        var next = state
        next.intents[intentID] = intent
        next.outboxOrder.removeAll(where: { $0 == intentID })
        next.remoteStates[intent.requestKey] = RemoteRequestState(state: terminalState,
                                                                  authorizedOriginAnswer: effectiveAuthorizedAnswer,
                                                                  classification: state.remoteStates[intent.requestKey]?.classification,
                                                                  eventSequence: sequence)
        if var published = next.replayPublishedIntents {
            published[intentID] = intent
            next.replayPublishedIntents = published
        }
        if var publishedStates = next.replayPublishedStates {
            publishedStates[intent.requestKey] = next.remoteStates[intent.requestKey]
            next.replayPublishedStates = publishedStates
        }
        try commit(next)
    }

    public func recordFixtureTerminal(_ terminal: FixtureTerminal,
                                      for requestKey: RequestKey,
                                      context suppliedContext: ProfileContext) throws {
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
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard suppliedContext.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        let event = try Self.externalizingConversationFiles(in: event,
            using: conversationFileReferences,
            allowInlinePersistence: persistence is MemoryAttentionStatePersistence)

        if event.sequence <= state.cursor {
            guard let previous = state.appliedEvents[event.sequence],
                  previous.hasSameSemanticContent(as: event) else {
                try recordRepair(.conflictingEvent(sequence: event.sequence))
                throw AttentionStoreError.eventConflict(event.sequence)
            }
            if let metadata = event.conversation {
                if let previous = state.appliedEvents[event.sequence]?.conversation, !metadata.canEnrich(previous) {
                    throw ConversationError.conflict
                }
                var next = state
                try applyOrdinaryConversationMetadata(event, to: &next)
                if state.appliedEvents[event.sequence]?.conversation != metadata {
                    next.appliedEvents[event.sequence] = event
                    try commit(next)
                }
            }
            if case let .delivery(request, classification) = event.body,
               state.remoteStates[request.key]?.classification != classification {
                var next = state
                next.appliedEvents[event.sequence] = event
                if let old = next.remoteStates[request.key] {
                    next.remoteStates[request.key] = RemoteRequestState(state: old.state,
                                                                        authorizedOriginAnswer: old.authorizedOriginAnswer,
                                                                        classification: classification,
                                                                        eventSequence: old.eventSequence)
                }
                try commit(next)
            }
            return state.cursor
        }

        let expected = state.cursor + 1
        guard event.sequence == expected else {
            try recordRepair(.eventGap(expected: expected, received: event.sequence))
            throw AttentionStoreError.eventGap(expected: expected, received: event.sequence)
        }
        if let barrier = state.replayBarrier, event.sequence > barrier {
            try recordRepair(.eventGap(expected: barrier, received: event.sequence))
            throw AttentionStoreError.eventGap(expected: barrier, received: event.sequence)
        }

        var next = state
        switch event.body {
        case let .delivery(request, classification):
            try validate(request.key, in: context.identity)
            if let existing = next.requests[request.key] {
                guard existing.originalPayload.semanticallyEquals(request.originalPayload) else {
                    try recordRepair(.conflictingEvent(sequence: event.sequence))
                    throw AttentionStoreError.eventConflict(event.sequence)
                }
                if existing.acceptanceOrder == nil {
                    let priorOrder = firstDeliverySequence(for: request.key, in: next.appliedEvents)
                    next.requests[request.key] = existing.assigningAcceptanceOrder(priorOrder ?? event.sequence)
                }
            } else {
                next.requests[request.key] = request.assigningAcceptanceOrder(event.sequence)
                let thread = next.conversation?.threads[request.key]
                let currentPayload = thread?.currentQuestionPayload ?? request.originalPayload
                next.drafts[request.key] = RequestDraft(interface: StoredRequest(key: request.key, originalPayload: currentPayload).interface)
            }
            let previous = next.remoteStates[request.key]
            next.remoteStates[request.key] = RemoteRequestState(state: previous?.state ?? next.conversation?.threads[request.key]?.terminal,
                                                                authorizedOriginAnswer: previous?.authorizedOriginAnswer,
                                                                classification: classification,
                                                                eventSequence: event.sequence)
        case let .originReference(requestKey):
            try validate(requestKey, in: context.identity)
            guard next.requests[requestKey] != nil else {
                try recordRepair(.missingOriginContent(sequence: event.sequence, requestKey: requestKey))
                throw AttentionStoreError.missingOriginContent(requestKey)
            }
            let previous = next.remoteStates[requestKey] ?? RemoteRequestState()
            next.remoteStates[requestKey] = RemoteRequestState(state: previous.state,
                                                               authorizedOriginAnswer: previous.authorizedOriginAnswer,
                                                               classification: nil,
                                                               eventSequence: event.sequence)
        case let .terminal(requestKey, terminalState, authorizedOriginAnswer):
            try validate(requestKey, in: context.identity)
            guard next.requests[requestKey] != nil else {
                try recordRepair(.missingOriginContent(sequence: event.sequence, requestKey: requestKey))
                throw AttentionStoreError.missingOriginContent(requestKey)
            }
            let previous = next.remoteStates[requestKey] ?? RemoteRequestState()
            if let oldState = previous.state, oldState != terminalState {
                try recordRepair(.conflictingEvent(sequence: event.sequence))
                throw AttentionStoreError.eventConflict(event.sequence)
            }
            let effectiveAuthorizedAnswer = authorizedOriginAnswer ?? previous.authorizedOriginAnswer
            next.remoteStates[requestKey] = RemoteRequestState(state: terminalState,
                                                               authorizedOriginAnswer: effectiveAuthorizedAnswer,
                                                               classification: previous.classification,
                                                               eventSequence: event.sequence)
            if let intentID = next.intentByRequest[requestKey], var intent = next.intents[intentID] {
                if case .accepted = intent.disposition {
                    // A later lifecycle event does not erase evidence that this exact operation won.
                } else {
                    intent.disposition = .terminal(state: terminalState,
                                                   sequence: event.sequence,
                                                   authorizedAnswer: effectiveAuthorizedAnswer)
                    next.intents[intentID] = intent
                }
                next.outboxOrder.removeAll(where: { $0 == intentID })
            }
        }
        try applyOrdinaryConversationMetadata(event, to: &next)
        next.appliedEvents[event.sequence] = event
        next.cursor = event.sequence
        next.repairIssues.removeAll { issue in
            switch issue {
            case let .eventGap(_, received): return received <= event.sequence + 1
            case let .missingOriginContent(sequence, _): return sequence == event.sequence
            case let .conflictingEvent(sequence): return sequence == event.sequence
            }
        }
        try commit(next)
        return state.cursor
    }

    private func applyOrdinaryConversationMetadata(_ event: RelayEvent, to next: inout PersistedAttentionState) throws {
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
                guard prior.sessionHandle == handle,
                      prior.revisions[1]?.semanticallyEquals(request.originalPayload) == true else {
                    throw ConversationError.conflict
                }
                thread = prior
            } else {
                thread = ConversationThread(request: request.key, sessionHandle: handle,
                    revision: 1, payload: request.originalPayload)
                if let availability = metadata.availability { thread.availability = availability }
                thread.listeningSupport = metadata.listeningSupport
                thread.terminal = next.remoteStates[request.key]?.state
            }
            if thread.listeningSupport == nil { thread.listeningSupport = metadata.listeningSupport }
            if let id = metadata.eventID, !thread.turns.contains(where: { $0.id == id }) {
                try validateConversationFiles(metadata.files ?? [])
                thread.turns.append(ConversationTurn(id: id, binding: ConversationBinding(request: request.key, revision: 1),
                    author: .origin, sessionHandle: handle, text: ExactText(""), files: metadata.files ?? [], kind: .revision))
                thread.facts[id, default: ConversationTurnFacts()] = thread.facts[id] ?? ConversationTurnFacts()
                thread.orderTurns()
            }
            conversation.threads[request.key] = thread
        case let .terminal(key, terminal, _):
            guard var thread = conversation.threads[key] else { return }
            guard thread.terminal == nil || thread.terminal == terminal else { throw ConversationError.conflict }
            thread.terminal = terminal
            if let author = event.conversation?.author { thread.terminalAuthor = author }
            if let eventID = event.conversation?.eventID {
                guard thread.terminalTurn == nil || thread.terminalTurn == eventID else { throw ConversationError.conflict }
                thread.terminalTurn = eventID
                if let author = event.conversation?.author, !thread.turns.contains(where: { $0.id == eventID }) {
                    thread.turns.append(ConversationTurn(id: eventID,
                        binding: ConversationBinding(request: key, revision: event.conversation!.revision), author: author,
                        sessionHandle: thread.sessionHandle, text: ExactText(""), files: event.conversation?.files ?? [], kind: .terminal))
                    thread.facts[eventID, default: ConversationTurnFacts()] = thread.facts[eventID] ?? ConversationTurnFacts()
                    thread.orderTurns()
                }
            }
            if event.conversation?.terminalReason == ExactText("retracted") {
                guard terminal == .cleared, event.conversation?.author == .origin,
                      let id = event.conversation?.eventID, let revision = event.conversation?.revision else {
                    throw ConversationError.invalidBinding
                }
                try thread.recordRetraction(turn: id, sequence: event.sequence, revision: revision)
                if let saved = next.drafts[key] {
                    var archived = thread.answerDrafts ?? [:]
                    archived[thread.currentRevision] = saved
                    thread.answerDrafts = archived
                }
            }
            for revision in thread.drafts.keys {
                guard var draft = thread.drafts[revision] else { continue }
                if case .saved = draft.disposition {
                    draft.disposition = .rejected(ExactText("Not delivered: request closed"))
                    thread.drafts[revision] = draft
                }
            }
            conversation.threads[key] = thread
        }
        next.conversation = conversation
    }

    public func applyRelayEvent(_ event: RelayEvent,
                                context suppliedContext: ProfileContext) -> ApplyEventResult {
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
            case .eventConflict:
                return .conflict
            default:
                return .repairRequired
            }
        } catch {
            return .repairRequired
        }
    }

    public func beginReplay(through highWaterSequence: UInt64,
                            context suppliedContext: ProfileContext) throws {
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
        try commit(next)
    }

    public func finishReplay(at resyncedSequence: UInt64,
                             context suppliedContext: ProfileContext) throws {
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
        try commit(next)
    }

    public func resolveOriginReference(sequence: UInt64,
                                       request: StoredRequest,
                                       context suppliedContext: ProfileContext) throws -> UInt64 {
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
        if let existing = next.requests[request.key] {
            guard existing.originalPayload.semanticallyEquals(request.originalPayload) else {
                throw AttentionStoreError.requestConflict
            }
        } else {
            next.requests[request.key] = request
            next.drafts[request.key] = RequestDraft(interface: request.interface)
        }
        next.appliedEvents[sequence] = RelayEvent(sequence: sequence, body: .originReference(request.key))
        next.remoteStates[request.key] = RemoteRequestState(state: next.remoteStates[request.key]?.state,
                                                            authorizedOriginAnswer: next.remoteStates[request.key]?.authorizedOriginAnswer,
                                                            classification: nil,
                                                            eventSequence: sequence)
        next.cursor = sequence
        next.repairIssues.removeAll { $0 == .missingOriginContent(sequence: sequence, requestKey: request.key) }
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
        let visibleKeys = Set(publishedRequests.keys)
        let visibleDrafts = state.drafts.filter { visibleKeys.contains($0.key) }
        let visibleSessions = state.fixtureSessions.filter { visibleKeys.contains($0.key) }
        let sortedOutbox = state.outboxOrder.compactMap { state.intents[$0] }
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
                                      conversationThreads: state.conversation?.threads ?? [:])
    }

    public func conversationSnapshot(context suppliedContext: ProfileContext) throws -> ConversationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let conversation = state.conversation ?? ConversationState()
        return ConversationSnapshot(cursor: conversation.cursor, threads: conversation.threads)
    }

    /// The conversation cursor commits in the same account transaction as its fact.
    /// Neither it nor its ACK can advance ordinary delivery/lifecycle replay.
    @discardableResult
    public func applyConversation(_ event: ConversationEvent, context suppliedContext: ProfileContext) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let event = try Self.externalizingConversationFiles(in: event,
            using: conversationFileReferences,
            allowInlinePersistence: persistence is MemoryAttentionStatePersistence)
        try validate(event.binding.request, in: context.identity)
        switch event.fact {
        case let .turn(turn), let .revision(turn, _), let .redactedRevision(turn): try validateConversationFiles(turn.files)
        default: break
        }
        var next = state
        var conversation = next.conversation ?? ConversationState()
        try conversation.apply(event)
        if conversation.cursor == state.conversation?.cursor { return conversation.cursor }
        let key = event.binding.request
        if let previous = state.conversation?.threads[key],
           let current = conversation.threads[key], current.currentRevision != previous.currentRevision {
            var archived = previous.answerDrafts ?? [:]
            if let draft = state.drafts[key] { archived[previous.currentRevision] = draft }
            conversation.threads[key]?.answerDrafts = archived
            if next.requests[key] != nil {
                let fresh = RequestDraft(interface: StoredRequest(key: key, originalPayload: current.currentQuestionPayload).interface)
                next.drafts[key] = fresh
                if var fixture = next.fixtureSessions[key], case .open = fixture.lifecycle {
                    fixture.draft = fresh
                    next.fixtureSessions[key] = fixture
                }
            }
            if current.terminal == nil, let id = next.intentByRequest[key], var intent = next.intents[id] {
                if case .accepted = intent.disposition { throw ConversationError.conflict }
                // An authoritative newer open question proves an earlier final answer did not close it.
                intent.disposition = .lost
                next.intents[id] = intent
                next.intentByRequest.removeValue(forKey: key)
                next.outboxOrder.removeAll { $0 == id }
            }
        }
        if case let .terminal(_, _, terminal) = event.fact, next.requests[key] != nil {
            let previous = next.remoteStates[key] ?? RemoteRequestState()
            guard previous.state == nil || previous.state == terminal else { throw ConversationError.conflict }
            next.remoteStates[key] = RemoteRequestState(state: terminal,
                authorizedOriginAnswer: previous.authorizedOriginAnswer, classification: previous.classification,
                eventSequence: previous.eventSequence)
            next.outboxOrder.removeAll { next.intents[$0]?.requestKey == key }
        }
        if case let .retraction(_, sequence) = event.fact, next.requests[key] != nil {
            // This projection references the one ordinary terminal. It closes
            // action locally without advancing or fabricating its ordinary cursor.
            let previous = next.remoteStates[key] ?? RemoteRequestState()
            guard previous.state == nil || previous.state == .cleared else { throw ConversationError.conflict }
            next.remoteStates[key] = RemoteRequestState(state: .cleared,
                authorizedOriginAnswer: previous.authorizedOriginAnswer, classification: previous.classification,
                eventSequence: sequence)
            if let saved = next.drafts[key], let revision = conversation.threads[key]?.currentRevision {
                var archived = conversation.threads[key]?.answerDrafts ?? [:]
                archived[revision] = saved
                conversation.threads[key]?.answerDrafts = archived
            }
            if let id = next.intentByRequest[key], var intent = next.intents[id] {
                if case .accepted = intent.disposition {} else {
                    intent.disposition = .terminal(state: .cleared, sequence: sequence,
                        authorizedAnswer: previous.authorizedOriginAnswer)
                    next.intents[id] = intent
                }
            }
            next.outboxOrder.removeAll { next.intents[$0]?.requestKey == key }
        }
        next.conversation = conversation
        try commit(next)
        return conversation.cursor
    }

    public func finishConversationReplay(at highWater: UInt64, context suppliedContext: ProfileContext) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let actual = state.conversation?.cursor ?? 0
        guard highWater == actual else {
            throw AttentionStoreError.replayIncomplete(expected: highWater, actual: actual)
        }
    }

    public func saveConversationDraft(_ draft: ConversationDraft, context suppliedContext: ProfileContext) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        let draft = try Self.externalizingConversationFiles(in: draft,
            using: conversationFileReferences,
            allowInlinePersistence: persistence is MemoryAttentionStatePersistence)
        try validate(draft.binding.request, in: context.identity)
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[draft.binding.request],
              thread.revisions[draft.binding.revision] != nil else { throw ConversationError.missingRequest }
        guard thread.terminal == nil else { throw ConversationError.closed }
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
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        try validate(binding.request, in: context.identity)
        var next = state
        guard var conversation = next.conversation,
              var thread = conversation.threads[binding.request],
              thread.revisions[binding.revision] != nil else { throw ConversationError.missingRequest }
        guard thread.terminal == nil else { throw ConversationError.closed }
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

    public func appendFixtureDiscussion(_ binding: ConversationBinding, context suppliedContext: ProfileContext) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        var next = state
        guard var conversation = next.conversation, let thread = conversation.threads[binding.request],
              let draft = thread.drafts[binding.revision] else { throw ConversationError.missingRequest }
        guard thread.terminal == nil else { throw ConversationError.closed }
        guard !draft.text.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.files.isEmpty else {
            throw ConversationError.emptyDraft
        }
        let turn = ConversationTurn(id: ExactText(UUID().uuidString.lowercased()), binding: binding,
            author: .person, sessionHandle: thread.sessionHandle, text: draft.text, files: draft.files)
        try conversation.apply(ConversationEvent(sequence: conversation.cursor + 1, binding: binding, fact: .turn(turn)))
        conversation.threads[binding.request]?.drafts.removeValue(forKey: binding.revision)
        next.conversation = conversation
        try commit(next)
    }

    /// A typed local upload example, with no delivery operation or transport.
    public func stageFixtureConversationUpload(_ file: ConversationFile, binding: ConversationBinding,
        text: ExactText, context suppliedContext: ProfileContext) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        let file = try Self.externalizingConversationFiles(in: file,
            using: conversationFileReferences,
            allowInlinePersistence: persistence is MemoryAttentionStatePersistence)
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
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[binding.request],
              var draft = thread.drafts[binding.revision] else { throw ConversationError.missingRequest }
        guard thread.terminal == nil else { throw ConversationError.closed }
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
        lock.lock()
        defer { lock.unlock() }
        try validate(suppliedContext)
        var next = state
        guard var conversation = next.conversation, var thread = conversation.threads[request] else { return [] }
        let committed = Set(thread.turns.compactMap(\.operationID))
        let groups = (thread.uploadGroups ?? [:]).values.filter { $0.cleanupID == nil && !committed.contains($0.operationID) }
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
                                        context suppliedContext: ProfileContext) throws {
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

    private func boundRequest(_ selector: BoundDocumentSelector,
                              context suppliedContext: ProfileContext) throws -> StoredRequest {
        guard selector.request.accountScope == context.identity.personID,
              let id = UUID(uuidString: selector.opaqueDocumentID.rawValue),
              let binding = selectorBindings[id],
              binding.profileGeneration == context.generation,
              binding.requestKey == selector.request,
              binding.requestRevision == state.conversation?.threads[selector.request]?.currentRevision,
              binding.opaqueSubmissionID == selector.opaqueSubmissionID else {
            throw AttentionStoreError.selectorExpired
        }
        guard let request = effectiveRequest(for: selector.request) else { throw AttentionStoreError.requestMissing }
        let currentFingerprint = fingerprint(request.answerDescription?.canonicalJSON ?? "")
        guard currentFingerprint == binding.descriptorFingerprint,
              fingerprint(submissionSignature(for: request.interface)) == binding.submissionFingerprint else {
            throw AttentionStoreError.selectorExpired
        }
        return request
    }

    private func effectiveRequest(for key: RequestKey) -> StoredRequest? {
        guard let original = state.requests[key] else { return nil }
        guard let thread = state.conversation?.threads[key] else { return original }
        let current = StoredRequest(key: key, originalPayload: thread.currentQuestionPayload)
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

    private func commit(_ proposed: PersistedAttentionState) throws {
        // File payloads are normalized when events and drafts enter the state,
        // and loaded state is normalized during initialization. Rewalking every
        // retained conversation value here makes an unrelated text edit grow
        // with conversation history.
        var next = proposed
        next.revision = state.revision &+ 1
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let bytes = try encoder.encode(next)
            try persistence.commit(bytes, identity: context.identity)
            state = next
            for observer in Array(changeObservers.values) {
                observer.yield(state.revision)
            }
        } catch {
            if let bytes = try? persistence.load(identity: context.identity),
               let recovered = try? PropertyListDecoder().decode(PersistedAttentionState.self, from: bytes),
               recovered.profileIdentity == context.identity,
               let normalized = try? Self.externalizingConversationFiles(in: recovered,
                    using: conversationFileReferences,
                    allowInlinePersistence: persistence is MemoryAttentionStatePersistence) {
                // A failed write may leave the prior on-disk plist in its legacy
                // inline form. Keep the in-memory invariant used by text-only
                // edits when recovering that older durable snapshot. This scan
                // runs only after a failed commit, never on the normal edit path.
                state = normalized
            }
            if let storeError = error as? AttentionStoreError { throw storeError }
            throw AttentionStoreError.persistence(error.localizedDescription)
        }
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
            contentRedacted: turn.contentRedacted, kind: turn.kind, resultStatus: turn.resultStatus)
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
        return ConversationEvent(sequence: event.sequence, binding: event.binding, fact: fact)
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
                terminalReason: old.terminalReason)
        }
        return RelayEvent(sequence: event.sequence, body: event.body, conversation: metadata)
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

    private static func externalizingConversationFiles(in state: PersistedAttentionState,
        using references: (any ConversationFileReferenceStore)?, allowInlinePersistence: Bool) throws -> PersistedAttentionState {
        var next = state
        next.appliedEvents = try state.appliedEvents.mapValues {
            try externalizingConversationFiles(in: $0, using: references, allowInlinePersistence: allowInlinePersistence)
        }
        if let oldConversation = state.conversation {
            var conversation = oldConversation
            conversation.events = try oldConversation.events.mapValues {
                try externalizingConversationFiles(in: $0, using: references, allowInlinePersistence: allowInlinePersistence)
            }
            conversation.threads = try oldConversation.threads.mapValues {
                try externalizingConversationFiles(in: $0, using: references, allowInlinePersistence: allowInlinePersistence)
            }
            next.conversation = conversation
        }
        return next
    }

    private func recordRepair(_ issue: StoreRepairIssue) throws {
        guard !state.repairIssues.contains(issue) else { return }
        var next = state
        next.repairIssues.append(issue)
        try commit(next)
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
        switch (request.interface, typedSubmission) {
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

    private func relayAnswerOperation(request: StoredRequest, answer: JSONValue, operationID: UUID, requestRevision: UInt64?) -> JSONValue {
        var members = [
            JSONMember("v", .number(JSONNumber(lexeme: "1"))),
            JSONMember("type", .string(ExactText("answer"))),
            JSONMember("op_id", .string(ExactText(operationID.uuidString.lowercased()))),
            JSONMember("sender_id", .string(request.key.senderID)),
            JSONMember("message_id", .string(request.key.messageID)),
            JSONMember("answer", answer)
        ]
        if let requestRevision { members.append(JSONMember("request_revision", .number(JSONNumber(lexeme: String(requestRevision))))) }
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
    let requestRevision: UInt64?
    let requestKey: RequestKey
    let profileGeneration: UUID
    let descriptorFingerprint: String
    let submissionFingerprint: String
    let opaqueSubmissionID: ExactText
}

private struct PersistedAttentionState: Codable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let profileIdentity: ProfileIdentity
    var revision: UInt64 = 0
    var requests: [RequestKey: StoredRequest] = [:]
    var drafts: [RequestKey: RequestDraft] = [:]
    var fixtureSessions: [RequestKey: RequestSession] = [:]
    var intents: [UUID: Submission] = [:]
    // Optional permits decoding older schema-2 profile files unchanged.
    var fencedIntents: [UUID: RequestKey]? = nil
    var intentByRequest: [RequestKey: UUID] = [:]
    var outboxOrder: [UUID] = []
    var remoteStates: [RequestKey: RemoteRequestState] = [:]
    var appliedEvents: [UInt64: RelayEvent] = [:]
    var cursor: UInt64 = 0
    var replayBarrier: UInt64?
    var replayPublishedRequests: [RequestKey: StoredRequest]?
    var replayPublishedStates: [RequestKey: RemoteRequestState]?
    var replayPublishedIntents: [UUID: Submission]?
    var repairIssues: [StoreRepairIssue] = []
    // Optional keeps existing schema-2 account files readable without resetting their data.
    var conversation: ConversationState?

    init(profileIdentity: ProfileIdentity) {
        self.schemaVersion = Self.currentSchemaVersion
        self.profileIdentity = profileIdentity
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
