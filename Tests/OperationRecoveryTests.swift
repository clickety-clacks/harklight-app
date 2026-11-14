import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest

final class OperationRecoveryTests: XCTestCase {
    func testReplayCoreReplacementDoesNotCancelIndependentOriginalOperation() async throws {
        let (context, key, payload) = try fixture()
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try confirm(store, context: context, key: key, payload: payload)
        let original = try submit(store, context: context, key: key)
        let sent = expectation(description: "Original operation reached its independent transport")
        let session = HeldRecoveryOperationSession(identity: context.identity, sent: sent)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileServerStateCache(identity: context.identity,
            fileURL: directory.appendingPathComponent("cache.json"))
        let replayCore = try NativeRelayCore(store: store, context: context, session: session,
            automaticallySendsPendingOperations: false, serverStateCache: cache)
        let mutationCore = try NativeRelayCore(store: store, context: context, session: session,
            automaticallySendsPendingOperations: false, serverStateCache: cache)
        let delivery = Task {
            try await mutationCore.sendOriginalOperationForUserTap(original.intentID, using: session)
        }
        await fulfillment(of: [sent], timeout: 5)
        await replayCore.deactivate()
        await session.accept(operation: original.operationID)
        try await delivery.value
        let frames = await session.frames
        XCTAssertEqual(frames, [original.wireFrame])
        XCTAssertEqual(try store.lookupIntent(original.intentID, context: context)?.operationID, original.operationID)
        XCTAssertEqual(try store.acceptedOperationsAwaitingTerminalReplay(context: context).map(\.operationID),
                       [original.operationID])
        XCTAssertNil(try store.snapshot(context: context).remoteStates[key],
                     "Acceptance stays pending until an actual Server terminal arrives.")
        await mutationCore.deactivate()
    }

    func testInterruptedOperationQueuesExactFrameBeforeReplayAfterRestart() throws {
        for lostReply in [false, true] {
            let (context, key, payload) = try fixture()
            let persistence = MemoryPendingActionPersistence()
            let first = try ClientRepository(context: context, persistence: persistence)
            try confirm(first, context: context, key: key, payload: payload)
            let original = try submit(first, context: context, key: key)
            _ = try first.queueOriginalOperationForUserTap(original.intentID, context: context)
            if lostReply {
                try first.recordUnresolvedOperation(original.intentID,
                    operationID: original.operationID, context: context)
            }
            let restarted = try ClientRepository(context: context, persistence: persistence)
            XCTAssertEqual(try restarted.inboxOperationInventory(context: context).map(\.operationID),
                           [original.operationID], "Reconciliation must not depend on a populated send queue.")
            try restarted.queueRecoverableOperations(context: context)
            XCTAssertEqual(try restarted.snapshot(context: context).outbox.map(\.operationID),
                           [original.operationID], "Recovery cannot depend on replay or its ACK.")
            XCTAssertTrue(try restarted.snapshot(context: context).requests.isEmpty,
                          "This check exercises recovery before Server pages are restored.")
            try restarted.queueRecoverableOperations(context: context)
            try restarted.queueRecoverableOperations(context: context)
            let queued = try restarted.snapshot(context: context).outbox
            XCTAssertEqual(queued.count, 1)
            XCTAssertEqual(queued.first?.intentID, original.intentID)
            XCTAssertEqual(queued.first?.operationID, original.operationID)
            XCTAssertEqual(queued.first?.wireFrame, original.wireFrame)
        }
    }

