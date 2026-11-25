import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest

final class OperationRecoveryTests: XCTestCase {

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
        for reason in ["closed", "not_found"] {
            let expected: IntentDisposition = reason == "closed" ? .refusedClosed : .refusedNotFound
            let (context, key, payload) = try fixture()
            let persistence = MemoryPendingActionPersistence()
            let first = try ClientRepository(context: context, persistence: persistence)
            try confirm(first, context: context, key: key, payload: payload)
            let original = try submit(first, context: context, key: key)
            try first.recordUnresolvedOperation(original.intentID,
                operationID: original.operationID, context: context)
            try first.recordAnswerRefusedClosed(original.intentID,
                operationID: original.operationID, requestNotFound: reason != "closed", context: context)
            let restarted = try ClientRepository(context: context, persistence: persistence)
            try restarted.queueRecoverableOperations(context: context)
            XCTAssertTrue(try restarted.snapshot(context: context).outbox.isEmpty)
            XCTAssertTrue(try restarted.inboxOperationInventory(context: context).isEmpty)
            XCTAssertEqual(try restarted.lookupIntent(original.intentID, context: context)?.disposition,
                           expected)
            XCTAssertThrowsError(try restarted.queueOriginalOperationForUserTap(original.intentID,
                context: context), "A definitive closure cannot succeed on Retry.")
            XCTAssertNil(try restarted.snapshot(context: context).remoteStates[key],
                         "The refusal must not invent an answered, expired or retracted final state.")
            try confirm(restarted, context: context, key: key, payload: payload)
            let port = AttentionDomainPort(store: restarted)
            let shown = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first)
            XCTAssertEqual(shown.intentReceipt?.localState, reason == "closed" ? .refusedClosed : .refusedNotFound)
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
        try restarted.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: [:], remoteStates: [:], cursor: 1, conversationCursor: 0,
            conversations: [:], inboxView: nil, currentRequestKeys: []), context: context)
        try restarted.queueRecoverableOperations(context: context)
        let recovered = try XCTUnwrap(restarted.snapshot(context: context).outbox.first)
        XCTAssertEqual(recovered.operationID, original.operationID)
        XCTAssertEqual(recovered.wireFrame, original.wireFrame)
        let again = try ClientRepository(context: context, persistence: persistence)
        XCTAssertEqual(try again.lookupIntent(original.intentID, context: context)?.operationID,
                       original.operationID)
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
        let model = ServerModelV2Store(fileURL: nil)
        try model.apply([v2CacheItem(key, message: payload, revision: 1)], cursor: 1,
                        onUnreadable: { _, error in throw error })
        try repository.restoreCachedServerState(
            ServerModelV2Projection.cachedState(model.snapshot, identity: context.identity), context: context)
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
