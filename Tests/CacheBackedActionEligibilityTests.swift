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
            conversations: [:], inboxView: nil, currentRequestKeys: [key]), context: context)
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
        let payload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        try domain.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: [key: StoredRequest(key: key, originalPayload: payload)], remoteStates: [:], cursor: 1,
            conversationCursor: 0, conversations: [:], inboxView: nil, currentRequestKeys: [key]), context: context)
        let port = AttentionDomainPort(store: domain)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
            inputs: [.compatibilityText(action: ExactText("reply"), text: ExactText("My pending reply"))]))
        let live = try LivePresentationStore(store: domain, context: context)
        live.beginRefresh()
        defer { live.endRefresh() }
        let pending = try XCTUnwrap(live.request(for: key))
        XCTAssertFalse(pending.inboxStateIsCurrent)
        let detail = LiveRequestDetail(request: pending, store: live)
        XCTAssertTrue(detail.showsPendingAnswerConfirmation)
        XCTAssertEqual(detail.pendingAnswerText, "My pending reply")
        XCTAssertFalse(LiveRequestDetail.answerStatusIsComplete(lifecycleStatus: pending.lifecycleStatus,
            ownOutcome: pending.receiptFacts?.ownOutcome, answerNotDelivered: false))
        try domain.recordAnswerNotDelivered(receipt.intentID, operationID: receipt.opID, context: context)
        try live.refreshFromDurableStore()
        XCTAssertTrue(live.canRetryUnconfirmedAnswer(for: key))
        XCTAssertEqual(live.request(for: key)?.intentReceipt?.opID, receipt.opID)
        let retry = try domain.queueOriginalOperationForUserTap(receipt.intentID, context: context)
        XCTAssertEqual(retry.operationID, receipt.opID)
        try domain.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
            terminalSequence: 2, context: context)
        try live.refreshFromDurableStore()
        let accepted = try XCTUnwrap(live.request(for: key))
        let acceptedDetail = LiveRequestDetail(request: accepted, store: live)
        XCTAssertTrue(acceptedDetail.showsPendingAnswerConfirmation)
        XCTAssertEqual(acceptedDetail.pendingAnswerText, "My pending reply")
        XCTAssertFalse(LiveRequestDetail.answerStatusIsComplete(lifecycleStatus: accepted.lifecycleStatus,
            ownOutcome: accepted.receiptFacts?.ownOutcome, answerNotDelivered: false))
    }

    func testConfirmedCacheBackedRefreshEnablesSeenRow() async throws {
        try await withConfirmedColdLaunch { scenario in
            let row = try XCTUnwrap(scenario.live.inboxRows.first { $0.key == scenario.seen })
            XCTAssertEqual(row.informationalSeenStatus, .available)
            XCTAssertTrue(row.canMarkSeen,
                          "A confirmed current open Seen request must offer its row action.")
        }
    }

    func testConfirmedCacheBackedRefreshEnablesNoCommentAndReplySubmission() async throws {
        try await withConfirmedColdLaunch { scenario in
            let request = try XCTUnwrap(scenario.live.request(for: scenario.reply))
            let row = try XCTUnwrap(scenario.live.inboxRows.first { $0.key == scenario.reply })
            XCTAssertTrue(row.canNoComment,
                          "A confirmed current open reply request must offer No comment.")
            let session = scenario.live.replyEditorSession(for: request)
            session.selectAction(ExactText("reply"), inputID: nil)
            session.updateText("A deliberate test reply", target: ReplyEditorTarget(inputID: nil, actionID: "reply"))
            XCTAssertTrue(session.canSubmitFromSnapshot)
            XCTAssertTrue(scenario.live.canSendToCurrentServer,
                          "Server permission is the remaining checkmark eligibility condition for this current valid draft.")
            XCTAssertTrue(LiveRequestDetail(request: request, store: scenario.live).canSubmitCurrentAnswer,
                          "The actual checkmark availability predicate must enable a confirmed valid reply.")
        }
    }

    func testRefreshingConfirmedInboxKeepsSeenAndReplyActionsAvailable() async throws {
        try await withConfirmedColdLaunch { scenario in
            scenario.live.beginRefresh()
            defer { scenario.live.endRefresh() }
            XCTAssertTrue(scenario.live.isRefreshing)
            XCTAssertTrue(scenario.live.canSendToCurrentServer,
                          "Refreshing must not hide actions on an already confirmed current inbox.")
            XCTAssertTrue(try XCTUnwrap(scenario.live.inboxRows.first { $0.key == scenario.seen }).canMarkSeen)
            XCTAssertTrue(try XCTUnwrap(scenario.live.inboxRows.first { $0.key == scenario.reply }).canNoComment)
            let request = try XCTUnwrap(scenario.live.request(for: scenario.reply))
            let session = scenario.live.replyEditorSession(for: request)
            session.selectAction(ExactText("reply"), inputID: nil)
            session.updateText("An answer during refresh", target: ReplyEditorTarget(inputID: nil, actionID: "reply"))
            XCTAssertTrue(LiveRequestDetail(request: request, store: scenario.live).canSubmitCurrentAnswer)
        }
    }

    func testConnectionInvalidationKeepsApplicableActionsAvailable() async throws {
        let scenario = try await confirmedColdLaunch()
        await NativeRelayLifecycle.shared.deactivate()
        XCTAssertTrue(scenario.live.canSendToCurrentServer)
        XCTAssertTrue(try XCTUnwrap(scenario.live.inboxRows.first { $0.key == scenario.seen }).canMarkSeen)
        XCTAssertTrue(try XCTUnwrap(scenario.live.inboxRows.first { $0.key == scenario.reply }).canNoComment)
        XCTAssertTrue(scenario.live.submitFromUser(scenario.seen, explicitCompatibilityAction: ExactText("seen")))
        XCTAssertNotNil(scenario.live.request(for: scenario.seen)?.intentReceipt)
    }

    func testBackgroundRefreshFailureIsVisibleWithoutViewOwnedRefresh() async throws {
        let scenario = try await confirmedColdLaunch()
        // The in-process session has no reconnect credentials. This exercises
        // the ordinary refresh failure path without touching an enrolled account.
        let refreshed = await NativeRelayLifecycle.shared.refreshFromTrustedRelay()
        XCTAssertFalse(refreshed)
        XCTAssertFalse(scenario.live.isRefreshing)
        XCTAssertTrue(scenario.live.canSendToCurrentServer)
        XCTAssertNotNil(scenario.live.connectionWarning,
                        "A push-owned refresh failure must reach the UI even without applyRefreshResult.")
        XCTAssertTrue(scenario.live.submitFromUser(scenario.seen, explicitCompatibilityAction: ExactText("seen")))
        XCTAssertNil(scenario.live.actionError)
        await NativeRelayLifecycle.shared.deactivate()
    }

    private func withConfirmedColdLaunch(_ check: (Scenario) throws -> Void) async throws {
        await NativeRelayLifecycle.shared.deactivate()
        do {
            let scenario = try await confirmedColdLaunch()
            try check(scenario)
            await NativeRelayLifecycle.shared.deactivate()
        } catch {
            await NativeRelayLifecycle.shared.deactivate()
            throw error
        }
    }

    private struct Scenario {
        let live: LivePresentationStore
        let seen: RequestKey
        let reply: RequestKey
    }

    private func confirmedColdLaunch() async throws -> Scenario {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("cache-actions-\(UUID().uuidString)"),
            deviceID: ExactText("test-installation")), transportMode: .relay)
        let seen = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("seen"))
        let reply = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("reply"))
        let seenPayload = try JSONValue.parse(Data(#"{"title":"Information","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        let replyPayload = try JSONValue.parse(Data(#"{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        let previousLaunch = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        for (index, item) in [(seen, seenPayload), (reply, replyPayload)].enumerated() {
            _ = try previousLaunch.apply(RelayEvent(sequence: UInt64(index + 1),
                body: .delivery(StoredRequest(key: item.0, originalPayload: item.1), .message)),
                context: context)
        }
        let requests = try previousLaunch.snapshot(context: context).requests
        let domain = try ClientRepository(context: context,
            persistence: MemoryPendingActionPersistence())
        try domain.restoreCachedServerState(CachedAttentionServerState(identity: context.identity,
            requests: requests, remoteStates: [:], cursor: 2, conversationCursor: 0,
            conversations: [:], inboxView: nil, currentRequestKeys: [seen, reply]), context: context)
        let live = try LivePresentationStore(store: domain, context: context)
        XCTAssertTrue(live.canSendToCurrentServer, "Catch-up does not gate an applicable local intent.")
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == seen }).canMarkSeen)
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == reply }).canNoComment)
        let relay = CacheActionRelayDouble(identity: context.identity, messages: [
            ("seen", seenPayload), ("reply", replyPayload)
        ])
        let namespace = "Harklight.cache-actions." + UUID().uuidString
        let launch = NativeAppLaunch(arguments: [],
            enrollmentStore: NativeEnrollmentStore(service: namespace),
            joinStore: NativeGuidedJoinStore(namespace: namespace + ".join"),
            initialState: .live(live), refreshOperation: { _ in
            do {
                let result = try await NativeRelayLifecycle.shared.confirmInProcessSessionForTesting(
                    store: domain, context: context, session: relay, serverStateCache: FileServerStateCache(identity: context.identity))
                try live.refreshFromDurableStore()
                return result
            } catch {
                XCTFail("In-process relay did not confirm: \(error)")
                return .failed(error: error)
            }
        })
        await launch.refreshLive()
        XCTAssertTrue(relay.checkpointAccepted, "The positive assertions require a real core checkpoint acceptance.")
        XCTAssertFalse(live.isRefreshing)
        XCTAssertNil(live.connectionWarning)
        for key in [seen, reply] {
            let request = try XCTUnwrap(live.request(for: key))
            XCTAssertTrue(request.inboxStateIsCurrent)
            XCTAssertEqual(request.lifecycleStatus, .open)
            XCTAssertNil(request.intentReceipt)
        }
        return Scenario(live: live, seen: seen, reply: reply)
    }
}