    func testDefinitiveFailureSurvivesRestartAndOnlyExplicitRetryQueuesSameOperation() throws {
        let (context, key, payload) = try fixture()
        let persistence = MemoryPendingActionPersistence()
        let first = try ClientRepository(context: context, persistence: persistence)
        try confirm(first, context: context, key: key, payload: payload)
        let original = try submit(first, context: context, key: key)
        try first.recordAnswerNotDelivered(original.intentID,
            operationID: original.operationID, context: context)
        let restarted = try ClientRepository(context: context, persistence: persistence)
        try confirm(restarted, context: context, key: key, payload: payload)
        try restarted.queueRecoverableOperations(context: context)
        XCTAssertTrue(try restarted.snapshot(context: context).outbox.isEmpty)
        XCTAssertEqual(try restarted.lookupIntent(original.intentID, context: context)?.disposition, .failed)
        let retry = try restarted.queueOriginalOperationForUserTap(original.intentID, context: context)
        XCTAssertEqual(retry.operationID, original.operationID)
        XCTAssertEqual(retry.wireFrame, original.wireFrame)
        XCTAssertEqual(try restarted.snapshot(context: context).outbox.count, 1)
    }

    func testClosedRefusalSurvivesRestartAndCannotBeRetriedBeforeReplay() throws {
        for reconciled in [false, true] {
            let (context, key, payload) = try fixture()
            let persistence = MemoryPendingActionPersistence()
            let first = try ClientRepository(context: context, persistence: persistence)
            try confirm(first, context: context, key: key, payload: payload)
            let original = try submit(first, context: context, key: key)
            try first.recordUnresolvedOperation(original.intentID,
                operationID: original.operationID, context: context)
            if reconciled {
                let batch = InboxReceiptBatch(batchID: "closed", operationIDs: [original.operationID])
                _ = try first.beginInboxCandidate(startupID: "closed", since: 1,
                    batches: [batch], context: context)
                try first.saveInboxInitialPage(snapshotID: "closed", highWater: 1,
                    items: [], nextCursor: nil, receiptCursor: nil, context: context)
                try first.saveInboxReceiptBatch(batch.batchID, results: [InboxOperationReceipt(
                    operationID: original.operationID, status: .refused, reason: "closed")], context: context)
            } else {
                try first.recordAnswerRefusedClosed(original.intentID,
                    operationID: original.operationID, context: context)
            }
            let restarted = try ClientRepository(context: context, persistence: persistence)
            try restarted.queueRecoverableOperations(context: context)
            XCTAssertTrue(try restarted.snapshot(context: context).outbox.isEmpty)
            XCTAssertTrue(try restarted.inboxOperationInventory(context: context).isEmpty)
            XCTAssertEqual(try restarted.lookupIntent(original.intentID, context: context)?.disposition,
                           .refusedClosed)
            XCTAssertThrowsError(try restarted.queueOriginalOperationForUserTap(original.intentID,
                context: context), "A definitive closure cannot succeed on Retry.")
            XCTAssertNil(try restarted.snapshot(context: context).remoteStates[key],
                         "The refusal must not invent an answered, expired or retracted final state.")
            try confirm(restarted, context: context, key: key, payload: payload)
            let port = AttentionDomainPort(store: restarted)
            let shown = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first)
            XCTAssertEqual(shown.intentReceipt?.localState, .refusedClosed)
            XCTAssertEqual(shown.receiptFacts?.ownOutcome, .refused)
            XCTAssertNotEqual(shown.lifecycleStatus, .answered)
        }
    }

    func testAcceptedOperationSurvivesRestartAsReceiptWithoutResending() throws {
        let (context, key, payload) = try fixture()
        let persistence = MemoryPendingActionPersistence()
        let first = try ClientRepository(context: context, persistence: persistence)
        try confirm(first, context: context, key: key, payload: payload)
        let original = try submit(first, context: context, key: key)
        try first.recordAcceptedOperation(original.intentID, operationID: original.operationID,
            terminalSequence: 2, context: context)
        let restarted = try ClientRepository(context: context, persistence: persistence)
        XCTAssertEqual(try restarted.acceptedOperationsAwaitingTerminalReplay(context: context).map(\.operationID),
                       [original.operationID])
        XCTAssertEqual(try restarted.inboxOperationInventory(context: context).map(\.operationID),
                       [original.operationID])
        try confirm(restarted, context: context, key: key, payload: payload)
        try restarted.queueRecoverableOperations(context: context)
        XCTAssertTrue(try restarted.snapshot(context: context).outbox.isEmpty,
                      "Accepted receipt waits for the actual Server terminal rather than sending again.")
        XCTAssertEqual(try restarted.lookupIntent(original.intentID, context: context)?.wireFrame,
                       original.wireFrame)
    }

    func testEmptySnapshotDoesNotDeleteUnresolvedUserOperation() throws {
        let (context, key, payload) = try fixture()
        let persistence = MemoryPendingActionPersistence()
        let first = try ClientRepository(context: context, persistence: persistence)
        try confirm(first, context: context, key: key, payload: payload)
        let original = try submit(first, context: context, key: key)
        let restarted = try ClientRepository(context: context, persistence: persistence)
        let batch = InboxReceiptBatch(batchID: "pending", operationIDs: [original.operationID])
        _ = try restarted.beginInboxCandidate(startupID: "empty", since: 0,
            batches: [batch], context: context)
        try restarted.saveInboxInitialPage(snapshotID: "empty", highWater: 1, items: [],
            nextCursor: nil, receiptCursor: nil, context: context)
        try restarted.saveInboxReceiptBatch(batch.batchID, results: [InboxOperationReceipt(
            operationID: original.operationID, status: .notCommittedAtSnapshot)], context: context)
        _ = try restarted.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try restarted.acceptInboxCheckpoint(snapshotID: "empty", highWater: 1, context: context)
        try restarted.queueRecoverableOperations(context: context)
        let recovered = try XCTUnwrap(restarted.snapshot(context: context).outbox.first)
        XCTAssertEqual(recovered.operationID, original.operationID)
        XCTAssertEqual(recovered.wireFrame, original.wireFrame)
        let again = try ClientRepository(context: context, persistence: persistence)
        XCTAssertEqual(try again.lookupIntent(original.intentID, context: context)?.operationID,
                       original.operationID)
    }

    func testSendAcceptedDuringFrozenSnapshotKeepsItsLaterReceipt() throws {
        let (context, key, payload) = try fixture()
        let persistence = MemoryPendingActionPersistence()
        let first = try ClientRepository(context: context, persistence: persistence)
        try confirm(first, context: context, key: key, payload: payload)
        let original = try submit(first, context: context, key: key)
        let restarted = try ClientRepository(context: context, persistence: persistence)
        let batch = InboxReceiptBatch(batchID: "in-flight", operationIDs: [original.operationID])
        _ = try restarted.beginInboxCandidate(startupID: "frozen", since: 0,
            batches: [batch], context: context)
        try restarted.saveInboxInitialPage(snapshotID: "frozen", highWater: 1,
            items: [InboxSnapshotItem(acceptance: RelayEvent(sequence: 1,
                body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)))],
            nextCursor: nil, receiptCursor: nil, context: context)
        try restarted.recordAcceptedOperation(original.intentID, operationID: original.operationID,
            terminalSequence: 2, context: context)
        try restarted.saveInboxReceiptBatch(batch.batchID, results: [InboxOperationReceipt(
            operationID: original.operationID, status: .notCommittedAtSnapshot)], context: context)
        _ = try restarted.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try restarted.acceptInboxCheckpoint(snapshotID: "frozen", highWater: 1, context: context)
        try restarted.queueRecoverableOperations(context: context)
        let snapshot = try restarted.snapshot(context: context)
        XCTAssertEqual(snapshot.cursor, 1, "A send response cannot advance the replay cursor.")
        XCTAssertEqual(snapshot.intents[original.intentID]?.disposition, .accepted(sequence: 2))
        XCTAssertTrue(snapshot.outbox.isEmpty, "An accepted operation waits for its later Server terminal.")
    }

    func testReplayInProgressDoesNotBlockNewAnswerOrHideItsPendingIntent() throws {
        let (context, key, payload) = try fixture()
        let persistence = MemoryPendingActionPersistence()
        let repository = try ClientRepository(context: context, persistence: persistence)
        try confirm(repository, context: context, key: key, payload: payload)
        try repository.beginReplay(through: UInt64.max, context: context)
        let operation = try submit(repository, context: context, key: key)
        let visible = try repository.snapshot(context: context)
        XCTAssertNotNil(visible.replayBarrier)
        XCTAssertEqual(visible.intents[operation.intentID]?.disposition, .pending,
                       "Local pending state appears while Server replay is still in progress.")
        let queued = try repository.queueOriginalOperationForUserTap(operation.intentID, context: context)
        XCTAssertEqual(queued.operationID, operation.operationID)
        XCTAssertEqual(queued.wireFrame, operation.wireFrame)
        let restarted = try ClientRepository(context: context, persistence: persistence)
        XCTAssertEqual(try restarted.lookupIntent(operation.intentID, context: context)?.wireFrame,
                       operation.wireFrame)
    }

    func testReplayInProgressDoesNotBlockNoCommentAcceptance() throws {
        let (context, key, payload) = try fixture()
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try confirm(repository, context: context, key: key, payload: payload)
        let port = AttentionDomainPort(store: repository)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        try repository.beginReplay(through: UInt64.max, context: context)
        let receipt = try port.submitNoComment(context: port.context, selector: selector, intentID: UUID())
        XCTAssertEqual(try repository.snapshot(context: context).intents[receipt.intentID]?.disposition, .pending)
        XCTAssertNotNil(try repository.snapshot(context: context).replayBarrier)
    }

    private func fixture() throws -> (ProfileContext, RequestKey, JSONValue) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("request"))
        let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":true}]}}"#.utf8))
        return (context, key, payload)
    }

    private func confirm(_ repository: ClientRepository, context: ProfileContext,
                         key: RequestKey, payload: JSONValue) throws {
        let snapshot = UUID().uuidString
        let inventory = try repository.inboxOperationInventory(context: context)
        let batches = inventory.isEmpty ? [] : [InboxReceiptBatch(batchID: "saved-operations",
            operationIDs: inventory.map(\.operationID))]
        _ = try repository.beginInboxCandidate(startupID: snapshot, since: 0, batches: batches, context: context)
        try repository.saveInboxInitialPage(snapshotID: snapshot, highWater: 1,
            items: [InboxSnapshotItem(acceptance: RelayEvent(sequence: 1,
                body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)))],
            nextCursor: nil, receiptCursor: nil, context: context)
        if let batch = batches.first {
            try repository.saveInboxReceiptBatch(batch.batchID, results: inventory.map {
                InboxOperationReceipt(operationID: $0.operationID, status: .notCommittedAtSnapshot)
            }, context: context)
        }
        _ = try repository.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try repository.acceptInboxCheckpoint(snapshotID: snapshot, highWater: 1, context: context)
    }

    private func submit(_ repository: ClientRepository, context: ProfileContext,
                        key: RequestKey) throws -> Submission {
        let port = AttentionDomainPort(store: repository)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        return try XCTUnwrap(repository.lookupIntent(receipt.intentID, context: context))
    }
}

private actor HeldRecoveryOperationSession: AuthenticatedInstallationSession {
    nonisolated let authenticatedIdentity: ProfileIdentity
    let sent: XCTestExpectation
    private var result: CheckedContinuation<OriginalOperationResult, Never>?
    private(set) var frames: [Data] = []

    init(identity: ProfileIdentity, sent: XCTestExpectation) {
        authenticatedIdentity = identity
        self.sent = sent
    }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        throw InstallationTransportError.unexpectedServerFrame
    }
    func acknowledge(_ request: Data) async throws {
        throw InstallationTransportError.unexpectedServerFrame
    }
    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        frames.append(frame)
        return await withCheckedContinuation { continuation in
            result = continuation
            sent.fulfill()
        }
    }
    func accept(operation: UUID) {
        result?.resume(returning: .accepted(operationID: operation, terminalSequence: 2))
        result = nil
    }
}
