import AttentionDomain
import Foundation
import Observation
import HarklightNativeRelay
import XCTest
@testable import Harklight

/// Uses the real cache restore, paging core and presentation refresh seam.
/// No transport, certificate, account enrollment or historical fixture is used.
@MainActor
final class CacheBackedActionEligibilityTests: XCTestCase {
    func testColdCacheSeenTapQueuesWhileCatchUpIsActive() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("cold-cache-seen-\(UUID().uuidString)"), deviceID: ExactText("test-installation"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("seen"))
        let payload = try JSONValue.parse(Data(#"{"title":"Information","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        let previous = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        _ = try previous.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let saved = try previous.snapshot(context: context)
        let domain = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        try domain.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: saved.requests, remoteStates: [:], cursor: 1, conversationCursor: 0,
            conversations: [:], inboxView: nil, currentRequestKeys: []), context: context)
        let live = try LivePresentationStore(store: domain, context: context)
        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.informationalSeenStatus, .available)
        live.beginRefresh()
        defer { live.endRefresh() }
        XCTAssertTrue(live.isRefreshing)
        XCTAssertFalse(request.inboxStateIsCurrent)
        XCTAssertTrue(live.canSendToCurrentServer)
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).canMarkSeen)
        var dismissals = 0
        LiveRequestDetail(request: request, store: live).finishSeenAction(ExactText("seen")) {
            dismissals += 1
        }
        let queued = try domain.snapshot(context: context)
        XCTAssertEqual(queued.intents.count, 1, "The tap persists its intent before catch-up finishes.")
        XCTAssertNotNil(live.request(for: key)?.intentReceipt)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(dismissals, 1, "Local acceptance completes the tap while Server confirmation stays pending.")
        XCTAssertTrue(live.isRefreshing)
        XCTAssertNil(queued.remoteStates[key], "Local acceptance cannot invent a Server terminal.")
    }

    func testColdCacheReplyShowsItsPendingTextAndAllowsSameOperationRetry() throws {
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("pending-reply"), deviceID: ExactText("device")), transportMode: .relay)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"),
                             messageID: ExactText("reply"))
        let reply = ExactText("reply")
        let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        // A saved cache holds requests as the Server accepted them, with their acceptance order.
        let previous = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        _ = try previous.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let saved = try previous.snapshot(context: context)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try domain.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: saved.requests, remoteStates: [:], cursor: 1,
            conversationCursor: 0, conversations: [:], inboxView: nil, currentRequestKeys: []), context: context)
        let port = AttentionDomainPort(store: domain)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
            inputs: [.compatibilityText(action: reply, text: ExactText("My pending reply"))]))
        let live = try LivePresentationStore(store: domain, context: context)
        live.beginRefresh()
        defer { live.endRefresh() }
        let pending = try XCTUnwrap(live.request(for: key))
        XCTAssertFalse(pending.inboxStateIsCurrent)
        XCTAssertEqual(pending.lifecycleStatus, .pending)
        XCTAssertEqual(live.submissionPhases[key]?.phase, .sending)
        XCTAssertEqual(pending.submittedAnswer?.compatibility.textByActionID[reply], ExactText("My pending reply"),
                       "The sending control keeps showing the queued reply during catch-up.")
        XCTAssertEqual(pending.receiptFacts?.ownOutcome, .unconfirmed,
                       "A queued reply is not shown as Server-confirmed.")
        XCTAssertFalse(LiveRequestDetail.answerStatusIsComplete(lifecycleStatus: pending.lifecycleStatus,
            ownOutcome: pending.receiptFacts?.ownOutcome, answerNotDelivered: false))

        try domain.recordAnswerNotDelivered(receipt.intentID, operationID: receipt.opID, context: context)
        try live.refreshFromDurableStore()
        let failed = try XCTUnwrap(live.submissionPhases[key])
        XCTAssertEqual(failed.phase, .failed(retryable: true, editable: true))
        XCTAssertEqual(failed.operationID, receipt.opID, "Retry offers the original operation.")
        XCTAssertEqual(live.request(for: key)?.failedAnswer?.compatibility.textByActionID[reply],
                       ExactText("My pending reply"))
        let retry = try domain.queueOriginalOperationForUserTap(receipt.intentID, context: context)
        XCTAssertEqual(retry.operationID, receipt.opID)

        try domain.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
            terminalSequence: 2, context: context)
        try live.refreshFromDurableStore()
        let accepted = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(live.submissionPhases[key]?.phase, .confirmed)
        XCTAssertTrue(LiveRequestDetail(request: accepted, store: live).isDurablyAccepted(.answer),
                      "Durable Server acceptance is the reply's confirmation.")
        XCTAssertFalse(LiveRequestDetail.answerStatusIsComplete(lifecycleStatus: accepted.lifecycleStatus,
            ownOutcome: accepted.receiptFacts?.ownOutcome, answerNotDelivered: false),
                       "The request's final state still comes only from the Server.")
    }







    private struct Scenario {
        let live: LivePresentationStore
        let seen: RequestKey
        let reply: RequestKey
    }

}
