import AttentionDomain
import Foundation
import XCTest

final class OperationRecoveryTests: XCTestCase {
    func testInterruptedOperationWaitsForCurrentServerThenQueuesExactFrameAfterRestart() throws {
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
            try restarted.queueRecoverableOperations(context: context)
            XCTAssertTrue(try restarted.snapshot(context: context).outbox.isEmpty,
                          "Saved intent alone cannot authorize sending against stale Server state.")
            try confirm(restarted, context: context, key: key, payload: payload)
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
        try confirm(restarted, context: context, key: key, payload: payload)
        try restarted.queueRecoverableOperations(context: context)
        XCTAssertTrue(try restarted.snapshot(context: context).outbox.isEmpty,
                      "Accepted receipt waits for the actual Server terminal rather than sending again.")
        XCTAssertEqual(try restarted.lookupIntent(original.intentID, context: context)?.wireFrame,
                       original.wireFrame)
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
        _ = try repository.beginInboxCandidate(startupID: snapshot, since: 0, batches: [], context: context)
        try repository.saveInboxInitialPage(snapshotID: snapshot, highWater: 1,
            items: [InboxSnapshotItem(acceptance: RelayEvent(sequence: 1,
                body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)))],
            nextCursor: nil, receiptCursor: nil, context: context)
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
