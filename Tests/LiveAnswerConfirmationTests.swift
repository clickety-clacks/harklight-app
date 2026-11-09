import AttentionDomain
import Foundation
import HarklightNativeRelay
import Network
import Security
import XCTest
@testable import Harklight

@MainActor
private func assertThrowsAsync<T>(
    _ expression: @MainActor () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}

/// Authenticated local Route A peer for the retained-answer retry test. The
/// first answer is refused, while the second stays pending until the test
/// explicitly releases its correlated acceptance.
private final class LiveAnswerConfirmationRelay: @unchecked Sendable {
    let rootDER: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Harklight.live-answer-confirmation-relay")
    private var connections: [NWConnection] = []
    private var answerFrames: [String] = []
    private var answerWaiters: [Int: CheckedContinuation<String, Never>] = [:]
    private var heldRetryConnection: NWConnection?
    private var acceptedRetry = false

    init(expectedDeviceID: String) throws {
        let bundle = Bundle(for: LiveAnswerConfirmationTests.self)
        guard let certificateURL = bundle.url(forResource: "guided-local-tls", withExtension: "pem"),
              let identityURL = bundle.url(forResource: "guided-local-tls", withExtension: "p12"),
              let root = NativeEnrollmentSettings.certificateDER(from:
                try String(contentsOf: certificateURL, encoding: .utf8)) else {
            throw NativeEnrollmentError.invalidIdentity
        }
        var items: CFArray?
        guard SecPKCS12Import(try Data(contentsOf: identityURL) as CFData,
                              [kSecImportExportPassphrase as String: "public-fixture-only"] as CFDictionary,
                              &items) == errSecSuccess,
              let rawIdentity = (items as? [[String: Any]])?.first?[kSecImportItemIdentity as String],
              let identity = rawIdentity as? SecIdentity,
              let localIdentity = sec_identity_create(identity) else {
            throw NativeEnrollmentError.invalidIdentity
        }
        rootDER = root

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
                complete(false)
                return
            }
            complete(DeviceCertificateBinding.matches(SecCertificateCopyData(certificate) as Data,
                                                       expectedDeviceID: expectedDeviceID))
        }, queue)

        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: "attention-relay/1",
                                         additionalHeaders: nil)
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: NativeJoinError.unavailable)
                        return
                    }
                    continuation.resume(returning: port.rawValue)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connections.append(connection)
                connection.start(queue: queue)
                receive(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForAnswer(attempt: Int) async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.answerFrames.indices.contains(attempt - 1) {
                    continuation.resume(returning: self.answerFrames[attempt - 1])
                } else {
                    self.answerWaiters[attempt] = continuation
                }
            }
        }
    }

    func acceptHeldRetry() {
        queue.async {
            guard let connection = self.heldRetryConnection else { return }
            self.acceptedRetry = true
            self.heldRetryConnection = nil
            self.send([#"{"v":1,"type":"ok","seq":2}"#], on: connection)
        }
    }

    func close() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil, let data else {
                connection.cancel()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .text, let text = String(data: data, encoding: .utf8) {
                handle(text, on: connection)
            }
            receive(connection)
        }
    }

    private func handle(_ text: String, on connection: NWConnection) {
        guard let value = try? JSONValue.parse(Data(text.utf8)),
              let type = value.uniqueValue(named: "type")?.stringValue?.rawValue else { return }
        switch type {
        case "resync":
            var frames = [#"{"v":1,"type":"ok","ref":"native-sync"}"#,
                #"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"retry","origin":"fixture-origin","as":"message","message":{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"got-it","label":"Got it","kind":"value","value":"got-it"}]}}}"#]
            let high = acceptedRetry ? 2 : 1
            if acceptedRetry {
                frames.append(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"retry","origin":"another-device","state":"answered","at":2}"#)
            }
            frames.append(#"{"v":1,"type":"resynced","seq":\#(high)}"#)
            send(frames, on: connection)
        case "view_get":
            let ref = value.uniqueValue(named: "ref")?.stringValue?.rawValue ?? ""
            send([#"{"v":1,"type":"ok","ref":"\#(ref)","view_rev":"retry-fixture","entries":[]}"#],
                 on: connection)
        case "conversation_open":
            send([#"{"v":1,"type":"ok","ref":"native-conversation-sync"}"#,
                  #"{"v":1,"type":"conversation_resynced","conversation_seq":0}"#], on: connection)
        case "ack":
            let sequence = value.uniqueValue(named: "seq")?.integerValue ?? 0
            send([#"{"v":1,"type":"ok","ref":"native-ack","seq":\#(sequence)}"#], on: connection)
        case "conversation_ack":
            let sequence = value.uniqueValue(named: "conversation_seq")?.integerValue ?? 0
            send([#"{"v":1,"type":"ok","ref":"native-conversation-ack","conversation_seq":\#(sequence)}"#],
                 on: connection)
        case "answer":
            answerFrames.append(text)
            let attempt = answerFrames.count
            answerWaiters.removeValue(forKey: attempt)?.resume(returning: text)
            if attempt == 1 {
                send([#"{"v":1,"type":"error","reason":"fixture_refusal"}"#], on: connection)
            } else if attempt == 2 {
                heldRetryConnection = connection
            }
        default:
            break
        }
    }

    private func send(_ frames: [String], on connection: NWConnection) {
        for frame in frames {
            let context = NWConnection.ContentContext(
                identifier: "relay-frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: Data(frame.utf8), contentContext: context, isComplete: true,
                            completion: .idempotent)
        }
    }
}

@MainActor
final class LiveAnswerConfirmationTests: XCTestCase {
    private func setup(messageID: String = "sample") async throws -> (ProfileContext, AttentionDomainStore, LivePresentationStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText(messageID))
        let payload = try JSONValue.parse(Data(#"{"title":"Sample","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"got-it","label":"Got it","kind":"value","value":"got-it"}]}}"#.utf8))
        _ = try await store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let live = try LivePresentationStore(store: store, context: context)
        try await live.refreshFromDurableStore()
        return (context, store, live, key)
    }

    private func setupReplyOnly() async throws -> (ProfileContext, AttentionDomainStore, LivePresentationStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("reply-only"))
        let payload = try JSONValue.parse(Data(#"{"title":"Reply-only request"}"#.utf8))
        _ = try await store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let live = try LivePresentationStore(store: store, context: context)
        try await live.refreshFromDurableStore()
        return (context, store, live, key)
    }

    private func setupTextReplyOnly() async throws -> (ProfileContext, AttentionDomainStore, LivePresentationStore, RequestKey) {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("text-reply-only"))
        let payload = try JSONValue.parse(Data(#"{"title":"Text reply request","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"reply","label":"Reply","kind":"text"}]}}"#.utf8))
        _ = try await store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let live = try LivePresentationStore(store: store, context: context)
        try await live.refreshFromDurableStore()
        return (context, store, live, key)
    }

    private func commitAnswer(_ store: AttentionDomainStore, key: RequestKey) async throws -> IntentReceipt {
        let port = AttentionDomainPort(store: store)
        let inspection = try await port.inspect(context: port.context, request: key)
        let selector = try XCTUnwrap(inspection.requests.first?.selector)
        return try await port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                                             inputs: [.compatibilityValue(action: ExactText("got-it"))]))
    }

    private func commitNoComment(_ store: AttentionDomainStore, key: RequestKey) async throws -> IntentReceipt {
        let port = AttentionDomainPort(store: store)
        let inspection = try await port.inspect(context: port.context, request: key)
        let selector = try XCTUnwrap(inspection.requests.first?.selector)
        return try await port.submitNoComment(context: port.context, selector: selector, intentID: UUID())
    }

    private func sampleResponse(for live: LivePresentationStore, key: RequestKey) -> SampleResponse {
        let message = SampleMessage(id: key.messageID.rawValue, kind: .note,
            sender: key.senderID.rawValue, initials: "", title: "Sample request", body: "",
            options: [], deadline: nil, missed: false, revised: false,
            chatUnread: false, hasChat: false, fixtureCreatedAtMilliseconds: 0)
        return SampleResponse(viewModel: live, key: key, message: message)
    }

    func testDelayedSendAfterDurableAnswerNeverClaimsFailureOrCreatesAnotherIntent() async throws {
        let (context, store, live, key) = try await setup()
        // The displayed Open view is deliberately older than the durable intent.
        let receipt = try await commitAnswer(store, key: key)
        await live.submitFromUser(key)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.intentReceipt?.opID, receipt.opID)
        let assertionSnapshot89 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot89.intents.count, 1)
        let assertionSnapshot90 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot90.outbox.map(\.operationID), [receipt.opID])

        try await store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        _ = try await store.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil)), context: context)
        await live.submitFromUser(key)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "A completed account state does not expose the submitting device's receipt.")
        let assertionSnapshot100 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot100.outbox.isEmpty)
        let assertionSnapshot101 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot101.intents.count, 1)
    }

    func testNewDurableReceiptClearsAnObsoleteSubmissionError() async throws {
        let (context, store, live, key) = try await setup()
        await live.submitFromUser(key) // No choice made: a genuine local validation error.
        XCTAssertEqual(live.actionError, "Complete the response before sending your answer.")
        let assertionSnapshot108 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot108.intents.isEmpty)
        let receipt = try await commitAnswer(store, key: key)
        try await store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        try await live.refreshFromDurableStore()
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
    }

    func testRejectedNoCommentThenBlankReplyShowsValidationWithoutSendingText() async throws {
        let (context, store, live, key) = try await setupTextReplyOnly()
        live.selectNoComment(for: key)
        await live.submitFromUser(key)
        let noComment = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        try await store.recordNoCommentUnsupported(noComment.intentID,
                                             operationID: noComment.opID,
                                             context: context)
        try await live.refreshFromDurableStore()
        XCTAssertTrue(live.request(for: key)?.noCommentUnavailable == true)
        XCTAssertTrue(LiveRequestDetail(request: try XCTUnwrap(live.request(for: key)),
                                        store: live).canAnswer)

        live.selectAction(ExactText("reply"), input: nil, for: key)
        let draftBeforeBlankReply = try await store.snapshot(context: context).drafts[key]
        await live.submitFromUser(key)

        XCTAssertEqual(live.actionError, "Complete the response before sending your answer.")
        let snapshot = try await store.snapshot(context: context)
        XCTAssertEqual(snapshot.intents.count, 1,
                       "Only the rejected No comment intent remains in history.")
        XCTAssertEqual(snapshot.intents[noComment.intentID]?.disposition, .unsupported)
        XCTAssertTrue(snapshot.outbox.isEmpty,
                      "The blank Reply must not create a sendable ordinary answer.")
        XCTAssertEqual(snapshot.drafts[key], draftBeforeBlankReply,
                       "The blank Reply attempt must not save or alter the persisted draft.")
        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.lifecycleStatus, .open)
        XCTAssertNil(request.intentReceipt)
        XCTAssertFalse(request.draft.noCommentSelected)
        XCTAssertTrue(LiveRequestDetail(request: request, store: live).canAnswer,
                      "The person can add text and submit after the empty attempt is refused.")
    }

    func testWhitespaceOnlyReplyIsRefusedAndTypedSurroundingSpacesAreSentAsIs() async throws {
        let (context, store, live, key) = try await setupTextReplyOnly()
        live.selectAction(ExactText("reply"), input: nil, for: key)
        live.updateCompatibilityText("  \n \n  ", action: ExactText("reply"), for: key)
        await live.submitFromUser(key)

        XCTAssertEqual(live.actionError, "Complete the response before sending your answer.")
        let refused = try await store.snapshot(context: context)
        XCTAssertTrue(refused.intents.isEmpty,
                      "A whitespace-only Reply must not create an intent.")
        XCTAssertTrue(refused.outbox.isEmpty,
                      "A whitespace-only Reply must not queue anything to send.")
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .open)

        let typed = "  Near the east entrance \n"
        live.updateCompatibilityText(typed, action: ExactText("reply"), for: key)
        await live.submitFromUser(key)

        XCTAssertNil(live.actionError)
        let sentSnapshot = try await store.snapshot(context: context)
        let sent = try XCTUnwrap(sentSnapshot.outbox.first)
        XCTAssertEqual(sent.typedInputs,
                       [.compatibilityText(action: ExactText("reply"), text: ExactText(typed))],
                       "Ordinary surrounding whitespace goes out exactly as typed.")
    }

    func testNoCommentUsesItsOwnPayloadFreeFrameAndUnsupportedLeavesTheRequestOpen() async throws {
        let (context, store, live, key) = try await setup()
        let port = AttentionDomainPort(store: store)
        let inspection = try await port.inspect(context: port.context, request: key)
        let selector = try XCTUnwrap(inspection.requests.first?.selector)
        let receipt = try await port.submitNoComment(context: port.context, selector: selector, intentID: UUID())

        XCTAssertEqual(receipt.answerKind, .noComment)
        XCTAssertEqual(receipt.inputs, [])
        XCTAssertEqual(receipt.exactAnswer, .null,
                       "The local null placeholder is distinguished by answerKind and is never the wire frame.")
        let submittedSnapshot = try await store.snapshot(context: context)
        let submitted = try XCTUnwrap(submittedSnapshot.outbox.first)
        XCTAssertEqual(submitted.requestRevision, 1,
                       "An ordinary request is the first revision even without conversation history.")
        XCTAssertEqual(String(decoding: submitted.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"sample","request_revision":1}"# + "\n")
        try await live.refreshFromDurableStore()
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .pending)
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied)

        try await store.recordNoCommentUnsupported(receipt.intentID, operationID: receipt.opID, context: context)
        try await live.refreshFromDurableStore()
        let reopened = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(reopened.lifecycleStatus, .open)
        XCTAssertTrue(reopened.noCommentUnavailable)
        XCTAssertNil(reopened.intentReceipt)
        let unavailableRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertFalse(unavailableRow.belongsToReplied,
                       "Unsupported No comment was not accepted, so the request stays in Inbox.")
        XCTAssertTrue(unavailableRow.hasDeliveryWarning)
        XCTAssertFalse(unavailableRow.visibleStatus.contains("Open"))
        XCTAssertFalse(unavailableRow.visibleStatus.contains("not delivered"))
        XCTAssertNil(unavailableRow.localStatus)
        let warning = try XCTUnwrap(live.failedResponseWarning(for: key))
        XCTAssertEqual(String(localized: warning.summary),
                       "Your No comment response was not delivered.")
        XCTAssertFalse(String(localized: warning.detail).contains("unsupported by this server"),
                       "The dialog must not repeat an unverified cause.")
        XCTAssertTrue(LiveRequestDetail(request: reopened, store: live).canAnswer,
                      "The app leaves ordinary answer choices to an explicit user action.")
        let assertionSnapshot216 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot216.outbox.isEmpty)

        await live.submitNoCommentFromUser(key)
        XCTAssertTrue(live.draft(for: key)?.noCommentSelected == true,
                      "A swipe submission persists the explicit No comment choice for retry.")
        let retrySnapshot = try await store.snapshot(context: context)
        let retry = try XCTUnwrap(retrySnapshot.outbox.first)
        XCTAssertEqual(retry.answerKind, .noComment)
        XCTAssertEqual(String(decoding: retry.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"sample","request_revision":1}"# + "\n")
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .pending)
        XCTAssertFalse(live.request(for: key)?.noCommentUnavailable ?? true,
                       "A newly queued attempt replaces the prior unsupported result in the current status.")
        let pendingRetryRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(pendingRetryRow.hasDeliveryWarning,
                      "The known delivery failure remains visible until the retry is accepted.")
        XCTAssertFalse(pendingRetryRow.belongsToReplied,
                       "The known delivery failure keeps the row in Inbox until the retry is accepted.")
    }

    func testAcceptedNoCommentIsFinalAndCannotBeResubmitted() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        live.selectNoComment(for: key)
        await live.submitFromUser(key)
        let receipt = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        try await store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        try await store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)), context: context)
        try await live.refreshFromDurableStore()

        let accepted = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(accepted.lifecycleStatus, .noComment)
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied)
        XCTAssertFalse(LiveRequestDetail(request: accepted, store: live).canAnswer)
        let intentCount = try await store.snapshot(context: context).intents.count
        await live.submitNoCommentFromUser(key)
        let assertionSnapshot251 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot251.intents.count, intentCount,
                       "An accepted final No comment answer cannot be submitted a second time.")
    }

    func testDefinitiveNoCommentErrorReturnsToInboxWithNotDeliveredTreatment() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        live.selectNoComment(for: key)
        let failed = try await live.submit(key)
        let session = AnswerSession(context.identity)
        session.rejectOperation = true
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        let sent = try await core.sendPendingOriginalOperations()
        XCTAssertEqual(sent, 1)
        try await live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        let assertionLookup267 = try await store.lookupIntent(failed.intentID, context: context)
        XCTAssertEqual(assertionLookup267?.disposition, .failed)
        let assertionSnapshot268 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot268.outbox.isEmpty,
                      "A definitive rejection retires the refused operation instead of retrying it.")
        XCTAssertEqual(request.lifecycleStatus, .open)
        XCTAssertNil(request.intentReceipt)
        XCTAssertTrue(request.answerNotDelivered)
        XCTAssertFalse(request.noCommentUnavailable,
                       "A generic rejection must not claim the server lacks No comment support.")
        XCTAssertTrue(LiveRequestDetail(request: request, store: live).canAnswer,
                      "After a definite refusal, the person can choose another response.")

        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertFalse(row.belongsToReplied)
        XCTAssertTrue(row.hasFailedResponse)
        XCTAssertTrue(row.hasDeliveryWarning)
        XCTAssertNil(row.localStatus)
        XCTAssertFalse(row.visibleStatus.contains("Open"))
        XCTAssertFalse(row.visibleStatus.contains("not delivered"))
        XCTAssertEqual(session.sentOperationIDs, [failed.opID])

        live.selectAction(ExactText("reply"), input: nil, for: key)
        live.updateCompatibilityText("Try again", action: ExactText("reply"), for: key)
        let retry = try await live.submit(key)
        XCTAssertNotEqual(retry.opID, failed.opID)
        let assertionSnapshot291 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot291.outbox.map(\.operationID), [retry.opID],
                       "Only the new answer is retryable after the relay explicitly rejected the old one.")
        XCTAssertFalse(try XCTUnwrap(live.request(for: key)).answerNotDelivered,
                       "A new pending attempt replaces the previous failure treatment.")
    }

    func testFailedResponseRetryUsesTheRetainedAnswerAndClearsWarningOnlyAfterAcceptance() async throws {
        let namespace = "Harklight.live-answer-confirmation-test." + UUID().uuidString
        let installation = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        let relay: LiveAnswerConfirmationRelay
        do {
            relay = try LiveAnswerConfirmationRelay(expectedDeviceID: installation.deviceID)
        } catch {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: installation.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
            throw error
        }
        let draftRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Harklight-live-answer-\(UUID().uuidString)", isDirectory: true)
        let lifecycle = NativeRelayLifecycle.shared
        addTeardownBlock {
            await lifecycle.deactivate()
            relay.close()
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: installation.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
            try? FileManager.default.removeItem(at: draftRoot)
        }

        let port = try await relay.start()
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("localhost"),
            personID: ExactText("person-\(UUID().uuidString.lowercased())"),
            deviceID: ExactText(installation.deviceID)), transportMode: .relay)
        let store = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
        try await lifecycle.activate(store: store, context: context,
            relayURL: try XCTUnwrap(URL(string: "wss://localhost:\(port)/relay")),
            clientIdentity: installation.value, trustedRootDER: relay.rootDER)
        let readiness = await lifecycle.confirmForegroundProgress(for: context, deadline: .seconds(10))
        XCTAssertEqual(readiness.outcome, .confirmed,
                       "The test must establish an authenticated, replay-confirmed relay before sending.")
        XCTAssertTrue(lifecycle.isOnline(for: context))

        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("retry"))
        let live = try LivePresentationStore(store: store, context: context,
            composerDraftPersistence: ComposerDraftPersistence(rootDirectory: draftRoot))
        try await live.refreshFromDurableStore()
        live.selectAction(ExactText("got-it"), input: nil, for: key)
        let initialSend = Task { @MainActor in await live.submitFromUser(key) }
        let firstFrameText = await relay.waitForAnswer(attempt: 1)
        let firstFrame = try JSONValue.parse(Data(firstFrameText.utf8))
        let original = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        let originalFrameOperationID = try XCTUnwrap(firstFrame.uniqueValue(named: "op_id")?.stringValue)
        XCTAssertEqual(originalFrameOperationID.rawValue, original.opID.uuidString.lowercased())
        let initialSendSucceeded = await initialSend.value
        XCTAssertFalse(initialSendSucceeded,
                       "The fixture's correlated refusal should retain the answer for manual Retry.")
        try await live.refreshFromDurableStore()

        let warning = try XCTUnwrap(live.failedResponseWarning(for: key))
        XCTAssertEqual(String(localized: warning.summary), "The response was not sent.")
        XCTAssertEqual(warning.submittedInputs, original.inputs)
        XCTAssertTrue(live.canRetryFailedResponse(for: key))

        let failedRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(failedRow.hasDeliveryWarning)
        XCTAssertNil(failedRow.localStatus)
        XCTAssertFalse(failedRow.visibleStatus.contains("Open"))
        XCTAssertFalse(failedRow.visibleStatus.contains("not delivered"))

        let retryTask = Task { @MainActor in await live.retryFailedResponse(for: key) }
        let retryFrameText = await relay.waitForAnswer(attempt: 2)
        let retryFrame = try JSONValue.parse(Data(retryFrameText.utf8))
        let retried = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        let retryFrameOperationID = try XCTUnwrap(retryFrame.uniqueValue(named: "op_id")?.stringValue)
        XCTAssertEqual(retryFrameOperationID, originalFrameOperationID,
                       "A correlated non-conflict refusal keeps the draft's operation id.")
        XCTAssertEqual(retried.opID, original.opID,
                       "Manual Retry reuses the original id after a correlated refusal.")
        XCTAssertEqual(retryFrame.uniqueValue(named: "inputs"), firstFrame.uniqueValue(named: "inputs"),
                       "The retry frame contains the exact original response.")
        XCTAssertEqual(retried.inputs, original.inputs,
                       "Retry uses the exact submitted response, not the editable draft.")
        XCTAssertEqual(live.failedResponseWarning(for: key)?.retryOperationID, retried.opID)
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).hasDeliveryWarning,
                      "The warning remains while the correlated acceptance is withheld.")
        XCTAssertEqual(live.failedResponseWarning(for: key)?.submittedInputs, original.inputs)

        relay.acceptHeldRetry()
        let retrySucceeded = await retryTask.value
        XCTAssertTrue(retrySucceeded)

        XCTAssertNil(live.failedResponseWarning(for: key),
                     "The warning clears only after correlated acceptance and authoritative refresh.")
        let acceptedRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertFalse(acceptedRow.hasDeliveryWarning)
        XCTAssertTrue(acceptedRow.belongsToReplied,
                      "Replied membership comes from the terminal lifecycle event in the relay refresh.")
    }

    func testFailedNoCommentWarningRetriesTheSameNoCommentResponse() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        let noCommentStarted = await live.submitNoCommentFromUser(key)
        XCTAssertTrue(noCommentStarted)
        let original = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        try await store.recordNoCommentUnsupported(original.intentID, operationID: original.opID,
                                             context: context)
        try await live.refreshFromDurableStore()

        let warning = try XCTUnwrap(live.failedResponseWarning(for: key))
        XCTAssertEqual(warning.answerKind, .noComment)
        XCTAssertTrue(warning.canRetry)
        let retryStarted = await live.retryFailedResponse(for: key)
        XCTAssertTrue(retryStarted)

        let retried = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        XCTAssertEqual(retried.answerKind, .noComment)
        XCTAssertEqual(retried.inputs, [])
        XCTAssertNotEqual(retried.opID, original.opID)
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).hasDeliveryWarning)

        try await store.recordAcceptedOperation(retried.intentID, operationID: retried.opID,
                                          terminalSequence: 2, context: context)
        _ = try await store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)),
                            context: context)
        try await live.refreshFromDurableStore()

        XCTAssertNil(live.failedResponseWarning(for: key))
        XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == key }).hasDeliveryWarning)
    }

    func testMissingNoCommentReplyKeepsPendingExplanationAndReusesOperationID() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        let receipt = try await commitNoComment(store, key: key)
        let session = AnswerSession(context.identity)
        session.loseOperationReply = true
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        let sent = try await core.sendPendingOriginalOperations()
        XCTAssertEqual(sent, 1)
        try await live.refreshFromDurableStore()

        let pending = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(pending.lifecycleStatus, .pending)
        XCTAssertEqual(pending.receiptFacts?.evidenceLabel,
                       "Your answer is saved on this device. Relay acceptance is not yet confirmed.")
        XCTAssertFalse(pending.answerNotDelivered)
        XCTAssertFalse(LiveRequestDetail(request: pending, store: live).canAnswer,
                       "An unknown delivery remains locked until the original operation is reconciled.")
        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(row.belongsToReplied,
                      "The pending response stays in Replied while its outcome is unknown.")
        XCTAssertFalse(row.hasFailedResponse)
        XCTAssertNil(row.localStatus)
        let assertionSnapshot389 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot389.outbox.map(\.operationID), [receipt.opID])

        _ = try await core.sendPendingOriginalOperations()
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID, receipt.opID],
                       "Retry sends the same durable operation rather than creating a duplicate answer.")
        let assertionSnapshot394 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot394.intents.count, 1)
        let assertionSnapshot395 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot395.outbox.map(\.operationID), [receipt.opID])
    }

    func testSwipeNoCommentAcceptanceIsFinalAndCannotBeResubmitted() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        await live.submitNoCommentFromUser(key)

        let receipt = try XCTUnwrap(live.request(for: key)?.intentReceipt)
        let pending = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertEqual(receipt.answerKind, .noComment)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .pending)
        XCTAssertTrue(pending.belongsToReplied,
                      "The swipe records the chosen response locally while server confirmation is pending.")

        try await store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        try await store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)), context: context)
        try await live.refreshFromDurableStore()

        let accepted = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(accepted.lifecycleStatus, .noComment)
        XCTAssertNil(accepted.receiptFacts,
                     "A common No comment terminal does not expose which phone submitted it.")
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied)
        XCTAssertFalse(LiveRequestDetail(request: accepted, store: live).canAnswer)
        let intentCount = try await store.snapshot(context: context).intents.count
        await live.submitNoCommentFromUser(key)
        let assertionSnapshot422 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot422.intents.count, intentCount,
                       "An accepted swipe choice cannot create another answer.")
    }

    func testServerNoCommentTerminalStaysDistinctAndAppearsInReplied() async throws {
        let (context, store, live, key) = try await setup()
        let terminal = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"other-installation","state":"no_comment","at":2}"#.utf8)
        let event = try RelayWire(profile: context).decodeEvent(terminal)
        _ = try await store.apply(event, context: context)
        try await live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.lifecycleStatus, .noComment)
        XCTAssertNil(request.receiptFacts)
        XCTAssertNil(request.accountAnswerOutcome,
                     "An older server still supplies the shared No comment state through lifecycle.")
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied)
    }

    func testAccountSeenOutcomeConfirmsOnAnyDeviceWithoutLocalAnswerReceipt() async throws {
        let (context, store, live, key) = try await setup()
        _ = try await store.apply(RelayEvent(sequence: 2,
            body: .terminal(key, .answered, nil)), context: context)
        let terminal = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","answer_outcome":{"kind":"seen"}}"#.utf8)
        let event = try RelayWire(profile: context).decodeEvent(terminal)
        XCTAssertEqual(event.accountAnswerOutcome, .seen)
        _ = try await store.apply(event, context: context)
        try await live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.informationalSeenStatus, .confirmed)
        XCTAssertEqual(request.accountAnswerOutcome, .seen)
        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(row.status.contains("Seen"))
        XCTAssertFalse(row.status.contains("confirmed"),
                       "A shared Seen outcome is presented as Seen, without a phone-specific confirmation label.")
        XCTAssertEqual(LiveRequestDetail.informationalSeenText(.confirmed), "Seen")
        XCTAssertNil(request.intentReceipt,
                     "A shared terminal does not expose an actor-device operation receipt.")
        XCTAssertTrue(row.belongsToReplied)
    }

    func testNoCommentTerminalKindAndUnknownOptionalOutcomeDoNotStopLifecycleSync() async throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let wire = try RelayWire(profile: context)
        let noComment = try wire.decodeEvent(Data(#"{"v":1,"type":"lifecycle","seq":1,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","terminal_kind":"no_comment"}"#.utf8))
        guard case let .terminal(_, state, _) = noComment.body else {
            return XCTFail("The known lifecycle terminal must continue to decode.")
        }
        XCTAssertEqual(state, .noComment,
                       "The existing terminal_kind field carries No comment across older-server fallback.")

        let commonNoComment = try wire.decodeEvent(Data(#"{"v":1,"type":"lifecycle","seq":4,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","terminal_kind":"no_comment","answer_outcome":{"kind":"no_comment"}}"#.utf8))
        guard case let .terminal(_, commonState, _) = commonNoComment.body else {
            return XCTFail("The shared No comment terminal must continue to decode.")
        }
        XCTAssertEqual(commonState, .noComment)
        XCTAssertEqual(commonNoComment.accountAnswerOutcome, .noComment)

        let futureOutcome = try wire.decodeUpdate(Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","answer_outcome":{"kind":"future_outcome","detail":"ignored"}}"#.utf8))
        guard case let .event(event) = futureOutcome else {
            return XCTFail("An unknown optional answer outcome must not stop the lifecycle stream.")
        }
        XCTAssertNil(event.accountAnswerOutcome)

        let incompleteReply = try wire.decodeUpdate(Data(#"{"v":1,"type":"lifecycle","seq":3,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","answer_outcome":{"kind":"reply"}}"#.utf8))
        guard case let .event(replyEvent) = incompleteReply else {
            return XCTFail("An unusable optional reply outcome must not stop lifecycle replay.")
        }
        XCTAssertNil(replyEvent.accountAnswerOutcome)
    }

    func testAccountReplyOutcomePreservesExactTextAndHidesOriginOnlyLegacyAnswer() async throws {
        let (context, store, live, key) = try await setup()
        let exactText = "Exact reply, with spaces."
        let terminal = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","answer_outcome":{"kind":"reply","text":"Exact reply, with spaces."}}"#.utf8)
        let event = try RelayWire(profile: context).decodeEvent(terminal)
        XCTAssertEqual(event.accountAnswerOutcome, .reply(ExactText(exactText)))
        _ = try await store.apply(event, context: context)
        try await live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.accountAnswerOutcome, .reply(ExactText(exactText)))
        XCTAssertNil(request.informationalSeenStatus,
                     "A reply is not a failed Seen action.")
        XCTAssertNil(request.intentReceipt,
                     "The synced account outcome, not a phone-local receipt, supplies the answer text.")
        XCTAssertNil(request.receiptFacts)
    }

    func testDefaultOutcomeShowsServerWordsAndMarksTheMatchingCurrentChoice() async throws {
        let (context, _, _, key) = try await setup()
        let initialPayload = try JSONValue.parse(Data(#"{"title":"Choose","stake":"Earlier stake","by_when":1793200000000,"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"old","label":"Old choice","kind":"value","value":1}]}}"#.utf8))
        // Replace the setup message with a fresh store to keep the event sequence coherent.
        let freshStore = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
        _ = try await freshStore.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: initialPayload), .message)),
            context: context)
        try await freshStore.applyConversation(ConversationEvent(sequence: 1,
            binding: ConversationBinding(request: key, revision: 1),
            fact: .request(sessionHandle: ExactText("origin"), payload: initialPayload)),
            context: context)
        let revisedPayload = try JSONValue.parse(Data(#"{"title":"Choose","stake":"The review deadline slips.","by_when":1793300000000,"answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"first","label":"Later","kind":"value","value":1},{"id":"second","label":"Later","kind":"value","value":2}]}}"#.utf8))
        let binding = ConversationBinding(request: key, revision: 2)
        let revision = ConversationTurn(id: ExactText("revision-2"), binding: binding,
            author: .origin, sessionHandle: ExactText("origin"), text: ExactText("Choose"), kind: .revision)
        try await freshStore.applyConversation(ConversationEvent(sequence: 2, binding: binding,
            fact: .revision(revision, payload: revisedPayload)), context: context)
        let defaultFrame = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"server","state":"answered","by":"default","answer_outcome":{"kind":"default","value":2,"text":"Hold for now"}}"#.utf8)
        _ = try await freshStore.apply(RelayWire(profile: context).decodeEvent(defaultFrame), context: context)
        let live = try LivePresentationStore(store: freshStore, context: context)

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertTrue(request.isDefaultAnswered)
        XCTAssertEqual(request.defaultAnswerAction,
                       ProjectedActionReference(inputID: nil, actionID: ExactText("second")))
        XCTAssertEqual(request.defaultAnswerWords, "Hold for now",
                       "Display words come from the shared outcome, not the duplicate action label.")
        XCTAssertEqual(request.defaultAnswerStatusText, "Answered by default: Hold for now")
        XCTAssertEqual(String(localized: LiveRequestDetail.answeredConfirmationTitle(
            isDefaultAnswered: request.isDefaultAnswered)), "Answered by default")
        XCTAssertEqual(request.byWhenMilliseconds, 1_793_300_000_000)
        XCTAssertEqual(request.stakeText, ExactText("The review deadline slips."))
        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(row.belongsToReplied)
        XCTAssertEqual(row.defaultAnswerStatus, "Answered by default: Hold for now")
    }

    func testDefaultOutcomeWithoutValueStillShowsTextAndDefaultStatus() async throws {
        let (context, _, _, key) = try await setup()
        let store = try AttentionDomainStore(context: context,
            persistence: MemoryAttentionStatePersistence())
        let payload = try JSONValue.parse(Data(#"{"title":"Choose","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":true}]}}"#.utf8))
        _ = try await store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let frame = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"server","state":"answered","answer_outcome":{"kind":"default","text":"Yes, automatically"}}"#.utf8)
        _ = try await store.apply(RelayWire(profile: context).decodeEvent(frame), context: context)

        let live = try LivePresentationStore(store: store, context: context)
        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertNil(request.defaultAnswerAction)
        XCTAssertEqual(request.defaultAnswerWords, "Yes, automatically")
        XCTAssertEqual(try XCTUnwrap(live.inboxRows.first { $0.key == key }).defaultAnswerStatus,
                       "Answered by default: Yes, automatically")
    }

    func testTerminalInboxPageCarriesTheSharedAccountOutcome() async throws {
        let (context, _, _, key) = try await setup()
        let paging = try InboxPagingWire(profile: context)
        let page = Data(#"{"v":1,"type":"ok","paging_version":1,"ref":"page","snapshot_id":"snapshot","high_water":2,"items":[{"acceptance":{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"sample","origin":"origin","as":"message","message":{"title":"Question","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"first","label":"Later","kind":"value","value":1},{"id":"second","label":"Later","kind":"value","value":2}]}},"session_handle":"handle","request_revision":1,"availability":"not_listening","last_detached_at":123},"terminal":{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","answer_outcome":{"kind":"default","value":2,"text":"Hold for now"}}}],"next_cursor":null}"#.utf8)

        let decoded = try paging.decodePage(page, ref: "page", snapshotID: "snapshot", highWater: 2)

        XCTAssertEqual(decoded.items.first?.terminal?.accountAnswerOutcome,
                       .defaultAnswer(value: .number(JSONNumber(lexeme: "2")),
                                      text: ExactText("Hold for now")))

        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        _ = try await store.beginInboxCandidate(startupID: "startup", since: 0, batches: [], context: context)
        try await store.saveInboxInitialPage(snapshotID: "snapshot", highWater: 2,
            items: decoded.items, nextCursor: nil, receiptCursor: nil, context: context)
        _ = try await store.prepareInboxCheckpointAcknowledgement(context: context)
        _ = try await store.acceptInboxCheckpoint(snapshotID: "snapshot", highWater: 2, context: context)
        let reconnected = try AttentionDomainStore(context: context, persistence: persistence)
        let live = try LivePresentationStore(store: reconnected, context: context)
        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertTrue(request.isDefaultAnswered)
        XCTAssertEqual(request.defaultAnswerAction,
                       ProjectedActionReference(inputID: nil, actionID: ExactText("second")))
        XCTAssertEqual(request.defaultAnswerWords, "Hold for now")
        XCTAssertEqual(try XCTUnwrap(live.inboxRows.first { $0.key == key }).defaultAnswerStatus,
                       "Answered by default: Hold for now")
    }

    func testOlderServerOriginOnlyAnswerDoesNotCreatePhoneSpecificSeenState() async throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("sample"))
        let payload = try JSONValue.parse(Data(#"{"title":"Sample","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        _ = try await store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let live = try LivePresentationStore(store: store, context: context)
        let terminal = Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"device","state":"answered","answer":{"acknowledgment":"seen"}}"#.utf8)
        _ = try await store.apply(RelayWire(profile: context).decodeEvent(terminal), context: context)
        try await live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(request.lifecycleStatus, .answered)
        XCTAssertNil(request.accountAnswerOutcome)
        XCTAssertNil(request.informationalSeenStatus,
                     "An older server's origin-only answer is not the shared account outcome.")
        XCTAssertNil(request.intentReceipt)
        XCTAssertNil(request.receiptFacts)
        XCTAssertTrue(try XCTUnwrap(live.inboxRows.first { $0.key == key }).status.contains("Answered"))
        XCTAssertEqual(String(localized: LiveRequestDetail.answeredConfirmationTitle(
            isDefaultAnswered: request.isDefaultAnswered)), "Answered",
            "An older server's terminal stays generic instead of claiming Replied or Seen.")
    }

    func testRemoteRequestStateReadsPersistedRecordsWithoutAccountOutcome() async throws {
        let saved = try JSONDecoder().decode(RemoteRequestState.self,
                                             from: Data(#"{"state":"answered"}"#.utf8))
        XCTAssertEqual(saved.state, .answered)
        XCTAssertNil(saved.accountAnswerOutcome)
    }

    func testNoCommentCheckmarkCommitsWithoutSavingReplyContents() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        let snapshotBeforeEditing = try await store.snapshot(context: context)
        let draftBeforeEditing = try XCTUnwrap(snapshotBeforeEditing.drafts[key])
        let request = try XCTUnwrap(live.request(for: key))
        let session = ReplyEditorDraftSession(request: request, canSubmitFromSnapshot: true)
        session.selectAction(ExactText("reply"), inputID: nil)
        session.updateText("Keep this local.", target: ReplyEditorTarget(inputID: nil,
                                                                          actionID: "reply"))
        session.selectNoComment()
        XCTAssertTrue(session.noCommentSelected)
        let assertionSnapshot645 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot645.drafts[key], draftBeforeEditing,
                       "Selecting No comment does not save Reply contents over the request's empty baseline.")
        XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied,
                       "Selecting No comment does not submit before the checkmark is tapped.")
        let noCommentSubmitted = await live.submitNoCommentFromUser(key,
            requestRevision: request.requestRevision, selectionIsLocal: true)
        XCTAssertTrue(noCommentSubmitted)

        let submittedSnapshot = try await store.snapshot(context: context)
        let submitted = try XCTUnwrap(submittedSnapshot.outbox.first)
        XCTAssertEqual(String(decoding: submitted.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"reply-only","request_revision":1}"# + "\n")
        let assertionSnapshot656 = try await store.snapshot(context: context)
        XCTAssertNil(assertionSnapshot656.drafts[key])
        XCTAssertTrue(try XCTUnwrap(live.request(for: key)).submittedAnswer?.noCommentSelected == true)
        XCTAssertEqual(submitted.answerKind, .noComment)
    }

    func testNoCommentUsesDisplayedRevisionAndStaleTapKeepsCurrentQuestionOpen() async throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("relay.example"), personID: ExactText("person"),
            deviceID: ExactText("device")), transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("conversation"))
        let first = JSONValue.object([JSONMember("title", .string(ExactText("First wording")))])
        let second = JSONValue.object([JSONMember("title", .string(ExactText("Second wording")))])
        let third = JSONValue.object([JSONMember("title", .string(ExactText("Current wording")))])
        let firstBinding = ConversationBinding(request: key, revision: 1)
        try await store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: first), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("origin"))),
            context: context)
        try await store.applyConversation(ConversationEvent(sequence: 1, binding: firstBinding,
            fact: .request(sessionHandle: ExactText("origin"), payload: first)), context: context)

        let secondBinding = ConversationBinding(request: key, revision: 2)
        let secondRevision = ConversationTurn(id: ExactText("revision-2"), binding: secondBinding,
            author: .origin, sessionHandle: ExactText("origin"), text: ExactText("Second wording"),
            kind: .revision)
        try await store.applyConversation(ConversationEvent(sequence: 2, binding: secondBinding,
            fact: .revision(secondRevision, payload: second)), context: context)

        let live = try LivePresentationStore(store: store, context: context)
        XCTAssertEqual(live.request(for: key)?.title, ExactText("Second wording"))
        let port = AttentionDomainPort(store: store)
        let inspection = try await port.inspect(context: port.context, request: key)
        let selector = try XCTUnwrap(inspection.requests.first?.selector)
        let receipt = try await port.submitNoComment(context: port.context, selector: selector, intentID: UUID())
        let staleSnapshot = try await store.snapshot(context: context)
        let staleSubmission = try XCTUnwrap(staleSnapshot.outbox.first)
        XCTAssertEqual(staleSubmission.requestRevision, 2)
        XCTAssertEqual(String(decoding: staleSubmission.wireFrame, as: UTF8.self),
                       #"{"type":"answer_no_comment","request_id":"conversation","request_revision":2}"# + "\n")

        // A newer replayed revision supersedes the locally pending older attempt.
        let thirdBinding = ConversationBinding(request: key, revision: 3)
        let thirdRevision = ConversationTurn(id: ExactText("revision-3"), binding: thirdBinding,
            author: .origin, sessionHandle: ExactText("origin"), text: ExactText("Current wording"),
            kind: .revision)
        try await store.applyConversation(ConversationEvent(sequence: 3, binding: thirdBinding,
            fact: .revision(thirdRevision, payload: third)), context: context)
        try await live.refreshFromDurableStore()

        let current = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(current.title, ExactText("Current wording"))
        XCTAssertEqual(current.lifecycleStatus, .open)
        XCTAssertNil(current.intentReceipt)
        let assertionSnapshot709 = try await store.conversationSnapshot(context: context)
        XCTAssertEqual(assertionSnapshot709.threads[key]?.currentRevision, 3)
        let assertionSnapshot710 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot710.outbox.isEmpty)
        let assertionLookup711 = try await store.lookupIntent(receipt.intentID, context: context)
        XCTAssertEqual(assertionLookup711?.disposition, .lost)
        XCTAssertFalse(try XCTUnwrap(live.inboxRows.first { $0.key == key }).belongsToReplied,
                       "The current open revision belongs in Inbox after the older No comment intent is superseded.")
    }

    func testDisconnectedInboxKeepsDraftEditableAndCannotCreateOrRetryAnAnswer() async throws {
        let (context, store, live, key) = try await setup(messageID: "offline-\(UUID().uuidString)")
        XCTAssertFalse(live.isOnline, "This fixture has no active relay connection.")
        XCTAssertFalse(live.isReadOnly, "Offline use still allows draft editing.")
        live.selectAction(ExactText("got-it"), input: nil, for: key)
        live.updateCompatibilityText("changed after disconnect", action: ExactText("got-it"), for: key)
        let staged = try XCTUnwrap(live.draft(for: key))
        XCTAssertTrue(staged.hasEdits)
        XCTAssertEqual(staged.compatibility.selectedActionID, ExactText("got-it"))
        XCTAssertEqual(staged.compatibility.textByActionID[ExactText("got-it")],
                       ExactText("changed after disconnect"))

        let sent = await live.submitFromUser(key)
        XCTAssertFalse(sent, "An offline user action cannot create or send an answer.")
        XCTAssertFalse(live.isReadOnly)
        XCTAssertEqual(live.draft(for: key), staged,
                       "The editable draft remains available after the offline send attempt.")
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .open)
        let snapshot = try await store.snapshot(context: context)
        XCTAssertTrue(snapshot.intents.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
    }

    func testAnswerCommittedDuringRefreshGetsADeliveryPassAfterThatRefresh() async throws {
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let (queued, queuedSignal) = AsyncStream<Void>.makeStream()
        var hasSavedAnswer = false
        var passes = 0
        var deliveries = 0
        let flights = RelayRefreshFlights(inactive: false) {
            passes += 1
            let answerSeen = hasSavedAnswer
            if passes == 1 {
                startedSignal.yield()
                for await _ in release { break }
            }
            if answerSeen { deliveries += 1 }
            return true
        }
        let initial = Task { await flights.coalesced() }
        for await _ in started { break }
        hasSavedAnswer = true
        let delivery = Task {
            queuedSignal.yield()
            return await flights.afterCurrent()
        }
        for await _ in queued { break }
        releaseSignal.yield()
        let initialReached = await initial.value
        let deliveryReached = await delivery.value
        XCTAssertTrue(initialReached)
        XCTAssertTrue(deliveryReached)
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(deliveries, 1, "The saved original operation cannot wait for another app wake.")
    }

    func testLateSendOnAnotherDevicesTerminalRequestDoesNotClaimOurAnswerWasAccepted() async throws {
        let (context, store, live, key) = try await setup()
        _ = try await store.apply(RelayEvent(sequence: 2, body: .terminal(key, .answered, nil)), context: context)
        await live.submitFromUser(key)
        XCTAssertEqual(live.actionError, "This request is no longer open for an answer.")
        let assertionSnapshot776 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot776.intents.isEmpty)
        XCTAssertNil(live.request(for: key)?.receiptFacts)
    }

    func testAcceptedAnswerReplaysTerminalEventBeforeCompletingRefresh() async throws {
        let (context, store, live, key) = try await setup()
        let receipt = try await commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        let high = try await core.resyncAndDrainOutbox()
        try await live.refreshFromDurableStore()
        XCTAssertEqual(high, 2)
        let assertionSnapshot788 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot788.cursor, 2)
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(session.acknowledgedCursors, [2],
                       "The checkpoint ACK is distinct; ordinary ACKs cover only post-H events.")
        let assertionSnapshot792 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot792.outbox.isEmpty)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "Without the common outcome field, local acceptance is not displayed as shared state.")
    }

    func testServerAnsweredAfterLostOperationReplyMovesToRepliedWithoutInventingAcceptance() async throws {
        let (context, store, live, key) = try await setup()
        let receipt = try await commitAnswer(store, key: key)
        let session = LostReplyRouteASession(context.identity)
        let core = try await NativeRelayCore(store: store, context: context, session: session)

        let sendResult = try await core.sendOriginalOperation(operationID: receipt.opID)
        guard case .unresolved = sendResult else {
            XCTFail("A lost operation reply remains unresolved until the account feed supplies a terminal fact.")
            return
        }
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])

        try await live.refreshFromDurableStore()
        let uncertain = try XCTUnwrap(live.request(for: key))
        XCTAssertEqual(uncertain.lifecycleStatus, .pending)
        XCTAssertNotEqual(uncertain.receiptFacts?.ownOutcome, .accepted,
                          "A transmitted operation with no correlated reply is not device acceptance.")

        let high = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(high, 2)
        try await live.refreshFromDurableStore()
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "The account terminal resolves the request without inventing device acceptance.")
        let assertionSnapshot810 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot810.outbox.isEmpty)
        XCTAssertNil(live.actionError)
        let row = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(row.belongsToReplied,
                      "The server's answered lifecycle moves the row to Replied.")
        XCTAssertFalse(row.hasFailedResponse)
        XCTAssertTrue(row.isResolved)
        XCTAssertNil(row.localStatus)
        XCTAssertTrue(row.status.contains("Answered"),
                      "Keep the server's answered wording without attributing it to this device.")
        XCTAssertTrue(session.acknowledgedCursors.isEmpty,
                      "Route A applies the resync barrier without sending the legacy paging ACK.")
    }

    func testServerNoCommentAfterLostOperationReplyMovesToRepliedWithoutInventingAcceptance() async throws {
        let (context, store, live, key) = try await setup()
        let receipt = try await commitNoComment(store, key: key)
        let session = AnswerSession(context.identity)
        session.loseOperationReply = true
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        let sentCount = try await core.sendPendingOriginalOperations()
        XCTAssertEqual(sentCount, 1)
        try await store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)), context: context)
        try await live.refreshFromDurableStore()

        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .noComment)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "The common answered state is shown without phone-specific operation attribution.")
        let assertionSnapshot837 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot837.outbox.isEmpty)
        XCTAssertNil(live.actionError)

        let liveRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(liveRow.belongsToReplied,
                      "The server's no-comment lifecycle moves the row to Replied.")
        XCTAssertFalse(liveRow.hasFailedResponse)
        XCTAssertTrue(liveRow.isResolved)
        XCTAssertNil(liveRow.localStatus)
        XCTAssertTrue(liveRow.status.contains("No comment"),
                      "Show the server's lifecycle wording without claiming this device's send was accepted.")

        let sampleResponse = sampleResponse(for: live, key: key)
        let sampleRow = try XCTUnwrap(sampleResponse.inboxRow)
        XCTAssertTrue(sampleRow.belongsToReplied,
                      "The sample projection follows the same server-reported final response.")
        XCTAssertFalse(sampleRow.hasFailedResponse)
        XCTAssertNil(sampleRow.localStatus)
    }

    func testServerNoCommentHidesPriorUnsupportedNoteFromBothRepliedProjections() async throws {
        let (context, store, live, key) = try await setupReplyOnly()
        let receipt = try await commitNoComment(store, key: key)
        try await store.recordNoCommentUnsupported(receipt.intentID, operationID: receipt.opID, context: context)
        try await live.refreshFromDurableStore()
        XCTAssertTrue(live.request(for: key)?.noCommentUnavailable == true)
        let unsupportedLiveRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertFalse(unsupportedLiveRow.belongsToReplied,
                       "An unsupported No comment leaves the request in Inbox.")
        XCTAssertTrue(unsupportedLiveRow.hasDeliveryWarning)
        XCTAssertNil(unsupportedLiveRow.localStatus)
        try await store.apply(RelayEvent(sequence: 2, body: .terminal(key, .noComment, nil)), context: context)
        try await live.refreshFromDurableStore()

        let request = try XCTUnwrap(live.request(for: key))
        XCTAssertFalse(request.noCommentUnavailable,
                       "A terminal account state supersedes the device-local failed attempt.")
        let liveRow = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertTrue(liveRow.belongsToReplied)
        XCTAssertFalse(liveRow.hasDeliveryWarning)
        XCTAssertFalse(liveRow.visibleStatus.contains("Open"))
        XCTAssertFalse(liveRow.localStatus?.contains("No comment not delivered") == true)

        let sampleResponse = sampleResponse(for: live, key: key)
        let sampleRow = try XCTUnwrap(sampleResponse.inboxRow)
        XCTAssertTrue(sampleRow.belongsToReplied)
        XCTAssertFalse(sampleRow.status.contains("No comment not delivered"))
        XCTAssertNil(sampleRow.localStatus)
    }

    func testFailedTerminalReplayDoesNotEraseAcceptedAnswerOrResendItOnReconnect() async throws {
        let (context, store, live, key) = try await setup()
        let receipt = try await commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        session.failReplayAfterSend = true
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        do { _ = try await core.resyncAndDrainOutbox(); XCTFail("The second replay is interrupted") }
        catch InstallationTransportError.unexpectedServerFrame {}
        try await live.refreshFromDurableStore()
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted,
                       "A sent answer remains pending locally until its lifecycle terminal arrives.")
        let assertionSnapshot898 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot898.outbox.isEmpty)
        let assertionSnapshot899 = try await store.snapshot(context: context)
        XCTAssertEqual(assertionSnapshot899.cursor, 1)
        session.failReplayAfterSend = false
        // A failed replay retires its connection's core; reconnect, as the
        // lifecycle does, with a fresh core over the same durable store.
        let reconnected = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await reconnected.resyncAndDrainOutbox()
        try await live.refreshFromDurableStore()
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "The shared terminal projection replaces local operation attribution.")
    }

    func testNotificationRegistrationRefusalDoesNotDowngradeAcceptedAnswer() async throws {
        let (context, store, live, key) = try await setup()
        let receipt = try await commitAnswer(store, key: key)
        let session = AnswerSession(context.identity)
        let core = try await NativeRelayCore(store: store, context: context, session: session)
        _ = try await core.resyncAndDrainOutbox()
        try await live.refreshFromDurableStore()

        let result = await NativeRelayRefreshResult.afterConfirmedRelay(
            context: context, transportAttemptID: UUID()) {
            throw InstallationTransportError.serverRejected
        }
        live.applyRefreshResult(result)
        XCTAssertTrue(result.relayConfirmed)
        XCTAssertEqual(result.pushRegistration, .unconfirmed)
        XCTAssertFalse(result.completedWithoutError)
        XCTAssertNil(live.connectionWarning, "A refused notification setup is not a failed relay answer.")
        XCTAssertNotNil(live.pushRegistrationWarning)
        XCTAssertNil(live.actionError)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(live.request(for: key)?.receiptFacts,
                     "Shared terminal state does not depend on which device sent the answer.")
        XCTAssertEqual(session.sentOperationIDs, [receipt.opID])
        let assertionSnapshot935 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot935.outbox.isEmpty)
    }

    func testLaterRelayFailureKeepsAcceptedReceiptAndNoRegistrationIsInventedOnRecovery() async throws {
        let (context, store, live, key) = try await setup()
        let receipt = try await commitAnswer(store, key: key)
        try await store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 2, context: context)
        try await live.refreshFromDurableStore()
        live.applyRefreshResult(.unavailable)
        XCTAssertNotNil(live.connectionWarning)
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
        XCTAssertNil(live.actionError)

        let result = await NativeRelayRefreshResult.afterConfirmedRelay(
            context: context, transportAttemptID: UUID()) { .notAttempted }
        live.applyRefreshResult(result)
        XCTAssertNil(live.connectionWarning)
        XCTAssertEqual(result.pushRegistration, .notAttempted,
                       "A working relay alone cannot establish APNs registration.")
        XCTAssertEqual(live.request(for: key)?.receiptFacts?.ownOutcome, .accepted)
    }

    func testConfirmedNotificationSetupClearsItsWarningWithoutCreatingAnAnswer() async throws {
        let (context, store, live, key) = try await setup()
        let refused = await NativeRelayRefreshResult.afterConfirmedRelay(
            context: context, transportAttemptID: UUID()) {
            throw InstallationTransportError.serverRejected
        }
        live.applyRefreshResult(refused)
        XCTAssertNotNil(live.pushRegistrationWarning)
        let registered = await NativeRelayRefreshResult.afterConfirmedRelay(
            context: context, transportAttemptID: UUID()) { .confirmed }
        live.applyRefreshResult(registered)
        XCTAssertEqual(registered.pushRegistration, .confirmed)
        XCTAssertNil(live.pushRegistrationWarning)
        XCTAssertNil(live.connectionWarning)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .open)
        let assertionSnapshot973 = try await store.snapshot(context: context)
        XCTAssertTrue(assertionSnapshot973.intents.isEmpty)
    }
}

