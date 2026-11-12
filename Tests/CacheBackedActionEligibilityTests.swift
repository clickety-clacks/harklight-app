import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest
@testable import Harklight

/// Uses the real cache restore, paging core and presentation refresh seam.
/// No transport, certificate, account enrollment or historical fixture is used.
@MainActor
final class CacheBackedActionEligibilityTests: XCTestCase {
    func testRejectedSeenSubmissionKeepsDetailOpen() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("rejected-seen-\(UUID().uuidString)"), deviceID: ExactText("test-installation"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let key = RequestKey(accountScope: identity.personID,
            senderID: ExactText("sender"), messageID: ExactText("seen"))
        let payload = try JSONValue.parse(Data(#"{"title":"Information","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        let previous = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence(), persistsOnlyLocalState: true)
        _ = try previous.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let saved = try previous.snapshot(context: context)
        let domain = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence(), persistsOnlyLocalState: true)
        try domain.restoreCachedServerState(CachedAttentionServerState(
            requests: saved.requests, remoteStates: [:], cursor: 1, conversationCursor: 0,
            conversations: [:], inboxView: nil, currentRequestKeys: [key]), context: context)
        let live = try LivePresentationStore(store: domain, context: context)
        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.informationalSeenStatus, .available)
        XCTAssertFalse(live.canSendToCurrentServer)
        XCTAssertFalse(live.submitFromUser(key, explicitCompatibilityAction: ExactText("seen"),
            requestRevision: request.requestRevision), "Establish a rejected submission, not an accepted pending intent.")
        var dismissals = 0
        LiveRequestDetail(request: request, store: live).finishSeenAction(ExactText("seen")) {
            dismissals += 1
        }
        XCTAssertTrue(try domain.snapshot(context: context).intents.isEmpty)
        XCTAssertEqual(live.request(for: key)?.informationalSeenStatus, .available)
        XCTAssertEqual(dismissals, 0, "A rejected Seen tap must keep the detail open instead of navigating as if submitted.")
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
        let previousLaunch = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence(), persistsOnlyLocalState: true)
        for (index, item) in [(seen, seenPayload), (reply, replyPayload)].enumerated() {
            _ = try previousLaunch.apply(RelayEvent(sequence: UInt64(index + 1),
                body: .delivery(StoredRequest(key: item.0, originalPayload: item.1), .message)),
                context: context)
        }
        let requests = try previousLaunch.snapshot(context: context).requests
        let domain = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence(), persistsOnlyLocalState: true)
        try domain.restoreCachedServerState(CachedAttentionServerState(
            requests: requests, remoteStates: [:], cursor: 2, conversationCursor: 0,
            conversations: [:], inboxView: nil, currentRequestKeys: [seen, reply]), context: context)
        let live = try LivePresentationStore(store: domain, context: context)
        XCTAssertFalse(live.canSendToCurrentServer, "A cache restore alone cannot authorize sending.")
        XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == seen }).canMarkSeen)
        XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == reply }).canNoComment)
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
                    store: domain, context: context, session: relay, serverStateCache: FileServerStateCache())
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
