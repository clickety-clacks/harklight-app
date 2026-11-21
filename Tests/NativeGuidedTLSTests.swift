import Foundation
import AttentionDomain
import CryptoKit
@testable import HarklightNativeRelay
import Network
import Security
import UserNotifications
import XCTest
@testable import Harklight

@MainActor
final class NativeGuidedTLSTests: XCTestCase {
    func testPushRegistrationProfileSelectionFollowsBuildConfiguration() {
        XCTAssertEqual(PushRegistrationProfile.forBuildConfiguration(.debug), .sandbox)
        XCTAssertEqual(PushRegistrationProfile.forBuildConfiguration(.release), .production)
        #if DEBUG
        XCTAssertEqual(PushRegistrationProfile.current, .sandbox)
        #else
        XCTAssertEqual(PushRegistrationProfile.current, .production)
        #endif
    }

    func testOrdinaryInboxGroupsUnresolvedThenResolvedAndUsesDescendingAcceptanceOrder() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-order"), deviceID: ExactText("device-order"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let olderResolved = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("older-resolved"))
        let newerResolved = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("newer-resolved"))
        let unresolved = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("unresolved"))
        let payload = try JSONValue.parse(Data(#"{"title":"Order check"}"#.utf8))

        _ = store.applyRelayEvent(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: olderResolved, originalPayload: payload), .message)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 2, body: .delivery(StoredRequest(key: newerResolved, originalPayload: payload), .message)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 3, body: .delivery(StoredRequest(key: unresolved, originalPayload: payload), .message)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 4, body: .terminal(newerResolved, .answered, nil)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 5, body: .terminal(olderResolved, .cleared, nil)), context: context)

        let port = AttentionDomainPort(store: store)
        let snapshot = try port.observe(context: port.context)
        XCTAssertEqual(snapshot.requests.map(\.key), [unresolved, newerResolved, olderResolved])
        XCTAssertEqual(snapshot.cursor, 5, "Presentation ordering must not reverse or advance the causal replay cursor.")
        XCTAssertEqual(snapshot.requests.map(\.isResolved), [false, true, true])
    }

    func testUnavailableChatMessageIsLocalToConversationAndDoesNotHideConnectionWarning() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let availability = NativeConversationAvailability()
        let presentation = try LivePresentationStore(store: domain, context: context,
                                                     conversationAvailability: availability)
        availability.confirm(for: context, conversationsUnavailable: true)
        presentation.applyRefreshResult(NativeRelayRefreshResult(relayConfirmed: true,
            pushRegistration: .confirmed, confirmedContext: context, confirmedTransportAttemptID: UUID()))
        XCTAssertEqual(presentation.conversationUnavailableMessage, "Chat is not available on this server yet.")
        XCTAssertNil(presentation.connectionWarning)
        XCTAssertNil(presentation.pushRegistrationWarning)
        presentation.applyRefreshResult(.unavailable)
        XCTAssertNotNil(presentation.connectionWarning, "A real refresh failure must still warn even when chat is unavailable.")
        availability.confirm(for: context, conversationsUnavailable: false)
        XCTAssertNil(presentation.conversationUnavailableMessage, "A replacement connection clears the old refusal.")
    }

    func testConnectionWarningShowsPlainStatusAndClearsOnlyAfterMatchingConfirmation() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let otherContext = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("other-relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device")), transportMode: .relay)
        let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let presentation = try LivePresentationStore(store: domain, context: context)
        let failure = NSError(domain: "RelayConnection", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "approved server could not be reached"])

        presentation.applyRefreshResult(.failed(error: failure))
        // The person sees plain status, not transport error text.
        XCTAssertEqual(presentation.connectionWarning, "Waiting for the server. Your pending actions are saved.")
        XCTAssertFalse(presentation.connectionWarning?.contains("approved server could not be reached") == true)

        presentation.applyRefreshResult(NativeRelayRefreshResult(relayConfirmed: true,
            pushRegistration: .confirmed, confirmedContext: otherContext,
            confirmedTransportAttemptID: UUID()))
        XCTAssertNotNil(presentation.connectionWarning,
                        "A confirmation for another profile cannot clear this connection warning.")

        presentation.applyRefreshResult(NativeRelayRefreshResult(relayConfirmed: true,
            pushRegistration: .confirmed, confirmedContext: context,
            confirmedTransportAttemptID: nil))
        XCTAssertNotNil(presentation.connectionWarning,
                        "A refresh without a confirmed transport attempt cannot clear this connection warning.")

        presentation.applyRefreshResult(NativeRelayRefreshResult(relayConfirmed: true,
            pushRegistration: .confirmed, confirmedContext: context,
            confirmedTransportAttemptID: UUID()))
        XCTAssertNil(presentation.connectionWarning)
    }

    func testReadOnlyDraftStatusDoesNotCallUncertainOrAcceptedSubmissionUndelivered() throws {
        XCTAssertEqual(ConversationDraftPresentationText.status(for: .outcomeUnknown(UUID())), .outcomeUnknown)
        XCTAssertEqual(ConversationDraftPresentationText.status(for:
            .acceptedPendingReplay(operation: UUID(), turn: ExactText("saved-turn"))), .acceptedPendingReplay)
        XCTAssertNil(ConversationDraftPresentationText.status(for: .saved))
        XCTAssertEqual(ConversationDraftPresentationText.status(for: .rejected(ExactText("Refused"))),
                       .rejected(ExactText("Refused")))
    }

    func testJoinRefusesPlaintextBeforeSendingAnInvitation() async throws {
        let server = try LocalEnrollmentTLS(expectedDevice: nil)
        defer { server.close() }
        let port = try await server.start()
        let url = try XCTUnwrap(URL(string: "http://localhost:\(port)/enroll"))
        do {
            _ = try await PinnedNativeJoinTransport().request(
                url, method: "POST", body: Data("{\"invite_token\":\"fictional-invitation\"}".utf8),
                rootDER: server.rootDER)
            XCTFail("An invitation must never be sent over plaintext HTTP")
        } catch NativeJoinError.refused {}
        XCTAssertFalse(server.receivedRequest)
    }

    func testJoinCanReachPinnedEnrollmentBeforeItHasAClientCertificate() async throws {
        let server = try LocalEnrollmentTLS(expectedDevice: nil)
        defer { server.close() }
        let port = try await server.start()
        let url = try XCTUnwrap(URL(string: "https://localhost:\(port)/enroll"))
        let result = try await PinnedNativeJoinTransport().request(url, method: "GET", body: nil,
                                                                  rootDER: server.rootDER)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.data, Data("{\"state\":\"reachable\"}".utf8))
    }

    func testRemovalProvesTheRetainedDeviceKeyToThePinnedServer() async throws {
        let namespace = "Harklight.guided-tls-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: identity.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }
        let server = try LocalEnrollmentTLS(expectedDevice: identity.deviceID)
        defer { server.close() }
        let port = try await server.start()
        let url = try XCTUnwrap(URL(string: "https://localhost:\(port)/device/remove"))
        let body = try JSONSerialization.data(withJSONObject: ["expected_device_id": identity.deviceID])
        let result = try await PinnedNativeJoinTransport().remove(url, body: body, rootDER: server.rootDER,
                                                                 identity: identity.value)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.data, Data("{\"state\":\"reachable\"}".utf8))
    }

    func testJoinSecretIsNotSentToAServerWithDifferentPinnedTrust() async throws {
        let namespace = "Harklight.wrong-join-trust-test." + UUID().uuidString
        let other = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: other.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }
        let server = try LocalEnrollmentTLS(expectedDevice: nil)
        defer { server.close() }
        let port = try await server.start()
        let url = try XCTUnwrap(URL(string: "https://localhost:\(port)/enroll"))
        let body = Data("{\"invite_token\":\"fictional-invitation\"}".utf8)
        do {
            _ = try await PinnedNativeJoinTransport().request(url, method: "POST", body: body,
                                                              rootDER: other.certificateDER)
            XCTFail("The wrong server trust must refuse the join before sending the invitation")
        } catch is URLError {}
        XCTAssertFalse(server.receivedRequest)
    }

    func testClientDiagnosticJournalPersistsRetrievableOperationAndSafeCauseOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarklightClientDiagnostics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = NativeClientDiagnosticJournal(fileURL: url)
        let operationID = UUID()
        let request = RequestKey(accountScope: ExactText("private-person-marker"),
                                 senderID: ExactText("private-sender-marker"),
                                 messageID: ExactText("private-message-marker"))
        let error = NSError(domain: "private-host-marker",
                            code: 731,
                            userInfo: [NSLocalizedDescriptionKey: "private-answer-marker token=secret-marker"])

        journal.record(area: .answer, phase: .originalOperationDelivery, transition: .unresolved,
                       error: error, operationID: operationID, request: request,
                       requestRevision: 4, receiptState: .unknown)

        let shared = journal.shareText
        XCTAssertTrue(journal.hasEvents)
        XCTAssertTrue(shared.contains("operation_id=\(operationID.uuidString.lowercased())"))
        XCTAssertTrue(shared.contains("request_revision=4"))
        XCTAssertTrue(shared.contains("receipt_state=unknown"))
        XCTAssertTrue(shared.contains("cause=unknown_error"))
        XCTAssertFalse(shared.contains("private-person-marker"))
        XCTAssertFalse(shared.contains("private-sender-marker"))
        XCTAssertFalse(shared.contains("private-message-marker"))
        XCTAssertFalse(shared.contains("private-answer-marker"))
        XCTAssertFalse(shared.contains("secret-marker"))
        XCTAssertFalse(shared.contains("private-host-marker"))

        journal.record(area: .relay, phase: .ordinaryReplay, transition: .failed,
                       error: NSError(domain: NSURLErrorDomain, code: -1001,
                                      userInfo: [NSLocalizedDescriptionKey: "private-url-marker"]))
        XCTAssertTrue(journal.shareText.contains("cause=url_session_error_code_-1001"),
                      "System error classes should retain their numeric cause without a localized message.")
        XCTAssertFalse(journal.shareText.contains("private-url-marker"))

        journal.record(area: .relay, phase: .ordinaryReplay, transition: .failed,
                       causeCode: "host=relay.private.example token=secret-marker")
        XCTAssertTrue(journal.shareText.contains("cause=unknown_error"),
                      "Caller-supplied cause text must be reduced to a fixed safe code.")
        XCTAssertFalse(journal.shareText.contains("relay.private.example"))
        XCTAssertFalse(journal.shareText.contains("secret-marker"))

        journal.record(area: .relay, phase: .ordinaryReplay, transition: .failed,
                       causeCode: "url_session_error_code_999999999999999999999999999999")
        XCTAssertTrue(journal.shareText.contains("cause=unknown_error"),
                      "An arbitrary code-shaped value must not bypass the numeric code bound.")

        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var savedEvents = try XCTUnwrap(saved["events"] as? [[String: Any]])
        savedEvents[0]["causeCode"] = "host=relay.private.example token=secret-marker"
        savedEvents[0]["requestTag"] = "private-sender-marker"
        saved["events"] = savedEvents
        try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys]).write(to: url, options: .atomic)

        let restored = NativeClientDiagnosticJournal(fileURL: url)
        XCTAssertEqual(restored.events.count, journal.events.count)
        XCTAssertEqual(restored.events[0].causeCode, "unknown_error")
        XCTAssertNil(restored.events[0].requestTag)
        XCTAssertTrue(restored.shareText.contains("operation_id=\(operationID.uuidString.lowercased())"))
        XCTAssertFalse(restored.shareText.contains("relay.private.example"))
        XCTAssertFalse(restored.shareText.contains("private-sender-marker"))
        XCTAssertFalse(restored.shareText.contains("secret-marker"))
    }

    func testPostAckFailureJournalRetainsBoundedStepAndErrorCode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarklightPostAckFailure-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = NativeClientDiagnosticJournal(fileURL: url)
        let code = "url_session_error_code_-1005"
        let event = NativeClientDiagnosticEvent(
            area: .relay,
            phase: .postAckDrain,
            transition: .failed,
            causeCode: code,
            postAckFailureStep: .drainPendingOperations,
            postAckFailureErrorCode: code,
            id: UUID(),
            occurredAtMilliseconds: 1)

        journal.record(event)
        let restored = NativeClientDiagnosticJournal(fileURL: url)
        XCTAssertEqual(restored.events.first?.postAckFailureStep, .drainPendingOperations)
        XCTAssertEqual(restored.events.first?.postAckFailureErrorCode, code)
        XCTAssertTrue(restored.shareText.contains("post_ack_failure_step=drain_pending_operations"))
        XCTAssertTrue(restored.shareText.contains("post_ack_failure_error_code=\(code)"))

        let unsafeEvent = NativeClientDiagnosticEvent(
            area: .relay,
            phase: .postAckDrain,
            transition: .failed,
            postAckFailureStep: .drainPendingOperations,
            postAckFailureErrorCode: "token=secret-marker",
            id: UUID(),
            occurredAtMilliseconds: 2)
        journal.record(unsafeEvent)
        XCTAssertFalse(journal.shareText.contains("secret-marker"))
        XCTAssertTrue(journal.shareText.contains("post_ack_failure_error_code=unknown_error"))
    }

    func testNoReplyJournalPersistsPayloadFreeOperationAndRoutingChain() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarklightNoReplyChain-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = NativeClientDiagnosticJournal(fileURL: url)
        let request = RequestKey(accountScope: ExactText("private-account-marker"),
                                 senderID: ExactText("private-sender-marker"),
                                 messageID: ExactText("private-request-marker"))
        let operationID = UUID()
        journal.record([
            NativeClientDiagnosticEvent(area: .answer, phase: .noReplyOriginalOperation,
                transition: .began, operationIDSource: .localSubmission,
                operationID: operationID, request: request, requestRevision: 7,
                receiptState: .pendingUnconfirmed, id: UUID(), occurredAtMilliseconds: 100),
            NativeClientDiagnosticEvent(area: .answer, phase: .noReplyResponseReceive,
                transition: .completed, noReplyResponseClass: .frameReceived,
                operationIDSource: .localSubmission, operationID: operationID,
                id: UUID(), occurredAtMilliseconds: 110),
            NativeClientDiagnosticEvent(area: .answer, phase: .noReplyResponseDecode,
                transition: .completed, noReplyResponseClass: .unknownFrame,
                operationIDSource: .localSubmission, operationID: operationID,
                id: UUID(), occurredAtMilliseconds: 111),
            NativeClientDiagnosticEvent(area: .answer, phase: .noReplyResponseReceive,
                transition: .completed, noReplyResponseClass: .frameReceived,
                operationIDSource: .pagingWireOperationID,
                terminalSequence: 12, lifecycleSequence: 12,
                operationID: operationID, request: request, requestRevision: 7,
                id: UUID(), occurredAtMilliseconds: 118),
            NativeClientDiagnosticEvent(area: .answer, phase: .noReplyResponseDecode,
                transition: .completed, noReplyResponseClass: .committedReceipt,
                operationIDSource: .pagingWireOperationID,
                terminalSequence: 12, lifecycleSequence: 12,
                operationID: operationID, request: request, requestRevision: 7,
                receiptState: .terminal, id: UUID(), occurredAtMilliseconds: 120),
            NativeClientDiagnosticEvent(area: .answer, phase: .noReplyLifecycleApply,
                transition: .began, noReplyResponseClass: .terminalNoComment,
                operationIDSource: .pagingWireOperationID,
                terminalSequence: 12, lifecycleSequence: 12,
                operationID: operationID, request: request, requestRevision: 7,
                receiptState: .terminal, id: UUID(), occurredAtMilliseconds: 120),
            NativeClientDiagnosticEvent(area: .answer, phase: .noReplyLifecycleApply,
                transition: .completed, noReplyResponseClass: .terminalNoComment,
                operationIDSource: .pagingWireOperationID,
                terminalSequence: 12, lifecycleSequence: 12,
                operationID: operationID, request: request, requestRevision: 7,
                receiptState: .terminal, id: UUID(), occurredAtMilliseconds: 121)
        ])
        journal.recordNoReplyRoutingIfChanged(request: request, revision: 7,
                                              operationID: nil, route: .replied)
        journal.recordNoReplyRoutingIfChanged(request: request, revision: 7,
                                              operationID: nil, route: .replied)
        journal.recordNoReplyRoutingIfChanged(request: request, revision: 7,
                                              operationID: nil, route: .inbox)

        let restored = NativeClientDiagnosticJournal(fileURL: url)
        let routes = restored.events.filter { $0.phase == .noReplyRouting }
        XCTAssertEqual(routes.count, 2, "Repeated projection of the same route is not a new routing transition.")
        XCTAssertEqual(routes.map(\.noReplyRoute), [.replied, .inbox])
        XCTAssertEqual(routes.map(\.operationID), [operationID, operationID])
        XCTAssertEqual(routes.map(\.operationIDSource), [.localRequestCorrelation, .localRequestCorrelation])
        XCTAssertEqual(restored.events.first(where: { $0.phase == .noReplyOriginalOperation })?.requestRevision, 7)
        XCTAssertEqual(restored.events.first(where: { $0.phase == .noReplyResponseDecode })?.noReplyResponseClass,
                       .unknownFrame)
        XCTAssertEqual(restored.events.first(where: {
            $0.phase == .noReplyResponseDecode && $0.noReplyResponseClass == .committedReceipt
        })?.operationIDSource, .pagingWireOperationID)
        XCTAssertEqual(restored.events.first(where: { $0.phase == .noReplyLifecycleApply })?.lifecycleSequence, 12)

        let export = restored.shareText
        XCTAssertTrue(export.contains("no_reply_response_class=unknown_frame"))
        XCTAssertTrue(export.contains("operation_id_source=local_submission"))
        XCTAssertTrue(export.contains("operation_id_source=paging_wire_op_id"))
        XCTAssertTrue(export.contains("operation_id_source=local_request_correlation"))
        XCTAssertTrue(export.contains("terminal_sequence=12"))
        XCTAssertTrue(export.contains("lifecycle_sequence=12"))
        XCTAssertTrue(export.contains("no_reply_route=replied"))
        XCTAssertTrue(export.contains("no_reply_route=inbox"))
        XCTAssertTrue(export.contains("app_source_commit="))
        XCTAssertTrue(export.contains("app_source_tree="))
        XCTAssertTrue(export.contains("request_tag_sha256="))
        XCTAssertTrue(export.contains("operation_id=\(operationID.uuidString.lowercased())"))
        XCTAssertFalse(export.contains("private-account-marker"))
        XCTAssertFalse(export.contains("private-sender-marker"))
        XCTAssertFalse(export.contains("private-request-marker"))
    }

    func testDiagnosticSourceProvenanceRequiresFullGitObjectIDs() {
        let valid = NativeDiagnosticSourceProvenance.validated(
            commit: String(repeating: "a", count: 40),
            tree: String(repeating: "b", count: 40))
        XCTAssertEqual(valid.commit, String(repeating: "a", count: 40))
        XCTAssertEqual(valid.tree, String(repeating: "b", count: 40))
        XCTAssertEqual(NativeDiagnosticSourceProvenance.validated(commit: "short", tree: String(repeating: "b", count: 40)),
                       .unavailable)
        XCTAssertEqual(NativeDiagnosticSourceProvenance.validated(commit: String(repeating: "a", count: 40), tree: "../tree"),
                       .unavailable)
    }

    func testClientDiagnosticJournalKeepsCallbackHistoryInOccurrenceOrder() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarklightDiagnosticOrder-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = NativeClientDiagnosticJournal(fileURL: url)
        let earlier = NativeClientDiagnosticEvent(area: .connection, phase: .serverTrust,
            transition: .completed, causeCode: "server_trust_validated",
            attemptID: UUID(), transportAttemptID: UUID(), id: UUID(), occurredAtMilliseconds: 100)
        let later = NativeClientDiagnosticEvent(area: .connection, phase: .webSocketOpen,
            transition: .completed, causeCode: "websocket_opened",
            attemptID: earlier.attemptID, transportAttemptID: earlier.transportAttemptID,
            id: UUID(), occurredAtMilliseconds: 200)

        // A concurrently delivered callback arrives before an earlier event.
        journal.record(later)
        journal.record(earlier)

        let earlyPosition = try XCTUnwrap(journal.shareText.range(of: "event_id=\(earlier.id.uuidString.lowercased())"))
        let latePosition = try XCTUnwrap(journal.shareText.range(of: "event_id=\(later.id.uuidString.lowercased())"))
        XCTAssertLessThan(earlyPosition.lowerBound, latePosition.lowerBound)
        let restored = NativeClientDiagnosticJournal(fileURL: url)
        XCTAssertEqual(restored.events.map(\.id), [earlier.id, later.id])
    }
}