private final class AnswerSession: AuthenticatedInboxPagingSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    var sentOperationIDs: [UUID] = []
    var acceptedOperationIDs: Set<UUID> = []
    var acknowledgedCursors: [UInt64] = []
    var loseOperationReply = false
    var rejectOperation = false
    var failReplayAfterSend = false

    init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        if !sentOperationIDs.isEmpty && failReplayAfterSend {
            throw InstallationTransportError.unexpectedServerFrame
        }
        try await consume(Data("{\"v\":1,\"type\":\"ok\",\"ref\":\"native-sync\"}\n".utf8))
        let since = try JSONValue.parse(request).uniqueValue(named: "since")
        if !sentOperationIDs.isEmpty {
            if case .number(let number)? = since, number.lexeme == "1" {
                try await consume(Data("{\"v\":1,\"type\":\"lifecycle\",\"seq\":2,\"sender_id\":\"sender\",\"message_id\":\"sample\",\"origin\":\"device\",\"state\":\"answered\",\"at\":1,\"answer\":\"got-it\"}\n".utf8))
            }
            try await consume(Data("{\"v\":1,\"type\":\"resynced\",\"seq\":2}\n".utf8))
        } else {
            try await consume(Data("{\"v\":1,\"type\":\"resynced\",\"seq\":1}\n".utf8))
        }
    }

    func correlatedRequest(_ request: Data, ref: String) async throws -> Data {
        try await inboxRequest(request, ref: ref)
    }

    func acknowledge(_ request: Data) async throws {
        if case .number(let value)? = try JSONValue.parse(request).uniqueValue(named: "seq"),
           let sequence = UInt64(value.lexeme) { acknowledgedCursors.append(sequence) }
    }

    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        sentOperationIDs.append(operationID)
        if rejectOperation { return .failed(operationID: operationID) }
        if loseOperationReply { return .unresolved }
        acceptedOperationIDs.insert(operationID)
        return .accepted(operationID: operationID, terminalSequence: 2)
    }

    /// Once the relay has accepted an answer, a new connection's inbox
    /// snapshot includes its terminal at sequence 2 and reconciles the
    /// operation as committed, as the relay reports an accepted original.
    func inboxRequest(_ request: Data, ref: String) async throws -> Data {
        let value = try JSONValue.parse(request)
        let kind = value.uniqueValue(named: "type")?.stringValue?.rawValue
        guard !acceptedOperationIDs.isEmpty, kind == "inbox_start" || kind == "inbox_reconcile" else {
            return try await emptyInboxReply(request, ref: ref)
        }
        var reply = "{\"v\":1,\"type\":\"ok\",\"ref\":\"\(ref)\",\"paging_version\":1,\"high_water\":2"
        if kind == "inbox_start" {
            let startupID = value.uniqueValue(named: "startup_id")?.stringValue?.rawValue ?? ""
            reply += ",\"snapshot_id\":\"test-\(startupID)-h2\",\"items\":[],\"next_cursor\":null,\"receipt_cursor\":null}"
        } else {
            let snapshotID = value.uniqueValue(named: "snapshot_id")?.stringValue?.rawValue ?? ""
            let batchID = value.uniqueValue(named: "batch_id")?.stringValue?.rawValue ?? ""
            let results = (value.uniqueValue(named: "operations")?.arrayValues ?? []).map { operation -> String in
                let opID = operation.uniqueValue(named: "op_id")?.stringValue?.rawValue ?? ""
                guard let id = UUID(uuidString: opID), acceptedOperationIDs.contains(id) else {
                    return "{\"op_id\":\"\(opID)\",\"status\":\"not_committed_at_snapshot\"}"
                }
                return "{\"op_id\":\"\(opID)\",\"status\":\"committed\",\"result\":{\"v\":1,\"type\":\"ok\",\"seq\":2,\"duplicate\":true},\"terminal\":{\"v\":1,\"type\":\"lifecycle\",\"seq\":2,\"sender_id\":\"sender\",\"message_id\":\"sample\",\"origin\":\"device\",\"state\":\"answered\",\"at\":1,\"answer\":\"got-it\"}}"
            }
            reply += ",\"snapshot_id\":\"\(snapshotID)\",\"batch_id\":\"\(batchID)\",\"results\":[\(results.joined(separator: ","))]}"
        }
        return Data((reply + "\n").utf8)
    }
}