private final class CacheActionRelayDouble: AuthenticatedInboxPagingSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    let messages: [(String, JSONValue)]
    private(set) var checkpointAccepted = false

    init(identity: ProfileIdentity, messages: [(String, JSONValue)]) {
        authenticatedIdentity = identity
        self.messages = messages
    }

    func inboxRequest(_ request: Data, ref: String) async throws -> Data {
        let value = try JSONValue.parse(request)
        let type = value.uniqueValue(named: "type")?.stringValue?.rawValue
        var response: [String: Any] = ["v": 1, "type": "ok", "ref": ref,
            "paging_version": 1, "snapshot_id": "cache-actions", "high_water": 2]
        switch type {
        case "inbox_start":
            response["items"] = try messages.enumerated().map { index, message -> [String: Any] in
                ["acceptance": ["v": 1, "type": "delivery", "seq": index + 1,
                    "sender_id": "sender", "message_id": message.0, "origin": "source", "as": "message",
                    "message": try JSONSerialization.jsonObject(with: Data(message.1.canonicalJSON.utf8))]]
            }
            response["next_cursor"] = NSNull()
            response["receipt_cursor"] = NSNull()
        case "inbox_checkpoint_ack":
            checkpointAccepted = true
            response["checkpoint_accepted"] = true
        case "inbox_attach":
            response["checkpoint_accepted"] = checkpointAccepted
            response["replay_started"] = false
        case "view_get":
            response = ["v": 1, "type": "error", "ref": ref, "code": "unknown_type"]
        default:
            throw InstallationTransportError.unexpectedServerFrame
        }
        return try JSONSerialization.data(withJSONObject: response)
    }

    func attachInboxReplay(_ request: Data, ref: String,
                           consume: @Sendable (Data) async throws -> Void) async throws {
        try await consume(Data(#"{"v":1,"type":"ok","ref":"\#(ref)","paging_version":1,"snapshot_id":"cache-actions","high_water":2,"checkpoint_accepted":true,"replay_started":true}"#.utf8))
        try await consume(Data(#"{"v":1,"type":"resynced","seq":2}"#.utf8))
    }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        XCTFail("A cache-backed launch must use inbox paging.")
        throw InstallationTransportError.unexpectedServerFrame
    }
    func acknowledge(_ request: Data) async throws {}
    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        .unresolved
    }
}