private final class LocalEnrollmentTLS: @unchecked Sendable {
    let rootDER: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Harklight.local-enrollment-tls")
    private let replyBody: Data
    private let redirectTo: URL?
    private let stallRequest: Bool
    private let responseFileHash: String?
    // All connection ownership is serialized on queue, including close().
    private var connections: [NWConnection] = []
    private var requestWasReceived = false
    private var connectionWasClosed = false
    var acceptedConnectionCount: Int { queue.sync { connections.count } }
    var receivedRequest: Bool { queue.sync { requestWasReceived } }
    var clientClosed: Bool { queue.sync { connectionWasClosed } }

    init(expectedDevice: String?, replyBody: Data = Data("{\"state\":\"reachable\"}".utf8),
         redirectTo: URL? = nil, stallRequest: Bool = false,
         responseFileHash: String? = nil) throws {
        self.replyBody = replyBody
        self.redirectTo = redirectTo
        self.stallRequest = stallRequest
        self.responseFileHash = responseFileHash
        let (tls, root) = try LocalEnrollmentTLS.fixtureTLS(expectedDevice: expectedDevice, queue: queue)
        rootDER = root
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func fixtureTLS(expectedDevice: String?, queue: DispatchQueue) throws -> (NWProtocolTLS.Options, Data) {
        let bundle = Bundle(for: NativeGuidedTLSTests.self)
        guard let certificateURL = bundle.url(forResource: "guided-local-tls", withExtension: "pem"),
              let identityURL = bundle.url(forResource: "guided-local-tls", withExtension: "p12"),
              let root = NativeEnrollmentSettings.certificateDER(from: try String(contentsOf: certificateURL,
                                                                                   encoding: .utf8)) else {
            throw NativeEnrollmentError.invalidIdentity
        }
        var items: CFArray?
        guard SecPKCS12Import(try Data(contentsOf: identityURL) as CFData,
                              [kSecImportExportPassphrase as String: "public-fixture-only"] as CFDictionary,
                              &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String] else { throw NativeEnrollmentError.invalidIdentity }
        let identity = raw as! SecIdentity
        guard let local = sec_identity_create(identity) else { throw NativeEnrollmentError.invalidIdentity }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, expectedDevice != nil)
        if let expectedDevice {
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let trust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let certificate = SecTrustGetCertificateAtIndex(trust, 0) else { complete(false); return }
                complete(DeviceCertificateBinding.matches(SecCertificateCopyData(certificate) as Data,
                                                           expectedDeviceID: expectedDevice))
            }, queue)
        }
        return (tls, root)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: NativeJoinError.unavailable); return
                    }
                    continuation.resume(returning: port.rawValue)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connections.append(connection)
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .failed = state { connectionWasClosed = true }
                    if case .cancelled = state { connectionWasClosed = true }
                }
                connection.start(queue: queue)
                receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, !data.isEmpty else {
                if stallRequest { connectionWasClosed = true }
                connection.cancel()
                return
            }
            let next = buffer + data
            guard next.count <= 32 * 1024 else { connection.cancel(); return }
            if let boundary = next.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: next[..<boundary.lowerBound], encoding: .utf8) {
                let length = header.components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if next.count - boundary.upperBound >= length {
                    requestWasReceived = true
                    if stallRequest {
                        receive(connection, buffer: Data())
                        return
                    }
                    let hashHeader = responseFileHash.map { "X-Harklight-Sha256: \($0)\r\n" } ?? ""
                    let reply: Data
                    if let redirectTo {
                        reply = Data("HTTP/1.1 302 Found\r\nLocation: \(redirectTo.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    } else {
                        reply = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(replyBody.count)\r\n\(hashHeader)Connection: close\r\n\r\n".utf8) + replyBody
                    }
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if done { connection.cancel() } else { receive(connection, buffer: next) }
        }
    }

    func close() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}