private final class LostReplyRouteASession: AuthenticatedInstallationSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    private(set) var sentOperationIDs: [UUID] = []
    private(set) var acknowledgedCursors: [UInt64] = []
    private var hasAttemptedOperation = false

    init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        try await consume(Data(#"{"v":1,"type":"ok","ref":"native-sync"}"#.utf8))
        try await consume(Data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"sample","origin":"source","as":"message","message":{"title":"Sample","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"got-it","label":"Got it","kind":"value","value":"got-it"}]}}}"#.utf8))
        if hasAttemptedOperation {
            try await consume(Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"sample","origin":"another-device","state":"answered","at":1}"#.utf8))
            try await consume(Data(#"{"v":1,"type":"resynced","seq":2}"#.utf8))
        } else {
            try await consume(Data(#"{"v":1,"type":"resynced","seq":1}"#.utf8))
        }
    }

    func acknowledge(_ request: Data) async throws {
        if case .number(let value)? = try JSONValue.parse(request).uniqueValue(named: "seq"),
           let sequence = UInt64(value.lexeme) {
            acknowledgedCursors.append(sequence)
        }
    }

    func correlatedRequest(_ request: Data, ref: String) async throws -> Data {
        let value = try JSONValue.parse(request)
        guard value.uniqueValue(named: "type")?.stringValue?.rawValue == "view_get" else {
            throw InstallationTransportError.unexpectedServerFrame
        }
        return Data((#"{"v":1,"type":"ok","ref":"\#(ref)","view_rev":"route-a-test","entries":[]}"# + "\n").utf8)
    }

    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        sentOperationIDs.append(operationID)
        hasAttemptedOperation = true
        return .unresolved
    }
}
